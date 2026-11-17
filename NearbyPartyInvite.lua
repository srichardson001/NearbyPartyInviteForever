-- NearbyPartyInvite
-- Lists nearby friendly players, lets you pick a quest, whisper an ask, and invite by button.

local NPI_AddonName, NPI_Addon = ...
NearbyPartyInvite = NPI_Addon

local L = NPI_Addon.L

local NPI_Frame = CreateFrame("Frame")
NPI_Addon.frame = NPI_Frame

NPI_Addon.invited = {}
NPI_Addon.pendingInvites = {}
NPI_Settings = NPI_Settings or {}
if NPI_Settings.whisperEnabled == nil then
    NPI_Settings.whisperEnabled = false
end
NPI_Settings.whisperMessage = NPI_Settings.whisperMessage or ""

local NPI_Verbosity = { none = 0, default = 1, high = 2, debug = 3 }
local NPI_VerbosityTexts = {
    none = L.NONE_VALUE,
    default = L.DEFAULT_VALUE,
    high = L.HIGH_VALUE,
    debug = L.DEBUG_VALUE,
}
local NPI_VerbosityNames = {
    [0] = NPI_VerbosityTexts.none,
    [1] = NPI_VerbosityTexts.default,
    [2] = NPI_VerbosityTexts.high,
    [3] = NPI_VerbosityTexts.debug,
}
if NPI_Settings.verbosity == nil then
    NPI_Settings.verbosity = NPI_Verbosity.default
end

local function NPI_Print(level, msg)
    if type(level) ~= "number" then
        level = NPI_Verbosity.default
    end
    if type(NPI_Settings.verbosity) ~= "number" then
        NPI_Settings.verbosity = NPI_Verbosity.default
    end
    if NPI_Settings.verbosity >= level then
        DEFAULT_CHAT_FRAME:AddMessage(L.ADDON_TITLE .. ": " .. msg)
    end
end

local NPI_PlayerName, NPI_PlayerRealm = UnitName("player")
local NPI_PlayerFullName = NPI_PlayerRealm and NPI_PlayerRealm ~= "" and NPI_PlayerName .. "-" .. NPI_PlayerRealm or NPI_PlayerName
local NPI_PlayerFaction = UnitFactionGroup("player")

local NPI_Options, NPI_SettingsCategory
local NPI_WhisperCheck, NPI_MessageInput
local NPI_Nearby = {}
local NPI_Asks = {}
local NPI_RowOffset = 0
local NPI_MAX_ROWS = 8
local NPI_ROW_HEIGHT = 24
local NPI_Window
local NPI_Rows = {}
local NPI_EmptyText
local NPI_QuestDropDown
local NPI_PlatesWarned = false
local NPI_Ticker

local NPI_YES = {
    yes = true, y = true, yeah = true, yep = true, sure = true, ok = true, okay = true,
}
local NPI_NO = {
    no = true, nope = true, nah = true,
}

local function NPI_UpdatePlayer()
    NPI_PlayerName, NPI_PlayerRealm = UnitName("player")
    NPI_PlayerFullName = NPI_PlayerRealm and NPI_PlayerRealm ~= "" and NPI_PlayerName .. "-" .. NPI_PlayerRealm or NPI_PlayerName
    NPI_PlayerFaction = UnitFactionGroup("player")
end

local function NPI_NameKey(name)
    if type(name) ~= "string" or name == "" then
        return nil
    end
    return (name:gsub("%s+", "")):lower()
end

local function NPI_GetPendingInviteCount()
    local NPI_Count = 0
    for NPI_Name in pairs(NPI_Addon.pendingInvites) do
        if NPI_IsPlayerInGroup(NPI_Name) then
            NPI_Addon.pendingInvites[NPI_Name] = nil
        else
            NPI_Count = NPI_Count + 1
        end
    end
    return NPI_Count
end

local function NPI_IsGroupFull()
    if IsInRaid and IsInRaid() then
        return false
    end
    local NPI_GroupSize = GetNumGroupMembers()
    if NPI_GroupSize == 0 then
        NPI_GroupSize = 1
    end
    NPI_GroupSize = NPI_GroupSize + NPI_GetPendingInviteCount()
    return NPI_GroupSize >= 5
end

function NPI_IsPlayerInGroup(NPI_TargetName)
    if not NPI_TargetName or not IsInGroup() then
        return false
    end

    local NPI_Count = GetNumGroupMembers()
    if IsInRaid() then
        for NPI_Index = 1, NPI_Count do
            local NPI_Unit = "raid" .. NPI_Index
            if UnitExists(NPI_Unit) then
                local NPI_Name, NPI_Realm = UnitName(NPI_Unit)
                local NPI_FullName = NPI_Realm and NPI_Realm ~= "" and NPI_Name .. "-" .. NPI_Realm or NPI_Name
                if NPI_FullName == NPI_TargetName or NPI_Name == NPI_TargetName then
                    return true
                end
            end
        end
    else
        for NPI_Index = 1, math.max(NPI_Count - 1, 0) do
            local NPI_Unit = "party" .. NPI_Index
            if UnitExists(NPI_Unit) then
                local NPI_Name, NPI_Realm = UnitName(NPI_Unit)
                local NPI_FullName = NPI_Realm and NPI_Realm ~= "" and NPI_Name .. "-" .. NPI_Realm or NPI_Name
                if NPI_FullName == NPI_TargetName or NPI_Name == NPI_TargetName then
                    return true
                end
            end
        end
    end

    return false
end

local function NPI_ReadCVar(name)
    local reader = (C_CVar and C_CVar.GetCVar) or GetCVar
    if not reader then
        return nil
    end
    local ok, value = pcall(reader, name)
    if not ok then
        return nil
    end
    if value == "1" or value == 1 or value == true then
        return true
    end
    if value == "0" or value == 0 or value == false then
        return false
    end
    return nil
end

local NPI_PlateCVars = { "nameplateShowFriendlyPlayers", "nameplateShowFriends" }

