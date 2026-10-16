-- Fixture tasks stay lowercase on purpose: Capitalized is the documented
-- convention, not a rule, and the suite pins that lowercase still runs.
--
-- Second offline tier: the surface spec.lua does not reach -- the coroutine
-- runner under interleaving, with()/pick()/ask(), the shell-vs-argv split,
-- discovery's error paths, the x layer and the user commands, term window
-- placement, and the params/state edge cases.
--
-- Runs in its own nvim (run.sh loops over tests/spec*.lua): the layer tests
-- consume the typeahead and several tests mutate config.opts, so process
-- isolation from spec.lua is deliberate.
local t = dofile((debug.getinfo(1, "S").source:sub(2)):gsub("spec_advanced%.lua$", "harness.lua"))
vim.opt.rtp:prepend(t.root())
t.quiet()

local discover = require("liter.discover")
local runner = require("liter.runner")
local state = require("liter.state")
local params = require("liter.params")
local term = require("liter.term")
local config = require("liter.config")
local liter = require("liter")

local function wait_done(task)
    return vim.wait(5000, function()
        return task.co ~= nil and coroutine.status(task.co) == "dead"
    end, 5)
end

local function find(d, id)
    for _, task in ipairs(d.tasks) do
        if task.id == id then
            return task
        end
    end
end

-- run by id from a fresh load(), wait for it, return the task
local function run(id)
    local task = assert(find(discover.load(), id), "no task " .. id)
    runner.run(task)
    t.ok(wait_done(task), id .. " did not finish")
    return task
end

-- Headless has no one to answer a prompt, so the stock vim.ui.select would
-- block forever: every test that does not install its own stub gets these.
local function auto_cancel_select(_items, _opts, on_choice)
    on_choice(nil)
end
local function auto_cancel_input(_opts, on_confirm)
    on_confirm(nil)
end
---@diagnostic disable-next-line: duplicate-set-field
vim.ui.select = auto_cancel_select
---@diagnostic disable-next-line: duplicate-set-field
vim.ui.input = auto_cancel_input

-- Tasks outlive the test that started them (a task is done when its coroutine
-- dies, not when the global it sets appears), so drain before asserting on
-- what is running.
local function wait_idle()
    return vim.wait(5000, function()
        return #runner.running_tasks() == 0
    end, 5)
end

local function notified(pat)
    for _, m in ipairs(t.notified) do
        if m:find(pat, 1, true) then
            return m
        end
    end
end

local function write(path, text)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    vim.fn.writefile(vim.split(text, "\n"), path)
end

local work -- filled with the main fixture dir below

-- Discovery keys off cwd, so a test that cds away and then fails would take
-- every later test with it. Always come back, then re-raise.
local function at(dir, fn)
    vim.cmd.cd(dir)
    local ok, err = pcall(fn)
    vim.cmd.cd(work)
    if not ok then
        error(err, 0)
    end
end

-- --- fixture tree -----------------------------------------------------------
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
tmp = vim.fs.normalize(assert(vim.uv.fs_realpath(tmp))) -- /var/tmp is a symlink here
work = vim.fs.joinpath(tmp, "work")
local deep = vim.fs.joinpath(work, "deep")
vim.fn.mkdir(deep, "p")
vim.fn.mkdir(vim.fs.joinpath(tmp, "a", "b"), "p")
-- outside the fixture tree entirely: the upward walk from here finds nothing
local bare = vim.fn.tempname()
vim.fn.mkdir(bare, "p")
bare = vim.fs.normalize(assert(vim.uv.fs_realpath(bare)))

write(vim.fs.joinpath(tmp, ".liter.lua"), [[
local l = require("liter")
shared_greeting = "hi"
function outer_task()
    vim.g.x_outer = l.command({ "pwd" }):run("captured")
end
function slow_outer()
    l.command({ "sleep", "0.15" }):run("captured")
    vim.g.x_slow_outer = l.command({ "pwd" }):run("captured")
end
]])

