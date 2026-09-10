local receivedBids = {}; -- tracking all received bids until list is cleared
local bidFrames = {}; -- tracking bidFrames in the bid window
local importResult = {}; -- results of prio import
local blockChatImport = false; -- block other people from messing with ur shit
local currentItemLink = nil; -- this value tracks which item is being bid on globally
local currentItemName = nil; -- this value tracks which item is being bid on globally
local gpExport = ""; -- continually added to for gp award info. reset when item bid window is closed
local lastGpExport = ""; -- kept for /gpexport

local GetRaidMembers = function()
    local raidMembers = {};
    for i = 1, GetNumRaidMembers(), 1 do
        local name = UnitName("raid" .. i);
        if name and UnitIsConnected("raid"..i) then
            table.insert(raidMembers, name);
        end
    end
    table.sort(raidMembers, function(a, b)
        local prioA = importResult[a] or 0
        local prioB = importResult[b] or 0
        return prioA > prioB
    end)
    return raidMembers
end

local PropagatePrios = function()
    local raidMembers = GetRaidMembers()
    local priosToSend = {}
    for i, character in pairs(raidMembers) do
        priosToSend[character] = importResult[character] or 0
    end

    local msgToSend = ""
    for character, prio in pairs(priosToSend) do
        msgToSend = msgToSend..character..":"..prio..";"
    end

    local maxMsgLen = 256
    local bufferLen = 30
    local msg = ""
    for i=0, string.len(msgToSend), 1 do
        local currentChar = string.sub(msgToSend, i, i)
        msg = msg..currentChar
        if((string.len(msg)>200 and currentChar == ';') or string.len(msg) >= string.len(msgToSend)) then
            print("Sending addon message")
            SendAddonMessage("CYDEPGP", msg, "RAID", nil)
            msg = ""
        end
    end
end

local ImportPriosFromString = function(input)
    importResult = {}
    string.gsub(input, "([^;]+)", function(segment)
        local _, _, namesPart, prioPart = string.find(segment, "(.-):(.+)")

        if namesPart and prioPart then
            string.gsub(namesPart, "([^,]+)", function(name)
                local cleanName = string.gsub(name, "%s+", "")
                importResult[cleanName] = tonumber(prioPart)
            end)
        end
    end)
    print("|cff00ff00Prio Import Complete!|r")
    SendChatMessage("New prios imported. Whisper \"prio\" to get a reply with your prio. Whisper \"howto\" to see how to bid after an item is posted.", "RAID" ,GetDefaultLanguage() , nil);
    PropagatePrios()
end

local ImportPriosFromChat = function(input)
    string.gsub(input, "([^;]+)", function(segment)
        local _, _, namesPart, prioPart = string.find(segment, "(.-):(.+)")
        if namesPart and prioPart then
            importResult[namesPart] = tonumber(prioPart)
        end
    end)
    print("|cff00ff00New (partial) prio update received and imported.|r")
end

local ShowImportField = function()
    StaticPopupDialogs["IMPORT_PRIO_INPUT"] = {
        text = "Paste the Prio String below:",
        button1 = "Import",
        button2 = "Cancel",
        hasEditBox = true,
        maxLetters = 50000,

        OnAccept = function()
            local dialog = this:GetParent()
            local editBox = getglobal(dialog:GetName().."EditBox")

            if editBox then
                local text = editBox:GetText()
                ImportPriosFromString(text)
                editBox:SetText("")
            end
        end,

        EditBoxOnEnterPressed = function()
            local text = this:GetText()
            ImportPriosFromString(text)
            this:SetText("")
            this:GetParent():Hide()
        end,

        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
    }
    StaticPopup_Show("IMPORT_PRIO_INPUT")
end

local PrintAllPrios = function()
    local raidMembers = GetRaidMembers()

    local printString = ""
    local maxMsgLen = 256
    local bufferLen = 30 -- to ensure we dont hit char limit with next string (dont judge me im lazy)
    for i, character in pairs(raidMembers) do
        local prioNotNil = importResult[character] or 0
        printString = printString.."<"..character..":"..prioNotNil.."> "
        if string.len(printString) >= maxMsgLen-bufferLen then
            SendChatMessage(printString, "RAID" ,GetDefaultLanguage() ,nil);
            printString = ""
        end
    end
    if not (printString == "") then
        SendChatMessage(printString, "RAID" ,GetDefaultLanguage() ,nil);
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
    local dialog = StaticPopup_Show("RAIDMEMBERS_OUTPUT");
    dialog.data = table.concat(raidMembers, ", ");
    local editBox = getglobal(dialog:GetName().."EditBox");
    editBox:SetText(table.concat(raidMembers, ", "));
end

local ShowPrio = function()
    local raidMembers = GetRaidMembers()

    local text = ""
    for i, character in pairs(raidMembers) do
        local prioNotNil = importResult[character] or 0
        text = text..character..": "..prioNotNil.."\n"
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

-- custom priority order
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


