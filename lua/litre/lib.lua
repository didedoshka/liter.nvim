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

-- sh runs the command on a real pty via jobstart: the program sees a tty on
-- every fd (stderr is merged into the pty), so ya/cmake/git color and draw
-- progress bars as in a terminal. vim.system cannot do this -- it has no pty
-- support at all, any `pty = true` is silently ignored and every fd is a
-- plain pipe (measured; why v2 streamed monochrome).
-- opts.stdin is the exception and takes a vim.system pipe path: a pty cannot
-- deliver EOF (a stdin-fed `wc -l` hangs forever, measured) and echoes the
-- fed input back into the output. Filters get pipes; terminals get the pty.
function M.sh(c, opts)
    opts = opts or {}
    local ctx = runner.ctx("sh")
    local dir = resolve_dir(ctx, opts)
    -- term.buf() check: a :bd!'d output buffer takes its channel with it, and
    -- the rest of the task would otherwise stream into the void
    if not ctx.chan or not term.buf(ctx.id) then
        ctx.chan = term.open(ctx.id)
    end
    local chan = ctx.chan
    term.send(chan, ("\27[1m$ %s\27[0m  [%s]\r\n"):format(display(c), vim.fn.fnamemodify(dir, ":~")))
    local function finish(code)
        term.send(chan, ("\27[1m[exit %d]\27[0m\r\n"):format(code))
        runner.resume(ctx, code)
    end
    if opts.stdin then
        local ok, proc = pcall(vim.system, argv(c), {
            cwd = dir,
            env = opts.env,
            stdin = opts.stdin,
            -- pipes never went through a pty: convert bare \n for the terminal
            stdout = function(_, data)
                if data then
                    vim.schedule(function()
                        term.send(chan, (data:gsub("\r?\n", "\r\n")))
                    end)
                end
            end,
            stderr = function(_, data)
                if data then
                    vim.schedule(function()
                        term.send(chan, (data:gsub("\r?\n", "\r\n")))
                    end)
                end
            end,
        }, function(res)
            vim.schedule(function()
                finish(res.code)
            end)
        end)
        if not ok then
            -- spawn failure (no such binary, bad dir): vim.system throws sync
            runner.abort(("cannot run %s: %s"):format(display(c), proc))
        end
        ctx.proc = proc
    else
        local win = vim.fn.win_findbuf(term.buf(ctx.id))[1]
        -- size the pty to the window's *text area*: the emulator is textoff
        -- columns narrower than the window (number column), and a progress
        -- line padded to full window width wraps there, so \r overwrites only
        -- the wrapped tail and every repaint stacks a new line (measured)
        local ok, job = pcall(vim.fn.jobstart, argv(c), {
            cwd = dir,
            env = opts.env,
            pty = true,
            width = win and (vim.api.nvim_win_get_width(win) - vim.fn.getwininfo(win)[1].textoff)
                or 80,
            height = win and vim.api.nvim_win_get_height(win) or 24,
            -- data is the raw stream split on \n; concat restores it (\r kept)
            on_stdout = function(_, data)
                term.send(chan, table.concat(data, "\n"))
            end,
            on_exit = function(_, code)
                finish(code)
            end,
        })
        if not ok then
            -- spawn failure (no such binary, bad dir): jobstart throws sync
            runner.abort(("cannot run %s: %s"):format(display(c), job))
        end
        local pid = vim.fn.jobpid(job)
        local started = vim.uv.now()
        ctx.proc = {
            -- signalling a pty job before its fork/exec completes can hit a
            -- forked child still wearing nvim's signal handlers and take the
            -- whole editor down (measured on 0.13-dev, ~50% of immediate
            -- kills; jobstop races identically) -- so a kill inside the
            -- first 200ms is deferred past that window
            kill = function(_, sig)
                local grace = 200 - (vim.uv.now() - started)
                if grace > 0 then
                    vim.defer_fn(function()
                        pcall(vim.uv.kill, pid, sig)
                    end, grace)
                else
                    vim.uv.kill(pid, sig)
                end
            end,
        }
    end
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
-- Top level ONLY: a param declared inside a task would read a value but never
-- register while discovery runs, so the picker could not see it -- a trap.
function M.param(name, options)
    local discover = require("litre.discover")
    local file = discover.loading
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