write(vim.fs.joinpath(work, ".liter.lua"), [[
local l = require("liter")
local level = l.parameter("level", { "-O2", "-O3" })
function slow_inner()
    l.command({ "sleep", "0.05" }):run("captured")
    vim.g.x_slow_inner = l.command({ "pwd" }):run("captured")
end
function withbundle()
    local b = l.with({ dir = "deep", check = false })
    vim.g.x_with_dir = b.command({ "pwd" }):run("captured")
    vim.g.x_with_check = select(2, b.command({ "false" }):run("captured"))
    vim.g.x_with_override = b.command({ "pwd" }, { dir = ".." }):run("captured")
end
function withstack()
    local b = l.with({ dir = "deep", env = { X_A = "a", X_B = "outer" } })
    local s = b.with({ env = { X_B = "inner", X_C = "c" } })
    vim.g.x_stack_dir = s.command({ "pwd" }):run("captured")
    vim.g.x_stack_env = s.command("echo $X_A $X_B $X_C"):run("captured")
    vim.g.x_stack_call = s.command("echo $X_A $X_B $X_C", { env = { X_C = "call" } }):run("captured")
    vim.g.x_stack_dir2 = s.with({ dir = ".." }).command({ "pwd" }):run("captured")
    vim.g.x_stack_base = b.command("echo $X_A $X_B ${X_C:-unset}"):run("captured")
end
function shellstr()
    vim.g.x_shell = l.command("echo one; echo two"):run("captured")
end
function argvliteral()
    vim.g.x_argv = l.command({ "echo", "$HOME and; echo x" }):run("captured")
end
function inherits()
    vim.g.x_inherit = shared_greeting .. level
end
function picky()
    vim.g.x_picked = tostring(l.pick({ "alpha", "beta" }, { prompt = "p" }))
end
function asky()
    vim.g.x_answer = tostring(l.ask("name: ", { default = "anon" }))
end
function nobinary()
    l.command({ "liter-no-such-binary-zzz" }):run()
end
function badout()
    l.command({ "liter-no-such-binary-zzz" }):run("captured")
end
function stderr_in_error()
    l.command({ "sh", "-c", "echo detail 1>&2; exit 3" }):run("captured")
end
function busy()
    l.command({ "sleep", "0.4" }):run("captured")
end
function hang()
    l.command({ "sleep", "30" }):run()
end
function dbgfn()
    l.debug("fn", { program = "bin/app", dir = "deep" })
end
function dbgmissing()
    l.debug("nope")
end
function badparam()
    l.parameter("late", { "x" })
end
function stderr_stream()
    -- the marker is built at runtime so the echoed `$ cmd` header can't match it
    l.command({ "sh", "-c", "echo err-lin''e 1>&2" }):run()
end
function twostep()
    l.command({ "sleep", "0.15" }):run()
    l.command({ "printf", "second-half" }):run()
end
function streamer()
    l.command({ "printf", "from-streamer" }):run()
end
]])

write(vim.fs.joinpath(tmp, "broken", ".liter.lua"), [[
function oops(
]])

write(vim.fs.joinpath(tmp, "rterr", ".liter.lua"), [[
error("top level boom")
]])

vim.cmd.cd(work)

-- --- coroutine runner under interleaving ------------------------------------
-- the central claim of runner.lua: M.current is pinned per resume, so two
-- tasks suspended at the same time each keep their own file/dir context.
t.test("two tasks run concurrently, each keeping its own dir", function()
    vim.g.x_slow_outer, vim.g.x_slow_inner = nil, nil
    local outer = assert(find(discover.load(), "../slow_outer"))
    local inner = assert(find(discover.load(), "slow_inner"))
    runner.run(outer)
    runner.run(inner)
    -- both are alive at once, and running_tasks() sorts by id
    t.ok(vim.wait(1000, function()
        return #runner.running_tasks() == 2
    end, 5), "the two tasks were not running together")
    t.eq(vim.tbl_map(function(x)
        return x.id
    end, runner.running_tasks()), { "../slow_outer", "slow_inner" })
    t.ok(wait_done(inner), "inner did not finish")
    t.ok(wait_done(outer), "outer did not finish")
    t.eq(vim.g.x_slow_inner, work)
    t.eq(vim.g.x_slow_outer, tmp)
    t.eq(#runner.running_tasks(), 0)
end)

t.test("a second run of a live task is refused, not queued", function()
    local task = assert(find(discover.load(), "busy"))
    runner.run(task)
    t.notified = {}
    runner.run(task)
    t.ok(notified("already running"), "no refusal: " .. vim.inspect(t.notified))
    t.ok(wait_done(task), "busy did not finish")
end)

-- --- with() bundle ----------------------------------------------------------
t.test("with() defaults apply to sh/out, per-call opts win", function()
    run("withbundle")
    t.eq(vim.g.x_with_dir, deep)
    t.eq(vim.g.x_with_check, 1, "check = false did not carry through the bundle")
    -- a per-call dir replaces the bundle's outright; it does not stack on top
    -- of it, because every dir resolves against the .liter.lua's own directory
    t.eq(vim.g.x_with_override, tmp, "per-call dir did not win over the default")
end)

t.test("with() stacks: closer wins key by key, env variables accumulate", function()
    config.setup({ shell = "sh" })
    run("withstack")
    t.eq(vim.g.x_stack_dir, deep, "the outer dir did not carry into the stacked bundle")
    t.eq(vim.g.x_stack_env, "a inner c")
    t.eq(vim.g.x_stack_call, "a inner call", "a per-call env must add to the stack, not replace it")
    t.eq(vim.g.x_stack_dir2, tmp, "a stacked dir must replace the outer one")
    t.eq(vim.g.x_stack_base, "a outer unset", "stacking must not mutate the base bundle")
end)

-- --- shell vs argv ----------------------------------------------------------
t.test("a string command goes through config.opts.shell", function()
    config.setup({ shell = "sh" })
    run("shellstr")
    t.eq(vim.g.x_shell, "one\ntwo")
end)

t.test("an argv table bypasses the shell entirely", function()
    run("argvliteral")
    t.eq(vim.g.x_argv, "$HOME and; echo x")
end)

-- --- env nesting ------------------------------------------------------------
t.test("inner file sees outer globals and its own param", function()
    run("inherits")
    t.eq(vim.g.x_inherit, "hi-O2")
end)

t.test("outer file cannot see inner globals", function()
    local d = discover.load()
    t.eq(find(d, "../withbundle"), nil, "inner task leaked into the outer env")
    t.eq(find(d, "../slow_inner"), nil)
end)

-- --- pick() / ask() through the coroutine -----------------------------------
-- the auto-cancel baseline, to restore after a test installs its own stub
local ui_select, ui_input = vim.ui.select, vim.ui.input

t.test("pick() returns the choice when ui.select answers synchronously", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, _opts, on_choice)
        on_choice(items[2])
    end
    run("picky")
    t.eq(vim.g.x_picked, "beta")
end)

t.test("pick() also survives an async ui.select (the fzf-lua shape)", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, _opts, on_choice)
        vim.defer_fn(function()
            on_choice(items[1])
        end, 20)
    end
    run("picky")
    t.eq(vim.g.x_picked, "alpha")
end)

