local Menu = {}

function Menu.generateChoices(currentSpaceName)
    local choices = {}

    -- Always show rename option for current space
    table.insert(choices, {
        action = "rename",
        text = "Rename: " .. currentSpaceName,
        subText = "Rename the current space and its Chrome windows"
    })

    -- Reset option to clear all custom names
    table.insert(choices, {
        action = "reset",
        text = "Reset",
        subText = "Clear all custom space names"
    })

    return choices
end

return Menu
