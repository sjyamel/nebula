# Proposal (v2): A Declarative UI Toolkit in Tauraro, Interpreted at Runtime, for Bare-Metal / OS-Level Use

## 1. Goal

Build a UI toolkit for people writing their own operating systems in Tauraro — declarative
components, utility-class ("Tailwind-like") styling, rendering straight to a hardware
framebuffer with no OS underneath — where **UI content is data, evaluated at runtime by an
interpreter you ship inside the OS, not code the Tauraro compiler bakes into the binary.**
The payoff: changing a screen, a component, or a style doesn't mean rebuilding and reflashing
the kernel. You edit the UI description and reload it into the running interpreter.

This supersedes the compile-time-macro version of this proposal. Most of that plan survives —
the rasterizer, layout engine, renderer backend, font rendering, input handling, and the
bare-metal port are unchanged. What changes is the top of the stack: `classnames!(...)` as a
compile-time macro is replaced by a small **interpreter that resolves class strings and walks
a UI tree at runtime**, and a new concern enters the plan that didn't exist before — how new UI
content actually reaches a machine that has already booted.

---

## 2. Core strategy: build hosted, port down — and interpret, don't compile, the UI content

Two decisions compound here, and it's worth keeping them separate:

1. **Hosted-first, then bare-metal** (unchanged from v1). The toolkit's logic talks to a small
   `Canvas` backend trait; you implement that trait twice (an in-memory buffer for fast hosted
   iteration, a real MMIO framebuffer for bare metal) and everything above it is written once.

2. **Interpreted, not compiled, UI content** (new in this version). The widget tree and style
   classes are *data* your OS reads and an interpreter walks at runtime — not Tauraro source
   the compiler turns into machine code. This is what makes "don't wait for builds" literal:
   the interpreter and the renderer are the only things that need a full `tauraroc` rebuild;
   everything a UI author writes is loaded and re-evaluated without one.

The important scoping rule that keeps this tractable: **interpretation happens once per UI
tree/state change, never per pixel.** The rasterizer stays fully compiled, native Tauraro code
— you're building an interpreter for a UI description, not a general scripting VM for
arbitrary compute. That distinction is what keeps this fast enough to be worth doing.

---

## 3. Layered architecture

```
┌─────────────────────────────────────────────────────────┐
│  Your OS / demo shell                                    │
├─────────────────────────────────────────────────────────┤
│  UI description (data: files, or bytes over UART/disk)    │
├─────────────────────────────────────────────────────────┤
│  UI runtime — parser + AST + tree-walking interpreter      │
│      resolves classnames -> Style (cached), walks the      │
│      tree, calls back into host functions for events       │
├─────────────────────────────────────────────────────────┤
│  Widget library (Button, Panel, Text, List, ...)           │
│      — native Tauraro, what the interpreter targets        │
├─────────────────────────────────────────────────────────┤
│  Layout engine — simplified flexbox subset                │
├─────────────────────────────────────────────────────────┤
│  Rasterizer — fill_rect, blit, draw_glyph, alpha blend      │
│      (always native Tauraro — never interpreted)           │
├─────────────────────────────────────────────────────────┤
│  Renderer backend trait                                    │
│      ├─ Hosted impl: in-memory buffer (std tier)            │
│      └─ Bare-metal impl: MMIO framebuffer (core tier)       │
├─────────────────────────────────────────────────────────┤
│  Platform layer: boot, allocator, timer, input, transport   │
│      (transport = how UI data reaches a booted machine)     │
└─────────────────────────────────────────────────────────┘
```

The new layer, relative to v1, is "UI runtime" near the top and "transport" at the bottom —
everything in between is the same toolkit as before.

---

## 4. Phased roadmap

### Phase 0 — Spike (days, not weeks)
Three things to prove before investing further:
- A tagged-union `UiNode` AST (see §5.2) walked by a recursive interpreter, in Tauraro, on the
  `std` tier — confirm the pattern is as natural as it looks in the compiler's own `src/mir.tr`.
- Runtime class-string resolution with caching (§5.4) — confirm a `Map[str, Style]` cache makes
  repeated class strings effectively free after the first parse.
- The same bare-metal pixel-plot spike from v1: write raw color bytes to a fixed MMIO address
  under qemu, proving the renderer backend's bare-metal half is possible at all.

