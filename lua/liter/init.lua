-- Public surface: the .liter.lua API (`local l = require("liter")` at the top
-- of every file gives l.command, l.with, l.pick, l.ask, l.parameter, l.debug
-- -- a module, not injected globals, so lua-ls types the calls) plus the
-- commands and the layer. Command index:
--   :Liter [task]       run a task by id (or bare name), no arg opens the picker
--   :LiterConfig        edit the innermost .liter.lua (path at cwd when none exists)
--   :LiterCloseAll      wipe every liter:// buffer except running tasks' ones
--
-- The layer -- map one key (x in didedoshka's config) to require("liter").layer():
-- opens the fzf-pin picker over every task and parameter, pinned chars shown
-- as [k]. A pinned char runs its task or opens its parameter's value picker; a
-- free char pins the highlighted entry, ctrl-x unpins it. Verbs:
--   C  edit config    O  show last task's output buffer    R  re-run last
-- `i` drops into fuzzy search, enter activates the selection.
local M = {}

local lib = require("liter.lib")
M.command, M.with = lib.command, lib.with
M.pick, M.ask, M.parameter, M.debug = lib.pick, lib.ask, lib.parameter, lib.debug

local function load_tasks()
    return require("liter.discover").load()
end

local function run(task)
    require("liter.runner").run(task)
end

local function short(p)
    return vim.fn.fnamemodify(p, ":~")
end

local NEW = "  new value..."

local function current(p)
    local cur = require("liter.state").get(p.file, p.name)
    if cur == nil and type(p.options) == "table" then
        cur = p.options[1]
    end
    return cur or "?"
end

-- a function-valued list runs as a task of its own: the runner gives it the
-- coroutine that lets it run/pick, and its output a liter:// buffer
local function choose_computed(p)
    local runner = require("liter.runner")
    local last = runner.last
    runner.run({
        id = "parameter " .. p.name,
        name = p.name,
        file = p.file,
        dir = vim.fs.dirname(p.file),
        fn = function()
            local v = lib.pick(p.options(), { prompt = p.name })
            if v ~= nil then
                require("liter.state").set(p.file, p.name, v)
            end
        end,
    })
    -- run() records every task as the R verb's target; choosing a value
    -- is not something to re-run
    runner.last = last
end

-- the value picker of one param, with a trailing "new value..." that prompts
-- and writes the option back into the .liter.lua
function M.choose_value(p)
    local state = require("liter.state")
    if type(p.options) == "function" then
        choose_computed(p)
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
                and require("liter.params").add_option(p.file, p.name, nv) then
                state.set(p.file, p.name, nv)
            end
        end)
    end)
end

-- Pins live in fzf-pin's store, one file per cwd (/ encoded as %, like the
-- config's bookmarks): task ids are relative to cwd, so a pin only means
-- something from the directory it was made in.
local function ns()
    return "liter/" .. vim.fs.normalize(vim.fn.getcwd()):gsub("/", "%%")
end

-- what a pin stores: a task by id, a param by file and name
local function pin_key(entry)
    if entry.kind == "task" then
        return "task " .. entry.task.id
    end
    return ("parameter %s %s"):format(entry.param.file, entry.param.name)
end

