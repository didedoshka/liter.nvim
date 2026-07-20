-- :LitreCmake <builddir> -- ask cmake for its targets and generate imperative
-- build/run/debug tasks into the current buffer (expected: a .litre.lua).
-- Successor of v1's declarative generator; the output is plain source meant
-- to be edited down, not regenerated.
local M = {}

local bad_targets = {
    "^following are some of the valid targets for this Makefile:$",
    "^all %(the default if no target is provided%)$", "^clean$", "^depend$",
    "^edit_cache$", "^rebuild_cache$", ".*%.i$", ".*%.o$", ".*%.s$",
}

local template = [[
function $NAME_build()
    sh("cmake --build $DIR --target $TARGET")
end

function $NAME_run()
    $NAME_build()
    sh("./$TARGET", { dir = "$DIR" })
end

function $NAME_debug()
    $NAME_build()
    debug("cpp", { program = "$TARGET", dir = "$DIR" })
end

]]

function M.generate(builddir)
    local base = vim.fn.expand("%:p:h")
    local obj = vim.system(
        { "cmake", "--build", vim.fs.joinpath(base, builddir), "--target", "help" },
        { text = true }):wait()
    if obj.code ~= 0 then
        vim.notify("litre: cmake --target help failed:\n" .. (obj.stderr or ""),
            vim.log.levels.ERROR)
        return
    end
    local chunks = {}
    for line in vim.gsplit(obj.stdout or "", "\n") do
        local target = line:match("^%.%.%. (%S+)")
        if target then
            for _, pat in ipairs(bad_targets) do
                if target:find(pat) then
                    target = nil
                    break
                end
            end
        end
        if target then
            local name = target:gsub("[^%w_]", "_")
            local text = template
                :gsub("%$NAME", function() return name end)
                :gsub("%$TARGET", function() return target end)
                :gsub("%$DIR", function() return builddir end)
            table.insert(chunks, text)
        end
    end
    if #chunks == 0 then
        vim.notify("litre: no targets found", vim.log.levels.WARN)
        return
    end
    vim.api.nvim_put(vim.split(table.concat(chunks):gsub("\n$", ""), "\n"), "l", true, false)
end

return M
