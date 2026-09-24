-- Offline end-to-end suite: builds a temp project tree with nested .litre.lua
-- files and drives discovery, the runner, both shell colors, params (state +
-- source write-back) and the dap merge -- on a bare `nvim --clean -l`.
-- run.sh points XDG_DATA_HOME at a temp dir so param state stays isolated.
local t = dofile((debug.getinfo(1, "S").source:sub(2)):gsub("spec%.lua$", "harness.lua"))
vim.opt.rtp:prepend(t.root())
t.quiet()

-- one wait to rule the async: a task is done when its coroutine died
local function wait_done(task)
    return vim.wait(5000, function()
        return task.co ~= nil and coroutine.status(task.co) == "dead"
    end, 10)
end

local function find(d, id)
    for _, task in ipairs(d.tasks) do
        if task.id == id then
            return task
        end
    end
end

-- --- fixture tree -----------------------------------------------------------
local tmp = vim.fn.tempname()
vim.fn.mkdir(vim.fs.joinpath(tmp, "sub"), "p")
-- realpath: on this box /var/tmp is a symlink and getcwd() reports resolved paths
tmp = assert(vim.uv.fs_realpath(tmp))
local inner = vim.fs.joinpath(tmp, "sub")

local outer_file = vim.fs.joinpath(tmp, ".litre.lua")
local inner_file = vim.fs.joinpath(inner, ".litre.lua")

vim.fn.writefile(vim.split([[
greeting = "hello"
function outer_task()
    vim.g.litre_outer = 1
end
local function hidden()
end
hidden()
]], "\n"), outer_file)

vim.fn.writefile(vim.split([[
local l = require("litre")
local level = l.param("level", { "-O2", "-O3" })
function build()
    vim.g.litre_result = greeting .. level
end
l.map("b", build)
capture = l.cmd({ "echo", "hehe" })
function compose()
    vim.g.litre_compose = "haha" .. capture()
end
function stream()
    l.sh({ "printf", "x\ny\n" })
end
function boom()
    l.sh({ "false" })
end
function soft()
    vim.g.litre_soft = l.sh({ "false" }, { check = false })
end
function sleepy()
    l.sh({ "sleep", "100" })
    vim.g.litre_sleepy_done = 1
end
function feed()
    vim.g.litre_fed = l.out({ "cat" }, { stdin = "picked-b" })
end
function where()
    vim.g.litre_where = l.out({ "pwd" })
    vim.g.litre_where_up = l.out({ "pwd" }, { dir = ".." })
end
function dbg()
    l.debug("tpl", { program = "bin/app", args = { "-x" } })
end
]], "\n"), inner_file)

vim.cmd.cd(inner)

local discover = require("litre.discover")
local runner = require("litre.runner")
local state = require("litre.state")

-- --- discovery --------------------------------------------------------------
t.test("finds both files, outermost first", function()
    local dirs, cwd = discover.files()
    t.eq(dirs, { vim.fs.normalize(tmp), vim.fs.normalize(inner) })
    t.eq(cwd, vim.fs.normalize(inner))
end)

local d = discover.load()

t.test("inner tasks unprefixed, outer prefixed with relative path", function()
    t.ok(find(d, "build"), "build missing")
    t.ok(find(d, "../outer_task"), "../outer_task missing")
end)

t.test("locals are private", function()
    t.eq(find(d, "hidden"), nil)
    t.eq(find(d, "../hidden"), nil)
end)

t.test("cmd values are tasks too", function()
    t.ok(find(d, "capture"), "capture missing")
end)

t.test("tasks sort innermost first", function()
    t.ok(d.tasks[1].dir == vim.fs.normalize(inner), "first task not from inner file")
end)

t.test("map() resolves to the global's task", function()
    t.ok(d.maps["b"], "map b missing")
    t.eq(d.maps["b"].id, "build")
end)

