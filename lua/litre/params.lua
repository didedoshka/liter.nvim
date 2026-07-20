-- Source write-back for param option lists: locate the `param("name", { ... })`
-- call via treesitter and splice a new string literal into the table. Only
-- literal lists can be edited -- a computed list has no node to append to,
-- and that constraint is accepted by design.
--
-- Buffer wins over disk: an open buffer may hold unsaved edits the file
-- doesn't, so the edit lands there and is written out.
local M = {}

local QUERY = [[
(function_call
  name: [(identifier) (dot_index_expression)] @fname
  arguments: (arguments . (string) @pname (table_constructor) @opts))
]]

-- One capture-name -> node table per match, across the iter_matches API
-- change (node vs list-of-nodes values).
local function captures(query, match)
    local caps = {}
    for id, nodes in pairs(match) do
        local node = nodes
        if type(nodes) == "table" then
            node = nodes[#nodes]
        end
        caps[query.captures[id]] = node
    end
    return caps
end

-- Insertion point for a new option of param `name`: 0-based row, col and the
-- text to splice in. nil + reason when the param has no literal list.
local function find_insert(src, name, value)
    local parser = vim.treesitter.get_string_parser(src, "lua")
    local root = parser:parse()[1]:root()
    local query = vim.treesitter.query.parse("lua", QUERY)
    for _, match in query:iter_matches(root, src, 0, -1) do
        local caps = captures(query, match)
        local fname = vim.treesitter.get_node_text(caps.fname, src)
        local pname = vim.treesitter.get_node_text(caps.pname, src):sub(2, -2)
        if (fname == "param" or fname:match("%.param$") ~= nil) and pname == name then
            local last = nil
            for child in caps.opts:iter_children() do
                if child:named() then
                    last = child
                end
            end
            if last then
                -- match the existing quote style
                local quote = vim.treesitter.get_node_text(last, src):sub(1, 1)
                if quote ~= "'" then
                    quote = '"'
                end
                local escaped = value:gsub("\\", "\\\\"):gsub(quote, "\\" .. quote)
                local _, _, erow, ecol = last:range()
                return erow, ecol, (", %s%s%s"):format(quote, escaped, quote)
            end
            local brace = caps.opts:child(0) -- "{" of an empty list
            local _, _, erow, ecol = brace:range()
            return erow, ecol, (' "%s" '):format(value:gsub("\\", "\\\\"):gsub('"', '\\"'))
        end
    end
    return nil, ("litre: no literal option list found for param %q in this file"):format(name)
end

---@return boolean ok
function M.add_option(file, name, value)
    local bufnr = vim.fn.bufnr(file)
    if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
        local row, col, text = find_insert(table.concat(lines, "\n"), name, value)
        if not row then
            vim.notify(col --[[@as string]], vim.log.levels.ERROR)
            return false
        end
        vim.api.nvim_buf_set_text(bufnr, row, col, row, col, { text })
        vim.api.nvim_buf_call(bufnr, function()
            vim.cmd("silent keepalt write")
        end)
        return true
    end
    local lines = vim.fn.readfile(file)
    local row, col, text = find_insert(table.concat(lines, "\n"), name, value)
    if not row then
        vim.notify(col --[[@as string]], vim.log.levels.ERROR)
        return false
    end
    local line = lines[row + 1]
    lines[row + 1] = line:sub(1, col) .. text .. line:sub(col + 1)
    vim.fn.writefile(lines, file)
    return true
end

return M
