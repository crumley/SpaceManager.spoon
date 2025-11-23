--- === SpaceManager ===
---
---
local hslogger = require("hs.logger")
local hschooser = require("hs.chooser")
local hsapplication = require("hs.application")
local hssettings = require("hs.settings")
local hsspaces = require("hs.spaces")
local hsinspect = require("hs.inspect")
local hswindow = require("hs.window")
local hscanvas = require("hs.canvas")
local hsdrawing = require("hs.drawing")
local hslayout = require("hs.layout")
local hsscreen = require("hs.screen")
local hstimer = require("hs.timer")
local hsfnutils = require("hs.fnutils")
local hseventtap = require("hs.eventtap")
local hsosascript = require("hs.osascript")
local hsnotify = require("hs.notify")
local hsdialog = require("hs.dialog")

local State = dofile(hs.spoons.resourcePath("state.lua"))
local Menu = dofile(hs.spoons.resourcePath("menu.lua"))

local m = {}
m.__index = m

-- Metadata
m.name = "SpaceManager"
m.version = "0.1"
m.author = "crumley@gmail.com"
m.license = "MIT"
m.homepage = "https://github.com/Hammerspoon/Spoons"

m.logger = hslogger.new('SpaceManager', 'debug')

-- Settings

m.settingsKey = m.name .. ".state"

-- Hattip: https://apple.stackexchange.com/questions/419028/disable-the-dock-in-all-but-one-desktop-space-only
m.dockOnPrimaryOnly = false
m.desktopLozenge = false

-- Configuration
m.activityTemplates = {}
m.activityTemplatesLookup = {}

-- Helper function to iterate over activity templates in order
function m:orderedActivityTemplates()
    -- activityTemplates is now already an ordered array
    return self.activityTemplates
end

-- Helper function to convert ordered array to lookup table
function m:_buildActivityTemplatesLookup()
    self.activityTemplatesLookup = {}
    for _, activity in ipairs(self.activityTemplates) do
        if activity.id then
            self.activityTemplatesLookup[activity.id] = activity
        end
    end
end

local actions = {
    start = function(choice)
        local activityTemplateId = choice["activityTemplateId"]
        m:startActivityFromTemplate(activityTemplateId)
    end,

    stop = function(choice)
        local activityId = choice["activityId"]
        m:stopActivity(activityId)
    end,

    jump = function(choice)
        local activityId = choice["activityId"]
        local spaceId = m.state:getSpaceByActivityId(activityId).id
        if spaceId then
            hsspaces.gotoSpace(spaceId)
        else
            m.logger.e("No space found for activityId: ", activityId)
        end
    end,

    rename = function(choice)
        local activityId = choice["activityId"]
        m:renameActivity(activityId)
    end,

    assign = function(choice)
        local activityTemplateId = choice["activityTemplateId"]
        m:assignActivityToCurrentSpace(activityTemplateId)
    end,

    closeAll = function()
        m:closeAll()
    end,

    reset = function()
        m:reset()
    end,

    cleanup = function()
        m:cleanup()
    end
}

function m:init()
    m.logger.d('init')

    m.state = State.new()

    m.chooser = hschooser.new(function(choice)
        if choice then
            local actionName = choice["action"]
            if actionName ~= nil then
                m.logger.d('Select action', actionName)
                actions[actionName](choice)
                return
            end
        end
    end)
end

function m:start()
    m.logger.d("start: allSpaces: ", hsinspect(hsspaces.spacesForScreen("primary")))

    -- Build lookup table for ID-based access
    m:_buildActivityTemplatesLookup()

    -- Set the id field for each template (if not already set)
    for _, activity in ipairs(m.activityTemplates) do
        if not activity.id then
            m.logger.e("Activity template missing id field:", hsinspect(activity))
        end
    end

    if m.dockOnPrimaryOnly then
        local w = hsspaces.watcher.new(function(s)
            m:_onSpaceChanged(true)
        end)
        w.start(w)
        m:_onSpaceChanged(true)
    end

    if m.desktopLozenge then
        m.canvas = m:_createCanvas()
        m.canvas:show()
    end

    pcall(function()
        m:_restoreState()
    end)

    for _, activity in ipairs(m.activityTemplates) do
        if activity.permanent and #m.state:getActivitiesByTemplateId(activity.id) == 0 then
            m:startActivityFromTemplate(activity.id)
        end
    end
