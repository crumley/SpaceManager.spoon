local Menu = {}

function Menu.generateChoices(currentSpaceName, hasCustomName, allSpaces, currentSpaceId)
    local choices = {}

    -- Always show rename option for current space
    table.insert(choices, {
        action = "rename",
        text = "Rename: " .. currentSpaceName,
        subText = "Rename the current space and its Chrome windows"
    })

    -- Clear Name option - only shown if current space has a custom name
    if hasCustomName then
        table.insert(choices, {
            action = "clearName",
            text = "Clear Name",
            subText = "Remove custom name from current space"
        })
    end

    -- Reset option to clear all custom names
    table.insert(choices, {
        action = "reset",
        text = "Reset",
        subText = "Clear all custom space names"
    })

    -- Go to options for all spaces (excluding current space)
    for _, space in ipairs(allSpaces) do
        if space.spaceId ~= currentSpaceId then
            local displayName
            if space.hasCustomName then
                displayName = space.name
            elseif space.hasConfiguredName then
                displayName = space.defaultName
            else
                displayName = space.defaultName .. " (unnamed)"
            end
            table.insert(choices, {
                action = "gotoSpace",
                text = "Go to: [" .. space.index .. "] " .. displayName,
                subText = "Switch to space " .. space.index,
                spaceId = space.spaceId
            })
        end
    end

    return choices
end

return Menu
