--[[
  BetterBags Companion
  Companion for BetterBags:
    1. A Bank tab immediately to the right of the Backpack tab. It shows the
       character's bank from anywhere, using a snapshot taken the last time
       the bank was open (the client will not read bank slots otherwise).
    2. An account-wide item database. Item tooltips list the total and how
       many each character holds, split by bags, bank, mailbox, and equipped.
    3. An account search box on the right side of the backpack title bar.
       Matches list quantity per character.
    4. ItemRack sets as BetterBags categories, through C_ItemRackSet.
]]

local ADDON = ...

local BANK_TAB_ID = 900000

local CLASS_COLORS = {
  WARRIOR = "C79C6E",
  PALADIN = "F58CBA",
  HUNTER = "ABD473",
  ROGUE = "FFF569",
  PRIEST = "FFFFFF",
  DEATHKNIGHT = "C41E3A",
  SHAMAN = "0070DE",
  MAGE = "69CCF0",
  WARLOCK = "9482C9",
  MONK = "00FF96",
  DRUID = "FF7D0A",
  DEMONHUNTER = "A330C9",
  EVOKER = "33937F",
}

local db
local index = {}
local pendingInfo = {}
local viewingBank = false
local viewCharKey
local boundBag
local searchEdit
local resultsFrame
local bankOverlay
local modeStrip

local eventFrame = CreateFrame("Frame")

local function copyDefaults()
  if type(BetterBagsCompanionDB) ~= "table" and type(BetterBagsEnhancedDB) == "table" then
    BetterBagsCompanionDB = BetterBagsEnhancedDB
  end
  BetterBagsEnhancedDB = nil
  BetterBagsCompanionDB = BetterBagsCompanionDB or {}
  BetterBagsCompanionDB.chars = BetterBagsCompanionDB.chars or {}
  db = BetterBagsCompanionDB
end

local function surnameSeparator()
  local consts = Constants and Constants.CharacterNameSeparatorConsts
  local sep = consts and consts.CHARACTERNAME_SURNAME_SEPARATOR
  if type(sep) == "string" and sep ~= "" then
    return sep
  end
  return " "
end

-- Forever returns the surname as UnitName's second value, where other clients
-- return a realm. A name that already contains the separator is the full name.
local function playerKey()
  local readName = UnitNameUnmodified or UnitName
  if not readName then
    return nil
  end
  local name, second = readName("player")
  local realm = GetRealmName() or ""
  if type(name) ~= "string" or name == "" or name == "Unknown" then
    return nil
  end
  local sep = surnameSeparator()
  local full = name
  if not name:find(sep, 1, true) and type(second) == "string" and second ~= "" and second ~= realm then
    full = name .. sep .. second
  end
  return full .. "-" .. realm, full, realm
end

-- Older snapshots were keyed by first name only, so two characters who shared
-- a first name wrote into one record. Move that record to the full name of
-- the character now logged in when they do not already have their own.
local function adoptFirstNameRecord(key, full, realm)
  local sep = surnameSeparator()
  local splitAt = full:find(sep, 1, true)
  if not splitAt then
    return
  end
  local oldKey = full:sub(1, splitAt - 1) .. "-" .. realm
  if oldKey == key or not db.chars[oldKey] or db.chars[key] then
    return
  end
  db.chars[key] = db.chars[oldKey]
  db.chars[oldKey] = nil
  if viewCharKey == oldKey then
    viewCharKey = key
  end
end

local function currentChar()
  local key, name, realm = playerKey()
  if not key then
    return nil
  end
  adoptFirstNameRecord(key, name, realm)
  local char = db.chars[key]
  if not char then
    local _, classFile = UnitClass("player")
    char = {
      name = name,
      realm = realm,
      class = classFile,
      bags = {},
      bank = {},
      mail = {},
      equipped = {},
    }
    db.chars[key] = char
  end
  char.name = name
  char.realm = realm
  local _, classFile = UnitClass("player")
  if classFile then
    char.class = classFile
  end
  char.bags = char.bags or {}
  char.bank = char.bank or {}
  char.mail = char.mail or {}
  char.equipped = char.equipped or {}
  return key, char
end

local function numSlots(bagID)
  if C_Container and C_Container.GetContainerNumSlots then
    return C_Container.GetContainerNumSlots(bagID) or 0
  end
  if GetContainerNumSlots then
    return GetContainerNumSlots(bagID) or 0
  end
  return 0
end

local function slotItem(bagID, slot)
  if C_Container and C_Container.GetContainerItemInfo then
    local info = C_Container.GetContainerItemInfo(bagID, slot)
    if type(info) ~= "table" or not info.itemID or info.itemID == 0 then
      return nil
    end
    local link = info.hyperlink or info.itemLink
    if not link then
      return nil
    end
    return info.itemID, link, info.stackCount or info.stack or 1
  end
  if GetContainerItemInfo then
    local _, count, _, _, _, _, link, _, _, itemID = GetContainerItemInfo(bagID, slot)
    if not link then
      return nil
    end
    itemID = itemID or tonumber(link:match("item:(%d+)"))
    if not itemID then
      return nil
    end
    return itemID, link, count or 1
  end
end

local function itemNameFromLink(link)
  if type(link) ~= "string" then
    return nil
  end
  return link:match("%[(.-)%]")
end

local function itemInfo(item)
  local fn = C_Item and C_Item.GetItemInfo or _G.GetItemInfo
  if not fn or item == nil then
    return
  end
  return fn(item)
end

local function rememberInfo(row, itemID, link)
  row.link = link or row.link
  row.name = itemNameFromLink(row.link) or row.name
  local name, _, quality, _, _, typeName, _, _, _, texture = itemInfo(row.link or itemID)
  if C_Item and C_Item.GetItemInfoInstant then
    local _, instType, _, _, instIcon = C_Item.GetItemInfoInstant(itemID)
    typeName = (instType and instType ~= "" and instType) or typeName
    texture = texture or instIcon
  end
  if name and name ~= "" then
    row.name = name
  end
  if quality ~= nil then
    row.quality = quality
  end
  if typeName and typeName ~= "" then
    row.class = typeName
  end
  if texture then
    row.icon = texture
  elseif not row.icon then
    if C_Item and C_Item.GetItemIconByID then
      row.icon = C_Item.GetItemIconByID(itemID)
    elseif GetItemIcon then
      row.icon = GetItemIcon(itemID)
    end
  end
  if not row.class or quality == nil then
    pendingInfo[itemID] = true
    if C_Item and C_Item.RequestLoadItemDataByID then
      C_Item.RequestLoadItemDataByID(itemID)
    end
  end
end

local function addStack(map, itemID, count, link)
  count = count or 1
  local row = map[itemID]
  if not row then
    row = { count = 0 }
    map[itemID] = row
  end
  row.count = (row.count or 0) + count
  rememberInfo(row, itemID, link)
end

