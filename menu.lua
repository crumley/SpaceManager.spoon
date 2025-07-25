local hsspaces = require("hs.spaces")
local hsscreen = require("hs.screen")
local hsfnutils = require("hs.fnutils")

local Menu = {}

function Menu.generateChoices(templates, currentActivityId, state, orderedTemplates)
    local choices = {}

    -- Get all spaces to calculate space indices
    local screenId = hsscreen.primaryScreen():getUUID()
    local allSpaces = hsspaces.allSpaces()[screenId]

    local activities = state:getActivities()
    local gotoItems = {}
    local hasCurrentSpaceActivity = false

    -- First pass: collect current space activities and goto activities
    for activityId, activity in pairs(activities) do
        if activity.spaceId == hsspaces.focusedSpace() then
            hasCurrentSpaceActivity = true

            -- Get template to check if activity is permanent
            local template = templates[activity.typeId]

            -- Only add stop option for non-permanent activities
            if template and not template.permanent then
                table.insert(choices, {
                    action = "stop",
                    activityId = activityId,
                    text = "Stop: " .. activity.name,
                    subText = "Stop the activity with ID " .. activityId .. " in the current space"
                })
            end

            -- Add rename option for non-singleton, non-permanent activities
            if template and not template.singleton and not template.permanent then
                table.insert(choices, {
                    action = "rename",
                    activityId = activityId,
                    text = "Rename: " .. activity.name,
                    subText = "Rename the current activity"
                })
            end
        else
            -- Calculate space index for the activity
            local spaceIndex = hsfnutils.indexOf(allSpaces, activity.spaceId)
            local spaceInfo = spaceIndex and (" (" .. spaceIndex .. ")") or ""

            table.insert(gotoItems, {
                action = "jump",
                activityId = activityId,
                text = "Goto: " .. activity.name .. spaceInfo,
                subText = "Goto the activity with ID " .. activityId,
                spaceIndex = spaceIndex or 9999 -- Put items without space index at the end
            })
        end
    end

    -- Sort goto items by space index
    table.sort(gotoItems, function(a, b)
        return a.spaceIndex < b.spaceIndex
    end)

    -- Add sorted goto items to choices
    for _, item in ipairs(gotoItems) do
        -- Remove the spaceIndex field as it's only used for sorting
        item.spaceIndex = nil
        table.insert(choices, item)
    end

    -- If current space is unmanaged (no activity assigned), offer assignment options
    if not hasCurrentSpaceActivity then
        -- Use ordered templates if provided, otherwise fall back to pairs
        if orderedTemplates then
            for _, activity in ipairs(orderedTemplates) do
                -- Only offer assignment for non-singleton, non-permanent activities
                if not activity.singleton and not activity.permanent then
                    -- For non-singleton activities, always allow assignment (multiple instances allowed)
                    table.insert(choices, {
                        action = "assign",
                        activityTemplateId = activity.text,
                        text = "Assign: " .. activity["text"],
                        subText = "Assign " .. activity["text"] .. " to this unmanaged space"
                    })
                end
            end
        else
            for templateId, template in pairs(templates) do
                -- Only offer assignment for non-singleton, non-permanent activities
                if not template.singleton and not template.permanent then
                    -- For non-singleton activities, always allow assignment (multiple instances allowed)
                    table.insert(choices, {
                        action = "assign",
                        activityTemplateId = template.text,
                        text = "Assign: " .. template["text"],
                        subText = "Assign " .. template["text"] .. " to this unmanaged space"
                    })
                end
            end
        end
    end

    -- Use ordered templates if provided, otherwise fall back to pairs
    if orderedTemplates then
        for _, activity in ipairs(orderedTemplates) do
            -- Check if this is a singleton activity that's already started
            local isStarted = false
            if activity.singleton then
                local existingActivities = state:getActivitiesByTemplateId(activity.text)
                isStarted = #existingActivities > 0
            end

            -- Only show start option if it's not a singleton or if it's not already started
            if not isStarted then
                table.insert(choices, {
                    action = "start",
                    activityTemplateId = activity.text,
                    text = "Start: " .. activity["text"],
                    subText = activity["subText"]
                })
            end
        end
    else
        for templateId, template in pairs(templates) do
            -- Check if this is a singleton activity that's already started
            local isStarted = false
            if template.singleton then
                local existingActivities = state:getActivitiesByTemplateId(template.text)
                isStarted = #existingActivities > 0
            end

            -- Only show start option if it's not a singleton or if it's not already started
            if not isStarted then
                table.insert(choices, {
                    action = "start",
                    activityTemplateId = template.text,
                    text = "Start: " .. template["text"],
                    subText = template["subText"]
                })
            end
        end
    end

    -- Cleanup currently doesn't do much due to hs apis not working...
    -- table.insert(choices, {
    --     action = "cleanup",
    --     text = "Clean up",
    --     subText = "Restore order in this world."
    -- })

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