### Phase 1 — Hosted rendering core
Unchanged from v1: software rasterizer over an in-memory pixel buffer — `fill_rect`, `blit`,
`line`, alpha blending, a `Canvas` abstraction. Dump frames to PPM or a dev-only host window
binding for visibility during development.

### Phase 2 — UI description format + parser
Design a small textual (or simple binary) format for describing a screen: elements, class
strings, text content, and event-handler names. Write the parser that turns it into the
`UiNode` AST. Keep the format minimal at first — element + class + children + a handful of
attributes — the same discipline as v1's advice not to copy Tailwind's whole surface on day one.

### Phase 3 — The interpreter
The tree-walking evaluator: walks `UiNode`, resolves each class string via the cached style
table, produces/updates the native widget tree, and calls back into host Tauraro functions for
event handlers (§5.5). This is the phase where "declarative, interpreted at runtime" actually
exists as working code.

### Phase 4 — Layout engine
Unchanged from v1: simplified flexbox subset (row/column, gap, padding, grow/shrink, fixed vs.
auto sizing). Operates on the widget tree the interpreter produces — doesn't care whether that
tree came from a macro or an interpreter.

### Phase 5 — Re-render / diffing on state change
When the interpreter re-walks a tree (because the underlying data changed, or a new UI file was
reloaded), diff against the previous walk and only re-issue rasterizer calls for what changed —
same idea as v1's retained-mode diffing, just driven by the interpreter's output instead of a
compiled widget tree.

### Phase 6 — Text rendering
Unchanged from v1: fixed-width bitmap font first; TrueType/shaping explicitly deferred.

### Phase 7 — Input abstraction
Unchanged from v1: define the event type now, implement against host keyboard/mouse first via a
dev-only FFI binding, so hit-testing/focus/press-state logic in the interpreter and widget
library can be built and tested long before real input drivers exist.

### Phase 8 — Content delivery ("transport") — new in this version
This is the phase that makes "don't wait for builds" real, and it needs an explicit answer:
- **Hosted dev loop:** trivial — watch a file or a dev socket, re-run the interpreter on change.
- **Bare metal, early:** a UART-based transfer protocol. You already need UART for `@output`/
  debug logging, so this reuses infrastructure that exists anyway — push bytes over serial, the
  interpreter picks them up and re-evaluates. Good enough for active development on real hardware.
- **Bare metal, later:** a storage driver (virtio-blk under qemu is the easiest real target) plus
  a minimal read-only FAT32 reader, so UI content lives on a disk image instead of being pushed
  live every time. Neither of these exists in Tauraro today — this is a genuine addition to the
  gap list from before, not something the language or stdlib gives you.

### Phase 9 — Port the renderer to bare metal
Unchanged from v1: implement `Canvas` against a real MMIO framebuffer (Multiboot2/UEFI-GOP
address on x86, a display controller on ARM), using `@aligned`/`@packed` for pixel formats.

### Phase 10 — Bare-metal input drivers
Unchanged from v1: PS/2 keyboard first, wired into the same input event type from Phase 7. USB
HID remains a stretch goal.

### Phase 11 — Interrupts, timers, minimal scheduling
Unchanged from v1: none of this exists in Tauraro today. Scope to what the UI loop needs — a
periodic tick and servicing one interrupt (keyboard) — not a general scheduler.

### Phase 12 — Real allocator
Unchanged from v1: move off the bump allocator once widgets (and now, interpreted trees) are
actually being created and torn down at runtime. A free-list allocator is enough at this scale.

### Phase 13 — Reference demo
A "mini OS" shell built with the toolkit — but the definition of done now specifically includes
**editing a UI file and seeing the running, booted system update without a rebuild or reboot.**
That's the actual proof this version of the proposal delivers on its premise; a static demo that
happens to have been built this way isn't enough on its own.

---

## 5. Key technical designs

### 5.1 Renderer backend trait
Unchanged from v1:
```python
interface Canvas:
    def width(self) -> int
    def height(self) -> int
    def fill_rect(self, x: int, y: int, w: int, h: int, color: Color)
    def blit(self, x: int, y: int, src: Bitmap)
    def draw_glyph(self, x: int, y: int, glyph: Glyph, color: Color)
```