local function enumerate(prefix, limit)
  local ids = {}
  if not Enum or not Enum.BagIndex then
    return ids
  end
  for n = 1, limit do
    local id = Enum.BagIndex[prefix .. n]
    if id == nil then
      break
    end
    ids[#ids + 1] = id
  end
  return ids
end

local function backpackBags()
  local ids = {}
  local bagIndex = Enum and Enum.BagIndex
  if not bagIndex then
    return { 0, 1, 2, 3, 4 }
  end
  ids[#ids + 1] = bagIndex.Backpack or 0
  for _, id in ipairs(enumerate("Bag_", 6)) do
    ids[#ids + 1] = id
  end
  if bagIndex.ReagentBag then
    ids[#ids + 1] = bagIndex.ReagentBag
  end
  if bagIndex.Keyring and C_ActionBar and C_ActionBar.ShouldShowKeyring and C_ActionBar.ShouldShowKeyring() then
    ids[#ids + 1] = bagIndex.Keyring
  end
  return ids
end

local function anySlots(ids)
  for _, id in ipairs(ids) do
    local ok, slots = pcall(numSlots, id)
    if ok and type(slots) == "number" and slots > 0 then
      return true
    end
  end
  return false
end

-- Character bank tabs and the legacy bank window can describe the same items.
-- Use whichever set currently has slots so a snapshot is not counted twice.
local function bankBags()
  local bagIndex = Enum and Enum.BagIndex
  if not bagIndex then
    return { -1 }
  end
  local tabs = enumerate("CharacterBankTab_", 12)
  local legacy = {}
  if bagIndex.Bank then
    legacy[#legacy + 1] = bagIndex.Bank
  end
  for _, id in ipairs(enumerate("BankBag_", 12)) do
    legacy[#legacy + 1] = id
  end
  if anySlots(tabs) then
    return tabs
  end
  if anySlots(legacy) then
    return legacy
  end
  if bagIndex.Characterbanktab then
    return { bagIndex.Characterbanktab }
  end
  return tabs
end

local function bankIsOpen()
  if BankFrame and BankFrame:IsShown() then
    return true
  end
  if C_Bank and C_Bank.CanViewBank and Enum and Enum.BankType and Enum.BankType.Character then
    local ok, can = pcall(C_Bank.CanViewBank, Enum.BankType.Character)
    if ok and can then
      return true
    end
  end
  local bb = LibStub and LibStub("AceAddon-3.0", true) and LibStub("AceAddon-3.0"):GetAddon("BetterBags", true)
  if bb and bb.atBank then
    return true
  end
  return false
end

local function readContainers(bagIDs)
  local map = {}
  local free = 0
  local saw = false
  for _, bagID in ipairs(bagIDs) do
    local ok, slots = pcall(numSlots, bagID)
    if ok and type(slots) == "number" and slots > 0 then
      saw = true
      for slot = 1, slots do
        local readOk, itemID, link, count = pcall(slotItem, bagID, slot)
        if readOk and itemID and link then
          addStack(map, itemID, count, link)
        else
          free = free + 1
        end
      end
    end
  end
  return map, free, saw
end

local function readEquipped()
  local map = {}
  local first = _G.INVSLOT_FIRST_EQUIPPED or 1
  local last = _G.INVSLOT_LAST_EQUIPPED or 19
  for slot = first, last do
    local link = GetInventoryItemLink("player", slot)
    if link then
      local itemID = tonumber(link:match("item:(%d+)"))
      if itemID then
        addStack(map, itemID, 1, link)
      end
    end
  end
  return map
end

local layoutBank, refreshSearch
local categorizedKey

local function rebuildIndex()
  wipe(index)
  for key, char in pairs(db.chars) do
    local function take(location, bucket)
      if type(bucket) ~= "table" then
        return
      end
      for itemID, row in pairs(bucket) do
        if type(row) == "table" and (row.count or 0) > 0 then
          local entry = index[itemID]
          if not entry then
            entry = {
              itemID = itemID,
              name = row.name or ("Item " .. itemID),
              nameLower = (row.name or ""):lower(),
              link = row.link,
              icon = row.icon,
              quality = row.quality,
              className = row.class or "Items",
              total = 0,
              chars = {},
            }
            index[itemID] = entry
          end
          if row.name and (entry.name == "" or entry.name:find("^Item ")) then
            entry.name = row.name
            entry.nameLower = row.name:lower()
          end
          if row.link then
            entry.link = row.link
          end
          if row.icon then
            entry.icon = row.icon
          end
          if row.quality ~= nil then
            entry.quality = row.quality
          end
          if row.class then
            entry.className = row.class
          end
          local holder = entry.chars[key]
          if not holder then
            holder = {
              key = key,
              name = char.name or key,
              class = char.class,
              bags = 0,
              bank = 0,
              mail = 0,
              equipped = 0,
            }
            entry.chars[key] = holder
          end
          holder[location] = (holder[location] or 0) + (row.count or 0)
          entry.total = entry.total + (row.count or 0)
        end
      end
    end
    take("bags", char.bags)
    take("bank", char.bank)
    take("mail", char.mail)
    take("equipped", char.equipped)
  end
end

local function patchPending(itemID)
  if not itemID or not pendingInfo[itemID] then
    return
  end
  local name = itemInfo(itemID)
  if not name then
    return
  end
  pendingInfo[itemID] = nil
  for _, char in pairs(db.chars) do
    for _, bucket in ipairs({ char.bags, char.bank, char.mail, char.equipped }) do
      local row = bucket and bucket[itemID]
      if row then
        rememberInfo(row, itemID, row.link)
      end
    end
  end
  rebuildIndex()
  if viewingBank then
    layoutBank()
  end
  refreshSearch()
end

local bagScanQueued, bankScanQueued
local bankTries = 0

local function scanBagsAndGear()
  local key, char = currentChar()
  if not key then
    return
  end
  local bags = readContainers(backpackBags())
  char.bags = bags
  char.equipped = readEquipped()
  char.updated = time()
  rebuildIndex()
  refreshSearch()
end

local function queueBagScan()
  if bagScanQueued then
    return
  end
  bagScanQueued = true
  C_Timer.After(0.25, function()
    bagScanQueued = false
    scanBagsAndGear()
  end)
end

local function scanBank()
  if not bankIsOpen() then
    bankTries = 0
    return
  end
  local key, char = currentChar()
  if not key then
    return
  end
  local map, free, saw = readContainers(bankBags())
  if not saw then
    bankTries = bankTries + 1
    if bankTries < 10 then
      C_Timer.After(0.3, scanBank)
    end
    return
  end
  bankTries = 0
  char.bank = map
  char.bankFree = free
  char.bankUpdated = time()
  rebuildIndex()
  categorizedKey = nil
  if viewingBank then
    layoutBank()
  end
  refreshSearch()
end

local function queueBankScan()
  if bankScanQueued then
    return
  end
  bankScanQueued = true
  C_Timer.After(0.35, function()
    bankScanQueued = false
    scanBank()
  end)
end

local mailScanQueued = false
local mailInboxReady = false

local function mailIsOpen()
  return MailFrame and MailFrame:IsShown()
end

local function readInbox(numItems)
  local map = {}
  local maxAttach = _G.ATTACHMENTS_MAX_RECEIVE or _G.ATTACHMENTS_MAX or 16
  for mailIndex = 1, numItems do
    for attachIndex = 1, maxAttach do
      local link = GetInboxItemLink and GetInboxItemLink(mailIndex, attachIndex)
      if link then
        local itemID = tonumber(link:match("item:(%d+)"))
        local count = 1
        if itemID and GetInboxItem then
          local _, second, third, fourth = GetInboxItem(mailIndex, attachIndex)
          if second == itemID then
            count = fourth or 1
          else
            count = third or 1
          end
        end
        if itemID then
          addStack(map, itemID, count, link)
        end
      end
    end
  end
  return map
end

local function scanMail()
  if not mailIsOpen() or not GetInboxNumItems then
    return
  end
  local key, char = currentChar()
  if not key then
    return
  end
  local numItems, totalItems = GetInboxNumItems()
  numItems = numItems or 0
  totalItems = totalItems or numItems
  -- Opening the mailbox reports an empty inbox until the server list arrives.
  -- Keep the previous snapshot until that list shows up.
  if numItems == 0 and totalItems == 0 and not mailInboxReady then
    return
  end
  char.mail = readInbox(numItems)
  char.mailUpdated = time()
  rebuildIndex()
  refreshSearch()
end

local function queueMailScan()
  if mailScanQueued then
    return
  end
  mailScanQueued = true
  C_Timer.After(0.2, function()
    mailScanQueued = false
    scanMail()
  end)
end

local function colorForClass(classFile)
  return CLASS_COLORS[classFile or ""] or "FFD100"
end

local function holderSum(holder)
  return (holder.bags or 0) + (holder.bank or 0) + (holder.mail or 0) + (holder.equipped or 0)
end

local function locationText(holder)
  local bits = {}
  if (holder.bags or 0) > 0 then
    bits[#bits + 1] = holder.bags .. " bags"
  end
  if (holder.bank or 0) > 0 then
    bits[#bits + 1] = holder.bank .. " bank"
  end
  if (holder.mail or 0) > 0 then
    bits[#bits + 1] = holder.mail .. " mail"
  end
  if (holder.equipped or 0) > 0 then
    bits[#bits + 1] = holder.equipped .. " equipped"
  end
  if #bits == 0 then
    return "0"
  end
  return table.concat(bits, ", ")
end

local function sortedHolders(entry)
  local list = {}
  for _, holder in pairs(entry.chars) do
    if holderSum(holder) > 0 then
      list[#list + 1] = holder
    end
  end
  local me = playerKey()
  table.sort(list, function(a, b)
    if a.key == me then
      return true
    end
    if b.key == me then
      return false
    end
    if holderSum(a) ~= holderSum(b) then
      return holderSum(a) > holderSum(b)
    end
    return (a.name or "") < (b.name or "")
  end)
  return list
end

local function annotateTooltip(tip, itemID)
  local entry = index[itemID]
  if not entry or entry.total <= 0 then
    return
  end
  if tip.bbeItemID == itemID then
    return
  end
  local name = tip.GetName and tip:GetName()
  if name and name:find("^ShoppingTooltip") then
    return
  end
  tip:AddLine(" ")
  tip:AddLine("Account: " .. entry.total, 1, 0.82, 0)
  local holders = sortedHolders(entry)
  local shown = math.min(#holders, 12)
  for i = 1, shown do
    local holder = holders[i]
    local color = colorForClass(holder.class)
    tip:AddLine(string.format("|cff%s%s|r  %s", color, holder.name, locationText(holder)), 0.9, 0.9, 0.9)
  end
  if #holders > shown then
    tip:AddLine(string.format("+ %d more characters", #holders - shown), 0.6, 0.6, 0.6)
  end
  tip.bbeItemID = itemID
  tip:Show()
end

local tooltipsHooked = false
local function hookTooltips()
  if tooltipsHooked then
    return
  end
  tooltipsHooked = true
  if TooltipDataProcessor and Enum and Enum.TooltipDataType and TooltipDataProcessor.AddTooltipPostCall then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tip, data)
      if tip and data and data.id then
        annotateTooltip(tip, data.id)
      end
    end)
  else
    local function onSet(tip)
      local _, link = tip:GetItem()
      if not link then
        return
      end
      local itemID = tonumber(link:match("item:(%d+)"))
      if itemID then
        annotateTooltip(tip, itemID)
      end
    end
    GameTooltip:HookScript("OnTooltipSetItem", onSet)
    if ItemRefTooltip then
      ItemRefTooltip:HookScript("OnTooltipSetItem", onSet)
    end
  end
  local function clear(tip)
    tip.bbeItemID = nil
  end
  GameTooltip:HookScript("OnHide", clear)
  GameTooltip:HookScript("OnTooltipCleared", clear)
  if ItemRefTooltip then
    ItemRefTooltip:HookScript("OnHide", clear)
    ItemRefTooltip:HookScript("OnTooltipCleared", clear)
  end
end

local function ago(stamp)
  if not stamp then
    return "not saved yet"
  end
  local delta = time() - stamp
  if delta < 45 then
    return "just now"
  end
  if delta < 3600 then
    return math.floor(delta / 60) .. " min ago"
  end
  if delta < 86400 then
    return math.floor(delta / 3600) .. " hr ago"
  end
  return math.floor(delta / 86400) .. " days ago"
end

local function qualityColor(quality)
  local colors = _G.ITEM_QUALITY_COLORS
  local color = colors and colors[quality or 1]
  if color then
    return color.r, color.g, color.b
  end
  return 1, 1, 1
end

local function charList()
  local list = {}
  for key, char in pairs(db.chars) do
    list[#list + 1] = { key = key, name = char.name or key, class = char.class, bankUpdated = char.bankUpdated }
  end
  local me = playerKey()
  table.sort(list, function(a, b)
    if a.key == me then
      return true
    end
    if b.key == me then
      return false
    end
    return (a.name or "") < (b.name or "")
  end)
  return list
end

local function selectedChar()
  local key = viewCharKey or playerKey()
  local char = key and db.chars[key]
  if not char then
    key = playerKey()
    char = key and db.chars[key]
  end
  return key, char
end

-- Bank browser -----------------------------------------------------------

local bankButtons = {}
local bankHeaders = {}
local charMenu

local function acquire(pool, parent, factory)
  for _, widget in ipairs(pool) do
    if not widget:IsShown() then
      widget:SetParent(parent)
      widget:Show()
      return widget
    end
  end
  local widget = factory(parent)
  pool[#pool + 1] = widget
  return widget
end

local function hidePool(pool)
  for _, widget in ipairs(pool) do
    widget:Hide()
  end
end

local function makeItemButton(parent)
  local button = CreateFrame("Button", nil, parent)
  button:SetSize(37, 37)
  button.border = button:CreateTexture(nil, "BACKGROUND")
  button.border:SetPoint("TOPLEFT", -1, 1)
  button.border:SetPoint("BOTTOMRIGHT", 1, -1)
  button.border:SetColorTexture(1, 1, 1, 0.9)
  button.icon = button:CreateTexture(nil, "ARTWORK")
  button.icon:SetAllPoints()
  button.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  button.count = button:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  button.count:SetPoint("BOTTOMRIGHT", -1, 2)
  button.count:SetJustifyH("RIGHT")
  button:SetScript("OnEnter", function(self)
    if not self.link then
      return
    end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(self.link)
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)
  return button
end

local function makeHeader(parent)
  local text = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  text:SetJustifyH("LEFT")
  return text
end

local function hideCharMenu()
  if charMenu then
    charMenu:Hide()
  end
end

local function toggleCharMenu(owner)
  if not charMenu then
    charMenu = CreateFrame("Frame", nil, UIParent)
    local bg = charMenu:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.05, 0.05, 0.06, 0.98)
    local edge = charMenu:CreateTexture(nil, "BORDER")
    edge:SetPoint("TOPLEFT", -1, 1)
    edge:SetPoint("BOTTOMRIGHT", 1, -1)
    edge:SetColorTexture(0.55, 0.45, 0.15, 0.9)
    local cover = charMenu:CreateTexture(nil, "BORDER", nil, 1)
    cover:SetPoint("TOPLEFT", 1, -1)
    cover:SetPoint("BOTTOMRIGHT", -1, 1)
    cover:SetColorTexture(0.05, 0.05, 0.06, 1)
    charMenu:SetFrameStrata("DIALOG")
    charMenu:SetClampedToScreen(true)
    charMenu.buttons = {}
  end
  if charMenu:IsShown() then
    charMenu:Hide()
    return
  end
  local list = charList()
  local y = -6
  for i, info in ipairs(list) do
    local button = charMenu.buttons[i]
    if not button then
      button = CreateFrame("Button", nil, charMenu)
      button:SetHeight(18)
      button.text = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      button.text:SetAllPoints()
      button.text:SetJustifyH("LEFT")
      charMenu.buttons[i] = button
    end
    button:SetPoint("TOPLEFT", 8, y)
    button:SetPoint("RIGHT", charMenu, "RIGHT", -8, 0)
    local mark = (info.key == (viewCharKey or playerKey())) and "|cffffd100>|r " or "  "
    local saved = info.bankUpdated and "" or "  |cff888888(no snapshot)|r"
    button.text:SetText(string.format("%s|cff%s%s|r%s", mark, colorForClass(info.class), info.name, saved))
    button:SetScript("OnClick", function()
      viewCharKey = info.key
      charMenu:Hide()
      layoutBank()
    end)
    button:Show()
    y = y - 18
  end
  for i = #list + 1, #charMenu.buttons do
    charMenu.buttons[i]:Hide()
  end
  charMenu:SetSize(180, math.max(24, -y + 8))
  charMenu:ClearAllPoints()
  charMenu:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, -2)
  charMenu:Show()
end

local function betterBagsAddon()
  if not LibStub then
    return nil
  end
  return LibStub("AceAddon-3.0"):GetAddon("BetterBags", true)
end

local function bankCategoryName(itemID, row)
  local addon = betterBagsAddon()
  if not addon then
    return row.class or "Items"
  end
  local items = addon:GetModule("Items", true)
  local const = addon:GetModule("Constants", true)
  local context = addon:GetModule("Context", true)
  if not items or not const or not context or not items.GetCategory then
    return row.class or "Items"
  end
  local info = { itemID = itemID, currentItemCount = row.count or 1 }
  if C_Item and C_Item.GetItemInfoInstant then
    local _, itemType, itemSubType, equipLoc, _, classID, subclassID = C_Item.GetItemInfoInstant(itemID)
    info.itemType = itemType
    info.itemSubType = itemSubType
    info.itemEquipLoc = equipLoc
    info.classID = classID
    info.subclassID = subclassID
  end
  local name, _, quality, _, _, _, _, _, _, _, _, _, _, _, expacID = itemInfo(row.link or itemID)
  info.itemName = name or row.name
  info.itemQuality = quality or row.quality
  info.itemLink = row.link
  info.expacID = expacID
  local data = {
    kind = const.BAG_KIND.BANK,
    slotkey = "bbe:" .. tostring(itemID),
    itemInfo = info,
    containerInfo = { quality = info.itemQuality },
  }
  local ok, category = pcall(items.GetCategory, items, context:New("BetterBags_Companion_Bank"), data, false, true)
  if ok and type(category) == "string" and category ~= "" then
    return category
  end
  return row.class or "Items"
end

local function liveBankCategories()
  local found = {}
  local addon = betterBagsAddon()
  if not addon then
    return found
  end
  local items = addon:GetModule("Items", true)
  local const = addon:GetModule("Constants", true)
  local slotInfo = items and const and items.slotInfo and items.slotInfo[const.BAG_KIND.BANK]
  local bySlot = slotInfo and slotInfo.itemsBySlotKey
  if not bySlot then
    return found
  end
  for _, item in pairs(bySlot) do
    local info = item.itemInfo
    if info and info.itemID and type(info.category) == "string" and info.category ~= "" and not item.isItemEmpty then
      found[info.itemID] = info.category
    end
  end
  return found
end

local function assignBankCategories(key, char)
  if categorizedKey == key or not char or not char.bank then
    return
  end
  categorizedKey = key
  local live = (key == playerKey()) and liveBankCategories() or {}
  for itemID, row in pairs(char.bank) do
    if type(row) == "table" then
      row.category = live[itemID] or bankCategoryName(itemID, row)
    end
  end
end

local function bankGridSettings()
  local columns, perRow, kind, view = 2, 7
  local addon = betterBagsAddon()
  if not addon then
    return columns, perRow, kind, view
  end
  local const = addon:GetModule("Constants", true)
  local database = addon:GetModule("Database", true)
  if not const or not database or not database.GetBagSizeInfo then
    return columns, perRow, kind, view
  end
  kind = const.BAG_KIND.BANK
  view = database.GetBagView and database:GetBagView(kind) or const.BAG_VIEW.SECTION_GRID
  local size = database:GetBagSizeInfo(kind, view)
  if size then
    columns = size.columnCount or columns
    perRow = size.itemsPerRow or perRow
  end
  if columns < 1 then
    columns = 1
  end
  if perRow < 1 then
    perRow = 1
  end
  return columns, perRow, kind, view
end

function layoutBank()
  if not bankOverlay or not bankOverlay:IsShown() then
    return
  end
  hidePool(bankButtons)
  hidePool(bankHeaders)
  local content = bankOverlay.content
  local width = bankOverlay.scroll:GetWidth()
  if not width or width < 40 then
    width = 300
  end
  local key, char = selectedChar()
  local title = char and char.name or "Bank"
  bankOverlay.charButton:SetText(title .. "  |cffaaaaaav|r")
  if not char or not char.bankUpdated then
    bankOverlay.status:SetText("Open the bank once on this character to save a snapshot you can view anywhere.")
  else
    local total = 0
    local kinds = 0
    for _, row in pairs(char.bank) do
      if type(row) == "table" and (row.count or 0) > 0 then
        total = total + row.count
        kinds = kinds + 1
      end
    end
    bankOverlay.status:SetText(string.format(
      "%d items, %d types, %d free slots, updated %s",
      total, kinds, char.bankFree or 0, ago(char.bankUpdated)
    ))
  end

  local groups = {}
  local sections = {}
  if char and char.bank then
    assignBankCategories(key, char)
    for itemID, row in pairs(char.bank) do
      if type(row) == "table" and (row.count or 0) > 0 then
        local name = row.category or row.class or "Items"
        local group = groups[name]
        if not group then
          group = {}
          groups[name] = group
          sections[#sections + 1] = { name = name, items = group, count = 0 }
        end
        group[#group + 1] = { itemID = itemID, row = row }
      end
    end
  end
  local freeName = "Free Space"
  local addon = betterBagsAddon()
  local loc = addon and addon:GetModule("Localization", true)
  if loc and loc.G then
    freeName = loc:G("Free Space")
  end
  local freeSlots = char and char.bankFree or 0
  if freeSlots > 0 then
    local empties = {}
    for i = 1, freeSlots do
      empties[i] = { empty = true, row = {} }
    end
    sections[#sections + 1] = { name = freeName, items = empties, count = freeSlots }
  end
  for _, section in ipairs(sections) do
    section.count = #section.items
  end

  local columns, perRow, kind, view = bankGridSettings()
  local sortMod = addon and addon:GetModule("Sort", true)
  local database = addon and addon:GetModule("Database", true)
  if sortMod and sortMod.GetCategoryDataSortFunction and kind then
    local cmp = sortMod:GetCategoryDataSortFunction(kind, view)
    local ok = pcall(table.sort, sections, cmp)
    if not ok then
      table.sort(sections, function(a, b)
        return a.name < b.name
      end)
    end
  else
    table.sort(sections, function(a, b)
      return a.name < b.name
    end)
  end
  local itemCmp
  if sortMod and sortMod.GetItemDataSortFunction and kind then
    itemCmp = sortMod:GetItemDataSortFunction(kind, view)
  end
  for _, section in ipairs(sections) do
    if itemCmp and section.name ~= freeName then
      local ok = pcall(table.sort, section.items, function(a, b)
        local function dataFor(item)
          local quality = item.row.quality
          if quality == 0 then
            quality = -1
          end
          return {
            itemInfo = {
              itemQuality = quality or 1,
              itemName = (item.row.name and item.row.name ~= "") and item.row.name or " ",
              currentItemCount = item.row.count or 1,
              itemGUID = tostring(item.itemID),
            },
          }
        end
        return itemCmp(dataFor(a), dataFor(b))
      end)
      if not ok then
        table.sort(section.items, function(a, b)
          return (a.row.name or "") < (b.row.name or "")
        end)
      end
    end
  end

  local showFull = database and kind and database.GetShowFullSectionNames and database:GetShowFullSectionNames(kind)
  local cell, gap, titleH = 37, 4, 16
  local sizes = {}
  for i, section in ipairs(sections) do
    local count = #section.items
    local cols = math.min(count, perRow)
    local rows = math.max(1, math.ceil(count / perRow))
    local contentW = cols * cell + math.max(0, cols - 1) * gap
    local contentH = rows * cell + math.max(0, rows - 1) * gap
    if showFull then
      local header = bankHeaders[1]
      if not header then
        header = makeHeader(content)
        bankHeaders[1] = header
      end
      header:SetText(section.name)
      contentW = math.max(contentW, math.ceil(header:GetStringWidth() or 0))
    end
    sizes[i] = { contentW + 12, contentH + titleH + 6 }
  end

  local positions = {}
  local packedHeight, packedWidth = 0, 0
  local flow = addon and addon:GetModule("Flow", true)
  local packed
  if flow and flow.Pack and #sizes > 0 then
    local ok, result = pcall(flow.Pack, flow, sizes, {
      rowLimit = ((cell + gap) * perRow) + 16,
      columns = columns,
      spacing = gap,
    })
    if ok then
      packed = result
    end
  end
  if packed and packed.positions then
    positions = packed.positions
    packedHeight = packed.height or 0
    packedWidth = packed.width or 0
  else
    local y = 0
    for i, size in ipairs(sizes) do
      positions[i] = { x = 0, y = -y }
      y = y + size[2] + gap
      packedWidth = math.max(packedWidth, size[1])
    end
    packedHeight = y
  end

  local usedButtons = 0
  local usedHeaders = 0
  for i, section in ipairs(sections) do
    local pos = positions[i] or { x = 0, y = 0 }
    local sectionX = 4 + pos.x
    local sectionY = -4 + pos.y
    usedHeaders = usedHeaders + 1
    local header = bankHeaders[usedHeaders]
    if not header then
      header = makeHeader(content)
      bankHeaders[usedHeaders] = header
    end
    header:SetParent(content)
    header:ClearAllPoints()
    header:SetPoint("TOPLEFT", sectionX + 6, sectionY)
    header:SetWidth(math.max(20, sizes[i][1] - 12))
    header:SetWordWrap(false)
    header:SetText(section.name)
    header:Show()
    local column = 0
    local row = 0
    for _, item in ipairs(section.items) do
      usedButtons = usedButtons + 1
      local button = bankButtons[usedButtons]
      if not button then
        button = makeItemButton(content)
        bankButtons[usedButtons] = button
      end
      button:SetParent(content)
      button:ClearAllPoints()
      button:SetPoint("TOPLEFT", sectionX + 6 + column * (cell + gap), sectionY - titleH - row * (cell + gap))
      if item.empty then
        button.link = nil
        button.icon:SetColorTexture(0.12, 0.12, 0.12, 0.85)
        button.border:SetColorTexture(0.25, 0.25, 0.25, 0.7)
        button.count:SetText("")
      else
        button.link = item.row.link
        button.icon:SetTexture(item.row.icon or 134400)
        local r, g, b = qualityColor(item.row.quality)
        button.border:SetColorTexture(r, g, b, 0.95)
        if (item.row.count or 0) > 1 then
          button.count:SetText(item.row.count)
          button.count:Show()
        else
          button.count:SetText("")
        end
      end
      button:Show()
      column = column + 1
      if column >= perRow then
        column = 0
        row = row + 1
      end
    end
  end
  for i = usedButtons + 1, #bankButtons do
    bankButtons[i]:Hide()
  end
  for i = usedHeaders + 1, #bankHeaders do
    bankHeaders[i]:Hide()
  end
  content:SetWidth(math.max(width, packedWidth + 8))
  content:SetHeight(math.max(bankOverlay.scroll:GetHeight() or 0, packedHeight + 12))
end

local function ensureBankOverlay(bag)
  if bag.bbeOverlay then
    bankOverlay = bag.bbeOverlay
    return bankOverlay
  end
  local host = bag.scrollBox or (bag.scroll and bag.scroll.scrollBox) or bag.body or bag.frame
  local overlay = CreateFrame("Frame", nil, bag.frame)
  overlay:SetFrameStrata(bag.frame:GetFrameStrata() or "MEDIUM")
  overlay:SetFrameLevel((bag.frame:GetFrameLevel() or 1) + 40)
  overlay:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
  overlay:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, 0)
  overlay:EnableMouse(true)
  overlay:Hide()
  local bg = overlay:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.03, 0.03, 0.04, 0.97)

  overlay.charButton = CreateFrame("Button", nil, overlay)
  overlay.charButton:SetPoint("TOPLEFT", 8, -6)
  overlay.charButton:SetSize(160, 18)
  overlay.charButton.text = overlay.charButton:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  overlay.charButton.text:SetAllPoints()
  overlay.charButton.text:SetJustifyH("LEFT")
  overlay.charButton:SetFontString(overlay.charButton.text)
  overlay.charButton:SetScript("OnClick", function(self)
    toggleCharMenu(self)
  end)

  overlay.status = overlay:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  overlay.status:SetPoint("TOPLEFT", 8, -24)
  overlay.status:SetPoint("TOPRIGHT", -8, -24)
  overlay.status:SetJustifyH("LEFT")
  overlay.status:SetWordWrap(true)
  overlay.status:SetHeight(24)

  local scroll = CreateFrame("ScrollFrame", nil, overlay)
  scroll:SetPoint("TOPLEFT", 0, -50)
  scroll:SetPoint("BOTTOMRIGHT", 0, 4)
  scroll:EnableMouseWheel(true)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(200, 200)
  scroll:SetScrollChild(content)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local child = self:GetScrollChild()
    local maxScroll = math.max(0, (child:GetHeight() or 0) - (self:GetHeight() or 0))
    local nextScroll = (self:GetVerticalScroll() or 0) - delta * 36
    if nextScroll < 0 then
      nextScroll = 0
    elseif nextScroll > maxScroll then
      nextScroll = maxScroll
    end
    self:SetVerticalScroll(nextScroll)
  end)
  scroll:SetScript("OnSizeChanged", function()
    if overlay:IsShown() then
      layoutBank()
    end
  end)
  overlay.scroll = scroll
  overlay.content = content
  bag.bbeOverlay = overlay
  bankOverlay = overlay
  return overlay
end

local function setBagTitle(bag, text)
  if bag.SetTitle then
    bag:SetTitle(text)
    return
  end
  if bag.window and bag.window.SetTitle then
    bag.window:SetTitle(text)
  elseif bag.title and bag.title.SetText then
    bag.title:SetText(text)
  end
end

local function showBank()
  if not boundBag then
    return
  end
  viewingBank = true
  categorizedKey = nil
  local overlay = ensureBankOverlay(boundBag)
  overlay:Show()
  if not viewCharKey then
    viewCharKey = playerKey()
  end
  if not boundBag.bbeSavedTitle then
    local title
    if boundBag.window and boundBag.window.GetTitle then
      title = boundBag.window:GetTitle()
    elseif boundBag.GetTitle then
      title = boundBag:GetTitle()
    end
    boundBag.bbeSavedTitle = (title and title ~= "" and title ~= "Bank") and title or "Backpack"
  end
  setBagTitle(boundBag, "Bank")
  layoutBank()
  if modeStrip then
    modeStrip:Update()
  end
end

local function hideBank()
  viewingBank = false
  hideCharMenu()
  if bankOverlay then
    bankOverlay:Hide()
  end
  if boundBag then
    setBagTitle(boundBag, boundBag.bbeSavedTitle or "Backpack")
  end
  if modeStrip then
    modeStrip:Update()
  end
end

-- Account search ---------------------------------------------------------

local resultRows = {}

local function matches(query)
  local list = {}
  if query == "" then
    return list
  end
  local asID = tonumber(query)
  for itemID, entry in pairs(index) do
    local hit = (asID and itemID == asID) or (entry.nameLower and entry.nameLower:find(query, 1, true))
    if hit then
      list[#list + 1] = entry
    end
  end
  table.sort(list, function(a, b)
    local aPrefix = a.nameLower:sub(1, #query) == query
    local bPrefix = b.nameLower:sub(1, #query) == query
    if aPrefix ~= bPrefix then
      return aPrefix
    end
    if a.total ~= b.total then
      return a.total > b.total
    end
    return a.name < b.name
  end)
  return list
end

local function ensureResults()
  if resultsFrame then
    return resultsFrame
  end
  local frame = CreateFrame("Frame", "BetterBagsCompanionSearchResults", UIParent)
  frame:SetFrameStrata("DIALOG")
  frame:SetClampedToScreen(true)
  frame:SetSize(320, 40)
  frame:Hide()
  frame:EnableMouse(true)
  local bg = frame:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.04, 0.04, 0.05, 0.97)
  local edge = frame:CreateTexture(nil, "BORDER")
  edge:SetPoint("TOPLEFT", -1, 1)
  edge:SetPoint("BOTTOMRIGHT", 1, -1)
  edge:SetColorTexture(0.55, 0.45, 0.15, 0.9)
  local cover = frame:CreateTexture(nil, "BORDER", nil, 1)
  cover:SetPoint("TOPLEFT", 1, -1)
  cover:SetPoint("BOTTOMRIGHT", -1, 1)
  cover:SetColorTexture(0.04, 0.04, 0.05, 1)
  frame.scroll = CreateFrame("ScrollFrame", nil, frame)
  frame.scroll:SetPoint("TOPLEFT", 4, -4)
  frame.scroll:SetPoint("BOTTOMRIGHT", -4, 4)
  frame.scroll:EnableMouseWheel(true)
  frame.content = CreateFrame("Frame", nil, frame.scroll)
  frame.content:SetSize(300, 40)
  frame.scroll:SetScrollChild(frame.content)
  frame.scroll:SetScript("OnMouseWheel", function(self, delta)
    local child = self:GetScrollChild()
    local maxScroll = math.max(0, (child:GetHeight() or 0) - (self:GetHeight() or 0))
    local nextScroll = (self:GetVerticalScroll() or 0) - delta * 28
    if nextScroll < 0 then
      nextScroll = 0
    elseif nextScroll > maxScroll then
      nextScroll = maxScroll
    end
    self:SetVerticalScroll(nextScroll)
  end)
  frame.note = frame.content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  frame.note:SetJustifyH("LEFT")
  resultsFrame = frame
  return frame
end

local function makeResultRow(parent)
  local row = CreateFrame("Frame", nil, parent)
  row:EnableMouse(true)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(28, 28)
  row.icon:SetPoint("TOPLEFT", 2, -2)
  row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -1)
  row.name:SetPoint("RIGHT", row, "RIGHT", -4, 0)
  row.name:SetJustifyH("LEFT")
  row.lines = {}
  row:SetScript("OnEnter", function(self)
    self.highlight:Show()
    if self.link then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetHyperlink(self.link)
      GameTooltip:Show()
    end
  end)
  row:SetScript("OnLeave", function(self)
    self.highlight:Hide()
    GameTooltip:Hide()
  end)
  row.highlight = row:CreateTexture(nil, "BACKGROUND")
  row.highlight:SetAllPoints()
  row.highlight:SetColorTexture(1, 0.82, 0, 0.12)
  row.highlight:Hide()
  return row
end

function refreshSearch()
  if not searchEdit or not resultsFrame or not resultsFrame:IsShown() then
    return
  end
  local query = (searchEdit:GetText() or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  local found = matches(query)
  local content = resultsFrame.content
  local y = 0
  local limit = math.min(#found, 20)
  for i = 1, limit do
    local entry = found[i]
    local row = resultRows[i]
    if not row then
      row = makeResultRow(content)
      resultRows[i] = row
    end
    row:SetParent(content)
    row:Show()
    row.link = entry.link
    row.icon:SetTexture(entry.icon or 134400)
    local r, g, b = qualityColor(entry.quality)
    row.name:SetTextColor(r, g, b)
    row.name:SetText(string.format("%s  |cffffd100%d|r", entry.name, entry.total))
    local holders = sortedHolders(entry)
    local lines = math.min(#holders, 8)
    for n = 1, lines do
      local line = row.lines[n]
      if not line then
        line = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        line:SetJustifyH("LEFT")
        row.lines[n] = line
      end
      local holder = holders[n]
      line:ClearAllPoints()
      line:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -16 - (n - 1) * 13)
      line:SetPoint("RIGHT", row, "RIGHT", -4, 0)
      line:SetText(string.format("|cff%s%s|r  %s", colorForClass(holder.class), holder.name, locationText(holder)))
      line:Show()
    end
    for n = lines + 1, #row.lines do
      row.lines[n]:Hide()
    end
    local height = 20 + lines * 13 + 6
    if #holders > lines then
      height = height + 13
      local extra = row.lines[lines + 1]
      if not extra then
        extra = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        extra:SetJustifyH("LEFT")
        row.lines[lines + 1] = extra
      end
      extra:ClearAllPoints()
      extra:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 6, -16 - lines * 13)
      extra:SetText(string.format("+ %d more", #holders - lines))
      extra:Show()
    end
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -y)
    row:SetPoint("RIGHT", content, "RIGHT", 0, 0)
    row:SetHeight(height)
    y = y + height
  end
  for i = limit + 1, #resultRows do
    resultRows[i]:Hide()
  end
  if #found > limit then
    resultsFrame.note:ClearAllPoints()
    resultsFrame.note:SetPoint("TOPLEFT", 4, -y)
    resultsFrame.note:SetText(string.format("Showing %d of %d matches", limit, #found))
    resultsFrame.note:Show()
    y = y + 16
  else
    resultsFrame.note:Hide()
  end
  if limit == 0 then
    resultsFrame.note:ClearAllPoints()
    resultsFrame.note:SetPoint("TOPLEFT", 6, -6)
    resultsFrame.note:SetText("No items on this account match.")
    resultsFrame.note:Show()
    y = 22
  end
  content:SetWidth(300)
  content:SetHeight(math.max(20, y))
  resultsFrame:SetHeight(math.min(360, y + 10))
  resultsFrame.scroll:SetVerticalScroll(0)
end

local function showSearchResults()
  if not searchEdit then
    return
  end
  local text = searchEdit:GetText() or ""
  if text == "" then
    if resultsFrame then
      resultsFrame:Hide()
    end
    return
  end
  local frame = ensureResults()
  frame:ClearAllPoints()
  frame:SetPoint("TOPRIGHT", searchEdit, "BOTTOMRIGHT", 0, -2)
  frame:SetWidth(math.max(280, searchEdit:GetWidth() or 160))
  frame:Show()
  refreshSearch()
end

local function createSearchBox(parent)
  local edit
  local ok = pcall(function()
    edit = CreateFrame("EditBox", "BetterBagsCompanionAccountSearch", parent, "SearchBoxTemplate")
  end)
  if not ok or not edit then
    edit = CreateFrame("EditBox", "BetterBagsCompanionAccountSearch", parent)
    edit:SetFontObject(ChatFontNormal)
    edit:SetAutoFocus(false)
    edit:SetTextInsets(6, 6, 0, 0)
    local bg = edit:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.65)
  end
  edit:SetAutoFocus(false)
  edit:SetSize(150, 22)
  if edit.Instructions then
    edit.Instructions:SetText("Account")
    edit.Instructions:SetTextColor(0.75, 0.75, 0.75)
  end
  edit:SetScript("OnTextChanged", function(self)
    if self.Instructions then
      self.Instructions:SetShown(self:GetText() == "")
    end
    showSearchResults()
  end)
  edit:SetScript("OnEditFocusGained", function()
    showSearchResults()
  end)
  edit:SetScript("OnEscapePressed", function(self)
    self:SetText("")
    self:ClearFocus()
    if resultsFrame then
      resultsFrame:Hide()
    end
  end)
  edit:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
  end)
  edit:SetScript("OnEditFocusLost", function()
    C_Timer.After(0.2, function()
      if resultsFrame and resultsFrame:IsShown() and not resultsFrame:IsMouseOver() and not edit:HasFocus() then
        resultsFrame:Hide()
      end
    end)
  end)
  return edit
end

-- Tabs -------------------------------------------------------------------

local function betterBags()
  if not LibStub then
    return nil
  end
  return LibStub("AceAddon-3.0"):GetAddon("BetterBags", true)
end

local function makeModeButton(parent, label, onClick)
  local button = CreateFrame("Button", nil, parent)
  button:SetSize(78, 22)
  local bg = button:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.08, 0.08, 0.08, 0.9)
  button.bg = bg
  button.label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  button.label:SetPoint("CENTER", 0, 0)
  button.label:SetText(label)
  button:SetScript("OnClick", onClick)
  button:SetScript("OnEnter", function(self)
    self.bg:SetColorTexture(0.18, 0.16, 0.08, 0.95)
  end)
  button:SetScript("OnLeave", function(self)
    if modeStrip then
      modeStrip:Update()
    end
  end)
  return button
end

local function paintModeButton(button, selected)
  if selected then
    button.label:SetTextColor(1, 0.82, 0)
    button.bg:SetColorTexture(0.22, 0.18, 0.05, 0.95)
  else
    button.label:SetTextColor(0.85, 0.85, 0.85)
    button.bg:SetColorTexture(0.08, 0.08, 0.08, 0.9)
  end
end

local function ensureModeStrip(bag)
  if bag.bbeModeStrip then
    modeStrip = bag.bbeModeStrip
    return modeStrip
  end
  local strip = CreateFrame("Frame", nil, bag.frame)
  strip:SetHeight(26)
  strip.backpack = makeModeButton(strip, "Backpack", function()
    hideBank()
    if bag.tabs and bag.tabs.SetTabByID and bag.tabs.TabExistsByID and bag.tabs:TabExistsByID(1) then
      local bb = betterBags()
      local ctx = bb and bb:GetModule("Context"):New("BBE_BackpackTab")
      bag.tabs:SetTabByID(ctx, 1)
    end
    if bag.tabs and bag.tabs.Select and bag.GetCurrentTabID then
      bag.tabs:Select(bag:GetCurrentTabID(), true)
    end
    strip:Update()
  end)
  strip.bank = makeModeButton(strip, "Bank", function()
    showBank()
    if bag.tabs and bag.tabs.Select then
      bag.tabs:Select(BANK_TAB_ID, true)
    end
    strip:Update()
  end)
  function strip:Update()
    paintModeButton(self.backpack, not viewingBank)
    paintModeButton(self.bank, viewingBank)
  end
  strip:Update()
  bag.bbeModeStrip = strip
  modeStrip = strip
  return strip
end

local function placeAccountSearch(bag)
  if not searchEdit or searchEdit ~= bag.bbeSearch then
    return nil
  end
  local decoration = bag.window and bag.window.decoration
  local overlay = decoration and decoration.GetOverlayFrame and decoration:GetOverlayFrame()
  local close = decoration and decoration.GetCloseButton and decoration:GetCloseButton()
  close = close or bag.closeButton or bag.frame.CloseButton
  local template = decoration and decoration.GetTemplateFrame and decoration:GetTemplateFrame()
  local container = (template and template.TitleContainer) or bag.frame.TitleContainer
  if container and container.GetHeight and bag.frame.GetHeight then
    local barHeight = container:GetHeight()
    local frameHeight = bag.frame:GetHeight()
    if barHeight and frameHeight and frameHeight > 0 and barHeight > frameHeight * 0.4 then
      container = nil
    end
  end
  local title = decoration and decoration.GetTitleText and decoration:GetTitleText()
  if title and title.IsShown and not title:IsShown() then
    title = nil
  end
  local yFrame = container or title

  local parent = overlay or container or bag.frame
  searchEdit:SetParent(parent)
  searchEdit:SetFrameStrata(parent:GetFrameStrata() or bag.frame:GetFrameStrata() or "MEDIUM")
  searchEdit:SetFrameLevel((parent:GetFrameLevel() or 1) + 40)
  searchEdit:SetSize(140, 18)
  searchEdit:ClearAllPoints()

  -- The close button hangs on the frame corner. Shift vertically onto the title
  -- text so the box sits in the brown bar instead of on the border.
  local yOffset = 0
  if close and yFrame and close.GetCenter and yFrame.GetCenter then
    local _, closeY = close:GetCenter()
    local _, barY = yFrame:GetCenter()
    if closeY and barY then
      yOffset = barY - closeY
    end
  end

  if close then
    searchEdit:SetPoint("RIGHT", close, "LEFT", -4, yOffset)
  elseif container then
    searchEdit:SetPoint("RIGHT", container, "RIGHT", -4, 0)
  else
    searchEdit:SetPoint("TOPRIGHT", bag.frame, "TOPRIGHT", -36, -6)
  end
  searchEdit:Show()
  return close
end

local function layoutChrome(bag, useStrip, stripAtBottom)
  if not searchEdit or searchEdit ~= bag.bbeSearch then
    return
  end
  placeAccountSearch(bag)
  local strip = bag.bbeModeStrip
  if useStrip and strip then
    strip:Show()
    strip:Update()
    strip.backpack:ClearAllPoints()
    strip.bank:ClearAllPoints()
    if stripAtBottom then
      strip:ClearAllPoints()
      strip:SetPoint("TOPLEFT", bag.frame, "BOTTOMLEFT", 8, 2)
      strip:SetPoint("TOPRIGHT", bag.frame, "BOTTOMRIGHT", -8, 2)
      strip.backpack:ClearAllPoints()
      strip.bank:ClearAllPoints()
      strip.backpack:SetPoint("LEFT", strip, "LEFT", 0, 0)
      strip.bank:SetPoint("LEFT", strip.backpack, "RIGHT", 4, 0)
    else
      strip:ClearAllPoints()
      strip:SetSize(1, 1)
      strip:SetPoint("TOPLEFT", bag.frame, "TOPLEFT", 0, 0)
      strip.bank:ClearAllPoints()
      strip.backpack:ClearAllPoints()
      strip.bank:SetPoint("RIGHT", searchEdit, "LEFT", -6, 0)
      strip.backpack:SetPoint("RIGHT", strip.bank, "LEFT", -4, 0)
    end
  elseif strip then
    strip:Hide()
  end
end

local function pinBankTab(bar)
  if not bar or not bar.tabIndex then
    return
  end
  local found
  for i, tab in ipairs(bar.tabIndex) do
    if tab.id == BANK_TAB_ID then
      found = table.remove(bar.tabIndex, i)
      break
    end
  end
  if not found then
    return
  end
  -- After every real tab, and before the "+" / purchase tabs.
  local at = #bar.tabIndex + 1
  for i, tab in ipairs(bar.tabIndex) do
    if tab.id and tab.id <= 0 then
      at = i
      break
    end
  end
  table.insert(bar.tabIndex, at, found)
  for i, tab in ipairs(bar.tabIndex) do
    tab.index = i
  end
  if not found:IsShown() then
    found:Show()
  end
  if bar.ReanchorTabs then
    bar:ReanchorTabs()
    if not bar.bbeReanchorQueued then
      bar.bbeReanchorQueued = true
      C_Timer.After(0, function()
        bar.bbeReanchorQueued = false
        if bar.ReanchorTabs then
          bar:ReanchorTabs()
        end
      end)
    end
  end
end

local function groupsEnabled(bag)
  local bb = betterBags()
  if not bb then
    return false
  end
  local database = bb:GetModule("Database", true)
  local const = bb:GetModule("Constants", true)
  if not database or not const or not database.GetGroupsEnabled then
    return false
  end
  local kind = bag.kind or const.BAG_KIND.BACKPACK
  return database:GetGroupsEnabled(kind) and true or false
end

local function showingBlizzardBags(bag)
  return bag.ShowsBlizzardBags and bag:ShowsBlizzardBags()
end

local function ensureClassicBankTab(bag)
  local bar = bag.tabs
  if not bar or not bar.AddTab then
    return false
  end
  if not groupsEnabled(bag) or showingBlizzardBags(bag) then
    return false
  end
  if bar.frame and not bar.frame:IsShown() then
    return false
  end
  if not bar:TabExistsByID(BANK_TAB_ID) then
    if InCombatLockdown() then
      eventFrame.needBankTab = true
      return false
    end
    local bb = betterBags()
    local ctx = bb:GetModule("Context"):New("BBE_BankTab")
    bar:AddTab(ctx, "Bank", BANK_TAB_ID)
  end
  local bankAt, specialAt
  for i, tab in ipairs(bar.tabIndex) do
    if tab.id == BANK_TAB_ID then
      bankAt = i
    elseif not specialAt and tab.id and tab.id <= 0 then
      specialAt = i
    end
  end
  local parked = bankAt and ((specialAt and bankAt == specialAt - 1) or (not specialAt and bankAt == #bar.tabIndex))
  local bankTab = bankAt and bar.tabIndex[bankAt]
  if not parked or (bankTab and not bankTab:IsShown()) then
    pinBankTab(bar)
  end
  if viewingBank then
    local current = bar.selectedTab and bar.tabIndex[bar.selectedTab]
    if not current or current.id ~= BANK_TAB_ID then
      local bb = betterBags()
      local ctx = bb:GetModule("Context"):New("BBE_SelectBank")
      bar:SetTabByID(ctx, BANK_TAB_ID)
    end
  end
  return true
end

local function injectNextBankTab(bag)
  if not bag.tabs or not bag.tabs.SetTabs or not bag.tabs.entries then
    return false
  end
  if not groupsEnabled(bag) or showingBlizzardBags(bag) then
    return false
  end
  if bag.tabs.frame and not bag.tabs.frame:IsShown() then
    return false
  end
  local bankAt, specialAt
  for i, entry in ipairs(bag.tabs.entries) do
    if entry.id == BANK_TAB_ID then
      bankAt = i
    elseif not specialAt and (entry.fixed or (entry.id and entry.id <= 0)) then
      specialAt = i
    end
  end
  local parked = bankAt and ((specialAt and bankAt == specialAt - 1) or (not specialAt and bankAt == #bag.tabs.entries))
  if parked then
    if viewingBank and bag.tabs.Select and bag.tabs.selected ~= BANK_TAB_ID then
      bag.tabs:Select(BANK_TAB_ID, false)
    end
    return true
  end
  local copy = {}
  local hasBackpack = false
  for _, entry in ipairs(bag.tabs.entries) do
    if entry.id ~= BANK_TAB_ID then
      copy[#copy + 1] = entry
      if entry.id == 1 then
        hasBackpack = true
      end
    end
  end
  if not hasBackpack then
    return false
  end
  local at = #copy + 1
  for i, entry in ipairs(copy) do
    if entry.fixed or (entry.id and entry.id <= 0) then
      at = i
      break
    end
  end
  table.insert(copy, at, {
    id = BANK_TAB_ID,
    name = "Bank",
    fixed = true,
    tooltip = {
      "Bank",
      "View this character's bank from anywhere. Open a banker once to save a snapshot.",
    },
  })
  bag.tabs:SetTabs(copy)
  if viewingBank and bag.tabs.Select then
    bag.tabs:Select(BANK_TAB_ID, false)
  end
  return true
end

local applyingTabs = false
local function applyTabMode(bag)
  if applyingTabs then
    return
  end
  applyingTabs = true
  local injected = false
  if bag.tabs and bag.tabs.AddTab then
    injected = ensureClassicBankTab(bag)
  elseif bag.RefreshTabs then
    injected = injectNextBankTab(bag)
  end
  local strip = ensureModeStrip(bag)
  local isNext = bag.RefreshTabs ~= nil and bag.tabs and bag.tabs.SetTabs and not bag.tabs.AddTab
  if injected then
    layoutChrome(bag, false, false)
  else
    layoutChrome(bag, true, not isNext)
  end
  strip:Update()
  applyingTabs = false
end

local function bindBag(bag)
  if not bag or not bag.frame then
    return
  end
  if bag.bbeBound then
    boundBag = bag
    searchEdit = bag.bbeSearch
    bankOverlay = bag.bbeOverlay
    modeStrip = bag.bbeModeStrip
    applyTabMode(bag)
    if viewingBank then
      showBank()
    end
    return
  end
  bag.bbeBound = true
  boundBag = bag

  searchEdit = bag.bbeSearch
  if not searchEdit then
    searchEdit = createSearchBox(bag.frame)
    bag.bbeSearch = searchEdit
  end
  searchEdit:SetParent(bag.frame)
  searchEdit:Show()

  ensureBankOverlay(bag)
  ensureModeStrip(bag)

  if bag.tabs and bag.tabs.AddTab and not bag.tabs.bbeHooked then
    bag.tabs.bbeHooked = true
    local bar = bag.tabs
    local origSort = bar.SortTabsByID
    if origSort then
      function bar:SortTabsByID(...)
        origSort(self, ...)
        pinBankTab(self)
      end
    end
    local origMove = bar.MoveToEnd
    if origMove then
      function bar:MoveToEnd(...)
        origMove(self, ...)
        pinBankTab(self)
      end
    end
    local origClick = bar.clickHandler
    bar:SetClickHandler(function(ctx, tabID, button)
      if tabID == BANK_TAB_ID then
        if button ~= "LeftButton" then
          return false
        end
        showBank()
        return true
      end
      if button == "LeftButton" and tabID and tabID > 0 then
        hideBank()
      end
      if origClick then
        return origClick(ctx, tabID, button)
      end
      return true
    end)
    local behavior = bag.behavior
    if behavior and behavior.GenerateGroupTabs then
      hooksecurefunc(behavior, "GenerateGroupTabs", function()
        applyTabMode(bag)
      end)
    end
    local bb = betterBags()
    local tabsMod = bb and bb:GetModule("Tabs", true)
    if tabsMod and not tabsMod.bbeReorderHooked then
      tabsMod.bbeReorderHooked = true
      local origReorder = tabsMod.IsTabReorderable
      function tabsMod:IsTabReorderable(kind, tab)
        if tab and tab.id == BANK_TAB_ID then
          return false
        end
        return origReorder(self, kind, tab)
      end
    end
  end

  if bag.RefreshTabs and not bag.bbeNextHooked then
    bag.bbeNextHooked = true
    local origRefresh = bag.RefreshTabs
    function bag:RefreshTabs(...)
      origRefresh(self, ...)
      applyTabMode(self)
    end
    local origClick = bag.OnTabClicked
    function bag:OnTabClicked(ctx, id, button)
      if id == BANK_TAB_ID then
        if button == "LeftButton" then
          showBank()
          if self.tabs and self.tabs.Select then
            self.tabs:Select(BANK_TAB_ID, true)
          end
        end
        return
      end
      if button == "LeftButton" and id and id > 0 then
        hideBank()
      end
      if origClick then
        return origClick(self, ctx, id, button)
      end
    end
  end

  if bag.Draw and not bag.bbeDrawHooked then
    bag.bbeDrawHooked = true
    hooksecurefunc(bag, "Draw", function(self)
      if viewingBank and self == boundBag then
        local overlay = self.bbeOverlay
        if overlay then
          overlay:Show()
        end
      end
    end)
  end

  if bag.LayoutHeader and not bag.bbeHeaderHooked then
    bag.bbeHeaderHooked = true
    hooksecurefunc(bag, "LayoutHeader", function(self)
      if self == boundBag then
        applyTabMode(self)
      end
    end)
  end

  bag.frame:HookScript("OnShow", function()
    C_Timer.After(0, function()
      if bag.bbeSearch then
        placeAccountSearch(bag)
      end
    end)
  end)
  bag.frame:HookScript("OnHide", function()
    if resultsFrame then
      resultsFrame:Hide()
    end
    hideCharMenu()
    if searchEdit then
      searchEdit:ClearFocus()
    end
    if viewingBank then
      hideBank()
      if bag.tabs and bag.tabs.SetTabByID and bag.tabs.TabExistsByID and bag.tabs:TabExistsByID(1) then
        local bb = betterBags()
        local context = bb and bb:GetModule("Context", true)
        if context then
          bag.tabs:SetTabByID(context:New("BBE_CloseBank"), 1)
        end
      end
      if bag.tabs and bag.tabs.Select then
        bag.tabs:Select(1, false)
      end
    end
  end)
  bag.frame:HookScript("OnSizeChanged", function()
    applyTabMode(bag)
    if viewingBank then
      layoutBank()
    end
  end)

  applyTabMode(bag)
  if viewingBank then
    showBank()
  end
end

local function tryBind()
  local bb = betterBags()
  if not bb or not bb.Bags or not bb.Bags.Backpack or not bb.Bags.Backpack.frame then
    return false
  end
  local bag = bb.Bags.Backpack
  if boundBag ~= bag then
    boundBag = nil
    bindBag(bag)
  end
  local bagSystem = bb:GetModule("BagSystem", true)
  if bagSystem and not bagSystem.bbeSwitchHooked then
    bagSystem.bbeSwitchHooked = true
    hooksecurefunc(bagSystem, "Switch", function()
      C_Timer.After(0, function()
        boundBag = nil
        tryBind()
      end)
    end)
  end
  return true
end

-- ItemRack sets ----------------------------------------------------------
-- C_ItemRackSet reads this character's ItemRackUser.Sets (names are the set
-- ids). Hidden ItemRack sets, whose names start with "~", are left out.
-- Each item is filed under "ItemRack: <set>". An item in several sets uses
-- the first set name in alphabetical order, which is the one category
-- BetterBags can show.

C_ItemRackSet = C_ItemRackSet or {}

local rackSets = {}
local rackItemSets = {}
local rackCategoryNames = {}
local rackSignature = ""
local rackCategoryHooked = false

local function rackItemID(stored)
  if stored == nil or stored == 0 or stored == "0" or stored == false then
    return nil
  end
  local id = tonumber(tostring(stored):match("^(%-?%d+)"))
  if id and id > 0 then
    return id
  end
end

local function rackSetHidden(name)
  return type(name) ~= "string" or name == "" or name:sub(1, 1) == "~"
end

function C_ItemRackSet.GetSetIDs()
  local ids = {}
  local sets = ItemRackUser and ItemRackUser.Sets
  if type(sets) ~= "table" then
    return ids
  end
  for name in pairs(sets) do
    if not rackSetHidden(name) then
      ids[#ids + 1] = name
    end
  end
  table.sort(ids)
  return ids
end

function C_ItemRackSet.GetItemIDs(setID)
  if not rackSets[setID] then
    C_ItemRackSet.Refresh()
  end
  local list = {}
  local info = rackSets[setID]
  if info then
    for itemID in pairs(info.itemIDs) do
      list[#list + 1] = itemID
    end
    table.sort(list)
  end
  return list
end

function C_ItemRackSet.GetSetInfo(setID)
  local set = ItemRackUser and ItemRackUser.Sets and ItemRackUser.Sets[setID]
  if type(set) ~= "table" or rackSetHidden(setID) then
    return
  end
  local ids = C_ItemRackSet.GetItemIDs(setID)
  local equipped = ItemRack and ItemRack.IsSetEquipped and ItemRack.IsSetEquipped(setID) and true or false
  return setID, set.icon, setID, equipped, #ids
end

function C_ItemRackSet.GetSetsForItem(item)
  local itemID = tonumber(item) or rackItemID(item)
  local names = itemID and rackItemSets[itemID]
  local copy = {}
  if names then
    for i, name in ipairs(names) do
      copy[i] = name
    end
  end
  return copy
end

local function clearRackAssignments(previousItems)
  local bb = betterBags()
  local categories = bb and bb:GetModule("Categories", true)
  if not categories or not categories.RemoveItemFromCategory then
    return
  end
  for itemID, names in pairs(previousItems) do
    for _, name in ipairs(names) do
      pcall(categories.RemoveItemFromCategory, categories, itemID, "ItemRack: " .. name)
    end
  end
end

local function syncRackCategories()
  local bb = betterBags()
  if not bb then
    return
  end
  local categories = bb:GetModule("Categories", true)
  local context = bb:GetModule("Context", true)
  if not categories or not context or not categories.ReprocessAllItems then
    return
  end
  local ctx = context:New("BBE_ItemRackSets")
  local live = {}
  for name in pairs(rackSets) do
    live["ItemRack: " .. name] = true
  end
  for category in pairs(rackCategoryNames) do
    if not live[category] and categories.DeleteCategory then
      pcall(categories.DeleteCategory, categories, ctx, category)
    end
  end
  wipe(rackCategoryNames)
  for category in pairs(live) do
    rackCategoryNames[category] = true
  end
  pcall(categories.ReprocessAllItems, categories, ctx)
end

local function ensureRackCategories()
  if rackCategoryHooked then
    return true
  end
  local bb = betterBags()
  if not bb then
    return false
  end
  local categories = bb:GetModule("Categories", true)
  if not categories or not categories.RegisterCategoryFunction then
    return false
  end
  categories:RegisterCategoryFunction("BetterBags_Companion_ItemRack", function(data)
    local info = data and data.itemInfo
    local itemID = info and info.itemID
    local names = itemID and rackItemSets[itemID]
    if names and names[1] then
      return "ItemRack: " .. names[1]
    end
  end)
  rackCategoryHooked = true
  return true
end

function C_ItemRackSet.Refresh(force)
  local sets = ItemRackUser and ItemRackUser.Sets
  local names = {}
  if type(sets) == "table" then
    for name in pairs(sets) do
      if not rackSetHidden(name) then
        names[#names + 1] = name
      end
    end
    table.sort(names)
  end
  local nextSets = {}
  local nextItems = {}
  local parts = {}
  for _, name in ipairs(names) do
    local set = sets[name]
    local itemIDs = {}
    local idList = {}
    if type(set) == "table" and type(set.equip) == "table" then
      for _, stored in pairs(set.equip) do
        local itemID = rackItemID(stored)
        if itemID then
          itemIDs[itemID] = true
        end
      end
    end
    for itemID in pairs(itemIDs) do
      idList[#idList + 1] = itemID
    end
    table.sort(idList)
    nextSets[name] = { itemIDs = itemIDs, icon = type(set) == "table" and set.icon or nil }
    for _, itemID in ipairs(idList) do
      local list = nextItems[itemID]
      if not list then
        list = {}
        nextItems[itemID] = list
      end
      list[#list + 1] = name
    end
    parts[#parts + 1] = name .. "=" .. table.concat(idList, ",")
  end
  for _, list in pairs(nextItems) do
    table.sort(list)
  end
  local signature = table.concat(parts, "|")
  local changed = force == true or signature ~= rackSignature
  local previousItems = rackItemSets
  rackSets = nextSets
  rackItemSets = nextItems
  rackSignature = signature
  if changed and ensureRackCategories() then
    clearRackAssignments(previousItems)
    syncRackCategories()
  end
  return changed
end

eventFrame:SetScript("OnEvent", function(self, event, arg1)
  if event == "ADDON_LOADED" and arg1 == ADDON then
    copyDefaults()
    rebuildIndex()
    hookTooltips()
  elseif event == "ADDON_LOADED" and arg1 == "ItemRack" then
    C_Timer.After(0.2, function()
      C_ItemRackSet.Refresh(true)
    end)
  elseif event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
    queueBagScan()
    C_Timer.After(0.5, tryBind)
    C_Timer.After(1, function()
      C_ItemRackSet.Refresh(true)
    end)
  elseif event == "BAG_UPDATE" or event == "BAG_UPDATE_DELAYED" then
    queueBagScan()
    if bankIsOpen() then
      queueBankScan()
    end
  elseif event == "PLAYER_EQUIPMENT_CHANGED" or (event == "UNIT_INVENTORY_CHANGED" and arg1 == "player") then
    queueBagScan()
  elseif event == "BANKFRAME_OPENED" or event == "PLAYERBANKSLOTS_CHANGED" then
    queueBankScan()
  elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" then
    local kind = Enum and Enum.PlayerInteractionType
    local banker = kind and kind.Banker
    local mailer = kind and (kind.MailInfo or kind.Mail)
    if banker == nil or arg1 == banker then
      queueBankScan()
    end
    if mailer and arg1 == mailer then
      if CheckInbox then
        CheckInbox()
      end
      queueMailScan()
    end
  elseif event == "MAIL_SHOW" then
    if CheckInbox then
      CheckInbox()
    end
    queueMailScan()
  elseif event == "MAIL_INBOX_UPDATE" then
    mailInboxReady = true
    queueMailScan()
  elseif event == "MAIL_CLOSED" then
    mailInboxReady = false
  elseif event == "BANKFRAME_CLOSED" or event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" then
    bankTries = 0
  elseif event == "GET_ITEM_INFO_RECEIVED" then
    patchPending(arg1)
  elseif event == "PLAYER_REGEN_ENABLED" then
    if self.needBankTab then
      self.needBankTab = nil
      tryBind()
      if boundBag then
        applyTabMode(boundBag)
      end
    end
  end
end)

local function registerEvent(event)
  if C_EventUtils and C_EventUtils.IsEventValid and not C_EventUtils.IsEventValid(event) then
    return
  end
  pcall(eventFrame.RegisterEvent, eventFrame, event)
end

registerEvent("ADDON_LOADED")
registerEvent("PLAYER_LOGIN")
registerEvent("PLAYER_ENTERING_WORLD")
registerEvent("BAG_UPDATE")
registerEvent("BAG_UPDATE_DELAYED")
registerEvent("PLAYER_EQUIPMENT_CHANGED")
registerEvent("UNIT_INVENTORY_CHANGED")
registerEvent("BANKFRAME_OPENED")
registerEvent("BANKFRAME_CLOSED")
registerEvent("PLAYERBANKSLOTS_CHANGED")
registerEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
registerEvent("PLAYER_INTERACTION_MANAGER_FRAME_HIDE")
registerEvent("MAIL_SHOW")
registerEvent("MAIL_INBOX_UPDATE")
registerEvent("MAIL_CLOSED")
registerEvent("GET_ITEM_INFO_RECEIVED")
registerEvent("PLAYER_REGEN_ENABLED")

C_Timer.NewTicker(2, function()
  C_ItemRackSet.Refresh()
end)

copyDefaults()
hookTooltips()

local watchTries = 0
local function watchForBackpack()
  if tryBind() then
    return
  end
  watchTries = watchTries + 1
  if watchTries < 40 then
    C_Timer.After(0.5, watchForBackpack)
  end
end
C_Timer.After(0.5, watchForBackpack)

SLASH_BETTERBAGSCOMPANION1 = "/bbe"
SLASH_BETTERBAGSCOMPANION2 = "/betterbagscompanion"
SlashCmdList.BETTERBAGSCOMPANION = function(msg)
  msg = (msg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  if msg == "scan" then
    scanBagsAndGear()
    if bankIsOpen() then
      scanBank()
    end
    if mailIsOpen() then
      scanMail()
    end
  end
  local chars = 0
  local items = 0
  for _ in pairs(db.chars) do
    chars = chars + 1
  end
  for _ in pairs(index) do
    items = items + 1
  end
  print(string.format("|cffffd100BetterBags Companion|r: %d characters, %d item types. Open the bank and the mailbox once on each character to snapshot them. /bbe scan refreshes this character.", chars, items))
end
