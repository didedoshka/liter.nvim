-- Public surface. Command index:
--   :Litre [task]       run a task by id (or bare name), no arg opens the picker
--   :LitreConfig        edit the innermost .litre.lua (path at cwd when none exists)
--   :LitreCmake <dir>   generate build/run/debug tasks for a cmake build dir
--
-- The layer -- map one key (x in didedoshka's config) to require("litre").layer():
-- opens the fzf-pin picker over every task, map()ped chars shown as [k].
-- A map()ped char runs its task immediately; verbs run in the picker too
--   v  param picker    c  edit config    o  show last task's output buffer
--   r  re-run last     k  kill a running task
-- `i` drops into fuzzy search, enter runs the selection.
local M = {}

local verbs -- filled below; load_tasks() strips map() keys that collide with them

local function load_tasks()
    local d = require("litre.discover").load()
    for k in pairs(d.maps) do
        -- "i" belongs to fzf-pin: it re-enables typing inside the picker
        if verbs[k] or k == "i" then
            vim.notify(("litre: key %q is reserved by the layer; map() ignored"):format(k),
                vim.log.levels.WARN)
            d.maps[k] = nil
        end
    end
    return d
end

local function run(task)
    require("litre.runner").run(task)
end

local function short(p)
    return vim.fn.fnamemodify(p, ":~")
end

-- The task layer as an fzf-pin source. Tasks are not pinnable from inside the
-- picker (keys are declared via map() in .litre.lua), so there is no pin().
M.source = {
    prompt = "litre> ",
    list = function()
        local d = load_tasks()
        local key_of = {}
        for k, t in pairs(d.maps) do
            key_of[t.id] = k
        end
        local live = {}
        for _, t in ipairs(require("litre.runner").running_tasks()) do
            live[t.id] = true
        end
        local items = {}
        for _, t in ipairs(d.tasks) do
            table.insert(items, {
                label = ("%-28s %s%s"):format(t.id, short(t.dir),
                    live[t.id] and "  (running)" or ""),
                char = key_of[t.id],
                data = t,
            })
        end
        return items
    end,
    activate = function(item)
        run(item.data)
    end,
    -- verbs attached below, once they exist
}

function M.layer()
    require("fzf-pin").pick(M.source)
end

local NEW = "  new value..."

function M.pick_param()
    local d = load_tasks()
    local state = require("litre.state")
    if #d.params == 0 then
        vim.notify("litre: no params declared in any .litre.lua", vim.log.levels.WARN)
        return
    end
    local function current(p)
        local cur = state.get(p.file, p.name)
        if cur == nil then
            cur = p.options[1]
        end
        return cur
    end
    vim.ui.select(d.params, {
        prompt = "litre param",
        format_item = function(p)
            return ("%s = %s  [%s]"):format(p.name, current(p), short(p.file))
        end,
    }, function(p)
        if not p then
            return
        end
        local options = vim.deepcopy(p.options)
        table.insert(options, NEW)
        vim.ui.select(options, { prompt = p.name }, function(v)
            if v == nil then
                return
            end
            if v ~= NEW then
                state.set(p.file, p.name, v)
                return
            end
            vim.ui.input({ prompt = p.name .. " (new): " }, function(nv)
                if nv and nv ~= ""
                    and require("litre.params").add_option(p.file, p.name, nv) then
                    state.set(p.file, p.name, nv)
                end
            end)
        end)
    end)
end

function M.edit_config()
    -- the raw dir walk, not load_tasks(): a config that fails to load is
    -- exactly the one that needs editing, and load() would drop it
    local dirs, cwd = require("litre.discover").files()
    vim.cmd.edit(vim.fs.joinpath(dirs[#dirs] or cwd, ".litre.lua"))
end

function M.show_output()
    local runner = require("litre.runner")
    local buf = runner.last and require("litre.term").buf(runner.last.id)
    if not buf then
        vim.notify("litre: no task output yet", vim.log.levels.WARN)
        return
    end
    vim.api.nvim_win_set_buf(0, buf)
end

function M.rerun()
    local runner = require("litre.runner")
    if not runner.last then
        vim.notify("litre: no task has run yet", vim.log.levels.WARN)
        return
    end
    local d = load_tasks()
    for _, t in ipairs(d.tasks) do
        if t.id == runner.last.id then
            run(t)
            return
        end
    end
    vim.notify("litre: task " .. runner.last.id .. " no longer exists", vim.log.levels.WARN)
end

function M.kill()
    local runner = require("litre.runner")
    local tasks = runner.running_tasks()
    if #tasks == 0 then
        vim.notify("litre: no task is running", vim.log.levels.WARN)
        return
    end
    if #tasks == 1 then
        runner.kill(tasks[1])
        return
    end
    vim.ui.select(tasks, {
        prompt = "litre kill",
        format_item = function(t)
            return t.id
        end,
    }, function(t)
        if t then
            runner.kill(t)
        end
    end)
end

verbs = {
    v = M.pick_param,
    c = M.edit_config,
    o = M.show_output,
    r = M.rerun,
    k = M.kill,
}
M.source.verbs = verbs

function M.setup(opts)
    require("litre.config").setup(opts)

    vim.api.nvim_create_user_command("Litre", function(o)
        if o.args == "" then
            M.layer()
            return
        end
        -- tasks are sorted innermost first, so a bare name hits the nearest one
        for _, t in ipairs(load_tasks().tasks) do
            if t.id == o.args or t.name == o.args then
                run(t)
                return
            end
        end
        vim.notify("litre: no task " .. o.args, vim.log.levels.WARN)
    end, {
        nargs = "?",
        complete = function()
            local ids = {}
            for _, t in ipairs(load_tasks().tasks) do
                table.insert(ids, t.id)
            end
            return ids
        end,
    })

    vim.api.nvim_create_user_command("LitreConfig", M.edit_config, {})

    vim.api.nvim_create_user_command("LitreCmake", function(o)
        require("litre.cmake").generate(o.fargs[1])
    end, { nargs = 1, complete = "dir" })
end

return M