local function NPI_FriendlyPlatesOn()
    for _, name in ipairs(NPI_PlateCVars) do
        local value = NPI_ReadCVar(name)
        if value ~= nil then
            return value, name
        end
    end
    if GetCVarBool then
        for _, name in ipairs(NPI_PlateCVars) do
            local ok, value = pcall(GetCVarBool, name)
            if ok and value == true then
                return true, name
            end
        end
    end
    return nil, nil
end

function NPI_Addon:EnableFriendlyNameplates()
    if InCombatLockdown() then
        NPI_Print(NPI_Verbosity.default, L.PLATES_COMBAT)
        return
    end
    if UnitIsDeadOrGhost("player") then
        NPI_Print(NPI_Verbosity.default, L.PLATES_DEAD)
        return
    end
    local enabled, name = NPI_FriendlyPlatesOn()
    local setter = (C_CVar and C_CVar.SetCVar) or SetCVar
    if not name or not setter then
        NPI_Print(NPI_Verbosity.default, L.PLATES_UNSUPPORTED)
        return
    end
    if not enabled then
        pcall(setter, name, "1")
    end
    if NPI_FriendlyPlatesOn() ~= true then
        NPI_Print(NPI_Verbosity.default, L.PLATES_FAILED)
        return
    end
    if NPI_ReadCVar("nameplateShowAll") == false then
        pcall(setter, "nameplateShowAll", "1")
        if NPI_ReadCVar("nameplateShowAll") ~= true then
            NPI_Print(NPI_Verbosity.default, L.PLATES_PARTIAL)
            NPI_RefreshWindow()
            return
        end
    end
    NPI_Print(NPI_Verbosity.default, L.PLATES_ON)
    NPI_RefreshWindow()
end

local function NPI_WarnPlates()
    if NPI_PlatesWarned then
        return
    end
    if NPI_FriendlyPlatesOn() == false then
        NPI_PlatesWarned = true
        NPI_Print(NPI_Verbosity.default, L.PLATES_OFF .. " " .. L.PLATES_HINT)
    end
end

local function NPI_DistanceBand(unit)
    local function interact(index)
        if not CheckInteractDistance then
            return false
        end
        local ok, value = pcall(CheckInteractDistance, unit, index)
        return ok and value and true or false
    end
    if interact(3) or interact(2) then
        return 1, L.DISTANCE_10
    end
    if interact(1) or interact(4) then
        return 2, L.DISTANCE_28
    end
    return 3, L.DISTANCE_NEAR
end

local function NPI_FullName(unit)
    local name, realm = UnitName(unit)
    if not name or name == "" then
        return nil, nil
    end
    if not realm or realm == "" then
        return name, name
    end
    return name .. "-" .. realm, name
end

local function NPI_Consider(unit, seen, list)
    if not unit or not UnitExists(unit) or not UnitIsPlayer(unit) then
        return
    end
    if UnitIsUnit(unit, "player") then
        return
    end
    local faction = UnitFactionGroup(unit)
    if not faction or not NPI_PlayerFaction or faction ~= NPI_PlayerFaction then
        return
    end
    local full, short = NPI_FullName(unit)
    if not full then
        return
    end
    if NPI_IsPlayerInGroup(full) or NPI_IsPlayerInGroup(short) then
        return
    end
    local guid = UnitGUID(unit)
    if not guid or seen[guid] then
        return
    end
    seen[guid] = true
    local band, label = NPI_DistanceBand(unit)
    local _, class = UnitClass(unit)
    local ask = NPI_Asks[NPI_NameKey(full)] or NPI_Asks[NPI_NameKey(short)]
    list[#list + 1] = {
        guid = guid,
        unit = unit,
        fullName = full,
        name = short,
        class = class,
        band = band,
        distance = label,
        ask = ask,
    }
end

local function NPI_ExpireAsks()
    local now = GetTime()
    for _, ask in pairs(NPI_Asks) do
        if ask.status == "waiting" and ask.expires and ask.expires <= now then
            ask.status = nil
            ask.expires = nil
        end
    end
end

