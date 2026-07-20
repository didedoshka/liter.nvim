# litre

An imperative task runner for Neovim. A `.litre.lua` file is a Lua
program: its global functions are tasks, `local` means private, and anything
expressible in Lua needs no plugin changes. See `design.md` for the rationale
and the decision history.

```lua
-- .litre.lua
local opt = param("optimization_level", { "-O2", "-O3", "-O0" })
local b = env { dir = "build" }

function build()
    b.sh("cmake --build . -- -j8")
end

function run()
    build()
    b.sh("./main " .. opt)
end
map("r", run)

function dbg()
    build()
    debug("cpp", { program = "main", dir = "build" })
end
```

## Loading

All `.litre.lua` files from cwd upward are found (one stat per directory level,
never a recursive walk) and re-executed on every use -- params and edits are
always fresh. Files execute in sandboxed envs that nest: an inner file reads
outer globals through `__index`, its own globals stay separate. Task ids from
outer files carry the relative path: `build` (cwd's file), `../deploy`,
`../../clean`. Tasks sort innermost first, so a bare name given to `:Litre`
resolves to the nearest one.

## Primitives (globals inside .litre.lua)

| call | does |
| --- | --- |
| `sh(cmd, opts?)` | stream into the task's `litre://` buffer; returns exit code |
| `out(cmd, opts?)` | capture silently; returns trimmed stdout (+ code) |
| `cmd(c, opts?)` | callable value: `c()` captures like `out`; invoked as a task it streams |
| `env { dir=, env= }` | defaults bundle: `b.sh`/`b.out`/`b.cmd` with those opts merged in |
| `pick(items, opts?)` | `vim.ui.select` through the task coroutine; returns the choice |
| `input(prompt_or_opts)` | `vim.ui.input` likewise |
| `param(name, { ... })` | declare a param; returns its current value (top level only) |
| `debug(template, overrides)` | merge overrides onto a `setup()` dap template, `dap.run` it |
| `map(key, fn)` | give a global task a layer key (top level only) |

- `cmd`/`sh`/`out` take a **string** (runs via `<shell> -c`, default fish:
  pipes, `$VAR`, globs work) or an **argv table** (no shell, no quoting).
- `opts.dir` is relative to the defining `.litre.lua`'s directory, which is also
  the default. There is no `cd` -- directory is data on the call (the os/exec
  model), so no call mutates state outside itself.
- `opts.env` adds environment variables for that command.
- `opts.stdin` (string or list of lines) feeds the command's standard input --
  the anticipated-prompt pattern: ask with `pick`/`input` first, pass the
  answer here.
- Nonzero exit **raises**: the task stops with a notification, so
  `build(); run()` is a correct chain. Opt out per call with
  `{ check = false }` to get the code back instead.
- Tasks run inside litre's coroutine runner; plain Lua helpers that call
  `sh()`/`pick()` need nothing special, but task functions are not callable
  from outside litre. Calling a primitive outside a task is an error, including
  at file top level -- top level is for definitions, shell work goes in tasks.
- A task already running is not started twice; different tasks run in
  parallel. The layer's `k` kills a running task: its current `sh`/`out`
  process gets SIGTERM and the task aborts with an "interrupted" notification.
  A task waiting in `pick`/`input` has no process -- cancel the prompt
  instead.
- Quitting nvim SIGTERMs every running task's process (vim.system children
  would otherwise outlive nvim -- measured), so `:restart` never leaks a
  build.

## Output buffers

`sh` streams into a dead terminal buffer named `litre://<task id>` -- a pty job
renders colors and progress, but no shell sits behind it. Re-running a task
replaces the buffer under the same name; windows showing the old run switch to
the new one, otherwise it opens in the current window like any buffer (no
floats, no owned windows). Programs that want stdin mid-run should be
anticipated with `pick`/`input` in the task; genuinely interactive work is
what `:terminal` is for.

## Params

`param("name", { "a", "b" })` returns the persisted selection, defaulting to
the first option. Selections persist in `stdpath("data")/litre/params.json`,
keyed by file + name. The picker's "new value..." entry writes the new option
back into the `.litre.lua` source (treesitter finds the literal list; computed
lists are refused with a message). If the file is open in a buffer the edit
goes through the buffer -- unsaved changes survive -- and is written.

## Commands & layer

| command | does |
| --- | --- |
| `:Litre [task]` | run by id or bare name; no argument opens the picker |
| `:LitreConfig` | edit the innermost `.litre.lua` (path at cwd if none exists) |
| `:LitreCmake <dir>` | generate build/run/debug tasks from cmake's target list |

Map a key to `require("litre").layer()`. Layer verbs (reserved; `map()` to them
warns and is ignored):

| key | does |
| --- | --- |
| `x` | task picker (mapped keys shown as `[k]`, running tasks marked) |
| `v` | param picker → value picker → "new value..." |
| `c` | edit config |
| `o` | show the last task's output buffer in the current window |
| `r` | re-run the last task |
| `k` | kill a running task (picker when several run; `k` again SIGKILLs) |
| anything else | the task `map()`ped to it |

## Setup

```lua
require("litre").setup({
    shell = "fish",              -- for string commands
    dap_templates = {
        cpp = { type = "gdb", request = "launch" },   -- table: merged with overrides
        -- name = function(overrides) return cfg end, -- or built per call
    },
})
```

`debug("cpp", { program = "main", dir = "build" })` resolves a relative
`program` against the task's directory (+ `dir`), defaults `cwd` to the same,
and calls `require("dap").run`. Adapters and machine quirks stay in the nvim
config; `.litre.lua` files only name a template.

## Verifying

`tests/run.sh` -- lua-language-server (baseline: zero problems) + an offline
end-to-end spec on `nvim --clean`. A PostToolUse hook runs it on every Lua
edit. `nvim --clean -l` is the Lua runtime here; there is no standalone lua.
