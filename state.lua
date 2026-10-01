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
    -- Names spaces used to carry: Chrome windows still wearing one of these
    -- are ours to rename, so a space rename or clear follows through.
    state.retiredNames = {}
    -- The date (as named) of the last daily window created, so closing it
    -- does not summon another one the same day.
    state.lastDailyWindow = nil
    state.version = 3
    return state
end

function State.fromTable(tableState)
    if tableState.version == 3 or tableState.version == 2 then
        local state = State.new()
        state.spaces = tableKeysToNumber(tableState.spaces)
        state.retiredNames = tableState.retiredNames or {}
        state.lastDailyWindow = tableState.lastDailyWindow
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
        retiredNames = self.retiredNames,
        lastDailyWindow = self.lastDailyWindow,
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
            local numberKey = tonumber(k)
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
    local space = self.spaces[spaceId]
    if space then
        self:_retire(space.name)
    end
    self.spaces[spaceId] = nil
end

-- Rename a space; nil clears. The previous custom name is retired.
function State:spaceRenamed(spaceId, name)
    local space = self:_getOrCreateSpace(spaceId)
    if space.name ~= name then
        self:_retire(space.name)
    end
    space.name = name
end

-- Every custom space name, current and retired, as a set.
function State:knownNames()
    local names = {}
    for _, space in pairs(self.spaces) do
        if space.name then
            names[space.name] = true
        end
    end
    for _, name in ipairs(self.retiredNames) do
        names[name] = true
    end
    return names
end

function State:_retire(name)
    if name == nil or name == "" then
        return
    end
    for _, existing in ipairs(self.retiredNames) do
        if existing == name then
            return
        end
    end
    table.insert(self.retiredNames, name)
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
