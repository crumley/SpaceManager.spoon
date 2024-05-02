local Activity = {}

function Activity.new(id, typeId, name)
    local activity = {}
    setmetatable(activity, { __index = Activity })
    activity.id = id
    activity.name = name or typeId
    activity.typeId = typeId
    activity.windowIds = {}
    activity.spaceId = nil
    return activity
end

local State = {}

function State.new()
    local state = {}
    setmetatable(state, { __index = State })
    state.activities = {}
    state.spaces = {}
    state.version = 1
    state._lastActivityIndex = 1
    return state
end

function State:activityStarted(typeId)
    assert(typeId ~= nil)

    local id = self._lastActivityIndex + 1
    self._lastActivityIndex = id
    self.activities[id] = Activity.new(id, typeId)
    return id
end

function State:activityRenamed(activityId, name)
    assert(self.activities[activityId] ~= nil)
    self.activities[activityId].name = name
end

function State:activityStopped(activityId)
    assert(self.activities[activityId] ~= nil)
    self.activities[activityId] = nil
end

function State:activityMoved(activityId, spaceId)
    assert(self.activities[activityId] ~= nil)
    self.activities[activityId].spaceId = spaceId
end

function State:windowMoved(windowId, activityId)
    assert(self.activities[activityId] ~= nil)
    self.activities[activityId].windowIds[windowId] = 1
end

function State:toTable()
    -- TODO can this just be self?
    return {
        activity = self.activity,
        spaces = self.spaces,
        version = self.version,
    }
end

return State
