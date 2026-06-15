local _, addon = ...

local Constants = addon.Constants
local Helpers = addon.Helpers
local MBLib = addon.MBLib
local Hooks = addon.Hooks
local L = addon.L

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

-- ===== Profile-aware storage =====
-- Watchers live in two buckets:
--   * account-wide ("global") — MBLib.Profiles:GetAccount().Watchers, shared
--     across every character on the account
--   * profile-scoped — MBLib.Profiles:GetActive().Watchers, lives in the
--     character's currently-active profile
--
-- The per-watcher `accountWide` flag picks which bucket the watcher lives
-- in. Reads merge both buckets so dispatch / UI see one logical list;
-- writes route to the correct bucket based on the flag (Upsert) or by
-- finding the watcher's current bucket (Delete, SetEnabled, mutation).
--
-- Legacy SavedVariables had a single flat `_db.Watchers` list. Migration
-- (one-shot, in Init) moves everything in that list into the active
-- profile's Watchers — that matches "what the user had configured was
-- this-character data" — and clears the legacy slot.
local function accountWatchers()
  local P = addon.MBLib and addon.MBLib.Profiles
  if not (P and P.IsEnabled and P:IsEnabled()) then
    -- Profiles disabled (e.g. legacy SV or transient state during init):
    -- fall back to flat _db.Watchers so the rest of the module keeps
    -- working until Profiles is wired.
    local d = db()
    return d.Watchers
  end
  local account = P:GetAccount()
  if not account then return {} end
  if type(account.Watchers) ~= "table" then account.Watchers = {} end
  return account.Watchers
end

local function profileWatchers()
  local P = addon.MBLib and addon.MBLib.Profiles
  if not (P and P.IsEnabled and P:IsEnabled()) then return {} end
  local profile = P:GetActive()
  if not profile then return {} end
  if type(profile.Watchers) ~= "table" then profile.Watchers = {} end
  return profile.Watchers
end

-- Returns the live backing array containing watcher.id, plus the index
-- within it. Used by mutation paths (Delete, SetEnabled, in-place edit
-- via Upsert when id matches). Returns nil when the id isn't found in
-- either bucket.
local function findWatcherBucket(id)
  if not id then return nil end
  for i, w in ipairs(accountWatchers()) do
    if w.id == id then return accountWatchers(), i, "account" end
  end
  for i, w in ipairs(profileWatchers()) do
    if w.id == id then return profileWatchers(), i, "profile" end
  end
  return nil
end

local function debugLog(msg)
  if MBLib.Utils and MBLib.Utils.DebugLog then
    MBLib.Utils:DebugLog(msg)
  end
end

-- ===== Schema normalization =====
-- Legacy SavedVariables had scalar reply.text / reply.emote and no filters
-- block. Phase 2 introduced reply.texts / reply.emotes as lists; Phase 3
-- added the per-watcher filters table. normalizeWatcher() lifts each watcher
-- forward in place so downstream code (UI, dispatch) can assume the modern
-- shape unconditionally — no `or {}` defensive reads scattered everywhere.
local function ensureList(v)
  if type(v) == "table" then return v end
  if type(v) == "string" and v ~= "" then return { v } end
  return {}
end