t.test("a cancelled pick() returns nil and the task keeps going", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(_items, _opts, on_choice)
        vim.defer_fn(function()
            on_choice(nil)
        end, 10)
    end
    t.notified = {}
    run("picky")
    t.eq(vim.g.x_picked, "nil")
    t.eq(t.notified, {}, "cancelling should not be an error")
end)

t.test("ask() merges the prompt into opts, sync and async", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.input = function(opts, on_confirm)
        t.eq(opts, { prompt = "name: ", default = "anon" })
        on_confirm("typed")
    end
    run("asky")
    t.eq(vim.g.x_answer, "typed")

    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.input = function(_opts, on_confirm)
        vim.defer_fn(function()
            on_confirm(nil) -- <Esc>
        end, 10)
    end
    run("asky")
    t.eq(vim.g.x_answer, "nil")
end)

vim.ui.select, vim.ui.input = ui_select, ui_input

-- --- failure paths ----------------------------------------------------------
t.test("run() on a missing binary aborts with a spawn message", function()
    t.notified = {}
    run("nobinary")
    t.ok(notified("cannot run liter-no-such-binary-zzz"),
        "unexpected: " .. vim.inspect(t.notified))
end)

t.test("run(\"captured\") on a missing binary aborts the same way", function()
    t.notified = {}
    run("badout")
    t.ok(notified("cannot run liter-no-such-binary-zzz"),
        "unexpected: " .. vim.inspect(t.notified))
end)

t.test("run(\"captured\")'s failure message carries stderr", function()
    t.notified = {}
    run("stderr_in_error")
    local msg = notified("command failed (exit 3)")
    t.ok(msg, "unexpected: " .. vim.inspect(t.notified))
    t.ok(msg:find("detail", 1, true), "stderr not reported: " .. msg)
end)

t.test("run() streams stderr into the buffer too (pty covers stdout only)", function()
    run("stderr_stream")
    local buf = assert(term.buf("stderr_stream"), "task produced no output buffer")
    t.ok(vim.wait(2000, function()
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        return text:find("err-line", 1, true) ~= nil
    end, 10), "stderr output never reached the buffer")
end)

-- --- terminal buffer placement ----------------------------------------------
t.test("a re-run replaces the buffer in every window showing it, without stealing focus", function()
    run("streamer")
    local old = assert(term.buf("streamer"))
    vim.cmd("split")
    local watcher = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(watcher, old)
    vim.cmd("wincmd j")
    local focus = vim.api.nvim_get_current_win()
    t.ok(focus ~= watcher, "test needs two windows")
    -- the focused window must hold something else, or it is a watcher too
    vim.cmd.enew()
    local focus_buf = vim.api.nvim_win_get_buf(focus)

    run("streamer")
    local new = assert(term.buf("streamer"))
    t.ok(new ~= old, "buffer was not replaced")
    t.eq(vim.api.nvim_win_get_buf(watcher), new, "the watching window did not follow")
    t.eq(vim.api.nvim_get_current_win(), focus, "focus moved")
    t.eq(vim.api.nvim_win_get_buf(focus), focus_buf, "the focused window was hijacked")
    vim.cmd("only")
end)

t.test("a deleted output buffer is reopened by the task's next run()", function()
    local task = assert(find(discover.load(), "twostep"))
    runner.run(task)
    local first = term.buf("twostep")
    t.ok(first, "first run() opened no buffer")
    vim.api.nvim_buf_delete(assert(first), { force = true })
    t.ok(wait_done(task), "twostep did not finish")
    local buf = term.buf("twostep")
    t.ok(buf, "the second run() did not reopen a buffer")
    t.ok(vim.wait(2000, function()
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        return text:find("second-half", 1, true) ~= nil
    end, 10), "the second command's output was lost")
    vim.cmd.enew()
end)

