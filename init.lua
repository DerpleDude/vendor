local mq                  = require('mq')
local ImGui               = require('ImGui')
local Icons               = require('mq.Icons')

local vendorInv           = require('vendor_inv')
local actors              = require 'actors'
local animItems           = mq.FindTextureAnimation("A_DragItem")

local openGUI             = true
local shouldDrawGUI       = false

local terminate           = false

local sourceIndex         = 1
local sellAllJunk         = false
local vendItem            = nil
local showHidden          = false
local lastInventoryScan   = 0
local collapsed           = false

-- Track platinum received during a Sell Junk run
local trackPlatDuringSell = false
local totalPlatThisSell   = 0

local settings_file       = mq.configDir .. "/vendor.lua"
local custom_sources      = mq.configDir .. "/vendor_sources.lua"

local settings            = {}

local Output              = function(msg, ...)
    local formatted = msg
    if ... then
        formatted = string.format(msg, ...)
    end
    printf('\aw[' .. mq.TLO.Time() .. '] [\aoDerple\'s Vendor Helper\aw] ::\a-t %s', formatted)
end

function Tooltip(desc)
    ImGui.SameLine()
    if ImGui.IsItemHovered() then
        ImGui.BeginTooltip()
        ImGui.PushTextWrapPos(ImGui.GetFontSize() * 25.0)
        ImGui.Text(desc)
        ImGui.PopTextWrapPos()
        ImGui.EndTooltip()
    end
end

local function SaveSettings()
    mq.pickle(settings_file, settings)
    actors.send({ from = mq.TLO.Me.DisplayName(), script = "DerpleVend", event = "SaveSettings", })
end

local function LoadSettings()
    local config, err = loadfile(settings_file)
    if err or not config then
        Output("\ayNo valid configuration found. Creating a new one: %s", settings_file)
        settings = {}
        SaveSettings()
    else
        settings = config()
    end

    settings.Junk = settings.Junk or {}
    settings.Hide = settings.Hide or {}

    if not settings.Colors then
        settings.Colors = { Green = { R = 50, G = 205, B = 50, A = 255, }, Red = { R = 205, G = 50, B = 50, A = 255, }, }
        SaveSettings()
    end

    local vendorSources = {}
    local config, err = loadfile(custom_sources)
    if not err and config then
        vendorSources = config()
    end

    vendorInv = vendorInv:new(vendorSources)
end

-- Capture coin received messages to total platinum during Sell Junk
mq.event('DerpleVend_PlatGain',
    '#*#You receive #1# platinum#*# from#*#',
    function(_, plat)
        if not trackPlatDuringSell then return end
        local cleaned = (plat or '0'):gsub(',', '')
        local amt = tonumber(cleaned) or 0
        totalPlatThisSell = totalPlatThisSell + amt
    end)
local function navToMerchant(merchant)
    if not mq.TLO.Window("MerchantWnd").Open() then
        local merchant = mq.TLO.NearestSpawn("merchant radius 1000") -- Adjust radius as needed; "merchant" searches for open merchants

        if not merchant() then
            Output("\arNo nearby merchant found!")
            return false
        end

        Output("\ayNavigating to nearest merchant: \at%s \ay(distance: %.0f)", merchant.CleanName(), merchant.Distance())

        mq.cmdf("/nav id %d", merchant.ID())
        mq.delay(1000, function() return mq.TLO.Navigation.Active() end)

        local timeout = mq.gettime() + 60000 -- 60 second timeout
        while mq.TLO.Navigation.Active() and merchant.Distance() > 30 do
            mq.delay(250)
            if mq.gettime() > timeout then
                Output("\arNavigation to merchant timed out!")
                mq.cmd("/nav stop")
                return false
            end
        end

        mq.cmdf("/mqtarget id %d", merchant.ID())
        mq.delay("5s", function() return mq.TLO.Target.ID() == merchant.ID() end)

        timeout = mq.gettime() + 10000 -- 10 second timeout
        while not mq.TLO.Window("MerchantWnd").Open() do
            mq.cmd("/click right target")
            mq.delay(100)
            if mq.gettime() > timeout then
                Output("\arFailed to open merchant window after 10 seconds!")
                return false
            end
        end

        Output("\agMerchant window opened! Starting junk sell...")
    else
        Output("\agMerchant window already open. Starting junk sell...")
    end

    return true
end

