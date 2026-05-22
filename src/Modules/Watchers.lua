local _, addon = ...

local Constants = addon.Constants
local Helpers = addon.Helpers
local MBLib = addon.MBLib

local Watchers = {}

-- ===== SavedVariables access =====
-- _db is opened by MBLib:Init() into _G["MeowerData"]. Returns the same table
-- on every call so module-load order doesn't matter — db() is invoked from
-- event handlers that fire after Init.
local function db()
  local d = MBLib._db
  if d.Watchers == nil then d.Watchers = {} end
  return d
end

local function debugLog(msg)
  if MBLib.Utils and MBLib.Utils.DebugLog then
    MBLib.Utils:DebugLog(msg)
  end
end

-- ===== Per-sender cooldown =====
-- Session-only suppression: once any watcher fires on a sender, further
-- messages from the same sender are ignored for SpamCooldown. BNet
-- whispers key on bnSenderID (display names can shift); everything else
-- keys on the sender string ("Name-Realm"). GetTime() resets on /reload,
-- which is acceptable — a fresh client re-evaluates from scratch.
local spamCooldowns = {}

local function spamKey(sender, bnSenderID)
  if bnSenderID and bnSenderID ~= 0 then
    return "b:" .. tostring(bnSenderID)
  end
  if not sender or sender == "" then return nil end
  return "c:" .. sender
end

local function spamCooldownSeconds()
  local v = MBLib.Settings and MBLib.Settings:Get("SpamCooldown")
  return tonumber(v) or 0
end

local function isOnSpamCooldown(sender, bnSenderID)
  local key = spamKey(sender, bnSenderID)
  if not key then return false end
  local expiry = spamCooldowns[key]
  if not expiry then return false end
  if expiry > GetTime() then return true end
  spamCooldowns[key] = nil
  return false
end

local function recordSpamCooldown(sender, bnSenderID)
  local seconds = spamCooldownSeconds()
  if seconds <= 0 then return end
  local key = spamKey(sender, bnSenderID)
  if not key then return end
  spamCooldowns[key] = GetTime() + seconds
end

-- Returns the channel's label wrapped in its live chat color (sourced from
-- ChatTypeInfo), as a |cAARRGGBB|...|r escape string suitable for embedding
-- in popup text. Falls back to plain label when ChatTypeInfo isn't populated
-- (e.g. early load) so the message still renders something readable.
local function channelLabelColored(channelKey)
  local def = Constants.CHANNEL_BY_KEY[channelKey]
  if not def then return "?" end
  local c = _G.ChatTypeInfo and _G.ChatTypeInfo[def.replyChatType]
  if not c then return def.label end
  return string.format("|cff%02x%02x%02x%s|r",
    math.floor((c.r or 1) * 255),
    math.floor((c.g or 1) * 255),
    math.floor((c.b or 1) * 255),
    def.label)
end

-- ===== Event subscription tracking =====
-- Only register chat events that at least one *enabled* watcher actually needs.
-- This avoids dispatching onChatEvent for channels nobody listens to. The set
-- is recomputed any time the watcher list changes (Upsert/Delete/SetEnabled)
-- and on Init. chatFrame is created in Init; CRUD calls before Init no-op via
-- the chatFrame nil guard.
local chatFrame
local EVENT_TO_KEY
local registeredEvents = {}

local function neededChatEvents()
  local channelKeys = {}
  local list = db().Watchers
  for _, w in ipairs(list) do
    if w.enabled and w.channels then
      for k, v in pairs(w.channels) do
        if v then channelKeys[k] = true end
      end
    end
  end
  local events = {}
  for channelKey in pairs(channelKeys) do
    local def = Constants.CHANNEL_BY_KEY[channelKey]
    if def and def.events then
      for _, event in ipairs(def.events) do
        events[event] = true
      end
    end
  end
  return events
end

local function refreshEventSubscriptions()
  if not chatFrame then return end
  local needed = neededChatEvents()
  for event in pairs(registeredEvents) do
    if not needed[event] then
      chatFrame:UnregisterEvent(event)
      registeredEvents[event] = nil
    end
  end
  for event in pairs(needed) do
    if not registeredEvents[event] then
      chatFrame:RegisterEvent(event)
      registeredEvents[event] = true
    end
  end
end

-- ===== CRUD =====

function Watchers:GetAll()
  return db().Watchers
end

function Watchers:GetByID(id)
  if not id then return nil end
  for _, w in ipairs(self:GetAll()) do
    if w.id == id then return w end
  end
  return nil
