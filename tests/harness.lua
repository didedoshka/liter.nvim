-- Minimal assertion harness (same shape as the nvim-config suite): test()
-- runs a function and remembers failures, finish() prints a summary and sets
-- the exit code.
local M = { failed = 0, passed = 0, notified = {} }

-- Replace vim.notify with a recorder: tests assert on M.notified instead of
-- letting messages hit the UI. Real arity kept so lua-ls doesn't relearn the
-- signature from this assignment.
function M.quiet()
    ---@diagnostic disable-next-line: duplicate-set-field
    vim.notify = function(msg, _level, _opts)
        table.insert(M.notified, tostring(msg))
    end
end

function M.test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        M.passed = M.passed + 1
    else
        M.failed = M.failed + 1
        io.stderr:write(("  FAIL  %s\n         %s\n"):format(name, tostring(err)))
    end
end

function M.ok(value, msg)
    if not value then
        error(msg or ("expected a truthy value, got " .. vim.inspect(value)), 2)
    end
end

function M.eq(got, want, msg)
    if not vim.deep_equal(got, want) then
        error(("%sexpected %s, got %s"):format(
            msg and (msg .. ": ") or "", vim.inspect(want), vim.inspect(got)), 2)
    end
end

function M.root()
    local this = debug.getinfo(1, "S").source:sub(2)
    return vim.fs.dirname(vim.fs.dirname(this))
end

function M.finish(label)
    local total = M.passed + M.failed
    if M.failed > 0 then
        io.stderr:write(("%s: %d/%d passed, %d FAILED\n"):format(label, M.passed, total, M.failed))
        os.exit(1)
    end
    io.stdout:write(("%s: %d/%d passed\n"):format(label, M.passed, total))
    os.exit(0)
end

return M