function NPI_ScanNearby()
    NPI_ExpireAsks()
    local seen = {}
    local list = {}
    for i = 1, 40 do
        NPI_Consider("nameplate" .. i, seen, list)
    end
    NPI_Consider("target", seen, list)
    NPI_Consider("mouseover", seen, list)
    table.sort(list, function(a, b)
        if a.band ~= b.band then
            return a.band < b.band
        end
        return a.name < b.name
    end)
    NPI_Nearby = list
    local maxOffset = math.max(0, #list - NPI_MAX_ROWS)
    if NPI_RowOffset > maxOffset then
        NPI_RowOffset = maxOffset
    end
    if NPI_PaintRows then
        NPI_PaintRows()
    end
end

local function NPI_QuestCount()
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries then
        local ok, count = pcall(C_QuestLog.GetNumQuestLogEntries)
        if ok and type(count) == "number" then
            return count
        end
    end
    if GetNumQuestLogEntries then
        return GetNumQuestLogEntries()
    end
    return 0
end

local function NPI_QuestKey(questID, title)
    if type(questID) == "number" and questID > 0 then
        return "id:" .. questID
    end
    return "title:" .. (title or "")
end

local function NPI_ReadQuest(index)
    if C_QuestLog and C_QuestLog.GetInfo then
        local ok, info = pcall(C_QuestLog.GetInfo, index)
        if ok and type(info) == "table" and not info.isHeader and info.title and info.title ~= "" then
            return info.questID, info.title
        end
        if ok and type(info) == "table" then
            return nil, nil
        end
    end
    if not GetQuestLogTitle then
        return nil, nil
    end
    local title, _, _, isHeader, _, _, _, questID = GetQuestLogTitle(index)
    if isHeader or not title or title == "" then
        return nil, nil
    end
    return questID, title
end

function NPI_GetQuests()
    local quests = {}
    local count = NPI_QuestCount()
    for index = 1, count do
        local questID, title = NPI_ReadQuest(index)
        if title then
            quests[#quests + 1] = {
                id = questID,
                title = title,
                key = NPI_QuestKey(questID, title),
            }
        end
    end
    return quests
end

function NPI_SelectedQuestTitle()
    local key = NPI_Settings.selectedQuestKey
    if not key then
        return nil
    end
    local quests = NPI_GetQuests()
    if #quests == 0 then
        return NPI_Settings.selectedQuestTitle
    end
    for _, quest in ipairs(quests) do
        if quest.key == key then
            NPI_Settings.selectedQuestTitle = quest.title
            return quest.title
        end
    end
    return nil
end

local function NPI_SyncQuestDropdown()
    if not NPI_QuestDropDown then
        return
    end
    local quests = NPI_GetQuests()
    local found
    for _, quest in ipairs(quests) do
        if quest.key == NPI_Settings.selectedQuestKey then
            found = quest
            break
        end
    end
    if found then
        NPI_Settings.selectedQuestTitle = found.title
        UIDropDownMenu_SetSelectedValue(NPI_QuestDropDown, found.key)
        UIDropDownMenu_SetText(NPI_QuestDropDown, found.title)
    elseif #quests > 0 then
        NPI_Settings.selectedQuestKey = nil
        NPI_Settings.selectedQuestTitle = nil
        UIDropDownMenu_SetSelectedValue(NPI_QuestDropDown, nil)
        UIDropDownMenu_SetText(NPI_QuestDropDown, L.NO_QUESTS)
    else
        UIDropDownMenu_SetText(NPI_QuestDropDown, L.NO_QUESTS)
    end
    if NPI_PaintRows then
        NPI_PaintRows()
    end
end

local function NPI_QuestDropdown_OnClick(button)
    local key = button.value
    local title
    for _, quest in ipairs(NPI_GetQuests()) do
        if quest.key == key then
            title = quest.title
            break
        end
    end
    NPI_Settings.selectedQuestKey = key
    NPI_Settings.selectedQuestTitle = title
    UIDropDownMenu_SetSelectedValue(NPI_QuestDropDown, key)
    UIDropDownMenu_SetText(NPI_QuestDropDown, title or L.NO_QUESTS)
    NPI_PaintRows()
end

local function NPI_QuestDropdown_Initialize()
    local quests = NPI_GetQuests()
    if #quests == 0 then
        local info = UIDropDownMenu_CreateInfo()
        info.text = L.NO_QUESTS
        info.disabled = true
        UIDropDownMenu_AddButton(info)
        return
    end
    for _, quest in ipairs(quests) do
        local title = quest.title
        local key = quest.key
        local info = UIDropDownMenu_CreateInfo()
        info.text = title
        info.value = key
        info.func = NPI_QuestDropdown_OnClick
        info.checked = (NPI_Settings.selectedQuestKey == key)
        UIDropDownMenu_AddButton(info)
    end
end

local NPI_NEAR_YARDS = 250
local NPI_WHISPER_LIMIT = 255
local NPI_NearbyQuests = {}
local NPI_FocusedTitle
local NPI_NearbyQuestText

local function NPI_DonNS()
    if type(DonData) ~= "table" or type(DonData.ns) ~= "table" then
        return nil
    end
    local ns = DonData.ns
    if type(ns.AvailableQuestsOnMap) ~= "function" or type(ns.DistanceFrom) ~= "function" or type(ns.PlayerWorld) ~= "function" then
        return nil
    end
    return ns
end

local function NPI_SelectedQuestID()
    local key = NPI_Settings and NPI_Settings.selectedQuestKey
    if type(key) ~= "string" then
        return nil
    end
    return tonumber(key:match("^id:(%d+)$"))
end

local function NPI_TitleForQuest(questID)
    if type(questID) ~= "number" then
        return nil
    end
    if type(DonDataAPI) == "table" and type(DonDataAPI.QuestTitle) == "function" then
        local ok, title = pcall(DonDataAPI.QuestTitle, questID)
        if ok and type(title) == "string" and title ~= "" then
            return title
        end
    end
    local ns = type(DonData) == "table" and DonData.ns
    if type(ns) == "table" and type(ns.QuestTitle) == "function" then
        local ok, title = pcall(ns.QuestTitle, questID)
        if ok and type(title) == "string" and title ~= "" then
            return title
        end
    end
    return nil
end

local function NPI_FocusedQuest()
    local title = NPI_SelectedQuestTitle()
    if type(title) == "string" and title ~= "" then
        return title, NPI_SelectedQuestID()
    end
    local ns = type(DonData) == "table" and DonData.ns
    if type(ns) ~= "table" or type(ns.TrackerFocusID) ~= "function" then
        return nil, nil
    end
    local ok, questID = pcall(ns.TrackerFocusID)
    questID = ok and tonumber(questID) or nil
    if not questID then
        return nil, nil
    end
    local focusTitle = NPI_TitleForQuest(questID)
    if not focusTitle then
        return nil, nil
    end
    return focusTitle, questID
end

local function NPI_PlayerMap()
    if not C_Map or type(C_Map.GetBestMapForUnit) ~= "function" then
        return nil
    end
    local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok then
        return nil
    end
    return tonumber(mapID)
end

local function NPI_AvailableDistance(ns, mapID, x, y)
    local ok, pc, pn, pw = pcall(ns.PlayerWorld)
    if not ok or not pc then
        return nil
    end
    local measured, dist = pcall(ns.DistanceFrom, pc, pn, pw, { mapID = mapID, x = x, y = y })
    if measured and type(dist) == "number" then
        return dist
    end
    return nil
end

local function NPI_LogQuestDistance(questID)
    local api = DonDataAPI
    if type(api) ~= "table" or type(api.DistanceTo) ~= "function" then
        return nil
    end
    local best
    local function consider(mapID, x, y)
        if not mapID or not x or not y then
            return
        end
        local ok, dist = pcall(api.DistanceTo, mapID, x, y)
        if ok and type(dist) == "number" and (not best or dist < best) then
            best = dist
        end
    end
    if type(api.ObjectivePoints) == "function" then
        local ok, points = pcall(api.ObjectivePoints, questID)
        if ok and type(points) == "table" then
            for _, point in ipairs(points) do
                if type(point) == "table" then
                    consider(point.mapID, point.x, point.y)
                end
            end
        end
    end
    if type(api.QuestPOI) == "function" then
        local ok, mapID, x, y = pcall(api.QuestPOI, questID)
        if ok then
            consider(mapID, x, y)
        end
    end
    return best
end

local function NPI_CollectNearby(focusedTitle, focusedID)
    local list = {}
    local seen = {}
    local function add(questID, title, dist)
        if type(title) ~= "string" or title == "" then
            return
        end
        if type(dist) ~= "number" or dist > NPI_NEAR_YARDS then
            return
        end
        if focusedID and questID == focusedID then
            return
        end
        if focusedTitle and title == focusedTitle then
            return
        end
        local key = questID or title:lower()
        local prev = seen[key]
        if prev then
            if dist < prev.dist then
                prev.dist = dist
            end
            return
        end
        local entry = { questID = questID, title = title, dist = dist }
        seen[key] = entry
        list[#list + 1] = entry
    end

    local ns = NPI_DonNS()
    if not ns then
        return list
    end

    local mapID = NPI_PlayerMap()
    if mapID then
        local ok, available = pcall(ns.AvailableQuestsOnMap, mapID)
        if ok and type(available) == "table" then
            for _, quest in ipairs(available) do
                if type(quest) == "table" and not quest.dimmed and quest.x and quest.y then
                    local questID = tonumber(quest.questID)
                    add(questID, NPI_TitleForQuest(questID), NPI_AvailableDistance(ns, mapID, quest.x, quest.y))
                end
            end
        end
    end

    for _, quest in ipairs(NPI_GetQuests()) do
        local questID = tonumber(quest.id)
        if questID then
            add(questID, quest.title, NPI_LogQuestDistance(questID))
        end
    end

    table.sort(list, function(a, b)
        if a.dist ~= b.dist then
            return a.dist < b.dist
        end
        return a.title < b.title
    end)
    return list
end

local function NPI_JoinTitles(focused, nearby)
    local parts = {}
    if type(focused) == "string" and focused ~= "" then
        parts[#parts + 1] = focused
    end
    for _, quest in ipairs(nearby) do
        if type(quest.title) == "string" and quest.title ~= "" then
            parts[#parts + 1] = quest.title
        end
    end
    return parts
end

local function NPI_PlaceQuestLine()
    if not NPI_Window then
        return
    end
    local showLine = NPI_DonNS() ~= nil
    NPI_Window:SetHeight(showLine and 320 or 280)
    local top = showLine and -116 or -88
    for i = 1, NPI_MAX_ROWS do
        local row = NPI_Rows[i]
        if row then
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", 16, top - (i - 1) * NPI_ROW_HEIGHT)
        end
    end
    if NPI_EmptyText then
        NPI_EmptyText:ClearAllPoints()
        NPI_EmptyText:SetPoint("TOPLEFT", 24, top - 12)
        NPI_EmptyText:SetPoint("TOPRIGHT", -24, top - 12)
    end
    if not NPI_NearbyQuestText then
        return
    end
    if not showLine then
        NPI_NearbyQuestText:Hide()
        return
    end
    NPI_NearbyQuestText:Show()
    local parts = NPI_JoinTitles(NPI_FocusedTitle, NPI_NearbyQuests)
    if #parts == 0 then
        NPI_NearbyQuestText:SetText(L.NO_NEARBY_QUESTS)
    else
        NPI_NearbyQuestText:SetText(string.format(L.NEARBY_QUESTS, table.concat(parts, ", ")))
    end
end

local function NPI_RefreshNearbyQuests()
    local title, questID = NPI_FocusedQuest()
    NPI_FocusedTitle = title
    if NPI_DonNS() then
        NPI_NearbyQuests = NPI_CollectNearby(title, questID)
    else
        NPI_NearbyQuests = {}
    end
    NPI_PlaceQuestLine()
end

local function NPI_AskText(title)
    local custom = NPI_Settings.whisperEnabled and NPI_Settings.whisperMessage or ""
    if custom ~= "" then
        return (custom:gsub("%%s", function()
            return title
        end))
    end
    return string.format(L.ASK_DEFAULT, title)
end

local function NPI_MessageFor(titles)
    return NPI_AskText(table.concat(titles, ", "))
end

local function NPI_FitTitles(titles)
    local kept = {}
    for i, title in ipairs(titles) do
        kept[i] = title
    end
    if #kept == 0 then
        return nil, nil
    end
    while #kept > 1 and #NPI_MessageFor(kept) > NPI_WHISPER_LIMIT do
        kept[#kept] = nil
    end
    if #NPI_MessageFor(kept) <= NPI_WHISPER_LIMIT then
        return NPI_MessageFor(kept), table.concat(kept, ", ")
    end
    local title = kept[1]
    local low, high, best = 1, #title, nil
    while low <= high do
        local mid = math.floor((low + high) / 2)
        local candidate = title:sub(1, mid)
        if #NPI_MessageFor({ candidate }) <= NPI_WHISPER_LIMIT then
            best = candidate
            low = mid + 1
        else
            high = mid - 1
        end
    end
    if not best or best == "" then
        return nil, nil
    end
    return NPI_MessageFor({ best }), best
end

local function NPI_RememberAsk(full, short, title)
    local ask = {
        status = "waiting",
        expires = GetTime() + 120,
        quest = title,
        fullName = full,
        name = short,
    }
    local fullKey = NPI_NameKey(full)
    local shortKey = NPI_NameKey(short)
    if fullKey then
        NPI_Asks[fullKey] = ask
    end
    if shortKey then
        NPI_Asks[shortKey] = ask
    end
end

function NPI_AskPlayer(entry)
    NPI_RefreshNearbyQuests()
    local titles = NPI_JoinTitles(NPI_FocusedTitle, NPI_NearbyQuests)
    if #titles == 0 then
        NPI_Print(NPI_Verbosity.default, L.NO_QUEST_SELECTED)
        return
    end
    local message, shown = NPI_FitTitles(titles)
    if not message or message == "" then
        NPI_Print(NPI_Verbosity.default, L.NO_QUEST_SELECTED)
        return
    end
    SendChatMessage(message, "WHISPER", nil, entry.fullName)
    NPI_RememberAsk(entry.fullName, entry.name, shown)
    NPI_Print(NPI_Verbosity.default, string.format(L.ASK_SENT, entry.name, shown))
    NPI_ScanNearby()
end

function NPI_InvitePlayer(entry)
    if NPI_IsPlayerInGroup(entry.fullName) or NPI_IsPlayerInGroup(entry.name) then
        NPI_Print(NPI_Verbosity.default, string.format(L.ALREADY_IN_GROUP, entry.name))
        NPI_ScanNearby()
        return
    end
    if NPI_IsGroupFull() then
        NPI_Print(NPI_Verbosity.default, L.GROUP_FULL)
        return
    end
    InviteUnit(entry.fullName)
    NPI_Addon.invited[entry.fullName] = true
    NPI_Addon.pendingInvites[entry.fullName] = true
    local invitedName = entry.fullName
    if C_Timer and C_Timer.After then
        C_Timer.After(60, function()
            if not NPI_IsPlayerInGroup(invitedName) then
                NPI_Addon.pendingInvites[invitedName] = nil
            end
        end)
    end
    NPI_Print(NPI_Verbosity.default, string.format(L.INVITED, entry.name))
end

local function NPI_FindAsk(sender)
    local key = NPI_NameKey(sender)
    if key and NPI_Asks[key] then
        return NPI_Asks[key]
    end
    local short = type(sender) == "string" and sender:match("^([^%-]+)") or nil
    local shortKey = NPI_NameKey(short)
    if shortKey and NPI_Asks[shortKey] then
        return NPI_Asks[shortKey]
    end
end

local function NPI_FirstWord(message)
    if type(message) ~= "string" then
        return nil
    end
    return message:lower():match("^%s*([%a]+)")
end

function NPI_PaintRows()
    if not NPI_Window then
        return
    end
    NPI_RefreshNearbyQuests()
    local count = #NPI_Nearby
    for i = 1, NPI_MAX_ROWS do
        local row = NPI_Rows[i]
        local entry = NPI_Nearby[NPI_RowOffset + i]
        if entry then
            row:Show()
            row.entry = entry
            local color = RAID_CLASS_COLORS and entry.class and RAID_CLASS_COLORS[entry.class]
            if color then
                row.name:SetTextColor(color.r, color.g, color.b)
            else
                row.name:SetTextColor(1, 1, 1)
            end
            row.name:SetText(entry.name)
            row.distance:SetText(entry.distance)
            local status = entry.ask and entry.ask.status
            if status == "waiting" then
                row.status:SetText(L.STATUS_WAITING)
            elseif status == "yes" then
                row.status:SetText(L.STATUS_ACCEPTED)
            elseif status == "no" then
                row.status:SetText(L.STATUS_DECLINED)
            else
                row.status:SetText("")
            end
            local canAsk = (type(NPI_FocusedTitle) == "string" and NPI_FocusedTitle ~= "") or #NPI_NearbyQuests > 0
            row.ask:SetEnabled(canAsk and status ~= "waiting")
            row.invite:SetEnabled(true)
        else
            row:Hide()
            row.entry = nil
        end
    end
    if count == 0 then
        if NPI_FriendlyPlatesOn() == false then
            NPI_EmptyText:SetText(L.PLATES_OFF .. " " .. L.PLATES_HINT)
        else
            NPI_EmptyText:SetText(L.EMPTY_NEARBY)
        end
        NPI_EmptyText:Show()
    else
        NPI_EmptyText:Hide()
    end
end

function NPI_RefreshWindow()
    NPI_SyncQuestDropdown()
    NPI_ScanNearby()
end

local function NPI_SaveWindowPosition()
    if not NPI_Window then
        return
    end
    local point, _, rel, x, y = NPI_Window:GetPoint(1)
    NPI_Settings.window = { point = point, rel = rel, x = x, y = y }
end

local function NPI_ToggleWindow()
    if not NPI_Window then
        return
    end
    if NPI_Window:IsShown() then
        NPI_Window:Hide()
    else
        NPI_Window:Show()
        NPI_RefreshWindow()
    end
end

local function NPI_CreateWindow()
    local backdrop = {
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true,
        tileSize = 32,
        edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    }
    local window = CreateFrame("Frame", "NPI_NearbyFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    NPI_Window = window
    window:SetSize(380, 280)
    window:SetFrameStrata("MEDIUM")
    window:SetClampedToScreen(true)
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)
    window:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        NPI_SaveWindowPosition()
    end)
    if window.SetBackdrop then
        window:SetBackdrop(backdrop)
    end
    local saved = NPI_Settings.window
    if saved and saved.point then
        window:SetPoint(saved.point, UIParent, saved.rel or saved.point, saved.x or 0, saved.y or 0)
    else
        window:SetPoint("CENTER")
    end

    local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -14)
    title:SetText(L.ADDON_TITLE)

    local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function()
        window:Hide()
    end)

    local questLabel = window:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    questLabel:SetPoint("TOPLEFT", 20, -36)
    questLabel:SetText(L.QUEST)

    NPI_QuestDropDown = CreateFrame("Frame", "NPI_QuestDropDown", window, "UIDropDownMenuTemplate")
    NPI_QuestDropDown:SetPoint("TOPLEFT", questLabel, "BOTTOMLEFT", -16, -2)
    UIDropDownMenu_SetWidth(NPI_QuestDropDown, 200)
    UIDropDownMenu_Initialize(NPI_QuestDropDown, NPI_QuestDropdown_Initialize)
    UIDropDownMenu_SetText(NPI_QuestDropDown, L.NO_QUESTS)

    NPI_NearbyQuestText = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    NPI_NearbyQuestText:SetPoint("TOPLEFT", 20, -78)
    NPI_NearbyQuestText:SetWidth(340)
    NPI_NearbyQuestText:SetJustifyH("LEFT")
    NPI_NearbyQuestText:SetWordWrap(true)
    NPI_NearbyQuestText:SetText("")
    NPI_NearbyQuestText:Hide()

    NPI_EmptyText = window:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    NPI_EmptyText:SetPoint("TOPLEFT", 24, -100)
    NPI_EmptyText:SetPoint("TOPRIGHT", -24, -100)
    NPI_EmptyText:SetJustifyH("CENTER")
    NPI_EmptyText:SetText(L.EMPTY_NEARBY)

    window:EnableMouseWheel(true)
    window:SetScript("OnMouseWheel", function(_, delta)
        NPI_RowOffset = NPI_RowOffset - delta
        if NPI_RowOffset < 0 then
            NPI_RowOffset = 0
        end
        local maxOffset = math.max(0, #NPI_Nearby - NPI_MAX_ROWS)
        if NPI_RowOffset > maxOffset then
            NPI_RowOffset = maxOffset
        end
        NPI_PaintRows()
    end)

    for i = 1, NPI_MAX_ROWS do
        local row = CreateFrame("Frame", nil, window)
        row:SetSize(348, NPI_ROW_HEIGHT)
        row:SetPoint("TOPLEFT", 16, -88 - (i - 1) * NPI_ROW_HEIGHT)
        local bg = row:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        if bg.SetColorTexture then
            bg:SetColorTexture(1, 1, 1, i % 2 == 0 and 0.04 or 0.08)
        else
            bg:SetTexture("Interface\\Buttons\\WHITE8X8")
            bg:SetVertexColor(1, 1, 1, i % 2 == 0 and 0.04 or 0.08)
        end

        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.name:SetPoint("LEFT", 6, 0)
        row.name:SetWidth(120)
        row.name:SetJustifyH("LEFT")
        row.name:SetWordWrap(false)

        row.distance = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.distance:SetPoint("LEFT", row.name, "RIGHT", 4, 0)
        row.distance:SetWidth(36)
        row.distance:SetJustifyH("LEFT")

        row.status = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        row.status:SetPoint("LEFT", row.distance, "RIGHT", 2, 0)
        row.status:SetWidth(36)
        row.status:SetJustifyH("LEFT")

        row.ask = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.ask:SetSize(64, 20)
        row.ask:SetPoint("LEFT", row.status, "RIGHT", 4, 0)
        row.ask:SetText(L.ASK)
        row.ask:SetScript("OnClick", function(self)
            if self:GetParent().entry then
                NPI_AskPlayer(self:GetParent().entry)
            end
        end)

        row.invite = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
        row.invite:SetSize(70, 20)
        row.invite:SetPoint("LEFT", row.ask, "RIGHT", 4, 0)
        row.invite:SetText(L.INVITE)
        row.invite:SetScript("OnClick", function(self)
            if self:GetParent().entry then
                NPI_InvitePlayer(self:GetParent().entry)
            end
        end)

        row:Hide()
        NPI_Rows[i] = row
    end

    window:Hide()
    NPI_SyncQuestDropdown()
end

function NPI_Frame:NAME_PLATE_UNIT_ADDED()
    NPI_ScanNearby()
end

function NPI_Frame:NAME_PLATE_UNIT_REMOVED()
    NPI_ScanNearby()
end

function NPI_Frame:UPDATE_MOUSEOVER_UNIT()
    NPI_ScanNearby()
end

function NPI_Frame:PLAYER_TARGET_CHANGED()
    NPI_ScanNearby()
end

function NPI_Frame:QUEST_LOG_UPDATE()
    NPI_SyncQuestDropdown()
end

function NPI_Frame:CHAT_MSG_WHISPER(message, sender)
    local ask = NPI_FindAsk(sender)
    if not ask or ask.status ~= "waiting" then
        return
    end
    local word = NPI_FirstWord(message)
    if word and NPI_YES[word] then
        ask.status = "yes"
        ask.expires = nil
        NPI_Print(NPI_Verbosity.default, string.format(L.REPLY_ACCEPTED, ask.name or sender))
    elseif word and NPI_NO[word] then
        ask.status = "no"
        ask.expires = nil
        local target = ask.fullName or sender
        if type(target) == "string" and target ~= "" and type(L.REPLY_THANKS) == "string" and L.REPLY_THANKS ~= "" then
            SendChatMessage(L.REPLY_THANKS, "WHISPER", nil, target)
        end
        NPI_Print(NPI_Verbosity.default, string.format(L.REPLY_DECLINED, ask.name or sender))
    end
    NPI_PaintRows()
end

function NPI_Frame:CHAT_MSG_SYSTEM(msg)
    for NPI_Name in pairs(NPI_Addon.pendingInvites) do
        if msg == ERR_DECLINE_GROUP_S:format(NPI_Name) or msg == ERR_ALREADY_IN_GROUP_S:format(NPI_Name) then
            NPI_Addon.pendingInvites[NPI_Name] = nil
            break
        end
    end
end

function NPI_Frame:GROUP_ROSTER_UPDATE()
    for NPI_Name in pairs(NPI_Addon.pendingInvites) do
        if NPI_IsPlayerInGroup(NPI_Name) then
            NPI_Addon.pendingInvites[NPI_Name] = nil
        end
    end
    NPI_ScanNearby()
end

function NPI_Frame:CVAR_UPDATE(name)
    if type(name) == "string" then
        local lower = name:lower()
        if lower == "nameplateshowfriendlyplayers" or lower == "nameplateshowfriends" or lower == "nameplateshowall" then
            NPI_PaintRows()
        end
    end
end

function NPI_Frame:PLAYER_LOGIN()
    NPI_UpdatePlayer()
    NPI_WarnPlates()
    NPI_RefreshWindow()
    if not NPI_Ticker and C_Timer and C_Timer.NewTicker then
        NPI_Ticker = C_Timer.NewTicker(0.5, NPI_ScanNearby)
    end
end

function NPI_Frame:PLAYER_ENTERING_WORLD()
    NPI_UpdatePlayer()
    NPI_RefreshWindow()
end

NPI_Frame:SetScript("OnEvent", function(self, event, ...)
    if self[event] then
        self[event](self, ...)
    end
end)

local function NPI_TryRegister(event)
    pcall(NPI_Frame.RegisterEvent, NPI_Frame, event)
end

NPI_TryRegister("PLAYER_LOGIN")
NPI_TryRegister("PLAYER_ENTERING_WORLD")
NPI_TryRegister("NAME_PLATE_UNIT_ADDED")
NPI_TryRegister("NAME_PLATE_UNIT_REMOVED")
NPI_TryRegister("UPDATE_MOUSEOVER_UNIT")
NPI_TryRegister("PLAYER_TARGET_CHANGED")
NPI_TryRegister("QUEST_LOG_UPDATE")
NPI_TryRegister("CHAT_MSG_WHISPER")
NPI_TryRegister("CHAT_MSG_SYSTEM")
NPI_TryRegister("GROUP_ROSTER_UPDATE")
NPI_TryRegister("CVAR_UPDATE")

if not C_Timer or not C_Timer.NewTicker then
    local elapsed = 0
    NPI_Frame:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed < 0.5 then
            return
        end
        elapsed = 0
        NPI_ScanNearby()
    end)
end

NPI_CreateWindow()

local NPI_MinimapButton = CreateFrame("Button", "NPI_MinimapButton", Minimap)
NPI_Addon.minimapButton = NPI_MinimapButton
NPI_MinimapButton:SetFrameStrata("MEDIUM")
NPI_MinimapButton:SetSize(31, 31)
NPI_MinimapButton:SetFrameLevel(8)
NPI_MinimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
NPI_MinimapButton:SetPoint("TOPLEFT", Minimap, "TOPLEFT")

local NPI_MinimapOverlay = NPI_MinimapButton:CreateTexture(nil, "OVERLAY")
NPI_MinimapOverlay:SetSize(53, 53)
NPI_MinimapOverlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
NPI_MinimapOverlay:SetPoint("TOPLEFT")

local NPI_MinimapIcon = NPI_MinimapButton:CreateTexture(nil, "BACKGROUND")
NPI_MinimapButton.icon = NPI_MinimapIcon
NPI_MinimapIcon:SetTexture("Interface\\AddOns\\NearbyPartyInvite\\NearbyPartyInvite_icon")
NPI_MinimapIcon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
NPI_MinimapIcon:SetSize(20, 20)
NPI_MinimapIcon:SetPoint("CENTER")

NPI_MinimapButton:SetScript("OnClick", function(_, button)
    if button == "LeftButton" then
        NPI_ToggleWindow()
    end
end)

NPI_MinimapButton:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(L.ADDON_TITLE)
    GameTooltip:AddLine(L.MINIMAP_TOOLTIP, 1, 1, 1)
    GameTooltip:Show()
end)

NPI_MinimapButton:SetScript("OnLeave", function()
    GameTooltip:Hide()
end)

NPI_Options = CreateFrame("Frame", "NPI_Options")
NPI_Options.name = L.ADDON_TITLE

NPI_WhisperCheck = CreateFrame("CheckButton", "NPI_WhisperCheck", NPI_Options, "InterfaceOptionsCheckButtonTemplate")
NPI_WhisperCheck:SetPoint("TOPLEFT", 16, -16)
NPI_WhisperCheck.Text:SetText(L.ENABLE_WHISPER_MESSAGE)
NPI_WhisperCheck:SetChecked(NPI_Settings.whisperEnabled)

NPI_MessageInput = CreateFrame("EditBox", "NPI_MessageInput", NPI_Options, "InputBoxTemplate")
NPI_MessageInput:SetSize(260, 25)
NPI_MessageInput:SetAutoFocus(false)
NPI_MessageInput:SetPoint("TOPLEFT", NPI_WhisperCheck, "BOTTOMLEFT", 30, -8)
NPI_MessageInput:SetText(NPI_Settings.whisperMessage)
NPI_MessageInput:SetScript("OnEnterPressed", function(self)
    NPI_Settings.whisperMessage = self:GetText()
    self:ClearFocus()
end)
NPI_MessageInput:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
end)
NPI_MessageInput:SetScript("OnEditFocusLost", function(self)
    NPI_Settings.whisperMessage = self:GetText()
end)

