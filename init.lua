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
local hsaxuielement = require("hs.axuielement")
local hsdrawing = require("hs.drawing")

local CHROME_BUNDLE = "com.google.Chrome"
local HAMMERSPOON_BUNDLE = "org.hammerspoon.Hammerspoon"

local State = dofile(hs.spoons.resourcePath("state.lua"))
local Menu = dofile(hs.spoons.resourcePath("menu.lua"))
local Chrome = dofile(hs.spoons.resourcePath("chrome.lua"))
-- The label, Inbox and day pages, opened from here without the extension.
local PAGES_DIR = hs.spoons.resourcePath("chrome-extension")

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
-- With chromeWindowNames, a window named after a space also keeps a pinned
-- tab of the label page (chrome-extension/label.html): its tab title
-- is the window's name and its icon the space's number on the space's color,
-- so a window shows which space it belongs to from inside Chrome. Renaming
-- the space updates the tab; a window that loses the name loses the tab.
-- Chrome only adds a tab to its front window, so a window still missing its
-- label gets it the next time it comes to the front. The page and its
-- pinning come from the extension, or from SpaceManager without it (see
-- chromeExtension).
m.chromeWindowLabels = false

-- The Inbox: one Chrome window, named inboxName, that links land in (see
-- linkRoutingNoChrome). It is opened when a link needs it and there is none,
-- with the Inbox page as its first tab, pinned. Its name is never
-- overwritten by chromeWindowNames. With the extension, every new tab in the
-- window goes into a group for the day it was opened, "📅 Sat, Oct 4";
-- without it, a link routed there on a new day first gets a "📅 Sat, Oct 4"
-- divider tab (tabs opened in the window by hand get none).
m.inbox = false
m.inboxName = "📥 Inbox"
-- The position of a space the Inbox is made on (1 for the first), or nil.
-- With chromeWindowNames on and no Inbox anywhere, the oldest Chrome window
-- on that space becomes the Inbox instead of taking the space's name -- so
-- "🟥 01 - Today" turns into the Inbox, and the space's other windows keep
-- its name. Its label tab, if it has one, becomes the Inbox page. Close the
-- Inbox and the next window there becomes it.
m.inboxSpace = nil

-- The SpaceManager Chrome extension (this spoon's chrome-extension folder,
-- loaded unpacked) serves the label, Inbox and day pages, pins them, and
-- groups the Inbox's tabs by day. Where Chrome extensions cannot be
-- installed, set this false: the same pages open from this spoon's folder as
-- file:// pages, SpaceManager pins them through Chrome's Tab > Pin Tab menu
-- item (which takes Chrome being the active app, so a label waits for that),
-- and the Inbox gets day divider tabs instead of groups. Label tabs made the
-- other way are taken over when this changes.
m.chromeExtension = true
m.extensionId = "jcabbbkgmcfmkekcjeokgbhniieojpgd"

-- Links clicked in other apps open in a Chrome window on the space showing,
-- rather than in whichever window Chrome last used, which pulls the screen to
-- that window's space. Hammerspoon has to be the default browser for this:
-- with linkRouting on, start() asks macOS to make it so (macOS confirms the
-- change once). A link that cannot be routed is handed to Chrome as usual.
m.linkRouting = false
-- A link opens in the Inbox when it is on the space showing (with inbox
-- on), else in the frontmost Chrome window there. With no Chrome window on
-- the space showing: "inbox" opens it in the Inbox, wherever that is (macOS
-- moves to its space), or a new Inbox here; "newWindow" opens a new window
-- here; "chrome" hands the link to Chrome to open wherever it would.
m.linkRoutingNoChrome = "newWindow"

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

    if m.chromeWindowNames then
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

function m:_chromeApp()
    return hsapplication.get("Google Chrome")
end

