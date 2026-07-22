-- Finds .litre.lua files from cwd upward and executes each in a sandboxed env.
--
-- Envs nest: an inner file reads outer definitions through __index, while its
-- own keys stay separate -- so introspection lists each file's tasks exactly
-- once, and a repo-root helper is usable in every subdirectory file.
--
-- Every callable own-key of a file's env is a task (`local` = private, the
-- habit lua-ls already enforces). Files re-execute on every load(): params and
-- maps re-register from scratch and nothing is ever stale.
--
-- The upward walk stats one exact path per directory level -- allowed even
-- under the arc-mount rules; it must never grow into anything recursive.
local lib = require("litre.lib")

local M = {}

M.loading = nil ---@type string|nil file currently executing (param/map registration)
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

function M.register_map(key, fn)
    if not collect then
        return
    end
    table.insert(collect.raw_maps, { key = key, fn = fn, file = M.loading })
end

-- Directories with a .litre.lua, outermost first, plus the cwd they hang off.
function M.files()
    local cwd = vim.fs.normalize(vim.fn.getcwd())
    local dirs = {}
    local d = cwd
    while d do
        if vim.uv.fs_stat(vim.fs.joinpath(d, ".litre.lua")) then
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

local function callable(v)
    if type(v) == "function" then
        return true
    end
    if type(v) ~= "table" then
        return false
    end
    local mt = getmetatable(v)
    return mt ~= nil and mt.__call ~= nil
end

local primitives = {
    "sh", "out", "cmd", "env", "pick", "input", "param", "debug", "map",
}

function M.load()
    local dirs, cwd = M.files()
    collect = { tasks = {}, params = {}, raw_maps = {}, maps = {}, files = {}, cwd = cwd }
    local base = setmetatable({}, { __index = _G })
    for _, name in ipairs(primitives) do
        base[name] = lib[name]
    end
    local parent = base
    for _, dir in ipairs(dirs) do
        local file = vim.fs.joinpath(dir, ".litre.lua")
        local env = setmetatable({}, { __index = parent })
        local chunk, lerr = loadfile(file)
        if not chunk then
            vim.notify("litre: " .. tostring(lerr), vim.log.levels.ERROR)
        else
            setfenv(chunk, env)
            -- param() and map() register as the chunk executes, so a file that
            -- raises halfway has already put entries in the collector. Its tasks
            -- are dropped below by never reaching the collection step; these have
            -- to be rolled back explicitly, or a file that fails to load still
            -- contributes params to the picker.
            local nparams, nmaps = #collect.params, #collect.raw_maps
            M.loading = file
            local ok, rerr = pcall(chunk)
            M.loading = nil
            if not ok then
                for i = #collect.params, nparams + 1, -1 do
                    table.remove(collect.params, i)
                end
                for i = #collect.raw_maps, nmaps + 1, -1 do
                    table.remove(collect.raw_maps, i)
                end
                vim.notify("litre: " .. tostring(rerr), vim.log.levels.ERROR)
            else
                table.insert(collect.files, file)
                local prefix = rel_prefix(cwd, dir)
                local names = {}
                for k, v in pairs(env) do -- own keys only; __index hides inherited
                    if type(k) == "string" and callable(v) then
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
                -- resolve this file's map() calls: fn -> global name -> task
                for _, m in ipairs(collect.raw_maps) do
                    if m.file == file and not m.resolved then
                        m.resolved = true
                        -- the layer reads exactly one getcharstr() key: one
                        -- char, or a K_SPECIAL (0x80) termcode from vim.keycode
                        local one_key = m.key ~= ""
                            and (vim.fn.strchars(m.key) == 1 or m.key:byte(1) == 0x80)
                        local found = nil
                        for k, v in pairs(env) do
                            if v == m.fn then
                                found = prefix .. k
                                break
                            end
                        end
                        if not one_key then
                            vim.notify(
                                ("litre: map(%q) is not a single key -- use one character"
                                    .. " or vim.keycode(); skipped"):format(m.key),
                                vim.log.levels.WARN)
                        elseif not found then
                            vim.notify(
                                ("litre: map(%q) target is not a global of %s -- skipped")
                                :format(m.key, file),
                                vim.log.levels.WARN)
                        else
                            collect.maps[m.key] = found
                        end
                    end
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
    -- maps store ids; point them at task entries now that sorting is done
    local by_id = {}
    for _, t in ipairs(collect.tasks) do
        by_id[t.id] = t
    end
    for key, id in pairs(collect.maps) do
        collect.maps[key] = by_id[id]
    end
    local done = collect
    collect = nil
    return done
end

return M
