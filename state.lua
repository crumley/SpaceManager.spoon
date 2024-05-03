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

function State:getActivityById(activityId)
    assert(activityId ~= nil)
    return self.activities[activityId]
end

function State:getActivitiesBySpaceId(spaceId)
    assert(spaceId ~= nil)

    local activities = {}
    local space = self.spaces[spaceId]

    if space ~= nil then
        for activityId, _ in pairs(space) do
            table.insert(activities, self:getActivityById(activityId))
        end
    end

    return activities
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
    local activity = self.activities[activityId]
    assert(activity ~= nil)

    -- Remove activity from any previous space
    if activity.spaceId ~= nil then
        local space = self.spaces[activity.spaceId]
        if space then
            space[activityId] = nil
        end
    end

    -- Add activity to new space
    if spaceId ~= nil then
        if (self.spaces[spaceId] ~= nil) then
            self.spaces[spaceId][activityId] = true
        else
            self.spaces[spaceId] = { [activityId] = true }
        end
    end

    activity.spaceId = spaceId
end

function State:windowMoved(windowId, activityId)
    -- Remove window from any other activity
    for id, activity in pairs(self.activities) do
        if id ~= activityId then
            activity.windowIds[windowId] = nil
        end
    end

    -- Add window to the new activity
    if activityId ~= nil and self.activities[activityId] ~= nil then
        self.activities[activityId].windowIds[windowId] = true
    end
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
