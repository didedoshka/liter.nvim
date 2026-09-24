# litre v2 — design

Status: implemented (2026-07-20). Written as the 2026-07-19 brainstorm; the
sections below record the decisions and still-open forks from the redesign
discussion, and "v2 implementation decisions" records how each landed in code.

Renamed from `brd` (build-run-debug) on 2026-07-20: v2 is a general task
runner, so the old expansion described something it no longer is. `litre` is
just the word — it does not stand for anything. Names below that only ever
existed under the old name (`brd.fish`) are left as they were.

## Why v2

v1's flaw: half declarative, half imperative. It defined a task *format*
(`return { target = { dir, build, run, debug } }`), so every new capability —
chains, variables, conditionals — required a change to the engine, like VS
Code's `${...}` variables all have to be implemented by VS Code. Unmaintainable.

v2 is fully imperative: a `.litre.lua` file is a Lua program, tasks are Lua
functions, and anything expressible in Lua needs zero plugin changes. The
plugin shrinks to four things:

1. discovery/loading of `.litre.lua` files,
2. a small stdlib of primitives for running commands,
3. param persistence + selection UI,
4. the surface: picker, `x`-layer keymaps, output buffers.

Two v1 pains from ideas.md dissolve for free: command chains become plain Lua
(`if build() == 0 then run() end` — or just `build(); run()` depending on the
error-semantics fork below), and variables become params.

## Workflow context: nvim as tmux

Decided in parallel (full research: nvim config `notes/nvim-as-tmux.md`): the
workflow centers on nvim replacing tmux — headless `nvim --listen` servers per
project on the dev box, `--remote-ui` clients attached through ssh, `:detach` /
`:connect` / `:restart` (all present in the installed 0.13.0-dev build).
Consequences for litre:

- **fish support is dropped** (decided). No `brd.fish`, no config helper, no
  headless-runner compromise. nvim is always the host; everything litre does is
  server-side and survives ssh churn automatically.
- **Terminals must be disposable.** `:restart` (the config-update path) kills
  terminal buffers. That is only painless if anything worth keeping ran as a
  re-runnable litre task. litre tasks being cheap to re-run is therefore a hard
  requirement, not a nicety.
- Genuinely long-lived processes that must survive even a server crash go to
  `systemd-run --user` (crontab is forbidden on this box), not a terminal
  buffer. litre doesn't own that problem.

## Alternatives considered (and why not)

- **vim-dispatch** (was in ideas.md): async `:Make`/quickfix circa 2014.
  Vimscript, compiler-centric, no project task files, no params, no dap. Off.
- **overseer.nvim**: closest functional match — imperative Lua `builder()`
  templates, params, dap integration. Fails the philosophy: task-list windows,
  floats, big abstraction surface (strategies, components), params prompt
  per-run instead of persisting. Worth reading for its param model only.
- **neovim-tasks (Shatur)**: small, and it *persists per-project params to
  disk* — precedent for req. 5. But built on per-buildsystem declarative
  modules, the exact trap v1 fell into.
- **just / Taskfile / make + thin runner**: fully imperative, ancestor-search
  discovery, and shell-callable for free. Lost when fish support was dropped:
  params have no selection/persistence story, string manipulation is shell not
  Lua, and a dap config table cannot be built in a Justfile.
- **core exrc**: nvim 0.11+ loads `.nvim.lua` from cwd *and ancestors* with a
  `vim.secure.read` trust prompt — requirement 1 nearly exists in core. litre
  walks `vim.fs.parents` itself (needs control over env/merging), but the trust
  machinery is there if ever wanted; see Discovery.
- **Command-running libraries** (plenary.job, nvim-nio): not needed.
  `vim.system` + the 8-line coroutine pattern already proven in v1
  (`co_select`, `run_co`) is the whole async story.

## Core model

### Tasks = globals in a sandboxed env (decided)