local function autoSellJunk()
    if navToMerchant() then
        sellAllJunk = true
        trackPlatDuringSell = true
        totalPlatThisSell = 0
    end
end

local function sellItem(item)
    if not mq.TLO.Window("MerchantWnd").Open() then
        return
    end

    local tabPage = mq.TLO.Window("MerchantWnd").Child("MW_MerchantSubWindows")
    while tabPage.CurrentTab.Name() ~= "MW_PurchasePage" do
        tabPage.SetCurrentTab(1)
        mq.delay(500)
    end

    if item and item.Item then
        Output("\aySelling item: \at%s\ay in Slot\aw(\am%d\aw)\ay, Slot2\aw(\am%d\aw)", item.Item.Name(), item.Item.ItemSlot(), item.Item.ItemSlot2())

        local retries = 15
        repeat
            mq.cmd("/itemnotify in " ..
                vendorInv.toPack(item.Item.ItemSlot()) ..
                " " .. vendorInv.toBagSlot(item["Item"].ItemSlot2()) .. " leftmouseup")
            mq.delay(500)
            retries = retries - 1
            if retries < 0 then return end
            if not openGUI then return end
        until mq.TLO.Window("MerchantWnd").Child("MW_Sell_Button")() == "TRUE" and mq.TLO.Window("MerchantWnd").Child("MW_Sell_Button").Enabled()

        retries = 15
        repeat
            mq.delay(500)
            if mq.TLO.Window("MerchantWnd").Child("MW_Sell_Button").Enabled() then
                Output("Pushing sell")
                mq.cmd("/shift /notify MerchantWnd MW_Sell_Button leftmouseup")
            end
            retries = retries - 1
            if retries < 0 then return end
            if not openGUI then return end
        until mq.TLO.Window("MerchantWnd").Child("MW_Sell_Button")() ~= "TRUE"

        Output("\agDone selling...")
    else
        vendorInv:resetState()
    end
end

-- default false
local function IsHidden(itemName)
    local itemStartString = itemName:sub(1, 1)
    return settings.Hide[itemStartString] and settings.Hide[itemStartString][itemName] == true
end

-- default false
local function IsJunk(itemName)
    local itemStartString = itemName:sub(1, 1)
    return settings.Junk[itemStartString] and settings.Junk[itemStartString][itemName] == true
end

local function renderItems()
    if ImGui.BeginTable("BagItemList", 5, bit32.bor(ImGuiTableFlags.Resizable, ImGuiTableFlags.Borders)) then
        ImGui.TableSetupColumn('Icon', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), 20.0)
        ImGui.TableSetupColumn('Item',
            bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.PreferSortDescending,
                ImGuiTableColumnFlags.WidthStretch),
            150.0)
        ImGui.TableSetupColumn('Junk', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), 20.0)
        ImGui.TableSetupColumn('Sell', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), 20.0)
        ImGui.TableSetupColumn('Hide', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), 20.0)
        ImGui.TableHeadersRow()

        for idx, item in ipairs(vendorInv.items) do
            if item and item.Item() and item.Item.Name():len() > 0 then
                local itemStartString = (item.Item.Name() or ""):sub(1, 1)
                settings.Junk[itemStartString] = settings.Junk[itemStartString] or {}
                settings.Hide[itemStartString] = settings.Hide[itemStartString] or {}

                if not IsHidden(item.Item.Name()) or showHidden then
                    ImGui.PushID("#_itm_" .. tostring(idx))
                    local currentItem = item.Item
                    ImGui.TableNextColumn()
                    animItems:SetTextureCell((tonumber(currentItem.Icon()) or 500) - 500)
                    ImGui.DrawTextureAnimation(animItems, 20, 20)
                    ImGui.TableNextColumn()
                    if ImGui.Selectable(currentItem.Name(), false, 0) then
                        currentItem.Inspect()
                    end
                    ImGui.TableNextColumn()
                    if IsJunk(item.Item.Name()) then
                        ImGui.PushStyleColor(ImGuiCol.Text, IM_COL32(settings.Colors.Green.R, settings.Colors.Green.G, settings.Colors.Green.B, settings.Colors.Green.A))
                    else
                        ImGui.PushStyleColor(ImGuiCol.Text, IM_COL32(settings.Colors.Red.R, settings.Colors.Red.G, settings.Colors.Red.B, settings.Colors.Red.A))
                    end
                    ImGui.PushID("#_btn_jnk" .. tostring(idx))
                    if ImGui.Selectable(Icons.FA_TRASH_O) then
                        settings.Junk[itemStartString][item.Item.Name()] = not IsJunk(item.Item.Name())
                        Output("\awToggled %s\aw for item: \at%s", IsJunk(item.Item.Name()) and "\arJunk" or "\agNot-Junk", item.Item.Name())
                        SaveSettings()
                    end
                    ImGui.PopID()
                    ImGui.PopStyleColor()
                    ImGui.TableNextColumn()
                    if ImGui.Selectable(Icons.MD_MONETIZATION_ON) then
                        vendItem = item
                    end
                    ImGui.TableNextColumn()
                    if not IsHidden(item.Item.Name()) then
                        ImGui.PushStyleColor(ImGuiCol.Text, IM_COL32(settings.Colors.Green.R, settings.Colors.Green.G, settings.Colors.Green.B, settings.Colors.Green.A))
                    else
                        ImGui.PushStyleColor(ImGuiCol.Text, IM_COL32(settings.Colors.Red.R, settings.Colors.Red.G, settings.Colors.Red.B, settings.Colors.Red.A))
                    end
                    ImGui.PushID("#_btn_hide" .. tostring(idx))
                    if ImGui.Selectable(IsHidden(item.Item.Name()) and Icons.FA_EYE or Icons.FA_EYE_SLASH) then
                        settings.Hide[itemStartString][item.Item.Name()] = not IsHidden(item.Item.Name())
                        Output("\awToggled %s\aw for item: \at%s", IsHidden(item.Item.Name()) and "\arHide" or "\agShow", item.Item.Name())
                        SaveSettings()
                    end
                    ImGui.PopID()
                    ImGui.PopStyleColor()
                    ImGui.PopID()
                end
            end
        end

        ImGui.EndTable()
    end