-- --- discovery error paths --------------------------------------------------
t.test("a .liter.lua that does not compile is reported, outer files still load", function()
    at(vim.fs.joinpath(tmp, "broken"), function()
        t.notified = {}
        local d = discover.load()
        t.ok(notified("liter:"), "syntax error not reported")
        t.ok(find(d, "../outer_task"), "the healthy outer file was dropped too")
        t.eq(#d.files, 1, "the broken file was counted as loaded")
    end)
end)

t.test("a .liter.lua that raises at load time is reported the same way", function()
    at(vim.fs.joinpath(tmp, "rterr"), function()
        t.notified = {}
        local d = discover.load()
        t.ok(notified("top level boom"), "not reported: " .. vim.inspect(t.notified))
        t.ok(find(d, "../outer_task"), "the healthy outer file was dropped too")
    end)
end)

t.test("ids carry one .. per level between cwd and the file", function()
    at(vim.fs.joinpath(tmp, "a", "b"), function()
        local d = discover.load()
        t.ok(find(d, "../../outer_task"), "two-level prefix missing: " ..
            vim.inspect(vim.tbl_map(function(x)
                return x.id
            end, d.tasks)))
    end)
end)

-- A file registers params as it executes, so anything it registered
-- before raising is already in the collector when the error unwinds it.
write(vim.fs.joinpath(tmp, "ghost", ".liter.lua"), [[
local l = require("liter")
local mode = l.parameter("ghost_param", { "x", "y" })
function ghost_task()
end
error("boom after registering")
]])

t.test("a file that raises after parameter() does not leak the param", function()
    at(vim.fs.joinpath(tmp, "ghost"), function()
        t.notified = {}
        local d = discover.load()
        t.ok(notified("boom after registering"), "the error was not reported")
        t.ok(not find(d, "ghost_task"), "a task from the failed file survived")
        for _, p in ipairs(d.params) do
            t.ok(p.name ~= "ghost_param",
                "param from a file that failed to load: " .. vim.inspect(d.params))
        end
    end)
end)

-- The contract is "every function own-global is a task". These pin its edges:
-- what does not count, and what a file can do to the primitives it inherits.
write(vim.fs.joinpath(tmp, "empty", ".liter.lua"), "")

write(vim.fs.joinpath(tmp, "callable", ".liter.lua"), [[
callable_task = setmetatable({}, { __call = function() vim.g.x_callable = 7 end })
plain_table = { 1, 2, 3 }
scalar = 5
]])

write(vim.fs.joinpath(tmp, "shadow", ".liter.lua"), [[
function command()
    vim.g.x_shadowed_command = "mine"
end
function uses_command()
    command({ "true" })
end
]])

t.test("an empty .liter.lua contributes nothing and says nothing", function()
    at(vim.fs.joinpath(tmp, "empty"), function()
        t.notified = {}
        local d = discover.load()
        t.eq(t.notified, {}, "an empty file should load silently")
        t.ok(find(d, "../outer_task"), "the outer file was dropped")
        for _, task in ipairs(d.tasks) do
            t.ok(task.dir ~= vim.fs.joinpath(tmp, "empty"),
                "the empty file produced a task: " .. task.id)
        end
    end)
end)

t.test("only functions are tasks: a __call table, a plain table, a scalar are not", function()
    at(vim.fs.joinpath(tmp, "callable"), function()
        local d = discover.load()
        t.ok(not find(d, "callable_task"), "a __call table became a task")
        t.ok(not find(d, "plain_table"), "a plain table became a task")
        t.ok(not find(d, "scalar"), "a number became a task")
    end)
end)

t.test("a global named after a primitive is just a task: nothing is injected", function()
    at(vim.fs.joinpath(tmp, "shadow"), function()
        t.notified = {}
        local d = discover.load()
        t.ok(find(d, "command"), "the global is not itself a task")
        t.eq(t.notified, {}, "a plain global should load silently")
        -- and the file's own calls resolve to it, not to lib.sh: the task
        -- below would otherwise need a coroutine to run at all
        vim.g.x_shadowed_command = nil
        assert(find(d, "uses_command")).fn()
        t.eq(vim.g.x_shadowed_command, "mine", "sh() did not resolve to the global")
    end)
end)

-- --- the x layer ------------------------------------------------------------
-- The layer is liter.source driven through fzf-pin's picker; build() returns
-- the per-char closures the real fzf binds would fire, so the semantics are
-- testable without a UI. run.sh finds fzf-pin where lazy.nvim loads it from.
vim.opt.rtp:prepend(assert(vim.env.FZF_PIN_DIR, "run via tests/run.sh, which finds fzf-pin"))
local fzfpin = require("fzf-pin.picker")
-- press key with the entry containing `highlight` under fzf's cursor; returns
-- what the picker's footer would say
local function layer_with(key, highlight)
    local built = fzfpin.build(liter.source)
    local line
    for _, e in ipairs(built.entries()) do -- populates the char lookup, as fzf would
        if highlight and e:find(highlight, 1, true) then
            line = e
        end
    end
    -- enter and the verbs are plain binds (uppercase ones dispatched by their
    -- underscore name); a lowercase key is decided at press time, and a
    -- pinned one accepts
    local action = built.actions[key] or built.actions["_verb_" .. key:lower()]
    if action then
        return action({ line })
    end
    local next, say = built.press(key, line)
    if next == "accept" then
        built.actions["_char_" .. key]()
    end
    return say
end

local function entry(needle)
    for _, e in ipairs(fzfpin.build(liter.source).entries()) do
        if e:find(needle, 1, true) then
            return e
        end
    end
end

t.test("layer: a free key pins the highlighted task, which then runs on that key", function()
    t.eq(layer_with("b", "withbundle"), "pinned withbundle to b")
    t.ok(vim.startswith(entry("withbundle") or "", "[b] "), "pin not rendered: "
        .. tostring(entry("withbundle")))
    vim.g.x_with_dir = nil
    layer_with("b")
    t.ok(vim.wait(3000, function()
        return vim.g.x_with_dir ~= nil
    end, 10), "the pinned task never ran")
end)

t.test("layer: pins persist on disk, per cwd", function()
    local pins = require("fzf-pin.store").load("liter/" .. work:gsub("/", "%%"))
    t.eq(pins, { b = "task withbundle" })
    at(bare, function()
        t.eq(require("fzf-pin.store").load("liter/" .. bare:gsub("/", "%%")), {})
    end)
end)

t.test("layer: an entry already pinned is not pinned twice", function()
    local say = layer_with("q", "withbundle")
    t.ok(say and say:find("already on b", 1, true), "unexpected: " .. tostring(say))
end)

t.test("layer: a free key with nothing highlighted says so", function()
    local say = layer_with("q")
    t.ok(say and say:find("nothing highlighted", 1, true), "unexpected: " .. tostring(say))
end)

t.test("layer: a param is listed, pinnable, and its key opens the value picker", function()
    t.ok(entry("level = -O2"), "param not listed")
    layer_with("l", "level = ")
    t.ok(vim.startswith(entry("level = ") or "", "[l] "), "param pin not rendered")
    local seen, prompt
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, opts, on_choice)
        seen, prompt = items, opts.prompt
        on_choice(nil)
    end
    layer_with("l")
    vim.ui.select = ui_select
    t.eq(seen and seen[1], "-O2", "the value picker did not open")
    -- vim.ui.select's own prompt shape, which fzf-lua renders as "level> "
    t.eq(prompt, "level:")
end)

