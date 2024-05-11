local State = require("state")

-- https://lunarmodules.github.io/busted/

describe("State", function ()
    it("should use activity type as name for new activity", function ()
        local state = State.new()

        local typeId = "myFunActivity"
        local activityId = state:activityStarted(typeId)

        assert(activityId == state:getActivityById(activityId).id)
        assert(typeId == state:getActivityById(activityId).name)
    end)

    it("should return nil after activity stops", function ()
        local state = State.new()

        local activityId = state:activityStarted("myFunActivity")
        assert(activityId == state:getActivityById(activityId).id)

        state:activityStopped(activityId)
        assert(state:getActivityById(activityId) == nil)
    end)

    it("should assign new unique ids", function ()
        local state = State.new()

        local a1 = state:activityStarted("a1")
        local a2 = state:activityStarted("a2")
        local a3 = state:activityStarted("a3")

        assert(a1 ~= a2 ~= a3)
        assert(a1 == state:getActivityById(a1).id)
        assert(a2 == state:getActivityById(a2).id)
        assert(a3 == state:getActivityById(a3).id)

        state:activityRenamed(a2, "Foo")
        assert("Foo" ~= state:getActivityById(a1).name)
        assert("Foo" == state:getActivityById(a2).name)
        assert("Foo" ~= state:getActivityById(a3).name)

        local a4 = state:activityStarted("a4")
        assert(a1 ~= a2 ~= a3 ~= a4)

        state:activityStopped(a2)
        assert(state:getActivityById(a1) ~= nil)
        assert(state:getActivityById(a2) == nil)
        assert(state:getActivityById(a3) ~= nil)
        assert(state:getActivityById(a4) ~= nil)
    end)

    it("should update activity spaceId after space movement", function ()
        local state = State.new()

        local a1 = state:activityStarted("a1")
        local a2 = state:activityStarted("a1")

        state:activityMoved(a1, "s1")
        assert("s1" == state:getActivityById(a1).spaceId)

        local activities = state:getActivitiesBySpaceId("s1")
        assert(#activities == 1)
        assert(activities[1].id == a1)
    end)

    it("should handle multiple activities in one space", function ()
        local state = State.new()

        local a1 = state:activityStarted("a1")
        local a2 = state:activityStarted("a1")

        state:activityMoved(a1, "s1")
        assert("s1" == state:getActivityById(a1).spaceId)

        local activities = state:getActivitiesBySpaceId("s1")
        assert(#activities == 1)

        state:activityMoved(a2, "s1")
        activities = state:getActivitiesBySpaceId("s1")
        assert(#activities == 2)
    end)

    it("should remove activity from space after it has moved", function ()
        local state = State.new()

        local a1 = state:activityStarted("a1")
        local a2 = state:activityStarted("a2")

        state:activityMoved(a1, "s1")
        state:activityMoved(a2, "s1")

        assert.are.equal(#state:getActivitiesBySpaceId("s1"), 2)

        state:activityMoved(a2, nil)
        assert(#state:getActivitiesBySpaceId("s1") == 1)
    end)

    it("should remove activity from space after it has moved", function ()
        local state = State.new()

        local a1 = state:activityStarted("a1")
        local a2 = state:activityStarted("a2")

        state:windowMoved("w1", a1)
        state:windowMoved("w2", a1)

        assert.are.same(
            { w1 = true, w2 = true },
            state:getActivityById(a1).windowIds
        )

        state:windowMoved("w2", a2)

        assert.are.same(
            { w1 = true },
            state:getActivityById(a1).windowIds
        )

        assert.are.same(
            { w2 = true },
            state:getActivityById(a2).windowIds
        )
    end)

    it("should roundtrip to table and back", function ()
        local state1 = State.new()

        local a1 = state1:activityStarted("a1")
        local a12 = state1:activityStarted("a1")
        local a2 = state1:activityStarted("a2")

        state1:activityMoved( a1, 2 )
        state1:windowMoved( "w1", a1 )
        state1:windowMoved( "w2", a1 )
        state1:windowMoved( "w3", a12 )
        state1:windowMoved( "w4", a2 )

        local t = state1:toTable()
        local state2 = State.fromTable(t) 

        assert.are.same(
            state1,
            state2
        ) 
    end)
end)
