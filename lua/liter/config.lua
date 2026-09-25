-- User options. Read `config.opts` at call time, never capture at load.
local M = {}

M.opts = {
    -- String commands run as `<shell> -c <command>`; argv tables bypass the
    -- shell entirely.
    shell = "fish",
    -- Machine-side bases for the `debug(name, overrides)` primitive: each
    -- entry is a dap configuration table (shallow-merged with overrides) or a
    -- function(overrides) returning one. The adapter itself is the nvim
    -- config's business; .liter.lua files only name a template.
    dap_templates = {},
}

function M.setup(user)
    M.opts = vim.tbl_deep_extend("force", M.opts, user or {})
end

return M
