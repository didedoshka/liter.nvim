-- Persisted param selections: one JSON file under stdpath("data"), keyed by
-- .litre.lua path, then param name. Read fresh on every access -- .litre.lua files
-- re-execute constantly and this file is tiny, so caching would only add a
-- staleness bug surface.
local M = {}

local function path()
    return vim.fs.joinpath(vim.fn.stdpath("data"), "litre", "params.json")
end

local function read()
    local f = io.open(path(), "r")
    if not f then
        return {}
    end
    local ok, data = pcall(vim.json.decode, f:read("*a"))
    f:close()
    return (ok and type(data) == "table") and data or {}
end

function M.get(file, name)
    return (read()[file] or {})[name]
end

function M.set(file, name, value)
    local data = read()
    data[file] = data[file] or {}
    data[file][name] = value
    vim.fn.mkdir(vim.fs.dirname(path()), "p")
    local f = assert(io.open(path(), "w"))
    f:write(vim.json.encode(data))
    f:close()
end

return M
