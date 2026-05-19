local M = {}
---@class dm.ui.Console: dm.ui.Sidepanel.IComponent
local Console = {}

---@param groups dm.MappingsGroup[]
function Console.new()
    ---@class dm.ui.Console
    local self = setmetatable({}, { __index = Console })

    self.buf = vim.api.nvim_create_buf(false, true)
    self._hl_ns = vim.api.nvim_create_namespace("ConsolePopupHighlightNamespace")
    self.win = nil
    self.name = "[C]onsole"

    return self
end

local state = require("debugmaster.state")
state.console = Console.new()

state.sidepanel:add_component(state.console)

M.open_terminal = function()
    -- local last_window = vim.api.nvim_get_current_win()
    state.sidepanel:set_active_with_open(state.console)
    if not M.is_buf_terminal() then
        vim.api.nvim_set_current_win(state.sidepanel.win)
        vim.cmd.terminal()
        vim.bo[state.console.buf].buflisted = false
        -- vim.keymap.set("n", "q", M.close_terminal, { buffer = state.console.buf })
        M.term_channel = vim.bo.channel
        -- vim.api.nvim_set_current_win(last_window)
    end
end

M.is_buf_terminal = function()
    return vim.api.nvim_buf_is_valid(state.console.buf) and vim.bo[state.console.buf].buftype == "terminal"
end

M.close_terminal = function()
    state.sidepanel:set_active_with_open(state.scopes)
end

return M
