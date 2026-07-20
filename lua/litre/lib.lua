-- The .litre.lua standard library, injected as globals into every file's env.
--
-- Modelled on Go's os/exec: there is no ambient shell state -- no cd, no
-- exported variables. A command carries its own dir/env, and running it
-- mutates nothing outside itself. Default dir is the directory of the
-- .litre.lua that defines the task.
--
-- Two colors of shell call, deliberately two functions:
--   sh(cmd, opts)   streams into the task's litre:// buffer, returns exit code
--   out(cmd, opts)  captures silently, returns trimmed stdout ($(...) analogue)
-- Both raise on nonzero exit unless { check = false }: chains read as
-- `build(); run()` and stop at the first failure, set -e style.
--
-- cmd is a string -> `<config.shell> -c` runs it (pipes, $VAR, globs work);
-- cmd is a table  -> direct argv, no shell, no quoting pitfalls.
local config = require("litre.config")
local runner = require("litre.runner")
local state = require("litre.state")
local term = require("litre.term")

local M = {}

local function argv(c)
    if type(c) == "table" then
        return c
    end
    return { config.opts.shell, "-c", c }
end

local function display(c)
    return type(c) == "table" and table.concat(c, " ") or c
end

-- opts.dir resolves against the defining .litre.lua's directory, absolute
-- paths pass through; nil means that directory itself.
local function resolve_dir(ctx, opts)
    local d = opts and opts.dir
    if not d or d == "" then
        return ctx.dir
    end
    d = vim.fs.normalize(d)
    if d:sub(1, 1) == "/" then
        return d
    end
    return vim.fs.joinpath(ctx.dir, d)
end

function M.sh(c, opts)
    opts = opts or {}
    local ctx = runner.ctx("sh")
    local dir = resolve_dir(ctx, opts)
    if not ctx.chan then
        ctx.chan = term.open(ctx.id)
    end
    local chan = ctx.chan
    term.send(chan, ("\27[1m$ %s\27[0m  [%s]\r\n"):format(display(c), vim.fn.fnamemodify(dir, ":~")))
    local ok, proc = pcall(vim.system, argv(c), {
        cwd = dir,
        env = opts.env,
        stdin = opts.stdin,
        pty = true,
        stdout = function(_, data)
            if data then
                vim.schedule(function()
                    term.send(chan, data)
                end)
            end
        end,
    }, function(res)
        vim.schedule(function()
            term.send(chan, ("\27[1m[exit %d]\27[0m\r\n"):format(res.code))
            runner.resume(ctx, res.code)
        end)
    end)
    if not ok then
        -- spawn failure (no such binary, bad dir): vim.system throws sync
        runner.abort(("cannot run %s: %s"):format(display(c), proc))
    end
    ctx.proc = proc
    local code = coroutine.yield()
    ctx.proc = nil
    if ctx.killed then
        runner.abort("interrupted: " .. display(c))
    end
    if code ~= 0 and opts.check ~= false then
        runner.abort(("command failed (exit %d): %s"):format(code, display(c)))
    end
    return code
end

function M.out(c, opts)
    opts = opts or {}
    local ctx = runner.ctx("out")
    local dir = resolve_dir(ctx, opts)
    local ok, proc = pcall(vim.system, argv(c),
        { cwd = dir, env = opts.env, stdin = opts.stdin, text = true },
        function(res)
            vim.schedule(function()
                runner.resume(ctx, res)
            end)
        end)
    if not ok then
        runner.abort(("cannot run %s: %s"):format(display(c), proc))
    end
    ctx.proc = proc
    local res = coroutine.yield()
    ctx.proc = nil
    if ctx.killed then
        runner.abort("interrupted: " .. display(c))
    end
    if res.code ~= 0 and opts.check ~= false then
        runner.abort(("command failed (exit %d): %s\n%s"):format(
            res.code, display(c), vim.trim(res.stderr or "")))
    end
    local stdout = (res.stdout or ""):gsub("%s+$", "")
    return stdout, res.code