end

function m:show()
    m:showMenu()
end

function m:showMenu()
    local spaceInfo = m:_spaceInfo()
    local currentActivityId = spaceInfo.primaryActivity ~= nil and spaceInfo.primaryActivity.id or nil
    m.chooser:choices(Menu.generateChoices(m.activityTemplatesLookup, currentActivityId, m.state,
        m:orderedActivityTemplates()))
    m.chooser:show()
end

function m:startActivityFromTemplate(templateId, windowObjs)
    local template = m.activityTemplatesLookup[templateId]
    m.logger.d('startActivity template:', template)

    local activityId = m.state:activityStarted(templateId)

    -- If the activity was seeded with windows, record them
    if windowObjs ~= nil and #windowObjs > 0 then
        for _, window in ipairs(windowObjs) do
            local wid = window:id()
            m.state:windowMoved(wid, activityId)
        end
    end

    m:moveAppsToActivity(template["apps"], activityId)

    local space = m:_getDefaultSpace()
    if template["space"] then
        space = m:_createNewSpace()
    end

    m:moveActivityToSpace(activityId, space)
    hsspaces.gotoSpace(space)

    if template["layout"] then
        hslayout.apply(template["layout"])
    end

    m:_saveState()
end

function m:jumpToActivityId(activityId)
    local space = m.state:getSpaceByActivityId(activityId)
    local spaceId = space ~= nil and space.id or m:_getDefaultSpace()

    if spaceId ~= hsspaces.focusedSpace() then
        hsspaces.gotoSpace(spaceId)
    end
end

function m:renameActivity(activityId)
    local activity = m.state:getActivityById(activityId)
    if not activity then
        m.logger.e("Activity not found:", activityId)
        return
    end

    local template = m.activityTemplatesLookup[activity.typeId]
    if not template then
        m.logger.e("Template not found for activity:", activity.typeId)
        return
    end

    local templateName = template.text or template.name or activity.typeId

    -- Extract current suffix from activity name (everything after ":")
    local currentSuffix = ""
    local colonPos = string.find(activity.name, ":")
    if colonPos then
        currentSuffix = string.sub(activity.name, colonPos + 2) -- +2 to skip ": "
    end

    -- Show text prompt for new suffix and auto-focus it
    hs.focus()
    local button, newSuffix = hsdialog.textPrompt("Rename Activity",
        "Enter new description for " .. templateName .. ":", currentSuffix, "OK", "Cancel")

    if button == "OK" and newSuffix and newSuffix ~= "" then
        local newName = templateName .. ": " .. newSuffix
        m.state:activityRenamed(activityId, newName)
        m:_saveState()
        m.logger.d("Renamed activity", activityId, "to", newName)

        -- Rename Chrome windows on current space using UI Scripting for persistent names
        local chrome = hsapplication.get("Google Chrome")
        if chrome then
            local currentSpace = hsspaces.focusedSpace()
            local wins = chrome:allWindows()
            local lastFocused = hswindow.focusedWindow()

            -- 1. Collect all target windows first
            local targetWindows = {}
            for _, win in ipairs(wins) do
                local winSpaces = hsspaces.windowSpaces(win)
                if winSpaces and hsfnutils.contains(winSpaces, currentSpace) then
                    table.insert(targetWindows, win)
                end
            end

            -- 2. Recursive function to rename them sequentially
            local function renameNext(index)
                if index > #targetWindows then
                    -- Done processing all windows
                    if lastFocused then
                        lastFocused:focus()
                    end
                    return
                end

                local win = targetWindows[index]
                win:focus()

                -- Give focus a moment to settle
                hstimer.doAfter(0.2, function()
                    local success = false

                    -- Method 1: Try direct selectMenuItem (Hammerspoon wrapper)
                    if chrome:selectMenuItem({"Window", "Name Window..."}) then
                        success = true
                    elseif chrome:selectMenuItem({"Window", "Name Window…"}) then
                        success = true
                    end

                    -- Method 2: Low-level AppleScript if wrapper fails
                    if not success then
                        m.logger.d("Falling back to raw AppleScript for menu selection")
                        local as = string.format([[
                            tell application "System Events"
                                tell process "Google Chrome"
                                    set frontmost to true
                                    click menu item "Name Window..." of menu "Window" of menu bar 1
                                end tell
                            end tell
                        ]])
                        local ok, _ = hsosascript.applescript(as)
                        success = ok
                    end

                    if success then
                        -- Wait for dialog to appear before typing
                        hstimer.doAfter(0.5, function()
                            -- Prefix with "Focus: " to make it stand out
                            local prefixedName = "Focus: " .. newSuffix
                            if #targetWindows > 1 then
                                prefixedName = prefixedName .. " " .. index
                            end

                            hseventtap.keyStrokes(prefixedName)
                            hstimer.doAfter(0.1, function()
                                hseventtap.keyStroke({}, "return")

                                -- Process next window after delay
                                hstimer.doAfter(0.2, function()
                                    renameNext(index + 1)
                                end)
                            end)
                        end)
                    else
                        m.logger.w("Could not find 'Name Window...' menu item in Chrome")
                        -- Proceed to next window anyway
                        renameNext(index + 1)
                    end
                end)
            end

            if #targetWindows > 0 then
                renameNext(1)
            end
        end
    end
