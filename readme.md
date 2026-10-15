# liter

An imperative task runner for Neovim. A `.liter.lua` file is a Lua
program: it requires liter like any module, its global functions are tasks
(Capitalized by convention), `local` means private, and anything expressible
in Lua needs no plugin changes. See `design.md` for the rationale and the
decision history.

```lua
-- .liter.lua
local l = require("liter")
local opt = l.parameter("optimization_level", { "-O2", "-O3", "-O0" })
local b = l.with { dir = "build" }

function Build()
    b.command("cmake --build . -- -j8"):run()
end

function Run()
    Build()
    b.command("./main " .. opt):run()
end

function Dbg()
    Build()
    l.debug("cpp", { program = "main", dir = "build" })
end
```

## Loading

All `.liter.lua` files from cwd upward are found (one stat per directory level,
never a recursive walk) and re-executed on every use -- params and edits are
always fresh. Files execute in sandboxed envs that nest: an inner file reads
outer globals through `__index`, its own globals stay separate. Task ids from
outer files carry the relative path: `Build` (cwd's file), `../Deploy`,
`../../Clean`. Tasks sort innermost first, so a bare name given to `:Liter`
resolves to the nearest one.

Tasks are Capitalized by convention: lua-ls's `lowercase-global` hint (its
"did you forget `local`?" heuristic) stays quiet, and the names read as
exported next to lowercase helpers. A lowercase task still runs.

## Primitives (`local l = require("liter")`)

| call | does |
| --- | --- |
| `l.command(c, opts?)` | a command value; runs nothing until `:run()` |
| `c:run()` | live: stream on a pty into the task's `liter://` buffer; returns exit code |
| `c:run("captured")` | captured: run on pipes, nothing shown; returns trimmed stdout (+ code) |
| `l.with { dir=, env= }` | defaults bundle: `b.command` with those opts merged in; `b.with { ... }` stacks |
| `l.pick(items, opts?)` | `vim.ui.select` through the task coroutine; returns the choice |
| `l.ask(prompt, opts?)` | `vim.ui.input` likewise; `opts` are its other options (`default`, ...) |
| `l.parameter(name, { ... })` | declare a param; returns its current value (top level only); a function list runs when the param is activated in the layer |
| `l.debug(template, overrides)` | merge overrides onto a `setup()` dap template, `dap.run` it |

The calls are annotated in `lib.lua`, so lua-ls gives hover, signature help
and completion on `l.` once it can see this checkout (lazydev adds it on the
`require`).

- `command` takes a **string** (runs via `<shell> -c`, default fish:
  pipes, `$VAR`, globs work) or an **argv table** (no shell, no quoting).
- `opts.dir` is relative to the defining `.liter.lua`'s directory, which is also
  the default. There is no `cd` -- directory is data on the command (the os/exec
  model), so no run mutates state outside itself.
- A command value is a plain table with public `cmd` and `opts`, so a helper can
  derive one from another (add env, wrap a retry) before anything runs.
- `opts.env` adds environment variables for that command.
- `b.with { ... }` returns a new bundle on top of `b`: the closer setting wins
  key by key (a stacked or per-call `dir` replaces, never appends), except
  `env`, whose variables accumulate.
- `opts.stdin` (string or list of lines) feeds the command's standard input --
  the anticipated-prompt pattern: `pick`/`ask` first, pass the
  answer here. A stdin-fed command runs on plain pipes instead of the pty (a
  pty cannot deliver EOF), so it sees no tty and prints no color.
- Nonzero exit **raises**: the task stops with a notification, so
  `Build(); Run()` is a correct chain. Opt out per command with
  `{ check = false }` to get the code back instead.
- Tasks run inside liter's coroutine runner; plain Lua helpers that call
  `:run()`/`l.pick()` need nothing special, but task functions are not callable
  from outside liter. Calling a primitive outside a task is an error, including
  at file top level -- top level is for definitions, shell work goes in tasks.
- A task already running is not started twice; different tasks run in
  parallel. `<C-c>` (normal mode) in a task's `liter://` buffer kills it: its
  current process gets SIGTERM and the task aborts with an
  "interrupted" notification; a second `<C-c>` SIGKILLs. A task waiting in
  `pick`/`ask` has no process -- cancel the prompt instead.
- Quitting nvim SIGTERMs every running task's process (vim.system children
  would otherwise outlive nvim -- measured), so `:restart` never leaks a
  build.

