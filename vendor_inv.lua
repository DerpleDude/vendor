local mq                      = require('mq')
local ICONS                   = require('mq.Icons')

local vendor_inv              = {}

vendor_inv.sendSources        = {}
vendor_inv.items              = {}
vendor_inv.currentSendItemIdx = 0

local inventoryOffset         = 22

vendor_inv.genericSources     = {
    {
        name = "All Items",
        filter = function(item)
            return (not item.NoDrop() and not item.NoRent()) and (item.Value() or 0) > 0
        end,
    },
    {
        name = "All TS Items",
        filter = function(item)
            return item.Tradeskills() and item.Stackable()
        end,
    },
    {
        name = "All Collectible Items",
        filter = function(item)
            return item.Collectible() and item.Stackable()
        end,
    },
}

vendor_inv.customSources      = {}

--[[
    Sample Custom Source in config/vendor_sources.lua

return {
    {
        name = "Tradable Armor",
        filter = function(item)
            return item.Type() == "Armor"
        end,
    },
}
]]

---@param additionalSource table
---@return table
function vendor_inv:new(additionalSource)
    local newInv = setmetatable({}, self)
    self.__index = self
    newInv.customSources = additionalSource or {}
    return newInv
end

function vendor_inv:createContainerInventory()
    local newSendSources = {}
    for _, v in ipairs(self.genericSources) do table.insert(newSendSources, v) end
    for _, v in ipairs(self.customSources) do table.insert(newSendSources, v) end

    for i = 23, 34, 1 do
        local slot = mq.TLO.Me.Inventory(i)
        if slot.Container() and slot.Container() > 0 then
            local bagName = string.format("%s (%d)", slot.Name(), slot.ItemSlot() - inventoryOffset)
            table.insert(newSendSources, { name = bagName, slot = slot, })
        end
    end

    self.sendSources = newSendSources
end

-- Converts between ItemSlot and /itemnotify pack numbers
function vendor_inv.toPack(slot_number)
    return "pack" .. tostring(slot_number - 22)
end

-- Converts between ItemSlot2 and /itemnotify numbers
function vendor_inv.toBagSlot(slot_number)
    return slot_number + 1
end

function vendor_inv:resetState()
    self.currentSendItemIdx = 0
end

function vendor_inv:getNextItem()
    self.currentSendItemIdx = self.currentSendItemIdx + 1

    if self.currentSendItemIdx > #self.items then
        self.currentSendItemIdx = 0
        return nil
    end

    return self.items[self.currentSendItemIdx]
end

function vendor_inv:getFilteredItems(filterFn)
    local newItems = {}
    for i = 23, 34, 1 do
        local slot = mq.TLO.Me.Inventory(i)
        if slot.Container() and slot.Container() > 0 then
            for j = 1, (slot.Container()), 1 do
                if (slot.Item(j)() and not slot.Item(j).NoDrop() and not slot.Item(j).NoRent()) and
                    filterFn(slot.Item(j)) then
                    table.insert(newItems, { Item = slot.Item(j), })
                end
            end
        else
            if (slot() and not slot.NoDrop() and not slot.NoRent()) and
                filterFn(slot) then
                table.insert(newItems, { Item = slot, })
            end
        end
    end
    self.items = newItems
end

---@param index number
function vendor_inv:getItems(index)
    local data = self.sendSources[index]

    if not data then return end

    if data.filter ~= nil then
        self:getFilteredItems(data.filter)
    else
        local itemTable = {}
        local slot = data.slot
        for j = 1, (slot.Container()), 1 do
            if (slot.Item(j)() and not slot.Item(j).NoDrop() and not slot.Item(j).NoRent()) then
                table.insert(itemTable, { Item = slot.Item(j), })
                --printf("Adding item %s to send list", slot.Item(j).Name())
            end
        end
        self.items = itemTable
    end

    self.currentSendItemIdx = 0
end

return vendor_inv
