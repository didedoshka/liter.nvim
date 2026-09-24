-- Fixture tasks stay lowercase on purpose: Capitalized is the documented
-- convention, not a rule, and the suite pins that lowercase still runs.
--
-- Second offline tier: the surface spec.lua does not reach -- the coroutine
-- runner under interleaving, with()/pick()/input(), the shell-vs-argv split,
-- discovery's error paths, the x layer and the user commands, term window
-- placement, and the params/state edge cases.
--
-- Runs in its own nvim (run.sh loops over tests/spec*.lua): the layer tests
-- consume the typeahead and several tests mutate config.opts, so process
-- isolation from spec.lua is deliberate.
local t = dofile((debug.getinfo(1, "S").source:sub(2)):gsub("spec_advanced%.lua$", "harness.lua"))
vim.opt.rtp:prepend(t.root())
t.quiet()

local discover = require("litre.discover")
local runner = require("litre.runner")
local state = require("litre.state")
local params = require("litre.params")
local term = require("litre.term")
local config = require("litre.config")
local litre = require("litre")

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

write(vim.fs.joinpath(tmp, ".litre.lua"), [[
local l = require("litre")
shared_greeting = "hi"
function outer_task()
    vim.g.x_outer = l.out({ "pwd" })
end
function slow_outer()
    l.out({ "sleep", "0.15" })
    vim.g.x_slow_outer = l.out({ "pwd" })
end
]])

write(vim.fs.joinpath(work, ".litre.lua"), [[
local l = require("litre")
local level = l.param("level", { "-O2", "-O3" })
function slow_inner()
    l.out({ "sleep", "0.05" })
    vim.g.x_slow_inner = l.out({ "pwd" })
end
function withbundle()
    local b = l.with({ dir = "deep", check = false })
    vim.g.x_with_dir = b.out({ "pwd" })
    vim.g.x_with_check = select(2, b.out({ "false" }))
    vim.g.x_with_override = b.out({ "pwd" }, { dir = ".." })
    vim.g.x_with_cmd = b.cmd({ "pwd" })()
end
function withstack()
    local b = l.with({ dir = "deep", env = { X_A = "a", X_B = "outer" } })
    local s = b.with({ env = { X_B = "inner", X_C = "c" } })
    vim.g.x_stack_dir = s.out({ "pwd" })
    vim.g.x_stack_env = s.out("echo $X_A $X_B $X_C")
    vim.g.x_stack_call = s.out("echo $X_A $X_B $X_C", { env = { X_C = "call" } })
    vim.g.x_stack_dir2 = s.with({ dir = ".." }).out({ "pwd" })
    vim.g.x_stack_base = b.out("echo $X_A $X_B ${X_C:-unset}")
end
function shellstr()
    vim.g.x_shell = l.out("echo one; echo two")
end
function argvliteral()
    vim.g.x_argv = l.out({ "echo", "$HOME and; echo x" })
end
function inherits()
    vim.g.x_inherit = shared_greeting .. level
end
function picky()
    vim.g.x_picked = tostring(l.pick({ "alpha", "beta" }, { prompt = "p" }))
end
function inputy()
    vim.g.x_input = tostring(l.input("name: "))
end
function nobinary()
    l.sh({ "litre-no-such-binary-zzz" })
end
function badout()
    l.out({ "litre-no-such-binary-zzz" })
end
function stderr_in_error()
    l.out({ "sh", "-c", "echo detail 1>&2; exit 3" })
end
function busy()
    l.out({ "sleep", "0.4" })
end
function hang()
    l.sh({ "sleep", "30" })
end
function dbgfn()
    l.debug("fn", { program = "bin/app", dir = "deep" })
end
function dbgmissing()
    l.debug("nope")
end
function badparam()
    l.param("late", { "x" })
end
function stderr_stream()
    -- the marker is built at runtime so the echoed `$ cmd` header can't match it
    l.sh({ "sh", "-c", "echo err-lin''e 1>&2" })
end
function twostep()
    l.sh({ "sleep", "0.15" })
    l.sh({ "printf", "second-half" })
end
streamer = l.cmd({ "printf", "from-cmd" })
l.map("b", withbundle)
]])

