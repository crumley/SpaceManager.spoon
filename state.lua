-- A space's record. `id` is macOS's ManagedSpaceID, which is only good for
-- one login: after a reboot macOS numbers the spaces afresh, left to right,
-- so an id names whichever space now sits at that position. `uuid` is the
-- space's own identifier, kept across reboots, and is what a saved name is
-- matched back to its space by (see State:attach).
local Space = {}
function Space.new(spaceId, index, name, uuid)
    local space = {}
    setmetatable(space, {
        __index = Space
    })
    space.id = spaceId
    space.index = index
    space.name = name or nil
    space.uuid = uuid or nil
    return space
end

local State = {}

function State.new()
    local state = {}
    setmetatable(state, {
        __index = State
    })
    state.spaces = {}
    -- Named spaces not present when last attached (on a display that is
    -- unplugged, say), by uuid, so their names are there when they return.
    state.detached = {}
    state.version = 4
    return state
end

function State.fromTable(tableState)
    if tableState.version == 4 or tableState.version == 3 or tableState.version == 2 then
        local state = State.new()
        state.spaces = tableKeysToNumber(tableState.spaces or {})
        state.detached = tableState.detached or {}
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
        detached = self.detached,
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
    self.spaces[spaceId] = nil
end

-- Rename a space; nil clears.
function State:spaceRenamed(spaceId, name)
    self:_getOrCreateSpace(spaceId).name = name
end

-- Fit the records to the spaces there are now. current lists them in order,
-- { {id=, uuid=, index=}, ... }; uuid is nil (or "") where macOS gives none.
-- Each space takes the record saved for its uuid, wherever and under
-- whatever id it was saved. A space whose uuid has no record takes the one
-- under its id only if that record has no uuid of its own (saved before
-- uuids were kept, or by a space macOS gives none): one that has a uuid
-- belongs to another space, renumbered since. Every record is stamped with
-- its space's id, index and uuid; named records left over with a uuid are
-- kept detached for their space to come back to, and the rest are dropped.
function State:attach(current)
    local byUuid = {}
    for uuid, space in pairs(self.detached) do
        byUuid[uuid] = space
    end
    for _, space in pairs(self.spaces) do
        if space.uuid ~= nil and space.uuid ~= "" then
            byUuid[space.uuid] = space
        end
    end

    local spaces, taken = {}, {}
    for _, cur in ipairs(current) do
        local uuid = cur.uuid ~= "" and cur.uuid or nil
        local record = uuid and byUuid[uuid]
        if record == nil then
            local same = self.spaces[cur.id]
            if same ~= nil and (same.uuid == nil or same.uuid == "") and not taken[same] then
                record = same
            end
        end
        local name = record and not taken[record] and record.name or nil
        if record ~= nil then
            taken[record] = true
        end
        spaces[cur.id] = Space.new(cur.id, cur.index, name, uuid)
    end

    local detached = {}
    for uuid, space in pairs(byUuid) do
        if not taken[space] and space.name ~= nil then
            detached[uuid] = { name = space.name, uuid = uuid }
        end
    end

    self.spaces = spaces
    self.detached = detached
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
