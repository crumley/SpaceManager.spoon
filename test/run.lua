-- test/run.lua -- run every test/*_test.lua under plain `lua`.
--
--   lua test/run.lua                 # all tests
--   lua test/run.lua test/chrome_test.lua
--
-- Tests are written in busted's describe/it shape with the handful of assert
-- forms below, so they read like the rest of the Lua world without pulling
-- busted (and LuaRocks) in for two files. Hammerspoon itself is not needed:
-- only the pure modules (chrome.lua, state.lua) are under test; init.lua is
-- exercised in Hammerspoon by hand.
local passed, failed, path = 0, 0, {}

local function dump(v)
    if type(v) ~= "table" then
        return tostring(v)
    end
    local parts = {}
    for k, x in pairs(v) do
        parts[#parts + 1] = tostring(k) .. "=" .. dump(x)
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ",") .. "}"
end

local function deepEqual(a, b)
    if type(a) ~= type(b) then
        return false
    end
    if type(a) ~= "table" then
        return a == b
    end
    for k, v in pairs(a) do
        if not deepEqual(v, b[k]) then
            return false
        end
    end
    for k in pairs(b) do
        if a[k] == nil then
            return false
        end
    end
    return true
end

function describe(name, fn)
    path[#path + 1] = name
    fn()
    path[#path] = nil
end

function it(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL " .. table.concat(path, " > ") .. " > " .. name)
        print("     " .. tostring(err))
    end
end

local function expect(cond, message)
    if not cond then
        error(message, 3)
    end
end

assert = setmetatable({
    are = {
        equal = function(expected, actual)
            expect(expected == actual, ("expected %s, got %s"):format(dump(expected), dump(actual)))
        end,
        same = function(expected, actual)
            expect(deepEqual(expected, actual), ("expected %s, got %s"):format(dump(expected), dump(actual)))
        end
    },
    is_true = function(v) expect(v == true, "expected true, got " .. dump(v)) end,
    is_false = function(v) expect(v == false, "expected false, got " .. dump(v)) end,
    is_nil = function(v) expect(v == nil, "expected nil, got " .. dump(v)) end
}, {
    __call = function(_, v, message)
        expect(v, message or "assertion failed")
        return v
    end
})

package.path = "./?.lua;" .. package.path

local files = { table.unpack(arg) }
if #files == 0 then
    local p = io.popen('ls test/*_test.lua')
    for line in p:lines() do
        files[#files + 1] = line
    end
    p:close()
end
for _, f in ipairs(files) do
    dofile(f)
end

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0)