Each `.litre.lua` is executed with `load(..., env)` where `env` is a fresh table
(falling back to `_G` via `__index`; the primitives come from
`require("litre")`, decision 17). Every top-level
`function foo()` lands in that table; every **callable** value in the env is a
task. `local` = private helper, invisible to the picker — which matches the
existing habit of marking non-exported functions `local` (lua-ls already
enforces it). Callable tables (results of `cmd`-style constructors) count as
tasks too, via `__call` detection. Enumeration is `pairs(env)` own-keys only,
so inherited outer-file tasks are not double-listed.

The rejected alternatives: `return {}`-table (a vestige of the declarative
format, metadata turns it back into config) and explicit `litre.task(...)`
registration (ceremony per task).

### Execution: tasks only run inside litre's coroutine runner (decided)

Every task invocation goes through `run_co`-style `coroutine.resume`. Any
primitive that waits (`sh`, `pick`, `input`) yields internally and is resumed
by the event loop. Function color exists but is invisible: a plain Lua helper
calling `sh()` needs no annotation, the yield propagates. The one rule bought
with this: task functions are not callable from outside litre (no autocmds
calling them directly). Accepted.

`bar = "echo hehe"` called as `bar()` — a string being callable — is
impossible in clean Lua. (`debug.setmetatable` could attach `__call` to the
string type globally; it works and was rejected: global to the whole runtime,
unsandboxable, opposite of "every line understandable".) The cost of staying
clean is one word: `bar = cmd "echo hehe"` returns a callable, and Lua's
paren-less string-literal call sugar keeps it close to the ideal syntax.

## Discovery & merging (decided)

- All `.litre.lua` files up the tree are loaded; the file is **re-executed on
  every invocation** (v1 already did this; performance negligible). So params
  and any computed values are always fresh — "when is a param read" resolves
  itself.
- Task names are **prefixed with the relative path** of their `.litre.lua`, so
  files up the tree coexist in one picker without shadowing rules.
- **Inner files see outer env**: the outer file's env is the inner env's
  `__index` fallback. Shared helpers and variables defined at the repo root are
  usable in subdirectory files.
- No trust prompt: `.litre.lua` is a private convention nobody targets; attack
  surface accepted as negligible (a decided position, not an oversight).
  `vim.secure.read` remains available if that ever changes.
- Open (small): the reference point — "up the tree from where nvim was
  launched" vs current cwd/`tcd`. With per-project servers the two nearly
  coincide; leaning cwd since a long-lived server may outlive its launch
  directory context.
- Environment note: the ancestor walk stats one exact path per level — allowed
  under the arc-mount rules; it must never grow into anything recursive.

## Primitives (the os/exec model — partially decided)

Go's `os/exec` is the inspiration and it answers the state problem: **there is
no ambient shell state**. No `cd` primitive — each command is a value carrying
its own `dir`/`env`, and running it mutates nothing outside itself:

```lua
sh("cmake --build .", { dir = "build" })
-- shared settings without a mutable cwd:
local b = litre.env { dir = "build" }    -- immutable bundle
b.sh("cmake --build .")
```

Default `dir` = the directory of the `.litre.lua` defining the task.

Two colors of shell call (they cannot be one primitive):

- **stream**: output into the visible task buffer, returns exit code — what
  "compile and run" wants;
- **capture**: silent `vim.system`, returns stdout — what
  `foo() .. bar()`-style composition wants (`$()` analogue).

### Open forks (the next discussion; these decide what every `.litre.lua` reads like)

1. **Shell string vs argv.** Go takes argv arrays (no quoting bugs, no pipes /
   `$VAR` / globs); v1 built `fish -c` strings (pipes free, quoting hell).
   Common compromise: string → run through shell, table → direct argv. Note the
   `cmd "echo hehe"` sugar only exists in string form.