end
local buyItemsSorted        = {}
local buyItemsDirty         = true
local buyFilter             = ""
local merchantSnapshotPending = false

local function matchesFilter(name, filter)
    if filter == "" then return true end
    local lower = name:lower()
    for term in filter:lower():gmatch("[^|]+") do
        if term ~= "" and lower:find(term, 1, true) then return true end
    end
    return false
end

local buyColumns = {
    {
        name = 'Icon',
        flags = bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed),
        width = 22.0,
        sort = nil,
        render = function(item)
            animItems:SetTextureCell((tonumber(item.IconId) or 500) - 500); ImGui.DrawTextureAnimation(animItems, 20, 20)
        end,
    },
    {
        name = 'Item',
        flags = bit32.bor(ImGuiTableColumnFlags.DefaultSort, ImGuiTableColumnFlags.WidthStretch),
        width = 150.0,
        sort = function(a, b) return (a.name or ""), (b.name or "") end,
        render = function(item)
            if ImGui.Selectable(item.name or "", false, ImGuiSelectableFlags.SpanAllColumns) then
                mq.TLO.Merchant.SelectItem("=" .. (item.name or ""))
            end
        end,
    },
    {
        name = 'Price',
        flags = bit32.bor(ImGuiTableColumnFlags.WidthFixed),
        width = 65.0,
        sort = function(a, b) return a.price, b.price end,
        render = function(item) ImGui.Text(tostring(item.price)) end,
    },
    {
        name = 'Qty',
        flags = bit32.bor(ImGuiTableColumnFlags.WidthFixed),
        width = 40.0,
        sort = function(a, b) return a.qty, b.qty end,
        render = function(item) ImGui.Text(item.qty == -1 and "-" or tostring(item.qty)) end,
    },
    {
        name = 'Buy',
        flags = bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed),
        width = 22.0,
        sort = nil,
        render = function(item)
            if ImGui.Selectable(Icons.FA_CART_PLUS) then
                mq.TLO.Merchant.SelectItem("=" .. (item.name or ""))
                mq.TLO.Merchant.Buy(1)
            end
        end,
    },
}

local function snapshotMerchantItems()
    buyItemsSorted = {}
    local count = mq.TLO.Merchant.Items() or 0
    for i = 1, count do
        local item = mq.TLO.Merchant.Item(i)
        table.insert(buyItemsSorted, {
            index  = i,
            name   = item.Name() or "",
            price  = (item.BuyPrice() or 0) / 1000,
            IconId = item.Icon() or 500,
            qty    = item.MerchQuantity() and math.floor(item.MerchQuantity()) or -1,
            canUse = item.CanUse() == true,
        })
    end
    buyItemsDirty = true