local function NPI_UpdateMessageInput()
    if NPI_WhisperCheck:GetChecked() then
        NPI_MessageInput:Show()
    else
        NPI_MessageInput:Hide()
    end
end

NPI_WhisperCheck:SetScript("OnClick", function(self)
    NPI_Settings.whisperEnabled = self:GetChecked()
    NPI_UpdateMessageInput()
end)

NPI_UpdateMessageInput()

local NPI_WhisperHint = NPI_Options:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
NPI_WhisperHint:SetPoint("TOPLEFT", NPI_MessageInput, "BOTTOMLEFT", -10, -6)
NPI_WhisperHint:SetText(L.WHISPER_HINT)
NPI_WhisperHint:SetJustifyH("LEFT")

local NPI_VerbosityDropDown = CreateFrame("Frame", "NPI_VerbosityDropDown", NPI_Options, "UIDropDownMenuTemplate")
NPI_VerbosityDropDown:SetPoint("TOPLEFT", NPI_WhisperHint, "BOTTOMLEFT", -16, -16)
UIDropDownMenu_SetWidth(NPI_VerbosityDropDown, 120)
UIDropDownMenu_SetText(NPI_VerbosityDropDown, L.VERBOSITY)

local function NPI_VerbosityDropDown_OnClick(self)
    UIDropDownMenu_SetSelectedValue(NPI_VerbosityDropDown, self.value)
    NPI_Settings.verbosity = self.value
