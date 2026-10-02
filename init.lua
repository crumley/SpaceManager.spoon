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
local hsosascript = require("hs.osascript")
local hsnotify = require("hs.notify")
local hsdialog = require("hs.dialog")
local hsjson = require("hs.json")
local hscaffeinate = require("hs.caffeinate")
local hswindowfilter = require("hs.window.filter")
local hsurlevent = require("hs.urlevent")

local CHROME_BUNDLE = "com.google.Chrome"
local HAMMERSPOON_BUNDLE = "org.hammerspoon.Hammerspoon"

local State = dofile(hs.spoons.resourcePath("state.lua"))
local Menu = dofile(hs.spoons.resourcePath("menu.lua"))
local Chrome = dofile(hs.spoons.resourcePath("chrome.lua"))

local m = {}
m.__index = m

-- Metadata
m.name = "SpaceManager"
m.version = "0.3"
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
-- What spaceLabel calls a space with no name, so a label never stops at the
-- number. "" leaves just the number.
m.unnamedSpaceName = "<untitled>"

-- An unnamed Chrome window takes its space's position and name, "01 - Today"
-- (Window > Name Window..., set through Chrome's scripting `givenName`, see
-- chrome.lua). A window that has a name keeps it until its space is renamed.
-- Reconciled when a Chrome window appears, when the active space changes, on
-- wake or unlock, and every chromeNamesInterval seconds.
m.chromeWindowNames = false
m.chromeNamesInterval = 60
-- Lead each name with a colored square close to the space's color (see
-- _getSpaceMarker), so a window shows which space it belongs to at a glance.
m.chromeWindowMarkers = true
-- A timer tick skips the full pass (which asks Chrome about every window)
-- while the windows last seen settled are still on the same spaces and the
-- space names are unchanged. A full pass still runs at least this often.
m.chromeNamesFullInterval = 600

-- Once a day, open a fresh Chrome window named for the date on the space at
-- dailyWindowSpaceIndex. Chrome opens a new window on the space showing, and
-- moving a window to another space is not reliable on current macOS, so it is
-- only created while that space is showing; otherwise a later tick tries.
m.dailyWindow = false
m.dailyWindowSpaceIndex = 1
m.dailyWindowDateFormat = "%Y-%m-%d"

-- Links clicked in other apps open in a Chrome window on the space showing,
-- rather than in whichever window Chrome last used, which pulls the screen to
-- that window's space. Hammerspoon has to be the default browser for this:
-- with linkRouting on, start() asks macOS to make it so (macOS confirms the
-- change once). A link that cannot be routed is handed to Chrome as usual.
m.linkRouting = false
-- With no Chrome window on the space showing: true opens a new one there;
-- false hands the link to Chrome to open wherever it would.
m.linkRoutingNewWindow = true

-- Spaces renamed or cleared since the last Chrome pass (spaceId -> true):
-- every window on them takes the new name, whatever it was called before.
m.renamedSpaces = {}

