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

-- The name a space gives its Chrome windows: an optional marker (a colored
-- square standing for the space's color), its position, zero-padded, then its
-- name -- "🟥 01 - Today". nil for a space with no name.
function Chrome.spaceWindowName(index, name, marker)
    if name == nil or name == "" then
        return nil
    end
    local base = string.format("%02d - %s", index, name)
    if marker == nil or marker == "" then
        return base
    end
    return marker .. " " .. base
end

-- Chrome window ids are numbers in string form; order them as numbers so the
-- oldest window on a space takes the bare name and later ones the suffixes.
local function byId(a, b)
    local x, y = tonumber(a.chrome.id), tonumber(b.chrome.id)
    if x and y and x ~= y then
        return x < y
    end
    return tostring(a.chrome.id) < tostring(b.chrome.id)
end

-- Decide renames.
--   pairs_:         from matchWindows; each hs window carries `spaces` (list of ids)
--   spaceNames:     spaceId -> the name its windows should carry (see
--                   spaceWindowName), or nil for an unnamed space
--   renamedSpaces:  set (spaceId -> true) of spaces renamed since the last pass
--   allWindows:     every Chrome scripting window, matched or not, so a new
--                   name never repeats one already in use (defaults to pairs_)
--   keepNames:      set (name -> true) of names never touched, like the Inbox's
-- A window that already has a name keeps it -- whoever gave it, and wherever
-- it has moved -- unless its space was renamed: then every window on that
-- space takes the new name, or loses its name if the space's was cleared.
-- Date-named daily windows, and windows named in keepNames, are never
-- touched. A second window wanting a name
-- already in use gets " 2", then " 3", and so on.
-- Returns a list of {id=<chrome id>, name=<new given name>} ("" clears).
function Chrome.plan(pairs_, spaceNames, renamedSpaces, allWindows, keepNames)
    keepNames = keepNames or {}
    local wanting = {}
    for _, p in ipairs(pairs_) do
        local current = p.chrome.givenName or ""
        local spaceId = p.hs.spaces and p.hs.spaces[1]
        if spaceId ~= nil and not Chrome.isDateName(current) and not keepNames[current] then
            if renamedSpaces[spaceId] then
                table.insert(wanting, { pair = p, target = spaceNames[spaceId] })
            elseif current == "" and spaceNames[spaceId] ~= nil then
                table.insert(wanting, { pair = p, target = spaceNames[spaceId] })
            end
        end
    end

    local renaming = {}
    for _, w in ipairs(wanting) do
        renaming[w.pair.chrome.id] = true
    end
    local taken = {}
    if allWindows == nil then
        allWindows = {}
        for _, p in ipairs(pairs_) do
            table.insert(allWindows, p.chrome)
        end
    end
    for _, cw in ipairs(allWindows) do
        if not renaming[cw.id] and cw.givenName and cw.givenName ~= "" then
            taken[cw.givenName] = true
        end
    end

    table.sort(wanting, function(a, b)
        return byId(a.pair, b.pair)
    end)
    local changes = {}
    for _, w in ipairs(wanting) do
        local current = w.pair.chrome.givenName or ""
        local name = ""
        if w.target ~= nil then
            name = w.target
            local n = 1
            while taken[name] do
                n = n + 1
                name = w.target .. " " .. n
            end
            taken[name] = true
        end
        if name ~= current then
            table.insert(changes, { id = w.pair.chrome.id, name = name })
        end
    end
    return changes
end

-- Which Chrome window a clicked link should open in: the frontmost one on
-- the given space, so following a link never pulls the screen to another
-- space.
--   pairs_:  from matchWindows; each hs window carries `id` and `spaces`
--   spaceId: the space showing
--   order:   hs window ids front to back (the window server's order); a
--            window missing from it ranks behind every window in it
-- Returns that window's pair, or nil when no Chrome window is on the space.
function Chrome.linkTarget(pairs_, spaceId, order)
    local rank = {}
    for i, id in ipairs(order) do
        rank[id] = i
    end
    local best, bestRank
    for _, p in ipairs(pairs_) do
        local onSpace = false
        for _, s in ipairs(p.hs.spaces or {}) do
            if s == spaceId then
                onSpace = true
            end
        end
        local r = rank[p.hs.id] or math.huge
        if onSpace and (best == nil or r < bestRank) then
            best, bestRank = p, r
        end
    end
    return best
end

-- Where a clicked link goes, with an Inbox window (named inboxName):
--   1. the Inbox, when it is on the space showing;
--   2. else the frontmost Chrome window on the space showing (linkTarget);
--   3. else, by noChrome: "inbox" the Inbox wherever it is (a new one when
--      there is none), "newWindow" a new window here, anything else nil.
-- inboxName nil leaves out 1 and makes "inbox" act as "newWindow".
-- Returns {pair=<pair or nil>, inbox=<bool>}: pair nil means a new window
-- (a new Inbox when inbox is true). nil hands the link to Chrome.
function Chrome.linkRoute(pairs_, spaceId, order, inboxName, noChrome)
    local inbox
    if inboxName ~= nil then
        for _, p in ipairs(pairs_) do
            if p.chrome.givenName == inboxName then
                inbox = p
                break
            end
        end
    end
    if inbox then
        for _, s in ipairs(inbox.hs.spaces or {}) do
            if s == spaceId then
                return { pair = inbox, inbox = true }
            end
        end
    end
    local here = Chrome.linkTarget(pairs_, spaceId, order)
    if here then
        return { pair = here, inbox = false }
    end
    if noChrome == "inbox" and inboxName ~= nil then
        return { pair = inbox, inbox = true }
    elseif noChrome == "inbox" or noChrome == "newWindow" then
        return { inbox = false }
    end
    return nil
end

-- A cheap fingerprint of everything a pass depends on that can change
-- without an event: which space each known Chrome window is on, and the name
-- each space wants. Equal fingerprints mean the last settled pass still holds.
--   spacesById:  hs window id -> list of space ids (empty once it is gone)
--   spaceNames:  spaceId -> name, as for plan
function Chrome.signature(spacesById, spaceNames)
    local parts = {}
    for id, spaces in pairs(spacesById) do
        local s = {}
        for i, spaceId in ipairs(spaces) do
            s[i] = tostring(spaceId)
        end
        parts[#parts + 1] = "w" .. tostring(id) .. "@" .. table.concat(s, ",")
    end
    for spaceId, name in pairs(spaceNames) do
        parts[#parts + 1] = "s" .. tostring(spaceId) .. "=" .. name
    end
    table.sort(parts)
    return table.concat(parts, "\n")
end

return Chrome