2. **Error semantics: `set -e` or Go-explicit.** Either primitives raise on
   nonzero (task aborts, litre notifies; `build(); run()` just works) or they
   return the code and callers check (`if build() ~= 0 then return end` —
   explicit, but every chain grows an `if`). A `sh`/`try_sh` hybrid is function
   color in miniature. Undecided.
3. **What does `()` on a `cmd` value do?** Proposal: `()` = capture (so
   composition reads naturally), while the *runner* streams when the same
   callable is invoked as a top-level task from the picker. Same value, two
   context-dependent behaviors — one-sentence rule, but possibly clever-bad.
   Undecided.
4. **Concurrency** (goroutine-style spawn/wait for parallel builds): parked.
   The coroutine runner can grow it later without redesign; not a day-one need.

## Params (decided, details open)

```lua
local opt = litre.param("optimization_level", { "-O3", "-O2", "-O0" })
```

- Declaration is an imperative call; returns the current value directly (fresh
  on every load, since files re-execute).
- **Persistence: `stdpath("data")`**, keyed by (config-file path, param name).
  Not a sidecar file — nothing to gitignore.
- **New option values write back into `.litre.lua` source** (decided — the file
  stays the single source of truth for the option list; state file holds only
  the current selection). Mechanism: treesitter finds the `litre.param` call's
  options table and appends a string literal. Constraint accepted: write-back
  works only on *literal* option lists, impossible in general once computed.
- The loaded-in-vim conflict has one rule: **buffer wins**. If a buffer for
  that `.litre.lua` exists, apply the edit via `nvim_buf_set_text` and write it
  (buffer may hold unsaved changes the disk doesn't); otherwise edit the disk
  file directly.
- Open: default value when nothing persisted (first element?); whether the
  `x`-layer flow is one action (pick param → pick value, with a "new…" entry
  that prompts and writes back) or separate set-value / add-option actions.

## dap (direction decided, home undecided)

Fully imperative, a debug task is just a task ending in `dap.run(cfg)` — litre
need own nothing. But "cpp binary gdb" boilerplate in every `.litre.lua` is
stupid, and the machine-specific base genuinely cannot live in project files
(system gdb + sourced arc pretty-printers — the ya-gdb-segfault history).
Middle ground: **name + overrides**. The base config is registered once
machine-side; `.litre.lua` supplies only what varies:

```lua
function debug_main()
    build()
    litre.debug("cpp", { program = "./build/main", args = { "--fast" } })
end
```

`litre.debug` merges overrides onto the named base and calls `dap.run`. Coupling
shrinks to template *names*. Open: does the registry live in litre
(`setup{ dap_templates = ... }`) or as a plain module in the nvim config that
`.litre.lua` calls? Rejected extreme: merging onto `dap.configurations.cpp[1]`
by hand in every task — zero litre surface but the boilerplate metastasizes.

## Output: dead terminal buffers, no owned window (decided)

- v1's floating terminal is contrary to the philosophy and is gone. No owned
  window at all: task output is a **buffer like any other** (the oil.nvim
  principle) — open it in whatever window, split, or tab.
- Named `litre://task/<name>` and **reused per task** (the arc-nvim scratch
  convention), so re-running refreshes in place instead of piling duplicates.
- **Dead terminal** (job output, not a live shell): a pty'd job streaming into
  the buffer keeps colors and progress bars rendering, while exit codes come
  from the job — none of v1's fragility (keystrokes into a live fish, OSC 133
  `TermRequest` parsing, the `^C` interruption hack). Dead matches the task
  model: tasks are re-runnable programs, not shell sessions.