### 5.2 The `UiNode` AST — and why it's not a new pattern in this codebase
A tagged union, boxed for recursion, walked with `match` — exactly the shape of Tauraro's own
compiler IR. `src/mir.tr` defines `pub enum MirStmt: MDeclare(place: str, value: Pointer[HirExpr])
/ MAssign(...) / MEval(...)` and walks it with `match`/`case` throughout `src/sema.tr` and
`src/taumir/`. Your UI AST is the same idea one layer up:
```python
pub enum UiNode:
    Element(tag: str, class_str: str, attrs: Map[str, str], children: Vec[Pointer[UiNode]])
    Text(value: str)
    EventRef(name: str)   # references a host-registered handler by name
```
This is a proven pattern already load-bearing in the language's own toolchain, not a novel risk.

### 5.3 The interpreter loop
A recursive tree-walk is the natural first implementation — `interpret(node: Pointer[UiNode],
parent_style: Style) -> Widget`. On the `std` tier this is unremarkable. On bare metal, be
deliberate about stack depth: the example freestanding targets in this repo run with a stack of
a few KB, not the megabytes a hosted thread gets, so a pathologically deep UI tree recursing
through parse → interpret → layout is a real way to overflow it. Cap nesting depth, or convert
the walk to an explicit `Vec`-backed stack (push/pop children yourself instead of recursing) once
you're targeting real hardware — cheap to design in from the start, annoying to retrofit.

Don't reach for a bytecode VM for execution speed — a UI tree isn't a hot loop, and a stack
machine means hand-managing your own execution stack instead of using Tauraro's. The one place a
bytecode-*like* format earns its keep is Phase 8's transport: a compact binary encoding of the
`UiNode` tree is smaller and faster to parse over UART or off disk than raw text. If you go
there, it's a serialization format compiled off-device (or by a small on-device encoder), not a
general-purpose VM instruction set — worth keeping those two ideas distinct so "VM" doesn't
quietly grow into a much bigger project than the UI actually needs.

### 5.4 Runtime class-string resolution
Replaces the compile-time `classnames!` macro from v1 with a runtime lookup, cached by the raw
string so repeated class strings cost one hash lookup, not a re-parse:
```python
class StyleCache:
    pub cache: Map[str, Style]

extend StyleCache:
    pub def resolve(self, class_str: str) -> Style:
        if self.cache.contains(class_str):
            return self.cache.get(class_str)
        mut style = Style.default()
        for token in class_str.split(" "):
            apply_utility(style, token)   # same utility-token table as v1's macro design
        self.cache.set(class_str, style)
        return style
```
The utility-token table (`apply_utility`) is unchanged from v1's design — the only thing that
moved is *when* it runs: once per unique string, at runtime, instead of once per call site, at
compile time. Unlike the macro version, this also removes v1's biggest constraint: class strings
no longer have to be compile-time literals — a UI file can compute or template a class string,
and the cache still keeps it cheap after the first evaluation.

### 5.5 Host-function bridge
The interpreter needs to call real Tauraro code for anything that isn't pure data — event
handlers above all. Keep this bridge small and explicit: a `Map[str, def(Event) -> void]` (or
equivalent closure table) that UI content references by name (`EventRef("on_click_close")`), the
same relationship an embedded Lua or JS runtime has with its host application. Do not let UI
content call arbitrary host functions by name lookup with no allowlist — see §8's kernel-crash
risk.

### 5.6 Memory strategy
Unchanged from v1: an arena per frame or per interpreted-tree generation, reset each cycle,
rather than churning the general allocator on every re-render.

### 5.7 What NOT to build first
Skip, for v1: a bytecode VM, JIT compilation of any kind, CSS grid, absolute/fixed positioning,
animations/transitions, TrueType fonts, USB input, multi-window compositing, and a general
preemptive scheduler. None of these block proving the core idea — interpreted declarative tree +
cached runtime style resolution + bare-metal framebuffer + live reload — works at all.

---

## 6. What's free vs. what you're building (recap, updated)