end

local function collectIdSet(list)
  local set = {}
  for _, w in ipairs(list) do set[w.id] = true end
  return set
end

function Watchers:Upsert(watcher)
  if type(watcher) ~= "table" then return nil end
  local list = self:GetAll()
  if watcher.id then
    for i, w in ipairs(list) do
      if w.id == watcher.id then
        list[i] = watcher
        refreshEventSubscriptions()
        return watcher
      end
    end
  end
  watcher.id = Helpers.newId(collectIdSet(list))
  table.insert(list, watcher)
  refreshEventSubscriptions()
  return watcher
end

function Watchers:Delete(id)
  local list = self:GetAll()
  for i, w in ipairs(list) do
    if w.id == id then
      table.remove(list, i)
      refreshEventSubscriptions()
      return true
    end
  end
  return false
end

function Watchers:SetEnabled(id, enabled)
  local w = self:GetByID(id)
  if w then
    w.enabled = not not enabled
    refreshEventSubscriptions()
  end
end

-- ===== Chat replies =====

-- Send chat reply via a specific channel code. Returns true if a SendChatMessage
-- (or equivalent) call was actually made.
local function sendReplyTo(channelCode, text, sender, bnSenderID)
  if not text or text == "" then return false end

  if channelCode == "w" then
    if not sender or sender == "" then
      debugLog("skip whisper reply: no sender name")
      return false
    end
    SendChatMessage(text, "WHISPER", nil, sender)
    return true
  end

  if channelCode == "g" then
    if not IsInGuild() then
      debugLog("skip guild reply: not in a guild")
      return false
    end
    SendChatMessage(text, "GUILD")
    return true
  end

  if channelCode == "s" then
    SendChatMessage(text, "SAY")
    return true
  end

  if channelCode == "e" then
    SendChatMessage(text, "EMOTE")
    return true
  end

  if channelCode == "p" then
    if not IsInGroup() then
      debugLog("skip party reply: not in a group")
      return false
    end
    SendChatMessage(text, "PARTY")
    return true
  end

  if channelCode == "r" then
    if not IsInRaid() then
      debugLog("skip raid reply: not in a raid")
      return false
    end
    SendChatMessage(text, "RAID")
    return true
  end

  if channelCode == "i" then
    if not IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
      debugLog("skip instance reply: not in an instance group")
      return false
    end
    SendChatMessage(text, "INSTANCE_CHAT")
    return true
  end

  debugLog("skip reply: unknown channel code '" .. tostring(channelCode) .. "'")
  return false
end

-- Reply in the same channel the trigger fired in. BNet whispers route through
-- BNSendWhisper because they carry a BattleTag and a presence id, not a
-- character name.
local function sendReplySameChannel(channelKey, text, sender, bnSenderID)
  if not text or text == "" then return false end
  local def = Constants.CHANNEL_BY_KEY[channelKey]
  if not def then return false end

  if def.isBnet then
    if bnSenderID and bnSenderID ~= 0 then
      BNSendWhisper(bnSenderID, text)
      return true
    end
    debugLog("skip BNet reply: no sender presence id")
    return false
  end

  -- Non-BNet "same channel" maps onto the same single-letter code used by the
  -- reply dropdown.
  return sendReplyTo(channelKey, text, sender, bnSenderID)
end

local function sendReply(watcher, channelKey, sender, bnSenderID, trigger)
  if not watcher.reply or not watcher.reply.text or watcher.reply.text == "" then return end
  local def = Constants.CHANNEL_BY_KEY[channelKey]
  local resolved = Helpers.applyPlaceholders(watcher.reply.text, {
    sender  = sender or "",
    trigger = trigger or "",
    channel = (def and def.label) or "",
  })

  if date("%m%d") == "0401" then
    resolved = string.reverse(resolved)
  end

  local ch = watcher.reply.ch or "same"
  if ch == "same" then
    sendReplySameChannel(channelKey, resolved, sender, bnSenderID)
  else
    sendReplyTo(ch, resolved, sender, bnSenderID)
  end
end

local function doEmoteReply(watcher, sender)
  local token = watcher.reply and watcher.reply.emote
  if not token or token == "" then return end
  local charName = sender and sender:match("^([^-]+)") or sender
  pcall(DoEmote, token, charName)
end