t.test("layer: ctrl-x unpins", function()
    local built = fzfpin.build(liter.source)
    built.entries()
    built.press("ctrl-x", assert(entry("withbundle")))
    built.press("ctrl-x", assert(entry("level = ")))
    t.ok(vim.startswith(entry("withbundle"), "    "), "still pinned: " .. entry("withbundle"))
    t.ok(vim.startswith(entry("level = "), "    "), "still pinned: " .. entry("level = "))
end)

t.test("layer: O shows the last task's output buffer", function()
    run("streamer") -- make streamer the last task, with a buffer
    layer_with("O")
    t.eq(vim.api.nvim_get_current_buf(), term.buf("streamer"))
    vim.cmd.enew()
end)

t.test("layer: R re-runs the last task", function()
    run("inherits")
    vim.g.x_inherit = nil
    layer_with("R")
    t.ok(vim.wait(3000, function()
        return vim.g.x_inherit ~= nil
    end, 10), "re-run did not happen")
end)

-- press the buffer-local <C-c> map the way the user would
local function ctrl_c(buf)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
        if vim.keycode(m.lhs) == vim.keycode("<C-c>") and m.callback then
            m.callback()
            return
        end
    end
    error("no <C-c> map on buffer " .. buf)
end

t.test("ctrl-c in the output buffer kills the buffer's task", function()
    t.ok(wait_idle(), "a task from an earlier test is still running")
    local task = assert(find(discover.load(), "hang"))
    runner.run(task)
    t.ok(vim.wait(2000, function()
        return task.proc ~= nil
    end, 5), "hang never started its process")
    t.notified = {}
    ctrl_c(assert(term.buf("hang"), "hang has no output buffer"))
    t.ok(wait_done(task), "the task was not killed")
    t.ok(notified("interrupted"), "unexpected: " .. vim.inspect(t.notified))
end)

t.test("ctrl-c on a finished run's buffer says the task is not running", function()
    run("streamer")
    t.notified = {}
    ctrl_c(assert(term.buf("streamer"), "streamer has no output buffer"))
    t.ok(notified("streamer is not running"), "unexpected: " .. vim.inspect(t.notified))
end)

t.test("ctrl-c on an earlier run's buffer says that run has finished", function()
    run("streamer")
    local old = assert(term.buf("streamer"))
    run("streamer")
    t.notified = {}
    ctrl_c(old)
    t.ok(notified("this run of streamer has finished"), "unexpected: " .. vim.inspect(t.notified))
end)

t.test("kill on a task waiting in a prompt explains itself instead", function()
    local held
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(_items, _opts, on_choice)
        held = on_choice -- never answered: the task stays suspended
    end
    local task = assert(find(discover.load(), "picky"))
    runner.run(task)
    t.ok(vim.wait(1000, function()
        return held ~= nil
    end, 5), "picker never opened")
    t.notified = {}
    runner.kill(task)
    t.ok(notified("waiting in a prompt"), "unexpected: " .. vim.inspect(t.notified))
    held(nil) -- let it finish so it stops counting as running
    t.ok(wait_done(task), "task did not resume after the prompt was cancelled")
    vim.ui.select = ui_select
end)

-- --- user commands ----------------------------------------------------------
t.test("setup() registers the two commands", function()
    liter.setup({ shell = "sh" })
    local cmds = vim.api.nvim_get_commands({})
    for _, name in ipairs({ "Liter", "LiterConfig" }) do
        t.ok(cmds[name], name .. " not registered")
    end
end)

