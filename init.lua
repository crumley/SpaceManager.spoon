--- === SpaceManager ===
---
---

local logger = require("hs.logger")
local chooser = require("hs.chooser")
local application = require("hs.application")

local m = {}
m.__index = m

-- Metadata
m.name = "SpaceManager"
m.version = "0.1"
m.author = "crumley@gmail.com"
m.license = "MIT"
m.homepage = "https://github.com/Hammerspoon/Spoons"

m.logger = logger.new('SpaceManager', 'debug')

-- Settings

-- Hattip: https://apple.stackexchange.com/questions/419028/disable-the-dock-in-all-but-one-desktop-space-only
m.dockOnPrimaryOnly = false
m.desktopLozenge = false
m.spaceToActivity = {}
m.spaceRecordsBySpaceId = {}
m.activityRecordsByActivityId = {}
m.activities = {}
m.settingsKey = m.name .. ".spaceRecordsBySpaceId"

local actions = {
  start = function(activityId)
    m:startActivity(activityId)
  end,

  stop = function(activityId)
    m:stopActivity(activityId)
  end,

  jump = function(activityId)
    hs.spaces.gotoSpace(m.activityRecordsByActivityId[activityId].space)
  end,

  closeAll = function(x)
    -- Do the thing
    m:closeAll()
  end,
}

function m:init()
  m.logger.d('init')

  m.chooser = chooser.new(function(choice)
    if choice then
      local actionName = choice["action"]
      if actionName ~= nil then
        m.logger.d('Select action', actionName)
        actions[actionName](choice["activityId"])
        return
      end
    end
  end)
end

function m:start()
  for id, activity in pairs(m.activities) do
    activity.id = id
  end

  if m.dockOnPrimaryOnly then
    local w = hs.spaces.watcher.new(function(s)
      m:_onSpaceChanged(true)
    end)
    w.start(w)
    m:_onSpaceChanged(true)
  end

  if m.desktopLozenge then
    local screen = hs.screen.primaryScreen()
    local res = screen:fullFrame()
    m.canvas = hs.canvas.new({
      x = 20,
      y = res.h - 18,
      w = 500,
      h = 18
    })
    m.canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    m.canvas:level(hs.canvas.windowLevels.desktopIcon)
    m.canvas[1] = {
      type = "rectangle",
      action = "fill",
      fillColor = { color = hs.drawing.color.black, alpha = 0.5 },
      roundedRectRadii = { xRadius = 5, yRadius = 5 },
    }
    m.canvas[2] = {
      id = "cal_title",
      type = "text",
      text = m:spaceInfoText(),
      textFont = "Courier",
      textSize = 16,
      textColor = hs.drawing.color.osx_green,
      textAlignment = "left",
    }
    m.canvas:show()
  end

  m:_loadState()
  m:_reconcileState()
end

function m:show()
  m.chooser:choices(m:_generateChoices())
  m.chooser:show()
end

function m:createActivityRecord(activity)
  local windowIds = {}

  for _, hint in ipairs(activity["apps"]) do
    local app = application(hint)
    if app ~= nil then
      local window = app:focusedWindow()
      table.insert(windowIds, window:id())
    end
  end

  return {
    activityId = activity.id,
    windowIds = windowIds,
  }
end

function m:_resetState()
  m.spaceRecordsBySpaceId = {}
  hs.settings.set(m.settingsKey, {})
end

function m:_saveState()
  m.canvas[2].text = m:spaceInfoText()

  local state = {}
  for k, v in pairs(m.spaceRecordsBySpaceId) do
    state[tostring(k)] = v
  end

  m.logger.d("Saving state", hs.inspect(state))

  hs.settings.set(m.settingsKey, state)
end

function m:_loadState()
  local state = hs.settings.get(m.settingsKey)

  if state ~= nil then
    m.logger.i("Loading state", hs.inspect(state))

    for k, spaceRecord in pairs(state) do
      -- TODO validate state
      m.spaceRecordsBySpaceId[tonumber(k)] = spaceRecord
      for activityId, activityRecord in pairs(spaceRecord.activityRecordsByActivityId) do
        m.activityRecordsByActivityId[activityId] = activityRecord
      end
    end
  end
end

