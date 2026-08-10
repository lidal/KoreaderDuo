--[[--
Prints Duo's menu exactly as KOReader would build it.

    luajit tools/duo-menu-dump.lua

Every label comes from the plugin's own menu table — including the ones
built at display time by `text_func` — so this is what the device shows,
not a description of it. Useful for checking wording without a Kindle to
hand, and for documentation.
--]]--

package.path = "./?.lua;./duo.koplugin/?.lua;" .. package.path

local Instance = require("spec/harness/instance")

local device = Instance.new{ name = "Kindle", page_count = 300 }
local plugin = device.plugin

local function labelOf(item)
    local text = item.text or (item.text_func and item.text_func()) or "?"
    local mark = ""
    if item.checked_func then
        mark = item.checked_func() and "  ✓" or "   "
    end
    local state = ""
    if item.enabled_func and not item.enabled_func() then
        state = "   (unavailable just now)"
    end
    return text .. mark .. state
end

local function dump(items, indent)
    for _, item in ipairs(items) do
        print(indent .. "· " .. labelOf(item))
        if item.sub_item_table then
            dump(item.sub_item_table, indent .. "    ")
        end
        if item.separator then
            print(indent .. "  " .. string.rep("─", 40))
        end
    end
end

local menu_items = {}
plugin:addToMainMenu(menu_items)

print("")
print("☰ → Network → " .. menu_items.duo.text)
print(string.rep("═", 52))
dump(menu_items.duo.sub_item_table, "")
print("")
