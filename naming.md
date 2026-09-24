# Renaming the primitives

Proposal, not a decision. Style: `hot/junk/babenko/claude/common/style.md` (function names start
with a verb describing what the function does; full words; `Get` aborts, `Find`/`TryGet` may
return null; be concise; mimic the surrounding codebase) and YT's own process vocabulary
(`TShellCommand::Run`, `TSubprocess::Execute` returning `Output`, `TProcessBase::Spawn`, `Kill`,
`Terminate`, `RunSubprocess`). The "surrounding codebase" for a `.litre.lua` is also Neovim's
Lua API (`vim.system`, `vim.ui.select`, `vim.ui.input`, `vim.keymap.set`), so mimicry pulls two
ways; the bundles at the end make that choice once instead of three times.

Two rules applied throughout:

- A function that *does* something is a verb. `with`, the one value constructor, keeps the name
  decided today.
- The failure vocabulary stays in options and docs, not names: `run` raises on nonzero exit
  unless `check = false`, `pick`/`ask` return nil on cancel. YT would spell that `RunOrThrow`
  and `TryPick`; the primitives typed in every task file cannot afford it.

## Per primitive

### `sh` / `out`

Decided (design.md 21): `command(c, opts):run()` and `:run("captured")`. Nothing left to name.

### `with(defaults)`

Decided today (design.md 19). Kept in every bundle below.

### `pick(items, opts)`

`vim.ui.select` through the coroutine; nil when cancelled.

| candidate  | for                                | against                              |
| ---------- | ---------------------------------- | ------------------------------------ |
| `pick`     | verb, short; Neovim's "pickers"    | none                                 |
| `select`   | mirrors `vim.ui.select` exactly    | Lua's `select(n, ...)`; SQL          |
| `choose`   | verb, plain                        | longer than `pick`, no gain          |
| `try_pick` | the guide's may-return-null prefix | nil on cancel is already Lua's idiom |

### `input(prompt)`

`vim.ui.input` through the coroutine; nil when cancelled.

| candidate | for                                     | against                      |
| --------- | --------------------------------------- | ---------------------------- |
| `ask`     | verb, short; pairs with `pick`          | not the Neovim word          |
| `prompt`  | verb and noun; `vim.fn.input` shows one | names the UI, not the result |
| `input`   | mirrors `vim.ui.input`                  | a noun in this position      |

### `param(name, options)`

Declares a persisted parameter at top level, returns its value.

| candidate   | for                            | against                                   |
| ----------- | ------------------------------ | ----------------------------------------- |
| `parameter` | full word; typed once per file | none                                      |
| `param`     | terse, universally read        | abbreviation, the guide's objection       |
| `option`    | short                          | Vim "option" = settings; arg is `options` |
| `setting`   | says persisted                 | vaguer than parameter                     |
| `declare`   | a verb                         | declare what?                             |

### `debug(template, overrides)`

Merges onto a dap template and `dap.run`s it.

| candidate | for                             | against                         |
| --------- | ------------------------------- | ------------------------------- |
| `debug`   | verb, says exactly what happens | none                            |
| `launch`  | dap's request name              | does not say "under a debugger" |
| `dap`     | the ecosystem name              | acronym, not a verb             |

### `map(key, fn)`

Gives a task a layer key.

| candidate | for                                   | against                  |
| --------- | ------------------------------------- | ------------------------ |
| `map`     | Vim's own verb (`:map`, `vim.keymap`) | none                     |
| `bind`    | generic                               | YT's `BIND` is callbacks |
| `key`     | short                                 | noun                     |

## Bundles

- **A, strict**: the guide as written, verbs and full words.
- **B, terse**: A with the one abbreviation everyone reads.
- **C, neovim mirror**: named after the API underneath each call.

| set | pick   | input | param     |
| --- | ------ | ----- | --------- |
| A   | pick   | ask   | parameter |
| B   | pick   | ask   | param     |
| C   | select | input | param     |

Recommendation: **A**. It is what the guide says, and the only cost over B is `parameter`,
typed once per file at top level. B if that word annoys you at the call site. C only if you want
`.litre.lua` to read like the rest of your Neovim config; it pays with a name that collides with
a Lua builtin (`select`).

The cmake snippet in A:

```lua
local l = require("litre")
local cm = require("litre.cmake")
local dir = "build"
local target = l.parameter("target", function() return cm.executables(dir) end)
local b = l.with { dir = dir }

function Build()
    b.command("cmake --build . --target " .. target):run()
end

function Run()
    Build()
    b.command("./" .. cm.executable_path(dir, target)):run()
end
l.map("r", Run)
```

## What a rename touches

`lib.lua` (functions, annotations), `init.lua` (re-exports, header comment), the two specs and
their fixtures, `readme.md`, `design.md` (a new numbered entry), the config's snippets, and the
two live files under `~/personal` once they are opened. Say the letter; the rest is mechanical.
