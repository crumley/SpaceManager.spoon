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

local actions = {
  start = function (choice)
    local activityTemplateId = choice["activityTemplateId"]
    m:startActivityFromTemplate(activityTemplateId)
  end,

  stop = function (choice)
    local activityId = choice["activityId"]
    m:stopActivity(activityId)
  end,

  jump = function (choice)
    local activityId = choice["activityId"]
    -- TODO
  end,

  closeAll = function ()
    m:closeAll()
  end,

  reset = function ()
    m:reset()
  end,

  cleanup = function ()
    m:cleanup()
  end,
}

function m:init()
  m.logger.d('init')

  m.state = State.new()

  m.chooser = hschooser.new(function (choice)
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
  for id, template in pairs(m.activityTemplates) do
    template.id = id
  end

  if m.dockOnPrimaryOnly then
    local w = hsspaces.watcher.new(function (s)
      m:_onSpaceChanged(true)
    end)
    w.start(w)
    m:_onSpaceChanged(true)
  end

  if m.desktopLozenge then
    m.canvas = m:_createCanvas()
    m.canvas:show()
  end

  pcall( function () m:_restoreState() end)
end

function m:showMenu()
  m.chooser:choices(Menu.generateChoices(m.activityTemplates, m.state))
  m.chooser:show()
end

function m:startActivityFromTemplate(templateId, windowObjs)
  local template = m.activityTemplates[templateId]
  m.logger.d('startActivity template=', template)

  local activityId = m.state:activityStarted(templateId)

  -- If the activity was seeded with windows, record them
  if windowObjs ~= nil and #windowObjs > 0 then
    for _, window in ipairs(windowObjs) do
      local wid = window:id()
      m.state:windowMoved(wid, activityId)
    end
  end

  local space = m:_getDefaultSpace()
  if template["space"] then
    local screenId = hsscreen.primaryScreen():getUUID()
    hsspaces.addSpaceToScreen(screenId)
    local spaces = hsspaces.allSpaces()[screenId]
    space = spaces[#spaces]
  end

  m:moveActivityToSpace(activityId, space)
  hsspaces.gotoSpace(space)

  if template["layout"] then
    hslayout.apply(template["layout"])
  end

  m:_saveState()
end

function m:stopActivity(activityId, keepSpace)
  m.logger.d('stopActivity', activityId)

  -- TODO

  -- TODO: close windows that are "owned" by the activity, move the others...

  local defaultSpace = m:_getDefaultSpace()
  for _, wid in ipairs(activityRecord.windowIds) do
    local w = hswindow(wid)
    if w ~= nil then
      hsspaces.moveWindowToSpace(w, defaultSpace)
    end
  end

  if not keepSpace then
    hsspaces.gotoSpace(defaultSpace)
    hsspaces.removeSpace(activityRecord.space)
  end

  m:_saveState()
end

function m:moveActivityToSpace(activityRecord, space)
  -- todo

  for _, wid in ipairs(activityRecord.windowIds) do
    local w = hswindow(wid)
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

  for activityId in pairs(m.activityTemplates) do
    m:stopActivity(activityId, true)
  end

  -- TODO: Clean up activities
  -- Save state
  -- Update canvas

  hstimer.doAfter(2, function ()
    hsfnutils.ieach(hsspaces.allSpaces()[screenId], function (s)
      if s ~= firstSpaceId then
        r = hsspaces.removeSpace(s, false)
      end
    end)
    hsspaces.closeMissionControl()
  end)

  m:_resetState()
end

function m:cleanUp() 
  -- take what is in m.state and make reality match as best as possible
  -- (call this after restoreState)
end

function m:reset()
  m.state = State.new()
  m:_saveState()
  m:cleanUp()
end

function m:_createCanvas() 
  local screen = hsscreen.primaryScreen()
  local res = screen:fullFrame()
  
  local canvas = hscanvas.new({
    x = 20,
    y = res.h - 18,
    w = 500,
    h = 18
  })
  canvas:behavior(hscanvas.windowBehaviors.canJoinAllSpaces)
  canvas:level(hscanvas.windowLevels.desktopIcon)
  
  canvas[1] = {
    type = "rectangle",
    action = "fill",
    fillColor = { color = hsdrawing.color.black, alpha = 0.5 },
    roundedRectRadii = { xRadius = 5, yRadius = 5 },
  }

  canvas[2] = {
    id = "cal_title",
    type = "text",
    text = m:_spaceInfoText(),
    textFont = "Courier",
    textSize = 16,
    textColor = hsdrawing.color.osx_green,
    textAlignment = "left",
  }

  return canvas
end

function m:_saveState()
  m.canvas[2].text = m:_spaceInfoText()

  local state = m.state:toTable()

  m.logger.d("Saving state", hsinspect(state))

  hssettings.set(m.settingsKey, state)
end

function m:_restoreState()
  local stateTable = hssettings.get(m.settingsKey)

  m.logger.d("Restoring state", hsinspect(stateTable))
  if stateTable ~= nil then
    local state = State.fromTable(stateTable)
  end
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
  elseif info.spaceRecord ~= nil and #info.spaceRecord.activityRecords > 0 then
    spaceName = info.spaceRecord.activityRecords[1].name
  elseif info.activity then
    spaceName = info.activity.text
  end
  return string.format(" %s (%d/%d)", spaceName, info.currentIndex, info.count)
end

function m:_spaceInfo()
  local screenId = hsscreen.primaryScreen():getUUID()
  local allSpaces = hsspaces.allSpaces()[screenId]
  local firstSpaceId = allSpaces[1]
  local currentSpaceId = hsspaces.focusedSpace()

  local activities = m.state:getActivitiesBySpaceId(currentSpaceId)
  local activityRecord = activities ~= nil and #activities > 0 and activities[1] or nil

  return {
    count = #allSpaces,
    isPrimary = firstSpaceId == currentSpaceId,
    currentIndex = hsfnutils.indexOf(allSpaces, currentSpaceId),
    primaryActivityRecord = activityRecord
  }
end

function m:_isDockHidden()
  local asCommand = "tell application \"System Events\" to return autohide of dock preferences"
  local ok, isDockHidden = hsosascript.applescript(asCommand)

  if not ok then
    local msg = "An error occurred getting the value of autohide for the Dock."
    hsnotify.new({ title = "Hammerspoon", informativeText = msg }):send()
  end

  return isDockHidden
end

function m:_onSpaceChanged(checkTwice)
  local isDockHidden = m:_isDockHidden()

  if m.dockOnPrimaryOnly then
    if m:_isPrimarySpace() and isDockHidden then
      m:toggleDock()
    end

    if not m:_isPrimarySpace() and not isDockHidden then
      m:toggleDock()
    end

    -- Check once more after spaces settle...
    if checkTwice then
      hstimer.doAfter(1, function ()
        self:_onSpaceChanged(false)
      end)
    end
  end

  if m.desktopLozenge and m.canvas then
    m.canvas[2].text = m:_spaceInfoText()
  end
end

return m