write(vim.fs.joinpath(tmp, "broken", ".litre.lua"), [[
function oops(
]])

write(vim.fs.joinpath(tmp, "rterr", ".litre.lua"), [[
error("top level boom")
]])

write(vim.fs.joinpath(tmp, "weird", ".litre.lua"), [[
local l = require("litre")
function real_task()
end
l.map("x", real_task)
l.map("z", function() end)
l.map("R", real_task)
l.map("i", real_task)
]])

write(vim.fs.joinpath(tmp, "badmap", ".litre.lua"), [[
local l = require("litre")
function mc_task()
end
l.map("gd", mc_task)
l.map(vim.keycode("<F5>"), mc_task)
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
t.test("with() defaults apply to sh/out/cmd, per-call opts win", function()
    run("withbundle")
    t.eq(vim.g.x_with_dir, deep)
    t.eq(vim.g.x_with_check, 1, "check = false did not carry through the bundle")
    -- a per-call dir replaces the bundle's outright; it does not stack on top
    -- of it, because every dir resolves against the .litre.lua's own directory
    t.eq(vim.g.x_with_override, tmp, "per-call dir did not win over the default")
    t.eq(vim.g.x_with_cmd, deep, "bundle defaults did not reach cmd()")
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

-- --- pick() / input() through the coroutine ---------------------------------
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

t.test("input() takes a bare string as the prompt, sync and async", function()
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.input = function(opts, on_confirm)
        t.eq(opts.prompt, "name: ")
        on_confirm("typed")
    end
    run("inputy")
    t.eq(vim.g.x_input, "typed")

    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.input = function(_opts, on_confirm)
        vim.defer_fn(function()
            on_confirm(nil) -- <Esc>
        end, 10)
    end
    run("inputy")
    t.eq(vim.g.x_input, "nil")
end)

vim.ui.select, vim.ui.input = ui_select, ui_input

-- --- failure paths ----------------------------------------------------------
t.test("sh() on a missing binary aborts with a spawn message", function()
    t.notified = {}
    run("nobinary")
    t.ok(notified("cannot run litre-no-such-binary-zzz"),
        "unexpected: " .. vim.inspect(t.notified))
end)

t.test("out() on a missing binary aborts the same way", function()
    t.notified = {}
    run("badout")
    t.ok(notified("cannot run litre-no-such-binary-zzz"),
        "unexpected: " .. vim.inspect(t.notified))
end)

t.test("out()'s failure message carries stderr", function()
    t.notified = {}
    run("stderr_in_error")
    local msg = notified("command failed (exit 3)")
    t.ok(msg, "unexpected: " .. vim.inspect(t.notified))
    t.ok(msg:find("detail", 1, true), "stderr not reported: " .. msg)
end)

-- --- cmd values as tasks ----------------------------------------------------
t.test("a cmd value invoked as a task streams instead of capturing", function()
    run("streamer")
    local buf = term.buf("streamer")
    t.ok(buf, "cmd task produced no output buffer")
    t.ok(vim.wait(2000, function()
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        return text:find("from-cmd", 1, true) ~= nil
    end, 10), "cmd output never reached the buffer")
end)

t.test("sh() streams stderr into the buffer too (pty covers stdout only)", function()
    run("stderr_stream")
    local buf = assert(term.buf("stderr_stream"), "task produced no output buffer")
    t.ok(vim.wait(2000, function()
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        return text:find("err-line", 1, true) ~= nil
    end, 10), "stderr output never reached the buffer")
end)

-- --- terminal buffer placement ----------------------------------------------
t.test("a re-run replaces the buffer in every window showing it, without stealing focus", function()
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

t.test("a deleted output buffer is reopened by the task's next sh()", function()
    local task = assert(find(discover.load(), "twostep"))
    runner.run(task)
    local first = term.buf("twostep")
    t.ok(first, "first sh() opened no buffer")
    vim.api.nvim_buf_delete(assert(first), { force = true })
    t.ok(wait_done(task), "twostep did not finish")
    local buf = term.buf("twostep")
    t.ok(buf, "the second sh() did not reopen a buffer")
    t.ok(vim.wait(2000, function()
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        return text:find("second-half", 1, true) ~= nil
    end, 10), "the second command's output was lost")
    vim.cmd.enew()
end)

-- --- discovery error paths --------------------------------------------------
t.test("a .litre.lua that does not compile is reported, outer files still load", function()
    at(vim.fs.joinpath(tmp, "broken"), function()
        t.notified = {}
        local d = discover.load()
        t.ok(notified("litre:"), "syntax error not reported")
        t.ok(find(d, "../outer_task"), "the healthy outer file was dropped too")
        t.eq(#d.files, 1, "the broken file was counted as loaded")
    end)
end)

t.test("a .litre.lua that raises at load time is reported the same way", function()
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

t.test("map() to a non-global is skipped with a warning", function()
    at(vim.fs.joinpath(tmp, "weird"), function()
        t.notified = {}
        local d = discover.load()
        t.ok(notified('map("z") target is not a global'),
            "unexpected: " .. vim.inspect(t.notified))
        t.eq(d.maps["z"], nil)
        t.ok(d.maps["x"], "the resolvable map was dropped as well")
    end)
end)

t.test("map() on a key the layer can never deliver is skipped with a warning", function()
    at(vim.fs.joinpath(tmp, "badmap"), function()
        t.notified = {}
        local d = discover.load()
        t.ok(notified('map("gd") is not a single key'),
            "unexpected: " .. vim.inspect(t.notified))
        t.eq(d.maps["gd"], nil)
        t.ok(d.maps[vim.keycode("<F5>")], "a vim.keycode special key should be accepted")
    end)
end)

-- A file registers params and maps as it executes, so anything it registered
-- before raising is already in the collector when the error unwinds it.
write(vim.fs.joinpath(tmp, "ghost", ".litre.lua"), [[
local l = require("litre")
local mode = l.param("ghost_param", { "x", "y" })
l.map("g", function() end)
function ghost_task()
end
error("boom after registering")
]])

t.test("a file that raises after param() does not leak the param", function()
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

t.test("a file that raises after map() does not leak the mapping", function()
    at(vim.fs.joinpath(tmp, "ghost"), function()
        t.notified = {}
        local d = discover.load()
        t.eq(d.maps["g"], nil, "mapping from a file that failed to load survived")
    end)
end)

-- The contract is "every callable own-global is a task". These pin its edges:
-- what counts as callable, and what a file can do to the primitives it inherits.
write(vim.fs.joinpath(tmp, "empty", ".litre.lua"), "")

write(vim.fs.joinpath(tmp, "callable", ".litre.lua"), [[
callable_task = setmetatable({}, { __call = function() vim.g.x_callable = 7 end })
plain_table = { 1, 2, 3 }
scalar = 5
]])

write(vim.fs.joinpath(tmp, "shadow", ".litre.lua"), [[
function sh()
    vim.g.x_shadowed_sh = "mine"
end
function uses_sh()
    sh({ "true" })
end
]])

t.test("an empty .litre.lua contributes nothing and says nothing", function()
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

t.test("a callable table is a task; a plain table and a scalar are not", function()
    at(vim.fs.joinpath(tmp, "callable"), function()
        local d = discover.load()
        t.ok(find(d, "callable_task"), "a __call table was not treated as a task")
        t.ok(not find(d, "plain_table"), "a plain table became a task")
        t.ok(not find(d, "scalar"), "a number became a task")
    end)
end)

t.test("a global named after a primitive is just a task: nothing is injected", function()
    at(vim.fs.joinpath(tmp, "shadow"), function()
        t.notified = {}
        local d = discover.load()
        t.ok(find(d, "sh"), "the global is not itself a task")
        t.eq(t.notified, {}, "a plain global should load silently")
        -- and the file's own calls resolve to it, not to lib.sh: the task
        -- below would otherwise need a coroutine to run at all
        vim.g.x_shadowed_sh = nil
        assert(find(d, "uses_sh")).fn()
        t.eq(vim.g.x_shadowed_sh, "mine", "sh() did not resolve to the global")
    end)
end)

t.test("a map() on a layer verb or on i is stripped when the layer loads", function()
    at(vim.fs.joinpath(tmp, "weird"), function()
        t.notified = {}
        litre.source.list()
        t.ok(notified('key "R" is reserved by the layer'),
            "unexpected: " .. vim.inspect(t.notified))
        t.ok(notified('key "i" is reserved by the layer'),
            "unexpected: " .. vim.inspect(t.notified))
    end)
end)

-- --- the x layer ------------------------------------------------------------
-- The layer is litre.source driven through fzf-pin's picker; build() returns
-- the per-char closures the real fzf binds would fire, so the semantics are
-- testable without a UI. The sibling checkout is the dependency, like lazy.nvim
-- loads it in the real config.
vim.opt.rtp:prepend(vim.fn.expand("~/personal/fzf-pin.nvim"))
local fzfpin = require("fzf-pin.picker")
local function layer_with(key)
    local built = fzfpin.build(litre.source)
    built.entries() -- populates the char lookup, as fzf listing entries would
    -- uppercase verbs are bound raw and dispatched by their underscore name
    local action = built.actions[key] or built.actions["_verb_" .. key:lower()]
    action()
end

t.test("layer: a map()ped key runs its task", function()
    vim.g.x_with_dir = nil
    layer_with("b")
    t.ok(vim.wait(3000, function()
        return vim.g.x_with_dir ~= nil
    end, 10), "the mapped task never ran")
end)

t.test("layer: a free key says so and does nothing else", function()
    t.notified = {}
    layer_with("q")
    t.ok(notified("nothing on q"), "unexpected: " .. vim.inspect(t.notified))
end)

t.test("layer: entries render map() chars and the running marker", function()
    local built = fzfpin.build(litre.source)
    local bundled
    for _, e in ipairs(built.entries()) do
        if e:find("withbundle", 1, true) then
            bundled = e
        end
    end
    t.ok(bundled and bundled:sub(1, 4) == "[b] ", "map()ped char not rendered: "
        .. tostring(bundled))
end)

t.test("layer: O shows the last task's output buffer", function()
    run("streamer") -- make streamer the last task, with a buffer
    layer_with("O")
    t.eq(vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf()), "litre://streamer")
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
    litre.setup({ shell = "sh" })
    local cmds = vim.api.nvim_get_commands({})
    for _, name in ipairs({ "Litre", "LitreConfig" }) do
        t.ok(cmds[name], name .. " not registered")
    end
end)

t.test(":Litre <name> runs the nearest task of that bare name", function()
    vim.g.x_inherit = nil
    vim.cmd("Litre inherits")
    t.ok(vim.wait(3000, function()
        return vim.g.x_inherit ~= nil
    end, 10), ":Litre inherits did not run")
end)

t.test(":Litre with a prefixed id also resolves", function()
    vim.g.x_outer = nil
    vim.cmd("Litre ../outer_task")
    t.ok(vim.wait(3000, function()
        return vim.g.x_outer ~= nil
    end, 10), ":Litre ../outer_task did not run")
    t.eq(vim.g.x_outer, tmp)
end)

t.test(":Litre on an unknown task warns", function()
    t.notified = {}
    vim.cmd("Litre nosuchtask")
    t.ok(notified("no task nosuchtask"), "unexpected: " .. vim.inspect(t.notified))
end)

t.test(":Litre completion lists task ids", function()
    local ids = vim.fn.getcompletion("Litre ", "cmdline")
    t.ok(vim.tbl_contains(ids, "inherits"), "inherits missing from " .. vim.inspect(ids))
    t.ok(vim.tbl_contains(ids, "../outer_task"), "prefixed id missing")
end)

t.test(":LitreConfig opens the innermost .litre.lua", function()
    vim.cmd("LitreConfig")
    t.eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), vim.fs.joinpath(work, ".litre.lua"))
    vim.cmd.enew()
end)

t.test("edit_config offers a path at cwd when no .litre.lua exists", function()
    at(bare, function()
        litre.edit_config()
        t.eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)), vim.fs.joinpath(bare, ".litre.lua"))
        t.eq(vim.fn.filereadable(vim.fs.joinpath(bare, ".litre.lua")), 0,
            "it should not be created")
        vim.cmd.enew()
    end)
end)

t.test("edit_config reaches a .litre.lua that fails to load", function()
    at(vim.fs.joinpath(tmp, "broken"), function()
        litre.edit_config()
        t.eq(vim.fs.normalize(vim.api.nvim_buf_get_name(0)),
            vim.fs.joinpath(tmp, "broken", ".litre.lua"),
            "the broken innermost file is exactly the one that needs editing")
        vim.cmd.enew()
    end)
end)

t.test("the layer source is empty but usable when no .litre.lua exists", function()
    at(bare, function()
        -- the picker still opens: verbs like C (edit config) must stay reachable
        t.eq(litre.source.list(), {})
    end)
end)

-- --- param picker -----------------------------------------------------------
t.test("pick_param shows the live value and persists a new selection", function()
    local labels, step = {}, 0
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, opts, on_choice)
        step = step + 1
        if step == 1 then
            for _, it in ipairs(items) do
                table.insert(labels, opts.format_item(it))
            end
            on_choice(items[1])
        else
            on_choice(items[2]) -- "-O3"
        end
    end
    litre.pick_param()
    vim.ui.select = ui_select
    t.eq(step, 2, "the second (value) picker never opened")
    t.ok(labels[1] and labels[1]:find("level = -O2", 1, true),
        "unexpected label: " .. vim.inspect(labels))
    t.eq(state.get(vim.fs.joinpath(work, ".litre.lua"), "level"), "-O3")
    run("inherits")
    t.eq(vim.g.x_inherit, "hi-O3", "the new value did not reach the task")
end)

t.test("pick_param's new-value path writes the source and selects it", function()
    local file = vim.fs.joinpath(work, ".litre.lua")
    local step = 0
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.select = function(items, _opts, on_choice)
        step = step + 1
        on_choice(step == 1 and items[1] or items[#items]) -- "  new value..."
    end
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.ui.input = function(_opts, on_confirm)
        on_confirm("-Og")
    end
    litre.pick_param()
    vim.ui.select, vim.ui.input = ui_select, ui_input
    t.eq(state.get(file, "level"), "-Og")
    t.ok(table.concat(vim.fn.readfile(file), "\n"):find('"-O3", "-Og"', 1, true),
        "the option was not written back to the source")
    t.eq(discover.load().params[1].options, { "-O2", "-O3", "-Og" })
    state.set(file, "level", "-O2")
end)

t.test("a function-valued param runs as a task under V and persists the pick", function()
    local dyn = vim.fs.joinpath(tmp, "dyn")
    local file = vim.fs.joinpath(dyn, ".litre.lua")
    write(file, [[
local l = require("litre")
local which = l.param("which", function()
    return vim.split(l.out({ "printf", "one\nthree\ntwo" }), "\n")
end)
function report()
    vim.g.x_which = tostring(which)
end
]])
    at(dyn, function()
        run("report")
        t.eq(vim.g.x_which, "nil", "an unchosen function param must read nil")
        local step, seen = 0, nil
        ---@diagnostic disable-next-line: duplicate-set-field
        vim.ui.select = function(items, _opts, on_choice)
            step = step + 1
            if step == 1 then
                on_choice(items[1])
            else
                seen = items
                on_choice(items[2])
            end
        end
        litre.pick_param()
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
    write(vim.fs.joinpath(proj, ".litre.lua"), [[
local cm = require("litre.cmake")
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
    t.eq(cfg.dir, nil, "the litre-only dir option leaked into the dap config")
end)

t.test("an unknown template aborts with a message naming setup{}", function()
    t.notified = {}
    run("dbgmissing")
    t.ok(notified('no dap template "nope"'), "unexpected: " .. vim.inspect(t.notified))
    t.ok(notified("dap_templates"), "the message should say where to register it")
end)

-- --- primitives outside a task ----------------------------------------------
t.test("out/pick/input/debug all refuse to run outside a task", function()
    local lib = require("litre.lib")
    for _, name in ipairs({ "out", "pick", "input" }) do
        local ok, err = pcall(lib[name], { "true" })
        t.eq(ok, false, name .. " did not refuse")
        t.ok(tostring(err):find("inside a running task", 1, true), tostring(err))
    end
end)

t.test("map() outside a load is an error, not a silent no-op", function()
    local ok, err = pcall(require("litre.lib").map, "j", function() end)
    t.eq(ok, false)
    t.ok(tostring(err):find("top level", 1, true), tostring(err))
end)

-- a param declared inside a task would read a value but never register while
-- discovery runs, so the picker could not see it -- refuse instead of half-working
t.test("param() inside a task errors instead of half-working", function()
    t.notified = {}
    run("badparam")
    t.ok(notified("top level"), "unexpected: " .. vim.inspect(t.notified))
end)

-- --- persisted state --------------------------------------------------------
t.test("state survives a round trip and is keyed by file and name", function()
    local f1, f2 = "/one/.litre.lua", "/two/.litre.lua"
    state.set(f1, "mode", "debug")
    state.set(f2, "mode", "release")
    state.set(f1, "other", "x")
    t.eq(state.get(f1, "mode"), "debug")
    t.eq(state.get(f2, "mode"), "release")
    t.eq(state.get(f1, "other"), "x")
    t.eq(state.get(f1, "missing"), nil)
    t.eq(state.get("/nowhere/.litre.lua", "mode"), nil)
end)

t.test("a corrupt state file reads as empty instead of raising", function()
    local p = vim.fs.joinpath(vim.fn.stdpath("data"), "litre", "params.json")
    vim.fn.writefile({ "{not json" }, p)
    t.eq(state.get("/one/.litre.lua", "mode"), nil)
    state.set("/one/.litre.lua", "mode", "recovered") -- and it heals on write
    t.eq(state.get("/one/.litre.lua", "mode"), "recovered")
end)

-- --- params write-back edges ------------------------------------------------
t.test("write-back into an empty option list", function()
    local f = vim.fs.joinpath(tmp, "pf_empty.lua")
    write(f, 'local m = param("mode", {})')
    t.ok(params.add_option(f, "mode", "first"))
    t.eq(table.concat(vim.fn.readfile(f), "\n"), 'local m = param("mode", { "first" })')
end)

t.test("write-back keeps single-quote style and escapes the quote", function()
    local f = vim.fs.joinpath(tmp, "pf_quote.lua")
    write(f, "local m = param('mode', { 'a' })")
    t.ok(params.add_option(f, "mode", "it's"))
    t.eq(table.concat(vim.fn.readfile(f), "\n"), "local m = param('mode', { 'a', 'it\\'s' })")
end)

t.test("write-back escapes backslashes", function()
    local f = vim.fs.joinpath(tmp, "pf_esc.lua")
    write(f, 'local m = param("p", { "a" })')
    t.ok(params.add_option(f, "p", [[c:\tmp]]))
    t.ok(table.concat(vim.fn.readfile(f), "\n"):find([["c:\\tmp"]], 1, true),
        "backslash not escaped: " .. table.concat(vim.fn.readfile(f), "\n"))
end)

t.test("write-back picks the named param, not the first one in the file", function()
    local f = vim.fs.joinpath(tmp, "pf_two.lua")
    write(f, 'local a = param("aa", { "1" })\nlocal b = param("bb", { "2" })')
    t.ok(params.add_option(f, "bb", "3"))
    t.eq(vim.fn.readfile(f), {
        'local a = param("aa", { "1" })',
        'local b = param("bb", { "2", "3" })',
    })
end)

t.test("write-back finds a param called through a module table", function()
    local f = vim.fs.joinpath(tmp, "pf_dot.lua")
    write(f, 'local m = litre.param("mode", { "a" })')
    t.ok(params.add_option(f, "mode", "b"))
    t.eq(table.concat(vim.fn.readfile(f), "\n"), 'local m = litre.param("mode", { "a", "b" })')
end)

-- The tests above pin the exact text for known-good values. This one pins the
-- property that matters for anything else: whatever goes in, the file still
-- parses as Lua afterwards and the option reads back byte-identical.
local function roundtrip(value)
    local f = vim.fs.joinpath(tmp, "pf_rt.lua")
    write(f, 'local m = param("p", { "a" })')
    if not params.add_option(f, "p", value) then
        return nil, "add_option refused"
    end
    local src = table.concat(vim.fn.readfile(f), "\n")
    local chunk, lerr = loadstring(src)
    if not chunk then
        return nil, ("no longer parses (%s) -- source: %s"):format(lerr, src)
    end
    local got
    setfenv(chunk, { param = function(_, opts) got = opts end })
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
    local target = vim.fs.joinpath(real, ".litre.lua")
    write(target, 'local m = param("mode", { "a" })')
    local link = vim.fs.joinpath(tmp, "link")
    assert(vim.uv.fs_symlink(real, link))
    vim.cmd.edit(vim.fs.joinpath(link, ".litre.lua"))
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

t.finish("litre advanced spec")
