-- liter://<task id>_<start time> output buffers: dead terminals. A pty job
-- streams in, so colors and progress bars render, but there is no shell behind
-- the buffer -- tasks are re-runnable programs, not sessions. Every run gets a
-- buffer of its own and earlier runs stay around to compare against; windows
-- showing the previous run switch to the new one.
--
-- No owned window (the oil.nvim rule): if the previous run is visible
-- somewhere, the new one streams there without stealing focus; otherwise the
-- buffer opens in the current window like any other buffer.
local M = {}

local bufs = {} -- task id -> buffer of its latest run

-- a task re-run within the same second (R on a quick one) must not collide
-- with the previous run's name
local function unique_name(id)
    local base = ("liter://%s_%s"):format(id, os.date("%m-%d-%H:%M:%S"))
    local taken = {}
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        taken[vim.api.nvim_buf_get_name(b)] = true
    end
    local name, n = base, 1
    while taken[name] do
        n = n + 1
        name = ("%s-%d"):format(base, n)
    end
    return name
end

-- Create the fresh terminal buffer for a run and place it. Returns the
-- channel to feed output into.
function M.open(id)
    local old = bufs[id]
    local wins = {}
    if old and vim.api.nvim_buf_is_valid(old) then
        wins = vim.fn.win_findbuf(old)
    end
    local buf = vim.api.nvim_create_buf(true, true)
    local chan = vim.api.nvim_open_term(buf, {})
    if #wins == 0 then
        wins = { vim.api.nvim_get_current_win() }
    end
    for _, w in ipairs(wins) do
        vim.api.nvim_win_set_buf(w, buf)
        -- terminal buffers follow output only while the cursor sits at the end
        pcall(vim.api.nvim_win_set_cursor, w, { vim.api.nvim_buf_line_count(buf), 0 })
        -- a run triggered from the task picker's key fires while its fzf
        -- terminal still holds terminal mode, and terminal mode survives a
        -- terminal-to-terminal buffer swap; there is no stdin behind a dead
        -- terminal, so drop back to normal mode
        if w == vim.api.nvim_get_current_win() then
            vim.cmd.stopinsert()
        end
    end
    vim.api.nvim_buf_set_name(buf, unique_name(id))
    -- the same leak whenever the buffer is opened from another terminal, e.g.
    -- the `s` picker's fzf window (measured: the mode is still "t" here).
    -- Decided a tick later, and only if the buffer is still current: fzf-lua,
    -- closing any picker, passes through the previous window, and a stop
    -- there carried over to the picker the action opened next (measured: a
    -- param's value picker after `x` landed in normal mode)
    vim.api.nvim_create_autocmd("BufEnter", {
        buffer = buf,
        callback = function()
            vim.schedule(function()
                local current = vim.api.nvim_get_current_buf() == buf
                if current and vim.api.nvim_get_mode().mode == "t" then
                    vim.cmd.stopinsert()
                end
            end)
        end,
    })
    -- ctrl-c interrupts the buffer's task, the reflex from real terminals --
    -- there is no stdin behind a dead terminal to deliver it to the process,
    -- so it goes through runner.kill (a second ctrl-c escalates to SIGKILL)
    vim.keymap.set("n", "<C-c>", function()
        if bufs[id] ~= buf then
            vim.notify("liter: this run of " .. id .. " has finished", vim.log.levels.WARN)
            return
        end
        local runner = require("liter.runner")
        for _, task in ipairs(runner.running_tasks()) do
            if task.id == id then
                runner.kill(task)
                return
            end
        end
        vim.notify("liter: " .. id .. " is not running", vim.log.levels.WARN)
    end, { buffer = buf, desc = "liter: interrupt this task" })
    bufs[id] = buf
    return chan, buf
end

function M.send(chan, data)
    -- the channel dies with its buffer; late job output must not error
    pcall(vim.api.nvim_chan_send, chan, data)
end

function M.buf(id)
    local b = bufs[id]
    return (b and vim.api.nvim_buf_is_valid(b)) and b or nil
end

return M
