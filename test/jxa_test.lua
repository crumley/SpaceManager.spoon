local Jxa = require("jxa")

-- A popen that records the command and replays a canned run.
local function fakePopen(output, exited)
    local calls = {}
    local popen = function(command, mode)
        calls[#calls + 1] = { command = command, mode = mode }
        return {
            read = function() return output end,
            close = function() return exited end
        }
    end
    return popen, calls
end

-- Decodes only the envelopes these tests print.
local envelopes = {
    ['{"v":"[1,2]"}'] = { v = "[1,2]" },
    ['{"v":true}'] = { v = true },
    ['{"v":42}'] = { v = 42 },
    ['{}'] = {},
}
local function decode(s)
    local v = envelopes[s]
    if v == nil then
        error("not JSON: " .. s)
    end
    return v
end

-- What /bin/sh makes of a quoted word.
local function shellEcho(word)
    local p = io.popen("printf %s " .. word)
    local out = p:read("a")
    p:close()
    return out
end

describe("Jxa.quote", function()
    it("is taken literally by the shell", function()
        for _, s in ipairs({
            "plain",
            "it's",
            "''",
            [[a "b" $HOME `id` \n \\ ; | & * ?]],
            "📥 Inbox",
            "line one\nline two",
            "",
        }) do
            assert.are.equal(s, shellEcho(Jxa.quote(s)))
        end
    end)
end)

describe("Jxa.command", function()
    it("hands the script to the run handler as an argument", function()
        local command = Jxa.command("const a = 'x'; a;")
        assert.are.equal("'/usr/bin/osascript' -l JavaScript -e " .. Jxa.quote(Jxa.runner) ..
            " 'const a = '\\''x'\\''; a;' 2>&1", command)
    end)
end)

describe("Jxa.parse", function()
    it("unwraps the value from its envelope", function()
        local ok, v = Jxa.parse('{"v":"[1,2]"}\n', true, decode)
        assert.is_true(ok)
        assert.are.equal("[1,2]", v)
    end)

    it("keeps booleans and numbers as they are", function()
        local _, t = Jxa.parse('{"v":true}\n', true, decode)
        assert.is_true(t)
        local _, n = Jxa.parse('{"v":42}\n', true, decode)
        assert.are.equal(42, n)
    end)

    it("gives nil for a script with no value", function()
        local ok, v = Jxa.parse("{}\n", true, decode)
        assert.is_true(ok)
        assert.is_nil(v)
    end)

    it("gives back the error text when osascript fails", function()
        local ok, err = Jxa.parse("execution error: Error: Can't get object. (-1728)\n", false, decode)
        assert.is_false(ok)
        assert.are.equal("execution error: Error: Can't get object. (-1728)", err)
    end)

    it("fails on output that is not an envelope", function()
        local ok, err = Jxa.parse("warning: something\n{}", true, decode)
        assert.is_false(ok)
        assert.are.equal("unreadable osascript output: warning: something\n{}", err)
    end)
end)

describe("Jxa.run", function()
    it("runs the command and parses what it printed", function()
        local popen, calls = fakePopen('{"v":true}\n', true)
        local ok, v = Jxa.run("true;", { decode = decode, popen = popen })
        assert.is_true(ok)
        assert.is_true(v)
        assert.are.equal(1, #calls)
        assert.are.equal(Jxa.command("true;"), calls[1].command)
        assert.are.equal("r", calls[1].mode)
    end)

    it("fails when the process exits nonzero", function()
        local popen = fakePopen("execution error: boom\n", nil)
        local ok, err = Jxa.run("throw 1;", { decode = decode, popen = popen })
        assert.is_false(ok)
        assert.are.equal("execution error: boom", err)
    end)

    it("fails when the process cannot start", function()
        local ok, err = Jxa.run("1;", { decode = decode, popen = function() return nil end })
        assert.is_false(ok)
        assert.are.equal("could not start /usr/bin/osascript", err)
    end)

    -- The real thing, where there is an osascript (macOS). No JSON decoder
    -- under plain lua, so the envelope is checked as text.
    local probe = io.open(Jxa.osascript, "r")
    if probe then
        probe:close()
        local raw = function(s) return { v = s } end

        it("evaluates the script in osascript and prints its value as JSON", function()
            local ok, out = Jxa.run([[
                const s = "it's \"quoted\" 📥";
                JSON.stringify([s, 1 + 1]);
            ]], { decode = raw })
            assert.is_true(ok)
            assert.are.equal([[{"v":"[\"it's \\\"quoted\\\" 📥\",2]"}]], out)
        end)

        it("keeps a boolean a boolean", function()
            local _, out = Jxa.run("1 === 1;", { decode = raw })
            assert.are.equal('{"v":true}', out)
        end)

        it("reports a script error", function()
            local ok, err = Jxa.run("throw new Error('boom');", { decode = raw })
            assert.is_false(ok)
            assert(err:find("boom"), err)
        end)
    end
end)
