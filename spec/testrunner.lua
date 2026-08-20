--[[--
A ~100 line test runner, so the suite needs nothing but a Lua interpreter.

Usage:
    local t = require("spec/testrunner")
    t.describe("thing", function()
        t.it("does something", function() t.assertEquals(1, 1) end)
    end)
    return t.run()
--]]--

local T = {}

local groups = {}
local current

-- Set DUO_TEST_TIMING=1 to have each test print how long it took, which is
-- how you find the suite's slow spots. Wall clock, not CPU time: most of what
-- is slow here is spent waiting, and waiting costs no CPU at all.
local TIMING = os.getenv("DUO_TEST_TIMING") == "1"
local has_socket, socket = pcall(require, "socket")
local function now()
    return has_socket and socket.gettime() or os.time()
end

function T.describe(name, body)
    current = { name = name, tests = {} }
    groups[#groups+1] = current
    body()
    current = nil
end

function T.it(name, body)
    assert(current, "it() outside of describe()")
    current.tests[#current.tests+1] = { name = name, body = body }
end

local function fail(message, ...)
    error(string.format(message, ...), 3)
end

function T.assertEquals(actual, expected, context)
    if actual ~= expected then
        fail("expected %s but got %s%s", tostring(expected), tostring(actual),
            context and (" (" .. context .. ")") or "")
    end
end

function T.assertNotEquals(actual, unexpected, context)
    if actual == unexpected then
        fail("expected something other than %s%s", tostring(unexpected),
            context and (" (" .. context .. ")") or "")
    end
end

function T.assertTrue(value, context)
    if not value then
        fail("expected a truthy value, got %s%s", tostring(value),
            context and (" (" .. context .. ")") or "")
    end
end

function T.assertNil(value, context)
    if value ~= nil then
        fail("expected nil, got %s%s", tostring(value),
            context and (" (" .. context .. ")") or "")
    end
end

function T.assertMatch(text, pattern)
    if type(text) ~= "string" or not text:match(pattern) then
        fail("expected %s to match %s", tostring(text), pattern)
    end
end

function T.assertTableEquals(actual, expected)
    if type(actual) ~= "table" then
        fail("expected a table, got %s", tostring(actual))
    end
    for key, value in pairs(expected) do
        if actual[key] ~= value then
            fail("key %s: expected %s, got %s", tostring(key), tostring(value), tostring(actual[key]))
        end
    end
    for key in pairs(actual) do
        if expected[key] == nil then
            fail("unexpected key %s = %s", tostring(key), tostring(actual[key]))
        end
    end
end

--- Runs every registered test, printing a TAP-ish report.
-- @treturn number process exit code (0 when everything passed)
function T.run()
    local passed, failed = 0, {}
    for _, group in ipairs(groups) do
        print("\n# " .. group.name)
        for _, test in ipairs(group.tests) do
            local started = TIMING and now()
            local ok, err = xpcall(test.body, function(message)
                return tostring(message) .. "\n" .. debug.traceback("", 2)
            end)
            local took = TIMING and string.format(" (%.1fs)", now() - started) or ""
            if ok then
                passed = passed + 1
                print("  ok   - " .. test.name .. took)
            else
                failed[#failed+1] = { name = group.name .. " / " .. test.name, err = err }
                print("  FAIL - " .. test.name .. took)
            end
        end
    end
    print(string.format("\n%d passed, %d failed", passed, #failed))
    for _, failure in ipairs(failed) do
        print("\n--- " .. failure.name .. "\n" .. failure.err)
    end
    return #failed == 0 and 0 or 1
end

return T