function CydEpgp_OnEvent(event)
    if (arg1 == "CYDEPGP" and not (arg4 == UnitName("player")) and not blockChatImport) then
        ImportPriosFromChat(arg2)
        return
    end

    local message = arg1
    local sender = arg2

    if string.lower(message) == "prio" then
        local prioNotNil = importResult[sender] or 0
        SendChatMessage("Prio for "..sender..": "..prioNotNil, "WHISPER" ,GetDefaultLanguage() ,sender);
        return
    end

    if string.lower(message) == "howto" then
        SendChatMessage("EPGP works by awarding items based on Prio. Prio is calculated by dividing your Effort Points (EP) by your Gear Points (GP) - GP increases for gear you get and EP increases for bosskills, using consumes, being on time etc.", "WHISPER" ,GetDefaultLanguage() ,sender);
        SendChatMessage("In order to bid you need to whisper MS LOW, MS MID or MS HIGH to me. Alternatively you can Whisper OS LOW, OS MID or OS HIGH for offspec bids.", "WHISPER" ,GetDefaultLanguage() ,sender);
        SendChatMessage("The highest prio in the highest bid category wins, so an MS HIGH will win vs an MS MID even when the player doing the high bid has lower prio, as long as the bid isn't downgraded.", "WHISPER" ,GetDefaultLanguage() ,sender);
        return
    end

    local whisperLowercase = string.lower(message)
    for bidWhispered, bidValue in pairs(matchTable) do
        if string.find(whisperLowercase, "^" .. bidWhispered) then
            -- This is the part where we received a valid bid
            receivedBids[sender] = bidValue;

            local importedPrio = importResult[sender];
            if importedPrio == nil then
                importedPrio = 0;
            end

            local rowName = "BidRow"..sender;
            local row;
            if bidFrames[sender] == nil then
                row = CreateFrame("Frame", rowName, CydEpgpFrame, "RowTemplate");
            else
                row = bidFrames[sender]
            end

            row.playerName = sender; -- this attrib is used for announcing the winner / saving the playerName to the row regardless of the text
            row.nameText = getglobal(rowName.."Name");
            row.bidText  = getglobal(rowName.."Bid");
            row.prioText  = getglobal(rowName.."Prio");
            row.awardButton = getglobal(rowName.."AwardButton");

            row.nameText:SetText(sender);
            row.bidText:SetText(bidValue..":");
            row.prioText:SetText(importedPrio);

            bidFrames[sender] = row;
            CydEpgp_UpdateWindow();
            return
        end
    end
end

function CydEpgp_UpdateWindow()
    local sortedEntries = {}
    for player, bidPriority in pairs(receivedBids) do
        local importedPrio = importResult[player]
        if importedPrio == nil then
            importedPrio = 0
        end
        table.insert(sortedEntries, {name = player, bidPriority = bidPriority, prio = importedPrio})
    end

    -- Sort based on bid and then prio
    table.sort(sortedEntries, function(a, b)
        if a.bidPriority == b.bidPriority then
            return a.prio > b.prio
        end
        return bidPriorityOrder[a.bidPriority] < bidPriorityOrder[b.bidPriority]
    end)

    local rowOffset = 20;
    local rowPostion = -30;
    for _, character in ipairs(sortedEntries) do
        local rowFrame = bidFrames[character.name]
        rowFrame:SetPoint("TOPLEFT", CydEpgpFrame, "TOPLEFT", 10, rowPostion);
        rowFrame:Show();
        rowPostion = rowPostion - rowOffset
    end

    CydEpgpFrame:Show();
end

-- LOOT WINDOW

local lootRows = {};
local activeLoot = {};

function CydEpgp_Award(playerName)
    local bidTier = receivedBids[playerName];
    local prioNotNil = importResult[playerName] or 0;
    SendChatMessage(playerName.." receives "..currentItemLink.." for "..bidTier.." with a current prio of "..prioNotNil..".", "RAID_WARNING" ,GetDefaultLanguage() , nil);
    gpExport = gpExport .. playerName .. "--" .. bidTier .. "--" .. currentItemName .. ";"

    for i, rowFrame in ipairs(lootRows) do
        if rowFrame.itemLink == currentItemLink then
            table.remove(activeLoot, i);
            break
        end
    end

    CydEpgp_RefreshLootList();
end

function CydEpgp_RefreshLootList()
    CydEpgp_HideAllItemRows();

    local displayCount = table.getn(activeLoot);
    if displayCount == 0 then
        CydEpgp_CloseItemFrame(); -- Auto-close and show export if last item is gone
        return
    end

    for i, itemData in ipairs(activeLoot) do
        CreateLootRow(itemData.slot, itemData.name, itemData.tex, itemData.link, i);
    end

    EpgpLootInteractFrame:Show();
end

function CydEpgp_StartBidding(slot, link, name)
    SendChatMessage("BID NOW FOR "..link, "RAID_WARNING" ,GetDefaultLanguage() , nil);

    local title = getglobal("CydEpgpTitle");
    if title then
        title:SetText("Bidding: " .. link);
    end

    currentItemLink = link;
    currentItemName = name;
