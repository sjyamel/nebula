# Project memory — read this first

This is a from-scratch project: a declarative, Tailwind-style UI toolkit written in the
**Tauraro** language (github.com/tauraro/tauraro), interpreted at runtime rather than compiled
in, targeting both a hosted dev loop and eventually bare-metal / OS-level rendering. Full
rationale and phased plan: `docs/proposal/proposal-v2-runtime-interpreter.md` — read that before
writing code, it's the actual spec this scaffold was generated from.

Everything below is what a prior session (Claude, in Cowork) verified about the Tauraro
language by actually building its compiler and compiling test programs against it — not by
reading documentation alone. Treat facts marked **verified** as tested; everything else is from
docs/README and should be spot-checked before being relied on for anything load-bearing.

**`tau_bugs.txt`** at the repo root is the running log of confirmed Tauraro compiler/SDK/docs
defects, each reduced to a minimal repro. Check it before spending time re-diagnosing a hang or
a confusing error — several of the entries there cost hours the first time.

## Getting a working compiler immediately

**Use the installed Windows SDK. It is on PATH and it works.**

```
C:\Users\HomePC\.taupkg\bin\tauraroc-windows-x64\tauraroc.exe   # tauraroc v0.0.8
```

It ships `zig/` (so no system gcc/clang is needed), `std/`, `runtime/`, plus `src/` (the
self-hosted compiler in Tauraro) and `examples/` — both are the best available source of
*idiomatic, actually-compiling* Tauraro, and worth reading before guessing at syntax from docs.

**Always run it from the repository root**, so that `.` (search-path priority 1) resolves
`toolkit.*` module paths:
```sh
tauraroc --run examples/hosted_demo/main.tr
```
Note: a fresh terminal may need PATH refreshed from the registry; the entry is on the *user*
PATH, so a shell started before install won't see it.

> The vendored `vendor/tauraroc/` binary below is **superseded and unusable on this machine** —
> it is a Linux x86-64 ELF. Kept only for provenance. Everything in this file that was verified
> against it has since been re-verified against the Windows SDK above.

`vendor/tauraroc/tauraroc` is a working Linux x64 build of `tauraroc v0.0.8`, built from the
upstream repo's own committed `bootstrap/c/` portable-C seed with:
```sh
gcc -O2 -w -Ibootstrap/c -std=gnu11 -D_GNU_SOURCE -D_XOPEN_SOURCE=700 \
  bootstrap/c/main.c bootstrap/c/module_*.c bootstrap/c/include/core/*.c \
  -o tauraroc -lm -lpthread -lrt
```
**Verified working** — this exact binary compiled and ran every `.tr` file in
`verified-examples/`. It needs `runtime/tauraro_rt.h` to be reachable — the compiler searches
(in order) relative to the binary's own directory/parent/grandparent for `runtime/tauraro_rt.h`,
and also checks `./runtime/tauraro_rt.h` relative to the **current working directory**. The
simplest reliable pattern: run it from `vendor/tauraroc/` (which has `runtime/` right beside the
binary), e.g. `./vendor/tauraroc/tauraroc --run ../../some_file.tr`, or `cd vendor/tauraroc &&
./tauraroc --run /absolute/path/to/file.tr`.

Before trusting anything below on real work: **get the actual current release binary** from
https://github.com/tauraro/tauraro/releases (currently `v0.0.8`) or re-clone and rebuild — this
vendored binary is a snapshot from one session and the upstream project is pre-0.1 (breaking
changes are normal between releases per its own versioning policy,
`docs/tauraro-lang-reference/dev/00_versioning_policy.md`).

Self-hosting (compiling the real compiler, written in Tauraro itself, at `src/*.tr` in the
upstream repo) was attempted and **failed** in this session with a missing-symbol link error
(`undefined reference to _tr_llvm_emit_object`) — not investigated further. Not needed for this
project; noted so it isn't re-discovered from scratch.

## Verified language facts (compiled and run, not assumed)

