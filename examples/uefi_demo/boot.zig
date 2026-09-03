// examples/uefi_demo/boot.zig — the entire OS-independent bring-up.
//
// This is the whole reason UEFI needs less from Tauraro than Cortex-M did:
// the firmware already did reset vectors, memory setup, and the boot menu
// before this function is ever called. All that is left is finding the two
// things a UI toolkit needs -- memory, and a framebuffer -- and handing them
// to Tauraro-compiled code. Everything downstream of the three calls below
// (parsing, style resolution, layout, painting, event dispatch) is the exact
// same toolkit source examples/bare_demo/main.tr runs on a Cortex-M3.
//
// Deliberately NOT written in Tauraro: Tauraro's --freestanding mode only
// generates boot glue for Cortex-M and RISC-V (see CLAUDE.md), and does not
// know the PE/COFF UEFI ABI or protocol tables. UEFI already provides its own
// entry point and its own allocator, so none of that generation is needed --
// only a thin caller, which is what this file is.

const std = @import("std");
const uefi = std.os.uefi;

// The two Tauraro entry points, compiled separately from render.tr with
// `tauraroc render.tr --freestanding --emit c` (no @entry, no --emit-ld --
// see the header comment in that file for why) and linked into this same
// binary by scripts/build-uefi.ps1.
extern fn tauraro_heap_init(base: [*]u8, size: usize) void;
extern fn tauraro_ui_render(fb: [*]u32, width: c_longlong, height: c_longlong, pitch: c_longlong) void;

// 16 MiB. Generous on purpose: heap_alloc() in render.tr has no error
// channel back to the caller if the arena runs out -- it returns a null
// pointer, which the toolkit was never written to expect, so this needs to
// be sized well above what one render pass and one bump-allocated parse
// tree actually cost rather than tuned tight.
const HEAP_SIZE: usize = 16 * 1024 * 1024;

pub fn main() void {
    const bs = uefi.system_table.boot_services.?;

    // 1) Memory. UEFI's AllocatePool is the real allocator; Tauraro's bump
    //    arena just carves fixed-size slices out of one block of it, the
    //    same shape as the Cortex-M version but pointed at real firmware
    //    memory instead of a hardcoded SRAM address.
    const heap_bytes = bs.allocatePool(.loader_data, HEAP_SIZE) catch return;
    tauraro_heap_init(heap_bytes.ptr, HEAP_SIZE);

    // 2) A framebuffer. This is the whole reason UEFI is a better target for
    //    a UI toolkit than raw Cortex-M: GOP hands back an already-mapped
    //    linear framebuffer with no MMIO driver to write.
    const gop = (bs.locateProtocol(uefi.protocol.GraphicsOutput, null) catch return) orelse return;
    const mode = gop.mode;
    const fb: [*]u32 = @ptrFromInt(mode.frame_buffer_base);

    // 3) Everything else -- parsing, style resolution, layout, painting,
    //    hit-testing, handler dispatch -- is Tauraro, unchanged from the
    //    other two tiers.
    tauraro_ui_render(
        fb,
        @intCast(mode.info.horizontal_resolution),
        @intCast(mode.info.vertical_resolution),
        @intCast(mode.info.pixels_per_scan_line),
    );

    // No OS to return to and nothing left to do -- halt rather than let the
    // firmware fall through to whatever boot option comes next.
    while (true) {
        asm volatile ("hlt");
    }
}
