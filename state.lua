local Space = {}
function Space.new(spaceId, index, name)
    local space = {}
    setmetatable(space, {
        __index = Space
    })
    space.id = spaceId
    space.index = index
    space.name = name or nil
    return space
end

local State = {}

function State.new()
    local state = {}
    setmetatable(state, {
        __index = State
    })
    state.spaces = {}
    state.version = 2
    return state
end

function State.fromTable(tableState)
    if tableState.version == 2 then
        local state = State.new()
        state.spaces = tableKeysToNumber(tableState.spaces)
        return state
    elseif tableState.version == 1 then
        -- Migration from old activity-based system: discard old state
        return State.new()
    end
    
    return nil
end

function State:toTable()
    local ret = {
        spaces = tableKeysToString(self.spaces),
        version = self.version
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

function State:getSpaces()
    return self.spaces
end

function State:getSpaceById(spaceId)
    assert(spaceId ~= nil)
    return self.spaces[spaceId]
end

function State:getSpaceByIndex(index)
    assert(index ~= nil)
    for _, space in pairs(self.spaces) do
        if space.index == index then
            return space
        end
    end
    return nil
end

function State:spaceAdded(spaceId, index)
    self:_getOrCreateSpace(spaceId).index = index
end

function State:spaceMoved(spaceId, index)
    self:_getOrCreateSpace(spaceId).index = index
end

function State:spaceRemoved(spaceId)
    self.spaces[spaceId] = nil
end

function State:spaceRenamed(spaceId, name)
    local space = self:_getOrCreateSpace(spaceId)
    space.name = name
end

function State:_getOrCreateSpace(spaceId)
    local space = self.spaces[spaceId]
    if space == nil then
        space = Space.new(spaceId, nil, nil)
        self.spaces[spaceId] = space
    end
    return space
end

return State