- **Collections: it's `Dict[K, V]`, not `Map[K, V]`.** `Dict` is the real user-facing type,
  constructed with a `{}` literal (`mut cache: Dict[str, int] = {}`), used with `in` and `[key]`
  indexing. An earlier draft of this project's proposal used `Map[...]` — that was wrong; ignore
  any `Map[...]` you see in older notes and use `Dict[...]`. See
  `verified-examples/dict_backed_cache.tr` for a confirmed-working example (a style-cache-shaped
  class using `Dict`).
- **Raw pointer `.read()` needs `unsafe:` in ordinary code.** `Pointer[T].read()` is rejected
  with error `[P-2]` outside an `unsafe:` block. The compiler's own internal modules (e.g.
  `src/mir.tr`) are exempt via a `@trusted` module annotation not available to ordinary user
  code — don't take patterns from the compiler's own source as proof something works unmarked.
- **`match` on an enum wants an explicit `case _:`, even when every variant is already listed**,
  or the compiler's return-path checker (`[F-3]`) reports a missing return on a function that in
  fact returns on every real path. Always add a trailing wildcard arm as a matter of style, even
  when it looks redundant. See `verified-examples/boxed_enum_tree_walk.tr` — a boxed recursive
  enum (`Pointer[UiNode]`) walked recursively with `match`, the exact pattern the UI AST design
  depends on, confirmed compiling and running correctly with this rule applied.
- **The macro system (`macro def` / `name!(...)`) segfaulted the compiler** on the simplest
  possible test case (a two-line function-like macro). Reproduced twice. Not yet retested against
  an actual release binary rather than this bootstrap build — do that before relying on macros
  for anything. The current proposal (v2) doesn't depend on macros for the UI/style system
  (that moved to a runtime interpreter instead), so this is lower-priority to chase down, but
  worth knowing before reaching for `macro def` for anything else.

## Verified while building the toolkit (compiled + run on the Windows SDK)

Everything here was confirmed by compiling and running it, not by reading docs. Several of these
contradict the docs directly — the docs lose.

**Ownership / moves — the biggest source of surprise.**
- **Assigning a local into a field moves it.** `self.root = box` then using `box` again is
  `[M-1]`. Assign first, then work through the field.
- **Upcasting to an interface-typed variable MOVES the concrete object.**
  `mut view: Canvas = canvas` makes `canvas` unusable afterwards — you can no longer call
  `canvas.save_ppm(...)`. This is a trap, because the docs present the explicit upcast as the
  recommended style.
- **Passing a concrete instance directly into a free function's interface parameter upcasts
  without moving it.** `draw(canvas)` where `def draw(c: Canvas)` leaves `canvas` fully usable.
- **A method call does NOT auto-upcast** — `it.render(tree, canvas)` fails to compile with an
  incompatible-pointer error. Combined with the two rules above, the working pattern is a free
  function wrapper; `toolkit/ui/interp.tr`'s `render_to()` exists solely for this reason.

**Interfaces.** `pub interface` in one module, `implements` in another, and vtable dispatch
across module boundaries all work. Two implementations of one interface confirmed working.

**Collections.**
- `Dict[str, def(Event) -> void]` **works hosted** — storing and fetching a function value from a
  Dict compiles and runs fine there. **But see `tau_bugs.txt` #1: calling any first-class function
  value hangs under `--freestanding`**, which rules this pattern out for the bare-metal tier
  despite compiling cleanly. The toolkit's handler bridge (`toolkit/ui/interp.tr`) uses an
  `EventHandler` interface instead, specifically because of this.
- `Dict[str, SomeClass]` works, as does `len(someDict)`.
- `List[T]` supports index assignment (`px[i] = v`) — the framebuffer depends on this.
- `List[u8]` works with explicit `255 as u8` casts.
- `len()` works on `List` and `Dict`. For a `str`, use `Str.len(s)`.

**Callables.** `def(int, int) -> int` **is** valid as a parameter type and as a class field type.
`docs/.../05_functions.md:477` explicitly calls this "ERROR: not valid syntax" — **that doc is
wrong**; the shipped `examples/28_first_class_functions.tr` uses it throughout. (`lambda` is the
type of *closures*, which are a different thing from top-level function values.)