-- Chrome's own view of its windows, via scripting: id, title, givenName,
-- bounds {x, y, width, height}. With labelPages (urls), also front (Chrome's
-- front window) and labels, the window's tabs showing one of those pages
-- {index=, url=}. nil when Chrome is not running or refuses.
function m:_chromeScriptWindows(labelPages)
    if not m:_chromeApp() then
        return nil
    end
    -- One Apple Event per property for all windows at once, not one per
    -- window: the cost stays flat however many windows are open.
    local ok, result = hsosascript.javascript(string.format([[
        const labelPages = %s;
        const ws = Application("Google Chrome").windows;
        const ids = ws.id(), titles = ws.title(), names = ws.givenName(), bounds = ws.bounds();
        const indexes = labelPages ? ws.index() : [], urls = labelPages ? ws.tabs.url() : [];
        JSON.stringify(ids.map((id, i) => {
            const w = { id: String(id), title: titles[i], givenName: names[i], bounds: bounds[i] };
            if (labelPages) {
                w.front = indexes[i] === 1;
                w.labels = [];
                urls[i].forEach((url, t) => {
                    if (labelPages.some(p => url.startsWith(p))) { w.labels.push({ index: t + 1, url: url }); }
                });
            }
            return w;
        }));
    ]], labelPages and hsjson.encode(labelPages) or "false"))
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

-- The label page in both forms, the one in use first: a label tab made the
-- other way is still a label, and is moved over to this way. With the Inbox
-- on, the Inbox page counts as a label too: it is the Inbox's label, kept by
-- the same pass (see _labelUrls).
function m:_labelPages()
    local pages = {}
    local function add(page)
        table.insert(pages, m:_page(page))
        table.insert(pages, m:_page(page, not m.chromeExtension))
    end
    if m.chromeWindowLabels then
        add("label.html")
    end
    if m.inbox then
        add("inbox.html")
    end
    return pages
end

-- Carry out Chrome.labelPlan's actions. Only ever touches label tabs (see
-- _labelPages), checked again here in case the tabs moved since they were
-- read. Without the extension, a new label is pinned here.
function m:_applyChromeLabels(actions)
    local ok, result = hsosascript.javascript(string.format([[
        const [actions, labelPages, pinHere] = %s;
        const c = Application("Google Chrome");
        const isLabel = (tab) => labelPages.some(p => tab.url().startsWith(p));
        const added = [];
        actions.forEach(a => {
            try {
                const w = c.windows.byId(Number(a.id));
                if (a.close) {
                    a.close.forEach(i => { const t = w.tabs[i - 1]; if (isLabel(t)) { t.close(); } });
                } else if (a.set) {
                    const t = w.tabs[a.set.index - 1];
                    if (isLabel(t)) { t.url = a.set.url; }
                } else if (a.add && w.index() === 1) {
                    // Chrome makes a new tab in its front window whatever
                    // window it is aimed at: only the front window gets one.
                    const active = w.activeTabIndex(), activeId = w.activeTab.id(), before = w.tabs.length;
                    w.tabs.push(c.Tab({ url: a.add }));
                    if (w.tabs.length === before + 1) {
                        if (pinHere) {
                            added.push({ id: a.id, tab: w.tabs[before].id(), active: activeId });
                        } else {
                            w.activeTabIndex = active;
                        }
                    }
                }
            } catch (e) {}
        });
        JSON.stringify(added);
    ]], hsjson.encode({ actions, m:_labelPages(), not m.chromeExtension })))
    if not ok then
        m.logger.w("Could not update Chrome label tabs", hsinspect(result))
        return
    end
    m.logger.d("Chrome label tabs added", result)
    for _, a in ipairs(hsjson.decode(result) or {}) do
        m:_pinChromeTab(a.id, a.tab, a.active)
    end
end

-- A page of the chrome-extension folder as Chrome should open it (see
-- chromeExtension); extension, when given, picks the form instead.
function m:_page(page, extension)
    if extension == nil then
        extension = m.chromeExtension
    end
    return Chrome.pageUrl(page, extension and m.extensionId or nil, PAGES_DIR)
end

local PIN_TAB = { "Tab", "Pin Tab" }
m.pinTimers = {}