end

function m:assignActivityToCurrentSpace(activityTemplateId)
    local template = m.activityTemplatesLookup[activityTemplateId]
    m.logger.d('assignActivityToCurrentSpace template:', template)

    -- Create new activity from template
    local activityId = m.state:activityStarted(activityTemplateId)

    -- Move apps to the new activity
    m:moveAppsToActivity(template["apps"], activityId)

    -- Assign activity to current space (don't create new space or switch)
    local currentSpace = hsspaces.focusedSpace()
    m:moveActivityToSpace(activityId, currentSpace)

    -- Apply layout if specified
    if template["layout"] then
        hslayout.apply(template["layout"])
    end

    m:_saveState()

    -- Automatically open rename dialog for the new activity
    m:renameActivity(activityId)
end

function m:stopActivity(activityId, keepSpace)
    m.logger.d('stopActivity', activityId)

    -- TODO
    -- TODO: close windows that are "owned" by the activity, move the others...

    local windowIds = m.state:getWindowsByActivityId(activityId)

    local defaultSpace = m:_getDefaultSpace()
    for wid, _ in ipairs(windowIds) do
        local w = hswindow(wid)
        if w ~= nil then
            hsspaces.moveWindowToSpace(w, defaultSpace)
        end
    end

    if not keepSpace then
        local space = m.state:getSpaceByActivityId(activityId)
        m.logger.d('Attemping to remove space', hsinspect(space))
        if space ~= nil then
            m.logger.d('Removing space', space.id)
            local activitiesInSpace = m.state:getActivitiesBySpaceId(space.id)
            if #activitiesInSpace == 1 and activitiesInSpace[1].id == activityId then
                if hsspaces.focusedSpace() == space.id then
                    hsspaces.gotoSpace(defaultSpace)
                end
                hsspaces.removeSpace(space.id)
                m.state:spaceRemoved(space.id)
            end
        end
    end

    m.state:activityStopped(activityId)

    m:_saveState()
end

function m:moveActivityToSpace(activityId, space)
    local windows = m.state:getWindowsByActivityId(activityId)
    m.logger.d('Moving Activity to space', activityId, space, hsinspect(windows))
    m.state:activityMoved(activityId, space)
    for wid, _ in pairs(windows) do
        local w = hswindow(wid)
        m.logger.d('  Moving activity window', wid, w, activityId)
        if w ~= nil then
            hsspaces.moveWindowToSpace(w, space)
        end
    end
end

function m:closeAll()
    local screenId = hsscreen.primaryScreen():getUUID()
    local firstSpaceId = hsspaces.allSpaces()[screenId][1]

    if not m:_isPrimarySpace() then
        hsspaces.gotoSpace(firstSpaceId)
    end

    for activityId, _ in pairs(m.state.activities) do
        m:stopActivity(activityId, true)
    end

    -- TODO: Clean up activities
    -- Save state
    -- Update canvas

    hstimer.doAfter(2, function()
        hsfnutils.ieach(hsspaces.allSpaces()[screenId], function(s)
            if s ~= firstSpaceId then
                r = hsspaces.removeSpace(s, false)
            end
        end)
        hsspaces.closeMissionControl()
    end)

    m:reset()
end

function m:moveAppsToActivity(appHints, activityId)
    for _, hint in ipairs(appHints) do
        if hint ~= nil and type(hint.getWindows) == "function" then
            local windows = hint:getWindows()
            for _, window in ipairs(windows) do
                m.state:windowMoved(window:id(), activityId)
            end
        end
    end
end

function m:cleanup()
    for activityId, activity in pairs(self.state:getActivities()) do
        local windows = self.state:getWindowsByActivityId(activityId)
        local space = self.state:getSpaceByActivityId(activityId)

        if space then
            for windowId, _ in pairs(windows) do
                local window = hswindow(windowId)
                if window and window:isVisible() then
                    hsspaces.moveWindowToSpace(window, space.id)
                end
            end
        end
        m:moveAppsToActivity(m.activityTemplatesLookup[activity.typeId]["apps"], activityId)
    end

    return nil
end

function m:reset()
    m.state = State.new()
    m:_saveState()
    m:cleanup()
end

function m:_getSpaceColor(spaceIndex)
    -- Vibrant graffiti and pastel color palette for 16 spaces
    -- Each color is designed to be distinct and easily recognizable
    local colors = {{
        red = 1.0,
        green = 0.2,
        blue = 0.5,
        alpha = 0.6
    }, -- Hot Pink
    {
        red = 0.2,
        green = 0.8,
        blue = 1.0,
        alpha = 0.6
    }, -- Cyan
    {
        red = 1.0,
        green = 0.8,
        blue = 0.2,
        alpha = 0.6
    }, -- Golden Yellow
    {
        red = 0.5,
        green = 1.0,
        blue = 0.3,
        alpha = 0.6
    }, -- Lime Green
    {
        red = 0.8,
        green = 0.3,
        blue = 1.0,
        alpha = 0.6
    }, -- Purple
    {
        red = 1.0,
        green = 0.5,
        blue = 0.2,
        alpha = 0.6
    }, -- Orange
    {
        red = 0.3,
        green = 1.0,
        blue = 0.8,
        alpha = 0.6
    }, -- Turquoise
    {
        red = 1.0,
        green = 0.4,
        blue = 0.7,
        alpha = 0.6
    }, -- Pink
    {
        red = 0.6,
        green = 0.8,
        blue = 1.0,
        alpha = 0.6
    }, -- Sky Blue
    {
        red = 1.0,
        green = 0.9,
        blue = 0.4,
        alpha = 0.6
    }, -- Pale Yellow
    {
        red = 0.8,
        green = 1.0,
        blue = 0.6,
        alpha = 0.6
    }, -- Mint
    {
        red = 1.0,
        green = 0.6,
        blue = 0.3,
        alpha = 0.6
    }, -- Coral
    {
        red = 0.7,
        green = 0.4,
        blue = 1.0,
        alpha = 0.6
    }, -- Lavender
    {
        red = 0.4,
        green = 1.0,
        blue = 0.5,
        alpha = 0.6
    }, -- Spring Green
    {
        red = 1.0,
        green = 0.3,
        blue = 0.3,
        alpha = 0.6
    }, -- Red
    {
        red = 0.4,
        green = 0.6,
        blue = 1.0,
        alpha = 0.6
    } -- Periwinkle
    }

    -- Use modulo to wrap around if spaceIndex is > 16
    local index = ((spaceIndex - 1) % 16) + 1
    return colors[index]
end

function m:_getContrastingTextColor(backgroundColor)
    -- Calculate relative luminance using the standard formula
    -- Luminance = 0.299*R + 0.587*G + 0.114*B
    local luminance = 0.299 * backgroundColor.red + 0.587 * backgroundColor.green + 0.114 * backgroundColor.blue

    -- If background is light (high luminance), use dark text
    -- If background is dark (low luminance), use light text
    if luminance > 0.6 then
        return {
            red = 0.1,
            green = 0.1,
            blue = 0.1,
            alpha = 1.0
        } -- Near black
    else
        return {
            red = 1.0,
            green = 1.0,
            blue = 1.0,
            alpha = 1.0
        } -- White
    end
end

function m:_createCanvas()
    local screen = hsscreen.primaryScreen()
    local res = screen:fullFrame()

    local canvas = hscanvas.new({
        x = 20,
        y = res.h - 26,
        w = 700,
        h = 28
    })
    canvas:behavior(hscanvas.windowBehaviors.canJoinAllSpaces)
    canvas:level(hscanvas.windowLevels.desktopIcon)

    -- Get current space info to determine color
    local info = m:_spaceInfo()
    local spaceIndex = info.currentIndex or 1
    local spaceColor = m:_getSpaceColor(spaceIndex)
    local textColor = m:_getContrastingTextColor(spaceColor)

    canvas[1] = {
        type = "rectangle",
        action = "fill",
        fillColor = spaceColor,
        roundedRectRadii = {
            xRadius = 5,
            yRadius = 5
        }
    }

    canvas[2] = {
        id = "cal_title",
        type = "text",
        text = m:_spaceInfoText(),
        textFont = "Courier",
        textSize = 24,
        textColor = textColor,
        textAlignment = "left"
    }

    return canvas
end

function m:_saveState()
    if m.desktopLozenge and m.canvas then
        -- Update text
        m.canvas[2].text = m:_spaceInfoText()

        -- Update background color and text color based on current space
        local info = m:_spaceInfo()
        local spaceIndex = info.currentIndex or 1
        local spaceColor = m:_getSpaceColor(spaceIndex)
        local textColor = m:_getContrastingTextColor(spaceColor)
        m.canvas[1].fillColor = spaceColor
        m.canvas[2].textColor = textColor
    end

    local stateTable = m.state:toTable()

    m.logger.d("Saving state", hsinspect(stateTable))

    hssettings.set(m.settingsKey, stateTable)
end

function m:_restoreState()
    local stateTable = hssettings.get(m.settingsKey)

    m.logger.d("Restoring state", hsinspect(stateTable))

    if stateTable ~= nil then
        local state = State.fromTable(stateTable)
        -- todo reconcile

        local activityIdMapping = {}

        for activityId, activity in pairs(state.activities) do
            local activityTemplate = m.activityTemplatesLookup[activity.typeId]
            if activityTemplate ~= nil then
                m.logger.d("Starting activity with typeId", activity.typeId)
                local id = m.state:activityStarted(activity.typeId)

                m.logger.d(" Renaming", id, activity.name)
                m.state:activityRenamed(id, activity.name)

                activityIdMapping[activityId] = id

                for wid, _ in pairs(activity.windowIds) do
                    local win = hswindow(wid)
                    if win ~= nil then
                        m.logger.d(" Recovering window", wid)
                        m.state:windowMoved(wid, id)
                    end
                end

                m.logger.d("Done with activity has windows", id, hsinspect(m.state:getWindowsByActivityId(id)))
            end
        end

        local allSpaces = hsspaces.spacesForScreen("primary")

        m.logger.d(" Reconciling current spaces:", allSpaces)
        m.logger.d(" With space state:", hsinspect(state.spaces))

        for i, spaceId in ipairs(allSpaces) do
            m.state:spaceAdded(spaceId, i)
        end

        for spaceId, space in pairs(state.spaces) do
            m.logger.d("Reconciling space", spaceId, hsinspect(space))
            local targetSpaceId = nil

            if hs.fnutils.contains(allSpaces, spaceId) then
                m.logger.d(" Current space matches previous space, using it.")
                targetSpaceId = spaceId
            else
                m.logger.d(" Searching for space by index instead: ", space.index, hsinspect(m.state.spaces))
                for newSpaceId, newSpace in pairs(m.state.spaces) do
                    if newSpace.index == space.index then
                        m.logger.d(" Current space matches previous space by index, using it.")
                        targetSpaceId = newSpaceId
                    end
                end
            end

            if targetSpaceId == nil then
                targetSpaceId = m:_createNewSpace()
                m.logger.d(" Did not find matching space. Created space has id", targetSpaceId)
            end

            m.logger.d("Moving all activities to target space", hsinspect(space.activityIds), targetSpaceId)
            for activityId, _ in pairs(space.activityIds) do
                local aid = activityIdMapping[activityId]
                m:moveActivityToSpace(aid, targetSpaceId)
            end
        end
    end
end

function m:_getAllSpaces()
    local screenId = hsscreen.primaryScreen():getUUID()
    return hsspaces.allSpaces()[screenId]
end

function m:_createNewSpace()
    local screenId = hsscreen.primaryScreen():getUUID()
    hsspaces.addSpaceToScreen(screenId)
    local spaces = hsspaces.allSpaces()[screenId]
    space = spaces[#spaces]
    m.state:spaceAdded(space, #spaces)
    return space
end

function m:_getDefaultSpace()
    -- First space is the default space (for now)
    local screenId = hsscreen.primaryScreen():getUUID()
    return hsspaces.allSpaces()[screenId][1]
end

function m:_isPrimarySpace()
    local screenId = hsscreen.primaryScreen():getUUID()
    local firstSpaceId = hsspaces.allSpaces()[screenId][1]
    local currentSpaceId = hsspaces.focusedSpace()
    return firstSpaceId == currentSpaceId
end

function m:_spaceInfoText()
    local info = m:_spaceInfo()
    local spaceName = "(Unmanaged)"
    if info.isPrimary then
        spaceName = "Primary"
    elseif info.primaryActivity ~= nil then
        spaceName = info.primaryActivity.name
    end
    local currentIndex = info.currentIndex or 1
    local count = info.count or 1
    return string.format(" %s (%d/%d)", spaceName, currentIndex, count)
end

function m:_spaceInfo()
    local screenId = hsscreen.primaryScreen():getUUID()
    local allSpaces = hsspaces.allSpaces()[screenId]
    local firstSpaceId = allSpaces[1]
    local currentSpaceId = hsspaces.focusedSpace()

    local activities = m.state:getActivitiesBySpaceId(currentSpaceId)
    local activity = activities ~= nil and #activities > 0 and activities[1] or nil

    local currentIndex = hsfnutils.indexOf(allSpaces, currentSpaceId) or 1

    return {
        count = #allSpaces,
        isPrimary = firstSpaceId == currentSpaceId,
        currentIndex = currentIndex,
        primaryActivity = activity
    }
end

function m:_toggleDock()
    hs.eventtap.keyStroke({"cmd", "alt"}, "d")
end

function m:_isDockHidden()
    local asCommand = "tell application \"System Events\" to return autohide of dock preferences"
    local ok, isDockHidden = hsosascript.applescript(asCommand)

    if not ok then
        local msg = "An error occurred getting the value of autohide for the Dock."
        hsnotify.new({
            title = "Hammerspoon",
            informativeText = msg
        }):send()
    end

    return isDockHidden
end

function m:_onSpaceChanged(checkTwice)
    local isDockHidden = m:_isDockHidden()

    if m.dockOnPrimaryOnly then
        if m:_isPrimarySpace() and isDockHidden then
            m:_toggleDock()
        end

        if not m:_isPrimarySpace() and not isDockHidden then
            m:_toggleDock()
        end

        -- Check once more after spaces settle...
        if checkTwice then
            hstimer.doAfter(1, function()
                self:_onSpaceChanged(false)
            end)
        end
    end

    if m.desktopLozenge and m.canvas then
        -- Update text
        m.canvas[2].text = m:_spaceInfoText()

        -- Update background color and text color based on current space
        local info = m:_spaceInfo()
        local spaceIndex = info.currentIndex or 1
        local spaceColor = m:_getSpaceColor(spaceIndex)
        local textColor = m:_getContrastingTextColor(spaceColor)
        m.canvas[1].fillColor = spaceColor
        m.canvas[2].textColor = textColor
    end
end

return m
