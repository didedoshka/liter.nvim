-- :LitreCmake <builddir> -- ask cmake for its targets and generate imperative
-- build/run/debug tasks into the current buffer (expected: a .litre.lua).
-- Successor of v1's declarative generator; the output is plain source meant
-- to be edited down, not regenerated. It assumes the file's module local is
-- `l`, as the readme's `local l = require("litre")` opening line names it.
local M = {}

-- matched against the captured target name alone (%S+ -- never any
-- parenthetical that follows it in the help line)
local bad_targets = {
    "^all$", "^clean$", "^depend$", "^edit_cache$", "^rebuild_cache$",
    ".*%.i$", ".*%.o$", ".*%.s$",
}

local template = [[
function Build_$NAME()
    l.sh("cmake --build $DIR --target $TARGET")
end

function Run_$NAME()
    Build_$NAME()
    l.sh("./$TARGET", { dir = "$DIR" })
end

function Debug_$NAME()
    Build_$NAME()
    l.debug("cpp", { program = "$TARGET", dir = "$DIR" })
end

]]

function M.generate(builddir)
    local base = vim.fn.expand("%:p:h")
    -- `--target help` exists only under the Makefile generator; with Ninja the
    -- notify below carries cmake's error
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
