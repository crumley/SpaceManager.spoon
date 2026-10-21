-- JavaScript for Automation, run in its own osascript process.
--
-- hs.osascript.javascript runs JXA inside Hammerspoon, and each run leaves
-- its JavaScriptCore heap behind: about 1.5 MB for one pass over Chrome's
-- windows and tabs, never given back. On SpaceManager's timers that is
-- gigabytes in a couple of weeks. A child process takes its heap with it
-- when it exits, and costs about as much time as the in-process run did.
--
-- Like hs.osascript.javascript, a run blocks Hammerspoon until the script
-- finishes, and gives back ok plus the value of the script's last expression
-- -- a string, number, boolean or table, as JSON carries it -- or false and
-- osascript's error text. The script travels as an argument to a small run
-- handler that evaluates it and prints its value as JSON, so a string stays a
-- string and true stays true. Apple Events osascript sends count as
-- Hammerspoon's, under the same Automation permission.
--
-- No hs dependency: the JSON decoder (hs.json.decode) and popen (io.popen)
-- are passed in, so the tests run under plain lua.
local Jxa = {}

Jxa.osascript = "/usr/bin/osascript"

-- Evaluates the script given as its argument; the envelope carries the
-- value's type through osascript's text output ({} for undefined).
Jxa.runner = "function run(argv) { return JSON.stringify({ v: eval(argv[0]) }); }"

-- One POSIX shell word, taken literally by /bin/sh.
function Jxa.quote(s)
    return "'" .. s:gsub("'", [['\'']]) .. "'"
end

-- The shell command for one run; stderr joins stdout, so an error's text is
-- what comes back.
function Jxa.command(script)
    return table.concat({ Jxa.quote(Jxa.osascript), "-l", "JavaScript", "-e", Jxa.quote(Jxa.runner),
        Jxa.quote(script), "2>&1" }, " ")
end

-- ok, value from what a run printed and whether it exited 0.
function Jxa.parse(output, exited, decode)
    output = (output or ""):gsub("%s+$", "")
    if not exited then
        return false, output
    end
    local ok, envelope = pcall(decode, output)
    if not ok or type(envelope) ~= "table" then
        return false, "unreadable osascript output: " .. output
    end
    return true, envelope.v
end

-- Run script; opts.decode is required, opts.popen defaults to io.popen.
function Jxa.run(script, opts)
    local popen = opts.popen or io.popen
    local p = popen(Jxa.command(script), "r")
    if not p then
        return false, "could not start " .. Jxa.osascript
    end
    local output = p:read("a")
    local exited = p:close()
    return Jxa.parse(output, exited == true, opts.decode)
end

return Jxa
