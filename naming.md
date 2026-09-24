# Renaming the primitives

Proposal, not a decision. Style: `hot/junk/babenko/claude/common/style.md` (function names start
with a verb describing what the function does; full words; `Get` aborts, `Find`/`TryGet` may
return null; be concise; mimic the surrounding codebase) and YT's own process vocabulary
(`TShellCommand::Run`, `TSubprocess::Execute` returning `Output`, `TProcessBase::Spawn`, `Kill`,
`Terminate`, `RunSubprocess`). The "surrounding codebase" for a `.litre.lua` is also Neovim's
Lua API (`vim.system`, `vim.ui.select`, `vim.ui.input`, `vim.keymap.set`), so mimicry pulls two
ways; the bundles at the end make that choice once instead of nine times.

Two rules applied throughout:

- A function that *does* something is a verb. A constructor of a value keeps the noun of what it
  builds (YT's types are `TSubprocess`, `TShellCommand`; a Lua constructor is `vim.system`,
  `Job:new`).
- The failure vocabulary stays in options and docs, not names: `run` raises on nonzero exit
  unless `check = false`, `pick`/`ask` return nil on cancel. YT would spell that `RunOrThrow`
  and `TryPick`; nine primitives typed in every task file cannot afford it.

## Per primitive

### `sh(c, opts)`

Runs a command, streams its output into the task buffer, returns the exit code.

| candidate | for                                       | against                              |
| --------- | ----------------------------------------- | ------------------------------------ |
| `run`     | the plain verb; YT `Run`, `RunSubprocess` | silent on where output goes          |
| `execute` | YT `TSubprocess::Execute`                 | YT's Execute captures: that is `out` |
| `spawn`   | YT `TProcessBase::Spawn`                  | Spawn returns a future; this waits   |
| `stream`  | names the distinguishing feature          | "stream a build" reads oddly         |
| `sh`      | terse, terminal habit                     | abbreviation; argv skips the shell   |
| `shell`   | full word                                 | same lie as `sh` for argv tables     |

### `out(c, opts)`

Runs silently, returns trimmed stdout and the exit code.

| candidate | for                                    | against                                |
| --------- | -------------------------------------- | -------------------------------------- |
| `capture` | verb; design.md's word for this colour | none                                   |
| `output`  | reads like `$()` at the call site      | noun; the guide would say `get_output` |
| `execute` | YT's `Execute` returns `Output`        | says nothing about silence             |
| `read`    | verb                                   | reads as file reading                  |
| `out`     | terse                                  | neither a verb nor a word              |

### `cmd(c, opts)`

A callable command value: `c()` captures, run as a task it streams.

| candidate | for                           | against                     |
| --------- | ----------------------------- | --------------------------- |
| `command` | full word; YT `TShellCommand` | none                        |
| `bind`    | YT's `BIND` makes a callable  | in Neovim "bind" means keys |
| `cmd`     | terse                         | abbreviation                |

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

| set | sh  | out     | cmd     | with | pick   | input | param     | debug | map |
| --- | --- | ------- | ------- | ---- | ------ | ----- | --------- | ----- | --- |
| A   | run | capture | command | with | pick   | ask   | parameter | debug | map |
| B   | run | capture | command | with | pick   | ask   | param     | debug | map |
| C   | run | output  | command | with | select | input | param     | debug | map |

Recommendation: **A**. It is what the guide says, and the only cost over B is `parameter`,
typed once per file at top level. B if that word annoys you at the call site. C only if you want
`.litre.lua` to read like the rest of your Neovim config; it pays with a noun (`output`) and a
name that collides with a Lua builtin (`select`).

The cmake snippet in A:

```lua
local l = require("litre")
local cm = require("litre.cmake")
local dir = "build"
local target = l.parameter("target", function() return cm.executables(dir) end)
local b = l.with { dir = dir }

function Build()
    b.run("cmake --build . --target " .. target)
end

function Run()
    Build()
    b.run("./" .. cm.executable_path(dir, target))
end
l.map("r", Run)
```

and a capture, in any set: `local rev = l.capture("git rev-parse --short HEAD")` (C:
`l.output(...)`).

Every set renames `sh`, `out`, `cmd` and nothing in the runner: the internal `runner.run` is not
the public `l.run`, they live in different modules. A task named `Run` next to `b.run` is fine
too, the case tells them apart, as in the snippet above.

## What a rename touches

`lib.lua` (functions, `litre.With` fields, annotations), `init.lua` (re-exports, header
comment), `cmake.lua` (calls `lib.sh`), the two specs and their fixtures, `readme.md`,
`design.md` (a new numbered entry), the config's four snippets, and the two live files under
`~/personal` once they are opened. Say the letter; the rest is mechanical.