local actions = {
    rename = function(choice)
        m:renameCurrentSpace()
    end,

    reset = function()
        m:reset()
    end,

    clearName = function()
        m:clearCurrentSpaceName()
    end,

    gotoSpace = function(choice)
        hsspaces.gotoSpace(choice.spaceId)
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

    m.spaceWatcher = hsspaces.watcher.new(function(s)
        m:_onSpaceChanged(true)
    end)
    m.spaceWatcher:start()
    if m.dockOnPrimaryOnly then
        m:_onSpaceChanged(true)
    end

    if m.desktopLozenge then
        m.canvas = m:_createCanvas()
        m.canvas:show()
    end

    pcall(function()
        m:_restoreState()
    end)

    if m.chromeWindowNames or m.dailyWindow then
        m:_startChromeNaming()
    end

    if m.linkRouting then
        m:_startLinkRouting()
    elseif hsurlevent.getDefaultHandler("http") == HAMMERSPOON_BUNDLE then
        -- Routing is off but Hammerspoon is still the default browser: pass
        -- links straight to Chrome rather than drop them.
        m.logger.w("Hammerspoon is the default browser with linkRouting off;",
            "make Chrome the default again in System Settings > Desktop & Dock")
        hsurlevent.httpCallback = function(_, _, _, url)
            m:_openInChrome(url)
        end
    end
end

function m:show()
    m:showMenu()
end

function m:showMenu()
    local spaceInfo = m:_spaceInfo()
    local hasCustomName = (spaceInfo.currentSpaceName ~= spaceInfo.defaultName)
    local allSpaces = m:_getSpacesForMenu()
    m.chooser:choices(Menu.generateChoices(
        spaceInfo.currentSpaceName,
        hasCustomName,
        allSpaces,
        spaceInfo.currentSpaceId
    ))
    m.chooser:show()
end

function m:renameCurrentSpace()
    local spaceInfo = m:_spaceInfo()
    local currentSpaceId = spaceInfo.currentSpaceId
    local defaultName = spaceInfo.defaultName
    local spaceRecord = m.state:getSpaceById(currentSpaceId)
    local currentName = spaceRecord and spaceRecord.name or ""

    -- Show text prompt for the new name and auto-focus it
    hs.focus()
    local button, newName = hsdialog.textPrompt("Rename Space",
        string.format("Name for %s (space %d), empty to clear:", defaultName, spaceInfo.currentIndex),
        currentName, "OK", "Cancel")

    if button == "OK" and newName then
        if newName == "" then
            newName = nil
        end
        m.state:spaceRenamed(currentSpaceId, newName)
        m.renamedSpaces[currentSpaceId] = true
        m:_saveState()
        m.logger.d("Renamed space", currentSpaceId, "to", newName or defaultName)
        m:_scheduleReconcile(0)
    end
end

function m:reset()
    -- Clear every custom name; the Chrome windows on those spaces follow.
    for spaceId, space in pairs(m.state:getSpaces()) do
        if space.name then
            m.state:spaceRenamed(spaceId, nil)
            m.renamedSpaces[spaceId] = true
        end
    end
    m:_saveState()
    m:_scheduleReconcile(0)
end

function m:clearCurrentSpaceName()
    local spaceInfo = m:_spaceInfo()
    m.state:spaceRenamed(spaceInfo.currentSpaceId, nil)
    m.renamedSpaces[spaceInfo.currentSpaceId] = true
    m:_saveState()
    m:_scheduleReconcile(0)
end

-- Chrome window names ----------------------------------------------------

local function jsString(str)
    return '"' .. str:gsub('\\', '\\\\'):gsub('"', '\\"') .. '"'
end

function m:_chromeApp()
    return hsapplication.get("Google Chrome")
end

-- Chrome's own view of its windows, via scripting: id, title, givenName,
-- bounds {x, y, width, height}. nil when Chrome is not running or refuses.
function m:_chromeScriptWindows()
    if not m:_chromeApp() then
        return nil
    end
    -- One Apple Event per property for all windows at once, not one per
    -- window: the cost stays flat however many windows are open.
    local ok, result = hsosascript.javascript([[
        const ws = Application("Google Chrome").windows;
        const ids = ws.id(), titles = ws.title(), names = ws.givenName(), bounds = ws.bounds();
        JSON.stringify(ids.map((id, i) => ({
            id: String(id), title: titles[i], givenName: names[i], bounds: bounds[i]
        })));
    ]])
    if not ok then
        m.logger.w("Could not list Chrome windows", hsinspect(result))
        return nil
    end
    return hsjson.decode(result)
end

-- Hammerspoon's view of the same windows, with the spaces each is on.
function m:_chromeHsWindows(app)
    local wins = {}
    for _, w in ipairs(app:allWindows()) do
        local id = w:id()
        if id and w:isStandard() then
            local f = w:frame()
            table.insert(wins, {
                id = id,
                title = w:title(),
                frame = { x = f.x, y = f.y, w = f.w, h = f.h },
                spaces = hsspaces.windowSpaces(w) or {},
                window = w
            })
        end
    end
    return wins
end

function m:_setChromeWindowNames(namesById)
    local ok, result = hsosascript.javascript(string.format([[
        const names = %s;
        const ws = Application("Google Chrome").windows;
        Object.keys(names).forEach(id => { ws.byId(Number(id)).givenName = names[id]; });
        true;
    ]], hsjson.encode(namesById)))
    if not ok then
        m.logger.w("Could not set Chrome window names", hsinspect(result))
    end
end

-- A short label for a space on the primary screen, for other spoons to show
-- next to a window: "🟥 01 - Today" for a named space, "🟦 02 - <untitled>"
-- for an unnamed one (the marker only with chromeWindowMarkers). nil for a
-- space it does not know, such as one on another screen. Chrome windows on an
-- unnamed space stay unnamed; the placeholder is for labels only.
function m:spaceLabel(spaceId)
    for index, id in ipairs(m:_getAllSpaces() or {}) do
        if id == spaceId then
            local record = m.state:getSpaceById(spaceId)
            local name = (record and record.name) or m.spaceConfig[index]
            if name == nil or name == "" then
                name = m.unnamedSpaceName
            end
            local marker = m.chromeWindowMarkers and m:_getSpaceMarker(index) or nil
            return Chrome.spaceWindowName(index, name, marker) or
                ((marker and marker .. " " or "") .. string.format("%02d", index))
        end
    end
    return nil
end

-- The name windows on each space should carry (spaceId -> "01 - Today"), nil
-- for a space with neither a custom nor a configured name.
function m:_spaceNames()
    local names = {}
    for index, spaceId in ipairs(m:_getAllSpaces() or {}) do
        local record = m.state:getSpaceById(spaceId)
        local configured = m.spaceConfig[index]
        local marker = m.chromeWindowMarkers and m:_getSpaceMarker(index) or nil
        names[spaceId] = Chrome.spaceWindowName(index, (record and record.name) or configured, marker)
    end
    return names
end

-- The fingerprint of the given hs window ids where they stand now. Only
-- asks the window server which space each is on: nothing goes to Chrome.
function m:_chromeSignature(ids, names)
    local spacesById = {}
    for _, id in ipairs(ids) do
        spacesById[id] = hsspaces.windowSpaces(id) or {}
    end
    return Chrome.signature(spacesById, names)
end

-- force: run the full pass even if nothing looks changed. Events (a new
-- window, a space switch, wake, a rename) force; the periodic timer does not.
function m:reconcileChromeWindows(force)
    if not m.chromeWindowNames then
        return
    end
    local settled = m.chromeSettled
    local now = hstimer.secondsSinceEpoch()
    if not force and settled and now - settled.at < m.chromeNamesFullInterval then
        local names = m:_spaceNames()
        if m:_chromeSignature(settled.ids, names) == settled.signature then
            return
        end
    end
    m.chromeSettled = nil

    local app = m:_chromeApp()
    local scripted = app and m:_chromeScriptWindows()
    if not scripted then
        return
    end
    local names = m:_spaceNames()
    local hsWindows = m:_chromeHsWindows(app)
    local pairs_ = Chrome.matchWindows(scripted, hsWindows)
    local changes = Chrome.plan(pairs_, names, m.renamedSpaces, scripted)
    m.renamedSpaces = {}
    if #changes == 0 then
        -- Nothing to do: remember where everything stood, so ticks can skip
        -- until something moves. After renames, the next pass confirms them.
        local ids = {}
        for _, w in ipairs(hsWindows) do
            table.insert(ids, w.id)
        end
        m.chromeSettled = { ids = ids, signature = m:_chromeSignature(ids, names), at = now }
        return
    end
    local byId = {}
    for _, change in ipairs(changes) do
        byId[change.id] = change.name
        m.logger.d("Chrome window", change.id, "->", change.name == "" and "(cleared)" or change.name)
    end
    m:_setChromeWindowNames(byId)
end

function m:ensureDailyWindow()
    if not m.dailyWindow then
        return
    end
    local today = os.date(m.dailyWindowDateFormat)
    if m.state.lastDailyWindow == today then
        return
    end
    local app = m:_chromeApp()
    local scripted = app and m:_chromeScriptWindows()
    if not scripted then
        return
    end
    for _, w in ipairs(scripted) do
        if w.givenName == today then
            -- Chrome restored it, or Hammerspoon reloaded after making it
            m:_recordDailyWindow(today)
            return
        end
    end

    local spaceId = (m:_getAllSpaces() or {})[m.dailyWindowSpaceIndex]
    if not spaceId then
        return
    end
    if hsspaces.focusedSpace() ~= spaceId then
        return -- a new window would open here, not there; a later tick tries
    end

    local previous = hswindow.focusedWindow()
    local ok, result = hsosascript.javascript(string.format([[
        const w = Application("Google Chrome").Window().make();
        w.givenName = %s;
        true;
    ]], jsString(today)))
    if not ok then
        m.logger.w("Could not create the daily Chrome window", hsinspect(result))
        return
    end
    m.logger.i("Created daily Chrome window", today)
    m:_recordDailyWindow(today)

    -- Give focus back to whatever had it: the window is for later, not now.
    hstimer.doAfter(0.5, function()
        if previous then
            previous:focus()
        end
    end)
end

function m:_recordDailyWindow(today)
    m.state.lastDailyWindow = today
    m:_saveState()
end

function m:_tick(force)
    m:ensureDailyWindow()
    m:reconcileChromeWindows(force)
end

-- Link routing -------------------------------------------------------------

function m:_startLinkRouting()
    hsurlevent.httpCallback = function(_, _, _, url)
        m:routeLink(url)
    end
    if hsurlevent.getDefaultHandler("http") ~= HAMMERSPOON_BUNDLE then
        -- Covers https too; macOS asks to confirm the new default browser.
        hsurlevent.setDefaultHandler("http")
    end
end

function m:_openInChrome(url)
    hsurlevent.openURLWithBundle(url, CHROME_BUNDLE)
end

-- Open a link in the frontmost Chrome window on the space showing, or in a
-- new window there. Anything that goes wrong hands the link to Chrome.
function m:routeLink(url)
    local ok, routed = pcall(m._routeLink, m, url)
    if not ok then
        m.logger.w("Could not route link", url, hsinspect(routed))
    end
    if not (ok and routed) then
        m:_openInChrome(url)
    end
end

-- true once the link is open on the space showing.
function m:_routeLink(url)
    local app = m:_chromeApp()
    local scripted = app and m:_chromeScriptWindows()
    if not scripted then
        return false -- Chrome is not running; launched, it opens here anyway
    end
    local order = {}
    for _, w in ipairs(hswindow.list(true) or {}) do
        table.insert(order, w.kCGWindowNumber)
    end
    local pairs_ = Chrome.matchWindows(scripted, m:_chromeHsWindows(app))
    local target = Chrome.linkTarget(pairs_, hsspaces.focusedSpace(), order)
    if target == nil and not m.linkRoutingNewWindow then
        return false
    end

    -- A new Chrome window opens on the space showing, like the daily window.
    local ok, result = hsosascript.javascript(string.format([[
        const [url, id] = %s;
        const c = Application("Google Chrome");
        if (id === false) {
            const w = c.Window().make();
            w.activeTab.url = url;
            w.index = 1;
            c.activate();
        } else {
            // Chrome makes a new tab in its front window whatever window the
            // tab is aimed at, so bring the target to the front first (it is
            // on the space showing), then confirm the tab landed there.
            const w = c.windows.byId(Number(id));
            w.index = 1;
            const before = w.tabs.length;
            w.tabs.push(c.Tab({ url: url }));
            if (w.tabs.length !== before + 1) { throw new Error("tab not added to window " + id); }
            w.activeTabIndex = w.tabs.length;
        }
        true;
    ]], hsjson.encode({ url, target and target.chrome.id or false })))
    if not ok then
        -- routeLink hands it to Chrome; if a tab did land in another window,
        -- the link ends up open twice rather than not at all.
        m.logger.w("Could not open link in Chrome", url, hsinspect(result))
        return false
    end
    if target then
        target.hs.window:focus()
    end
    m.logger.d("Routed link", url, "to", target and target.chrome.id or "a new window")
    return true
end

-- Coalesce bursts (a space switch plus the windows it reveals) into one pass.
function m:_scheduleReconcile(delay)
    if m.pendingTick then
        m.pendingTick:stop()
    end
    m.pendingTick = hstimer.doAfter(delay, function()
        m.pendingTick = nil
        m:_tick(true)
    end)
end

function m:_startChromeNaming()
    m.chromeFilter = hswindowfilter.new("Google Chrome")
    m.chromeFilter:subscribe(hswindowfilter.windowCreated, function()
        m:_scheduleReconcile(1)
    end)
    m.wakeWatcher = hscaffeinate.watcher.new(function(event)
        if event == hscaffeinate.watcher.systemDidWake or event == hscaffeinate.watcher.screensDidUnlock then
            m:_scheduleReconcile(5)
        end
    end)
    m.wakeWatcher:start()
    m.tickTimer = hstimer.doEvery(m.chromeNamesInterval, function()
        m:_tick(false)
    end)
    m:_scheduleReconcile(5)
end

function m:_getSpacesForMenu()
    local result = {}
    local allSpaces = m:_getAllSpaces()
    for index, spaceId in ipairs(allSpaces or {}) do
        local spaceRecord = m.state:getSpaceById(spaceId)
        local customName = spaceRecord and spaceRecord.name or nil
        local configuredName = m.spaceConfig[index]
        local defaultName = configuredName or "Space"
        table.insert(result, {
            spaceId = spaceId,
            index = index,
            name = customName,
            defaultName = defaultName,
            hasCustomName = (customName ~= nil),
            hasConfiguredName = (configuredName ~= nil)
        })
    end
    return result
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

-- The colored square emoji closest to each _getSpaceColor entry, same order.
-- There are only nine squares, so some spaces share one.
function m:_getSpaceMarker(spaceIndex)
    local markers = {
        "🟥", -- Hot Pink
        "🟦", -- Cyan
        "🟨", -- Golden Yellow
        "🟩", -- Lime Green
        "🟪", -- Purple
        "🟧", -- Orange
        "🟩", -- Turquoise
        "🟪", -- Pink
        "🟦", -- Sky Blue
        "🟨", -- Pale Yellow
        "🟩", -- Mint
        "🟧", -- Coral
        "🟪", -- Lavender
        "🟩", -- Spring Green
        "🟥", -- Red
        "🟦", -- Periwinkle
    }
    return markers[((spaceIndex - 1) % #markers) + 1]
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
    -- "Primary" only stands in for a first space nobody named: a configured
    -- name (spaceConfig) or a custom one is shown as is.
    if info.isPrimary and spaceName == info.defaultName and m.spaceConfig[info.currentIndex] == nil then
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

    if checkTwice then
        m:_scheduleReconcile(1)
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