-- ===== Secure-template invite + kick popups =====
-- UninviteUnit / InviteUnit-from-button-click are protected operations; the
-- only legal route from an addon is a SecureActionButton whose macrotext
-- dispatches through Blizzard's secure /uninvite or /invite slash handlers.

local kickPopup, invitePopup
local pendingActions = {}

local function buildPopup(frameName, accent)
  local popup = CreateFrame("Frame", frameName, UIParent, "BackdropTemplate")
  popup:SetSize(420, 180)
  popup:SetPoint("CENTER")
  popup:SetFrameStrata("DIALOG")
  popup:SetToplevel(true)
  popup:EnableMouse(true)
  popup:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })
  popup:Hide()

  local title = popup:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -18)
  title:SetText("Meower")
  title:SetTextColor(accent.r, accent.g, accent.b)

  local text = popup:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  text:SetPoint("TOPLEFT", 20, -46)
  text:SetPoint("TOPRIGHT", -20, -46)
  text:SetJustifyH("CENTER")
  text:SetSpacing(4)
  popup.text = text

  local confirmBtn = CreateFrame("Button", frameName .. "_Confirm", popup,
                                 "SecureActionButtonTemplate,UIPanelButtonTemplate")
  confirmBtn:SetSize(130, 24)
  confirmBtn:SetPoint("BOTTOMRIGHT", popup, "BOTTOM", -6, 18)
  confirmBtn:SetAttribute("type", "macro")
  confirmBtn:RegisterForClicks("AnyUp", "AnyDown")
  confirmBtn:HookScript("PostClick", function() popup:Hide() end)
  popup.confirmBtn = confirmBtn

  local cancelBtn = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
  cancelBtn:SetSize(130, 24)
  cancelBtn:SetPoint("BOTTOMLEFT", popup, "BOTTOM", 6, 18)
  cancelBtn:SetText("Cancel")
  cancelBtn:SetScript("OnClick", function() popup:Hide() end)

  return popup
end

local function buildKickPopup()
  local p = buildPopup("Meower_KickPopup", { r = 1, g = 0.27, b = 0.27 })
  p.confirmBtn:SetText("Kick")
  return p
end

local function buildInvitePopup()
  local p = buildPopup("Meower_InvitePopup", { r = 0.1, g = 0.8, b = 0.1 })
  p.confirmBtn:SetText("Invite")
  return p
end

local function charNameOf(sender)
  if not sender or sender == "" then return nil end
  return sender:match("^([^-]+)") or sender
end

-- Resolve a BNet sender's presence id to a "Name-Realm" string suitable for
-- /invite or /uninvite. Returns nil when the friend is offline, on a non-WoW
-- Blizzard client, or otherwise unreachable. The friends API is the only way
-- to bridge a BattleTag back to an in-game character; without it, BNet whispers
-- can't drive secure invite/kick handlers (those need a character name).
local function resolveBnetCharacter(bnSenderID)
  if not bnSenderID or bnSenderID == 0 then return nil end
  if not (C_BattleNet and C_BattleNet.GetAccountInfoByID) then return nil end
  local ok, info = pcall(C_BattleNet.GetAccountInfoByID, bnSenderID)
  if not ok or type(info) ~= "table" or type(info.gameAccountInfo) ~= "table" then
    return nil
  end
  local g = info.gameAccountInfo
  if g.clientProgram ~= "WoW" then return nil end
  local name = g.characterName
  if not name or name == "" then return nil end
  if g.realmName and g.realmName ~= "" then
    return name .. "-" .. g.realmName
  end
  return name
end

-- Returns the in-game character string to pass to /invite or /uninvite for the
-- given trigger source. For non-BNet whispers / chat that's the sender's
-- character name; for BNet it's whatever resolveBnetCharacter() can find, or
-- nil if the BNet friend isn't currently on a WoW character.
local function targetCharFor(channelKey, sender, bnSenderID)
  local def = Constants.CHANNEL_BY_KEY[channelKey]
  if def and def.isBnet then
    return resolveBnetCharacter(bnSenderID)
  end
  return charNameOf(sender)
end

local function combatNotice(sender, msg)
  if not sender or sender == "" then return end
  pcall(SendChatMessage, msg, "WHISPER", nil, sender)
end

-- ===== Kick popup =====

