local State = require("state")

-- https://lunarmodules.github.io/busted/

describe("State manipulation test", function ()
    it("should be easy to use", function ()
        local state = State.new()
        local activityId = state:activityStarted("myFunActivity")
        state:activityRenamed(activityId, "Foo")
        state:activityStopped(activityId)
    end)
end)