- **Input is still possible**, two anticipated kinds:
  1. *task-asks-you*: `pick(...)` / `input(...)` primitives via
     `vim.ui.select/input` through the coroutine (v1's `co_select`, proven);
  2. *program-asks-on-stdin*: the primitive keeps a stdin handle; a task can
     prompt in Lua and write the answer to the process.
  What a dead terminal cannot do is **unanticipated** interactivity (surprise
  password prompt). The escape hatch is not a litre feature: `:terminal` already
  is the live terminal, native, zero litre code. Boundary position (leaning
  accepted): a task that needs surprise interaction should have prompted in
  Lua; truly interactive work is `:terminal` by hand.

## Picker & keymaps (partially decided)

- Selection via fzf-lua over the discovered task list (path-prefixed names).
- **`x` is the layer leader** — free per the layer-key inventory in ideas.md,
  joining `<bs>` (debugmaster) and `s` (arrow) as layers. v1's fixed
  `<bs>s`/`<bs>x`/`<bs>p` (select / compile+run / compile+debug) workflow was
  not extensible — constant target-switching; per-task shortcuts replace it.
- Keys are assigned in `.litre.lua` itself (`map("c", build)`, per-project, next
  to the definition); verbs are `V/C/O/R` (lowercase with v2, uppercase since
  2026-09-24, see decision 16; `k` was a verb until 2026-08-12, see decision 15).
- Discoverability (decided 2026-08-06): the blind `getcharstr` layer is gone.
  `x` opens fzf-pin's picker (shared machinery, `~/personal/fzf-pin.nvim`) with
  every task listed and the map()ped chars live as binds — same keystrokes as
  before, but the state is visible. `i` is reserved on top of the verbs: it is
  fzf-pin's enter-search key. litre gained fzf-lua/fzf-pin as runtime deps of
  `layer()`; everything else still runs without them.

## v1 inventory — what carries over

| v1 piece | fate |
| --- | --- |
| `co_select` / `run_co` coroutine pattern | **keep** — it is the async story |
| OSC 133 `TermRequest` exit-code parsing | superseded by dead-terminal jobs |
| live fish terminal + `^C` interrupt hack | dropped with live terminals |
| float terminal (`terminal/float.lua`) | dropped (philosophy) |
| `_target` selection (`choose_target`) | gone — tasks are called directly |
| declarative `{ dir, build, run, debug }` format | gone — that's the point |
| `LitreCmake` target generator | undecided — regenerate as task-emitting Lua? |
| `LitreConfig` (open nearest config) | keep as an `x`-layer verb, trivially |
| `fish/` (brd.fish, config helper) | dropped (no fish support) |

## Requirements → status

1. all `.litre.lua` up the tree — decided (walk + re-execute + nested envs)
2. utilities to run commands — decided in shape (os/exec model), forks open
3. call-as-function syntax — resolved via `cmd` wrapper + runner (string-call
   is impossible in Lua; color solved by the coroutine runner)
4. picker + `x` layer + shortcuts — decided in shape, key-assignment open
5. params: select, persist, write back — decided, small details open
6. dap — direction decided (name + overrides), registry home open
7. no float, embedded nicely — decided (dead terminal buffers, no owned window)
8. (emergent) re-runnable tasks so `:restart` stays cheap — hard requirement

## Open questions, ranked

1. Primitives: shell string vs argv; error semantics; `()` = capture with
   runner-streams-tasks rule. *(Every `.litre.lua` ever written is made of
   these.)*
2. dap template registry: litre `setup` opt vs plain nvim-config module.
3. Key assignment: in `.litre.lua` vs nvim config; fixed layer verbs.
4. Param UX details: default value, one flow or two.
5. Discovery reference point: launch dir vs cwd.
6. `LitreCmake` successor.
7. Concurrency primitives (parked deliberately).

## v2 implementation decisions (2026-07-19 -- provisional, veto freely)

The first implementation landed with the user asleep; every open fork above
got a call, recorded here. `readme.md` documents the resulting behaviour;
tests cover all of it (`tests/run.sh`, 24 cases).

1. **String AND argv** (fork 1): a string command runs `<shell> -c` (shell =
   `setup{ shell }`, default fish -- it is the only shell in this workflow);
   an argv table spawns directly. One rule, both worlds; the `cmd "..."`
   sugar exists only for strings, as predicted.
2. **set -e semantics** (fork 2): `sh`/`out` raise on nonzero exit -- the
   runner turns it into a single vim.notify, no traceback -- so chains are
   `build(); run()`. Per-call `{ check = false }` returns the code instead
   (Python subprocess convention). Chose the clean happy path over Go-style
   explicitness: a per-call opt is not function color, and the two-line task
   was the whole point.
3. **`()` = capture, runner streams** (fork 3): implemented exactly as
   proposed; the one-sentence rule survived contact with the code
   (`runner.run` special-cases cmd values via `lib.as_cmd`).
4. **Concurrency** (fork 4): stayed parked. Different tasks may run in
   parallel (each owns its buffer); the same task is refused while running.
5. **Key assignment in `.litre.lua`** (open q. 3): `map(key, fn)` next to the
   definition; discovery reverse-looks-up the function's global name, warns
   and skips if the target is local. Layer verbs fixed as x/v/c/o/r
   (picker/params/config/output/re-run); map() onto a reserved key warns and
   is ignored. Innermost file wins key collisions.
6. **dap registry = `setup{ dap_templates }`** (open q. 2): table templates
   merge under overrides, function templates build per call. `debug()`
   resolves relative `program` against the task dir and defaults `cwd` there.
7. **Param UX** (open q. 4): default is the first option; one flow --
   param picker -> value picker with a trailing "new value..." that prompts,
   writes back into source, and selects. Write-back matches existing quote
   style; buffer-wins rule implemented as specified.
8. **Discovery keys off cwd** (open q. 5), `vim.fn.getcwd()` at use time --
   with per-project servers the launch dir is meaningless.
9. **`LitreCmake` reimplemented** (open q. 6) as a generator of imperative
   source: build/run/debug function triple per cmake target, inserted at the
   cursor, meant to be edited down.
10. Not previously discussed, decided in code: primitives are **injected
    globals** in the sandbox env (no `require` in .litre.lua); `debug` therefore
    shadows Lua's debug library inside .litre.lua files -- accepted, task files
    have no business introspecting stacks. Top-level `sh`/`out` is an error:
    top level re-executes on every load, so shell work there would fire on
    every picker open.

11. **Kill (2026-07-20, gap found post-landing):** a hung command used to
    block its task forever ("already running", process left alive) with no
    way out. New layer verb `k`: SIGTERMs the running task's current
    `sh`/`out` process; the primitive sees `task.killed` on resume and aborts
    as "interrupted" instead of "command failed". Tasks suspended in
    `pick`/`input` have no process -- `k` says to cancel the prompt instead
    of pretending it can unwind a `vim.ui` callback.

12. **stdin (2026-07-20):** the anticipated "program-asks-on-stdin" input kind
    landed as `opts.stdin` (string or list) on `sh`/`out`, not a live write
    handle -- the task is suspended while the command runs, so "prompt in Lua,
    then write" can only mean prompting *before* the call and passing the
    answer in. pty + stdin coexist in vim.system (measured).

13. **Exit reaper (2026-07-20):** vim.system children are not killed when
    nvim exits (measured: a pty'd sleep survives `qa!`), so with
    :restart-driven servers every restart would leak the running build.
    A `VimLeavePre` autocmd in the runner SIGTERMs every running task's
    process; verified end-to-end headlessly.

14. **Review fixes (2026-07-22):** `param()` is now genuinely top-level-only —
    the undocumented in-task fallback read a value but could never register in
    the picker (registration only happens while discovery executes the file),
    a trap rather than a feature. `LitreConfig`/`xc` targets the innermost
    *discovered* file, not the innermost successfully *loaded* one, so a
    syntax-broken config can be opened for fixing. `map()` keys that
    `getcharstr` can never deliver (multi-char strings, `"<F5>"` notation)
    warn and are skipped; `vim.keycode` termcodes pass. `params.json` is
    written to a tmp file and renamed: a concurrent reader in another
    per-project server used to be able to see a half-written file, decode `{}`
    and wipe every selection on its next write. A `:bd!`'d output buffer is
    reopened by the task's next `sh()` instead of streaming into the void.
    Write-back finds the target buffer by resolved path (`bufnr()` does
    pattern matching, and symlinked paths never matched). `:LitreCmake`
    filters the `all` pseudo-target — its old filter pattern kept the
    parenthetical from the help line and could never match the captured name.

15. **Kill moved to ctrl-c (2026-08-12):** the layer verb `k` never became a
    reflex — the terminal habit is ctrl-c *in the window showing the output*,
    not "open a picker, press k". The output buffer is a dead terminal with no
    stdin, so a buffer-local normal-mode `<C-c>` (set in `term.open`) routes
    to `runner.kill` of the buffer's own task: no picker needed even with
    several tasks running, since each buffer knows its task. Escalation kept
    (second ctrl-c SIGKILLs); prompt-suspended tasks still answer "cancel the
    prompt instead". `k` is a free map() key again.

16. **Verbs uppercase (2026-09-24):** `v/c/o/r` sat on the keys tasks want
    most -- `map("r", run)` was rejected as reserved by the first real config.
    Verbs are `V/C/O/R` now (fzf-pin binds a source's verb keys whatever their
    case), so the whole lowercase alphabet minus `i` belongs to `map()`.

17. **Primitives via require, tasks Capitalized (2026-09-24):** reverses 10.
    lua-ls saw eight undefined globals per file and typed nothing. Every
    file now opens with `local l = require("litre")` (init re-exports
    `lib`'s nine functions, annotated there) so hover, signature help and
    completion work, and a file stays warning-free even when lua-ls cannot
    see the checkout. A `---@meta` stub was rejected: it duplicates the
    signatures and depends on litre.nvim being in lua-ls's library, which the
    config's runtime-path snapshot delivered in 2 of 5 launches (replaced by
    lazydev on the config side). `debug` no longer shadows Lua's debug
    library. Tasks are Capitalized: `lowercase-global` is lua-ls's "forgot
    `local`" heuristic and Capitalized is its own convention for intended
    globals, so no directive line and no diagnostic filter -- a convention,
    not a rule; lowercase tasks still run (the spec pins it).

18. **Function-valued params, `:LitreCmake` gone (2026-09-24):** closes open
    q. 6. The generator (9) pasted one build/run/debug triple per target,
    parsed `--target help`, which is Makefile-only and omitted executables
    under Ninja (measured), and knew nothing you don't when opening the file.
    Wanted instead: choose from the live target list. Rejected: a
    `set_param` primitive plus a refresh task per file (a new primitive and
    a second meaning for "change a param"). Landed: `param(name, fn)`. Top
    level still never runs anything; `V` runs `fn` through `runner.run` as a
    task of its own -- the coroutine is the same one that keeps `sh`/`out`/
    `pick` blue for every task body, so the function is colourless too, and
    ctrl-c in its buffer kills it. `runner.last` is restored around it so
    `R` never re-runs a choice. `cmake.lua` shrinks to `executables(build_dir)`
    and `executable_path(build_dir, executable)` over cmake's file API: generator-agnostic, executables
    only, real artifact paths (a subdirectory target is `sub/tool`), and a
    plain `cmake --build` refreshes the reply once the query file exists
    (measured), so cmake itself runs only on the first call. The config's
    `litre_cmake` snippet is the whole per-project boilerplate.

Integration (nvim config): `lua/plugins/litre.lua` wires setup with a `cpp`
template (type `gdb` -- the arc-aware adapter from `plugins/dap.lua`); normal-
mode `x` is the layer (the visual-mode habit stays). The nvim-as-tmux half
landed as `plugin/server.lua` (SSH_AUTH_SOCK pin, `:Restart` with session,
`:Connect` picker) plus the `nv`/`nvls` fish functions.