-- Deep-copy that's safe for the small, table-only watcher shape. We don't
-- need to handle cycles or metatables — watcher state is plain data.
local function deepCopyDefaults(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deepCopyDefaults(v) end
  return out
end

local function normalizeWatcher(w)
  if type(w) ~= "table" then return end
  w.reply = w.reply or {}
  -- accountWide picks which storage bucket the watcher lives in (account
  -- vs active profile). Legacy watchers predate this field — default to
  -- false so existing rows stay where they currently are (the profile
  -- bucket they were migrated into).
  if w.accountWide == nil then w.accountWide = false end

  -- Per-trigger case-sensitive flags parallel to w.triggers. Older watchers
  -- predate this field — default everything to nil (case-insensitive).
  if type(w.triggerCaseSensitive) ~= "table" then
    w.triggerCaseSensitive = {}
  end

  -- Per-trigger exact-match flags parallel to w.triggers. Lifts the legacy
  -- whole-watcher `exact` boolean into the per-phrase array: when the old
  -- field was true, every existing phrase gets exact=true so behavior is
  -- preserved. We then clear the legacy field so future loads don't keep
  -- re-migrating it.
  if type(w.triggerExact) ~= "table" then
    w.triggerExact = {}
  end
  if w.exact then
    for i = 1, #(w.triggers or {}) do
      if w.triggerExact[i] == nil then w.triggerExact[i] = true end
    end
    w.exact = nil
  end

  -- Per-trigger "partial match" (plain substring contains) flags. Mutually
  -- exclusive with triggerExact at the UI layer; older watchers predate
  -- this and default to nil (= whole-word matching, the historical
  -- behavior).
  if type(w.triggerPartial) ~= "table" then
    w.triggerPartial = {}
  end

  -- Texts / emotes: lift scalar fields into list form and drop the originals
  -- so future loads don't keep re-migrating. An entry with both .text and
  -- .texts (shouldn't happen normally) prefers the existing .texts.
  if w.reply.texts == nil then
    w.reply.texts = ensureList(w.reply.text)
  end
  w.reply.text = nil

  if w.reply.emotes == nil then
    w.reply.emotes = ensureList(w.reply.emote)
  end
  w.reply.emote = nil

  -- Per-emote "non-targeted" flags parallel to w.reply.emotes. Older
  -- watchers had a single watcher-level boolean; lift it into the per-
  -- emote array so every existing emote inherits the same flag, then
  -- drop the legacy scalar. The default at runtime is false (targeted).
  if type(w.reply.emoteNonTargeted) == "boolean" then
    local was = w.reply.emoteNonTargeted
    w.reply.emoteNonTargeted = {}
    if was then
      for i = 1, #(w.reply.emotes or {}) do
        w.reply.emoteNonTargeted[i] = true
      end
    end
  elseif type(w.reply.emoteNonTargeted) ~= "table" then
    w.reply.emoteNonTargeted = {}
  end

  -- Notifications block: added later than the reply block, so legacy watchers
  -- need it filled in. Defaults to no sound and noReply=false.
  w.notifications = w.notifications or {}
  if w.notifications.sound == nil then
    w.notifications.sound = Constants.SOUND_NONE
  end
  if w.notifications.noReply == nil then
    w.notifications.noReply = false
  end
  if type(w.notifications.triggerColors) ~= "table" then
    w.notifications.triggerColors = {}
  end

  -- Per-section master toggles. Legacy watchers predate them — derive from
  -- "has data" so the section starts expanded for users who already
  -- configured it, collapsed otherwise. Once the flags exist they're the
  -- source of truth (and unticking clears the underlying data).
  if w.notifications.soundEnabled == nil then
    local sv = w.notifications.sound
    w.notifications.soundEnabled = sv ~= nil
      and sv ~= Constants.SOUND_NONE
      and not (type(sv) == "string" and sv == "")
  end
  if w.notifications.coloringEnabled == nil then
    local any = false
    for _, v in pairs(w.notifications.triggerColors) do
      if v and v ~= "" then any = true break end
    end
    w.notifications.coloringEnabled = any
  end

  -- Icon notification block. Added in 12.0.5.2 (Phase 2). Legacy watchers
  -- get the defaults filled in here; later loads see the modern shape.
  -- position stays nil until the user runs the Mover for this watcher —
  -- at that point IconDisplay's onSave callback persists the tuple.
  if type(w.notifications.icon) ~= "table" then
    w.notifications.icon = {}
  end
  local ic = w.notifications.icon
  if ic.fileID == nil      then ic.fileID = nil end
  if ic.size == nil        then ic.size        = Constants.ICON_DEFAULT_SIZE end
  if ic.fadeSeconds == nil then ic.fadeSeconds = Constants.ICON_DEFAULT_FADE end
  if w.notifications.iconEnabled == nil then
    w.notifications.iconEnabled = ic.fileID ~= nil
  end
  -- position intentionally left nil when unset — IconDisplay treats nil as
  -- "place at screen center" until the user repositions via the Mover.

  -- guildInvite action: nil on legacy watchers, default off.
  if w.reply.guildInvite == nil then
    w.reply.guildInvite = false
  end

  -- Per-section master toggles for the Reply tab. Mirrors the Notifications
  -- tab pattern: legacy watchers predate them, derive from "has data" so
  -- the section starts expanded for already-configured watchers. Once set
  -- the flags are the source of truth (and unticking clears the data).
  if w.reply.textEnabled == nil then
    local any = false
    for _, t in ipairs(w.reply.texts or {}) do
      if t and t ~= "" then any = true break end
    end
    w.reply.textEnabled = any
  end
  if w.reply.emoteEnabled == nil then
    w.reply.emoteEnabled = type(w.reply.emotes) == "table" and #w.reply.emotes > 0
  end
  if w.reply.actionsEnabled == nil then
    w.reply.actionsEnabled = (w.reply.invite or w.reply.guildInvite or w.reply.kick) and true or false
  end

  -- Filters block: fill missing keys from defaults but keep whatever the user
  -- already configured. We don't replace the whole block — the user's saved
  -- mapIDs / days / etc. take priority.
  local defaults = (Constants.NEW_FILTER_DEFAULTS and Constants.NEW_FILTER_DEFAULTS()) or {}
  w.filters = w.filters or {}
  for key, default in pairs(defaults) do
    if w.filters[key] == nil then
      w.filters[key] = deepCopyDefaults(default)
    else
      -- Sub-fields inside a filter block: same fill-missing logic one level
      -- deeper so adding a new sub-field doesn't break existing watchers.
      for subKey, subDefault in pairs(default) do
        if w.filters[key][subKey] == nil then
          w.filters[key][subKey] = deepCopyDefaults(subDefault)
        end
      end
    end
  end
end

-- ===== Reply text / emote picking =====
-- Lists are random-pick: one element per fire. Empty lists return nil so the
-- caller can no-op without an explicit length check.
local function pickRandom(list)
  if type(list) ~= "table" or #list == 0 then return nil end
  if #list == 1 then return list[1] end
  return list[math.random(1, #list)]
end

-- ===== Per-watcher per-sender cooldown =====
-- Session-only suppression keyed on (watcherID, senderKey). Each watcher
-- rate-limits independently per sender — firing watcher A on someone does
-- not gate watcher B from firing on the same person. The cooldown duration
-- defaults to the global SpamCooldown setting but can be overridden by the
-- watcher's filters.cooldown block.
--
-- Keying on watcherID is intentional: if the same watcher is renamed in
-- place, its cooldown carries through; if it's deleted and re-created, the
-- new one gets a fresh slate because newId() bumps the integer suffix.
local spamCooldowns = {}

local function spamKey(sender, bnSenderID)
  if bnSenderID and bnSenderID ~= 0 then
    return "b:" .. tostring(bnSenderID)
  end
  if not sender or sender == "" then return nil end
  return "c:" .. sender
end

local function globalSpamCooldownSeconds()
  local v = MBLib.Settings and MBLib.Settings:Get("SpamCooldown")
  return tonumber(v) or 0
end

-- Cooldown duration this watcher should use after firing. Override wins if
-- enabled, otherwise we fall back to the global setting.
local function cooldownFor(watcher)
  local f = watcher and watcher.filters and watcher.filters.cooldown
  if f and f.enabled then
    return tonumber(f.seconds) or 0
  end
  return globalSpamCooldownSeconds()
end

local function watcherKey(watcher, sender, bnSenderID)
  local sKey = spamKey(sender, bnSenderID)
  if not sKey or not watcher or not watcher.id then return nil end
  return watcher.id .. "|" .. sKey
end

local function isWatcherOnCooldown(watcher, sender, bnSenderID)
  local key = watcherKey(watcher, sender, bnSenderID)
  if not key then return false end
  local expiry = spamCooldowns[key]
  if not expiry then return false end
  if expiry > GetTime() then return true end
  spamCooldowns[key] = nil
  return false
end

local function recordWatcherCooldown(watcher, sender, bnSenderID)
  local seconds = cooldownFor(watcher)
  if seconds <= 0 then return end
  local key = watcherKey(watcher, sender, bnSenderID)
  if not key then return end
  spamCooldowns[key] = GetTime() + seconds
end

-- ===== Anti-mimic =====
-- Per-sender ring buffer of recent lowered message strings + their arrival
-- timestamps. When a new message from the same sender matches an entry that
-- hasn't yet expired, we drop the message entirely (no watcher fires). A
-- small ring (3 slots) catches simple alternating spam ("A B A B A") where
-- a 1-slot tracker would miss every other repeat. Slots are session-only
-- and shared across all watchers — this is a global-style filter that gates
-- BEFORE per-watcher dispatch.
local ANTI_MIMIC_RING_SIZE = 3
local antiMimicLog = {}

-- Window seconds doubles as the on/off switch: 0 disables anti-mimic
-- entirely (same convention as SpamCooldown). The check is cheap so we
-- re-read the setting on every message rather than caching.
local function antiMimicWindowSeconds()
  local v = MBLib.Settings and MBLib.Settings:Get("AntiMimicWindow")
  return tonumber(v) or 0
end

local function isMimic(sender, bnSenderID, loweredMessage)
  if antiMimicWindowSeconds() <= 0 then return false end
  local key = spamKey(sender, bnSenderID)
  if not key or not loweredMessage then return false end
  local entries = antiMimicLog[key]
  if not entries then return false end
  local now = GetTime()
  for _, entry in ipairs(entries) do
    if entry.expiry > now and entry.message == loweredMessage then
      return true
    end
  end
  return false
end

local function recordAntiMimic(sender, bnSenderID, loweredMessage)
  local windowSeconds = antiMimicWindowSeconds()
  if windowSeconds <= 0 then return end
  local key = spamKey(sender, bnSenderID)
  if not key or not loweredMessage then return end
  local entries = antiMimicLog[key] or {}
  table.insert(entries, 1, { message = loweredMessage, expiry = GetTime() + windowSeconds })
  -- Trim to ring size; the oldest entries fall off the end as new ones land
  -- at the head. Window expiry is checked lazily on read, so stale entries
  -- past their TTL are tolerated until they get evicted by ring overflow.
  while #entries > ANTI_MIMIC_RING_SIZE do
    table.remove(entries)
  end
  antiMimicLog[key] = entries
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

-- ===== Combat-tainted "secret values" =====
-- Blizzard added an `issecretvalue` API that flags fields the secure-capsule
-- subsystem has marked as opaque during combat / protected contexts. Touching
-- one — even with `==`, `:find`, or arithmetic — raises a "attempt to compare
-- a secret value" error and taints the current execution. The dispatcher reads
-- message/sender/guid every event, so any of them coming through as a secret
-- in combat would crash the whole handler.
--
-- We can't peer at the value before checking; we can only ask "is this a
-- secret value?" first and bail if so. Wrapped in a type check so the addon
-- still loads on clients that predate the API (it'll simply never flag).
local function isSecretValue(v)
  return type(issecretvalue) == "function" and issecretvalue(v) or false
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
  -- Walk both buckets directly so we see every enabled watcher even
  -- before the merged GetAll() view is asked for. Order doesn't matter
  -- here — we're only collecting the union of channel keys.
  local function collect(list)
    for _, w in ipairs(list or {}) do
      if w.enabled and w.channels then
        for k, v in pairs(w.channels) do
          if v then channelKeys[k] = true end
        end
      end
    end
  end
  collect(accountWatchers())
  collect(profileWatchers())
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

-- Returns a fresh array combining account + profile watchers — in that
-- order so account-wide watchers fire first when several would all match
-- the same message. Callers SHOULD NOT mutate the returned list: the
-- backing storage is split between two buckets and the merged view is
-- recomputed on every call. Mutation paths use the bucket helpers above.
function Watchers:GetAll()
  local out = {}
  for _, w in ipairs(accountWatchers()) do out[#out + 1] = w end
  for _, w in ipairs(profileWatchers()) do out[#out + 1] = w end
  return out
end

-- Account-only and profile-only views, for the tabbed Watchers panel.
function Watchers:GetAccount() return accountWatchers() end
function Watchers:GetProfile() return profileWatchers() end

function Watchers:GetByID(id)
  if not id then return nil end
  for _, w in ipairs(accountWatchers()) do
    if w.id == id then return w end
  end
  for _, w in ipairs(profileWatchers()) do
    if w.id == id then return w end
  end
  return nil
end

-- Monotonic id allocator. Persists the highest-ever-issued numeric suffix
-- in SavedVariables so deletions can never cause a reused id — even after
-- /reload or relog. Seeds from the existing watcher list the first time
-- it's called (handles upgrades from builds that used Helpers.newId,
-- which derived the next id from the current set max and DID reuse ids
-- after the highest one was deleted). Stats and other extras key off
-- watcher.id, and a reused id would silently fold the new watcher's
-- counters into the deleted one's row.
-- Monotonic id allocator. The counter lives at the SV root (NOT inside a
-- profile) so ids stay unique across every bucket — account watchers and
-- watchers in every profile pull from the same sequence. Without that,
-- exporting a watcher from profile A and importing it into profile B
-- could land on an id that's already in use by an unrelated watcher.
local function nextWatcherId()
  local d = db()
  if d.NextWatcherIdSeq == nil then
    local seed = 0
    local function seedFromList(list)
      for _, w in ipairs(list or {}) do
        local n = type(w.id) == "string" and tonumber(w.id:match("^w(%d+)$"))
        if n and n > seed then seed = n end
      end
    end
    seedFromList(d.Watchers)
    seedFromList(accountWatchers())
    -- Walk every profile's watchers so the seed beats the highest id in
    -- existence anywhere, not just in the active profile.
    if addon.MBLib and addon.MBLib.Profiles and addon.MBLib.Profiles.All then
      for _, profile in pairs(addon.MBLib.Profiles:All()) do
        seedFromList(profile.Watchers)
      end
    end
    d.NextWatcherIdSeq = seed
  end
  d.NextWatcherIdSeq = d.NextWatcherIdSeq + 1
  return ("w%d"):format(d.NextWatcherIdSeq)
end

-- Pick the backing list that matches the watcher's accountWide flag. Used
-- both when inserting a brand-new watcher and when an Upsert flips an
-- existing watcher's accountWide value (we delete from the old bucket
-- and re-insert into the new one — that path lives in Upsert below).
local function bucketFor(watcher)
  if watcher and watcher.accountWide then return accountWatchers(), "account" end
  return profileWatchers(), "profile"
end

function Watchers:Upsert(watcher)
  if type(watcher) ~= "table" then return nil end
  normalizeWatcher(watcher)
  if watcher.id then
    local list, idx, bucketName = findWatcherBucket(watcher.id)
    if list and idx then
      -- accountWide flip: if the saved value moves between buckets, lift
      -- it out of the old list and fall through to the insert path.
      local targetBucketName = watcher.accountWide and "account" or "profile"
      if bucketName == targetBucketName then
        list[idx] = watcher
        refreshEventSubscriptions()
        return watcher
      end
      table.remove(list, idx)
    end
  end
  if not watcher.id then
    watcher.id = nextWatcherId()
  end
  local targetList = bucketFor(watcher)
  table.insert(targetList, watcher)
  refreshEventSubscriptions()
  return watcher
end

function Watchers:Delete(id)
  local list, idx = findWatcherBucket(id)
  if not list then return false end
  table.remove(list, idx)
  refreshEventSubscriptions()
  -- Let extras (Stats, ...) drop any state they keep keyed by the
  -- deleted id. The id is never reused (nextWatcherId is monotonic),
  -- so any leftover entry would be permanently orphaned in the UI.
  Hooks:Dispatch("OnWatcherDeleted", id)
  return true
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

  -- World channels (General / Trade / Services). channelIndex is the slot
  -- number the user currently has the channel joined as; GetChannelName
  -- returns 0 when not joined, in which case the reply is silently skipped
  -- (the user can't post to a channel they aren't in).
  local def = Constants.CHANNEL_BY_KEY[channelCode]
  if def and def.isWorldChannel and def.channelName then
    local chIndex = GetChannelName(def.channelName)
    if not chIndex or chIndex == 0 then
      debugLog("skip channel reply: not joined to " .. def.channelName)
      return false
    end
    SendChatMessage(text, "CHANNEL", nil, chIndex)
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
  local texts = watcher.reply and watcher.reply.texts
  local pickedText = pickRandom(texts)
  if not pickedText or pickedText == "" then return end

  local def = Constants.CHANNEL_BY_KEY[channelKey]
  local resolved = Helpers.applyPlaceholders(pickedText, {
    sender  = sender or "",
    trigger = trigger or "",
    channel = (def and def.label) or "",
    purr    = pickRandom(Constants.PURR_PHRASES) or "",
  })

  -- Reply text transforms (Extras subscribe via Hooks). Each transform is
  -- pcall-wrapped; if any throw, the unmodified text carries through.
  resolved = Hooks:Transform("ReplyTransforms", resolved, {
    watcher    = watcher,
    sender     = sender,
    channelKey = channelKey,
    trigger    = trigger,
  })

  local ch = watcher.reply.ch or "same"
  if ch == "same" then
    sendReplySameChannel(channelKey, resolved, sender, bnSenderID)
  else
    sendReplyTo(ch, resolved, sender, bnSenderID)
  end
  -- Stats subscribes here so the picked + transformed text shows up in the
  -- top-replies list (random pick happens above, so OnWatcherFired alone
  -- can't see the actually-sent text). Pass channelKey + trigger so the
  -- per-player drill-down view can join the reply to its originating
  -- trigger (otherwise the trigger fan-out is invisible to that hook).
  Hooks:Dispatch("OnReplyText", watcher, sender, resolved, channelKey, trigger)
end

local function doEmoteReply(watcher, sender, channelKey, trigger)
  local r = watcher.reply
  local emotes = r and r.emotes
  if type(emotes) ~= "table" or #emotes == 0 then return end
  -- Pick by index (not just value) so we can look up the parallel
  -- non-targeted flag for the same row.
  local idx   = math.random(1, #emotes)
  local token = emotes[idx]
  if not token or token == "" then return end
  -- emoteNonTargeted[i] suppresses the sender target so the emote reads
  -- as a generic action ("/smile") rather than aimed at the speaker
  -- ("/smile Player"). DoEmote treats nil as "no target". Per-emote
  -- (not per-watcher) since some emotes make sense aimed at the sender
  -- and others read better as ambient.
  local nonTargeted = r.emoteNonTargeted and r.emoteNonTargeted[idx] or false
  local charName
  if not nonTargeted then
    charName = sender and sender:match("^([^-]+)") or sender
  end
  pcall(DoEmote, token, charName)
  -- Per-emote counter (Stats). Fired even when the underlying DoEmote
  -- pcall fails — the user's INTENT was to emote, which is what stats
  -- track. Listeners get the watcher + sender + emote token + channel +
  -- trigger so the per-player drill-down can join the emote back to
  -- the trigger that caused it.
  Hooks:Dispatch("OnEmoteFired", watcher, sender, token, channelKey, trigger)
end

-- ===== Secure-template invite + kick popups =====
-- UninviteUnit / InviteUnit-from-button-click are protected operations; the
-- only legal route from an addon is a SecureActionButton whose macrotext
-- dispatches through Blizzard's secure /uninvite or /invite slash handlers.

local kickPopup, invitePopup, guildInvitePopup
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
  title:SetText(L.POPUP_TITLE)
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
  cancelBtn:SetText(L.POPUP_CANCEL_BTN)
  cancelBtn:SetScript("OnClick", function() popup:Hide() end)

  return popup
end

local function buildKickPopup()
  local p = buildPopup("Meower_KickPopup", { r = 1, g = 0.27, b = 0.27 })
  p.confirmBtn:SetText(L.POPUP_KICK_CONFIRM_BTN)
  return p
end

local function buildInvitePopup()
  local p = buildPopup("Meower_InvitePopup", { r = 0.1, g = 0.8, b = 0.1 })
  p.confirmBtn:SetText(L.POPUP_INVITE_CONFIRM_BTN)
  return p
end

local function buildGuildInvitePopup()
  -- Tabard purple to visually distinguish "guild" from the green party invite.
  local p = buildPopup("Meower_GuildInvitePopup", { r = 0.55, g = 0.45, b = 0.95 })
  p.confirmBtn:SetText(L.POPUP_GINVITE_CONFIRM_BTN)
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
  kickPopup.text:SetText(string.format(L.POPUP_KICK_BODY_FMT,
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
  invitePopup.text:SetText(string.format(L.POPUP_INVITE_BODY_FMT,
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

-- ===== Guild invite =====
-- C_GuildInfo.Invite is a protected function (same constraint as /invite and
-- /uninvite), so the only legal route from an addon is a SecureActionButton
-- whose macrotext dispatches through the secure /ginvite slash handler. That
-- requires a user click — hence the confirm popup. We can't fire-and-forget
-- a guild invite from a chat event.
--
-- Permission gating: IsInGuild + CanGuildInvite (rank-level permission).
-- /ginvite wants just the character name — strip realm when present.
local function showGuildInvitePopup(channelKey, sender, bnSenderID, trigger)
  if not guildInvitePopup then return end
  if guildInvitePopup:IsShown() then
    debugLog("guild-invite popup already open; ignoring new request")
    return
  end
  if InCombatLockdown() then
    table.insert(pendingActions, { kind = "guildInvite", channelKey = channelKey, sender = sender,
                                   bnSenderID = bnSenderID, trigger = trigger })
    combatNotice(sender, "You're in combat — your guild-invite prompt will surface after combat ends.")
    return
  end
  local target = targetCharFor(channelKey, sender, bnSenderID)
  if not target then
    debugLog("cannot guild-invite: could not resolve sender to a WoW character (BNet friend offline or not on WoW)")
    return
  end
  local charOnly = target:match("^([^-]+)") or target
  guildInvitePopup.text:SetText(string.format(L.POPUP_GINVITE_BODY_FMT,
    sender or "?", trigger or "?", channelLabelColored(channelKey)
  ))
  guildInvitePopup.confirmBtn:SetAttribute("macrotext", "/ginvite " .. charOnly)
  guildInvitePopup:Show()
end

local function tryGuildInvite(channelKey, sender, bnSenderID, trigger)
  if not sender or sender == "" then
    debugLog("cannot guild-invite: no sender name")
    return
  end
  if not IsInGuild() then
    debugLog("cannot guild-invite: not in a guild")
    return
  end
  if CanGuildInvite and not CanGuildInvite() then
    debugLog("cannot guild-invite: rank has no invite permission")
    return
  end
  showGuildInvitePopup(channelKey, sender, bnSenderID, trigger)
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
    elseif req.kind == "guildInvite" then
      combatNotice(req.sender, "Combat ended — guild-invite prompt opening now.")
      showGuildInvitePopup(req.channelKey, req.sender, req.bnSenderID, req.trigger)
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

-- Sound value polymorphism (single source of truth — keep this comment in
-- sync with Constants.SOUNDS and the editor's playSoundValue):
--   number != SOUND_NONE -> PlaySound(value, "Master")        SoundKit ID
--   string "file:<id>"   -> PlaySoundFile(<id>, "Master")     FileDataID
--   other non-empty str  -> LSM:Fetch("sound", value) + PlaySoundFile(path)
-- "Master" channel so the cue plays even if Sound or SFX is muted in-game.
local function playNotificationSound(watcher)
  local n = watcher.notifications
  if not n then return end
  local v = n.sound
  if v == nil or v == Constants.SOUND_NONE then return end

  if type(v) == "number" then
    pcall(PlaySound, v, "Master")
    return
  end

  if type(v) == "string" and v ~= "" then
    local fileID = v:match("^file:(%d+)$")
    if fileID then
      pcall(PlaySoundFile, tonumber(fileID), "Master")
      return
    end
    local LSM
    pcall(function() LSM = LibStub and LibStub("LibSharedMedia-3.0", true) end)
    if not LSM then return end
    local path
    pcall(function() path = LSM:Fetch("sound", v) end)
    if path and path ~= "" then
      pcall(PlaySoundFile, path, "Master")
    end
  end
end

local function dispatch(watcher, channelKey, sender, bnSenderID, trigger)
  local r = watcher.reply
  if not r then return end

  -- Local notification cues first — they're the user's "this matched" cue
  -- and should fire even if the Reply tab is skipped via noReply, or if
  -- all reply branches end up silent (e.g. group-channel reply with no
  -- group). Sound + icon are sibling notifications; both fire if both are
  -- configured. IconDisplay no-ops cleanly when no icon is set.
  playNotificationSound(watcher)
  if addon.IconDisplay and addon.IconDisplay.Show then
    pcall(function() addon.IconDisplay:Show(watcher) end)
  end

  -- "No reply needed" short-circuits the entire Reply tab: no text, no emote,
  -- no invite, no kick. The notification cues above are the only effects.
  if watcher.notifications and watcher.notifications.noReply then return end

  local hasText  = type(r.texts)  == "table" and #r.texts  > 0
  local hasEmote = type(r.emotes) == "table" and #r.emotes > 0

  if r.emoteFirst and hasText and hasEmote then
    doEmoteReply(watcher, sender, channelKey, trigger)
    sendReply(watcher, channelKey, sender, bnSenderID, trigger)
  else
    if hasText  then sendReply(watcher, channelKey, sender, bnSenderID, trigger) end
    if hasEmote then doEmoteReply(watcher, sender, channelKey, trigger) end
  end

  if r.invite then
    tryInvite(watcher, channelKey, sender, bnSenderID, trigger)
    Hooks:Dispatch("OnActionFired", watcher, sender, "invite", channelKey, trigger)
  end
  if r.guildInvite then
    tryGuildInvite(channelKey, sender, bnSenderID, trigger)
    Hooks:Dispatch("OnActionFired", watcher, sender, "guildInvite", channelKey, trigger)
  end
  if r.kick then
    tryKick(channelKey, sender, bnSenderID, trigger)
    Hooks:Dispatch("OnActionFired", watcher, sender, "kick", channelKey, trigger)
  end
end

-- ===== Per-trigger chat coloring =====
-- Rewrites the displayed chat line so each matched trigger phrase is wrapped
-- in |cffRRGGBB...|r based on the watcher's notifications.triggerColors. Only
-- touches what chat frames render — the raw event still flows to our regular
-- dispatcher (and any other addon's handlers) unchanged, because filters
-- registered via ChatFrame_AddMessageEventFilter only affect chat-frame display.

local function hexFromRGB(r, g, b)
  return string.format("%02x%02x%02x",
    math.floor((r or 0) * 255 + 0.5),
    math.floor((g or 0) * 255 + 0.5),
    math.floor((b or 0) * 255 + 0.5))
end

-- "Class color" always resolves to the local player's class color, not the
-- sender's. This is intentional: the user-facing toggle is "their own class
-- color as the highlight", independent of who triggered the watcher. Cached
-- across calls because UnitClass for the player doesn't change in-session.
local cachedPlayerClassHex
local function playerClassColorHex()
  if cachedPlayerClassHex then return cachedPlayerClassHex end
  local _, englishClass = UnitClass("player")
  if not englishClass or englishClass == "" then return nil end
  local rgb = _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[englishClass]
  if not rgb then return nil end
  cachedPlayerClassHex = hexFromRGB(rgb.r, rgb.g, rgb.b)
  return cachedPlayerClassHex
end

-- Replace-all of `find` inside `s` with whole-word semantics, invoking
-- replaceFn with the original-cased matched substring. Boundary rules mirror
-- Helpers.matchWholeWord: a phrase that starts/ends with a non-word character
-- relaxes the corresponding boundary (so "!gg" still matches mid-message).
-- This keeps the chat-display coloring in lockstep with the actual trigger
-- match — substrings inside longer words ("test" in "testet") are skipped.
-- Apostrophe counts as a word char so contractions read as single tokens:
-- phrase "I" doesn't highlight "I'm", phrase "isn" doesn't highlight in
-- "isn't". Mirrors Helpers.matchWholeWord's rule so coloring and dispatch
-- agree on what's a whole-word hit.
local function isWordChar(ch)
  return ch ~= "" and ch:match("[%w_']") ~= nil
end

-- Plain substring replace — counterpart to gsubWholeWord for partial-match mode.
-- No word-boundary check: every occurrence of `find` inside `s` is wrapped,
-- including ones inside larger words ("test" inside "testest").
local function gsubPlain(s, find, replaceFn, caseSensitive)
  if not s or s == "" or not find or find == "" then return s end
  local hay = caseSensitive and s or s:lower()
  local needle = caseSensitive and find or find:lower()
  local out = {}
  local i = 1
  local n = #s
  local flen = #needle
  while i <= n do
    local pos = hay:find(needle, i, true)
    if not pos then
      table.insert(out, s:sub(i))
      break
    end
    if pos > i then table.insert(out, s:sub(i, pos - 1)) end
    table.insert(out, replaceFn(s:sub(pos, pos + flen - 1)))
    i = pos + flen
  end
  return table.concat(out)
end

local function gsubWholeWord(s, find, replaceFn, caseSensitive)
  if not s or s == "" or not find or find == "" then return s end
  local hay = caseSensitive and s or s:lower()
  local needle = caseSensitive and find or find:lower()
  local needLeft = isWordChar(needle:sub(1, 1))
  local needRight = isWordChar(needle:sub(-1))
  local out = {}
  local i = 1
  local n = #s
  local flen = #needle
  while i <= n do
    local pos = hay:find(needle, i, true)
    if not pos then
      table.insert(out, s:sub(i))
      break
    end
    local leftOK  = (not needLeft)  or pos == 1 or not isWordChar(hay:sub(pos - 1, pos - 1))
    local rightOK = (not needRight) or (pos + flen - 1) == n or not isWordChar(hay:sub(pos + flen, pos + flen))
    if leftOK and rightOK then
      if pos > i then table.insert(out, s:sub(i, pos - 1)) end
      table.insert(out, replaceFn(s:sub(pos, pos + flen - 1)))
      i = pos + flen
    else
      -- Boundary failed; emit one char and keep scanning. We can't jump to
      -- pos+flen because a valid match may overlap (e.g. "aa" in "aaa").
      table.insert(out, s:sub(i, pos))
      i = pos + 1
    end
  end
  return table.concat(out)
end

-- Strict 6-digit hex validator (no leading "#", no alpha). The UI normalizes
-- input to this shape before storing, so this is just a safety check at the
-- render site.
local function isValidHex6(h)
  return type(h) == "string" and h:match("^%x%x%x%x%x%x$") ~= nil
end

-- Returns the message with each enabled watcher's matching trigger phrases
-- color-wrapped. `channelKey` gates the watcher to this channel's filter.
local function applyTriggerColoring(message, channelKey)
  if not message or message == "" then return message end

  -- Collect {phrase, hex} entries from every enabled watcher whose channel
  -- includes this event. First-watcher-wins per phrase: subsequent rules for
  -- the same lowercased phrase are ignored.
  local entries, seen = {}, {}
  for _, watcher in ipairs(Watchers:GetAll()) do
    if watcher.enabled
       and watcher.channels and watcher.channels[channelKey]
       and watcher.notifications and watcher.notifications.triggerColors
       and watcher.triggers
    then
      local colors = watcher.notifications.triggerColors
      local caseFlags = watcher.triggerCaseSensitive or {}
      local exactFlags = watcher.triggerExact or {}
      local partialFlags = watcher.triggerPartial or {}
      for i, phrase in ipairs(watcher.triggers) do
        local c = colors[i]
        if phrase and phrase ~= "" and c and c ~= "" then
          -- De-dupe per phrase. The dedupe key tracks casing AND match mode
          -- (exact / partial / whole-word) so e.g. an exact rule for "Foo"
          -- doesn't get shadowed by an earlier whole-word rule for the same
          -- phrase. exact wins over partial when both ended up set on a row.
          local cs = caseFlags[i] and true or false
          local ex = exactFlags[i] and true or false
          local pm = (not ex) and (partialFlags[i] and true or false) or false
          local modeTag = ex and "ex:" or (pm and "pm:" or "wd:")
          local key = modeTag .. (cs and "cs:" or "ci:") .. phrase:lower()
          if not seen[key] then
            local hex
            if c == "class" then
              hex = playerClassColorHex()
            elseif isValidHex6(c) then
              hex = c
            end
            if hex then
              seen[key] = true
              table.insert(entries, { phrase = phrase, hex = hex, caseSensitive = cs, exact = ex, partial = pm })
            end
          end
        end
      end
    end
  end

  if #entries == 0 then return message end

  -- Longest-first so a phrase like "thank you" wins over "thank" when both
  -- are configured — otherwise the outer "thank" wrap would split the longer
  -- match into uncolorable fragments. Exact entries also slot into this
  -- ordering; if one fires it wraps the whole message, but that's only
  -- possible when the trimmed message equals the phrase, in which case no
  -- other entry would have anything left to color anyway.
  table.sort(entries, function(a, b) return #a.phrase > #b.phrase end)

  for _, e in ipairs(entries) do
    if e.exact then
      -- Exact match: only color the message when the trimmed message equals
      -- the configured phrase. This mirrors Helpers.findIn's exact branch so
      -- the chat display stays in sync with whether the watcher fired.
      local trimmed = message:match("^%s*(.-)%s*$") or message
      local matched
      if e.caseSensitive then
        matched = (trimmed == e.phrase)
      else
        matched = (trimmed:lower() == e.phrase:lower())
      end
      if matched then
        message = "|cff" .. e.hex .. message .. "|r"
      end
    elseif e.partial then
      -- Partial-match mode: plain substring contains, no word boundary check.
      -- Mirrors Helpers.findIn's partial branch so coloring matches what
      -- fired.
      message = gsubPlain(message, e.phrase, function(match)
        return "|cff" .. e.hex .. match .. "|r"
      end, e.caseSensitive)
    else
      message = gsubWholeWord(message, e.phrase, function(match)
        return "|cff" .. e.hex .. match .. "|r"
      end, e.caseSensitive)
    end
  end

  return message
end

-- EVENT_TO_KEY (the module-level upvalue declared with chatFrame near the
-- subscription block) is shared with the regular event dispatcher and the
-- chat-coloring filter. Both read it at fire time, so the lazy population in
-- Init is fine.
--
-- Filter signature mirrors ChatFrame_AddMessageEventFilter: (chatFrame, event,
-- msg, sender, ..., guid, bnSenderID, ...). We only rewrite the message; the
-- rest of the args pass through untouched. Return false to keep the line.
local function chatColoringFilter(_, event, msg, ...)
  -- Same secret-value guard as onChatEvent — `msg == ""` and the per-watcher
  -- :find calls inside applyTriggerColoring would raise on a secret string.
  if isSecretValue(msg) then return end
  if not msg or msg == "" or not EVENT_TO_KEY then return end
  -- CHAT_MSG_CHANNEL serves every world channel. The filter callback's
  -- vararg starts at arg2 (the event's first vararg is `msg` which we
  -- already pulled out), so what was arg9 in onChatEvent is select(8, ...)
  -- here. Same locale-safe fallback via GetChannelName.
  local channelKey
  if event == "CHAT_MSG_CHANNEL" then
    local channelName  = select(8, ...)
    local channelIndex = select(7, ...)
    local def = channelName and Constants.WORLD_CHANNEL_BY_NAME[channelName]
    if not def and channelIndex then
      for _, candidate in pairs(Constants.WORLD_CHANNEL_BY_NAME) do
        local myIdx = GetChannelName(candidate.channelName)
        if myIdx and myIdx > 0 and myIdx == channelIndex then
          def = candidate
          break
        end
      end
    end
    channelKey = def and def.key
  else
    channelKey = EVENT_TO_KEY[event]
  end
  if not channelKey then return end

  -- Mirror onChatEvent's sender gating: only color messages that the
  -- dispatcher would actually fire on. Without this, the filter colored
  -- the player's own outgoing messages (and NPC chatter on SAY/EMOTE)
  -- whenever the text contained a trigger phrase — even though no watcher
  -- ever fired on them. In the filter, msg is pulled out as the first
  -- vararg, so the event's arg12 (guid) lands at select(11, ...).
  local channelDef = Constants.CHANNEL_BY_KEY[channelKey]
  if not (channelDef and channelDef.isBnet) then
    local guid = select(11, ...)
    if isSecretValue(guid) then return end
    if not guid or not guid:find("^Player%-") then return end
    if guid == UnitGUID("player") then return end
  end

  local newMsg = applyTriggerColoring(msg, channelKey)
  if newMsg == msg then return end
  return false, newMsg, ...
end

local chatColoringRegistered = false
local function registerChatColoringFilters()
  if chatColoringRegistered then return end
  chatColoringRegistered = true
  for _, def in pairs(Constants.CHANNELS) do
    for _, event in ipairs(def.events) do
      pcall(ChatFrame_AddMessageEventFilter, event, chatColoringFilter)
    end
  end
end

-- ===== Chat event wiring =====

local function buildEventMap()
  local map = {}
  for _, info in pairs(Constants.CHANNELS) do
    -- World channels all share CHAT_MSG_CHANNEL; mapping that to a single
    -- key here would clobber the others. The dispatcher resolves world
    -- channels by inspecting arg9 (channelBaseName) instead.
    if not info.isWorldChannel then
      for _, event in ipairs(info.events) do
        map[event] = info.key
      end
    end
  end
  return map
end

-- Trigger-match + dispatch loop for a single classified message. Public so
-- Debug can drive it from synthetic input without faking a chat event with
-- 13 positional varargs (the real CHAT_MSG_* args shape).
function Watchers:ProcessMessage(channelKey, sender, message, bnSenderID)
  if not channelKey or not message or message == "" then return end
  local channelDef = Constants.CHANNEL_BY_KEY[channelKey]
  if not channelDef then return end

  local lower = message:lower()

  -- Anti-mimic: drop identical repeats from the same sender inside the
  -- configured window. Evaluated before any watcher logic so it counts as a
  -- global filter, not a per-watcher one. Always record after the check —
  -- the second copy still updates the window for the NEXT message.
  if isMimic(sender, bnSenderID, lower) then
    recordAntiMimic(sender, bnSenderID, lower)
    return
  end

  local isLeader = UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")

  for _, watcher in ipairs(self:GetAll()) do
    if watcher.enabled and watcher.channels and watcher.channels[channelKey] then
      if not isWatcherOnCooldown(watcher, sender, bnSenderID) then
        local gated = channelDef.isGroupChannel and watcher.onlyLead and not isLeader
        -- Filters module may not be loaded yet (early errors during init) —
        -- if missing, treat as allow so the addon degrades to "no filters"
        -- rather than silently blocking every watcher.
        local filtersAllow = true
        if addon.Filters and addon.Filters.Allow then
          filtersAllow = addon.Filters:Allow(watcher, { sender = sender, bnSenderID = bnSenderID })
        end
        if not gated and filtersAllow then
          -- Pass the ORIGINAL message (not lowered) so per-phrase
          -- case-sensitive matching can compare against the source casing.
          -- findIn lowercases internally as needed. Match mode (exact /
          -- partial / whole-word) and case-sensitivity are all per-trigger
          -- arrays parallel to watcher.triggers.
          local trigger = Helpers.findIn(message, watcher.triggers, watcher.triggerExact, watcher.triggerCaseSensitive, watcher.triggerPartial)
          if trigger then
            dispatch(watcher, channelKey, sender, bnSenderID, trigger)
            recordWatcherCooldown(watcher, sender, bnSenderID)
            Hooks:Dispatch("OnWatcherFired", watcher, sender, channelKey, trigger)
          end
        end
      end
    end
  end

  -- Always log the message under anti-mimic, even when nothing matched, so a
  -- sender's first non-matching repeat is suppressed too. This mirrors the
  -- "global filter" intent — anti-mimic is about the sender's behavior, not
  -- about whether any watcher cared.
  recordAntiMimic(sender, bnSenderID, lower)
end

-- Force-runs dispatch on a watcher without any matching / filter checks.
-- For Debug's "force fire" widget. The synthetic trigger is the first
-- trigger phrase on the watcher (or a placeholder if it has none).
function Watchers:ForceFire(watcherId, channelKey, sender)
  local watcher = self:GetByID(watcherId)
  if not watcher then return false end
  channelKey = channelKey or "w"
  sender = sender or UnitName("player") or "Test"
  local trigger = (watcher.triggers and watcher.triggers[1]) or "(forced)"
  dispatch(watcher, channelKey, sender, nil, trigger)
  Hooks:Dispatch("OnWatcherFired", watcher, sender, channelKey, trigger)
  return true
end

local function onChatEvent(EVENT_TO_KEY, event, ...)
  local channelKey
  if event == "CHAT_MSG_CHANNEL" then
    -- Try arg9 (channelBaseName) first — fast and works on English
    -- clients. Fall back to matching arg8 (channel slot index) against
    -- GetChannelName(canonical) so the resolve is locale-independent
    -- and survives the user reordering their channel list.
    local channelName  = select(9, ...)
    local channelIndex = select(8, ...)
    local def = channelName and Constants.WORLD_CHANNEL_BY_NAME[channelName]
    if not def and channelIndex then
      for _, candidate in pairs(Constants.WORLD_CHANNEL_BY_NAME) do
        local myIdx = GetChannelName(candidate.channelName)
        if myIdx and myIdx > 0 and myIdx == channelIndex then
          def = candidate
          break
        end
      end
    end
    channelKey = def and def.key
  else
    channelKey = EVENT_TO_KEY[event]
  end
  if not channelKey then return end
  local channelDef = Constants.CHANNEL_BY_KEY[channelKey]

  local message, sender = ...
  local guid       = select(12, ...)
  local bnSenderID = select(13, ...)

  -- Bail before any comparison if any of the fields we read came through
  -- as a Blizzard "secret value" — touching one with `==` / `:find` raises
  -- and taints execution. This happens during combat for some event flows.
  if isSecretValue(message) or isSecretValue(sender) or isSecretValue(guid) then
    return
  end

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

  Watchers:ProcessMessage(channelKey, sender, message, bnSenderID)
end

-- ===== Init =====

function Watchers:Init()
  if self._initialized then return end
  self._initialized = true

  -- One-time migration: pre-Profiles builds wrote every watcher to a flat
  -- _db.Watchers list. Move that list into the active profile (where the
  -- character's previous data conceptually belonged) and drop the legacy
  -- slot. Walk every existing watcher AFTER migration so normalizeWatcher
  -- sees the modern shape and the bucket helpers iterate the right
  -- storage.
  local d = db()
  if type(d.Watchers) == "table" and #d.Watchers > 0 then
    local target = profileWatchers()
    for _, w in ipairs(d.Watchers) do
      table.insert(target, w)
    end
    d.Watchers = nil
  end

  -- One-time schema lift over everything in SavedVariables. After this pass
  -- the rest of the code (UI, dispatch) can assume the modern shape without
  -- defensive `or {}` reads on every field.
  for _, w in ipairs(accountWatchers()) do normalizeWatcher(w) end
  for _, w in ipairs(profileWatchers()) do normalizeWatcher(w) end

  -- When the active profile changes (the user activates a different one
  -- from the Profiles panel), re-evaluate which chat events we need to
  -- subscribe to — different profile = different watcher set.
  if addon.MBLib and addon.MBLib.Profiles and addon.MBLib.Profiles.OnActivated then
    addon.MBLib.Profiles:OnActivated(function()
      for _, w in ipairs(profileWatchers()) do normalizeWatcher(w) end
      refreshEventSubscriptions()
    end)
  end

  -- Build secure popups now; SecureActionButton needs to be created out of
  -- combat, and Init() is reached from ADDON_LOADED, well before any pull.
  kickPopup        = buildKickPopup()
  invitePopup      = buildInvitePopup()
  guildInvitePopup = buildGuildInvitePopup()

  -- The module-scope EVENT_TO_KEY / chatFrame / registeredEvents drive
  -- refreshEventSubscriptions, which only registers events that an enabled
  -- watcher actually needs (no listening to channels nobody watches).
  EVENT_TO_KEY = buildEventMap()
  chatFrame = CreateFrame("Frame")
  chatFrame:SetScript("OnEvent", function(_, event, ...)
    onChatEvent(EVENT_TO_KEY, event, ...)
  end)
  refreshEventSubscriptions()

  -- Register chat-frame message filters for per-trigger coloring. These are
  -- separate from the event subscriptions above: filters only rewrite what
  -- chat frames display, they don't drive our dispatcher. Registered once
  -- across every channel we know about — short-circuits cheaply when no
  -- watcher has triggerColors configured.
  registerChatColoringFilters()

  local combatFrame = CreateFrame("Frame")
  combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
  combatFrame:SetScript("OnEvent", drainPendingActions)
end

-- Public hook for the import-preview popup so it can normalize a
-- decoded payload before describeWatcher walks it (filters block fill,
-- accountWide default, etc.) without actually inserting the watcher.
function Watchers:NormalizeForPreview(w)
  normalizeWatcher(w)
end

addon.Watchers = Watchers
