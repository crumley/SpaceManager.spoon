-- Mission Control's AX tree moved from Dock to WindowManager in macOS 27.
-- Keep this adapter local to the spoon, not a patch to hs.spaces or the app.
-- Dependencies are injected so both layouts and asynchronous switching can
-- be tested without Hammerspoon. Never cache AX elements across openings.
local MissionControl = {}
MissionControl.__index = MissionControl

local function children(element)
    if not element then return {} end
    local ok, value = pcall(element.attributeValue, element, "AXChildren")
    return ok and type(value) == "table" and value or {}
end

local function attribute(element, name)
    local ok, value = pcall(element.attributeValue, element, name)
    if ok then return value end
end

local function childWithId(element, id)
    for _, child in ipairs(children(element)) do
        if attribute(child, "AXIdentifier") == id then return child end
    end
end

function MissionControl.new(deps)
    return setmetatable({ deps = deps }, MissionControl)
end

function MissionControl:_root(bundle)
    local ok, root = pcall(self.deps.applicationElement, bundle)
    if ok then return root end
end

function MissionControl:_displays()
    local displays = {}
    for _, child in ipairs(children(self:_root("com.apple.WindowManager"))) do
        if attribute(child, "AXIdentifier") == "mc.display" then
            displays[#displays + 1] = child
        end
    end
    if #displays > 0 then return displays end
    local mc = childWithId(self:_root("com.apple.dock"), "mc")
    for _, child in ipairs(children(mc)) do
        if attribute(child, "AXIdentifier") == "mc.display" then
            displays[#displays + 1] = child
        end
    end
    return displays
end

function MissionControl:isOpen()
    return #self:_displays() > 0
        or childWithId(self:_root("com.apple.dock"), "mc") ~= nil
end

function MissionControl:open()
    if not self:isOpen() then self.deps.spaces.toggleMissionControl() end
end

function MissionControl:close()
    if self:isOpen() then self.deps.spaces.toggleMissionControl() end
end

local function sameFrame(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for _, key in ipairs({ "x", "y", "w", "h" }) do
        if type(a[key]) ~= "number" or math.abs(a[key] - b[key]) > 1 then return false end
    end
    return true
end

function MissionControl:_spaceButton(screen, index)
    for _, display in ipairs(self:_displays()) do
        local displayId = attribute(display, "AXDisplayID")
        -- Some OS versions omit AXDisplayID. Full frame, not the usable
        -- frame: the Mission Control group covers the menu bar and Dock too.
        if displayId == screen:id() or (displayId == nil
            and sameFrame(attribute(display, "AXFrame"), screen:fullFrame())) then
            local bar = childWithId(display, "mc.spaces")
            local list = childWithId(bar, "mc.spaces.list")
            return children(list)[index]
        end
    end
end

function MissionControl:cancelSwitch()
    if self.switchTimer then self.switchTimer:stop() end
    self.switchTimer = nil
    self.switchState = nil
end

-- Returns true when accepted, nil/error for an invalid target. Completion
-- (including a timeout or AX failure) is reported to done(ok, error).
function MissionControl:gotoSpace(spaceId, done)
    local spaces, timer = self.deps.spaces, self.deps.timer
    local uuid = spaces.spaceDisplay(spaceId)
    local screen
    for _, candidate in ipairs(self.deps.screens.allScreens()) do
        if candidate:getUUID() == uuid then screen = candidate; break end
    end
    local index
    for i, id in ipairs(uuid and spaces.spacesForScreen(uuid) or {}) do
        if id == spaceId then index = i; break end
    end
    if not screen or not index then return nil, "Space is no longer available" end
    local previous = self.switchState
    self:cancelSwitch()
    if spaces.focusedSpace() == spaceId then
        self:close()
        if done then done(true) end
        return true
    end

    local wasOpen = self:isOpen()
    local state = {
        owned = (previous and previous.owned) or not wasOpen,
        pressed = false,
        sawOpen = wasOpen
    }
    -- A replacement owns the original opening too. Do not toggle again
    -- while that opening is still waiting for its first AX tree. If the old
    -- request already pressed a button, let its closing animation finish
    -- before reopening for the replacement instead of pressing stale UI.
    local openingInFlight = previous and previous.owned
        and not previous.pressed and not previous.sawOpen
    state.waitingForClose = previous and (previous.pressed or previous.waitingForClose) and wasOpen
    if not openingInFlight and not state.waitingForClose then self:open() end
    self.switchState = state
    local started = timer.secondsSinceEpoch()
    local lastError = "Mission Control space button did not appear"
    local function finish(ok, err)
        self:cancelSwitch()
        if not ok and state.owned then self:close() end
        if done then done(ok, err) end
    end
    self.switchTimer = timer.doEvery(0.05, function()
        local elapsed = timer.secondsSinceEpoch() - started
        if spaces.focusedSpace() == spaceId then finish(true); return end
        if elapsed >= 3 then finish(nil, lastError); return end
        local open = self:isOpen()
        if open then state.sawOpen = true end
        if state.waitingForClose then
            if not open then
                self:open()
                state.waitingForClose = false
                state.sawOpen = false
                started = timer.secondsSinceEpoch()
            end
            return
        end
        if state.pressed or elapsed < (spaces.MCwaitTime or 0.3) then return end
        local button = self:_spaceButton(screen, index)
        if button then
            local ok, result, err = pcall(button.performAction, button, "AXPress")
            if ok and result then
                state.pressed = true
                lastError = "Mission Control did not switch to the selected space"
            else
                lastError = tostring(ok and err or result)
            end
        end
    end)
    return true
end

return MissionControl
