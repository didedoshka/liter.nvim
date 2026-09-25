-- The .liter.lua standard library, re-exported by require("liter") -- files
-- reach it as `l.command` etc. The annotations here are what lua-ls shows there.
--
-- Modelled on Go's os/exec: there is no ambient shell state -- no cd, no
-- exported variables. `command(c, opts)` is a value that runs nothing until
-- `:run(mode)`, carries its own dir/env, and running it mutates nothing
-- outside itself. Default dir is the directory of the .liter.lua that
-- defines the task. Two modes, one verb (pytest's words):
--   :run()           "live": pty into the task's liter:// buffer, returns exit code
--   :run("captured") pipes, returns trimmed stdout and the code ($(...) analogue)
-- Both raise on nonzero exit unless { check = false }: chains read as
-- `Build(); Run()` and stop at the first failure, set -e style.
--
-- c is a string -> `<config.shell> -c` runs it (pipes, $VAR, globs work);
-- c is a table  -> direct argv, no shell, no quoting pitfalls.
local config = require("liter.config")
local runner = require("liter.runner")
local state = require("liter.state")
local term = require("liter.term")

local M = {}

---@class liter.Opts
---@field dir? string relative to the defining .liter.lua's directory (the default); absolute passes through
---@field env? table<string, string> extra environment variables for the command
---@field check? boolean false: return the exit code instead of raising on nonzero
---@field stdin? string|string[] feed standard input; runs on plain pipes, not the pty

---@class liter.With a defaults bundle: `command` with the bundle's opts merged in
---@field command fun(c: string|string[], opts?: liter.Opts): liter.Command
---@field with fun(more?: liter.Opts): liter.With a new bundle with `more` merged on top

local function argv(c)
    if type(c) == "table" then
        return c
    end
    return { config.opts.shell, "-c", c }
end

local function display(c)
    return type(c) == "table" and table.concat(c, " ") or c
end

-- opts.dir resolves against the defining .liter.lua's directory, absolute
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

-- A live run is on a real pty via jobstart: the program sees a tty on every
-- fd (stderr is merged into the pty), so ya/cmake/git color and draw
-- progress bars as in a terminal. vim.system cannot do this -- it has no pty
-- support at all, any `pty = true` is silently ignored and every fd is a
-- plain pipe (measured; why v2 streamed monochrome).
-- opts.stdin is the exception and takes a vim.system pipe path: a pty cannot
-- deliver EOF (a stdin-fed `wc -l` hangs forever, measured) and echoes the
-- fed input back into the output. Filters get pipes; terminals get the pty.
---@param c string|string[]
---@param opts liter.Opts
---@return integer code
local function run_live(c, opts)
    local ctx = runner.ctx("run")
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

---@param c string|string[]
---@param opts liter.Opts
---@return string stdout trimmed
---@return integer code
local function run_captured(c, opts)
    local ctx = runner.ctx("run")
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

---@class liter.Command a command and its options; runs nothing until :run()
---@field cmd string|string[] shell string (`<shell> -c`) or argv table (no shell)
---@field opts liter.Opts
local Command = {}
Command.__index = Command

-- "live" (default): on a pty into the task's liter:// buffer, returns the
-- exit code. "captured": on pipes, nothing shown, returns trimmed stdout and
-- the code. Nonzero exit raises either way unless opts.check == false.
---@param mode? "live"
---@return integer code
---@overload fun(self: liter.Command, mode: "captured"): string, integer
function Command:run(mode)
    mode = mode or "live"
    if mode == "live" then
        -- lua-ls checks this branch against the overload's two returns too
        ---@diagnostic disable-next-line: return-type-mismatch
        return run_live(self.cmd, self.opts)
    elseif mode == "captured" then
        return run_captured(self.cmd, self.opts)
    end
    error(('run: mode must be "live" or "captured", got %s'):format(vim.inspect(mode)), 2)
end

-- A plain table: `cmd` and `opts` are public, so a helper can derive a new
-- command from one it is handed (a wrapper adds env, a retry re-runs it).
---@param c string|string[] shell string (`<shell> -c`) or argv table (no shell)
---@param opts? liter.Opts
---@return liter.Command
function M.command(c, opts)
    return setmetatable({ cmd = c, opts = opts or {} }, Command)
end

-- Immutable defaults bundle -- the os/exec answer to `cd`. Stackable: b.with
-- returns a new bundle with more defaults on top. The closer setting wins key
-- by key (a per-call dir replaces the bundle's, it does not append to it);
-- `env` is the exception, its variables accumulate through the stack.
--   local b = l.with { dir = "build" }
--   b.command("cmake --build ."):run()
--   b.with({ env = { ASAN_OPTIONS = "detect_leaks=0" } }).command("./main"):run()
---@param defaults? liter.Opts
---@return liter.With
function M.with(defaults)
    defaults = defaults or {}
    local function merge(opts)
        opts = opts or {}
        local merged = vim.tbl_extend("keep", opts, defaults)
        if opts.env and defaults.env then
            merged.env = vim.tbl_extend("keep", opts.env, defaults.env)
        end
        return merged
    end
    return {
        command = function(c, opts)
            return M.command(c, merge(opts))
        end,
        with = function(more)
            return M.with(merge(more))
        end,
    }
end

-- vim.ui.select through the coroutine. The stock implementation calls back
-- synchronously; fzf-lua does not -- handle both (same dance as the dap
-- config's input()).
---@generic T
---@param items T[]
---@param opts? table vim.ui.select options (prompt, format_item)
---@return T? choice nil when cancelled
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

-- vim.ui.input through the coroutine, the same dance as pick.
---@param prompt string
---@param opts? table further vim.ui.input options (default, completion)
---@return string? answer nil when cancelled
function M.ask(prompt, opts)
    local ctx = runner.ctx("ask")
    opts = vim.tbl_extend("force", opts or {}, { prompt = prompt })
    local value, returned = nil, false
    vim.ui.input(opts, function(v)
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

-- Declared at .liter.lua top level; returns the persisted selection (or the
-- first option). Selection UI and source write-back live in liter.params.
-- Top level ONLY: a param declared inside a task would read a value but never
-- register while discovery runs, so the picker could not see it -- a trap.
--
-- A function instead of a list is not called here (top level runs on every
-- load): the V picker runs it as a task, so it may run/pick like any task
-- body, and picks from what it returns. No first option then -- nil until a
-- value has been chosen once.
---@param name string
---@param options string[]|fun(): string[] a literal list: the picker's "new value..." writes into it
---@return string? value the persisted selection, else options[1] (nil for a function)
function M.parameter(name, options)
    local discover = require("liter.discover")
    local file = discover.loading
    if not file then
        error("parameter() belongs at .liter.lua top level", 2)
    end
    discover.register_param(file, name, options)
    local v = state.get(file, name)
    if v ~= nil then
        return v
    end
    if type(options) == "function" then
        return nil
    end
    return options[1]
end

-- Machine-side base named `template` (setup{ dap_templates }), project-side
-- overrides; merges and dap.run()s. Relative program resolves like dir does.
---@param template string a key of setup{ dap_templates }
---@param overrides? table dap fields plus `dir`
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
    cfg.dir = nil -- liter option, not a dap field
    cfg.name = cfg.name or template
    if type(cfg.program) == "string" and cfg.program:sub(1, 1) ~= "/" then
        cfg.program = vim.fs.joinpath(resolve_dir(ctx, overrides), cfg.program)
    end
    cfg.cwd = cfg.cwd or resolve_dir(ctx, overrides)
    require("dap").run(cfg)
end

-- x-layer key for a task, declared next to the task itself. Discovery
-- resolves the function back to its global name.
---@param key string one typable key; vim.keycode() for specials
---@param fn function a global task of this file
function M.map(key, fn)
    local discover = require("liter.discover")
    if not discover.loading then
        error("map() belongs at .liter.lua top level", 2)
    end
    discover.register_map(key, fn)
end

return M
