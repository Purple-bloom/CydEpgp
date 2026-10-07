local addonName, privateTable = ...

-- Database local references
local dbSettings = {}
local dbPlayers = {}
local dbCharacters = {}
local dbRaidRewards = {}
local dbBidPrios = {}
local importResult = {}

local defaults = {
    minRarity = 4,           -- 4 = Epic (Default)
    enableAutolootBoE = false,
    reloadOnSave = true,     -- Default to enabled
    minimapPos = 45          -- Default angle in degrees
}

local rarityMap = {
    [1] = "Common",
    [2] = "Uncommon",
    [3] = "Rare",
    [4] = "Epic",
    [5] = "Legendary"
}

local receivedBids = {}
local bidFrames = {}
local currentItemLink = nil
local currentItemName = nil

-- Helper for case-insensitive lookup
local function GetPlayerPrio(name)
    if not name then return 0 end
    local lowerName = string.lower(name)
    return importResult[lowerName] or 0
end

-- ----------------------------------------------------
-- PARSER / IMPORT LOGIC
-- ----------------------------------------------------
function CydEpgp_ImportFromString(input)
    if not input or input == "" then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[CydEpgp]|r Import failed: Text box was empty!")
        return
    end

    -- Clean up string (remove carriage returns/newlines)
    input = string.gsub(input, "[\r\n]", "")

    -- Ensure SavedVariable root tables exist
    if type(CydEpgpData) ~= "table" then CydEpgpData = {} end
    if type(CydEpgpPrios) ~= "table" then CydEpgpPrios = {} end

    CydEpgpData.settings = CydEpgpData.settings or {}
    CydEpgpData.players = CydEpgpData.players or {}
    CydEpgpData.characters = CydEpgpData.characters or {}
    CydEpgpData.raidRewards = CydEpgpData.raidRewards or {}
    CydEpgpData.bidPrios = CydEpgpData.bidPrios or {}

    -- Wipe standalone prio table
    for k in pairs(CydEpgpPrios) do
        CydEpgpPrios[k] = nil
    end

    dbSettings = CydEpgpData.settings
    dbPlayers = CydEpgpData.players
    dbCharacters = CydEpgpData.characters
    dbRaidRewards = CydEpgpData.raidRewards
    dbBidPrios = CydEpgpData.bidPrios
    importResult = CydEpgpPrios

    -- Extract section blocks using brace delimiters
    local settingsStr   = string.match(input, "{SETTINGS}([^{}]+)") or ""
    local playersStr    = string.match(input, "{PLAYERS}([^{}]+)") or ""
    local charactersStr = string.match(input, "{CHARACTERS}([^{}]+)") or ""
    local rewardsStr    = string.match(input, "{RAIDREWARDS}([^{}]+)") or ""

    -- Validate essential sections
    if settingsStr == "" or playersStr == "" or charactersStr == "" or rewardsStr == "" then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[CydEpgp]|r Import failed: Missing required sections in import string.")
        if settingsStr == "" then DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[CydEpgp]|r No Settings found.") end
        if playersStr == "" then DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[CydEpgp]|r No Players found.") end
        if charactersStr == "" then DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[CydEpgp]|r No Characters found.") end
        if rewardsStr == "" then DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[CydEpgp]|r No Rewards found.") end
        return
    end

    -- 1. Parse SETTINGS (key:value;)
    for entry in string.gmatch(settingsStr, "([^;]+)") do
        local key, val = string.match(entry, "([^:]+):(%d+%.?%d*)")
        if key and val then
            local numVal = tonumber(val)
            dbSettings[key] = numVal

            if key == "lowminimumprio" then
                dbBidPrios["low"] = numVal
            elseif key == "midminimumprio" then
                dbBidPrios["mid"] = numVal
            elseif key == "highminimumprio" then
                dbBidPrios["high"] = numVal
            end
        end
    end

    -- 2. Parse PLAYERS (playerID:EP:value,GP:value;)
    local importedPlayerCount = 0
    for entry in string.gmatch(playersStr, "([^;]+)") do
        local pID, epVal, gpVal = string.match(entry, "(%d+):EP:(%d+%.?%d*),GP:(%d+%.?%d*)")
        if pID and epVal and gpVal then
            local numericID = tonumber(pID)
            dbPlayers[numericID] = {
                id = numericID,
                ep = tonumber(epVal),
                gp = tonumber(gpVal)
            }
            importedPlayerCount = importedPlayerCount + 1
        end
    end

    -- 3. Parse CHARACTERS (playerId:charName-role,charName2-role2;)
    local importedCharCount = 0
    for entry in string.gmatch(charactersStr, "([^;]+)") do
        local pID, charList = string.match(entry, "(%d+):(.+)")
        if pID and charList then
            local numericID = tonumber(pID)
            local playerData = dbPlayers[numericID]

            for singleChar in string.gmatch(charList, "([^,]+)") do
                local charName, roleType = string.match(singleChar, "^(.-)%-([^-]+)$")

                if charName and roleType then
                    charName = string.gsub(charName, "%s+", "")
                    roleType = string.gsub(roleType, "%s+", "")

                    local lowerCharName = string.lower(charName)
                    local isAlt = (string.lower(roleType) ~= "main")

                    dbCharacters[lowerCharName] = {
                        name = charName,
                        playerId = numericID,
                        isAlt = isAlt,
                        role = roleType
                    }

                    if playerData and playerData.gp and playerData.gp > 0 then
                        importResult[lowerCharName] = playerData.ep / playerData.gp
                    else
                        importResult[lowerCharName] = 0
                    end

                    importedCharCount = importedCharCount + 1
                end
            end
        end
    end

    -- 4. Parse RAIDREWARDS (ID:name, value OR ID:name:value;)
    for entry in string.gmatch(rewardsStr, "([^;]+)") do
        local rID, rewardName, val = string.match(entry, "(%d+):(.+)[:,-](%d+)")
        if rID and rewardName and val then
            local numericID = tonumber(rID)
            dbRaidRewards[numericID] = {
                id = numericID,
                name = rewardName,
                value = tonumber(val)
            }
        end
    end

    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[CydEpgp]|r Import Complete! Loaded " .. importedCharCount .. " characters across " .. importedPlayerCount .. " player profiles.")

    if GetNumRaidMembers() > 0 then
        SendChatMessage("New data imported. Whisper \"prio\" to get a reply with your prio.", "RAID")
    end