-- The layer as an fzf-pin source: every task, then every param.
M.source = {
    prompt = "liter> ",
    list = function()
        local d = load_tasks()
        local char_of = {}
        for c, key in pairs(require("fzf-pin.store").load(ns())) do
            char_of[key] = c
        end
        local live = {}
        for _, t in ipairs(require("liter.runner").running_tasks()) do
            live[t.id] = true
        end
        local entries = {}
        for _, t in ipairs(d.tasks) do
            table.insert(entries, {
                kind = "task",
                task = t,
                label = ("%-28s %s%s"):format(t.id, short(t.dir),
                    live[t.id] and "  (running)" or ""),
            })
        end
        for _, p in ipairs(d.params) do
            table.insert(entries, {
                kind = "parameter",
                param = p,
                label = ("%-28s %s"):format(p.name .. " = " .. current(p),
                    short(vim.fs.dirname(p.file))),
            })
        end
        local items = {}
        for _, e in ipairs(entries) do
            table.insert(items, { label = e.label, char = char_of[pin_key(e)], data = e })
        end
        return items
    end,
    activate = function(item)
        if item.data.kind == "task" then
            run(item.data.task)
        else
            M.choose_value(item.data.param)
        end
    end,
    pin = function(char, item)
        if not item then
            vim.notify("liter: nothing highlighted to pin", vim.log.levels.WARN)
            return
        end
        local store = require("fzf-pin.store")
        local pins = store.load(ns())
        local key = pin_key(item.data)
        for c, k in pairs(pins) do
            if k == key then
                vim.notify("liter: already on " .. c .. " (ctrl-x it to move)",
                    vim.log.levels.WARN)
                return
            end
        end
        pins[char] = key
        store.save(ns(), pins)
        vim.notify(("pinned %s to %s"):format(vim.trim(item.label:match("^%S+")), char))
    end,
    unpin = function(item)
        if not item.char then
            return
        end
        local store = require("fzf-pin.store")
        local pins = store.load(ns())
        pins[item.char] = nil
        store.save(ns(), pins)
    end,
    -- verbs attached below, once they exist
}

function M.layer()
    require("fzf-pin").pick(M.source)
end

function M.edit_config()
    -- the raw dir walk, not load_tasks(): a config that fails to load is
    -- exactly the one that needs editing, and load() would drop it
    local dirs, cwd = require("liter.discover").files()
    vim.cmd.edit(vim.fs.joinpath(dirs[#dirs] or cwd, ".liter.lua"))
end

function M.show_output()
    local runner = require("liter.runner")
    local buf = runner.last and require("liter.term").buf(runner.last.id)
    if not buf then
        vim.notify("liter: no task output yet", vim.log.levels.WARN)
        return
    end
    vim.api.nvim_win_set_buf(0, buf)
    -- same terminal-to-terminal mode leak as term.open: `o` fires while the
    -- picker's fzf terminal still holds terminal mode
    vim.cmd.stopinsert()
end

function M.rerun()
    local runner = require("liter.runner")
    if not runner.last then
        vim.notify("liter: no task has run yet", vim.log.levels.WARN)
        return
    end
    local d = load_tasks()
    for _, t in ipairs(d.tasks) do
        if t.id == runner.last.id then
            run(t)
            return
        end
    end
    vim.notify("liter: task " .. runner.last.id .. " no longer exists", vim.log.levels.WARN)
end

-- a running task keeps its buffer: closing output must not silently stop a
-- build, and its next output would stream into a buffer nobody can see
function M.close_all()
    local term = require("liter.term")
    local keep = {}
    for _, task in ipairs(require("liter.runner").running_tasks()) do
        local b = term.buf(task.id)
        if b then
            keep[b] = true
        end
    end
    local kept = 0
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.startswith(vim.api.nvim_buf_get_name(b), "liter://") then
            if keep[b] then
                kept = kept + 1
            else
                vim.api.nvim_buf_delete(b, { force = true })
            end
        end
    end
    if kept > 0 then
        vim.notify(("liter: kept %d running task buffer(s)"):format(kept))
    end
end

-- uppercase: every lowercase key stays free for pins -- r for run was the
-- first real config's collision when these were lowercase
local verbs = {
    C = M.edit_config,
    O = M.show_output,
    R = M.rerun,
}
M.source.verbs = verbs

function M.setup(opts)
    require("liter.config").setup(opts)

    vim.api.nvim_create_user_command("Liter", function(o)
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
        vim.notify("liter: no task " .. o.args, vim.log.levels.WARN)
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

    vim.api.nvim_create_user_command("LiterConfig", M.edit_config, {})
    vim.api.nvim_create_user_command("LiterCloseAll", M.close_all, {})
end

return M
