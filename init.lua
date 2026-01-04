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
m.version = "0.2"
m.author = "crumley@gmail.com"
m.license = "MIT"
m.homepage = "https://github.com/Hammerspoon/Spoons"

m.logger = hslogger.new('SpaceManager', 'debug')

-- Settings
m.settingsKey = m.name .. ".state"

-- Configuration
m.dockOnPrimaryOnly = false
m.desktopLozenge = false
m.spaceConfig = {}

local actions = {
    rename = function(choice)
        m:renameCurrentSpace()
    end,

    reset = function()
        m:reset()
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
end

function m:show()
    m:showMenu()
end

function m:showMenu()
    local spaceInfo = m:_spaceInfo()
    m.chooser:choices(Menu.generateChoices(spaceInfo.currentSpaceName))
    m.chooser:show()
end

function m:renameCurrentSpace()
    local spaceInfo = m:_spaceInfo()
    local currentSpaceId = spaceInfo.currentSpaceId
    local currentSpaceName = spaceInfo.currentSpaceName
    local defaultName = spaceInfo.defaultName

    -- Extract current suffix from space name (everything after ":")
    local currentSuffix = ""
    local colonPos = string.find(currentSpaceName, ":")
    if colonPos then
        currentSuffix = string.sub(currentSpaceName, colonPos + 2) -- +2 to skip ": "
    end

    -- Show text prompt for new suffix and auto-focus it
    hs.focus()
    local button, newSuffix = hsdialog.textPrompt("Rename Space", "Enter description for " .. defaultName .. ":",
        currentSuffix, "OK", "Cancel")

    if button == "OK" and newSuffix then
        local newName
        if newSuffix == "" then
            -- Empty suffix means revert to default name
            newName = nil
        else
            newName = defaultName .. ": " .. newSuffix
        end

        m.state:spaceRenamed(currentSpaceId, newName)
        m:_saveState()
        m.logger.d("Renamed space", currentSpaceId, "to", newName or defaultName)

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
                            local displayName = newName or defaultName
                            local prefixedName = "Focus: " .. displayName
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

function m:reset()
    m.state = State.new()
    m:_saveState()
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
        if state ~= nil then
            m.state = state

            -- Ensure all current spaces are registered in state
            local allSpaces = hsspaces.spacesForScreen("primary")
            for i, spaceId in ipairs(allSpaces) do
                if m.state:getSpaceById(spaceId) == nil then
                    m.state:spaceAdded(spaceId, i)
                end
            end
        end
    end
end

function m:_getAllSpaces()
    local screenId = hsscreen.primaryScreen():getUUID()
    return hsspaces.allSpaces()[screenId]
end

function m:_getDefaultSpace()
    -- First space is the default space
    local screenId = hsscreen.primaryScreen():getUUID()
    return hsspaces.allSpaces()[screenId][1]
end

function m:_isPrimarySpace()
    local screenId = hsscreen.primaryScreen():getUUID()
    local firstSpaceId = hsspaces.allSpaces()[screenId][1]
    local currentSpaceId = hsspaces.focusedSpace()
    return firstSpaceId == currentSpaceId
end

function m:_getDefaultNameForIndex(index)
    -- Get default name from config or use generic name for unmanaged spaces
    return m.spaceConfig[index] or "Space"
end

function m:_spaceInfoText()
    local info = m:_spaceInfo()
    local spaceName = info.currentSpaceName
    if info.isPrimary and spaceName == info.defaultName then
        spaceName = "Primary"
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

    local currentIndex = hsfnutils.indexOf(allSpaces, currentSpaceId) or 1
    local defaultName = m:_getDefaultNameForIndex(currentIndex)

    -- Get custom name from state if it exists
    local spaceRecord = m.state:getSpaceById(currentSpaceId)
    local customName = spaceRecord and spaceRecord.name or nil
    local currentSpaceName = customName or defaultName

    return {
        count = #allSpaces,
        isPrimary = firstSpaceId == currentSpaceId,
        currentIndex = currentIndex,
        currentSpaceId = currentSpaceId,
        currentSpaceName = currentSpaceName,
        defaultName = defaultName
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
