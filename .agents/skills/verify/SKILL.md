---
name: verify
description: Verify a liter change actually works — the offline suite always, plus the interactive checks that need a real UI (layer keys, pickers, terminal windows, dap).
---

# Verifying liter

## Tier 1 — offline, always run this

```bash
tests/run.sh          # lua-language-server (baseline: 0 problems) + spec
tests/run.sh spec     # just the spec
```

The spec is end-to-end on `nvim --clean`: it builds a temp tree of nested
`.liter.lua` files and drives discovery (nesting, prefixes, locals),
the layer's pins, the runner (both shell colors, streaming into `liter://` buffers, a buffer
per run, error semantics both ways), params (state persistence
and treesitter write-back: single-line, multiline, through a dirty buffer,
computed-list refusal) and the dap merge against a stubbed `dap.run`.
A PostToolUse hook runs the whole suite on every Lua edit. There is no
standalone lua on this box; `nvim --clean -l` is the runtime.

## Tier 2 — needs a human in a real UI

The spec cannot press keys or see windows. After changes to these, check by
hand in a real nvim with the config loaded:

- **the layer**: `x` picker, a param's value flow (fzf-lua renders it),
  pinning the highlighted entry with a free key and `x<key>` on it,
  `xO`/`xR`; Esc closes the picker.
- **terminal mode**: opening a `liter://` buffer from another terminal
  (`s`'s fzf window) lands in normal mode -- the spec cannot see modes.
- **window placement**: output buffer takes the current window when hidden,
  stays put when visible in a split; autoscroll while streaming.
- **`debug()`**: needs the real gdb adapter from the nvim config
  (`plugins/dap.lua`) and a real binary -- the spec only checks the merge.
- **`liter.cmake`**: the spec feeds it a hand-written file-API reply; the
  first-call configure and a real reply need a real cmake build directory.

A quick real-UI smoke: `cd` to a dir with a `.liter.lua`, `:Liter`, watch the
buffer stream. As of 2026-07-19 the whole v2 surface is spec-tested but has
never been battle-tested in an interactive session.