end

local function renderBuyItems()
    local tableFlags = bit32.bor(ImGuiTableFlags.Sortable, ImGuiTableFlags.Resizable,
        ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.ScrollY)

    if ImGui.BeginTable("MerchantItemList", #buyColumns, tableFlags) then
        for id, col in ipairs(buyColumns) do
            ImGui.TableSetupColumn(col.name, col.flags, col.width, id - 1)
        end
        ImGui.TableSetupScrollFreeze(0, 1)
        ImGui.TableHeadersRow()

        local sort_specs = ImGui.TableGetSortSpecs()
        if sort_specs and (sort_specs.SpecsDirty or buyItemsDirty) then
            local spec = sort_specs:Specs(1)
            local col = buyColumns[(spec and spec.ColumnIndex or 1) + 1]
            if col and col.sort then
                table.sort(buyItemsSorted, function(a, b)
                    local av, bv = col.sort(a, b)
                    if spec.SortDirection == ImGuiSortDirection.Ascending then
                        return av < bv
                    else
                        return av > bv
                    end
                end)
            end
            sort_specs.SpecsDirty = false
            buyItemsDirty = false
        end

        local usableOnly = mq.TLO.Window("MerchantWnd").Child("MW_UsableButton").Checked()
        for _, item in ipairs(buyItemsSorted) do
            if matchesFilter(item.name, buyFilter) and (not usableOnly or item.canUse) then
                ImGui.PushID("##buy_" .. tostring(item.index))
                for _, col in ipairs(buyColumns) do
                    ImGui.TableNextColumn()
                    col.render(item)
                end
                ImGui.PopID()
            end
        end

        ImGui.EndTable()
    end
end

-- Dumpster Dive

local equippedSlots = {
    { id = 0, name = "Charm", }, { id = 1, name = "Ear1", },
    { id = 2, name = "Head", }, { id = 3, name = "Face", },
    { id = 4, name = "Ear2", }, { id = 5, name = "Neck", },
    { id = 6, name = "Shoulders", }, { id = 7, name = "Arms", },
    { id = 8,  name = "Back", }, { id = 9, name = "Wrist1", },
    { id = 10, name = "Wrist2", }, { id = 11, name = "Range", },
    { id = 12, name = "Hands", }, { id = 13, name = "Primary", },
    { id = 14, name = "Secondary", }, { id = 15, name = "Ring1", },
    { id = 16, name = "Ring2", }, { id = 17, name = "Chest", },
    { id = 18, name = "Legs", }, { id = 19, name = "Feet", },
    { id = 20, name = "Waist", }, { id = 21, name = "PowerSource", },
    { id = 22, name = "Ammo", },
}

local diveResults   = {}
local diveDirty     = true
local diveColumns   = {
    {
        name = 'Slot',
        flags = bit32.bor(ImGuiTableColumnFlags.DefaultSort, ImGuiTableColumnFlags.WidthFixed),
        width = 75.0,
        sort = function(a, b) return a.slotName, b.slotName end,
        render = function(r) ImGui.Text(r.slotName) end,
    },
    {
        name = 'Equipped',
        flags = bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthStretch),
        width = 120.0,
        sort = nil,
        render = function(r)
            if ImGui.Selectable("##eq_" .. r.slotName .. r.upgradeName, false) then
                local eqItem = mq.TLO.Me.Inventory(r.slotId)
                if eqItem() then eqItem.Inspect() end
            end
            ImGui.SameLine()
            ImGui.Text(r.equippedName)
        end,
    },
    {
        name = 'Upgrade',
        flags = bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthStretch),
        width = 120.0,
        sort = nil,
        render = function(r)
            if ImGui.Selectable("##up_" .. r.slotName .. r.upgradeName, false) then
                mq.TLO.Merchant.Item(r.merchantIndex).Inspect()
            end
            ImGui.SameLine()
            ImGui.Text(r.upgradeName)
        end,
    },
    {
        name = 'AC',
        flags = bit32.bor(ImGuiTableColumnFlags.WidthFixed),
        width = 40.0,
        sort = function(a, b) return a.deltaAC, b.deltaAC end,
        render = function(r) ImGui.Text(r.deltaAC > 0 and ("+" .. r.deltaAC) or tostring(r.deltaAC)) end,
    },
    {
        name = 'HP',
        flags = bit32.bor(ImGuiTableColumnFlags.WidthFixed),
        width = 45.0,
        sort = function(a, b) return a.deltaHP, b.deltaHP end,
        render = function(r) ImGui.Text(r.deltaHP > 0 and ("+" .. r.deltaHP) or tostring(r.deltaHP)) end,
    },
    {
        name = 'Mana',
        flags = bit32.bor(ImGuiTableColumnFlags.WidthFixed),
        width = 48.0,
        sort = function(a, b) return a.deltaMana, b.deltaMana end,
        render = function(r) ImGui.Text(r.deltaMana > 0 and ("+" .. r.deltaMana) or tostring(r.deltaMana)) end,
    },
    {
        name = 'Price',
        flags = bit32.bor(ImGuiTableColumnFlags.WidthFixed),
        width = 55.0,
        sort = function(a, b) return a.price, b.price end,
        render = function(r)
            local canAfford = (mq.TLO.Me.Platinum() or 0) >= r.price
            local c = settings.Colors[canAfford and "Green" or "Red"]
            ImGui.PushStyleColor(ImGuiCol.Text, IM_COL32(c.R, c.G, c.B, c.A))
            ImGui.Text(tostring(r.price) .. "p")
            ImGui.PopStyleColor()
        end,
    },
    {
        name = 'Buy',
        flags = bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed),
        width = 22.0,
        sort = nil,
        render = function(r)
            if ImGui.Selectable(Icons.FA_CART_PLUS .. "##dive_" .. r.slotName .. r.upgradeName) then
                mq.TLO.Merchant.SelectItem("=" .. r.upgradeName)
                mq.TLO.Merchant.Buy(1)
            end
        end,
    },
}

