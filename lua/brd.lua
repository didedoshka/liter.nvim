local M = {}
local dm = require("debugmaster")

local default_config = {
    debugmaster = false,
}

local plugin_config = vim.deepcopy(default_config)

M.setup = function(user_config)
    plugin_config = vim.tbl_deep_extend('force', vim.deepcopy(default_config), user_config or {})

    if plugin_config.debugmaster then
        M.term = require("terminal.debugmaster")

        dm.keys.get("x").key = "dp"

        dm.keys.add({
            key = "J",
            action = M.build,
            desc = "build",
        })

        dm.keys.add({
            key = "X",
            action = M.run,
            desc = "run",
        })

        dm.keys.add({
            key = "P",
            action = M.debug,
            desc = "debug",
        })

        dm.keys.add({
            key = "x",
            action = M.build_and_run,
            desc = "build and run",
        })

        dm.keys.add({
            key = "p",
            action = M.build_and_debug,
            desc = "build and debug",
        })

        dm.keys.add({
            key = "s",
            action = M.choose_target,
            desc = "choose target",
        })

        dm.keys.add({
            key = "C",
            action = M.term.open_terminal,
            desc = "open (C)onsole",
        })

        vim.keymap.set("n", "<bs><bs>", dm.mode.toggle)
        vim.keymap.set("n", "<Esc>", dm.mode.disable)

        -- local state = require("debugmaster.state")
        -- vim.keymap.set("n", "<bs>u", function()
        --     state.sidepanel:toggle()
        -- end)

        -- vim.keymap.set("n", "<bs>J", M.build)
        -- vim.keymap.set("n", "<bs>X", M.run)
        -- vim.keymap.set("n", "<bs>P", M.debug)
        -- vim.keymap.set("n", "<bs>x", M.build_and_run)
        -- vim.keymap.set("n", "<bs>p", M.build_and_debug)
        -- vim.keymap.set("n", "<bs>s", M.choose_target)
        -- vim.keymap.set("n", "<bs>C", M.term.open_terminal)

        local keymaps = require("debugmaster.debug.keymaps")
        for _, group in ipairs(keymaps.groups) do
            for _, mapping in ipairs(group.mappings) do
                vim.keymap.set("n", "<bs>" .. mapping.key, mapping.action, { desc = mapping.desc })
            end
        end
    else
        M.term = require("terminal.basic")
    end
end

local co = coroutine
local _target = nil

local function co_select(items, opts)
    local thread = co.running()
    vim.ui.select(items, opts, function(choice) co.resume(thread, choice) end)

    local choice = co.yield(thread)
    return choice
end

local get_config = function()
    local config_dir = vim.fs.root(vim.fn.getcwd(), ".brd.lua")
    if config_dir == nil then
        local create_file = co_select({ "yes", "no" },
            { prompt = "Create .brd.lua file at " .. vim.fn.getcwd() .. "?" })
        if create_file == nil or create_file == "no" then
            return
        end
        vim.cmd.edit(".brd.lua")
        vim.api.nvim_buf_set_lines(0, 0, 0, true, { "return {", "}" })
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        vim.cmd.write()
        config_dir = vim.fs.root(vim.fn.getcwd(), ".brd.lua")
    end
    if config_dir == nil then
        print("config not found")
        return nil, nil
    end
    local config = dofile(config_dir .. "/.brd.lua")
    return config, config_dir
end

local function is_target_ok(config, target)
    for k, _ in pairs(config) do
        if target == k then
            return true
        end
    end
    return false
end


local function choose_target(config)
    local targets = {}
    for k, _ in pairs(config) do
        table.insert(targets, k)
    end

    local new_target = co_select(targets, {})
    if new_target ~= nil then
        _target = new_target
    end
end

local function get_target(config)
    if _target == nil or not is_target_ok(config, _target) then
        choose_target(config)
    end
    return _target
end

local function normalize(value)
    if type(value) == "function" then
        return value()
    end
    return value
end

local function normalize_path(config_dir, path)
    if path == nil or path == '' then
        return config_dir
    end

    local normalized_path = vim.fs.normalize(path)
    if string.sub(normalized_path, 1, 1) == '/' then
        return normalized_path
    else
        return vim.fs.joinpath(config_dir, path)
    end
end

M.get_directory = function()
    local config, config_dir = get_config()
    if config == nil then
        print("error while reading config")
        return
    end
    local target = get_target(config)
    if target == nil then
        print("target not set")
        return
    end

    return normalize_path(config_dir, normalize(config[target]["dir"]))
end

M.get_debug_executable = function()
    local config, config_dir = get_config()
    if config == nil then
        print("error while reading config")
        return
    end
    local target = get_target(config)
    if target == nil then
        print("target not set")
        return
    end

    local dir = normalize_path(config_dir, normalize(config[target]["dir"]))
    local debug_executable = normalize(config[target]["debug"]["executable"])
    if debug_executable == nil then
        print("debug executable not set")
        return nil
    end
    return dir .. "/" .. debug_executable
end

M.dap_configurations = {
}

local function debug(config, target)
    local debug_configuration = normalize(config[target]["debug"]["configuration"])
    if debug_configuration == nil then
        print("debug configuration not found")
        return
    end

    local state = require("debugmaster.state")
    state.sidepanel:close()
    require("dap").run(M.dap_configurations[debug_configuration])
    state.sidepanel:open()
end

