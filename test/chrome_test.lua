local Chrome = require("chrome")

local function cw(id, title, givenName, x, y, w, h)
    return { id = id, title = title, givenName = givenName, bounds = { x = x, y = y, width = w, height = h } }
end

local function hw(id, title, x, y, w, h, spaces)
    return { id = id, title = title, frame = { x = x, y = y, w = w, h = h }, spaces = spaces }
end

describe("Chrome.matchWindows", function()
    it("pairs by title and frame", function()
        local chrome = { cw("c1", "Austin Leak Detection", "", 218, 33, 1501, 1030) }
        local hs = { hw(1, "Austin Leak Detection - Google Chrome - Ryan", 218, 33, 1503, 1030, { 3 }) }
        local pairs_ = Chrome.matchWindows(chrome, hs)
        assert.are.equal(1, #pairs_)
        assert.are.equal("c1", pairs_[1].chrome.id)
        assert.are.equal(1, pairs_[1].hs.id)
    end)

    it("uses the given name as title once a window is named", function()
        local chrome = { cw("c1", "Planning", "Planning", 0, 0, 100, 100) }
        local hs = { hw(1, "Planning - Google Chrome", 0, 0, 100, 100, { 3 }) }
        assert.are.equal(1, #Chrome.matchWindows(chrome, hs))
    end)

    it("matches a title Chrome shortened with an ellipsis", function()
        local chrome = {
            cw("c1", "hammerspoon: load hs.ipc, trace…Request #39 · crumley/dotfiles", "", 218, 33, 1503, 1030),
            cw("c2", "Austin Leak Detection", "", 218, 33, 1501, 1030),
        }
        local hs = {
            hw(1, "Austin Leak Detection - Google Chrome - Ryan", 218, 33, 1501, 1030, { 3 }),
            hw(2, "hammerspoon: load hs.ipc, trace AppJump, pick up its exposed-window fix by crumley · Pull Request #39 · crumley/dotfiles - Google Chrome - Ryan", 218, 33, 1503, 1030, { 3 }),
        }
        local pairs_ = Chrome.matchWindows(chrome, hs)
        assert.are.equal(2, #pairs_)
        for _, p in ipairs(pairs_) do
            if p.chrome.id == "c1" then assert.are.equal(2, p.hs.id) end
            if p.chrome.id == "c2" then assert.are.equal(1, p.hs.id) end
        end
    end)

    it("does not let an ellipsis tail match the wrong window", function()
        local chrome = { cw("c1", "Alpha…dotfiles", "", 0, 0, 100, 100) }
        local hs = { hw(1, "Alphabet soup - Google Chrome", 0, 0, 100, 100, { 3 }), hw(2, "Beta dotfiles - Google Chrome", 0, 0, 100, 100, { 3 }) }
        assert.are.equal(0, #Chrome.matchWindows(chrome, hs))
    end)

    it("does not treat a title prefix as a title match", function()
        local chrome = { cw("c1", "Plan", "", 0, 0, 100, 100) }
        local hs = { hw(1, "Planning - Google Chrome", 50, 50, 100, 100, { 3 }) }
        assert.are.equal(0, #Chrome.matchWindows(chrome, hs))
    end)

    it("separates same-sized windows by title", function()
        local chrome = { cw("c1", "Alpha", "", 0, 0, 100, 100), cw("c2", "Beta", "", 0, 0, 100, 100) }
        local hs = { hw(1, "Beta - Google Chrome", 0, 0, 100, 100, { 2 }), hw(2, "Alpha - Google Chrome", 0, 0, 100, 100, { 1 }) }
        local pairs_ = Chrome.matchWindows(chrome, hs)
        assert.are.equal(2, #pairs_)
        for _, p in ipairs(pairs_) do
            if p.chrome.id == "c1" then assert.are.equal(2, p.hs.id) end
            if p.chrome.id == "c2" then assert.are.equal(1, p.hs.id) end
        end
    end)

    it("falls back to the frame when the title changed but only one window fits", function()
        local chrome = { cw("c1", "Loading...", "", 10, 10, 800, 600) }
        local hs = { hw(1, "Loaded - Google Chrome", 10, 10, 800, 600, { 3 }), hw(2, "Other - Google Chrome", 0, 0, 100, 100, { 3 }) }
        local pairs_ = Chrome.matchWindows(chrome, hs)
        assert.are.equal(1, #pairs_)
        assert.are.equal(1, pairs_[1].hs.id)
    end)

    it("refuses an ambiguous frame-only match", function()
        local chrome = { cw("c1", "Loading...", "", 0, 0, 100, 100) }
        local hs = { hw(1, "A - Google Chrome", 0, 0, 100, 100, { 3 }), hw(2, "B - Google Chrome", 0, 0, 100, 100, { 4 }) }
        assert.are.equal(0, #Chrome.matchWindows(chrome, hs))
    end)
end)

describe("Chrome.spaceWindowName", function()
    it("prefixes the zero-padded space position", function()
        assert.are.equal("01 - Today", Chrome.spaceWindowName(1, "Today"))
        assert.are.equal("12 - Taxes", Chrome.spaceWindowName(12, "Taxes"))
    end)

    it("leads with the marker when there is one", function()
        assert.are.equal("🟥 01 - Today", Chrome.spaceWindowName(1, "Today", "🟥"))
        assert.are.equal("01 - Today", Chrome.spaceWindowName(1, "Today", ""))
        assert.is_nil(Chrome.spaceWindowName(1, nil, "🟥"))
    end)

    it("is nil for an unnamed space", function()
        assert.is_nil(Chrome.spaceWindowName(3, nil))
        assert.is_nil(Chrome.spaceWindowName(3, ""))
    end)
end)

describe("Chrome.plan", function()
    local names = { [1] = "01 - Today", [3] = "03 - Planning" }
    local none = {}

    local function pair(id, givenName, spaceId)
        return { chrome = { id = id, givenName = givenName }, hs = { spaces = { spaceId } } }
    end

    it("names an unnamed window after its space", function()
        local changes = Chrome.plan({ pair("10", "", 3) }, names, none)
        assert.are.same({ { id = "10", name = "03 - Planning" } }, changes)
    end)

    it("suffixes later windows on the same space, oldest first", function()
        local changes = Chrome.plan({ pair("12", "", 3), pair("9", "", 3), pair("10", "", 3) }, names, none)
        assert.are.same({
            { id = "9", name = "03 - Planning" },
            { id = "10", name = "03 - Planning 2" },
            { id = "12", name = "03 - Planning 3" },
        }, changes)
    end)

    it("takes the lowest suffix not already in use", function()
        local changes = Chrome.plan({ pair("1", "03 - Planning 2", 3), pair("2", "", 3) }, names, none)
        assert.are.same({ { id = "2", name = "03 - Planning" } }, changes)
    end)

    it("avoids a name in use by a window on another space", function()
        local changes = Chrome.plan({ pair("1", "03 - Planning", 1), pair("2", "", 3) }, names, none)
        assert.are.same({ { id = "2", name = "03 - Planning 2" } }, changes)
    end)

    it("avoids a name in use by a window it could not match", function()
        local all = { { id = "1", givenName = "03 - Planning" }, { id = "2", givenName = "" } }
        local changes = Chrome.plan({ pair("2", "", 3) }, names, none, all)
        assert.are.same({ { id = "2", name = "03 - Planning 2" } }, changes)
    end)

    it("leaves a named window alone, even one moved from another space", function()
        assert.are.same({}, Chrome.plan({ pair("1", "Taxes", 3) }, names, none))
        assert.are.same({}, Chrome.plan({ pair("1", "01 - Today", 3) }, names, none))
    end)

    it("leaves windows on an unnamed space unnamed", function()
        assert.are.same({}, Chrome.plan({ pair("1", "", 5) }, names, none))
    end)

    it("renames every window on a renamed space", function()
        local changes = Chrome.plan({ pair("1", "Taxes", 3), pair("2", "03 - Plans", 3), pair("3", "Other", 1) },
            names, { [3] = true })
        assert.are.same({
            { id = "1", name = "03 - Planning" },
            { id = "2", name = "03 - Planning 2" },
        }, changes)
    end)

    it("clears every window on a space whose name was cleared", function()
        local changes = Chrome.plan({ pair("1", "05 - Research", 5), pair("2", "", 5) }, names, { [5] = true })
        assert.are.same({ { id = "1", name = "" } }, changes)
    end)

    it("leaves a dated daily window alone, even on a renamed space", function()
        assert.are.same({}, Chrome.plan({ pair("1", "2026-09-30", 3) }, names, none))
        assert.are.same({}, Chrome.plan({ pair("1", "2026-09-30", 1) }, names, { [1] = true }))
    end)

    it("leaves a window named in keepNames alone, even on a renamed space", function()
        local keep = { ["📥 Inbox"] = true }
        assert.are.same({}, Chrome.plan({ pair("1", "📥 Inbox", 3) }, names, { [3] = true }, nil, keep))
    end)

    it("renumbers a window whose space moved", function()
        assert.are.same({ { id = "1", name = "03 - Planning" } }, Chrome.plan({ pair("1", "05 - Planning", 3) }, names, none))
        local marked = { [2] = "🟦 02 - ws/main" }
        assert.are.same({ { id = "1", name = "🟦 02 - ws/main" } },
            Chrome.plan({ pair("1", "🟩 04 - ws/main", 2) }, marked, none))
    end)

    it("renumbers a moved second window, keeping the names unique", function()
        local changes = Chrome.plan({ pair("1", "03 - Planning", 3), pair("2", "05 - Planning 2", 3) }, names, none)
        assert.are.same({ { id = "2", name = "03 - Planning 2" } }, changes)
    end)

    it("leaves a current second window and a look-alike name alone", function()
        assert.are.same({}, Chrome.plan({ pair("1", "03 - Planning 2", 3) }, names, none))
        assert.are.same({}, Chrome.plan({ pair("1", "05 - Planning ahead", 3) }, names, none))
    end)

    it("does nothing for a window on no known space", function()
        assert.are.same({}, Chrome.plan({ { chrome = { id = "c", givenName = "" }, hs = { spaces = {} } } }, names, none))
    end)
end)

describe("Chrome.linkTarget", function()
    local function pair(chromeId, hsId, spaceId)
        return { chrome = { id = chromeId }, hs = { id = hsId, spaces = { spaceId } } }
    end

    it("picks the frontmost Chrome window on the space showing", function()
        local pairs_ = { pair("a", 1, 3), pair("b", 2, 3), pair("c", 3, 5) }
        assert.are.equal("b", Chrome.linkTarget(pairs_, 3, { 9, 3, 2, 1 }).chrome.id)
    end)

    it("never picks a window on another space, however far forward", function()
        assert.are.equal("a", Chrome.linkTarget({ pair("a", 1, 3), pair("c", 3, 5) }, 3, { 3, 1 }).chrome.id)
    end)

    it("still picks a window on the space that is missing from the order", function()
        assert.are.equal("a", Chrome.linkTarget({ pair("a", 1, 3) }, 3, {}).chrome.id)
    end)

    it("is nil when no Chrome window is on the space", function()
        assert.is_nil(Chrome.linkTarget({ pair("c", 3, 5) }, 3, { 3 }))
    end)
end)

describe("Chrome.linkRoute", function()
    local INBOX = "📥 Inbox"
    local function pair(chromeId, hsId, spaceId, name)
        return { chrome = { id = chromeId, givenName = name }, hs = { id = hsId, spaces = { spaceId } } }
    end

    it("picks the Inbox on the space showing, over a window in front of it", function()
        local route = Chrome.linkRoute({ pair("a", 1, 3), pair("i", 2, 3, INBOX) }, 3, { 1, 2 }, INBOX, "inbox")
        assert.are.equal("i", route.pair.chrome.id)
        assert.is_true(route.inbox)
    end)

    it("picks the window on the space showing over the Inbox elsewhere", function()
        local route = Chrome.linkRoute({ pair("a", 1, 3), pair("i", 2, 5, INBOX) }, 3, { 2, 1 }, INBOX, "inbox")
        assert.are.equal("a", route.pair.chrome.id)
        assert.is_false(route.inbox)
    end)

    it("sends a link from a space without Chrome to the Inbox elsewhere", function()
        local route = Chrome.linkRoute({ pair("i", 2, 5, INBOX) }, 3, { 2 }, INBOX, "inbox")
        assert.are.equal("i", route.pair.chrome.id)
        assert.is_true(route.inbox)
    end)

    it("asks for a new Inbox when there is none", function()
        assert.are.same({ inbox = true }, Chrome.linkRoute({ pair("a", 1, 5) }, 3, { 1 }, INBOX, "inbox"))
    end)

    it("opens a new window here with noChrome newWindow, Inbox or not", function()
        assert.are.same({ inbox = false }, Chrome.linkRoute({ pair("i", 2, 5, INBOX) }, 3, { 2 }, INBOX, "newWindow"))
    end)

    it("hands the link to Chrome with any other noChrome", function()
        assert.is_nil(Chrome.linkRoute({ pair("i", 2, 5, INBOX) }, 3, { 2 }, INBOX, "chrome"))
    end)

    it("without an Inbox name, inbox means a new window here", function()
        assert.are.same({ inbox = false }, Chrome.linkRoute({ pair("i", 2, 5, INBOX) }, 3, { 2 }, nil, "inbox"))
    end)
end)

describe("Chrome.isDateName", function()
    it("recognises ISO dates only", function()
        assert.is_true(Chrome.isDateName("2026-09-30"))
        assert.is_false(Chrome.isDateName("Today"))
        assert.is_false(Chrome.isDateName("2026-09-30 notes"))
        assert.is_false(Chrome.isDateName(nil))
    end)
end)

describe("Chrome.signature", function()
    local names = { [3] = "Planning", [5] = "Taxes" }

    it("does not depend on iteration order", function()
        local a = Chrome.signature({ [1] = { 3 }, [2] = { 5 } }, names)
        local b = Chrome.signature({ [2] = { 5 }, [1] = { 3 } }, { [5] = "Taxes", [3] = "Planning" })
        assert.are.equal(a, b)
    end)

    it("changes when a window moves to another space", function()
        assert.are_not.equal(Chrome.signature({ [1] = { 3 } }, names), Chrome.signature({ [1] = { 5 } }, names))
    end)

    it("changes when a window is gone", function()
        assert.are_not.equal(Chrome.signature({ [1] = { 3 } }, names), Chrome.signature({ [1] = {} }, names))
    end)

    it("changes when a space is renamed", function()
        assert.are_not.equal(Chrome.signature({ [1] = { 3 } }, names),
            Chrome.signature({ [1] = { 3 } }, { [3] = "Plans", [5] = "Taxes" }))
    end)
end)

describe("Chrome.labelPlan", function()
    local urls = { ["🟥 01 - Today"] = "L?today", ["🟦 02 - Work"] = "L?work" }

    it("adds a label to a named front window", function()
        local plan = Chrome.labelPlan({ { id = "1", givenName = "🟥 01 - Today", front = true, labels = {} } }, urls)
        assert.are.same({ { id = "1", add = "L?today" } }, plan.actions)
        assert.are.same({}, plan.pending)
    end)

    it("waits for a window that is not in front", function()
        local plan = Chrome.labelPlan({ { id = "1", givenName = "🟦 02 - Work", front = false, labels = {} } }, urls)
        assert.are.same({}, plan.actions)
        assert.are.same({ "1" }, plan.pending)
    end)

    it("labels a second window on a space by its base name", function()
        local plan = Chrome.labelPlan({ { id = "1", givenName = "🟥 01 - Today 2", front = true, labels = {} } }, urls)
        assert.are.same({ { id = "1", add = "L?today" } }, plan.actions)
    end)

    it("leaves a correct label alone", function()
        local plan = Chrome.labelPlan({ { id = "1", givenName = "🟥 01 - Today", labels = { { index = 1, url = "L?today" } } } }, urls)
        assert.are.same({}, plan.actions)
        assert.are.same({}, plan.pending)
    end)

    it("points a stale label at the new name, wherever the window is", function()
        local plan = Chrome.labelPlan({ { id = "1", givenName = "🟦 02 - Work", front = false, labels = { { index = 2, url = "L?old" } } } }, urls)
        assert.are.same({ { id = "1", set = { index = 2, url = "L?work" } } }, plan.actions)
    end)

    it("closes the label of a window that lost its space name", function()
        local plan = Chrome.labelPlan({
            { id = "1", givenName = "", labels = { { index = 1, url = "L?today" } } },
            { id = "2", givenName = "My research", labels = { { index = 3, url = "L?work" } } },
        }, urls)
        assert.are.same({ { id = "1", close = { 1 } }, { id = "2", close = { 3 } } }, plan.actions)
    end)

    it("leaves the label of a window named for where its space used to be", function()
        -- Work moved from fourth to second; the window is renamed (and its
        -- label pointed at the new name) once its space is showing.
        local plan = Chrome.labelPlan({ { id = "1", givenName = "🟩 04 - Work", front = true,
            labels = { { index = 1, url = "L?work4" } } } }, urls)
        assert.are.same({}, plan.actions)
        assert.are.same({}, plan.pending)
    end)

    it("keeps the right one of several labels and closes the rest", function()
        local plan = Chrome.labelPlan({ { id = "1", givenName = "🟥 01 - Today", labels = {
            { index = 1, url = "L?old" }, { index = 2, url = "L?today" }, { index = 5, url = "L?today" } } } }, urls)
        assert.are.same({ { id = "1", close = { 5, 1 } } }, plan.actions)
    end)

    it("fixes the first label after closing extras to its left", function()
        local plan = Chrome.labelPlan({ { id = "1", givenName = "🟦 02 - Work", labels = {
            { index = 2, url = "L?old" }, { index = 4, url = "L?older" } } } }, urls)
        assert.are.same({ { id = "1", close = { 4 } }, { id = "1", set = { index = 2, url = "L?work" } } }, plan.actions)
    end)

    it("leaves windows without a space name and no labels alone", function()
        local plan = Chrome.labelPlan({ { id = "1", givenName = "📥 Inbox", front = true, labels = {} } }, urls)
        assert.are.same({}, plan.actions)
        assert.are.same({}, plan.pending)
    end)
end)

describe("Chrome.pageUrl", function()
    it("is the extension's page given its id", function()
        assert.are.equal("chrome-extension://abc/label.html", Chrome.pageUrl("label.html", "abc", "/x/y"))
    end)

    it("is the file on disk without one, its path escaped", function()
        assert.are.equal("file:///Users/me/My%20Spoons/SpaceManager.spoon/chrome-extension/day.html",
            Chrome.pageUrl("day.html", nil, "/Users/me/My Spoons/SpaceManager.spoon/chrome-extension"))
    end)
end)

describe("Chrome.dayDivider", function()
    it("titles the day as the extension titles its group", function()
        local d = Chrome.dayDivider({ year = 2026, month = 10, day = 4, wday = 1 })
        assert.are.same({ title = "📅 Sun, Oct 4", n = "4", bg = "9334e6", fg = "ffffff" }, d)
    end)

    it("colors each weekday its own way", function()
        local thu = Chrome.dayDivider({ year = 2026, month = 10, day = 8, wday = 5 })
        local fri = Chrome.dayDivider({ year = 2026, month = 10, day = 9, wday = 6 })
        assert.are.equal("📅 Thu, Oct 8", thu.title)
        assert.are_not.equal(thu.bg, fri.bg)
    end)
end)