end

function CreateLootRow(slotIndex, itemName, itemTexture, itemLink, displayIndex)
    local f = lootRows[displayIndex];

    if not f then
        f = CreateFrame("Button", "EpgpLootRow"..displayIndex, EpgpLootInteractFrame, "EpgpLootItemTemplate");
        table.insert(lootRows, f);
    end
    f:ClearAllPoints();
    if displayIndex == 1 then
        f:SetPoint("TOPLEFT", EpgpLootInteractFrame, "TOPLEFT", 10, -35);
    else
        f:SetPoint("TOPLEFT", lootRows[displayIndex-1], "BOTTOMLEFT", 0, -5);
    end

    f.itemSlot = slotIndex;
    f.itemLink = itemLink;
    f.itemName = itemName;

    getglobal(f:GetName().."Text"):SetText(itemLink or itemName);
    getglobal(f:GetName().."Icon"):SetTexture(itemTexture);

    f:Show();
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
    activeLoot = {};
    local numItems = GetNumLootItems();
    if numItems > 0 then
        local method, masterlooterPartyID = GetLootMethod();
        if (method == "master" and masterlooterPartyID == 0) then

            CydEpgp_HideAllItemRows();

            local displayCount = 0;
            for i = 1, numItems do
                local texture, name, qty, quality = GetLootSlotInfo(i);
                if not LootSlotIsCoin(i) then
                    local link = GetLootSlotLink(i);
                    local isItemBoP = IsItemLinkBoP(link);

                    if isItemBoP then
                        if quality >= 3 then -- quality is rarity
                            displayCount = displayCount + 1;
                            CreateLootRow(i, name, texture, link, displayCount);
                            table.insert(activeLoot, {slot=displayCount, name=name, tex=texture, link=link});
                        end
                    else --autoloots BoE items to yourself
                        for raidMemberIndex = 1, GetNumRaidMembers() do
                            if (GetMasterLootCandidate(raidMemberIndex) == UnitName("player")) then
                                GiveMasterLoot(i, raidMemberIndex);
                            end
                        end
                    end
                    --[[
                    if quality >= 3 then -- quality is rarity
                        displayCount = displayCount + 1;
                        CreateLootRow(i, name, texture, link, displayCount);
                        table.insert(activeLoot, {slot=displayCount, name=name, tex=texture, link=link});
                    end
                    ]]
                end
            end
            if displayCount > 0 then
                EpgpLootInteractFrame:Show();
            end
        end
    end
end

function CydEpgp_HideAllItemRows()
    for _, frame in ipairs(lootRows) do
        frame:Hide();
    end
end

function CydEpgp_CloseItemFrame()
    EpgpLootInteractFrame:Hide();
    CydEpgp_HideAllItemRows();

    if gpExport ~= "" then
        StaticPopupDialogs["EPGP_EXPORT_COPY"] = {
            text = "Press Ctrl+C to copy the GP Export data:",
            button1 = "Okay",
            button2 = "Cancel",
            hasEditBox = true,
            maxLetters = 2000,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
        }
        local dialog = StaticPopup_Show("EPGP_EXPORT_COPY");
        dialog.data = gpExport;
        local editBox = getglobal(dialog:GetName().."EditBox");
        editBox:SetText(gpExport);
    end
    lastGpExport = gpExport;
    gpExport = "";
end

function CydEpgp_ClearEntries()
    receivedBids = {}
    for player, rowFrame in pairs(bidFrames) do
        rowFrame:Hide();
    end
    CydEpgpFrame:Hide()
end

function disableReceive()
    blockChatImport = not blockChatImport
    print("Prio importing from other addons is now ".. tostring(blockChatImport))
end

function slashShowGpExport()
    if lastGpExport ~= "" then
        StaticPopupDialogs["EPGP_EXPORT_COPY"] = {
            text = "Press Ctrl+C to copy the GP Export data:",
            button1 = "Okay",
            button2 = "Cancel",
            hasEditBox = true,
            maxLetters = 2000,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
        }
        local dialog = StaticPopup_Show("EPGP_EXPORT_COPY");
        dialog.data = lastGpExport;
        local editBox = getglobal(dialog:GetName().."EditBox");
        editBox:SetText(lastGpExport);
    end
end

local ShowHelp = function()
    print("/pimp --- prio import using format [characterName:prio;characterName2:prio2;...]")
    print("/pap --- print all prios of people currently in your raid")
    print("/getRaidMembers --- print list of all Characters currently in raid")
    print("/prio --- display window with prio of all people in raid (very scuffed)")
    print("/blockChatImport --- blocks other installations of this addon in the same raid from sending you an import via /pimp")
    print("/gpexport --- shows you the gp export text window again if you closed it too early accidentally")
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

SLASH_DISABLERECEIVE1 = "/blockChatImport"
SlashCmdList.DISABLERECEIVE = disableReceive

SLASH_GPEXPORT1 = "/gpexport"
SlashCmdList.GPEXPORT = slashShowGpExport