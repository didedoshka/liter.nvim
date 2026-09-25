-- Persisted param selections: one JSON file under stdpath("data"), keyed by
-- .liter.lua path, then param name. Read fresh on every access -- .liter.lua files
-- re-execute constantly and this file is tiny, so caching would only add a
-- staleness bug surface.
local M = {}

local function path()
    return vim.fs.joinpath(vim.fn.stdpath("data"), "liter", "parameters.json")
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
    -- several per-project nvim servers share this file: write to a private tmp
    -- and rename, so a concurrent read never sees a half-written file (which
    -- would decode as {} and let that server's next set() wipe every selection)
    local tmp = ("%s.%d"):format(path(), vim.uv.os_getpid())
    local f = assert(io.open(tmp, "w"))
    f:write(vim.json.encode(data))
    f:close()
    assert(vim.uv.fs_rename(tmp, path()))
end

return M