local function snapshotDiveResults()
    diveResults = {}
    local itemCount = mq.TLO.Merchant.Items() or 0
    if itemCount == 0 then
        diveDirty = true; return
    end

    -- Build equipped stat map: slotId -> { name, ac, hp, mana }
    local equipped = {}
    for _, slot in ipairs(equippedSlots) do
        local item = mq.TLO.Me.Inventory(slot.id)
        if item() then
            equipped[slot.id] = {
                name = item.Name() or "",
                ac   = item.AC() or 0,
                hp   = item.HP() or 0,
                mana = item.Mana() or 0,
            }
        else
            equipped[slot.id] = { name = "(empty)", ac = 0, hp = 0, mana = 0, }
        end
    end

    local usableOnly = mq.TLO.Window("MerchantWnd").Child("MW_UsableButton").Checked()

    for i = 1, itemCount do
        local mitem = mq.TLO.Merchant.Item(i)
        local mAC   = mitem.AC() or 0
        local mHP   = mitem.HP() or 0
        local mMana = mitem.Mana() or 0
        if mAC == 0 and mHP == 0 and mMana == 0 then goto continue end
        if usableOnly and mitem.CanUse() ~= true then goto continue end

        local wornCount = mitem.WornSlots() or 0
        for w = 1, wornCount do
            local wornSlot = mitem.WornSlot(w)
            if not wornSlot() then goto nextslot end
            local slotName = wornSlot.Name() or ""

            -- find matching equipped slot by name
            for _, slot in ipairs(equippedSlots) do
                if slot.name:lower() == slotName:lower() then
                    local eq    = equipped[slot.id]
                    local dAC   = mAC - eq.ac
                    local dHP   = mHP - eq.hp
                    local dMana = mMana - eq.mana
                    if dAC > 0 or dHP > 0 or dMana > 0 then
                        table.insert(diveResults, {
                            slotId        = slot.id,
                            slotName      = slot.name,
                            equippedName  = eq.name,
                            upgradeName   = mitem.Name() or "",
                            merchantIndex = i,
                            price         = (mitem.BuyPrice() or 0) / 1000,
                            deltaAC       = dAC,
                            deltaHP       = dHP,
                            deltaMana     = dMana,
                        })
                    end
                    break
                end
            end
            ::nextslot::
        end
        ::continue::
    end

    diveDirty = true
end