**Standard library import paths: both forms work.** `from core.vec import Vec` and
`from std.hal.mmio import write32` are both valid, because the compiler's install root *and* its
`std/` subdirectory are both on the search path. The shipped examples use both. Prefer whichever
the nearest shipped example uses; don't "fix" one into the other.

Useful signatures, confirmed: `Str.len/split/slice(s,start,end_exclusive)/starts_with/index_of/
trim/char_at(->int codepoint)/parse_int/is_digit`; `StringBuilder.init(cap)/.append/.append_int/
.append_char(int)/.to_string().as_str()`; `File.read_text(path)->str`,
`File.write_text(path,data)->bool`.

**Syntax that works:** `elif`, `not`, `break` in nested `while`, private (non-`pub`) methods in an
`extend` block called via `self`, `for x in list`, integer division with `/`.

## Not yet verified — treat as docs-only until tested

Ownership/borrow annotations (`Own`/`Borrow`/`Move`/`Shared`) beyond their names; closure capture
semantics; interfaces/dynamic dispatch; `Result[T,E]`/`throws`/`?` error handling; concurrency
primitives (`spawn`, `Thread`, `Mutex`, `Chan` — note `Atomic[T]` is documented to work at every
runtime tier including freestanding, everything else concurrency-related is undocumented for
freestanding and likely OS-thread-backed only); and — most importantly for this project —
**nothing on the `--freestanding` / bare-metal path has been compiled yet.** That's the highest-
value thing to verify next; the proposal's whole premise rests on it.

## Known real gaps in Tauraro relevant to this project (confirmed absent, not just undocumented)

No framebuffer/graphics/rasterizer code anywhere in `std/` (searched the full tree). No font/text
rendering beyond a minimal `std/unicode`. No input drivers (PS/2, USB HID) of any kind. No
interrupt-controller support (PIC/APIC/GIC) — `@interrupt` only emits the bare GCC attribute, it
doesn't configure hardware. No filesystem or storage driver, which matters for the
`toolkit/transport/` layer's disk-based delivery option. No general-purpose allocator for the
freestanding tier — only a hand-written bump allocator is demonstrated
(`docs/tauraro-lang-reference/lang/advanced/11_bare_metal.md`). `std.gpu.Gpu` (the parallel-
dispatch story) is OpenMP-backed and hosted-only; not usable bare-metal. Full detail and the
reasoning behind each is in the proposal doc's §5–§8.

## Repo layout (from the proposal's §7, already scaffolded as empty dirs)

```
toolkit/ui/          UiNode AST, parser, tree-walking interpreter, style cache
toolkit/layout/       flexbox-subset layout engine
toolkit/render/       Canvas trait + rasterizer primitives
toolkit/render/hosted/  in-memory buffer backend (fast dev loop)
toolkit/render/bare/    MMIO framebuffer backend (Cortex-M, UART-PPM)
toolkit/render/uefi/    GOP linear-framebuffer backend (real display, primary target)
toolkit/widgets/      Text, Panel, Button, List, Image
toolkit/text/          baked bitmap font atlas + lookup (real glyph rendering, all 3 tiers)
toolkit/input/         event types + PS/2 driver (bare) + host binding (dev)
toolkit/transport/     UART push protocol (bare) + file/socket watch (hosted)
toolkit/platform/      boot glue, allocator, timer — thin, OS-specific
examples/hosted_demo/  std tier, loads + hot-reloads a UI file
examples/bare_demo/    --freestanding Cortex-M, qemu-system-arm + UART-PPM
examples/uefi_demo/    --freestanding (no @entry) + hand-written zig UEFI stub,
                        qemu-system-x86_64 + OVMF, real display window
tools/fonts/           JetBrainsMono.ttf (SIL OFL 1.1) + its license -- font-baking source
vendor/tauraroc/       the compiler binary + runtime/ headers it needs
verified-examples/     small .tr files confirmed to compile+run in this session
docs/proposal/          the actual spec (v2, current)
docs/tauraro-lang-reference/  upstream language/stdlib/dev docs, copied for offline reading
```

