-- Runs tasks inside coroutines so primitives can wait without callback
-- pyramids. Every resume goes through M.resume, which pins M.current for the
-- duration of the slice: primitives read it to find the task they belong to,
-- and it stays correct even while several tasks sit suspended at once.
--
-- This is the answer to function color: any plain Lua function called from a
-- task can use run()/pick() -- the yield propagates through it invisibly.
-- The one rule bought with that: task functions only run through M.run.

---@class litre.Task
---@field id string task id shown in the picker ("build", "../deploy", ...)
---@field name string bare name inside its file
---@field fn function the task function from the .litre.lua env
---@field dir string directory of the defining .litre.lua
---@field file string path of the defining .litre.lua
---@field co? thread
---@field chan? integer terminal channel of this run's output buffer
---@field proc? { kill: fun(self, signal: string|integer) } process this run waits on (vim.system handle or sh's pty-job wrapper)
---@field killed? boolean set by M.kill; run turns the exit into "interrupted"

local M = {}

M.current = nil ---@type litre.Task|nil
M.last = nil ---@type litre.Task|nil last started task, for re-run and output
local running = {} ---@type table<string, litre.Task> id -> task while its coroutine is alive

-- run raises this on nonzero exit so failures abort the task with a clean
-- message instead of a traceback.
local ABORT = {}

function M.abort(msg)
    error(setmetatable({ msg = msg }, ABORT), 0)
end

function M.resume(task, ...)
    local prev = M.current
    M.current = task
    local ok, err = coroutine.resume(task.co, ...)
    M.current = prev
    if coroutine.status(task.co) == "dead" then
        running[task.id] = nil
    end
    if not ok then
        running[task.id] = nil
        local msg = getmetatable(err) == ABORT and err.msg or tostring(err)
        vim.notify(("litre %s: %s"):format(task.id, msg), vim.log.levels.ERROR)
    end
end

---@param task litre.Task
function M.run(task)
    if running[task.id] then
        vim.notify("litre: " .. task.id .. " is already running -- ctrl-c in its buffer kills it",
            vim.log.levels.WARN)
        return
    end
    running[task.id] = task
    M.last = task
    task.chan = nil -- each run gets a fresh output buffer on the first live run()
    task.proc, task.killed = nil, nil
    task.co = coroutine.create(task.fn)
    M.resume(task)
end

---Running tasks, stable order (the layer's running markers, ctrl-c's lookup).
---@return litre.Task[]
function M.running_tasks()
    local list = {}
    for _, task in pairs(running) do
        table.insert(list, task)
    end
    table.sort(list, function(a, b)
        return a.id < b.id
    end)
    return list
end

---Interrupt a running task: SIGTERM its current process; run sees the flag
---and abort with "interrupted" instead of "command failed". A task suspended
---in a prompt has no process -- cancelling the prompt is the way out there.
---@param task litre.Task
function M.kill(task)
    if not task.proc then
        vim.notify("litre: " .. task.id .. " is waiting in a prompt -- cancel that instead",
            vim.log.levels.WARN)
        return
    end
    -- a second kill escalates: the first SIGTERM was ignored
    local sig = task.killed and "sigkill" or "sigterm"
    task.killed = true
    -- the process may exit between the check and the signal; that race is fine
    pcall(task.proc.kill, task.proc, sig)
end

-- vim.system children are NOT killed when nvim exits (measured: a pty'd sleep
-- survives qa!). With :restart-driven servers that would leak a build per
-- restart, so reap running tasks' processes on the way out.
vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("litre.runner", {}),
    callback = function()
        for _, task in pairs(running) do
            if task.proc then
                pcall(task.proc.kill, task.proc, "sigterm")
            end
        end
    end,
})

-- Primitives call this to insist they are inside a task.
function M.ctx(what)
    if not M.current then
        error(what .. "() can only be called inside a running task", 3)
    end
    return M.current
end

return M