function m:_reconcileState()
  -- TODO: This is very broken!
  -- TODO BUG: Validate if the space index is maintained after moving the space or if its an index
  -- TODO validate activity records (windows, spaces, etc) creating spaces and migrating as needed.
  -- for id, activity in pairs(m.activities) do
  --   if activity.permanent and m.activityRecordsByActivityId[activity.id] == nil then
  --     m:startActivity(id)
  --   end
  -- end
end

function m:getSpaceRecord(spaceId)
  if m.spaceRecordsBySpaceId[spaceId] then
    return m.spaceRecordsBySpaceId[spaceId]
  end

  local spaceRecord = {
    spaceId = spaceId,
    activityRecordsByActivityId = {}
  }

  m.spaceRecordsBySpaceId[spaceId] = spaceRecord
  return spaceRecord
end

function m:moveActivityToSpace(activityRecord, space)
  activityRecord.space = space
  local spaceRecord = m:getSpaceRecord(space)

  spaceRecord.activityRecordsByActivityId[activityRecord.activityId] = activityRecord
  m.activityRecordsByActivityId[activityRecord.activityId] = activityRecord

  for _, wid in ipairs(activityRecord.windowIds) do
    local w = hs.window(wid)
    if w ~= nil then
      hs.spaces.moveWindowToSpace(w, space)
    end
  end
end