end

local function NPI_VerbosityDropDown_Initialize()
    local info = UIDropDownMenu_CreateInfo()
    info.func = NPI_VerbosityDropDown_OnClick

    info.text = L.NONE_LABEL
    info.value = NPI_Verbosity.none
    info.checked = (NPI_Settings.verbosity == NPI_Verbosity.none)
    UIDropDownMenu_AddButton(info)

    info = UIDropDownMenu_CreateInfo()
    info.func = NPI_VerbosityDropDown_OnClick
    info.text = L.DEFAULT_LABEL
    info.value = NPI_Verbosity.default
    info.checked = (NPI_Settings.verbosity == NPI_Verbosity.default)
    UIDropDownMenu_AddButton(info)

    info = UIDropDownMenu_CreateInfo()
    info.func = NPI_VerbosityDropDown_OnClick
    info.text = L.HIGH_LABEL
    info.value = NPI_Verbosity.high
    info.checked = (NPI_Settings.verbosity == NPI_Verbosity.high)
    UIDropDownMenu_AddButton(info)

    info = UIDropDownMenu_CreateInfo()
    info.func = NPI_VerbosityDropDown_OnClick
    info.text = L.DEBUG_LABEL
    info.value = NPI_Verbosity.debug
    info.checked = (NPI_Settings.verbosity == NPI_Verbosity.debug)
    UIDropDownMenu_AddButton(info)
