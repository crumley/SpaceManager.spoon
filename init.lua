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

m.settingsKey = m.name .. ".spaceRecordsBySpaceId"

-- Hattip: https://apple.stackexchange.com/questions/419028/disable-the-dock-in-all-but-one-desktop-space-only
m.dockOnPrimaryOnly = false
m.desktopLozenge = false

-- Configuration
m.activities = {}

local actions = {
  start = function (choice)
    local activityId = choice["activityId"]
    m:startActivity(activityId)
  end,

  stop = function (choice)
    local activityRecordId = choice["activityRecordId"]
    m:stopActivity(activityRecordId)
  end,

  jump = function (choice)
    local activityRecordId = choice["activityRecordId"]
    local activityRecord = hsfnutils.find(m.state.activityRecords,
      function (ar) return ar.id == activityRecordId end)
    if activityRecord ~= nil and activityRecord.space ~= nil then
      hsspaces.gotoSpace(activityRecord.space)
    end
  end,

  closeAll = function ()
    m:closeAll()
  end,

  reset = function ()
    m:reset()
  end,
}

function m:init()
  m.logger.d('init')

  -- State
  m.state = {
    spaceToActivity = {},
    spaceRecordsBySpaceId = {},
    activityRecordsByActivityId = {},
    activeRecordIdIndex = 0,
    activityRecords = {},
    spaceRecords = {}
  }

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
  for id, activity in pairs(m.activities) do
    activity.id = id
  end

  if m.dockOnPrimaryOnly then
    local w = hsspaces.watcher.new(function (s)
      m:_onSpaceChanged(true)
    end)
    w.start(w)
    m:_onSpaceChanged(true)
  end

  if m.desktopLozenge then
    local screen = hsscreen.primaryScreen()
    local res = screen:fullFrame()
    m.canvas = hscanvas.new({
      x = 20,
      y = res.h - 18,
      w = 500,
      h = 18
    })
    m.canvas:behavior(hscanvas.windowBehaviors.canJoinAllSpaces)
    m.canvas:level(hscanvas.windowLevels.desktopIcon)
    m.canvas[1] = {
      type = "rectangle",
      action = "fill",
      fillColor = { color = hsdrawing.color.black, alpha = 0.5 },
      roundedRectRadii = { xRadius = 5, yRadius = 5 },
    }
    m.canvas[2] = {
      id = "cal_title",
      type = "text",
      text = m:spaceInfoText(),
      textFont = "Courier",
      textSize = 16,
      textColor = hsdrawing.color.osx_green,
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

function m:_resetState()
  m.state.spaceRecordsBySpaceId = {}
  hssettings.set(m.settingsKey, {})
end

function m:_saveState()
  m.canvas[2].text = m:spaceInfoText()

  local state = {
    version = 1,
    spaceRecordsBySpaceId = {},
  }

  for k, v in pairs(m.state.spaceRecordsBySpaceId) do
    state.spaceRecordsBySpaceId[tostring(k)] = v
  end

  state.activityRecords = m.state.activityRecords
  state.spaceRecords = m.state.spaceRecords

  m.logger.d("Saving state", hsinspect(state))

  hssettings.set(m.settingsKey, state)
end

function m:_loadState()
  local maxActivityRecordIndex = m.activeRecordIdIndex

  local state = hssettings.get(m.settingsKey)
  -- if state ~= nil then
  --   m.logger.i("Loading state", hsinspect(state))

  --   if state.version ~= nil then
  --     if state.version == 1 then
  --       for k, spaceRecord in pairs(state.spaceRecordsBySpaceId) do
  --         -- TODO validate state
  --         m.state.spaceRecordsBySpaceId[tonumber(k)] = spaceRecord
  --         for activityId, activityRecord in pairs(spaceRecord.activityRecordsByActivityId) do
  --           maxActivityRecordIndex = activityRecord.id ~= nil and math.max(activityRecord.id, maxActivityRecordIndex) or
  --               maxActivityRecordIndex
  --           m.state.activityRecordsByActivityId[activityId] = activityRecord
  --         end
  --       end
  --     else
  --       m.logger.i("Saved state did not have a version, refusing to honor.")
  --       for k, spaceRecord in pairs(state.spaceRecordsBySpaceId) do
  --         -- TODO validate state
  --         m.state.spaceRecordsBySpaceId[tonumber(k)] = spaceRecord
  --         for activityId, activityRecord in pairs(spaceRecord.activityRecordsByActivityId) do
  --           maxActivityRecordIndex = activityRecord.id ~= nil and math.max(activityRecord.id, maxActivityRecordIndex) or
  --               maxActivityRecordIndex
  --           m.state.activityRecordsByActivityId[activityId] = activityRecord
  --         end
  --       end
  --     end
  --   end

  --   m.activeRecordIdIndex = maxActivityRecordIndex
  -- end
end

function m:_reconcileState()
  -- TODO: This is very broken!
  -- TODO BUG: Validate if the space index is maintained after moving the space or if its an index
  -- TODO validate activity records (windows, spaces, etc) creating spaces and migrating as needed.
  -- for id, activity in pairs(m.activities) do
  --   if activity.permanent and m.state.activityRecordsByActivityId[activity.id] == nil then
  --     m:startActivity(id)
  --   end
  -- end
end

function m:moveActivityToSpace(activityRecord, space)
  activityRecord.space = space
  local spaceRecord = m:getSpaceRecord(space)

  table.insert(spaceRecord.activityRecords, activityRecord)
  spaceRecord.activityRecordsByActivityId[activityRecord.activityId] = activityRecord
  m.state.activityRecordsByActivityId[activityRecord.activityId] = activityRecord

  for _, wid in ipairs(activityRecord.windowIds) do
    local w = hswindow(wid)
    if w ~= nil then
      hsspaces.moveWindowToSpace(w, space)
    end
  end
end

function m:startActivity(activityId, windows)
  local activity = m.activities[activityId]
  m.logger.d('startActivity', activity)

  local activityRecord = m:_createActivityRecord(activity)
  if activity["setup"] ~= nil then
    activity["setup"](activityRecord)
  end

  -- If the activity was seeded with windows, record them
  if windows ~= nil and #windows > 0 then
    for _, window in ipairs(windows) do
      table.insert(activityRecord.windowIds, window:id())
    end
  end

  local space = m:getDefaultSpace()
  if activity["space"] then
    local screenId = hsscreen.primaryScreen():getUUID()
    hsspaces.addSpaceToScreen(screenId)
    local spaces = hsspaces.allSpaces()[screenId]
    space = spaces[#spaces]
  end

  m:moveActivityToSpace(activityRecord, space)
  hsspaces.gotoSpace(space)

  if activity["layout"] then
    hslayout.apply(activity["layout"])
  end

  m:_saveState()
end

function m:stopActivity(activityRecordId, keepSpace)
  m.logger.d('stopActivity', activityRecordId)

  local activityRecord = hsfnutils.find(m.state.activityRecords,
    function (ar) return ar.id == activityRecordId end)

  if activityRecord == nil then
    m.logger.debug("No such activityRecord: ", activityRecordId)
    return
  end

  local activityId = activityRecord.activityId
  m.state.activityRecordsByActivityId[activityId] = nil

  -- TODO: close windows that are "owned" by the activity, move the others...

  local defaultSpace = m:getDefaultSpace()
  for _, wid in ipairs(activityRecord.windowIds) do
    local w = hswindow(wid)
    if w ~= nil then
      hsspaces.moveWindowToSpace(w, defaultSpace)
    end
  end

  local spaceRecord = m.state.spaceRecordsBySpaceId[activityRecord.space]
  spaceRecord.activityRecordsByActivityId[activityId] = nil
  if next(spaceRecord.activityRecordsByActivityId) == nil then
    m.state.spaceRecordsBySpaceId[activityRecord.space] = nil
  end

  if not keepSpace then
    hsspaces.gotoSpace(defaultSpace)
    hsspaces.removeSpace(activityRecord.space)
  end

  m:_saveState()
end

function m:isStarted(activityId)
  return m.state.activityRecordsByActivityId[activityId] ~= nil
end

function m:_generateChoices()
  local choices = {}

  local spaceInfo = m:spaceInfo()
  if spaceInfo.spaceRecord ~= nil then
    for _, activityRecord in pairs(spaceInfo.spaceRecord.activityRecords) do
      if not m.activities[activityRecord.activityId].permanent then
        table.insert(choices,
          {
            action = "stop",
            activityRecordId = activityRecord.id,
            text = "Stop: " .. activityRecord.name,
            subText = ""
          }
        )
      end
    end
  end

  for _, activityRecord in pairs(m.state.activityRecords) do
    local activity = m.activities[activityRecord.activityId]
    local isCurrent = spaceInfo ~= nil and spaceInfo.primaryActivityRecord ~= nil and
        spaceInfo.primaryActivityRecord.id == activityRecord.id
    if not isCurrent then
      table.insert(choices, {
        action = "jump",
        activityRecordId = activityRecord.id,
        text = "Goto: " .. activityRecord.name,
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
  local screenId = hsscreen.primaryScreen():getUUID()
  return hsspaces.allSpaces()[screenId][1]
end

function m:isPrimarySpace()
  local screenId = hsscreen.primaryScreen():getUUID()
  local firstSpaceId = hsspaces.allSpaces()[screenId][1]
  local currentSpaceId = hsspaces.focusedSpace()
  return firstSpaceId == currentSpaceId
end

function m:spaceInfoText()
  local info = m:spaceInfo()
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

function m:spaceInfo()
  local screenId = hsscreen.primaryScreen():getUUID()
  local allSpaces = hsspaces.allSpaces()[screenId]
  local firstSpaceId = allSpaces[1]
  local currentSpaceId = hsspaces.focusedSpace()
  local spaceRecord = m.state.spaceRecordsBySpaceId[currentSpaceId]
  local activityRecord = spaceRecord and #spaceRecord.activityRecords > 0 and spaceRecord.activityRecords[1] or nil

  return {
    count = #allSpaces,
    isPrimary = firstSpaceId == currentSpaceId,
    currentIndex = hsfnutils.indexOf(allSpaces, currentSpaceId),
    primaryActivityRecord = activityRecord,
    spaceRecord = spaceRecord,
  }
end

function m:closeAll()
  local screenId = hsscreen.primaryScreen():getUUID()
  local firstSpaceId = hsspaces.allSpaces()[screenId][1]

  if not m:isPrimarySpace() then
    hsspaces.gotoSpace(firstSpaceId)
  end

  for activityId in pairs(m.activities) do
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

-- function m:clearCurrentSpace()
--   local screenId = hsscreen.primaryScreen():getUUID()
--   local targetSpaceId = hsspaces.allSpaces()[screenId][1]
--   local sourceSpaceId = hsspaces.focusedSpace()

--   local windows = hsspaces.windowsForSpace(sourceSpaceId)

--   hs.fnutils.each(windows, function(w)
--     hsspaces.moveWindowToSpace(w, targetSpaceId)
--   end)
-- end

function m:toggleDock()
  hseventtap.keyStroke({ "cmd", "alt" }, "d")
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
    if m:isPrimarySpace() and isDockHidden then
      m:toggleDock()
    end

    if not m:isPrimarySpace() and not isDockHidden then
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
    m.canvas[2].text = m:spaceInfoText()
  end
end

-- State manipulation

function _internalStateToPersistedState(state)
  return {
    version = 0
  }
end

function m:_persistedStateToInternal(state)

end

-- Data structures + State

function m:_createActivityRecord(activity)
  local windowIds = {}

  for _, hint in ipairs(activity["apps"]) do
    local app = hsapplication(hint)
    if app ~= nil then
      local window = app:focusedWindow()
      table.insert(windowIds, window:id())
    end
  end

  local name = activity.text
  if not activity.permanent and not activity.singleton then
    name = string.format("%s: %i", name, #m.state.activityRecords)
  end

  m.state.activeRecordIdIndex = m.state.activeRecordIdIndex + 1
  local activityRecord = {
    id = m.state.activeRecordIdIndex,
    name = name,
    activityId = activity.id,
    windowIds = windowIds,
    space = nil -- starts unassigned
  }
  table.insert(m.state.activityRecords, activityRecord)

  return activityRecord
end

function m:getSpaceRecord(spaceId)
  if m.state.spaceRecordsBySpaceId[spaceId] then
    return m.state.spaceRecordsBySpaceId[spaceId]
  end

  local spaceRecord = {
    spaceId = spaceId,
    activityRecordsByActivityId = {},
    activityRecords = {}
  }

  table.insert(m.state.spaceRecords, spaceRecord)

  m.state.spaceRecordsBySpaceId[spaceId] = spaceRecord
  return spaceRecord
end

return m
