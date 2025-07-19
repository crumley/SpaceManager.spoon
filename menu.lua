local hsspaces = require("hs.spaces")

local Menu = {}

function Menu.generateChoices(templates, currentActivityId, state, orderedTemplates)
    local choices = {}

    local activities = state:getActivities()

    for activityId, activity in pairs(activities) do
        if activity.spaceId == hsspaces.focusedSpace() then
            table.insert(choices, {
                action = "stop",
                activityId = activityId,
                text = "Stop: " .. activity.name,
                subText = "Stop the activity with ID " .. activityId .. " in the current space"
            })
        else
            table.insert(choices, {
                action = "jump",
                activityId = activityId,
                text = "Goto: " .. activity.name,
                subText = "Goto the activity with ID " .. activityId
            })
        end
    end

    -- Use ordered templates if provided, otherwise fall back to pairs
    if orderedTemplates then
        for _, activity in ipairs(orderedTemplates) do
            table.insert(choices, {
                action = "start",
                activityTemplateId = activity.id,
                text = "Start: " .. activity["text"],
                subText = activity["subText"]
            })
        end
    else
        for templateId, template in pairs(templates) do
            table.insert(choices, {
                action = "start",
                activityTemplateId = templateId,
                text = "Start: " .. template["text"],
                subText = template["subText"]
            })
        end
    end

    table.insert(choices, {
        action = "cleanup",
        text = "Clean up",
        subText = "Restore order in this world."
    })

    table.insert(choices, {
        action = "closeAll",
        text = "Close All",
        subText = "Stop all open activities and remove spaces."
    })

    table.insert(choices, {
        action = "reset",
        text = "Reset",
        subText = "Nuke state, start over"
    })

    return choices
end

function _generateChoices()
    local choices = {}

    local _spaceInfo = m:_spaceInfo()
    if _spaceInfo.spaceRecord ~= nil then
        for _, activityRecord in pairs(_spaceInfo.spaceRecord.activityRecords) do
            if not m.activityTemplates[activityRecord.activityId].permanent then
                table.insert(choices, {
                    action = "stop",
                    activityRecordId = activityRecord.id,
                    text = "Stop: " .. activityRecord.name,
                    subText = ""
                })
            end
        end
    end

    for _, activityRecord in pairs(m.state.activityRecords) do
        local activity = m.activityTemplates[activityRecord.activityId]
        local isCurrent = _spaceInfo ~= nil and _spaceInfo.primaryActivityRecord ~= nil and
                              _spaceInfo.primaryActivityRecord.id == activityRecord.id
        if not isCurrent then
            table.insert(choices, {
                action = "jump",
                activityRecordId = activityRecord.id,
                text = "Goto: " .. activityRecord.name,
                subText = activity["subText"]
            })
        end
    end

    for activityId, activity in pairs(m.activityTemplates) do
        local isStarted = m:isStarted(activityId)
        local isCurrent = _spaceInfo.activity ~= nil and _spaceInfo.activity.id == activityId
        if not isCurrent and not isStarted then
            table.insert(choices, {
                action = "start",
                activityId = activityId,
                text = "Start: " .. activity["text"],
                subText = activity["subText"]
            })
        end
    end

    table.insert(choices, {
        action = "closeAll",
        text = "Close All",
        subText = "Stop all open activities and remove spaces."
    })

    return choices
end

return Menu
