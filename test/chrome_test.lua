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

describe("Chrome.plan", function()
    local names = { [1] = "Today", [3] = "Planning" }
    local managed = { Today = true, Planning = true, Research = true }

    local function pair(givenName, spaceId)
        return { chrome = { id = "c", givenName = givenName }, hs = { spaces = { spaceId } } }
    end

    it("names an unnamed window after its space", function()
        local changes = Chrome.plan({ pair("", 3) }, names, managed)
        assert.are.same({ { id = "c", name = "Planning" } }, changes)
    end)

    it("renames a window that moved to another named space", function()
        local changes = Chrome.plan({ pair("Today", 3) }, names, managed)
        assert.are.same({ { id = "c", name = "Planning" } }, changes)
    end)

    it("clears a managed name on an unnamed space", function()
        local changes = Chrome.plan({ pair("Research", 5) }, names, managed)
        assert.are.same({ { id = "c", name = "" } }, changes)
    end)

    it("leaves a person's own name alone", function()
        assert.are.same({}, Chrome.plan({ pair("Taxes", 3) }, names, managed))
        assert.are.same({}, Chrome.plan({ pair("Taxes", 5) }, names, managed))
    end)

    it("leaves a dated daily window alone wherever it is", function()
        assert.are.same({}, Chrome.plan({ pair("2026-09-30", 3) }, names, managed))
        assert.are.same({}, Chrome.plan({ pair("2026-09-30", 5) }, names, managed))
    end)

    it("does nothing when the name already matches", function()
        assert.are.same({}, Chrome.plan({ pair("Planning", 3) }, names, managed))
        assert.are.same({}, Chrome.plan({ pair("", 5) }, names, managed))
    end)

    it("does nothing for a window on no known space", function()
        assert.are.same({}, Chrome.plan({ { chrome = { id = "c", givenName = "" }, hs = { spaces = {} } } }, names, managed))
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