end

-- `cmd "echo hehe"` -- the closest Lua gets to a callable command string.
-- Calling the value captures (so `foo() .. bar()` composition reads like
-- command substitution); invoking it as a task from the picker streams
-- (runner.run special-cases these via as_cmd).
M.CMD = {}
M.CMD.__index = M.CMD
M.CMD.__call = function(self)
    return M.out(self.cmd, self.opts)
end

function M.cmd(c, opts)
    return setmetatable({ cmd = c, opts = opts }, M.CMD)
end

function M.as_cmd(v)
    if type(v) == "table" and getmetatable(v) == M.CMD then
        return v
    end
    return nil
end

-- Immutable defaults bundle -- the os/exec answer to `cd`. Per-call opts win.
--   local b = env { dir = "build" }
--   b.sh("cmake --build .")
function M.env(defaults)
    local function merge(opts)
        return vim.tbl_extend("keep", opts or {}, defaults or {})
    end
    return {
        sh = function(c, opts)
            return M.sh(c, merge(opts))
        end,
        out = function(c, opts)
            return M.out(c, merge(opts))
        end,
        cmd = function(c, opts)
            return M.cmd(c, merge(opts))
        end,
    }
end

-- vim.ui.select through the coroutine. The stock implementation calls back
-- synchronously; fzf-lua does not -- handle both (same dance as the dap
-- config's input()).
function M.pick(items, opts)
    local ctx = runner.ctx("pick")
    local value, returned = nil, false
    vim.ui.select(items, opts or {}, function(choice)
        value, returned = choice, true
        if coroutine.status(ctx.co) == "suspended" then
            runner.resume(ctx, choice)
        end
    end)
    if returned then
        return value
    end
    return coroutine.yield()
end

function M.input(opts)
    local ctx = runner.ctx("input")
    if type(opts) == "string" then
        opts = { prompt = opts }
    end
    local value, returned = nil, false
    vim.ui.input(opts or {}, function(v)
        value, returned = v, true
        if coroutine.status(ctx.co) == "suspended" then
            runner.resume(ctx, v)
        end
    end)
    if returned then
        return value
    end
    return coroutine.yield()
end

-- Declared at .litre.lua top level; returns the persisted selection (or the
-- first option). Selection UI and source write-back live in litre.params.
function M.param(name, options)
    local discover = require("litre.discover")
    local file = discover.loading or (runner.current and runner.current.file)
    if not file then
        error("param() belongs at .litre.lua top level", 2)
    end
    discover.register_param(file, name, options)
    local v = state.get(file, name)
    if v ~= nil then
        return v
    end
    return options[1]
end

-- Machine-side base named `template` (setup{ dap_templates }), project-side
-- overrides; merges and dap.run()s. Relative program resolves like dir does.
function M.debug(template, overrides)
    local ctx = runner.ctx("debug")
    local base = config.opts.dap_templates[template]
    if not base then
        runner.abort(("no dap template %q -- register it in setup{ dap_templates }"):format(template))
    end
    overrides = overrides or {}
    local cfg
    if type(base) == "function" then
        cfg = base(overrides)
    else
        cfg = vim.tbl_deep_extend("force", vim.deepcopy(base), overrides)
    end
    cfg.dir = nil -- litre option, not a dap field
    cfg.name = cfg.name or template
    if type(cfg.program) == "string" and cfg.program:sub(1, 1) ~= "/" then
        cfg.program = vim.fs.joinpath(resolve_dir(ctx, overrides), cfg.program)
    end
    cfg.cwd = cfg.cwd or resolve_dir(ctx, overrides)
    require("dap").run(cfg)
end

-- x-layer key for a task, declared next to the task itself. Discovery
-- resolves the function back to its global name.
function M.map(key, fn)
    local discover = require("litre.discover")
    if not discover.loading then
        error("map() belongs at .litre.lua top level", 2)
    end
    discover.register_map(key, fn)
end

return M
