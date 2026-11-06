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

        local t = state:toTable()
        assert.are.equal(4, t.version)
        assert.are.equal("Planning", t.spaces["101"].name)

        local back = State.fromTable(t)
        assert.are.equal("Planning", back:getSpaceById(101).name)
        assert.are.equal(1, back:getSpaceById(101).index)
    end)

    it("loads saved state that still carries retired fields", function()
        local back = State.fromTable({ version = 3, spaces = {}, retiredNames = { "Old" }, lastDailyWindow = "2026-09-30" })
        assert.are.same({}, back.spaces)
        assert.is_nil(back.retiredNames)
        assert.is_nil(back.lastDailyWindow)
    end)

    it("migrates version 2 state", function()
        local back = State.fromTable({ version = 2, spaces = { ["101"] = { id = 101, index = 1, name = "Planning" } } })
        assert.are.equal("Planning", back:getSpaceById(101).name)
        assert.are.equal(4, back.version)
    end)

    it("discards version 1 state and rejects unknown versions", function()
        assert.are.same({}, State.fromTable({ version = 1 }).spaces)
        assert.is_nil(State.fromTable({ version = 99 }))
    end)

    it("migrates version 3 state, keeping names by id and stamping uuids", function()
        local back = State.fromTable({ version = 3, spaces = {
            ["3"] = { id = 3, index = 1 },
            ["4"] = { id = 4, index = 9, name = "ops" },
        } })
        back:attach({ { id = 3, uuid = "U3", index = 1 }, { id = 4, uuid = "U4", index = 2 } })
        assert.are.equal("ops", back:getSpaceById(4).name)
        assert.are.equal("U4", back:getSpaceById(4).uuid)
        assert.are.equal(2, back:getSpaceById(4).index)
        assert.are.equal(4, back:toTable().version)
    end)

    it("keeps names on their spaces when a reboot renumbers the ids", function()
        -- Before the reboot: SFR-on-QE (id 13) is 4th, ops (id 6) 2nd.
        local state = State.new()
        state:attach({
            { id = 3, uuid = "A", index = 1 },
            { id = 6, uuid = "B", index = 2 },
            { id = 2086, uuid = "C", index = 3 },
            { id = 13, uuid = "D", index = 4 },
        })
        state:spaceRenamed(6, "ops")
        state:spaceRenamed(13, "SFR-on-QE")
        local saved = state:toTable()

        -- After it: the same spaces, the same order, numbered 3, 4, 5, 6.
        local back = State.fromTable(saved)
        back:attach({
            { id = 3, uuid = "A", index = 1 },
            { id = 4, uuid = "B", index = 2 },
            { id = 5, uuid = "C", index = 3 },
            { id = 6, uuid = "D", index = 4 },
        })
        assert.are.equal("ops", back:getSpaceById(4).name)
        assert.are.equal("SFR-on-QE", back:getSpaceById(6).name)
        assert.is_nil(back:getSpaceById(5).name)
        assert.is_nil(back:getSpaceById(3).name)
        assert.is_nil(back:getSpaceById(13))
        assert.are.equal(6, back:getSpaceByIndex(4).id)
    end)

    it("never gives a space the name saved under its id for another uuid", function()
        local back = State.fromTable({ version = 4, spaces = {
            ["5"] = { id = 5, index = 1, uuid = "OLD", name = "stale" },
        } })
        back:attach({ { id = 5, uuid = "NEW", index = 1 } })
        assert.is_nil(back:getSpaceById(5).name)
        assert.are.equal("NEW", back:getSpaceById(5).uuid)
    end)

    it("keeps a missing named space detached until it comes back", function()
        local state = State.new()
        state:attach({ { id = 3, uuid = "A", index = 1 }, { id = 9, uuid = "E", index = 1 } })
        state:spaceRenamed(9, "external")
        state:attach({ { id = 3, uuid = "A", index = 1 } })
        assert.is_nil(state:getSpaceById(9))

        local back = State.fromTable(state:toTable())
        back:attach({ { id = 3, uuid = "A", index = 1 }, { id = 12, uuid = "E", index = 1 } })
        assert.are.equal("external", back:getSpaceById(12).name)
        assert.are.same({}, back.detached)
    end)

    it("drops records for spaces gone that carry no name or no uuid", function()
        local back = State.fromTable({ version = 3, spaces = {
            ["77"] = { id = 77, name = "gone" },
            ["78"] = { id = 78, uuid = "G" },
        } })
        back:attach({ { id = 3, uuid = "A", index = 1 } })
        assert.is_nil(back:getSpaceById(77))
        assert.are.same({}, back.detached)
        local ids = {}
        for id in pairs(back:getSpaces()) do
            table.insert(ids, id)
        end
        assert.are.same({ 3 }, ids)
    end)

    it("matches a space macOS gives no uuid by its id", function()
        local state = State.new()
        state:attach({ { id = 1, uuid = "", index = 1 } })
        state:spaceRenamed(1, "Main")
        local back = State.fromTable(state:toTable())
        back:attach({ { id = 1, uuid = "", index = 1 } })
        assert.are.equal("Main", back:getSpaceById(1).name)
        assert.is_nil(back:getSpaceById(1).uuid)
    end)
end)