t.test("params registered", function()
    t.eq(#d.params, 1)
    t.eq(d.params[1].name, "level")
    t.eq(d.params[1].options, { "-O2", "-O3" })
    t.eq(d.params[1].file, vim.fs.joinpath(vim.fs.normalize(inner), ".litre.lua"))
end)

-- --- runner + env nesting + params ------------------------------------------
t.test("inner file reads outer env; param defaults to first option", function()
    local task = find(d, "build")
    runner.run(task)
    t.ok(wait_done(task), "build did not finish")
    t.eq(vim.g.litre_result, "hello-O2")
end)

t.test("persisted param value wins on the next load", function()
    state.set(d.params[1].file, "level", "-O3")
    local d2 = discover.load()
    local task = find(d2, "build")
    runner.run(task)
    t.ok(wait_done(task), "build did not finish")
    t.eq(vim.g.litre_result, "hello-O3")
end)

-- --- shell colors -----------------------------------------------------------
t.test("out() captures trimmed stdout; compose via cmd()", function()
    local task = find(d, "compose")
    runner.run(task)
    t.ok(wait_done(task), "compose did not finish")
    t.eq(vim.g.litre_compose, "hahahehe")
end)

t.test("out() dir option resolves relative to the .litre.lua", function()
    local task = find(d, "where")
    runner.run(task)
    t.ok(wait_done(task), "where did not finish")
    t.eq(vim.g.litre_where, vim.fs.normalize(inner))
    t.eq(vim.g.litre_where_up, vim.fs.normalize(tmp))
end)

t.test("opts.stdin feeds the command's standard input", function()
    local task = find(d, "feed")
    runner.run(task)
    t.ok(wait_done(task), "feed did not finish")
    t.eq(vim.g.litre_fed, "picked-b")
end)

t.test("sh() streams into a litre:// terminal buffer with exit marker", function()
    local task = find(d, "stream")
    runner.run(task)
    t.ok(wait_done(task), "stream did not finish")
    local buf = require("litre.term").buf("stream")
    t.ok(buf, "no output buffer")
    t.ok(vim.wait(3000, function()
        local text = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
        return text:find("x", 1, true) and text:find("[exit 0]", 1, true)
    end, 10), "buffer never showed output + exit marker")
    t.eq(vim.api.nvim_buf_get_name(buf), "litre://stream")
end)

t.test("re-run replaces the buffer under the same name", function()
    local before = require("litre.term").buf("stream")
    local task = find(discover.load(), "stream")
    runner.run(task)
    t.ok(wait_done(task), "second stream did not finish")
    local after = require("litre.term").buf("stream")
    t.ok(after and after ~= before, "buffer was not replaced")
    t.eq(vim.api.nvim_buf_get_name(after), "litre://stream")
    t.eq(vim.api.nvim_buf_is_valid(before), false)
end)

-- --- error semantics --------------------------------------------------------
t.test("nonzero exit aborts the task with a clean notification", function()
    t.notified = {}
    local task = find(d, "boom")
    runner.run(task)
    t.ok(wait_done(task), "boom did not finish")
    t.ok(vim.wait(1000, function()
        return #t.notified > 0
    end, 10), "no notification")
    t.ok(t.notified[#t.notified]:find("command failed (exit 1)", 1, true),
        "unexpected message: " .. (t.notified[#t.notified] or "nil"))
end)

t.test("check = false returns the code instead", function()
    t.notified = {}
    local task = find(d, "soft")
    runner.run(task)
    t.ok(wait_done(task), "soft did not finish")
    t.eq(vim.g.litre_soft, 1)
    t.eq(#t.notified, 0, "unexpected notification")
end)

-- --- kill -------------------------------------------------------------------
t.test("kill interrupts a running sh(); the task aborts as interrupted", function()
    local task = find(d, "sleepy")
    runner.run(task)
    t.ok(vim.wait(2000, function()
        return task.proc ~= nil
    end, 10), "sh never exposed its process")
    t.eq(#runner.running_tasks(), 1)
    t.eq(runner.running_tasks()[1].id, "sleepy")
    t.notified = {}
    runner.kill(task)
    t.ok(wait_done(task), "kill did not end the task")
    t.eq(vim.g.litre_sleepy_done, nil, "task ran past the killed command")
    t.ok(vim.wait(1000, function()
        return #t.notified > 0
    end, 10), "no notification")
    t.ok(t.notified[#t.notified]:find("interrupted", 1, true),
        "unexpected message: " .. (t.notified[#t.notified] or "nil"))
    t.eq(#runner.running_tasks(), 0)
end)

t.test("a killed task can be re-run at once", function()
    local task = find(discover.load(), "sleepy")
    t.notified = {}
    runner.run(task)
    t.eq(#t.notified, 0, "still counted as running: " .. (t.notified[1] or ""))
    t.ok(vim.wait(2000, function()
        return task.proc ~= nil
    end, 10), "second run never started its process")
    runner.kill(task)
    t.ok(wait_done(task), "second kill did not end the task")
end)

t.test("sh() outside a task errors clearly", function()
    local ok, err = pcall(require("litre.lib").sh, { "true" })
    t.eq(ok, false)
    t.ok(tostring(err):find("inside a running task", 1, true), tostring(err))
end)

-- --- dap template merge -----------------------------------------------------
t.test("debug() merges template + overrides, resolves program and cwd", function()
    require("litre.config").setup({
        dap_templates = { tpl = { type = "gdb", request = "launch" } },
    })
    package.loaded["dap"] = {
        run = function(cfg)
            vim.g.litre_dap = cfg
        end,
    }
    local task = find(d, "dbg")
    runner.run(task)
    t.ok(wait_done(task), "dbg did not finish")
    local cfg = vim.g.litre_dap
    t.eq(cfg.type, "gdb")
    t.eq(cfg.request, "launch")
    t.eq(cfg.name, "tpl")
    t.eq(cfg.args, { "-x" })
    t.eq(cfg.program, vim.fs.joinpath(vim.fs.normalize(inner), "bin/app"))
    t.eq(cfg.cwd, vim.fs.normalize(inner))
end)

-- --- param write-back -------------------------------------------------------
local params = require("litre.params")

t.test("write-back appends to a single-line literal list on disk", function()
    t.ok(params.add_option(inner_file, "level", "-O0"))
    local text = table.concat(vim.fn.readfile(inner_file), "\n")
    t.ok(text:find('{ "-O2", "-O3", "-O0" }', 1, true), "not appended: " .. text:sub(1, 80))
    local d2 = discover.load()
    t.eq(d2.params[1].options, { "-O2", "-O3", "-O0" })
end)

t.test("write-back appends to a multiline list", function()
    local multi = vim.fs.joinpath(tmp, "multi", ".litre.lua")
    vim.fn.mkdir(vim.fs.dirname(multi), "p")
    vim.fn.writefile(vim.split([[
local l = require("litre")
local mode = l.param("mode", {
    "debug",
    "release",
})
]], "\n"), multi)
    t.ok(params.add_option(multi, "mode", "asan"))
    local text = table.concat(vim.fn.readfile(multi), "\n")
    t.ok(text:find('"release", "asan"', 1, true), "not appended: " .. text)
end)

t.test("write-back through a loaded buffer keeps its unsaved edits", function()
    vim.cmd.edit(inner_file)
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, 0, true, { "-- unsaved comment" })
    t.ok(params.add_option(inner_file, "level", "-Os"))
    local text = table.concat(vim.fn.readfile(inner_file), "\n")
    t.ok(text:find("-- unsaved comment", 1, true), "buffer edit lost")
    t.ok(text:find('"-O0", "-Os" }', 1, true), "option not appended: " .. text:sub(1, 120))
    t.eq(vim.bo[buf].modified, false, "buffer left unsaved")
end)

t.test("write-back on a computed list fails with a message, not an edit", function()
    local comp = vim.fs.joinpath(tmp, "comp", ".litre.lua")
    vim.fn.mkdir(vim.fs.dirname(comp), "p")
    vim.fn.writefile(vim.split([[
local l = require("litre")
local opts = vim.split("a,b", ",")
local mode = l.param("mode", opts)
]], "\n"), comp)
    t.notified = {}
    t.eq(params.add_option(comp, "mode", "c"), false)
    t.ok(#t.notified > 0 and t.notified[1]:find("no literal option list", 1, true),
        "expected a clear error")
end)

t.finish("litre spec")