local function renderDumpsterDive()
    local tableFlags = bit32.bor(ImGuiTableFlags.Sortable, ImGuiTableFlags.Resizable,
        ImGuiTableFlags.Borders, ImGuiTableFlags.RowBg, ImGuiTableFlags.ScrollY)

    if ImGui.BeginTable("DiveTable", #diveColumns, tableFlags) then
        for id, col in ipairs(diveColumns) do
            ImGui.TableSetupColumn(col.name, col.flags, col.width, id - 1)
        end
        ImGui.TableSetupScrollFreeze(0, 1)
        ImGui.TableHeadersRow()

        local sort_specs = ImGui.TableGetSortSpecs()
        if sort_specs and (sort_specs.SpecsDirty or diveDirty) then
            local spec = sort_specs:Specs(1)
            local col  = diveColumns[(spec and spec.ColumnIndex or 0) + 1]
            if col and col.sort then
                table.sort(diveResults, function(a, b)
                    local av, bv = col.sort(a, b)
                    if spec.SortDirection == ImGuiSortDirection.Ascending then
                        return av < bv
                    else
                        return av > bv
                    end
                end)
            end
            sort_specs.SpecsDirty = false
            diveDirty = false
        end

        for _, r in ipairs(diveResults) do
            ImGui.PushID("##dive_row_" .. r.slotName .. r.upgradeName)
            for _, col in ipairs(diveColumns) do
                ImGui.TableNextColumn()
                col.render(r)
            end
            ImGui.PopID()
        end

        ImGui.EndTable()
    end
end

local openLastFrame = false
local function vendorGUI()
    if mq.TLO.MacroQuest.GameState() ~= "INGAME" then return end

    local merchantWnd = mq.TLO.Window("MerchantWnd")
    if openGUI and merchantWnd.Open() then
        if not openLastFrame then
            vendorInv:createContainerInventory()
            vendorInv:getItems(sourceIndex)
            merchantSnapshotPending = true
        end

        openLastFrame = true

        ImGui.SetNextWindowPos(merchantWnd.X() + merchantWnd.Width(), merchantWnd.Y())
        if collapsed then
            ImGui.SetNextWindowSize(40, 30)
        else
            ImGui.SetNextWindowSize(400, merchantWnd.Height())
        end

        openGUI, shouldDrawGUI = ImGui.Begin('DerpleVend', openGUI,
            bit32.bor(ImGuiWindowFlags.NoDecoration, ImGuiWindowFlags.NoCollapse, ImGuiWindowFlags.NoScrollWithMouse))

        ImGui.PushStyleColor(ImGuiCol.Text, 1, 1, 1, 1)
        local pressed

        if shouldDrawGUI then
            if ImGui.BeginTabBar("VendorTabs", ImGuiTabBarFlags.None) then
                if ImGui.BeginTabItem("Sell Junk") then
                    local disabled = false
                    if vendItem ~= nil or sellAllJunk then
                        ImGui.BeginDisabled()
                        disabled = true
                    end
                    if collapsed then
                        pressed = ImGui.SmallButton(Icons.MD_CHEVRON_RIGHT)
                        if pressed then
                            collapsed = false
                        end
                    else
                        ImGui.Text("Item Filters: ")
                        ImGui.SameLine()
                        sourceIndex, pressed = ImGui.Combo("##Select Bag", sourceIndex, function(idx) return vendorInv.sendSources[idx].name end, #vendorInv.sendSources)
                        if pressed then
                            vendorInv:getItems(sourceIndex)
                        end

                        ImGui.SameLine()
                        pressed = ImGui.SmallButton(Icons.MD_CHEVRON_LEFT)
                        if pressed then
                            collapsed = true
                        end

                        ImGui.Text(string.format("Filtered Items (%d):", #vendorInv.items or 0))

                        ImGui.SameLine()

                        if ImGui.SmallButton(Icons.MD_REFRESH) then
                            vendorInv:createContainerInventory()
                            vendorInv:getItems(sourceIndex)
                        end

                        ImGui.SameLine()

                        if disabled then
                            ImGui.EndDisabled()
                        end

                        if ImGui.SmallButton(disabled and "Cancel Selling" or "Sell Junk") then
                            sellAllJunk = not sellAllJunk
                            if sellAllJunk then
                                autoSellJunk()
                            end
                        end
                        Tooltip(disabled and "Stop selling junk items" or "Sell all junk items")

                        if disabled then
                            ImGui.BeginDisabled()
                        end
                        ImGui.SameLine()

                        if ImGui.SmallButton(showHidden and Icons.FA_EYE or Icons.FA_EYE_SLASH) then
                            showHidden = not showHidden
                        end
                        Tooltip("Toggle showing hidden items")

                        ImGui.NewLine()
                        ImGui.Separator()

                        ImGui.BeginChild("##VendorItems", -1, -1, ImGuiChildFlags.None, ImGuiWindowFlags.AlwaysVerticalScrollbar)
                        renderItems()
                        ImGui.EndChild()
                    end

                    if disabled then
                        ImGui.EndDisabled()
                    end
                    ImGui.EndTabItem()
                end
                if ImGui.BeginTabItem("Buy Items") then
                    ImGui.Text(string.format("Merchant Items (%d):", #buyItemsSorted))
                    ImGui.SameLine()
                    if ImGui.SmallButton(Icons.MD_REFRESH) then
                        snapshotMerchantItems()
                    end
                    buyFilter = ImGui.InputText("##BuyFilter", buyFilter, 64)
                    ImGui.Separator()
                    ImGui.BeginChild("##BuyItems", -1, -1, ImGuiChildFlags.None, ImGuiWindowFlags.None)
                    renderBuyItems()
                    ImGui.EndChild()
                    ImGui.EndTabItem()
                end
                if ImGui.BeginTabItem("Dumpster Dive") then
                    ImGui.Text(string.format("Potential Upgrades (%d):", #diveResults))
                    ImGui.SameLine()
                    if ImGui.SmallButton(Icons.MD_REFRESH) then
                        snapshotDiveResults()
                    end
                    ImGui.Separator()
                    ImGui.BeginChild("##DiveItems", -1, -1, ImGuiChildFlags.None, ImGuiWindowFlags.None)
                    renderDumpsterDive()
                    ImGui.EndChild()
                    ImGui.EndTabItem()
                end
                ImGui.EndTabBar()
            end
        end

        ImGui.PopStyleColor()
        ImGui.End()
    else
        openLastFrame = false
    end
end

mq.imgui.init('vendorGUI', vendorGUI)

mq.bind("/vendor", function(args)
    if args == "selljunk" then
        autoSellJunk()
    else
        openGUI = not openGUI
    end
end
)

LoadSettings()

vendorInv:createContainerInventory()
vendorInv:getItems(sourceIndex)

Output("\aw>>> \ayDerple's Vendor tool loaded! UI will auto show when you open a Merchant Window. Use \at/vendor\ay to toggle the UI!")

-- Global Messaging callback
---@diagnostic disable-next-line: unused-local
local script_actor = actors.register(function(message)
    local msg = message()

    if msg["from"] == mq.TLO.Me.DisplayName() then
        return
    end
    if msg["script"] ~= "DerpleVend" then
        return
    end

    ---@diagnostic disable-next-line: redundant-parameter
    Output("\ayGot Event from(\am%s\ay) event(\at%s\ay)", msg["from"], msg["event"])

    if msg["event"] == "SaveSettings" then
        LoadSettings()
    end
end)

while not terminate do
    if mq.TLO.MacroQuest.GameState() ~= "INGAME" then return end

    if merchantSnapshotPending and mq.TLO.Merchant.ItemsReceived() == true then
        snapshotMerchantItems()
        snapshotDiveResults()
        merchantSnapshotPending = false
    end

    if mq.gettime() - lastInventoryScan > 1000 then
        lastInventoryScan = mq.gettime()
        vendorInv:createContainerInventory()
        vendorInv:getItems(sourceIndex)
    end

    if vendItem ~= nil then
        sellItem(vendItem)
        vendItem = nil
        mq.delay(50)
        Output("\amRefreshing inv...")
        vendorInv:createContainerInventory()
        vendorInv:getItems(sourceIndex)
    end

    if sellAllJunk then
        local itemsToSell = vendorInv.items
        for _, item in ipairs(itemsToSell) do
            if IsJunk(item.Item.Name()) then
                sellItem(item)
                mq.delay(50)
                mq.doevents()
                vendorInv:getItems(sourceIndex)
            end

            if not openGUI then return end
            if not sellAllJunk then break end
        end

        Output("\amRefreshing inv...")
        vendorInv:createContainerInventory()
        vendorInv:getItems(sourceIndex)
        sellAllJunk = false
        if trackPlatDuringSell then
            mq.doevents()
            Output("\agReceived \at%d\ag platinum from selling junk.", totalPlatThisSell)
            -- Reset tracking after report
            trackPlatDuringSell = false
            totalPlatThisSell   = 0
        end
    end

    mq.doevents()
    mq.delay(400)
end
