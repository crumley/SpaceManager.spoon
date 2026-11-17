-- Exercise Chrome reconciliation with Hammerspoon snapshots, without Apple
-- Events or an installed spoon. Load init.lua in its own environment so these
-- fakes cannot leak into the pure-module tests.
local function spoon(windows, scripted, primarySpaces)
    local spaces = primarySpaces or { 16, 42 }
    local effects = { names = {}, labels = {} }
    local app = {
        allWindows = function() return windows end,
        isFrontmost = function() return true end,
    }
    local deps = {
        ["hs.logger"] = { new = function()
            return { d = function() end, i = function() end, w = function() end }
        end },
        ["hs.application"] = { get = function() return app end },
        ["hs.timer"] = { secondsSinceEpoch = function() return 100 end },
        ["hs.spaces"] = {
            allSpaces = function() return { primary = spaces } end,
            windowSpaces = function(w)
                if type(w) == "table" then return w.spaces end
                for _, window in ipairs(windows) do
                    if window:id() == w then return window.spaces end
                end
            end,
        },
        ["hs.screen"] = { primaryScreen = function()
            return { getUUID = function() return "primary" end }
        end },
        ["hs.inspect"] = function() return "" end,
        ["hs.json"] = {
            decode = function(value) return value end,
            encode = function() return "[]" end,
        },
    }
    local env = setmetatable({
        hs = { spoons = { resourcePath = function(path) return path end } },
        require = function(name) return deps[name] or {} end,
        dofile = function(path)
            if path == "jxa.lua" then
                return { run = function(script)
                    effects.script = script
                    return true, scripted
                end }
            end
            return dofile(path)
        end,
    }, { __index = _G })
    local m = assert(loadfile("init.lua", "t", env))()
    m.state = { getSpaceById = function() end }
    m.spaceConfig = { "Today", "Planning" }
    m.chromeWindowNames = true
    m.chromeWindowLabels = true
    m.chromeWindowMarkers = false
    effects.readWindows = m._chromeScriptWindows
    m._chromeScriptWindows = function() return scripted end
    m._setChromeWindowNames = function(_, names) effects.names = names end
    m._applyChromeLabels = function(_, actions) effects.labels = actions end
    return m, effects
end

local function window(id, spaces, standard)
    return {
        id = function() return id end,
        isStandard = function() return standard ~= false end,
        title = function() return "Meet - Google Chrome" end,
        frame = function() return { x = 10, y = 20, w = 800, h = 600 } end,
        spaces = spaces,
    }
end

local function scriptWindow(name)
    return { id = "101", title = "Meet", givenName = name or "", front = true, labels = {}, closeable = true,
        bounds = { x = 10, y = 20, width = 800, height = 600 } }
end

describe("Chrome reconciliation", function()
    it("excludes non-closeable PiP before matching, even with a transient single-space snapshot", function()
        local pip, normal = scriptWindow(), scriptWindow()
        pip.closeable = false
        normal.id = "102"
        local m, effects = spoon({ window(1, { 16 }) }, { pip, normal })
        m._chromeScriptWindows = effects.readWindows
        m:reconcileChromeWindows(true)
        assert.is_true(effects.script:find("const closeables = ws.closeable();", 1, true) ~= nil)
        assert.is_true(effects.script:find("closeable: closeables[i]", 1, true) ~= nil)
        assert.are.same({ ["102"] = "01 - Today" }, effects.names)
        assert.are.equal("102", effects.labels[1].id)
    end)

    it("uses the ordinal, not ManagedSpaceID, for names, labels and page numbers", function()
        local m, effects = spoon({ window(1, { 16 }) }, { scriptWindow() })
        m:reconcileChromeWindows(true)
        assert.are.same({ ["101"] = "01 - Today" }, effects.names)
        assert.are.equal("01 - Today", m:spaceLabel(16))
        assert.is_nil(m:spaceLabel(1))
        assert.are.equal(1, #effects.labels)
        assert.is_true(effects.labels[1].add:find("name=01%20-%20Today&n=01&", 1, true) ~= nil)
    end)

    it("does not name a window without a known space", function()
        local m, effects = spoon({ window(1, {}) }, { scriptWindow() })
        m:reconcileChromeWindows(true)
        assert.are.same({}, effects.names)
        assert.are.same({}, effects.labels)
    end)

    it("does not give Meet PiP the last desktop's name from its reverse all-spaces list", function()
        -- Live snapshot: focused space 4 is desktop 1; PiP's first space 13
        -- is desktop 16, not its home. It reports AXStandardWindow too.
        local primary = { 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 15, 16, 17, 18, 19, 13 }
        local floating = { 13, 19, 18, 17, 16, 15, 14, 12, 11, 10, 9, 8, 7, 6, 5, 4 }
        local m, effects = spoon({ window(1, floating) }, { scriptWindow() }, primary)
        m.spaceConfig[16] = "oncall"
        m:reconcileChromeWindows(true)
        assert.are.same({}, effects.names)
        assert.are.same({}, effects.labels)
    end)

    it("does not add labels to a multi-space window even when already named", function()
        local m, effects = spoon({ window(1, { 42, 16 }) }, { scriptWindow("01 - Today") })
        m:reconcileChromeWindows(true)
        assert.are.same({}, effects.names)
        assert.are.same({}, effects.labels)
        assert.is_true(m.chromeLabelsPending)
    end)

    it("still updates existing labels for unmatched offspace windows", function()
        local scripted = scriptWindow("01 - Today")
        scripted.front = false
        scripted.labels = { { index = 1, url = "old-label" } }
        local m, effects = spoon({}, { scripted })
        m:reconcileChromeWindows(true)
        assert.are.same({}, effects.names)
        assert.are.equal(1, #effects.labels)
        assert.are.equal("101", effects.labels[1].id)
        assert.are.equal(1, effects.labels[1].set.index)
        assert.is_true(effects.labels[1].set.url:find("&n=01&", 1, true) ~= nil)
    end)

    it("does not reapply a popup name cleared by the tabless fallback", function()
        local normal = scriptWindow()
        normal.id = "102"
        local m, effects = spoon({ window(1, { 16 }), window(2, { 16 }) }, { scriptWindow(), normal })
        m._applyChromeLabels = function(_, actions)
            assert.are.equal(2, #actions)
            m.chromeTabless["101"] = true -- what the failed-add fallback discovers
        end
        m:reconcileChromeWindows(true)
        assert.are.same({ ["102"] = "01 - Today 2" }, effects.names)
    end)

    it("does not add a label to an unmatched popup with a previous space name", function()
        local m, effects = spoon({ window(1, { 16 }, false) }, { scriptWindow("01 - Today") })
        m:reconcileChromeWindows(true)
        assert.are.same({}, effects.names)
        assert.are.same({}, effects.labels)
    end)
end)
