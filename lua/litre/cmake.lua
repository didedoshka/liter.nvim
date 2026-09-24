-- cmake helpers for .litre.lua files, on top of cmake's file API: the reply
-- under <build>/.cmake/api/v1/reply lists every target with its type and
-- artifact path, whatever the generator (`--target help` is Makefile-only and
-- omitted executables under Ninja, measured). Once the query file exists any
-- `cmake --build` that re-configures refreshes the reply (measured), so only
-- the very first call runs cmake itself.
--
--   local target = l.param("target", function() return cm.targets("build") end)
--   b.sh("./" .. cm.exe("build", target))
--
-- Both take the build dir the way sh's opts.dir does: relative to the calling
-- task's .litre.lua, so they only work inside a task (targets() runs inside the
-- V picker's task; exe() inside Build/Run/Debug).
local M = {}

local lib = require("litre.lib")
local runner = require("litre.runner")

local function build_dir(dir)
    local ctx = runner.ctx("cmake")
    dir = vim.fs.normalize(dir)
    if dir:sub(1, 1) == "/" then
        return dir
    end
    return vim.fs.joinpath(ctx.dir, dir)
end

local function read_json(path)
    local f = io.open(path, "r")
    if not f then
        return nil
    end
    local text = f:read("*a")
    f:close()
    return vim.json.decode(text)
end

-- The current index is the lexicographically largest index-*.json (the file
-- API's own rule: a re-generate briefly leaves the old one beside the new).
local function index(reply)
    local best = nil
    for name in vim.fs.dir(reply) do
        if name:match("^index%-.*%.json$") and (best == nil or name > best) then
            best = name
        end
    end
    return best and vim.fs.joinpath(reply, best)
end

-- name -> artifact path (relative to the build dir) of every executable target
local function executables(build)
    local reply = vim.fs.joinpath(build, ".cmake", "api", "v1", "reply")
    local idx = index(reply)
    if not idx then
        return nil
    end
    local codemodel = read_json(idx).reply["codemodel-v2"]
    if not codemodel then
        return nil
    end
    local exes = {}
    local cm = read_json(vim.fs.joinpath(reply, codemodel.jsonFile))
    -- multi-config generators list one target set per configuration; the
    -- first is the one `cmake --build` builds by default
    for _, t in ipairs(cm.configurations[1].targets) do
        local target = read_json(vim.fs.joinpath(reply, t.jsonFile))
        if target.type == "EXECUTABLE" and target.artifacts then
            exes[target.name] = target.artifacts[1].path
        end
    end
    return exes
end

-- Executable target names of a build dir, sorted. Plants the file-API query
-- and configures once when no reply exists yet (streams like any sh).
---@param dir string build directory, relative to the task's .litre.lua
---@return string[]
function M.targets(dir)
    local build = build_dir(dir)
    local exes = executables(build)
    if not exes then
        vim.fn.mkdir(vim.fs.joinpath(build, ".cmake", "api", "v1", "query"), "p")
        vim.fn.writefile({}, vim.fs.joinpath(build, ".cmake", "api", "v1", "query", "codemodel-v2"))
        lib.sh({ "cmake", build })
        exes = executables(build) or {}
    end
    local names = vim.tbl_keys(exes)
    table.sort(names)
    return names
end

-- Artifact path of an executable target, relative to the build dir (a target
-- from a subdirectory lives in that subdirectory).
---@param dir string build directory, relative to the task's .litre.lua
---@param name string? target name (a param that is still unset is nil)
---@return string
function M.exe(dir, name)
    if not name then
        runner.abort("cmake: no target chosen yet -- pick one with V")
    end
    local exes = executables(build_dir(dir)) or {}
    if not exes[name] then
        runner.abort(("cmake: no executable target %q (V refreshes the list)"):format(name))
    end
    return exes[name]
end

return M
