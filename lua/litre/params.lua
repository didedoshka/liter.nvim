-- Source write-back for param option lists: locate the `parameter("name", { ... })`
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

-- Body of a Lua string literal delimited by `quote`. Backslash first, then the
-- quote, then the line breaks: an unescaped newline would splice a real line
-- break into the source and leave the user's file unparseable.
local function escape(value, quote)
    return (value:gsub("\\", "\\\\")
        :gsub(quote, "\\" .. quote)
        :gsub("\n", "\\n")
        :gsub("\r", "\\r"))
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
        if (fname == "parameter" or fname:match("%.parameter$") ~= nil) and pname == name then
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
                local _, _, erow, ecol = last:range()
                return erow, ecol, (", %s%s%s"):format(quote, escape(value, quote), quote)
            end
            local brace = caps.opts:child(0) -- "{" of an empty list
            local _, _, erow, ecol = brace:range()
            return erow, ecol, (' "%s" '):format(escape(value, '"'))
        end
    end
    return nil, ("litre: no literal option list found for param %q in this file"):format(name)
end

-- bufnr() treats its argument as a name pattern (partial matches, magic
-- chars), and a buffer opened through a symlinked path carries a different
-- name from discovery's resolved one -- compare realpaths, exactly.
local function loaded_buf(file)
    local want = vim.uv.fs_realpath(file) or file
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(b) then
            local name = vim.api.nvim_buf_get_name(b)
            if name ~= "" and (vim.uv.fs_realpath(name) or name) == want then
                return b
            end
        end
    end
    return nil
end

---@return boolean ok
function M.add_option(file, name, value)
    local bufnr = loaded_buf(file)
    if bufnr then
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
