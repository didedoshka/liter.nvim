# litre -- session rules

Imperative task runner for Neovim; personal project, single user, loaded from
this checkout via lazy.nvim (`~/.config/nvim/lua/plugins/litre.lua`).

- **`readme.md` is the spec** -- it documents shipped behaviour precisely and
  any behaviour change is incomplete until it matches.
- **`design.md` is the decision record** -- v1 post-mortem, settled choices,
  provisional calls awaiting battle-testing, open forks. Update it when a
  decision lands or is reversed; don't re-derive what it already answers.

## Layout

`lua/litre/`: `init.lua` public surface (commands + layer; read first),
`discover.lua` file walk + sandboxed envs, `runner.lua` coroutine runner,
`lib.lua` the .litre.lua primitives, `term.lua` `litre://` output buffers,
`params.lua` treesitter write-back, `state.lua` persisted selections,
`config.lua` opts (read `config.opts` at call time), `cmake.lua` `:LitreCmake`.

## Invariants

- Tasks only run through `runner.run`; primitives find their task via
  `runner.current`, pinned by `runner.resume`. Never resume a task coroutine
  directly.
- No owned windows, no floats. Output is a `litre://` buffer replaced in place
  on re-run; failures are a single `vim.notify`, never a traceback.
- Discovery stats exact paths upward only -- **never anything recursive**
  (arc-mount rules, see the global CLAUDE.md; a hook enforces it).
- `.litre.lua` files re-execute on every load; nothing may cache their contents.

## Verify

`tests/run.sh` (offline, ~1s): lua-language-server --check from the repo root
(baseline **0 problems**) + end-to-end spec on `nvim --clean`. The PostToolUse
hook runs it on every Lua edit. `nvim --clean -l` is the only Lua runtime on
this box. lua-ls does not catch cross-module breakage; only the spec does.

## Style

4-space indent, double quotes, ~100 cols; formatting via lua_ls/EmmyLuaCodeStyle
from `.luarc.json` -- no stylua. Comments explain *why*, never the next line.
Commit each verified change (suite green) without asking. Never rewrite
history -- no amend, rebase, or reset past a commit; fix forward with a new
commit, so nothing is ever lost.
