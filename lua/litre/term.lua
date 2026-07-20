-- litre://<task id> output buffers: dead terminals. A pty job streams in, so
-- colors and progress bars render, but there is no shell behind the buffer --
-- tasks are re-runnable programs, not sessions. One buffer per task, replaced
-- on re-run so windows showing the old run switch to the new one (the
-- arc-nvim scratch convention: re-viewing refreshes, never piles duplicates).
--
-- No owned window (the oil.nvim rule): if the previous run is visible
-- somewhere, the new one streams there without stealing focus; otherwise the
-- buffer opens in the current window like any other buffer.
local M = {}

local bufs = {} -- task id -> buffer of its latest run

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
    end
    if old and vim.api.nvim_buf_is_valid(old) then
        vim.api.nvim_buf_delete(old, { force = true })
    end
    vim.api.nvim_buf_set_name(buf, "litre://" .. id)
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
