# Tauraro UI Toolkit

A declarative, Tailwind-style UI toolkit for the [Tauraro](https://github.com/tauraro/tauraro)
language, aimed at people building their own operating systems in Tauraro — bring your own
kernel, get a UI layer almost for free.

**Start here:** `CLAUDE.md` (project context, verified language facts, gotchas) and
`docs/proposal/proposal-v2-runtime-interpreter.md` (the actual architecture and phased plan).

## What's in this scaffold

- `docs/proposal/` — the design proposal this project is built from.
- `docs/tauraro-lang-reference/` — a copy of the upstream Tauraro language/stdlib/dev docs, for
  offline reference.
- `vendor/tauraroc/` — a working `tauraroc` binary (Linux x64, built from upstream's own
  bootstrap tree) plus the `runtime/` headers it needs. Verify against a current release before
  relying on it for real work — see `CLAUDE.md`.
- `verified-examples/` — small `.tr` programs actually compiled and run against the vendored
  compiler in the session this scaffold was generated from. Not toy filler — these are the
  confirmed-working shape of the patterns the toolkit design depends on (a boxed recursive enum
  walked with `match`, a `Dict`-backed cache class).
- `toolkit/`, `examples/` — empty scaffold matching the proposal's suggested repo layout.

## Running the demo

The installed Windows SDK (`tauraroc v0.0.8`) is on PATH. **Run from the repository root** so
that `toolkit.*` module paths resolve:

```sh
tauraroc --run examples/hosted_demo/main.tr
```

This loads `examples/hosted_demo/app.ui`, parses it into a `UiNode` tree, resolves its class
strings through the cached style table, lays it out, paints it to a `Canvas`, and writes
`out_1.ppm` — then renders `app.reload.ui` through the *same live interpreter* to `out_2.ppm`,
with no rebuild and no restart. It also dispatches synthetic clicks to show the handler
allowlist accepting hits on buttons and rejecting everything else.

The `vendor/tauraroc/` binary is a Linux ELF and does **not** run on Windows; it is kept for
provenance only. See `CLAUDE.md`.