## Current status

**Phases 0–4 are built, compiling, and running** (hosted tier). `tauraroc --run
examples/hosted_demo/main.tr` from the repo root loads a UI file, parses it to a `UiNode` tree,
resolves class strings through the cached style table, lays it out, paints it to a `Canvas`, and
writes a PPM — then renders a *different* file through the *same* live `Interpreter`, which is
the live-reload half of the proposal's §9 definition of done.

Real modules, in dependency order (each imports only downward — Tauraro rejects circular imports,
so `toolkit/types.tr` exists to hold shared vocabulary and import nothing):

```
toolkit/types.tr              Color packing, Rect, Event        (imports nothing)
toolkit/ui/ast.tr             UiNode enum, boxing, depth guard
toolkit/ui/style.tr           utility tokens, Style, StyleCache
toolkit/ui/parser.tr          XML-like markup -> UiNode (see below)
toolkit/render/canvas.tr      the Canvas interface (width/height/fill_rect/set_pixel)
toolkit/render/hosted/buffer.tr  BufferCanvas + clipping + PPM
toolkit/text/font_data.tr     GENERATED: baked bitmap glyph atlas (scripts/bake-font.ps1)
toolkit/text/font.tr          Font: pixel_set(codepoint, col, row) lookup
toolkit/layout/flex.tr        build/measure/place, row+col+gap+pad+grow (glyph size from font)
toolkit/ui/interp.tr          tree walk, real glyph painting, hit-test, handler allowlist
examples/hosted_demo/         main.tr + app.ui + app.reload.ui
```

## UI markup format: XML-like, not indentation-based (changed 2026-09-03)

The `.ui` format switched from an indentation-based syntax to angle-bracket markup, at the
user's direction — they want this toolkit usable for real OS-level UI (they previously shipped a
Rust UEFI DXE driver doing exactly that), and XML/HTML-shaped markup is what every editor already
has syntax highlighting for. See `examples/hosted_demo/app.ui` for a live example. Shape:

```
<panel "flex-col p-4 gap-3 bg-slate">
  <text "text-white">TAURARO UI TOOLKIT</text>
  <panel "bg-red grow" />
  <button "bg-amber grow" @on_click(on_ok)>
    <text "text-black">OK</text>
  </button>
</panel>
```

- The class string is a single **bare** quoted literal — no `class="..."` attribute name. This
  was a deliberate user choice (see the three options offered and picked in this session), not
  an oversight; `class="..."` was on the table and rejected.