end

-- XML Import Button Handler
function CydEpgp_ExecuteImport()
    if CydEpgpImportEditBox then
        local text = CydEpgpImportEditBox:GetText()
        CydEpgp_ImportFromString(text)
        CydEpgpImportEditBox:SetText("")
        CydEpgpImportEditBox:ClearFocus()
    end
    if CydEpgpImportFrame then
        CydEpgpImportFrame:Hide()
    end
end

-- ----------------------------------------------------
-- HELPER FUNCTIONS
-- ----------------------------------------------------
local function UpdateMinimapButtonPosition(btn, angle)
    local radius = 80
    local x = math.cos(math.rad(angle)) * radius
    local y = math.sin(math.rad(angle)) * radius
    btn:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function CreateMinimapButton()
    local btn = CreateFrame("Button", "CydEpgpMinimapButton", Minimap)
    btn:SetSize(33, 33)
    btn:SetFrameStrata("MEDIUM")
    btn:SetMovable(true)

    local icon = btn:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\Icons\\inv_misc_elvencoins")
    icon:SetSize(21, 21)
    icon:SetPoint("CENTER")

    local border = btn:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(56, 56)
    border:SetPoint("TOPLEFT", 0, 0)

    btn:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    UpdateMinimapButtonPosition(btn, CydEpgp.minimapPos or defaults.minimapPos)

    btn:RegisterForDrag("LeftButton")

    btn:SetScript("OnDragStart", function(self)
        self:LockHighlight()
        self:SetScript("OnUpdate", function(self)
            local xpos, ypos = GetCursorPosition()
            local xmin, ymin = Minimap:GetCenter()
            local scale = Minimap:GetEffectiveScale()

            xpos = xpos / scale
            ypos = ypos / scale

            local angle = math.deg(math.atan2(ypos - ymin, xpos - xmin))
            if angle < 0 then angle = angle + 360 end

            CydEpgp.minimapPos = angle
            UpdateMinimapButtonPosition(self, angle)
        end)
    end)

    btn:SetScript("OnDragStop", function(self)
        self:UnlockHighlight()
        self:SetScript("OnUpdate", nil)
    end)

    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("CydEpgp")
        GameTooltip:AddLine("Left-click to open CydEPGP settings", 1, 1, 1)
        GameTooltip:AddLine("Drag to move button", 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

    btn:SetScript("OnClick", function(self, button)
        if CydEpgpConfigFrame:IsShown() then
            CydEpgpConfigFrame:Hide()
        else
            CydEpgpConfigFrame:Show()
        end
    end)
end

function CydEpgp_InitConfigUI()
    UIDropDownMenu_Initialize(CydEpgpRarityDropdown, function(self, level)
        for value = 1, 5 do
            local info = UIDropDownMenu_CreateInfo()
            info.text = rarityMap[value]
            info.value = value
            info.func = function(btn)
                UIDropDownMenu_SetSelectedValue(CydEpgpRarityDropdown, btn.value)
                UIDropDownMenu_SetText(CydEpgpRarityDropdown, rarityMap[btn.value])
            end
            UIDropDownMenu_AddButton(info, level)
        end
    end)
end

local function LoadConfigIntoUI()
    UIDropDownMenu_SetSelectedValue(CydEpgpRarityDropdown, CydEpgp.minRarity)
    UIDropDownMenu_SetText(CydEpgpRarityDropdown, rarityMap[CydEpgp.minRarity])

    CydEpgpAutolootCheck:SetChecked(CydEpgp.enableAutolootBoE)

    if CydEpgpReloadOnSaveCheck then
        local isReloadEnabled = defaults.reloadOnSave
        if CydEpgp.reloadOnSave ~= nil then
            isReloadEnabled = CydEpgp.reloadOnSave
        end
        CydEpgpReloadOnSaveCheck:SetChecked(isReloadEnabled)
    end
end

function CydEpgp_SaveConfig()
    CydEpgp.minRarity = UIDropDownMenu_GetSelectedValue(CydEpgpRarityDropdown) or defaults.minRarity
    CydEpgp.enableAutolootBoE = CydEpgpAutolootCheck:GetChecked() and true or false

    if CydEpgpReloadOnSaveCheck then
        CydEpgp.reloadOnSave = CydEpgpReloadOnSaveCheck:GetChecked() and true or false
    end

    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[CydEpgp]|r Settings saved successfully.")
    CydEpgpConfigFrame:Hide()
end

function CydEpgp_PresenceCheck()
    local numRaidMembers = GetNumRaidMembers()

    if numRaidMembers == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[CydEpgp]|r Presence check failed: You are not in a raid group.")
        return
    end

    local missingCharacters = {}

    for i = 1, numRaidMembers do
        local unitName = UnitName("raid" .. i)
        if unitName then
            local lowerName = string.lower(unitName)
            local charData = dbCharacters[lowerName]

            if not charData or not charData.playerId then
                table.insert(missingCharacters, unitName)
            end
        end
    end

    if #missingCharacters > 0 then
        local charListStr = table.concat(missingCharacters, ", ")
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000The following characters are not in the system: " .. charListStr .. "|r")
    else
        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00All characters are present in the system.|r")
    end
end

function LoadPrioData()
    if type(CydEpgpData) ~= "table" then CydEpgpData = {} end
    if type(CydEpgpPrios) ~= "table" then CydEpgpPrios = {} end

    CydEpgpData.settings = CydEpgpData.settings or {}
    CydEpgpData.players = CydEpgpData.players or {}
    CydEpgpData.characters = CydEpgpData.characters or {}
    CydEpgpData.raidRewards = CydEpgpData.raidRewards or {}
    CydEpgpData.bidPrios = CydEpgpData.bidPrios or {}

    dbSettings = CydEpgpData.settings
    dbPlayers = CydEpgpData.players
    dbCharacters = CydEpgpData.characters
    dbRaidRewards = CydEpgpData.raidRewards
    dbBidPrios = CydEpgpData.bidPrios

    -- Point runtime table directly to standalone SavedVariable
    importResult = CydEpgpPrios
end

local mainFrame = CreateFrame("Frame")
mainFrame:RegisterEvent("ADDON_LOADED")

mainFrame:SetScript("OnEvent", function(self, event, loadedAddon)
    if loadedAddon == addonName then
        if type(CydEpgpData) ~= "table" then CydEpgpData = {} end
        if CydEpgp == nil then CydEpgp = {} end

        -- Restore action log from table or legacy variable
        CydEpgpData.actionLog = CydEpgpData.actionLog or CydEpgpActionLog or ""
        CydEpgpData.lastActionExport = CydEpgpData.lastActionExport or CydEpgpLastActionExport or ""

        CydEpgpActionLog = CydEpgpData.actionLog
        CydEpgpLastActionExport = CydEpgpData.lastActionExport

        for key, val in pairs(defaults) do
            if CydEpgp[key] == nil then
                CydEpgp[key] = val
            end
        end

        LoadPrioData()
        CreateMinimapButton()
        CydEpgp_InitConfigUI()

        CydEpgpConfigFrame:SetScript("OnShow", LoadConfigIntoUI)

        DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[CydEpgp]|r loaded.")
    end
end)

local GetRaidMembers = function()
    local raidMembers = {}
    for i = 1, GetNumRaidMembers(), 1 do
        local name = UnitName("raid" .. i)
        if name and UnitIsConnected("raid"..i) then
            table.insert(raidMembers, name)
        end
    end
    table.sort(raidMembers, function(a, b)
        local prioA = GetPlayerPrio(a)
        local prioB = GetPlayerPrio(b)
        return prioA > prioB
    end)
    return raidMembers
end

local ShowImportField = function()
    CydEpgpImportFrame:Show()
    CydEpgpImportEditBox:SetText("")
    CydEpgpImportEditBox:HighlightText()
    CydEpgpImportEditBox:SetFocus()
end

local PrintAllPrios = function()
    local raidMembers = GetRaidMembers()

    local printString = ""
    local maxMsgLen = 256
    local bufferLen = 30
    for i, character in pairs(raidMembers) do
        local prioNotNil = GetPlayerPrio(character)
        printString = printString.."<"..character..":"..string.format("%.2f", prioNotNil).."> "
        if string.len(printString) >= maxMsgLen-bufferLen then
            SendChatMessage(printString, "RAID")
            printString = ""
        end
    end
    if not (printString == "") then
        SendChatMessage(printString, "RAID")
    end
end

local ShowRaidMembers = function()
    local raidMembers = GetRaidMembers()
    table.sort(raidMembers)
    StaticPopupDialogs["RAIDMEMBERS_OUTPUT"] = {
        text = "All currently logged in raid members:",
        button1 = "Okay",
        button2 = "Cancel",
        hasEditBox = true,
        maxLetters = 2000,
        OnAccept = function()
            local dialog = this:GetParent()
            local editBox = getglobal(dialog:GetName().."EditBox")
            editBox:SetText("")
        end,
        EditBoxOnEnterPressed = function()
            this:SetText("")
            this:GetParent():Hide()
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
    local dialog = StaticPopup_Show("RAIDMEMBERS_OUTPUT")
    dialog.data = table.concat(raidMembers, ", ")
    local editBox = getglobal(dialog:GetName().."EditBox")
    editBox:SetText(table.concat(raidMembers, ", "))
end

local ShowPrio = function()
    local raidMembers = GetRaidMembers()

    local text = ""
    for i, character in pairs(raidMembers) do
        local prioNotNil = GetPlayerPrio(character)
        text = text..character..": "..string.format("%.2f", prioNotNil).."\n"
    end
    PrioText:SetText(text)
    PrioFrame:Show()
end

function Prio_Hide()
    PrioFrame:Hide()
end

local matchTable = {
    ["ms low"] = "MS LOW", ["low"] = "MS LOW", ["min"] = "MS LOW", ["ms min"] = "MS LOW",
    ["ms mid"] = "MS MID", ["mid"] = "MS MID", ["medium"] = "MS MID", ["med"] = "MS MID", ["ms med"] = "MS MID",
    ["ms high"] = "MS HIGH", ["high"] = "MS HIGH", ["max"] = "MS HIGH", ["ms max"] = "MS HIGH",
    ["os low"] = "OS LOW", ["os min"] = "OS LOW",
    ["os mid"] = "OS MID", ["os medium"] = "OS MID",
    ["os high"] = "OS HIGH", ["os max"] = "OS HIGH",
}

local bidPriorityOrder = {
    ["MS HIGH"] = 1,
    ["MS MID"] = 2,
    ["MS LOW"] = 3,
    ["OS HIGH"] = 4,
    ["OS MID"] = 5,
    ["OS LOW"] = 6,
}

function CydEpgp_OnLoad()
    this:RegisterEvent("CHAT_MSG_ADDON")
    this:RegisterEvent("CHAT_MSG_WHISPER")
end

function CydEpgp_UpdateWindow()
    local sortedEntries = {}
    for player, bidPriority in pairs(receivedBids) do
        local importedPrio = GetPlayerPrio(player)
        table.insert(sortedEntries, {name = player, bidPriority = bidPriority, prio = importedPrio})
    end

    table.sort(sortedEntries, function(a, b)
        if a.bidPriority == b.bidPriority then
            return a.prio > b.prio
        end
        return bidPriorityOrder[a.bidPriority] < bidPriorityOrder[b.bidPriority]
    end)

    local rowOffset = 20
    local rowPostion = -30
    for _, character in ipairs(sortedEntries) do
        local rowFrame = bidFrames[character.name]
        rowFrame:SetPoint("TOPLEFT", CydEpgpFrame, "TOPLEFT", 10, rowPostion)
        rowFrame:Show()
        rowPostion = rowPostion - rowOffset
    end

    CydEpgpFrame:Show()
end

-- LOOT WINDOW

local lootRows = {}
local activeLoot = {}

local function GetValidatedBid(playerName, originalBid)
    if not originalBid then return nil, "INVALID", false, nil end

    local lowerName = string.lower(playerName)
    local charData = dbCharacters[lowerName]
    local isAlt = charData and charData.isAlt or false

    -- Automatically convert MS bids to OS if the character is an Alt
    local isOS = (string.find(originalBid, "^OS") or isAlt)

    local highThresh = dbBidPrios["high"] or 0
    local midThresh  = dbBidPrios["mid"] or 0
    local lowThresh  = dbBidPrios["low"] or 0

    local currentPrio = GetPlayerPrio(playerName)
    local prefix = isOS and "OS " or "MS "
    local changeReason = nil

    if isAlt and string.find(originalBid, "^MS") then
        changeReason = "Alt character (converted to OS)"
    end

    -- Evaluate HIGH tier
    if string.find(originalBid, "HIGH") then
        if currentPrio >= highThresh then
            return prefix .. "HIGH", "HIGH", isOS, changeReason
        elseif currentPrio >= midThresh then
            local reason = "Downgraded from HIGH to MID (Prio " .. string.format("%.2f", currentPrio) .. " < " .. highThresh .. ")"
            changeReason = changeReason and (changeReason .. " & " .. reason) or reason
            return prefix .. "MID", "MID", isOS, changeReason
        elseif currentPrio >= lowThresh then
            local reason = "Downgraded from HIGH to LOW (Prio " .. string.format("%.2f", currentPrio) .. " < " .. midThresh .. ")"
            changeReason = changeReason and (changeReason .. " & " .. reason) or reason
            return prefix .. "LOW", "LOW", isOS, changeReason
        else
            return nil, "INVALID", isOS, "Insufficient Prio (" .. string.format("%.2f", currentPrio) .. " < " .. lowThresh .. ")"
        end
    end

    -- Evaluate MID tier
    if string.find(originalBid, "MID") then
        if currentPrio >= midThresh then
            return prefix .. "MID", "MID", isOS, changeReason
        elseif currentPrio >= lowThresh then
            local reason = "Downgraded from MID to LOW (Prio " .. string.format("%.2f", currentPrio) .. " < " .. midThresh .. ")"
            changeReason = changeReason and (changeReason .. " & " .. reason) or reason
            return prefix .. "LOW", "LOW", isOS, changeReason
        else
            return nil, "INVALID", isOS, "Insufficient Prio (" .. string.format("%.2f", currentPrio) .. " < " .. lowThresh .. ")"
        end
    end

    -- Evaluate LOW tier
    if string.find(originalBid, "LOW") then
        if currentPrio >= lowThresh then
            return prefix .. "LOW", "LOW", isOS, changeReason
        else
            return nil, "INVALID", isOS, "Insufficient Prio (" .. string.format("%.2f", currentPrio) .. " < " .. lowThresh .. ")"
        end
    end

    return nil, "INVALID", isOS, "Invalid Bid"
end

function CydEpgp_Award(playerName)
    local effectiveBid = receivedBids[playerName]
    if not effectiveBid then return end
    if not currentItemLink then
        currentItemLink = "Unknown"
        currentItemName = "Unknown"
    end

    local prioNotNil = GetPlayerPrio(playerName)
    SendChatMessage(playerName.." receives "..currentItemLink.." for "..effectiveBid.." with a current prio of "..string.format("%.2f", prioNotNil)..". ", "RAID_WARNING", nil, nil)

    local bidTypeToID = {
        ["MS LOW"] = 1, ["MS MID"] = 2, ["MS HIGH"] = 3,
        ["OS LOW"] = 4, ["OS MID"] = 5, ["OS HIGH"] = 6
    }
    local bidTypeId = bidTypeToID[effectiveBid] or 1

    -- Log GP Action format: {GP}bidTypeID;characterName;itemName
    local gpEntry = "{GP}" .. bidTypeId .. ";" .. playerName .. ";" .. (currentItemName or "Unknown")
    local existingLog = (CydEpgpData and CydEpgpData.actionLog) or CydEpgpActionLog or ""
    if existingLog == "" then
        existingLog = gpEntry
    else
        existingLog = existingLog .. gpEntry
    end
    CydEpgpActionLog = existingLog
    if CydEpgpData then CydEpgpData.actionLog = existingLog end
    -- logging done

    local costTier = "low"
    if string.find(effectiveBid, "MID") then
        costTier = "mid"
    elseif string.find(effectiveBid, "HIGH") then
        costTier = "high"
    end

    local isOS = string.find(effectiveBid, "^OS") and true or false

    -- Award GP to Player and update Priority live
    local lowerName = string.lower(playerName)
    local charData = dbCharacters[lowerName]
    if charData and charData.playerId then
        local playerData = dbPlayers[charData.playerId]
        if playerData then
            local costKey = costTier .. "cost"
            local baseGpCost = dbSettings[costKey] or 0
            local finalGpCost = baseGpCost

            if isOS then
                local discountPercent = dbSettings["offspecgpdiscount"] or 0
                finalGpCost = baseGpCost * (1 - (discountPercent / 100))
            end

            playerData.gp = (playerData.gp or 0) + finalGpCost

            if playerData.gp > 0 then
                importResult[lowerName] = playerData.ep / playerData.gp
            end

            local osMsg = isOS and " [OS Discount Applied]" or ""
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[CydEpgp]|r " .. playerName .. " awarded +" .. finalGpCost .. " GP (" .. costTier .. ")" .. osMsg .. ". New GP: " .. playerData.gp)
        end
    end

    -- Remove awarded item from active loot array
    for i, itemData in ipairs(activeLoot) do
        if itemData.link == currentItemLink then
            table.remove(activeLoot, i)
            break
        end
    end

    CydEpgp_ClearEntries()
    CydEpgp_RefreshLootList()
end

function CydEpgp_RefreshLootList()
    CydEpgp_HideAllItemRows()

    local displayCount = table.getn(activeLoot)

    for i, itemData in ipairs(activeLoot) do
        CreateLootRow(itemData.slot, itemData.name, itemData.tex, itemData.link, i)
    end

    EpgpLootInteractFrame:Show()
end

function CydEpgp_StartBidding(slot, link, name)
    SendChatMessage("BID NOW FOR "..link, "RAID_WARNING", nil, nil)

    local title = getglobal("CydEpgpTitle")
    if title then
        title:SetText("Bidding: " .. link)
    end

    currentItemLink = link
    currentItemName = name
end

function CreateLootRow(slotIndex, itemName, itemTexture, itemLink, displayIndex)
    local f = lootRows[displayIndex]

    if not f then
        f = CreateFrame("Button", "EpgpLootRow"..displayIndex, EpgpLootInteractFrame, "EpgpLootItemTemplate")
        table.insert(lootRows, f)
    end
    f:ClearAllPoints()
    if displayIndex == 1 then
        f:SetPoint("TOPLEFT", EpgpLootInteractFrame, "TOPLEFT", 10, -35)
    else
        f:SetPoint("TOPLEFT", lootRows[displayIndex-1], "BOTTOMLEFT", 0, -5)
    end

    f.itemSlot = slotIndex
    f.itemLink = itemLink
    f.itemName = itemName

    getglobal(f:GetName().."Text"):SetText(itemLink or itemName)
    getglobal(f:GetName().."Icon"):SetTexture(itemTexture)

    f:Show()
end

local scannerTooltip = CreateFrame("GameTooltip", "MyBoPScannerTooltip", nil, "GameTooltipTemplate")
scannerTooltip:SetOwner(WorldFrame, "ANCHOR_NONE")

local function IsItemLinkBoP(itemLink)
    if not itemLink then return false end

    scannerTooltip:ClearLines()
    scannerTooltip:SetHyperlink(itemLink)

    for i = 1, scannerTooltip:NumLines() do
        local line = _G["MyBoPScannerTooltipTextLeft" .. i]
        if line and line:GetText() == ITEM_BIND_ON_PICKUP then
            return true
        end
    end

    return false
end

function CydEpgp_OnLootOpen()
    activeLoot = {}
    local numItems = GetNumLootItems()
    if numItems > 0 then
        local method, masterlooterPartyID = GetLootMethod()
        if (method == "master" and masterlooterPartyID == 0) then

            CydEpgp_HideAllItemRows()

            local displayCount = 0
            local minRarityThreshold = CydEpgp and CydEpgp.minRarity or defaults.minRarity

            for i = 1, numItems do
                local texture, name, qty, quality = GetLootSlotInfo(i)
                if not LootSlotIsCoin(i) then
                    local link = GetLootSlotLink(i)
                    local isItemBoP = IsItemLinkBoP(link)

                    if isItemBoP or not (CydEpgp and CydEpgp.enableAutolootBoE) then
                        if quality >= minRarityThreshold then
                            displayCount = displayCount + 1
                            CreateLootRow(i, name, texture, link, displayCount)
                            table.insert(activeLoot, {slot=displayCount, name=name, tex=texture, link=link})
                        end
                    else
                        for raidMemberIndex = 1, GetNumRaidMembers() do
                            if (GetMasterLootCandidate(raidMemberIndex) == UnitName("player")) then
                                GiveMasterLoot(i, raidMemberIndex)
                            end
                        end
                    end
                end
            end
            if displayCount > 0 then
                EpgpLootInteractFrame:Show()
            end
        end
    end
end

function CydEpgp_HideAllItemRows()
    for _, frame in ipairs(lootRows) do
        frame:Hide()
    end
end

function CydEpgp_CloseItemFrame()
    EpgpLootInteractFrame:Hide()
    CydEpgp_HideAllItemRows()

    local shouldReload = defaults.reloadOnSave
    if CydEpgp and CydEpgp.reloadOnSave ~= nil then
        shouldReload = CydEpgp.reloadOnSave
    end

    if shouldReload then
        ReloadUI()
    end
end

function CydEpgp_ClearEntries()
    receivedBids = {}
    for player, rowFrame in pairs(bidFrames) do
        rowFrame:Hide()
    end
    CydEpgpFrame:Hide()
end

function CydEpgp_InitRaidRewardDropdown()
    UIDropDownMenu_Initialize(CydEpgpRaidRewardDropdown, function(self, level)
        for _, rewardData in pairs(dbRaidRewards) do
            local info = UIDropDownMenu_CreateInfo()
            local text = rewardData.name .. " (" .. rewardData.value .. " EP)"
            local value = rewardData.id

            info.text = text
            info.value = value
            info.func = function()
                UIDropDownMenu_SetSelectedValue(CydEpgpRaidRewardDropdown, value)
                UIDropDownMenu_SetText(CydEpgpRaidRewardDropdown, text)
            end

            UIDropDownMenu_AddButton(info, level)
        end
    end)
end

function CydEpgp_OpenEpAwardFrame()
    CydEpgp_InitRaidRewardDropdown()

    local firstRewardKey, reward = next(dbRaidRewards)
    if firstRewardKey and reward then
        local displayText = reward.name .. " (" .. reward.value .. " EP)"
        UIDropDownMenu_SetSelectedValue(CydEpgpRaidRewardDropdown, reward.id)
        UIDropDownMenu_SetText(CydEpgpRaidRewardDropdown, displayText)
    else
        UIDropDownMenu_SetSelectedValue(CydEpgpRaidRewardDropdown, nil)
        UIDropDownMenu_SetText(CydEpgpRaidRewardDropdown, "No Rewards Found")
    end

    CydEpgpEpAwardFrame:Show()
end

function CydEpgp_AwardRaidReward()
    local selectedRewardId = UIDropDownMenu_GetSelectedValue(CydEpgpRaidRewardDropdown)
    if not selectedRewardId or not dbRaidRewards[selectedRewardId] then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[CydEpgp]|r Please select a valid Raid Reward first.")
        return
    end

    local rewardData = dbRaidRewards[selectedRewardId]
    local epValue = rewardData.value
    local numRaidMembers = GetNumRaidMembers()

    if numRaidMembers == 0 then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[CydEpgp]|r You are not in a raid group.")
        return
    end

    local awardedCount = 0
    local raidMemberNames = {}

    for i = 1, numRaidMembers do
        local unitName = UnitName("raid" .. i)
        if unitName then
            table.insert(raidMemberNames, unitName)
            local lowerName = string.lower(unitName)
            local charData = dbCharacters[lowerName]

            if not charData then
                DEFAULT_CHAT_FRAME:AddMessage("|cffff0000Character in the raid encountered that does not exist in the EPGP system yet. Please export any stored changes to the website, add the new character/player, and re-import. NO EP WAS GIVEN OUT.|r")
                return
            end
        end
    end

    for i = 1, numRaidMembers do
        local unitName = UnitName("raid" .. i)
        if unitName then
            table.insert(raidMemberNames, unitName)
            local lowerName = string.lower(unitName)
            local charData = dbCharacters[lowerName]

            local playerData = dbPlayers[charData.playerId]
            if playerData then
                playerData.ep = (playerData.ep or 0) + epValue

                if playerData.gp and playerData.gp > 0 then
                    importResult[lowerName] = playerData.ep / playerData.gp
                end

                awardedCount = awardedCount + 1
            end
        end
    end

    -- Log EP Action format: {EP}rewardID;Name1,Name2,Name3
    local charListStr = table.concat(raidMemberNames, ",")
    local epEntry = "{EP}" .. selectedRewardId .. ";" .. charListStr

    local existingLog = (CydEpgpData and CydEpgpData.actionLog) or CydEpgpActionLog or ""
    if existingLog == "" then
        existingLog = epEntry
    else
        existingLog = existingLog .. epEntry
    end

    CydEpgpActionLog = existingLog
    if CydEpgpData then CydEpgpData.actionLog = existingLog end
    -- logging done

    DEFAULT_CHAT_FRAME:AddMessage("|cff00ff00[CydEpgp]|r Awarded " .. epValue .. " EP (" .. rewardData.name .. ") to " .. awardedCount .. " raid members.")
    SendChatMessage("Awarded " .. epValue .. " EP for " .. rewardData.name .. " to all raid members.", "RAID")
end

function CydEpgp_OnEvent(event)
    local message = arg1
    local sender = arg2

    if not message or not sender then return end

    local lowerMessage = string.lower(message)

    if lowerMessage == "prio" then
        local prioNotNil = GetPlayerPrio(sender)
        SendChatMessage("Prio for "..sender..": "..string.format("%.2f", prioNotNil), "WHISPER", nil, sender)
        return
    end

    if lowerMessage == "howto" then
        SendChatMessage("EPGP works by awarding items based on Prio. Prio is calculated by dividing your Effort Points (EP) by your Gear Points (GP).", "WHISPER", nil, sender)
        SendChatMessage("In order to bid you need to whisper MS LOW, MS MID or MS HIGH to me. Alternatively you can Whisper OS LOW, OS MID or OS HIGH for offspec bids.", "WHISPER", nil, sender)
        SendChatMessage("The highest prio in the highest bid category wins.", "WHISPER", nil, sender)
        return
    end

    for bidWhispered, rawBidValue in pairs(matchTable) do
        if string.find(lowerMessage, "^" .. bidWhispered) then
            local effectiveBid, costTier, isOS, changeReason = GetValidatedBid(sender, rawBidValue)

            if not effectiveBid then
                SendChatMessage("[CydEPGP] Your bid was rejected (" .. (changeReason or "Insufficient Prio") .. ").", "WHISPER", nil, sender)
                return
            end

            receivedBids[sender] = effectiveBid
            local calculatedPrio = GetPlayerPrio(sender)
            local prioDisplay = string.format("%.2f", calculatedPrio)

            local rowName = "BidRow"..sender
            local row
            if bidFrames[sender] == nil then
                row = CreateFrame("Frame", rowName, CydEpgpFrame, "RowTemplate")
            else
                row = bidFrames[sender]
            end

            row.playerName = sender
            row.nameText = getglobal(rowName.."Name")
            row.bidText  = getglobal(rowName.."Bid")
            row.prioText  = getglobal(rowName.."Prio")

            row.nameText:SetText(sender)
            row.bidText:SetText(effectiveBid..":")
            row.prioText:SetText(prioDisplay)

            bidFrames[sender] = row
            CydEpgp_UpdateWindow()

            if changeReason then
                SendChatMessage("[CydEPGP] Your bid was adjusted to " .. effectiveBid .. " (" .. changeReason .. ").", "WHISPER", nil, sender)
            else
                SendChatMessage("[CydEPGP] Your bid (" .. effectiveBid .. ") has been accepted.", "WHISPER", nil, sender)
            end
            return
        end
    end
end

function slashShowActionExport()
    local currentLog = (CydEpgpData and CydEpgpData.actionLog) or CydEpgpActionLog

    if not currentLog or currentLog == "" then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[CydEpgp]|r No action export data available.")
        return
    end

    CydEpgpLastActionExport = currentLog
    if CydEpgpData then CydEpgpData.lastActionExport = currentLog end

    CydEpgpExportEditBox:SetText(currentLog)
    CydEpgpExportFrame:Show()
    CydEpgpExportEditBox:HighlightText()
    CydEpgpExportEditBox:SetFocus()

    CydEpgpActionLog = ""
    if CydEpgpData then CydEpgpData.actionLog = "" end
end

function slashShowLastActionExport()
    local lastLog = (CydEpgpData and CydEpgpData.lastActionExport) or CydEpgpLastActionExport

    if not lastLog or lastLog == "" then
        DEFAULT_CHAT_FRAME:AddMessage("|cffff0000[CydEpgp]|r No previous action export backup available.")
        return
    end

    CydEpgpExportEditBox:SetText(lastLog)
    CydEpgpExportFrame:Show()
    CydEpgpExportEditBox:HighlightText()
    CydEpgpExportEditBox:SetFocus()
end

function CydEpgp_OnExportFrameHide()
    if CydEpgpExportEditBox then
        CydEpgpExportEditBox:SetText("")
    end
end

local ShowHelp = function()
    DEFAULT_CHAT_FRAME:AddMessage("/pimp --- prio import using the import string supplied by the website.")
    DEFAULT_CHAT_FRAME:AddMessage("/pap --- print all prios of people currently in your raid")
    DEFAULT_CHAT_FRAME:AddMessage("/getRaidMembers --- print list of all Characters currently in raid")
    DEFAULT_CHAT_FRAME:AddMessage("/prio --- display window with prio of all people in raid (very scuffed)")
    DEFAULT_CHAT_FRAME:AddMessage("/gpexport --- shows you the gp export text window again if you closed it too early accidentally")
end

SLASH_CYDEPGPHELP1 = "/cydEpgp"
SlashCmdList.CYDEPGPHELP = ShowHelp

SLASH_PRIOIMPORT1 = "/pimp"
SlashCmdList.PRIOIMPORT = ShowImportField

SLASH_PRIOPRINT1 = "/pap"
SlashCmdList.PRIOPRINT = PrintAllPrios

SLASH_GETRAID1 = "/getRaidMembers"
SlashCmdList.GETRAID = ShowRaidMembers

SLASH_SHOWPRIO1 = "/prio"
SlashCmdList.SHOWPRIO = ShowPrio

SLASH_ACTIONEXPORT1 = "/actionexport"
SlashCmdList.ACTIONEXPORT = slashShowActionExport

SLASH_LASTACTIONEXPORT1 = "/lastactionexport"
SlashCmdList.LASTACTIONEXPORT = slashShowLastActionExport