local function execute_in_terminal(command_dir, command)
    local command_table
    if type(command) == "table" then
        command_table = command
    elseif type(command) == "string" then
        command_table = { command }
    else
        print("wrong command type. expected string or table, got", type(command))
    end
    local command_str = "fish -c \"cd " .. command_dir .. "; \\\r\n" .. table.concat(command_table, " &&\r\n") .. "\""

    if M.term.is_buf_terminal() then
        command_str = "\03" .. command_str
    end
    M.term.open_terminal()
    local bad_group = vim.api.nvim_create_augroup("bad_group", {})

    local thread = co.running()

    vim.api.nvim_create_autocmd({ 'TermRequest' }, {
        callback = function(ev)
            if string.sub(ev.data.sequence, 1, 8) == '\x1b]133;D;' then
                vim.api.nvim_clear_autocmds({ group = bad_group })
                local exit_code = string.sub(ev.data.sequence, 9)
                co.resume(thread, tonumber(exit_code))
            end
        end,
        group = bad_group
    })
    vim.fn.chansend(M.term.term_channel, { command_str, "" })
    local result = co.yield(thread)
    return result
end

local function run_co(f, ...)
    co.resume(co.create(f), ...)
end

M.build = function()
    run_co(
        function()
            local config, config_dir = get_config()
            if config == nil then
                print("error while reading config")
                return
            end
            local target = get_target(config)
            if target == nil then
                print("target not set")
                return
            end

            local dir = normalize_path(config_dir, normalize(config[target]["dir"]))

            local build = normalize(config[target]["build"])
            local exit_code = execute_in_terminal(dir, build)
        end
    )
end

M.run = function()
    run_co(
        function()
            local config, config_dir = get_config()
            if config == nil then
                print("error while reading config")
                return
            end
            local target = get_target(config)
            if target == nil then
                print("target not set")
                return
            end

            local dir = normalize_path(config_dir, normalize(config[target]["dir"]))

            local run = normalize(config[target]["run"])
            local exit_code = execute_in_terminal(dir, run)
        end
    )
end

M.debug = function()
    run_co(
        function()
            local config, config_dir = get_config()
            if config == nil then
                print("error while reading config")
                return
            end
            local current_win = vim.api.nvim_get_current_win()
            local target = get_target(config)
            if target == nil then
                print("target not set")
                return
            end

            debug(config, target)
        end
    )
end

M.build_and_run = function()
    run_co(
        function()
            local config, config_dir = get_config()
            if config == nil then
                print("error while reading config")
                return
            end
            local target = get_target(config)
            if target == nil then
                print("target not set")
            end

            local command_dir = normalize_path(config_dir, normalize(config[target]["dir"]))

            local exit_code = 0
            local build = normalize(config[target]["build"])
            if not (build == nil or build == "") then
                exit_code = execute_in_terminal(command_dir, build)
            end

            if exit_code == 0 then
                local run = normalize(config[target]["run"])
                exit_code = execute_in_terminal(command_dir, run)
            end
        end
    )
end


M.build_and_debug = function()
    run_co(
        function()
            local config, config_dir = get_config()
            if config == nil then
                print("error while reading config")
                return
            end
            -- local current_win = vim.api.nvim_get_current_win()
            local target = get_target(config)
            if target == nil then
                print("target not set")
                return
            end

            local dir = normalize_path(config_dir, normalize(config[target]["dir"]))

            local build = normalize(config[target]["build"])
            local exit_code = execute_in_terminal(dir, build)

            if exit_code == 0 then
                M.term.close_terminal()
                -- vim.api.nvim_set_current_win(current_win)
                debug(config, target)
            end
        end
    )
end


M.choose_target = function()
    run_co(function()
        local config = get_config()
        if config == nil then
            print("config not found")
            return
        end
        choose_target(config)
    end)
end

local bad_cmake_targets = { "^following are some of the valid targets for this Makefile:$",
    "^all %(the default if no target is provided%)$", "^clean$", "^depend$",
    "^edit_cache$", "^rebuild_cache$", ".*%.i$", ".*%.o$", ".*%.s$" }

local cmake_target_template = [[
    $DIR_$TARGET = {
        dir = "$DIR",
        build = "cmake --build . --target $TARGET",
        run = "./$TARGET",
        debug = {
            configuration = "cpp",
            executable = "$TARGET"
        }
    },

]]

vim.api.nvim_create_user_command("BrdCmake",
    function(opts)
        local config, config_dir = get_config()
        local build_directory_path = opts["fargs"][1]
        local obj = vim.system({ "cmake", "--build", config_dir .. "/" .. build_directory_path, "--target", "help" },
            { text = true }):wait()
        if obj["code"] ~= 0 then
            print("Failed with exit code " .. obj["code"])
        end
        local targets = obj["stdout"]
        targets = vim.split(targets, "\n")
        table.remove(targets)
        targets = vim.tbl_map(function(value) return string.sub(value, 5) end, targets)
        targets = vim.tbl_filter(
            function(value)
                for _, v in ipairs(bad_cmake_targets) do
                    if string.find(value, v) ~= nil then
                        return false
                    end
                end
                return true
            end, targets)
        local lines_to_insert = ""
        for _, v in ipairs(targets) do
            lines_to_insert = lines_to_insert ..
                string.gsub(string.gsub(cmake_target_template, "$TARGET", v), "$DIR", build_directory_path)
        end
        lines_to_insert = vim.split(lines_to_insert, '\n')
        table.remove(lines_to_insert)
        vim.api.nvim_buf_set_lines(0, 1, 1, true, lines_to_insert)
    end, { nargs = 1 })


vim.api.nvim_create_user_command("BrdConfig",
    function(opts)
        run_co(function()
            local config, config_dir = get_config()
            vim.cmd.edit(config_dir .. "/.brd.lua")
        end)
    end, { nargs = 0 })


return M
