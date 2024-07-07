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

local Space = {}
function Space.new(spaceId, index)
    local space = {}
    setmetatable(space, { __index = Space })
    space.id = spaceId
    space.index = index
    space.activityIds = {}
    return space
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

function State.fromTable(tableState)
    if tableState.version == 1 then
        local state = State.new()

        state.activities = tableKeysToNumber(tableState.activities)
        state.spaces = tableKeysToNumber(tableState.spaces)

        for k, v in pairs(state.activities) do
            state._lastActivityIndex = math.max(v.id, state._lastActivityIndex)
        end

        return state
    end

    return nil
end

function State:toTable()
    local ret = {
        activities = tableKeysToString(self.activities),
        spaces = tableKeysToString(self.spaces),
        version = self.version,
    }

    return ret
end

function tableKeysToString(t)
    if (type(t) ~= "table") then
        return t
    end

    local ret = {}
    for k, v in pairs(t) do
        if type(k) == "string" then
            ret[k] = tableKeysToString(v)
        else
            ret[tostring(k)] = tableKeysToString(v)
        end
    end
    return ret
end

function tableKeysToNumber(t)
    if (type(t) ~= "table") then
        return t
    end

    local ret = {}
    for k, v in pairs(t) do
        if type(k) == "number" then
            ret[k] = tableKeysToNumber(v)
        else
            numberKey = tonumber(k)
            if numberKey ~= nil then
                ret[numberKey] = tableKeysToNumber(v)
            else
                ret[k] = tableKeysToNumber(v)
            end
        end

    end
    return ret
end

function State:getActivities()
    return self.activities
end

function State:getActivityById(activityId)
    assert(activityId ~= nil)
    return self.activities[activityId]
end

function State:getActivityById1()
    return self.activities[1]
end

function State:getSpaceByActivityId(activityId)
    assert(activityId ~= nil)
    local activity = self.activities[activityId]
    local spaceId =  activity ~= nil and activity.spaceId or nil
    return self:_getOrCreateSpace(spaceId)
end

function State:getWindowsByActivityId(activityId)
    assert(activityId ~= nil)
    return self.activities[activityId].windowIds
end

function State:getActivitiesBySpaceId(spaceId)
    assert(spaceId ~= nil)

    local activities = {}
    for _, activity in pairs(self.activities) do
        if activity.spaceId == spaceId then
            table.insert(activities, activity)
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
            space.activityIds[activityId] = nil
        end
    end

    -- Add activity to new space
    if spaceId ~= nil then
        local space = self:_getOrCreateSpace(spaceId)
        space.activityIds[activityId] = true
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

function State:spaceAdded(spaceId, index)
    self:_getOrCreateSpace(spaceId).index = index
end

function State:spaceMoved(spaceId, index)
    self:_getOrCreateSpace(spaceId).index = index
end

function State:spaceRemoved(spaceId)
    -- TODO should the indexes be updated? Maybe no if all we care about is
    -- relative indexes for those that remain.
    self.spaces[spaceId] = nil
end

function State:_getOrCreateSpace(spaceId)
    local space = self.spaces[spaceId]
    if space == nill then
        space = Space.new(spaceId, nil)
        self.spaces[spaceId] = space
    end
    
    return space
end

return State