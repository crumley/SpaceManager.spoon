local MissionControl = require("mission_control")

-- Plain Lua only: every AX object, clock tick, screen, and space is injected.
local function ax(id, kids, attrs)
    local element = { attrs = attrs or {}, presses = 0 }
    element.attrs.AXIdentifier = id
    element.attrs.AXChildren = kids or {}
    function element:attributeValue(name)
        if self.failAttribute == name then error("stale AX element") end
        return self.attrs[name]
    end
    function element:performAction(action)
        assert.are.equal("AXPress", action)
        self.presses = self.presses + 1
        if self.action then return self.action() end
        return true
    end
    return element
end

local function display(id, frame)
    local first, second, third = ax("mc.space"), ax("mc.space"), ax("mc.space")
    local list = ax("mc.spaces.list", { first, second, third })
    local bar = ax("mc.spaces", { list })
    return ax("mc.display", { bar }, { AXDisplayID = id, AXFrame = frame }),
        { first, second, third }, bar, list
end

local function screen(id, uuid, frame)
    return {
        id = function() return id end,
        getUUID = function() return uuid end,
        fullFrame = function() return frame end,
        -- Using the usable frame here is a regression: MC includes the menu bar.
        frame = function() error("must use fullFrame, not frame") end,
    }
end

local function fixture()
    local f = {
        ticks = 0, timers = {}, roots = {}, toggles = 0, focused = 101,
        events = {}, allSpaces = { A = { 101, 102, 103 }, B = { 201, 202, 203 } },
        frame = { x = 0, y = 0, w = 1440, h = 900 },
    }
    f.screen = screen(11, "A", f.frame)
    f.otherScreen = screen(22, "B", { x = 1440, y = 0, w = 1920, h = 1080 })
    f.display, f.buttons, f.bar, f.list = display(11, f.frame)
    f.screens = { f.screen, f.otherScreen }
    function f:install(layout, displays)
        displays = displays or { self.display }
        self.roots = {}
        if layout == "dock" then
            self.roots["com.apple.dock"] = ax("dock", { ax("mc", displays) })
        else
            -- Deliberately NO Dock process/mc stub in the new layout.
            self.roots["com.apple.WindowManager"] = ax("wm", displays)
        end
    end
    function f:step(count)
        for _ = 1, count or 1 do
            self.ticks = self.ticks + 1
            -- Snapshot permits callbacks to stop or replace their own timer.
            local snapshot = { table.unpack(self.timers) }
            for _, t in ipairs(snapshot) do
                if t.active then t.callback() end
            end
        end
    end
    function f:activeTimers()
        local count = 0
        for _, t in ipairs(self.timers) do if t.active then count = count + 1 end end
        return count
    end
    function f.done(ok, err)
        f.events[#f.events + 1] = { ok = ok, err = err }
    end
    local deps = {
        applicationElement = function(bundle)
            if f.failRoot == bundle then error("AX application unavailable") end
            return f.roots[bundle]
        end,
        timer = {
            secondsSinceEpoch = function() return f.ticks / 20 end,
            doEvery = function(interval, callback)
                assert.are.equal(0.05, interval)
                local t = { active = true, callback = callback }
                function t:stop() self.active = false end
                f.timers[#f.timers + 1] = t
                return t
            end,
        },
        screens = { allScreens = function() return f.screens end },
        spaces = {
            MCwaitTime = 0.3,
            spaceDisplay = function(id)
                for uuid, ids in pairs(f.allSpaces) do
                    for _, candidate in ipairs(ids) do if candidate == id then return uuid end end
                end
            end,
            spacesForScreen = function(uuid) return f.allSpaces[uuid] end,
            focusedSpace = function() return f.focused end,
            toggleMissionControl = function()
                f.toggles = f.toggles + 1
                if f.mc:isOpen() then f.roots = {}
                elseif f.onOpen then f.onOpen()
                else f:install("windowmanager") end
            end,
        },
    }
    f.deps = deps
    f.mc = MissionControl.new(deps)
    return f
end

local function assertStopped(f)
    assert.are.equal(0, f:activeTimers())
    assert.is_nil(f.mc.switchTimer)
end

local function assertFailure(f, message)
    assert.are.equal(1, #f.events)
    assert.is_nil(f.events[1].ok)
    assert.are.equal(message, f.events[1].err)
    assertStopped(f)
end

describe("MissionControl", function()
    describe("AX layouts and lifecycle", function()
        it("discovers the old Dock mc/display/spaces/list layout", function()
            local f = fixture()
            f:install("dock")
            assert.is_true(f.mc:isOpen())
            assert.are.equal(f.buttons[2], f.mc:_spaceButton(f.screen, 2))
        end)

        it("discovers WindowManager mc.display without a Dock mc stub", function()
            local f = fixture()
            f:install("windowmanager")
            assert.is_nil(f.roots["com.apple.dock"])
            assert.is_true(f.mc:isOpen())
            assert.are.equal(f.buttons[2], f.mc:_spaceButton(f.screen, 2))
        end)

        it("prefers real WindowManager displays over a stale Dock tree", function()
            local f = fixture()
            local stale = display(11, f.frame)
            f:install("windowmanager")
            f.roots["com.apple.dock"] = ax("dock", { ax("mc", { stale }) })
            assert.are.equal(f.buttons[2], f.mc:_spaceButton(f.screen, 2))
        end)

        it("does not mistake Stage Manager sm.space for Mission Control", function()
            local f = fixture()
            f.roots["com.apple.WindowManager"] = ax("wm", { ax("sm.space", { f.display }) })
            assert.is_false(f.mc:isOpen())
            assert.is_nil(f.mc:_spaceButton(f.screen, 2))
            f.mc:open()
            assert.are.equal(1, f.toggles)
        end)

        it("does not toggle an already-open Mission Control in either layout", function()
            for _, layout in ipairs({ "dock", "windowmanager" }) do
                local f = fixture()
                f:install(layout)
                f.mc:open()
                f.mc:open()
                f.mc:gotoSpace(102, f.done)
                assert.are.equal(0, f.toggles)
                f.mc:cancelSwitch()
            end
        end)

        it("recognizes a partial Dock mc root without closing it while opening", function()
            local f = fixture()
            f:install("dock", {})
            assert.is_true(f.mc:isOpen())
            f.mc:open()
            assert.are.equal(0, f.toggles)
            assert.is_nil(f.mc:_spaceButton(f.screen, 2))
        end)

        it("opens and closes idempotently", function()
            local f = fixture()
            f.mc:close()
            assert.are.equal(0, f.toggles)
            f.mc:open()
            f.mc:open()
            assert.are.equal(1, f.toggles)
            f.mc:close()
            f.mc:close()
            assert.are.equal(2, f.toggles)
            assert.is_false(f.mc:isOpen())
        end)

        it("does not cache AX elements across openings", function()
            local f = fixture()
            f:install("dock")
            assert.are.equal(f.buttons[2], f.mc:_spaceButton(f.screen, 2))
            f.mc:close()
            local fresh, buttons = display(11, f.frame)
            f:install("windowmanager", { fresh })
            assert.are.equal(buttons[2], f.mc:_spaceButton(f.screen, 2))
        end)
    end)

    describe("display selection", function()
        it("selects by display id rather than enumeration order or frame", function()
            local f = fixture()
            local wrong = display(22, f.frame)
            f.display.attrs.AXFrame = { x = 9000, y = 0, w = 1, h = 1 }
            f:install("windowmanager", { wrong, f.display })
            assert.are.equal(f.buttons[2], f.mc:_spaceButton(f.screen, 2))
        end)

        it("falls back to the full screen frame when AXDisplayID is absent", function()
            local f = fixture()
            f.display.attrs.AXDisplayID = nil
            f:install("windowmanager")
            assert.are.equal(f.buttons[2], f.mc:_spaceButton(f.screen, 2))
        end)

        it("allows one-point frame rounding differences", function()
            local f = fixture()
            f.display.attrs.AXDisplayID = nil
            f.display.attrs.AXFrame = { x = 1, y = -1, w = 1441, h = 899 }
            f:install("dock")
            assert.are.equal(f.buttons[2], f.mc:_spaceButton(f.screen, 2))
        end)

        it("rejects mismatched ids even if the frame matches", function()
            local f = fixture()
            f.display.attrs.AXDisplayID = 22
            f:install("windowmanager")
            assert.is_nil(f.mc:_spaceButton(f.screen, 2))
        end)

        it("rejects missing, incomplete, or mismatched fallback frames", function()
            local f = fixture()
            f.display.attrs.AXDisplayID = nil
            f:install("windowmanager")
            for _, frame in ipairs({ {}, { x = 0, y = 0, w = 1440 },
                { x = 2, y = 0, w = 1440, h = 900 },
                { x = 0, y = 25, w = 1440, h = 875 } }) do
                f.display.attrs.AXFrame = frame
                assert.is_nil(f.mc:_spaceButton(f.screen, 2))
            end
            f.display.attrs.AXFrame = nil
            assert.is_nil(f.mc:_spaceButton(f.screen, 2))
        end)

        it("rejects non-table AXFrame and fullFrame values without throwing", function()
            local f = fixture()
            f.display.attrs.AXDisplayID = nil
            f:install("windowmanager")
            for _, invalid in ipairs({ false, 17, "unavailable" }) do
                f.display.attrs.AXFrame = invalid
                assert.is_nil(f.mc:_spaceButton(f.screen, 2))
                f.display.attrs.AXFrame = f.frame
                local badScreen = screen(11, "A", invalid)
                assert.is_nil(f.mc:_spaceButton(badScreen, 2))
            end
            local badScreen = screen(11, "A", nil)
            assert.is_nil(f.mc:_spaceButton(badScreen, 2))
            assert.are.equal(f.buttons[2], f.mc:_spaceButton(f.screen, 2))
        end)

        it("uses the target display's local space index, not a global index", function()
            local f = fixture()
            local other, buttons = display(22)
            f:install("windowmanager", { f.display, other })
            assert.is_true(f.mc:gotoSpace(202, f.done))
            f:step(6)
            assert.are.equal(1, buttons[2].presses)
            assert.are.equal(0, f.buttons[2].presses)
            f.focused = 202
            f:step()
            assert.are.same({ { ok = true } }, f.events)
            assertStopped(f)
        end)
    end)

    describe("asynchronous switching", function()
        it("waits for MC animation, presses once, and verifies focusedSpace", function()
            local f = fixture()
            assert.is_true(f.mc:gotoSpace(102, f.done))
            assert.are.equal(1, f.toggles)
            assert.are.equal(0, f.buttons[2].presses)
            f:step(5)
            assert.are.equal(0, f.buttons[2].presses)
            f:step()
            assert.are.equal(1, f.buttons[2].presses)
            assert.are.equal(0, #f.events) -- AXPress success is not switch success.
            f:step(10)
            assert.are.equal(1, f.buttons[2].presses)
            assert.are.equal(0, #f.events)
            f.focused = 102
            f:step()
            assert.are.same({ { ok = true } }, f.events)
            assertStopped(f)
            f:step(100)
            assert.are.equal(1, #f.events)
        end)

        it("uses the default wait when MCwaitTime is absent", function()
            local f = fixture()
            f.deps.spaces.MCwaitTime = nil
            f.mc:gotoSpace(102)
            f:step(5)
            assert.are.equal(0, f.buttons[2].presses)
            f:step()
            assert.are.equal(1, f.buttons[2].presses)
            f.mc:cancelSwitch()
        end)

        it("honors a configured MCwaitTime", function()
            local f = fixture()
            f.deps.spaces.MCwaitTime = 0.5
            f.mc:gotoSpace(102)
            f:step(9)
            assert.are.equal(0, f.buttons[2].presses)
            f:step()
            assert.are.equal(1, f.buttons[2].presses)
            f.mc:cancelSwitch()
        end)

        it("retries a progressively populated WindowManager startup tree", function()
            local f = fixture()
            f.onOpen = function() end -- Opening initially exposes no AX tree.
            f.mc:gotoSpace(102, f.done)
            f:step(6)
            f:install("windowmanager", { ax("mc.display", {}, { AXDisplayID = 11 }) })
            f:step(2)
            f:install("windowmanager")
            f.display.attrs.AXChildren = {}
            f:step(2)
            f.display.attrs.AXChildren = { f.bar }
            f.bar.attrs.AXChildren = {}
            f:step(2)
            f.bar.attrs.AXChildren = { f.list }
            f.list.attrs.AXChildren = { f.buttons[1] }
            f:step(2)
            assert.are.equal(0, f.buttons[2].presses)
            f.list.attrs.AXChildren = f.buttons
            f:step()
            assert.are.equal(1, f.buttons[2].presses)
            assert.are.equal(1, f.toggles) -- No toggle/reopen during tree retries.
            f.focused = 102
            f:step()
            assert.are.same({ { ok = true } }, f.events)
            assertStopped(f)
        end)

        it("retries a partial legacy Dock startup tree", function()
            local f = fixture()
            f:install("dock", {})
            f.mc:gotoSpace(102, f.done)
            f:step(10)
            assert.are.equal(0, f.buttons[2].presses)
            f:install("dock")
            f:step()
            assert.are.equal(1, f.buttons[2].presses)
            assert.are.equal(0, f.toggles)
            f.mc:cancelSwitch()
        end)

        it("accepts focus reaching the target before an AX button is pressed", function()
            local f = fixture()
            f.mc:gotoSpace(102, f.done)
            f.focused = 102
            f:step()
            assert.are.equal(0, f.buttons[2].presses)
            assert.are.same({ { ok = true } }, f.events)
            assertStopped(f)
        end)
    end)

    describe("timeouts and AX failures", function()
        it("times out and closes an opening it owns when no button appears", function()
            local f = fixture()
            f.onOpen = function() f:install("windowmanager", {}) end
            f.mc:gotoSpace(102, f.done)
            -- A partial mc root becomes visible, but never a display or button.
            f:install("dock", {})
            f:step(59)
            assert.are.equal(0, #f.events)
            f:step()
            assertFailure(f, "Mission Control space button did not appear")
            assert.are.equal(2, f.toggles)
            assert.is_false(f.mc:isOpen())
            f:step(20)
            assert.are.equal(1, #f.events)
        end)

        it("does not close Mission Control that was already open on timeout", function()
            local f = fixture()
            f:install("windowmanager")
            f.mc:gotoSpace(102, f.done)
            f:step(60)
            assertFailure(f, "Mission Control did not switch to the selected space")
            assert.are.equal(1, f.buttons[2].presses)
            assert.are.equal(0, f.toggles)
            assert.is_true(f.mc:isOpen())
        end)

        it("does not report AXPress success as completion and cleans up on timeout", function()
            local f = fixture()
            f.mc:gotoSpace(102, f.done)
            f:step(60)
            assertFailure(f, "Mission Control did not switch to the selected space")
            assert.are.equal(2, f.toggles)
            assert.is_false(f.mc:isOpen())
        end)

        it("retries a failed AXPress and reports its error at timeout", function()
            local f = fixture()
            f.buttons[2].action = function() return nil, "AX action unavailable" end
            f.mc:gotoSpace(102, f.done)
            f:step(60)
            assertFailure(f, "AX action unavailable")
            assert(f.buttons[2].presses > 1)
            assert.are.equal(2, f.toggles)
        end)

        it("catches thrown AXPress errors and permits recovery", function()
            local f = fixture()
            f.buttons[2].action = function() error("stale button") end
            f.mc:gotoSpace(102, f.done)
            f:step(6)
            assert.are.equal(1, f.buttons[2].presses)
            assert.are.equal(0, #f.events)
            f.buttons[2].action = nil
            f:step()
            assert.are.equal(2, f.buttons[2].presses)
            f.focused = 102
            f:step()
            assert.are.same({ { ok = true } }, f.events)
            assertStopped(f)
        end)

        it("reports a thrown AXPress error rather than escaping the timer", function()
            local f = fixture()
            f.buttons[2].action = function() error("stale button") end
            f.mc:gotoSpace(102, f.done)
            f:step(60)
            assert.are.equal(1, #f.events)
            assert.is_nil(f.events[1].ok)
            assert(f.events[1].err:find("stale button", 1, true))
            assertStopped(f)
        end)

        it("falls back to Dock when the WindowManager AX application throws", function()
            local f = fixture()
            f.failRoot = "com.apple.WindowManager"
            f:install("dock")
            assert.is_true(f.mc:isOpen())
            assert.are.equal(f.buttons[2], f.mc:_spaceButton(f.screen, 2))
        end)

        it("tolerates missing applications and failed AXChildren/AXIdentifier reads", function()
            local f = fixture()
            assert.is_false(f.mc:isOpen())
            f:install("windowmanager")
            local root = f.roots["com.apple.WindowManager"]
            root.failAttribute = "AXChildren"
            assert.is_false(f.mc:isOpen())
            root.failAttribute = nil
            f.display.failAttribute = "AXIdentifier"
            assert.is_false(f.mc:isOpen())
            f.display.failAttribute = nil
            f.list.failAttribute = "AXChildren"
            f.mc:gotoSpace(102, f.done)
            f:step(10)
            assert.are.equal(0, f.buttons[2].presses)
            f.list.failAttribute = nil
            f:step()
            assert.are.equal(1, f.buttons[2].presses)
            f.mc:cancelSwitch()
        end)

        it("ignores non-table root AXChildren and still falls back to Dock", function()
            local f = fixture()
            f:install("dock")
            local root = ax("wm")
            f.roots["com.apple.WindowManager"] = root
            for _, invalid in ipairs({ false, 17, "unavailable" }) do
                root.attrs.AXChildren = invalid
                assert.is_true(f.mc:isOpen())
                assert.are.equal(f.buttons[2], f.mc:_spaceButton(f.screen, 2))
            end
            root.attrs.AXChildren = nil
            assert.are.equal(f.buttons[2], f.mc:_spaceButton(f.screen, 2))
        end)

        it("retries non-table space-list AXChildren until valid children arrive", function()
            local f = fixture()
            f:install("windowmanager")
            f.mc:gotoSpace(102, f.done)
            f.list.attrs.AXChildren = false
            f:step(6)
            for _, invalid in ipairs({ 17, "unavailable" }) do
                f.list.attrs.AXChildren = invalid
                f:step()
            end
            f.list.attrs.AXChildren = nil
            f:step()
            assert.are.equal(0, f.buttons[2].presses)
            assert.are.equal(0, #f.events)
            f.list.attrs.AXChildren = f.buttons
            f:step()
            assert.are.equal(1, f.buttons[2].presses)
            f.focused = 102
            f:step()
            assert.are.same({ { ok = true } }, f.events)
            assertStopped(f)
        end)

        it("uses frame fallback when AXDisplayID cannot be read", function()
            local f = fixture()
            f.display.failAttribute = "AXDisplayID"
            f:install("windowmanager")
            assert.are.equal(f.buttons[2], f.mc:_spaceButton(f.screen, 2))
        end)
    end)

    describe("cancellation and target validation", function()
        it("inherits opening ownership when a replacement times out", function()
            local f = fixture()
            f.mc:gotoSpace(102, function() error("superseded callback") end)
            f:step(2)
            f.mc:gotoSpace(103, f.done)
            f:step(60)
            assertFailure(f, "Mission Control did not switch to the selected space")
            assert.are.equal(2, f.toggles)
            assert.is_false(f.mc:isOpen())
        end)

        it("does not toggle twice when superseded before the AX tree appears", function()
            local f = fixture()
            f.onOpen = function() end
            f.mc:gotoSpace(102, function() error("superseded callback") end)
            f.mc:gotoSpace(103, f.done)
            assert.are.equal(1, f.toggles)
            f:step(6)
            f:install("windowmanager")
            f:step()
            assert.are.equal(0, f.buttons[2].presses)
            assert.are.equal(1, f.buttons[3].presses)
            f.focused = 103
            f:step()
            assert.are.same({ { ok = true } }, f.events)
            assertStopped(f)
        end)

        it("closes a delayed opening if its replacement later times out", function()
            local f = fixture()
            f.onOpen = function() end
            f.mc:gotoSpace(102)
            f.mc:gotoSpace(103, f.done)
            f:step(6)
            f:install("windowmanager")
            f:step(54)
            assertFailure(f, "Mission Control did not switch to the selected space")
            assert.are.equal(2, f.toggles)
            assert.is_false(f.mc:isOpen())
        end)

        it("preserves preexisting Mission Control when a replacement times out", function()
            local f = fixture()
            f:install("windowmanager")
            f.mc:gotoSpace(102)
            f:step(2)
            f.mc:gotoSpace(103, f.done)
            f:step(60)
            assertFailure(f, "Mission Control did not switch to the selected space")
            assert.are.equal(0, f.toggles)
            assert.is_true(f.mc:isOpen())
        end)

        it("reopens for a replacement after the previous AXPress closed MC", function()
            local f = fixture()
            f.buttons[2].action = function()
                f.roots = {}
                f.focused = 102
                return true
            end
            f.mc:gotoSpace(102, function() error("superseded callback") end)
            f:step(6)
            f.mc:gotoSpace(103, f.done)
            assert.are.equal(2, f.toggles)
            f:step(6)
            assert.are.equal(1, f.buttons[3].presses)
            f.focused = 103
            f:step()
            assert.are.same({ { ok = true } }, f.events)
            assertStopped(f)
        end)

        it("waits for a previous AXPress to close MC before reopening", function()
            local f = fixture()
            f.mc:gotoSpace(102, function() error("superseded callback") end)
            f:step(6)
            f.mc:gotoSpace(103, f.done)
            f:step(8)
            assert.are.equal(0, f.buttons[3].presses)
            assert.are.equal(1, f.toggles)
            f.roots = {}
            f.focused = 102
            f:step()
            assert.are.equal(2, f.toggles)
            f:step(6)
            assert.are.equal(1, f.buttons[3].presses)
            f.focused = 103
            f:step()
            assert.are.same({ { ok = true } }, f.events)
            assertStopped(f)
        end)

        it("inherits the closing phase through multiple replacements", function()
            local f = fixture()
            f.mc:gotoSpace(102)
            f:step(6)
            f.mc:gotoSpace(103)
            f.mc:gotoSpace(102, f.done)
            f:step(8)
            assert.are.equal(1, f.buttons[2].presses)
            assert.are.equal(0, f.buttons[3].presses)
            f.roots = {}
            f:step()
            assert.are.equal(2, f.toggles)
            f:step(6)
            assert.are.equal(2, f.buttons[2].presses)
            f.focused = 102
            f:step()
            assert.are.same({ { ok = true } }, f.events)
            assertStopped(f)
        end)

        it("cancels a pending switch without pressing or invoking completion", function()
            local f = fixture()
            f.mc:gotoSpace(102, f.done)
            f.mc:cancelSwitch()
            f.mc:cancelSwitch()
            assertStopped(f)
            f:step(100)
            assert.are.equal(0, f.buttons[2].presses)
            assert.are.equal(0, #f.events)
        end)

        it("cancels a switch after AXPress without late completion", function()
            local f = fixture()
            f.mc:gotoSpace(102, f.done)
            f:step(6)
            f.mc:cancelSwitch()
            f.focused = 102
            f:step(100)
            assert.are.equal(1, f.buttons[2].presses)
            assert.are.equal(0, #f.events)
            assertStopped(f)
        end)

        it("supersedes a pending request and only completes its replacement", function()
            local f = fixture()
            local oldEvents = {}
            f.mc:gotoSpace(102, function(ok) oldEvents[#oldEvents + 1] = { ok = ok } end)
            f:step(2)
            f.mc:gotoSpace(103, f.done)
            assert.are.equal(1, f:activeTimers())
            f:step(6)
            assert.are.equal(0, f.buttons[2].presses)
            assert.are.equal(1, f.buttons[3].presses)
            assert.are.equal(1, f.toggles)
            f.focused = 103
            f:step(100)
            assert.are.same({}, oldEvents)
            assert.are.same({ { ok = true } }, f.events)
            assertStopped(f)
        end)

        it("rejects unknown space ids without opening or creating a timer", function()
            local f = fixture()
            for _, id in ipairs({ 999, -1, "102" }) do
                local ok, err = f.mc:gotoSpace(id, f.done)
                assert.is_nil(ok)
                assert.are.equal("Space is no longer available", err)
            end
            assert.are.equal(0, f.toggles)
            assert.are.equal(0, #f.events)
            assertStopped(f)
        end)

        it("rejects spaces whose display is disconnected", function()
            local f = fixture()
            f.screens = { f.screen }
            local ok, err = f.mc:gotoSpace(202, f.done)
            assert.is_nil(ok)
            assert.are.equal("Space is no longer available", err)
            assert.are.equal(0, f.toggles)
            assertStopped(f)
        end)

        it("rejects a space absent from the reported display's current list", function()
            local f = fixture()
            f.deps.spaces.spaceDisplay = function() return "A" end
            local ok, err = f.mc:gotoSpace(999, f.done)
            assert.is_nil(ok)
            assert.are.equal("Space is no longer available", err)
            assertStopped(f)
        end)

        it("accepts the current space immediately without opening MC", function()
            local f = fixture()
            assert.is_true(f.mc:gotoSpace(101, f.done))
            assert.are.same({ { ok = true } }, f.events)
            assert.are.equal(0, f.toggles)
            assertStopped(f)
        end)

        it("closes already-open MC for the current space and cancels a pending request", function()
            local f = fixture()
            f:install("windowmanager")
            f.mc:gotoSpace(102, function() error("superseded callback must not fire") end)
            assert.is_true(f.mc:gotoSpace(101, f.done))
            assert.are.equal(1, f.toggles)
            assert.is_false(f.mc:isOpen())
            assert.are.same({ { ok = true } }, f.events)
            assertStopped(f)
            f:step(100)
        end)
    end)
end)