-- Pin a tab without the extension. Chrome's Tab > Pin Tab pins the active tab
-- of the front window, and only while Chrome is the active app: the tab is
-- made active for the moment it takes, then restoreTab (a tab id, or nil) is
-- made active again. Pin Tab is ticked while the active tab is pinned, so a
-- pinned tab is never unpinned. Waits a couple of seconds for Chrome to
-- become the active app (a new Inbox has only just asked it to).
function m:_pinChromeTab(windowId, tabId, restoreTab, tries)
    tries = tries or 10
    m.pinTimers[tabId] = nil
    local app = m:_chromeApp()
    if not app then
        return
    end
    if not app:isFrontmost() then
        if tries > 0 then
            m.pinTimers[tabId] = hstimer.doAfter(0.2, function()
                m:_pinChromeTab(windowId, tabId, restoreTab, tries - 1)
            end)
        else
            m.logger.w("Could not pin Chrome tab", tabId, "- Chrome is not the active app")
        end
        return
    end
    local function activate(id)
        local ok, result = hsosascript.javascript(string.format([[
            const [windowId, tabId] = %s;
            const w = Application("Google Chrome").windows.byId(Number(windowId));
            const i = w.tabs.id().map(String).indexOf(String(tabId));
            const front = w.index() === 1 && i >= 0;
            if (front) { w.activeTabIndex = i + 1; }
            front;
        ]], hsjson.encode({ windowId, id })))
        return ok and result == true
    end
    if activate(tabId) then
        local item = app:findMenuItem(PIN_TAB)
        if item and not item.ticked then
            app:selectMenuItem(PIN_TAB)
            m.logger.d("Pinned Chrome tab", tabId)
        end
    else
        m.logger.w("Could not pin Chrome tab", tabId, "- its window is no longer in front")
    end
    if restoreTab ~= nil then
        activate(restoreTab)
    end
end

local function urlEncode(str)
    return (str:gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", c:byte())
    end))
end

local function hexColor(color)
    return string.format("%02x%02x%02x", math.floor(color.red * 255 + 0.5), math.floor(color.green * 255 + 0.5),
        math.floor(color.blue * 255 + 0.5))
end

-- The label page url for each space window name (see chromeWindowLabels),
-- and the Inbox page for the Inbox's name.
function m:_labelUrls(names)
    local urls = {}
    if m.inbox then
        urls[m.inboxName] = m:_page("inbox.html")
    end
    for index, spaceId in ipairs(m:_getAllSpaces() or {}) do
        local name = names[spaceId]
        if name ~= nil and m.chromeWindowLabels then
            local color = m:_getSpaceColor(index)
            urls[name] = string.format("%s?name=%s&n=%02d&bg=%s&fg=%s", m:_page("label.html"), urlEncode(name), index,
                hexColor(color), hexColor(m:_getContrastingTextColor(color)))
        end
    end
    return urls
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
    local labelling = m.chromeWindowLabels or m.inbox
    local scripted = app and m:_chromeScriptWindows(labelling and m:_labelPages() or nil)
    if not scripted then
        return
    end
    local names = m:_spaceNames()
    local hsWindows = m:_chromeHsWindows(app)
    local pairs_ = Chrome.matchWindows(scripted, hsWindows)
    local changes = Chrome.plan(pairs_, names, m.renamedSpaces, scripted, m:_keepNames(), m:_inboxPlace())
    m.renamedSpaces = {}

    local labelActions = {}
    if labelling then
        -- Labels follow the names this pass leaves each window with.
        local renamed = {}
        for _, change in ipairs(changes) do
            renamed[change.id] = change.name
        end
        local windows = {}
        for _, w in ipairs(scripted) do
            -- Without the extension a new label is pinned through Chrome's
            -- menu bar, which only works while Chrome is the active app.
            local front = w.front and (m.chromeExtension or app:isFrontmost())
            table.insert(windows, { id = w.id, givenName = renamed[w.id] or w.givenName, front = front,
                labels = w.labels })
        end
        local labelPlan = Chrome.labelPlan(windows, m:_labelUrls(names))
        labelActions = labelPlan.actions
        -- The rest come to the front later; a Chrome focus then forces a pass.
        m.chromeLabelsPending = #labelPlan.pending > 0
        if #labelActions > 0 then
            m.logger.d("Chrome label tabs", hsinspect(labelActions))
            m:_applyChromeLabels(labelActions)
        end
    end

    if #changes == 0 and #labelActions == 0 then
        -- Nothing to do: remember where everything stood, so ticks can skip
        -- until something moves. After renames, the next pass confirms them.
        local ids = {}
        for _, w in ipairs(hsWindows) do
            table.insert(ids, w.id)
        end
        m.chromeSettled = { ids = ids, signature = m:_chromeSignature(ids, names), at = now }
        return
    end
    if #changes == 0 then
        return
    end
    local byId = {}
    for _, change in ipairs(changes) do
        byId[change.id] = change.name
        m.logger.d("Chrome window", change.id, "->", change.name == "" and "(cleared)" or change.name)
    end
    m:_setChromeWindowNames(byId)
end

function m:_tick(force)
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

