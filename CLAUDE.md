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
- `Dict[str, def(Event) -> void]` **works** — the proposal's §5.5 handler table is valid as
  designed. (The docs only ever confirm `Vec[...]`/`List[...]` of callables; `Dict` is fine too.)
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
toolkit/render/bare/    MMIO framebuffer backend (real hardware)
toolkit/widgets/      Text, Panel, Button, List, Image
toolkit/input/         event types + PS/2 driver (bare) + host binding (dev)
toolkit/transport/     UART push protocol (bare) + file/socket watch (hosted)
toolkit/platform/      boot glue, allocator, timer — thin, OS-specific
examples/hosted_demo/  std tier, loads + hot-reloads a UI file
examples/bare_demo/    --freestanding, qemu-runnable
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
toolkit/ui/parser.tr          indentation format -> UiNode
toolkit/render/canvas.tr      the Canvas interface (3 methods)
toolkit/render/hosted/buffer.tr  BufferCanvas + clipping + PPM
toolkit/layout/flex.tr        build/measure/place, row+col+gap+pad+grow
toolkit/ui/interp.tr          tree walk, painting, hit-test, handler allowlist
examples/hosted_demo/         main.tr + app.ui + app.reload.ui
```

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

## What's next, highest value first

1. **Install QEMU (needs an admin terminal), then run the shipped `mps2_pure` ELF.** This is the
   last unproven link in the bare-metal chain — the build side is already verified above.

2. **Port the toolkit core to `--freestanding` and dump the framebuffer over UART.** This is the
   highest-value next milestone and it needs **no display driver at all**: render into a RAM
   framebuffer exactly as `BufferCanvas` does, then stream the PPM out the UART sink, redirect
   qemu's `-nographic` stdout to a `.ppm`, and open it. That proves the entire stack — freestanding
   tier, pluggable allocator, parser, style cache, layout, interpreter, rasterizer — on real bare
   metal, while deferring the one genuinely large piece (a display driver) until it is the only
   thing left. Expect friction in two places: everything in `toolkit/` leans on heap types
   (`List`, `Dict`, `str`, `StringBuilder`), so a bump allocator that never frees will need a
   per-frame arena reset (proposal §5.6); and `int` is 64-bit, so a `List[int]` framebuffer costs
   8 bytes/pixel — prefer `List[u8]` with a palette, or a small resolution, for the first attempt.

3. **Only then decide the display path.** Ranked by effort: RISC-V `virt` + virtio-gpu keeps
   Tauraro's generated boot glue (`--target embedded-riscv64`) but needs a real virtqueue driver;
   ARM `versatilepb` + the PL110 LCD gives a trivially simple linear framebuffer but is ARMv5, so
   the Cortex-M `@entry` glue and generated linker script no longer fit. Step 2 will surface the
   memory and allocator realities that should decide this — don't pick before then.
4. **Text rendering (Phase 6).** `interp.paint_text` currently fills one block per non-space
   character on the real glyph advance. Layout and positioning are correct; only the glyph bitmaps
   are missing, so a fixed-width bitmap font drops in without touching layout.
5. **Diffing (Phase 5)** — re-render currently repaints everything.
6. **Transport (Phase 8)** — hosted is a file read today; there is no watch loop and no UART path.