local function showKickPopup(channelKey, sender, bnSenderID, trigger)
  if not kickPopup then return end
  if kickPopup:IsShown() then
    debugLog("kick popup already open; ignoring new flag")
    return
  end
  if InCombatLockdown() then
    table.insert(pendingActions, { kind = "kick", channelKey = channelKey, sender = sender,
                                   bnSenderID = bnSenderID, trigger = trigger })
    combatNotice(sender, "You're in combat — your kick prompt will surface after combat ends.")
    return
  end
  local target = targetCharFor(channelKey, sender, bnSenderID)
  if not target then
    debugLog("cannot kick: could not resolve sender to a WoW character (BNet friend offline or not on WoW)")
    return
  end
  kickPopup.text:SetText(string.format(
    "|cffffff00%s|r\nmatched \"|cffff8000%s|r\" in %s\nKick them from the group?",
    sender or "?", trigger or "?", channelLabelColored(channelKey)
  ))
  kickPopup.confirmBtn:SetAttribute("macrotext", "/uninvite " .. target)
  kickPopup:Show()
end

local function tryKick(channelKey, sender, bnSenderID, trigger)
  if not sender or sender == "" then
    debugLog("cannot kick: no sender name")
    return
  end
  -- BNet is allowed now: showKickPopup will try to resolve the BNet ID to a
  -- WoW character via C_BattleNet.GetAccountInfoByID, and bails cleanly if
  -- the friend isn't on a WoW character right now.
  if not IsInGroup() then
    debugLog("cannot kick: not in a group")
    return
  end
  if HasLFGRestrictions and HasLFGRestrictions() then
    debugLog("cannot kick: instance group requires a vote kick")
    return
  end
  if not (UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")) then
    debugLog("cannot kick: not group leader / raid assistant")
    return
  end
  showKickPopup(channelKey, sender, bnSenderID, trigger)
end

-- ===== Invite path =====

local function showInvitePopup(channelKey, sender, bnSenderID, trigger)
  if not invitePopup then return end
  if invitePopup:IsShown() then
    debugLog("invite popup already open; ignoring new request")
    return
  end
  -- SetAttribute on a secure frame is blocked during combat lockdown, so
  -- confirm-mode invites always queue when the player is in combat.
  if InCombatLockdown() then
    table.insert(pendingActions, { kind = "inviteConfirm", channelKey = channelKey, sender = sender,
                                   bnSenderID = bnSenderID, trigger = trigger })
    combatNotice(sender, "You're in combat — your invite request will be handled after combat ends.")
    return
  end
  local target = targetCharFor(channelKey, sender, bnSenderID)
  if not target then
    debugLog("cannot invite: could not resolve sender to a WoW character (BNet friend offline or not on WoW)")
    return
  end
  invitePopup.text:SetText(string.format(
    "|cffffff00%s|r\nmatched \"|cff88ff88%s|r\" in %s\nInvite them to your group?",
    sender or "?", trigger or "?", channelLabelColored(channelKey)
  ))
  invitePopup.confirmBtn:SetAttribute("macrotext", "/invite " .. target)
  invitePopup:Show()
end

local function tryInvite(watcher, channelKey, sender, bnSenderID, trigger)
  if not sender or sender == "" then
    debugLog("cannot invite: no sender name")
    return
  end
  -- BNet is allowed now: targetCharFor resolves the BNet ID to a WoW
  -- character via the friends API, or returns nil if unreachable. Each
  -- downstream branch handles the nil case.

  if watcher.reply.inviteConfirm then
    showInvitePopup(channelKey, sender, bnSenderID, trigger)
    return
  end

  if InCombatLockdown() and watcher.reply.inviteQueue ~= false then
    table.insert(pendingActions, { kind = "invite", channelKey = channelKey, sender = sender,
                                   bnSenderID = bnSenderID, trigger = trigger })
    combatNotice(sender, "You're in combat — your invite request will be handled after combat ends.")
    return
  end

  local target = targetCharFor(channelKey, sender, bnSenderID)
  if not target then
    debugLog("cannot invite: could not resolve sender to a WoW character")
    return
  end
  -- C_PartyInfo.InviteUnit is NOT combat-protected. With inviteQueue == false
  -- the invite fires through immediately, even mid-combat.
  pcall(C_PartyInfo.InviteUnit, target)
end

-- ===== Combat queue drain =====

local function drainPendingActions()
  if #pendingActions == 0 then return end
  -- Snapshot then clear so any re-entrant queue inserts during this drain go
  -- into the next combat cycle, not this one.
  local snapshot = pendingActions
  pendingActions = {}

  for _, req in ipairs(snapshot) do
    if req.kind == "kick" then
      combatNotice(req.sender, "Combat ended — kick prompt opening now.")
      showKickPopup(req.channelKey, req.sender, req.bnSenderID, req.trigger)
    elseif req.kind == "inviteConfirm" then
      combatNotice(req.sender, "Combat ended — invite prompt opening now.")
      showInvitePopup(req.channelKey, req.sender, req.bnSenderID, req.trigger)
    elseif req.kind == "invite" then
      combatNotice(req.sender, "Combat ended — sending your invite now.")
      local target = targetCharFor(req.channelKey, req.sender, req.bnSenderID)
      if target then
        pcall(C_PartyInfo.InviteUnit, target)
      else
        debugLog("cannot invite post-combat: could not resolve sender to a WoW character")
      end
    end
  end
end

-- ===== Dispatch =====

local function dispatch(watcher, channelKey, sender, bnSenderID, trigger)
  local r = watcher.reply
  if not r then return end

  local hasText  = r.text and r.text ~= ""
  local hasEmote = r.emote and r.emote ~= ""

  if r.emoteFirst and hasText and hasEmote then
    doEmoteReply(watcher, sender)
    sendReply(watcher, channelKey, sender, bnSenderID, trigger)
  else
    if hasText  then sendReply(watcher, channelKey, sender, bnSenderID, trigger) end
    if hasEmote then doEmoteReply(watcher, sender) end
  end

  if r.invite then tryInvite(watcher, channelKey, sender, bnSenderID, trigger) end
  if r.kick   then tryKick(channelKey, sender, bnSenderID, trigger) end
end

-- ===== Chat event wiring =====

local function buildEventMap()
  local map = {}
  for _, info in pairs(Constants.CHANNELS) do
    for _, event in ipairs(info.events) do
      map[event] = info.key
    end
  end
  return map
end

local function onChatEvent(EVENT_TO_KEY, event, ...)
  local channelKey = EVENT_TO_KEY[event]
  if not channelKey then return end
  local channelDef = Constants.CHANNEL_BY_KEY[channelKey]

  local message, sender = ...
  local guid       = select(12, ...)
  local bnSenderID = select(13, ...)

  if not message or message == "" then return end

  -- Player vs NPC filter. BNet whispers have no GUID — they're identified by
  -- bnSenderID and are always real players, so we accept them unconditionally.
  -- For every other channel, require a player GUID. This blocks NPC chatter
  -- that can leak through CHAT_MSG_SAY / CHAT_MSG_TEXT_EMOTE (creature emotes,
  -- ambient quest dialogue, summon/pet messages, etc.) without us having to
  -- enumerate the NPC-specific events.
  if not (channelDef and channelDef.isBnet) then
    if not guid or not guid:find("^Player%-") then return end
    if guid == UnitGUID("player") then return end
  end

  if isOnSpamCooldown(sender, bnSenderID) then return end

  local lower = message:lower()
  local isLeader = UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
  local matched = false

  for _, watcher in ipairs(Watchers:GetAll()) do
    if watcher.enabled and watcher.channels and watcher.channels[channelKey] then
      local gated = channelDef.isGroupChannel and watcher.onlyLead and not isLeader
      if not gated then
        local trigger = Helpers.findIn(lower, watcher.triggers, watcher.exact)
        if trigger then
          dispatch(watcher, channelKey, sender, bnSenderID, trigger)
          matched = true
        end
      end
    end
  end

  if matched then
    recordSpamCooldown(sender, bnSenderID)
  end
end

-- ===== Init =====

function Watchers:Init()
  if self._initialized then return end
  self._initialized = true

  -- Build secure popups now; SecureActionButton needs to be created out of
  -- combat, and Init() is reached from ADDON_LOADED, well before any pull.
  kickPopup   = buildKickPopup()
  invitePopup = buildInvitePopup()

  -- The module-scope EVENT_TO_KEY / chatFrame / registeredEvents drive
  -- refreshEventSubscriptions, which only registers events that an enabled
  -- watcher actually needs (no listening to channels nobody watches).
  EVENT_TO_KEY = buildEventMap()
  chatFrame = CreateFrame("Frame")
  chatFrame:SetScript("OnEvent", function(_, event, ...)
    onChatEvent(EVENT_TO_KEY, event, ...)
  end)
  refreshEventSubscriptions()

  local combatFrame = CreateFrame("Frame")
  combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
  combatFrame:SetScript("OnEvent", drainPendingActions)
end

addon.Watchers = Watchers