function m:startActivity(activityId)
  if activityId == nil then
    local currentWindow = hs.window.focusedWindow()
    -- TODO Need an adhoc activity
  end

  local activity = m.activities[activityId]
  m.logger.d('startActivity', activity)

  if activity["setup"] ~= nil then
    activity["setup"]()
  end

  local activityRecord = m:createActivityRecord(activity)

  local space = m:getDefaultSpace()
  if activity["space"] then
    local screenId = hs.screen.primaryScreen():getUUID()
    hs.spaces.addSpaceToScreen(screenId)
    local spaces = hs.spaces.allSpaces()[screenId]
    space = spaces[#spaces]
  end

  m:moveActivityToSpace(activityRecord, space)
  hs.spaces.gotoSpace(space)

  if activity["layout"] then
    hs.layout.apply(activity["layout"])
  end

  m:_saveState()
end

function m:stopActivity(activityId, keepSpace)
  m.logger.d('stopActivity', activityId)

  local activityRecord = m.activityRecordsByActivityId[activityId]

  if activityRecord == nil then
    return
  end

  m.activityRecordsByActivityId[activityId] = nil

  -- TODO: close windows that are "owned" by the activity, move the others...

  local defaultSpace = m:getDefaultSpace()
  for _, wid in ipairs(activityRecord.windowIds) do
    local w = hs.window(wid)
    if w ~= nil then
      hs.spaces.moveWindowToSpace(w, defaultSpace)
    end
  end

  local spaceRecord = m.spaceRecordsBySpaceId[activityRecord.space]
  spaceRecord.activityRecordsByActivityId[activityId] = nil
  if next(spaceRecord.activityRecordsByActivityId) == nil then
    m.spaceRecordsBySpaceId[activityRecord.space] = nil
  end

  if not keepSpace then
    hs.spaces.gotoSpace(defaultSpace)
    hs.spaces.removeSpace(activityRecord.space)
  end

  m:_saveState()
end

function m:isStarted(activityId)
  return m.activityRecordsByActivityId[activityId] ~= nil
end

function m:_generateChoices()
  local choices = {}

  local spaceInfo = m:spaceInfo()
  if spaceInfo.activity ~= nil and not spaceInfo.activity.permanent then
    table.insert(choices,
      {
        action = "stop",
        activityId = spaceInfo.activity.id,
        text = "Stop: " .. m.activities[spaceInfo.activity.id].text,
        subText = ""
      }
    )
  end

  for activityId in pairs(m.activityRecordsByActivityId) do
    local activity = m.activities[activityId]
    local isCurrent = spaceInfo.activity ~= nil and spaceInfo.activity.id == activityId
    if not isCurrent then
      table.insert(choices, {
        action = "jump",
        activityId = activityId,
        text = "Goto: " .. activity["text"],
        subText = activity["subText"]
      })
    end
  end

  for activityId, activity in pairs(m.activities) do
    local isStarted = m:isStarted(activityId)
    local isCurrent = spaceInfo.activity ~= nil and spaceInfo.activity.id == activityId
    if not isCurrent and not isStarted then
      table.insert(choices, {
        action = "start",
        activityId = activityId,
        text = "Start: " .. activity["text"],
        subText = activity["subText"]
      })
    end
  end

  table.insert(choices,
    {
      action = "closeAll",
      text = "Close All",
      subText = "Stop all open activities and remove spaces."
    }
  )

  return choices
end

function m:getDefaultSpace()
  -- First space is the default space (for now)
  local screenId = hs.screen.primaryScreen():getUUID()
  return hs.spaces.allSpaces()[screenId][1]
end

function m:isPrimarySpace()
  local screenId = hs.screen.primaryScreen():getUUID()
  local firstSpaceId = hs.spaces.allSpaces()[screenId][1]
  local currentSpaceId = hs.spaces.focusedSpace()
  return firstSpaceId == currentSpaceId
end

function m:spaceInfoText()
  local info = m:spaceInfo()
  local spaceName = "(Unmanaged)"
  if info.isPrimary then
    spaceName = "Primary"
  elseif info.activity then
    spaceName = info.activity.text
  end
  return string.format(" %s (%d/%d)", spaceName, info.currentIndex, info.count)
end

function m:spaceInfo()
  local screenId = hs.screen.primaryScreen():getUUID()
  local allSpaces = hs.spaces.allSpaces()[screenId]
  local firstSpaceId = allSpaces[1]
  local currentSpaceId = hs.spaces.focusedSpace()
  local spaceRecord = m.spaceRecordsBySpaceId[currentSpaceId]
  local activityId = spaceRecord and next(spaceRecord.activityRecordsByActivityId, nil) or nil
  local activity = activityId and m.activities[activityId] or nil

  return {
    count = #allSpaces,
    isPrimary = firstSpaceId == currentSpaceId,
    currentIndex = hs.fnutils.indexOf(allSpaces, currentSpaceId),
    activity = activity,
  }
end

function m:closeAll()
  local screenId = hs.screen.primaryScreen():getUUID()
  local firstSpaceId = hs.spaces.allSpaces()[screenId][1]

  if not m:isPrimarySpace() then
    hs.spaces.gotoSpace(firstSpaceId)
  end

  for activityId in pairs(m.activities) do
    m:stopActivity(activityId, true)
  end

  -- TODO: Clean up activities
  -- Save state
  -- Update canvas

  hs.timer.doAfter(2, function()
    hs.fnutils.ieach(hs.spaces.allSpaces()[screenId], function(s)
      if s ~= firstSpaceId then
        r = hs.spaces.removeSpace(s, false)
      end
    end)
    hs.spaces.closeMissionControl()
  end)

  m:_resetState()
end

-- function m:clearCurrentSpace()
--   local screenId = hs.screen.primaryScreen():getUUID()
--   local targetSpaceId = hs.spaces.allSpaces()[screenId][1]
--   local sourceSpaceId = hs.spaces.focusedSpace()

--   local windows = hs.spaces.windowsForSpace(sourceSpaceId)

--   hs.fnutils.each(windows, function(w)
--     hs.spaces.moveWindowToSpace(w, targetSpaceId)
--   end)
-- end

function m:toggleDock()
  hs.eventtap.keyStroke({ "cmd", "alt" }, "d")
end

function m:_isDockHidden()
  local asCommand = "tell application \"System Events\" to return autohide of dock preferences"
  local ok, isDockHidden = hs.osascript.applescript(asCommand)

  if not ok then
    local msg = "An error occurred getting the value of autohide for the Dock."
    hs.notify.new({ title = "Hammerspoon", informativeText = msg }):send()
  end

  return isDockHidden
end

function m:_onSpaceChanged(checkTwice)
  local isDockHidden = m:_isDockHidden()

  if m.dockOnPrimaryOnly then
    if m:isPrimarySpace() and isDockHidden then
      m:toggleDock()
    end

    if not m:isPrimarySpace() and not isDockHidden then
      m:toggleDock()
    end

    -- Check once more after spaces settle...
    if checkTwice then
      hs.timer.doAfter(1, function()
        self:_onSpaceChanged(false)
      end)
    end
  end

  if m.desktopLozenge and m.canvas then
    m.canvas[2].text = m:spaceInfoText()
  end
end

return m