end

UIDropDownMenu_Initialize(NPI_VerbosityDropDown, NPI_VerbosityDropDown_Initialize)
UIDropDownMenu_SetSelectedValue(NPI_VerbosityDropDown, NPI_Settings.verbosity)
local NPI_VerbosityLabel = NPI_Options:CreateFontString(nil, "OVERLAY", "GameFontNormal")
NPI_VerbosityLabel:SetPoint("BOTTOMLEFT", NPI_VerbosityDropDown, "TOPLEFT", 16, 3)
NPI_VerbosityLabel:SetText(L.VERBOSITY)

NPI_Options:HookScript("OnShow", function()
    NPI_WhisperCheck:SetChecked(NPI_Settings.whisperEnabled)
    NPI_MessageInput:SetText(NPI_Settings.whisperMessage)
    NPI_UpdateMessageInput()
    UIDropDownMenu_SetSelectedValue(NPI_VerbosityDropDown, NPI_Settings.verbosity)
    UIDropDownMenu_SetText(NPI_VerbosityDropDown, string.gsub(NPI_VerbosityNames[NPI_Settings.verbosity], "^%l", string.upper))
end)
if Settings and Settings.RegisterAddOnCategory then
    NPI_SettingsCategory = Settings.RegisterCanvasLayoutCategory(NPI_Options, NPI_Options.name)
    NPI_SettingsCategory.ID = NPI_Options.name
    Settings.RegisterAddOnCategory(NPI_SettingsCategory)