-- Open a link where linkRoutingNoChrome and the Inbox say (see
-- Chrome.linkRoute). Anything that goes wrong hands the link to Chrome.
function m:routeLink(url)
    local ok, routed = pcall(m._routeLink, m, url)
    if not ok then
        m.logger.w("Could not route link", url, hsinspect(routed))
    end
    if not (ok and routed) then
        m:_openInChrome(url)
    end
end

-- Where Chrome.plan makes the Inbox (see inboxSpace), or nil.
function m:_inboxPlace()
    if not (m.inbox and m.inboxSpace) then
        return nil
    end
    local spaceId = (m:_getAllSpaces() or {})[m.inboxSpace]
    return spaceId and { name = m.inboxName, spaceId = spaceId } or nil
end

-- Names chromeWindowNames never overwrites.
function m:_keepNames()
    return m.inbox and { [m.inboxName] = true } or {}
end

-- true once the link is open.
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
    local route = Chrome.linkRoute(pairs_, hsspaces.focusedSpace(), order,
        m.inbox and m.inboxName or nil, m.linkRoutingNoChrome)
    if route == nil then
        return false
    end
    local id = route.pair and route.pair.chrome.id
    if route.inbox and id == nil then
        -- An Inbox Hammerspoon could not place on a space is still the Inbox.
        for _, w in ipairs(scripted) do
            if w.givenName == m.inboxName then
                id = w.id
            end
        end
    end
    local target = id and { id = id, window = route.pair and route.pair.hs.window }
    local newInbox = route.inbox and target == nil
    -- Without the extension to group the Inbox's tabs by day, a link there
    -- on a new day comes after a divider tab for the day.
    local divider = false
    if route.inbox and not m.chromeExtension then
        local day = Chrome.dayDivider(os.date("*t"))
        divider = string.format("%s?name=%s&n=%s&bg=%s&fg=%s", m:_page("day.html"), urlEncode(day.title), day.n,
            day.bg, day.fg)
    end

    -- A new Chrome window opens on the space showing.
    local ok, result = hsosascript.javascript(string.format([[
        const [url, id, inboxName, inboxPage, divider] = %s;
        const c = Application("Google Chrome");
        const addDivider = (w) => {
            if (divider && !w.tabs.url().includes(divider)) { w.tabs.push(c.Tab({ url: divider })); }
        };
        let made = null;
        if (id === false) {
            const w = c.Window().make();
            if (inboxName) {
                w.givenName = inboxName;
                w.activeTab.url = inboxPage;
                made = { id: String(w.id()), inboxTab: w.activeTab.id() };
                addDivider(w);
                w.tabs.push(c.Tab({ url: url }));
                w.activeTabIndex = w.tabs.length;
            } else {
                w.activeTab.url = url;
            }
            w.index = 1;
            c.activate();
        } else {
            // Chrome makes a new tab in its front window whatever window the
            // tab is aimed at, so bring the target to the front first, then
            // confirm the tab landed there.
            const w = c.windows.byId(Number(id));
            w.index = 1;
            addDivider(w);
            const before = w.tabs.length;
            w.tabs.push(c.Tab({ url: url }));
            if (w.tabs.length !== before + 1) { throw new Error("tab not added to window " + id); }
            w.activeTabIndex = w.tabs.length;
        }
        JSON.stringify(made || {});
    ]], hsjson.encode({ url, target and target.id or false,
        newInbox and m.inboxName or false, m:_page("inbox.html"), divider })))
    if ok and not m.chromeExtension then
        -- The new Inbox's own tab, pinned once Chrome is the active app; the
        -- link stays the tab showing.
        local made = hsjson.decode(result)
        if made and made.id then
            local okActive, active = hsosascript.javascript(string.format(
                [[Application("Google Chrome").windows.byId(%s).activeTab.id();]], made.id))
            m:_pinChromeTab(made.id, made.inboxTab, okActive and active or nil)
        end
    end
    if not ok then
        -- routeLink hands it to Chrome; if a tab did land in another window,
        -- the link ends up open twice rather than not at all.
        m.logger.w("Could not open link in Chrome", url, hsinspect(result))
        return false
    end
    if target and target.window then
        -- On another space (the Inbox), macOS moves to it.
        target.window:focus()
    elseif target then
        app:activate()
    end
    m.logger.d("Routed link", url, "to", target and target.id or (newInbox and "a new Inbox" or "a new window"))
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
    m.chromeFilter:subscribe(hswindowfilter.windowFocused, function()
        if m.chromeLabelsPending then
            m:_scheduleReconcile(0.5)
        end
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

-- Mission Control with a legend of space names in the bottom-left corner, so
-- the numbered "Desktop N" in its spaces bar can be told apart when dragging
-- a window to a space. The bar itself is left alone so its previews still
-- expand on hover. Calling it again while open closes both. Mission Control
-- opened any other way (hot corner, F3, a swipe) shows no legend.
function m:toggleMissionControl()
    if m.legendCanvas then
        m:_hideLegend()
        hsspaces.closeMissionControl()
        return
    end
    m:_showLegend()
    hsspaces.openMissionControl()
    -- Nothing reports Mission Control opening or closing, but while it is
    -- open the Dock's accessibility tree holds an element with id "mc". Watch
    -- for it only while the legend is up: it goes when Mission Control does,
    -- however that is closed, or if Mission Control never opened.
    local seen, started = false, hstimer.secondsSinceEpoch()
    m.legendPoll = hstimer.doEvery(0.15, function()
        if m:_missionControlOpen() then
            seen = true
        elseif seen or hstimer.secondsSinceEpoch() - started > 2 then
            m:_hideLegend()
        end
    end)
end

function m:_missionControlOpen()
    local dock = hsapplication.get("com.apple.dock")
    if not dock then
        return false
    end
    local ok, children = pcall(function()
        return hsaxuielement.applicationElement(dock):attributeValue("AXChildren")
    end)
    for _, child in ipairs(ok and children or {}) do
        if child:attributeValue("AXIdentifier") == "mc" then
            return true
        end
    end
    return false
end

-- One lozenge per space, in the desktop lozenge's colors and font, stacked
-- above it: " 01 - Today". The current space's is outlined.
function m:_showLegend()
    local current = hsspaces.focusedSpace()
    local rows = {}
    for index, spaceId in ipairs(m:_getAllSpaces() or {}) do
        if hsspaces.spaceType(spaceId) == "user" then
            local record = m.state:getSpaceById(spaceId)
            local name = (record and record.name) or m.spaceConfig[index]
            if name == nil or name == "" then
                name = m.unnamedSpaceName
            end
            rows[#rows + 1] = {
                text = " " .. (Chrome.spaceWindowName(index, name) or string.format("%02d", index)) .. " ",
                color = m:_getSpaceColor(index),
                current = spaceId == current
            }
        end
    end
    if #rows == 0 then
        return
    end

    local style = { font = "Courier", size = 24 }
    local lineH, gap = 28, 6
    local w = 0
    for _, row in ipairs(rows) do
        w = math.max(w, hsdrawing.getTextDrawingSize(row.text, style).w)
    end
    w = math.ceil(w) + 4
    local h = #rows * lineH + (#rows - 1) * gap
    local inset = 2 -- room for the current space's outline
    local res = hsscreen.primaryScreen():fullFrame()

    -- Above the desktop lozenge. "stationary" keeps Mission Control from
    -- shrinking the canvas into a window thumbnail, so it draws over it.
    local canvas = hscanvas.new({
        x = res.x + 20 - inset,
        y = res.y + res.h - 26 - gap - h - inset,
        w = w + inset * 2,
        h = h + inset * 2
    })
    canvas:level(hscanvas.windowLevels.overlay)
    canvas:behavior({ "canJoinAllSpaces", "stationary" })
    for i, row in ipairs(rows) do
        local frame = { x = inset, y = inset + (i - 1) * (lineH + gap), w = w, h = lineH }
        canvas[#canvas + 1] = {
            type = "rectangle",
            action = row.current and "strokeAndFill" or "fill",
            fillColor = row.color,
            strokeColor = { white = 1 },
            strokeWidth = 2,
            roundedRectRadii = { xRadius = 5, yRadius = 5 },
            frame = frame
        }
        canvas[#canvas + 1] = {
            type = "text",
            text = row.text,
            textFont = "Courier",
            textSize = 24,
            textColor = m:_getContrastingTextColor(row.color),
            frame = frame
        }
    end
    canvas:show()
    m.legendCanvas = canvas
end

function m:_hideLegend()
    if m.legendPoll then
        m.legendPoll:stop()
        m.legendPoll = nil
    end
    if m.legendCanvas then
        m.legendCanvas:delete()
        m.legendCanvas = nil
    end
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