| Layer | Tauraro gives you | You build |
|---|---|---|
| Boot | `@entry`, `--emit-ld`, reset trampoline | Bootloader (Multiboot2/UEFI stub) |
| Memory | Pluggable allocator hook, ARC, `Vec`/`Map` | The actual allocator (bump → free-list) |
| Hardware access | `std/hal/mmio.tr`, `@aligned`/`@packed`, `unsafe:` | Framebuffer driver, PS/2 driver, timer driver |
| Interrupts | `@interrupt`, `@naked` attributes | IDT/PIC/APIC/GIC setup, handler dispatch |
| UI content model | Enums/`match`/`Pointer[T]` (proven in `src/mir.tr`) | The AST, the parser, the interpreter itself |
| Style resolution | `Map`, string ops | The utility-token table + the cache |
| Concurrency | `Atomic[T]` (works bare-metal) | Any scheduler/event loop (Thread/Mutex are OS-only) |
| Content delivery | Nothing | UART transfer protocol, and later a storage + FAT32 driver |
| Math | Full `sin`/`cos`/`sqrt`/etc. in `std/math` | — (this one's genuinely free) |
| Rasterization | Nothing | Everything: fill, blit, blend, glyphs |
| Text | Nothing beyond a thin `std/unicode` | Bitmap font renderer (+ shaping, later) |

---

## 7. Suggested repo layout

```
toolkit/
  ui/
    ast.tr           UiNode, Value, parser
    interp.tr         tree-walking interpreter, host-function bridge
    style.tr          utility-token table, StyleCache
  layout/             flexbox-subset engine
  render/             Canvas trait, rasterizer primitives
  render/hosted/      in-memory buffer backend (dev loop)
  render/bare/        MMIO framebuffer backend
  widgets/            Text, Panel, Button, List, Image
  input/              event types + PS/2 driver (bare) + host binding (dev)
  transport/          UART push protocol (bare) + file/socket watch (hosted)
  platform/           boot glue, allocator, timer — thin, OS-specific
  examples/
    hosted_demo.tr        std tier, hot-reloads a UI file, dumps PPM per change
    bare_demo/             --freestanding, qemu-runnable, UART-pushed UI updates
```

---

## 8. Risks and open questions

- **A crash in the interpreter is a crash of the whole OS.** There's no process isolation at
  this level — a browser tab with a bad script dies without taking the browser down; a UI
  interpreter running in your kernel with no protection boundary does not have that luxury. The
  parser and interpreter need to be defensive by construction (reject malformed input, bound
  recursion depth, validate event-handler names against the allowlist in §5.5) rather than
  assuming well-formed input, especially once Phase 8 means content can arrive from outside the
  build process entirely.
- **Content delivery is a real new dependency, not a detail.** "Don't wait for builds" only
  works once Phase 8 exists — until then, bare-metal UI content is exactly as build-locked as
  v1's macro approach was. Decide early whether UART push or a disk-backed filesystem is the v1
  target; they want different input framing.
- **Stack depth on constrained targets** (§5.3) — a real constraint on the freestanding tier
  that doesn't exist hosted, worth designing around rather than discovering under qemu.
- **Single-threaded rasterization on bare metal**, unchanged from v1 — `std.gpu.Gpu` is
  OpenMP/hosted-only; `Simd[T; N]` is the fallback if blitting throughput matters.
- **No prior art in the language for drivers/interrupts/scheduling**, unchanged from v1 — every
  driver is written against raw hardware references, same as it would be in C or Rust.
- **Language is pre-0.1**, unchanged from v1 — pin a `tauraroc` tag and upgrade deliberately.

---

## 9. First milestone — definition of done

Ship when: a hosted demo loads a UI file, the interpreter parses it into a `UiNode` tree,
resolves its class strings through the cached style table, renders the result to PPM — **and**
editing that file and re-triggering the interpreter (no process restart) produces an updated
render, proving live reload actually works, not just that the interpreter runs once at startup.
Separately, a bare-metal demo boots under qemu, receives a UI update over UART, and re-renders to
a real MMIO framebuffer using the same `Canvas` trait and the same interpreter. That pair — one
hosted with file-based reload, one bare-metal with UART-based reload, both driving the same
interpreter and renderer code — is the actual proof that this version's premise (runtime,
build-independent UI) holds up, before investing in fonts, real input drivers, or interrupts.