else
    InterfaceOptions_AddCategory(NPI_Options)
end

SLASH_NPI1 = "/npi"
SlashCmdList["NPI"] = function(NPI_Command)
    local NPI_Cmd, NPI_Rest = (NPI_Command or ""):match("^(%S*)%s*(.-)$")
    NPI_Cmd = string.lower(NPI_Cmd or "")
    if NPI_Cmd == "" or NPI_Cmd == "toggle" or NPI_Cmd == "show" then
        NPI_ToggleWindow()
    elseif NPI_Cmd == "status" then
        local title = NPI_SelectedQuestTitle() or L.NONE_VALUE
        NPI_Print(NPI_Verbosity.default, string.format(L.NEARBY_STATUS, #NPI_Nearby, title))
    elseif NPI_Cmd == "plates" then
        NPI_Addon:EnableFriendlyNameplates()
    elseif NPI_Cmd == "message" then
        if NPI_Rest == "" then
            if NPI_Settings.whisperEnabled and NPI_Settings.whisperMessage ~= "" then
                NPI_Print(NPI_Verbosity.default, string.format(L.CURRENT_WHISPER_MESSAGE, NPI_Settings.whisperMessage))
            else
                NPI_Print(NPI_Verbosity.default, L.NO_WHISPER_MESSAGE)
            end
        else
            NPI_Settings.whisperMessage = NPI_Rest
            NPI_Settings.whisperEnabled = true
            if NPI_WhisperCheck then
                NPI_WhisperCheck:SetChecked(true)
                NPI_MessageInput:SetText(NPI_Rest)
                NPI_UpdateMessageInput()
            end
            NPI_Print(NPI_Verbosity.default, string.format(L.WHISPER_MESSAGE_SET, NPI_Rest))
        end
    elseif NPI_Cmd == "verbosity" then
        if NPI_Rest == "" then
            NPI_Print(NPI_Verbosity.default, string.format(L.CURRENT_VERBOSITY, NPI_VerbosityNames[NPI_Settings.verbosity]))
        else
            local level = string.lower(NPI_Rest)
            if NPI_Verbosity[level] then
                NPI_Settings.verbosity = NPI_Verbosity[level]
                NPI_Print(NPI_Verbosity.default, string.format(L.VERBOSITY_SET, NPI_VerbosityTexts[level] or level))
            else
                NPI_Print(NPI_Verbosity.default, L.INVALID_VERBOSITY_LEVEL)
            end
        end
    else
        NPI_Print(NPI_Verbosity.default, L.COMMANDS)
    end
end