t.test(":Liter <name> runs the nearest task of that bare name", function()
    vim.g.x_inherit = nil
    vim.cmd("Liter inherits")
    t.ok(vim.wait(3000, function()
        return vim.g.x_inherit ~= nil
    end, 10), ":Liter inherits did not run")
end)

t.test(":Liter with a prefixed id also resolves", function()
    vim.g.x_outer = nil
    vim.cmd("Liter ../outer_task")
    t.ok(vim.wait(3000, function()
        return vim.g.x_outer ~= nil
    end, 10), ":Liter ../outer_task did not run")
    t.eq(vim.g.x_outer, tmp)
end)

t.test(":Liter on an unknown task warns", function()
    t.notified = {}
    vim.cmd("Liter nosuchtask")
    t.ok(notified("no task nosuchtask"), "unexpected: " .. vim.inspect(t.notified))
end)

t.test(":Liter completion lists task ids", function()
    local ids = vim.fn.getcompletion("Liter ", "cmdline")
    t.ok(vim.tbl_contains(ids, "inherits"), "inherits missing from " .. vim.inspect(ids))
    t.ok(vim.tbl_contains(ids, "../outer_task"), "prefixed id missing")
end)

t.test(":LiterConfig opens the innermost .liter.lua", function()
    vim.cmd("LiterConfig")
    t.eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), vim.fs.joinpath(work, ".liter.lua"))
    vim.cmd.enew()
end)

t.test("edit_config offers a path at cwd when no .liter.lua exists", function()
    at(bare, function()
        liter.edit_config()
        t.eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), vim.fs.joinpath(bare, ".liter.lua"))
        t.eq(vim.fn.filereadable(vim.fs.joinpath(bare, ".liter.lua")), 0,
            "it should not be created")
        vim.cmd.enew()
    end)
end)

t.test("edit_config reaches a .liter.lua that fails to load", function()
    at(vim.fs.joinpath(tmp, "broken"), function()
        liter.edit_config()
        t.eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)),
            vim.fs.joinpath(tmp, "broken", ".liter.lua"),
            "the broken innermost file is exactly the one that needs editing")
        vim.cmd.enew()
    end)
end)

t.test("the layer source is empty but usable when no .liter.lua exists", function()
    at(bare, function()
        -- the picker still opens: verbs like C (edit config) must stay reachable
        t.eq(liter.source.list(), {})
    end)
end)

-- --- param picker -----------------------------------------------------------
t.test("a param entry shows the live value and persists a new selection", function()
    t.ok(entry("level = -O2"), "unexpected entries: "
        .. vim.inspect(fzfpin.build(liter.source).entries()))
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, _opts, on_choice)
        on_choice(items[2]) -- "-O3"
    end
    layer_with("enter", "level = ")
    vim.ui.select = ui_select
    t.ok(entry("level = -O3"), "the label did not follow the new value")
    t.eq(state.get(vim.fs.joinpath(work, ".liter.lua"), "level"), "-O3")
    run("inherits")
    t.eq(vim.g.x_inherit, "hi-O3", "the new value did not reach the task")
end)

