local State = require("state")

-- https://lunarmodules.github.io/busted/

describe("State", function()
    it("names and clears spaces", function()
        local state = State.new()
        state:spaceAdded(101, 1)
        state:spaceRenamed(101, "Planning")
        assert.are.equal("Planning", state:getSpaceById(101).name)
        assert.are.equal(1, state:getSpaceByIndex(1).index)

        state:spaceRenamed(101, nil)
        assert.is_nil(state:getSpaceById(101).name)
    end)

    it("round-trips through a table with string keys", function()
        local state = State.new()
        state:spaceAdded(101, 1)
        state:spaceRenamed(101, "Planning")
        state.lastDailyWindow = "2026-09-30"

        local t = state:toTable()
        assert.are.equal(3, t.version)
        assert.are.equal("Planning", t.spaces["101"].name)

        local back = State.fromTable(t)
        assert.are.equal("Planning", back:getSpaceById(101).name)
        assert.are.equal(1, back:getSpaceById(101).index)
        assert.are.equal("2026-09-30", back.lastDailyWindow)
    end)

    it("loads saved state that still carries retired names", function()
        local back = State.fromTable({ version = 3, spaces = {}, retiredNames = { "Old" } })
        assert.are.same({}, back.spaces)
        assert.is_nil(back.retiredNames)
    end)

    it("migrates version 2 state", function()
        local back = State.fromTable({ version = 2, spaces = { ["101"] = { id = 101, index = 1, name = "Planning" } } })
        assert.are.equal("Planning", back:getSpaceById(101).name)
        assert.is_nil(back.lastDailyWindow)
        assert.are.equal(3, back.version)
    end)

    it("discards version 1 state and rejects unknown versions", function()
        assert.are.same({}, State.fromTable({ version = 1 }).spaces)
        assert.is_nil(State.fromTable({ version = 99 }))
    end)
end)