## Output buffers

A live `run` streams into a dead terminal buffer named
`liter://<task id>_<mm-dd-HH:MM:SS>` (the run's start; `-2`, `-3`, ... on a
same-second re-run) -- the command runs on a real pty sized to the window, with
stderr merged in, so programs see a tty on every fd and color and progress-bar
as in a terminal -- but no shell sits behind the buffer. Every run gets a
buffer of its own and earlier runs' buffers stay; windows showing the previous
run switch to the new one, otherwise it opens in the current window like any
buffer (no floats, no owned windows). Opening the buffer never leaves you in
terminal mode, even from another terminal (fzf's window) -- there is no stdin
to type into. Deleting the buffer mid-run is fine: the task's next live `run`
opens a fresh one. `<C-c>` in the buffer (normal mode) kills the running task,
as it would in a real terminal; in an earlier run's buffer it says that run has
finished. Programs that want stdin mid-run
should be anticipated with `pick`/`ask` in the task; genuinely interactive
work is what `:terminal` is for.

## Params

`l.parameter("name", { "a", "b" })` returns the persisted selection, defaulting to
the first option. Selections persist in `stdpath("data")/liter/parameters.json`,
keyed by file + name. The picker's "new value..." entry writes the new option
back into the `.liter.lua` source (treesitter finds the literal list; computed
lists are refused with a message). If the file is open in a buffer the edit
goes through the buffer -- unsaved changes survive -- and is written.

`l.parameter("name", function() ... end)` never runs the function at top level.
Activating that param in the layer runs it as a task of its own (`run`/`pick` work inside,
output streams to a `liter://` buffer as usual) and opens the value picker on
what it returns; no "new value..." entry. Until a value has been chosen once
the param reads `nil`. `require("liter.cmake")` is the ready-made case:
`cm.executables(build_dir)` lists a build dir's executable targets through
cmake's file API (configuring once to plant the query; any later re-configure
refreshes the reply), `cm.executable_path(build_dir, executable)` gives the
binary's path for `Run`/`Debug`. Both resolve `build_dir` like `command`'s
`opts.dir` and only work inside a task.

## Commands & layer

| command | does |
| --- | --- |
| `:Liter [task]` | run by id or bare name; no argument opens the picker |
| `:LiterConfig` | edit the innermost `.liter.lua` (path at cwd if none exists) |

Map a key to `require("liter").layer()`: it opens the fzf-pin picker over every
task (running ones marked), then every param as `name = value`. Activating a
task runs it; activating a param opens its value picker → "new value...".
Keys work inside the picker:

| key | does |
| --- | --- |
| pinned lowercase | activates the entry pinned to it |
| free lowercase | pins the highlighted entry to it (move with ctrl-n/ctrl-p first) |
| `ctrl-x` | unpins the highlighted entry |
| `C` | edit config |
| `O` | show the last task's output buffer in the current window |
| `R` | re-run the last task |
| `i` | fzf-pin's search key: unbinds the chars, type to filter, enter activates |

Pins are saved in fzf-pin's store, one file per cwd
(`stdpath("state")/fzf-pin/liter/<cwd>.json`): task ids are relative to cwd,
so a pin belongs to the directory it was made in. A pin whose task or param
no longer exists is simply not shown, and its key counts as free.

The picker opens even with no tasks discovered, so `C` can create the first
`.liter.lua`. The layer source is `require("liter").source` (an
[fzf-pin](../fzf-pin.nvim) source; that repo's readme has the contract).

## Setup

```lua
require("liter").setup({
    shell = "fish",              -- for string commands
    dap_templates = {
        cpp = { type = "gdb", request = "launch" },   -- table: merged with overrides
        -- name = function(overrides) return cfg end, -- or built per call
    },
})
```

`l.debug("cpp", { program = "main", dir = "build" })` resolves a relative
`program` against the task's directory (+ `dir`), defaults `cwd` to the same,
and calls `require("dap").run`. Adapters and machine quirks stay in the nvim
config; `.liter.lua` files only name a template.

## Verifying

`tests/run.sh` -- lua-language-server (baseline: zero problems) + an offline
end-to-end spec on `nvim --clean`. A PostToolUse hook runs it on every Lua
edit. `nvim --clean -l` is the Lua runtime here; there is no standalone lua.