t.test("a param entry's new-value path writes the source and selects it", function()
    local file = vim.fs.joinpath(work, ".liter.lua")
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, _opts, on_choice)
        on_choice(items[#items]) -- "  new value..."
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.input = function(_opts, on_confirm)
        on_confirm("-Og")
    end
    layer_with("enter", "level = ")
    vim.ui.select, vim.ui.input = ui_select, ui_input
    t.eq(state.get(file, "level"), "-Og")
    t.ok(table.concat(vim.fn.readfile(file), "\n"):find('"-O3", "-Og"', 1, true),
        "the option was not written back to the source")
    t.eq(discover.load().params[1].options, { "-O2", "-O3", "-Og" })
    state.set(file, "level", "-O2")
end)

t.test("a function-valued param runs as a task when activated and persists the pick", function()
    local dyn = vim.fs.joinpath(tmp, "dyn")
    local file = vim.fs.joinpath(dyn, ".liter.lua")
    write(file, [[
local l = require("liter")
local which = l.parameter("which", function()
    return vim.split(l.command({ "printf", "one\nthree\ntwo" }):run("captured"), "\n")
end)
function report()
    vim.g.x_which = tostring(which)
end
]])
    at(dyn, function()
        run("report")
        t.eq(vim.g.x_which, "nil", "an unchosen function param must read nil")
        local seen
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.ui.select = function(items, _opts, on_choice)
            seen = items
            on_choice(items[2])
        end
        t.ok(entry("which = ?"), "an unchosen function param should read ?")
        layer_with("enter", "which = ")
        -- the list function yields on out(): the value picker opens later
        t.ok(wait_idle(), "the V task did not finish")
        vim.ui.select = ui_select
        t.eq(seen, { "one", "three", "two" }, "the value picker did not get the function's list")
        t.eq(state.get(file, "which"), "three")
        t.eq(runner.last.id, "report", "choosing a value must not become R's target")
        run("report")
        t.eq(vim.g.x_which, "three")
    end)
end)

-- --- cmake helpers ----------------------------------------------------------
-- No cmake in the offline tier: a hand-written file-API reply (the shape
-- cmake 3.28 writes, measured) stands in for a configured build dir.
t.test("cmake.executables/executable_path read the file-API reply", function()
    local proj = vim.fs.joinpath(tmp, "cm")
    local reply = vim.fs.joinpath(proj, "bld", ".cmake", "api", "v1", "reply")
    local function json(name, obj)
        write(vim.fs.joinpath(reply, name), vim.json.encode(obj))
    end
    json("index-2026-01-01T00-00-00-0000.json", { reply = { ["codemodel-v2"] = { jsonFile = "old.json" } } })
    json("index-2026-09-24T00-00-00-0000.json", { reply = { ["codemodel-v2"] = { jsonFile = "cm.json" } } })
    json("cm.json", { configurations = { { targets = {
        { name = "tool", jsonFile = "t-tool.json" },
        { name = "lib", jsonFile = "t-lib.json" },
        { name = "main", jsonFile = "t-main.json" },
    } } } })
    json("t-tool.json", { name = "tool", type = "EXECUTABLE", artifacts = { { path = "sub/tool" } } })
    json("t-lib.json", { name = "lib", type = "STATIC_LIBRARY", artifacts = { { path = "liblib.a" } } })
    json("t-main.json", { name = "main", type = "EXECUTABLE", artifacts = { { path = "main" } } })
    write(vim.fs.joinpath(proj, ".liter.lua"), [[
local cm = require("liter.cmake")
function probe()
    vim.g.x_cm = { targets = cm.executables("bld"), tool = cm.executable_path("bld", "tool") }
end
function missing()
    cm.executable_path("bld", "lib")
end
function unset()
    cm.executable_path("bld", nil)
end
]])
    at(proj, function()
        run("probe")
        t.eq(vim.g.x_cm, { targets = { "main", "tool" }, tool = "sub/tool" })
        t.notified = {}
        run("missing")
        t.ok(notified('no executable target "lib"'), vim.inspect(t.notified))
        t.notified = {}
        run("unset")
        t.ok(notified("no target chosen yet"), vim.inspect(t.notified))
    end)
end)

-- --- dap templates ----------------------------------------------------------
t.test("a function template is called with the overrides", function()
    config.setup({
        dap_templates = {
            fn = function(o)
                return { type = "gdb", request = "launch", program = o.program, seen = o }
            end,
        },
    })
    package.loaded["dap"] = {
        run = function(cfg)
            vim.g.x_dap = cfg
        end,
    }
    run("dbgfn")
    local cfg = vim.g.x_dap
    t.eq(cfg.type, "gdb")
    t.eq(cfg.name, "fn", "name defaulted from the template name")
    t.eq(cfg.program, vim.fs.joinpath(deep, "bin/app"), "program resolved against opts.dir")
    t.eq(cfg.cwd, deep)
    t.eq(cfg.dir, nil, "the liter-only dir option leaked into the dap config")
end)

t.test("an unknown template aborts with a message naming setup{}", function()
    t.notified = {}
    run("dbgmissing")
    t.ok(notified('no dap template "nope"'), "unexpected: " .. vim.inspect(t.notified))
    t.ok(notified("dap_templates"), "the message should say where to register it")
end)

-- --- primitives outside a task ----------------------------------------------
t.test("run(captured)/pick/ask all refuse to run outside a task", function()
    local lib = require("liter.lib")
    local ok, err = pcall(function()
        return lib.command({ "true" }):run("captured")
    end)
    t.eq(ok, false, "captured run did not refuse")
    t.ok(tostring(err):find("inside a running task", 1, true), tostring(err))
    for _, name in ipairs({ "pick", "ask" }) do
        ok, err = pcall(lib[name], { "true" })
        t.eq(ok, false, name .. " did not refuse")
        t.ok(tostring(err):find("inside a running task", 1, true), tostring(err))
    end
end)

t.test("run() rejects an unknown mode before spawning anything", function()
    local ok, err = pcall(function()
        ---@diagnostic disable-next-line: param-type-mismatch
        return require("liter.lib").command({ "true" }):run("loud")
    end)
    t.eq(ok, false)
    t.ok(tostring(err):find('"live" or "captured"', 1, true), tostring(err))
end)

-- a param declared inside a task would read a value but never register while
-- discovery runs, so the picker could not see it -- refuse instead of half-working
t.test("parameter() inside a task errors instead of half-working", function()
    t.notified = {}
    run("badparam")
    t.ok(notified("top level"), "unexpected: " .. vim.inspect(t.notified))
end)

-- --- persisted state --------------------------------------------------------
t.test("state survives a round trip and is keyed by file and name", function()
    local f1, f2 = "/one/.liter.lua", "/two/.liter.lua"
    state.set(f1, "mode", "debug")
    state.set(f2, "mode", "release")
    state.set(f1, "other", "x")
    t.eq(state.get(f1, "mode"), "debug")
    t.eq(state.get(f2, "mode"), "release")
    t.eq(state.get(f1, "other"), "x")
    t.eq(state.get(f1, "missing"), nil)
    t.eq(state.get("/nowhere/.liter.lua", "mode"), nil)
end)

t.test("a corrupt state file reads as empty instead of raising", function()
    local p = vim.fs.joinpath(vim.fn.stdpath("data"), "liter", "parameters.json")
    vim.fn.writefile({ "{not json" }, p)
    t.eq(state.get("/one/.liter.lua", "mode"), nil)
    state.set("/one/.liter.lua", "mode", "recovered") -- and it heals on write
    t.eq(state.get("/one/.liter.lua", "mode"), "recovered")
end)

-- --- params write-back edges ------------------------------------------------
t.test("write-back into an empty option list", function()
    local f = vim.fs.joinpath(tmp, "pf_empty.lua")
    write(f, 'local m = parameter("mode", {})')
    t.ok(params.add_option(f, "mode", "first"))
    t.eq(table.concat(vim.fn.readfile(f), "\n"), 'local m = parameter("mode", { "first" })')
end)

t.test("write-back keeps single-quote style and escapes the quote", function()
    local f = vim.fs.joinpath(tmp, "pf_quote.lua")
    write(f, "local m = parameter('mode', { 'a' })")
    t.ok(params.add_option(f, "mode", "it's"))
    t.eq(table.concat(vim.fn.readfile(f), "\n"), "local m = parameter('mode', { 'a', 'it\\'s' })")
end)

t.test("write-back escapes backslashes", function()
    local f = vim.fs.joinpath(tmp, "pf_esc.lua")
    write(f, 'local m = parameter("p", { "a" })')
    t.ok(params.add_option(f, "p", [[c:\tmp]]))
    t.ok(table.concat(vim.fn.readfile(f), "\n"):find([["c:\\tmp"]], 1, true),
        "backslash not escaped: " .. table.concat(vim.fn.readfile(f), "\n"))
end)

t.test("write-back picks the named param, not the first one in the file", function()
    local f = vim.fs.joinpath(tmp, "pf_two.lua")
    write(f, 'local a = parameter("aa", { "1" })\nlocal b = parameter("bb", { "2" })')
    t.ok(params.add_option(f, "bb", "3"))
    t.eq(vim.fn.readfile(f), {
        'local a = parameter("aa", { "1" })',
        'local b = parameter("bb", { "2", "3" })',
    })
end)

t.test("write-back finds a param called through a module table", function()
    local f = vim.fs.joinpath(tmp, "pf_dot.lua")
    write(f, 'local m = liter.parameter("mode", { "a" })')
    t.ok(params.add_option(f, "mode", "b"))
    t.eq(table.concat(vim.fn.readfile(f), "\n"), 'local m = liter.parameter("mode", { "a", "b" })')
end)

-- The tests above pin the exact text for known-good values. This one pins the
-- property that matters for anything else: whatever goes in, the file still
-- parses as Lua afterwards and the option reads back byte-identical.
local function roundtrip(value)
    local f = vim.fs.joinpath(tmp, "pf_rt.lua")
    write(f, 'local m = parameter("p", { "a" })')
    if not params.add_option(f, "p", value) then
        return nil, "add_option refused"
    end
    local src = table.concat(vim.fn.readfile(f), "\n")
    local chunk, lerr = loadstring(src)
    if not chunk then
        return nil, ("no longer parses (%s) -- source: %s"):format(lerr, src)
    end
    local got
    setfenv(chunk, { parameter = function(_, opts) got = opts end })
    local ok, rerr = pcall(chunk)
    if not ok then
        return nil, "no longer runs: " .. tostring(rerr)
    end
    return got
end

t.test("write-back round-trips awkward values without breaking the file", function()
    for _, value in ipairs({
        [[a"b]], [[c:\tmp]], "it's", "100%", "a\tb", "héllo", "}", [[\]], [["]],
        "both'and\"", "-- not a comment", "]] .. [[",
        -- a real line break used to be spliced in as-is, leaving the file
        -- unparseable while add_option still reported success
        "a\nb", "trailing\n", "\r\n",
    }) do
        local got, err = roundtrip(value)
        t.ok(got ~= nil, ("value %q: %s"):format(value, tostring(err)))
        if got then
            t.eq(got, { "a", value }, ("value %q did not round-trip"):format(value))
        end
    end
end)

t.test("write-back finds a buffer opened through a symlinked path", function()
    local real = vim.fs.joinpath(tmp, "real")
    local target = vim.fs.joinpath(real, ".liter.lua")
    write(target, 'local m = parameter("mode", { "a" })')
    local link = vim.fs.joinpath(tmp, "link")
    assert(vim.uv.fs_symlink(real, link))
    vim.cmd.edit(vim.fs.joinpath(link, ".liter.lua"))
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, 0, true, { "-- via symlink" })
    t.ok(params.add_option(target, "mode", "b"))
    local text = table.concat(vim.fn.readfile(target), "\n")
    t.ok(text:find("-- via symlink", 1, true),
        "buffer edit lost -- the disk path was edited behind the buffer's back")
    t.ok(text:find('"a", "b"', 1, true), "option not appended: " .. text)
    t.eq(vim.bo[buf].modified, false, "buffer left unsaved")
    vim.cmd.enew()
end)

t.test("write-back for a param that is not in the file fails cleanly", function()
    local f = vim.fs.joinpath(tmp, "pf_two.lua")
    t.notified = {}
    t.eq(params.add_option(f, "zz", "1"), false)
    t.ok(notified("no literal option list"), "unexpected: " .. vim.inspect(t.notified))
end)

t.finish("liter advanced spec")
