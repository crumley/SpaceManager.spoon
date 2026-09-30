-- Pure decisions about Chrome window names: which Chrome window is which
-- Hammerspoon window, and what each should be called. No hs dependency, so
-- busted can cover it (spec/chrome_spec.lua). init.lua does the talking to
-- Chrome and to Hammerspoon.
--
-- Chrome exposes a window's "given name" (Window > Name Window...) to
-- scripting as `givenName`, read and write. Its scripting window ids are
-- Chrome's own, unrelated to accessibility window ids, so the two views are
-- paired by title and frame:
--   * a scripting window's `title` is its given name when it has one and its
--     active tab's title otherwise, shortened with an ellipsis when long; the
--     accessibility title is the full text followed by " - Google Chrome"
--     (then " - <profile>" for a named profile);
--   * `bounds` and the accessibility frame agree to within a couple of pixels.
local Chrome = {}

Chrome.frameTolerance = 4

-- A name this module considers its own to overwrite: empty, a current space
-- name, or a name a space used to have. Anything else was typed by a person
-- and is left alone. Date-stamped daily windows are pinned to their date.
local DATE_NAME = "^%d%d%d%d%-%d%d%-%d%d$"

function Chrome.isDateName(name)
    return type(name) == "string" and name:match(DATE_NAME) ~= nil
end

local SUFFIX = " - Google Chrome"

-- Chrome's scripting title shortens a long title to "<head>…<tail>"; the
-- accessibility title is complete. So the head must open the accessibility
-- title and the tail must end it, right before the " - Google Chrome" suffix.
local function titleMatches(chromeWin, hsWin)
    local t, full = chromeWin.title, hsWin.title
    if t == nil or t == "" or full == nil then
        return false
    end
    local head, tail = t:match("^(.-)…(.*)$")
    if head == nil then
        head, tail = t, ""
    end
    if full:sub(1, #head) ~= head then
        return false
    end
    local rest = full:sub(#head + 1)
    local at = rest:find(tail .. SUFFIX, 1, true)
    return at ~= nil and (tail ~= "" or at == 1)
end

local function frameMatches(chromeWin, hsWin, tolerance)
    local b, f = chromeWin.bounds, hsWin.frame
    if b == nil or f == nil then
        return false
    end
    return math.abs(b.x - f.x) <= tolerance and math.abs(b.y - f.y) <= tolerance and
        math.abs(b.width - f.w) <= tolerance and math.abs(b.height - f.h) <= tolerance
end

-- Pair Chrome scripting windows with Hammerspoon windows.
--   chromeWindows: { {id=, title=, givenName=, bounds={x,y,width,height}}, ... }
--   hsWindows:     { {id=, title=, frame={x,y,w,h}, ...}, ... }
-- Returns a list of {chrome=, hs=} pairs, each window used at most once.
-- Title and frame together win; frame alone only when it is unambiguous.
function Chrome.matchWindows(chromeWindows, hsWindows, tolerance)
    tolerance = tolerance or Chrome.frameTolerance
    local pairs_, usedHs = {}, {}

    local function claim(chromeWin, hsWin)
        usedHs[hsWin] = true
        table.insert(pairs_, { chrome = chromeWin, hs = hsWin })
    end

    local unmatched = {}
    for _, cw in ipairs(chromeWindows) do
        local found
        for _, hw in ipairs(hsWindows) do
            if not usedHs[hw] and titleMatches(cw, hw) and frameMatches(cw, hw, tolerance) then
                found = hw
                break
            end
        end
        if found then
            claim(cw, found)
        else
            table.insert(unmatched, cw)
        end
    end

    for _, cw in ipairs(unmatched) do
        local candidates = {}
        for _, hw in ipairs(hsWindows) do
            if not usedHs[hw] and frameMatches(cw, hw, tolerance) then
                table.insert(candidates, hw)
            end
        end
        if #candidates == 1 then
            claim(cw, candidates[1])
        end
    end

    return pairs_
end

-- Decide renames.
--   pairs_:        from matchWindows; each hs window carries `spaces` (list of ids)
--   spaceNames:    spaceId -> the name windows on that space should carry, or nil
--   managedNames:  set (name -> true) of names this module may overwrite
-- Returns a list of {id=<chrome id>, name=<new given name>} ("" clears).
function Chrome.plan(pairs_, spaceNames, managedNames)
    local changes = {}
    for _, p in ipairs(pairs_) do
        local current = p.chrome.givenName or ""
        local spaceId = p.hs.spaces and p.hs.spaces[1]
        local target = spaceId and spaceNames[spaceId] or nil
        local ours = current == "" or managedNames[current] == true

        if Chrome.isDateName(current) or not ours then
            -- pinned or person-named: leave it
        elseif target ~= nil and current ~= target then
            table.insert(changes, { id = p.chrome.id, name = target })
        elseif target == nil and current ~= "" then
            table.insert(changes, { id = p.chrome.id, name = "" })
        end
    end
    return changes
end

return Chrome
