-- Finds .liter.lua files from cwd upward and executes each in a sandboxed env.
--
-- Envs nest: an inner file reads outer definitions through __index, while its
-- own keys stay separate -- so introspection lists each file's tasks exactly
-- once, and a repo-root helper is usable in every subdirectory file.
--
-- Every function own-key of a file's env is a task (`local` = private, the
-- habit lua-ls already enforces; Capitalized keeps its lowercase-global hint
-- quiet). Files re-execute on every load(): params re-register from
-- scratch and nothing is ever stale. The primitives are not injected: a file
-- does `local l = require("liter")` like any Lua module user.
--
-- The upward walk stats one exact path per directory level -- allowed even
-- under the arc-mount rules; it must never grow into anything recursive.
local M = {}

M.loading = nil ---@type string|nil file currently executing (param registration)
local collect = nil -- load() output under construction

function M.register_param(file, name, options)
    if not collect then
        return
    end
    for _, p in ipairs(collect.params) do
        if p.file == file and p.name == name then
            p.options = options
            return
        end
    end
    table.insert(collect.params, { file = file, name = name, options = options })
end

-- Directories with a .liter.lua, outermost first, plus the cwd they hang off.
function M.files()
    local cwd = vim.fs.normalize(vim.fn.getcwd())
    local dirs = {}
    local d = cwd
    while d do
        if vim.uv.fs_stat(vim.fs.joinpath(d, ".liter.lua")) then
            table.insert(dirs, 1, d)
        end
        local parent = vim.fs.dirname(d)
        if parent == d then
            break
        end
        d = parent
    end
    return dirs, cwd
end

-- "" for cwd's own file, else "..", "../..", ... -- the id prefix (decided:
-- task names carry the relative path of their file).
local function rel_prefix(cwd, dir)
    if cwd == dir then
        return ""
    end
    local rel, d = "..", vim.fs.dirname(cwd)
    while d ~= dir do
        local parent = vim.fs.dirname(d)
        if parent == d then
            break
        end
        rel, d = rel .. "/..", parent
    end
    return rel .. "/"
end

function M.load()
    local dirs, cwd = M.files()
    collect = { tasks = {}, params = {}, files = {}, cwd = cwd }
    local parent = setmetatable({}, { __index = _G })
    for _, dir in ipairs(dirs) do
        local file = vim.fs.joinpath(dir, ".liter.lua")
        local env = setmetatable({}, { __index = parent })
        local chunk, lerr = loadfile(file)
        if not chunk then
            vim.notify("liter: " .. tostring(lerr), vim.log.levels.ERROR)
        else
            setfenv(chunk, env)
            -- parameter() registers as the chunk executes, so a file that raises
            -- halfway has already put entries in the collector. Its tasks are
            -- dropped below by never reaching the collection step; params have
            -- to be rolled back explicitly, or a file that fails to load still
            -- contributes params to the picker.
            local nparams = #collect.params
            M.loading = file
            local ok, rerr = pcall(chunk)
            M.loading = nil
            if not ok then
                for i = #collect.params, nparams + 1, -1 do
                    table.remove(collect.params, i)
                end
                vim.notify("liter: " .. tostring(rerr), vim.log.levels.ERROR)
            else
                table.insert(collect.files, file)
                local prefix = rel_prefix(cwd, dir)
                local names = {}
                for k, v in pairs(env) do -- own keys only; __index hides inherited
                    if type(k) == "string" and type(v) == "function" then
                        table.insert(names, k)
                    end
                end
                table.sort(names)
                for _, name in ipairs(names) do
                    table.insert(collect.tasks, {
                        id = prefix .. name,
                        name = name,
                        fn = rawget(env, name),
                        dir = dir,
                        file = file,
                    })
                end
                parent = env
            end
        end
    end
    -- innermost first: "" sorts before "..", ".." before "../.."
    table.sort(collect.tasks, function(a, b)
        if a.dir ~= b.dir then
            return #a.dir > #b.dir
        end
        return a.name < b.name
    end)
    local done = collect
    collect = nil
    return done
end

return M