- `@event(handler)` binds a host handler **name** to an event **name** — e.g. `@on_click(on_ok)`
  registers "on_ok" against the "on_click" event specifically. These are two separate strings in
  the AST (`UiNode.Element`'s `event_name` and `handler` fields), not one combined token, so a
  second event kind (e.g. `on_load`, a lifecycle event) is an `interp.tr`-only change later, not
  a format change. **Only `on_click` is wired to real dispatch today** —
  `toolkit.types.event_name_for_kind()` is the one place that mapping lives; a node written as
  `@on_load(...)` parses fine and simply never fires, because no lifecycle system exists yet.
- `<text "...">inner text</text>` — the one tag whose body is read **verbatim** up to the literal
  `</text>`, not re-parsed as markup. No mixed content anywhere else: every other tag's children
  are always child elements, never interleaved text.
- Self-closing (`<panel "..." />`) and open/close (`<panel "...">...</panel>`) are both supported;
  `#` starts a line comment, recognized only between tags.
- The parser (`toolkit/ui/parser.tr`) is a hand-written recursive-descent scanner over the whole
  source string (not line-based like the old format), with the same "never crash on malformed
  input" philosophy as before: unterminated tags, mismatched closing tag names, and bad `@event(`
  syntax are all recorded as errors and recovered from rather than aborting the parse.

## Bare metal on Windows — the toolchain half is SOLVED and verified

The freestanding path **works on Windows with no extra installs**, contrary to the earlier
assumption in this file. Verified on 2026-09-02 by building the SDK's own
`examples/freestanding/mps2_pure.tr`:

- `tauraroc <f>.tr --freestanding --emit c --emit-ld app.ld` emits C + a Cortex-M linker script.
- The **bundled `zig/zig.exe` cross-links it to a real ARM ELF** — confirmed 32-bit little-endian
  `EXEC`, `e_machine` 40 (ARM), entry `0x0` (the Cortex-M reset vector). No `arm-none-eabi-gcc`
  needed. The "MinGW is not a faithful freestanding target" warning in the docs is about using
  MinGW; it does not apply to cross-compiling with zig, which is what we do.

Use `scripts/build-bare.ps1`. **Two flags differ from the documented command**, both found by
running the documented one and reading the linker errors:

| Docs say | Use instead | Why |
|---|---|---|
| `-nostdlib` | `-nostartfiles` | `-nostdlib` also drops zig's compiler_rt, so every soft-float / 64-bit helper the Cortex-M3 lacks fails to link (`__aeabi_dsub`, `dmul`, `d2iz`, `i2d`, `uldivmod`, …). The arm-none-eabi path solves this with `-lgcc`. |
| *(nothing)* | `-fno-sanitize=undefined` | zig enables UBSan by default; nothing provides `__ubsan_handle_*` freestanding. |

`ld.lld: warning: cannot find entry symbol _start` is expected and harmless — on Cortex-M the
`.isr_vector` table drives reset. Also note: in PowerShell 5.1, do **not** pipe a native tool's
stderr with `2>&1`; it becomes ErrorRecords and trips `ErrorActionPreference=Stop` even on
success. The script redirects through `cmd /c` for this reason.

**The one missing piece is QEMU**, which is not installed. `winget install --id
SoftwareFreedomConservancy.QEMU` needs elevation, so it must be run from an **admin** terminal.
After installing, add `C:\Program Files\qemu` to PATH and run:
```
qemu-system-arm -M mps2-an385 -nographic -kernel build-bare\app.elf
```

**Target choice — do not follow the proposal's Phase 9 x86 assumption.** Tauraro generates boot
glue for **Cortex-M and RISC-V only** (`docs/.../11_bare_metal.md` §"Boot entry"). Going to x86
Multiboot2 means hand-writing the startup and linker script and giving up `@entry` / `--emit-ld`
entirely — maximum work, zero tool support. ARM/RISC-V is where the language actually helps.

The open sub-problem is that **mps2-an385 has no display** — it is UART-only. See next section.

## Bare metal: VERIFIED END TO END (2026-09-03)

QEMU is installed (`SoftwareFreedomConservancy.QEMU`, at `C:\Program Files\qemu` — not
automatically on PATH). The **entire toolkit now runs on bare metal**:

```
.\scriptsuild-bare.ps1 -Source examplesare_demo\main.tr
qemu-system-arm -M mps2-an385 -nographic -kernel build-barepp.elf > out.ppm
```

`examples/bare_demo/` renders a 64x48 frame on a Cortex-M3 with no OS, no libc and no
filesystem, streams it out the UART as a PPM, and reports
`dispatch button=true padding=false hits=1`. Parser, style cache, flexbox layout, interpreter,
rasteriser, hit-test and handler dispatch are the SAME toolkit source the hosted demo runs.
Only two things are substituted: `BufferCanvas` (needs `io.file`) becomes `FrameBuffer`, and the
UI file becomes a string compiled into the image.

### Three freestanding compiler bugs found the hard way

All three cost hours; none is in our code. Each was reduced to a minimal repro.

1. **Calling ANY first-class function value hangs.** Not Dict-specific, not toolkit-specific:
   `mut f: def(int) -> int = add1` then `f(41)` hangs in a standalone freestanding program.
   Assigning the value works; *calling* it never returns. Works fine hosted.
   **Consequence:** the proposal's 5.5 `Dict[str, def(Event) -> void]` handler table CANNOT
   work bare-metal. The toolkit now uses a `pub interface EventHandler` instead — interface
   vtable dispatch works on both tiers (the `Canvas` backend already proved it).
2. **A private recursive method returning `str` hangs.** `Interpreter.hit` did; the
   byte-identical logic as a free function (`hit_test`) does not. `Interpreter.paint` is also
   private and recursive but returns `void` and is fine, so the trigger looks like the string
   return, not the recursion. Keep recursive string-returning helpers as free functions.
3. **`register` is a C keyword.** A `pub def register(...)` emitted as a C symbol gets mangled
   to `_tr_fn_register` and *silently loses the interface upcast*, producing a confusing
   `passing 'char *' to parameter of incompatible type 'TrStr'`. Avoid C keywords as public
   function names (`register`, `auto`, `extern`, `inline`, `restrict`, ...).

### The bump allocator in the SDK example is subtly broken — do not copy it

`examples/freestanding/mps2_pure.tr` defines `@realloc` as `return heap_alloc(n)`: it allocates
fresh memory and **never copies the old contents**. That example never grows a collection so the
bug is invisible there, but every `List`/`Dict` append reallocs. The symptom is maddening — the
parser reports `parse: ok` and returns **exactly one node**, holding the *last* line of input.
A correct arena for this toolkit needs all four of:

- **realloc must COPY** the old bytes.
- **grow in place when the block is the newest allocation** (track `_last_ptr`), or repeated
  appends are O(n^2) and a 64x48 framebuffer never finishes on an emulated M3.
- **never move `_heap_next` backwards** on a shrinking realloc, or the freed tail is handed out
  while the block is still live — this showed up as a hang in an unrelated `Dict` lookup.
- **never return a zero-length block**; round up and enforce a minimum, or two live objects
  share an address.

Also: the bare `FrameBuffer` uses `Vec[int].init(w*h)` rather than `List[int]` + `append`,
because `Vec` reserves the exact final size up front and never reallocs.

## UEFI: real display, VERIFIED END TO END (2026-09-03) — now the primary target

Direction changed deliberately (user has prior experience shipping a Rust UEFI DXE driver and
wants this toolkit usable for real OS-level UI, e.g. a boot-time login screen — the display path
matters more here than the Cortex-M/UART route). **UEFI is a materially better target than
Cortex-M for this project**, and, contrary to first assumption, it is *less* work, not more:
firmware already did reset vectors, memory setup, and the boot menu, and it hands a real
already-mapped linear framebuffer (GOP) directly to the caller — no MMIO display driver to write,
no PPM-over-UART round trip, no `@entry`/`--emit-ld` at all.

```
.\scripts\run-uefi.ps1
```

builds `examples/uefi_demo/` and boots it under `qemu-system-x86_64 -M q35` with OVMF firmware
(shipped inside the QEMU install, nothing extra to fetch), opening a **real graphical window**
showing the toolkit's actual render — parser, style cache, layout, interpreter, `EventHandler`
dispatch, all unchanged from the Cortex-M tier. `-NoWindow` runs headless and captures an
automated screenshot via QEMU's monitor `screendump` command for verification without a human
watching.

### The shape: Tauraro is not the boot glue here — a thin zig stub is

Tauraro's `--freestanding` only generates boot glue for Cortex-M and RISC-V (see below); it does
not know the PE/COFF UEFI ABI or protocol tables, and does not need to, because UEFI firmware
already **is** the boot glue. The split:

- `examples/uefi_demo/boot.zig` — ~50 lines, hand-written. The real UEFI entry point. Calls
  `BootServices.allocatePool()` for a heap block, locates the GOP protocol for a framebuffer
  pointer + resolution + `PixelsPerScanLine`, then calls two Tauraro-exported functions.
- `examples/uefi_demo/render.tr` — plain Tauraro, compiled with `tauraroc render.tr
  --freestanding --emit c` (**no `@entry`, no `--emit-ld`** — confirmed unnecessary: a
  `pub export def` with no `@entry` anywhere in the program compiles and links fine standalone).
  Exports `tauraro_heap_init(base, size)` and `tauraro_ui_render(fb, width, height, pitch)`. Still
  needs `@allocator`/`@free`/`@realloc`/`@calloc` — `--freestanding` always defines
  `TAURARO_KERNEL`, which `#error`s at actual C-compile time (not at `--emit c` time) if those
  aren't supplied, regardless of `@entry`. Same proven copy+grow-in-place+no-shrink+no-zero-block
  allocator design as the Cortex-M tier (tau_bugs.txt #4), just parameterized on a pool pointer
  from `AllocatePool` instead of a hardcoded MMIO-adjacent SRAM address.
- `toolkit/render/uefi/gop.tr` — the third `Canvas` backend. The thinnest of the three: GOP's
  common `PixelBlueGreenRedReserved8BitPerColor` mode stores bytes `[B,G,R,reserved]`, which read
  as a little-endian 32-bit word is exactly `0x00RRGGBB` — the same packing `toolkit.types.rgb()`
  already produces, so a `Style` color writes straight into the framebuffer with zero conversion.
  (If a target ever reports the RGB-ordered variant instead, colors would need byte-swapping —
  not hit yet, not handled.)
- `scripts/build-uefi.ps1` — `tauraroc --freestanding --emit c`, then **one** `zig build-exe`
  invocation mixing the `.zig` stub and the generated `.c` files directly (`build-exe` accepts
  both; no separate object-file or linker step needed).
- `scripts/run-uefi.ps1` — boots it under QEMU + OVMF, with the `-serial file:`-style robustness
  already learned from the Cortex-M runner script.

### Two new bugs found getting here (full detail in `tau_bugs.txt` #12)

- zig's `x86_64-uefi` target legitimately predefines `_WIN32`/`_WIN64`/`_MSC_VER` (UEFI really
  does share the Microsoft x64 ABI and PE format), but `tauraro_rt.h` treats bare `_WIN32` as
  "real hosted Windows, `windows.h`/`psapi`/`bcrypt` are available" without checking
  `TAURARO_KERNEL` first, so freestanding UEFI builds fail with `'windows.h' file not found`
  unless those three macros are explicitly undefined at compile time
  (`-cflags -U_WIN32 -U_WIN64 -U_MSC_VER --` bracketed before the `.c` sources in the
  `zig build-exe` invocation — a bare top-level `-U_WIN32` is rejected by `build-exe`).
- `New-Object System.Drawing.Bitmap($w * $Scale, $h * $Scale)` — PowerShell's
  parenthesized-constructor shorthand for `New-Object` only reliably evaluates bare variables
  inside the parens, not expressions; use `-ArgumentList` explicitly instead. Not a Tauraro bug,
  but cost real time in `scripts/ppm-to-png.ps1`.
- (Also relearned, not new: `Start-Process -ArgumentList` with a PowerShell array does not
  reliably quote elements containing spaces in PS 5.1 — both the OVMF path and the ESP directory
  are typically under `C:\Program Files\...`. Build one pre-quoted string instead, same pattern
  `build-bare.ps1`/`build-uefi.ps1` already used for the C-compiler invocations.)

## Text rendering (Phase 6): DONE — real bitmap font on all three tiers (2026-09-03)

Real, legible text now renders on hosted, Cortex-M, and UEFI — replacing the old
one-block-per-character placeholder. The approach: **bake a TTF into a fixed bitmap glyph atlas
offline, ship only the resulting byte data.** Tauraro's stdlib has zero font/curve-rasterizer
support (confirmed by searching `std/`), and real TTF outlines are quadratic Beziers wanting
float/fixed-point scanline rasterization — a large, risky thing to write from scratch and get
right on freestanding targets that also have no filesystem to load a `.ttf` from at runtime. A
baked atlas turns "render text" into a lookup + blit: no curve math, no float dependency,
identical on all three tiers because it's just data.

- **Font source:** `tools/fonts/JetBrainsMono.ttf` (SIL OFL 1.1, license alongside it). No
  Python in this environment — baking uses `scripts/bake-font.ps1` and .NET's `System.Drawing`
  (GDI+): renders each glyph supersampled 4x with real antialiasing, then box-downsamples back
  to a crisp 1-bit-per-pixel 8x14 cell. Covers ASCII 32–126 (95 glyphs), emits
  `toolkit/text/font_data.tr` — 1330 bytes as one `List[u8]` literal (confirmed compiling fine
  at this size; no issue at this scale).
- **`toolkit/text/font.tr`** — the lookup: `Font.pixel_set(codepoint, col, row) -> bool`. An
  out-of-range codepoint or pixel returns `false` unconditionally (renders as blank space, never
  a crash) — text content is not trusted input.
- **`Canvas` interface gained a 4th method**, `set_pixel(x, y, color)` — a baked glyph is an
  irregular per-pixel pattern, `fill_rect` alone can't draw one. Deliberately NOT a
  `draw_glyph(codepoint, ...)` method: that would couple every backend to font lookup. All three
  backends (`BufferCanvas`, `FrameBuffer`, `GopCanvas`) implement it; `interp.paint_text` does
  the font lookup and calls `set_pixel` per foreground bit.
- **`toolkit.layout.flex`'s `glyph_w()`/`glyph_h()`** — previously hardcoded placeholders (6x10)
  — now delegate to the real baked font cell size (8x14), so layout automatically matches what
  gets painted with zero other changes.
- Interpreter now owns a `Font` (loaded once in `Interpreter.init()`), not passed around
  separately.

**A real, deep bug found and fixed getting here** (full detail in `tau_bugs.txt` #4's update):
`toolkit/render/bare/framebuffer.tr`'s `emit_ppm` allocated a FRESH `StringBuilder` per row and
never freed any of them (bump allocator) — on a bigger canvas with real text this accumulated
enough that a `StringBuilder` being grown was no longer the newest allocation, so the realloc
slow path's read ran past `_heap_next` into unmapped memory: a Cortex-M bus fault with no
handler installed, which presents as a silent hang with zero further UART output. Fixed by
reusing one `StringBuilder` via `.clear()` (resets length in place, no realloc) across all rows,
and by using `.as_str()` instead of `.to_string().as_str()` (the latter allocates a fresh copy
on every call).

**A second, NOT fully root-caused bug also found on the Cortex-M tier** (`tau_bugs.txt` #13):
certain specific packed RGB color values (amber `0xF59E0B`, violet `0x8B5CF6`), certain
same-row color combinations, and certain canvas widths (96 hangs, 88 does not, otherwise
identical) each independently trigger the same kind of silent hang — confirmed present hosted
NOT and on UEFI NOT (both render amber/violet correctly), so this is specific to
`--freestanding`/thumb-freestanding-eabi/cortex_m3. Worked around in `examples/bare_demo/` by
using only colors and a canvas width empirically confirmed to complete; the underlying mechanism
is still unknown and would need disassembly of the generated code to chase further.

## What's next, highest value first

1. **A real login-screen demo on UEFI** — the user's actual stated goal (they previously shipped
   a Rust DXE driver doing exactly this). `examples/uefi_demo/` now has real rendered text; a
   real screen wants text INPUT (a UEFI Simple Text Input / Simple Pointer protocol driving
   `Event`s through the existing `EventHandler` dispatch — the plumbing already exists
   end-to-end) and a text field widget.

2. **Per-frame arena reset (proposal 5.6).** The bump allocator never frees on any freestanding
   tier, so today's demos are strictly single-frame. Needed before any animation, redraw, or
   input-driven live-reload loop on bare metal or UEFI.

3. **Diffing (Phase 5)** — re-render currently repaints everything.
4. **Transport (Phase 8)** — hosted is a file read today; there is no watch loop and no UART path,
   and now also no "read the next UI file from an EFI System Partition" path for UEFI.

### Cortex-M/UART tier — kept working, no longer the priority

Still fully functional (`scripts/build-bare.ps1` / `scripts/run-bare.ps1`,
`examples/bare_demo/`) and worth keeping green as a regression check — it's the only tier that
exercises Tauraro's own generated boot glue (`@entry`/`--emit-ld`) — but no further investment
planned unless a real Cortex-M target becomes relevant again.
