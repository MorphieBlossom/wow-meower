local _, addon = ...
local L = addon.L

-- Per-character trigger counters. Storage lives on MBLib._db.Stats (which
-- IS MeowerData.Stats since MBLib's _db points at the consumer's saved
-- variables). Hooks emit at the dispatch sites that know what was actually
-- picked / sent — OnWatcherFired alone can't see the random-picked text or
-- the random-picked emote, so per-text and per-emote counters subscribe to
-- their own dedicated hooks.
--
-- purrCount is the cat-themed alias of totalFires — same number, surfaced
-- by name for the Stats panel's flavor row and the /mw stats summary.

local Stats = {}

-- Stats are profile-scoped: each profile holds its own counters so the
-- numbers reflect what THIS character / configuration has produced. The
-- one-time migration below moves any legacy account-wide _db.Stats into
-- the active profile's bucket the first time the new schema is loaded.
local function statsHome()
  local P = addon.MBLib and addon.MBLib.Profiles
  if P and P.IsEnabled and P:IsEnabled() then
    local profile = P:GetActive()
    if profile then
      if type(profile.Stats) ~= "table" then profile.Stats = {} end
      return profile.Stats
    end
  end
  -- Fallback for the (rare) case where Profiles isn't enabled / ready —
  -- keep stats functional by writing to the legacy slot.
  local root = addon.MBLib and addon.MBLib._db
  if not root then return nil end
  if type(root.Stats) ~= "table" then root.Stats = {} end
  return root.Stats
end

local function db()
  local s = statsHome()
  if not s then return nil end
  -- Fill missing fields so the schema stays consistent across partial /
  -- older save shapes. Cheap to do on every call.
  s.totalFires        = s.totalFires        or 0
  s.repliesTextCount  = s.repliesTextCount  or 0
  s.repliesEmoteCount = s.repliesEmoteCount or 0
  s.actionsCount      = s.actionsCount      or 0
  s.firesByWatcherId  = s.firesByWatcherId  or {}
  s.firesBySender     = s.firesBySender     or {}
  s.firesByEmote      = s.firesByEmote      or {}
  s.repliesByText     = s.repliesByText     or {}
  -- Per-watcher reply / emote fan-out. The flat repliesByText / firesByEmote
  -- maps above can't tell us WHICH watcher produced a given reply, so the
  -- Top 10s panel folds replies + emotes under their watcher in this map.
  -- Indexed by watcher.id (stable across renames; reused after delete via
  -- newId reusing free slots). Empty until the first fire after the schema
  -- bump — there's no way to back-fill historical joins.
  s.repliesByWatcher  = s.repliesByWatcher  or {}
  s.emotesByWatcher   = s.emotesByWatcher   or {}
  -- Per-watcher action counter (invite / guildInvite / kick all increment
  -- the same slot — the "what kind" distinction wasn't surfaced anywhere
  -- in the UI and felt like overkill for the Top 10s view).
  s.actionsByWatcher  = s.actionsByWatcher  or {}
  -- Per-player drill-down (Phase 7 addition): for each normalized sender,
  -- counts of which triggers they hit, which text replies they got back,
  -- and which emote replies they got back. The flat firesBy* maps above
  -- can't reconstruct this fan-out, so it's tracked separately at write
  -- time. Empty until the first fire after the schema bump — there's no
  -- way to back-fill historical joins.
  s.byPlayer          = s.byPlayer          or {}
  -- totalPurrs counts every /purr invocation, whether typed by the player
  -- or dispatched by a watcher. On first migration, seed from the existing
  -- watcher-dispatched count so prior history isn't lost.
  if s.totalPurrs == nil then
    s.totalPurrs = (s.firesByEmote["PURR"] or 0)
  end

  -- One-time migration: collapse bare-name sender keys into "Name-Realm"
  -- using the player's home realm. WoW chat events omit the realm suffix
  -- for same-realm senders and include it for cross-realm, so historical
  -- data has both "XXX" and "XXX-YYY" pointing at the same
  -- player. Going forward, normalizeSender() ensures every write is
  -- already in Name-Realm form; this pass merges anything pre-migration.
  -- We skip keys that already contain "-" (cross-realm or already
  -- normalized) and BattleTag-style keys (contain "#") which come from
  -- BNet senders we shouldn't tag with a WoW realm.
  if not s._sendersNormalized then
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if realm and realm ~= "" then
      local merged = {}
      for k, v in pairs(s.firesBySender) do
        local key = k
        if type(k) == "string" and not k:find("-") and not k:find("#") then
          key = k .. "-" .. realm
        end
        merged[key] = (merged[key] or 0) + v
      end
      s.firesBySender = merged
      s._sendersNormalized = true
    end
  end

  return s
end

function Stats:Get()
  return db()
end

-- How many times the `/purr` emote has fired — includes both watcher-
-- dispatched and player-typed invocations. Reads from totalPurrs, which
-- the DoEmote hook (set up in Init) keeps in sync.
function Stats:PurrCount()
  local d = db()
  return d and d.totalPurrs or 0
end

local function inc(map, key)
  if not key or key == "" then return end
  map[key] = (map[key] or 0) + 1
end

-- Always store senders as "Name-Realm" so same-realm and cross-realm fires
-- from the same player share a row. WoW chat events drop the realm suffix
-- for same-realm senders, so we tack the player's home realm on bare names.
-- BNet senders (whose channel def is flagged isBnet) are left alone — their
-- "sender" is a BattleTag/display name, not a Name-Realm pair, and appending
-- a WoW realm to it would be nonsense.
local function normalizeSender(sender, channelKey)
  if type(sender) ~= "string" or sender == "" then return sender end
  if channelKey and addon.Constants and addon.Constants.CHANNEL_BY_KEY then
    local def = addon.Constants.CHANNEL_BY_KEY[channelKey]
    if def and def.isBnet then return sender end
  end
  if sender:find("-") then return sender end
  local realm = GetNormalizedRealmName and GetNormalizedRealmName()
  if not realm or realm == "" then return sender end
  return sender .. "-" .. realm
end

-- Lazily fetch (or create) the byPlayer entry for a sender. Returns nil on
-- empty sender so callers can skip silently.
local function playerEntry(d, sender)
  if not d or type(sender) ~= "string" or sender == "" then return nil end
  local map = d.byPlayer
  if not map then return nil end
  local entry = map[sender]
  if not entry then
    entry = { total = 0, triggers = {}, replies = {}, emotes = {} }
    map[sender] = entry
  end
  return entry
end

local function onWatcherFired(watcher, sender, channelKey, trigger)
  local d = db()
  if not d then return end
  d.totalFires = (d.totalFires or 0) + 1
  if watcher and watcher.id then inc(d.firesByWatcherId, watcher.id) end
  if sender then
    local normSender = normalizeSender(sender, channelKey)
    inc(d.firesBySender, normSender)
    -- Per-player drill-down: bump total + per-trigger count. Replies and
    -- emotes are tracked on their own hooks because OnWatcherFired can't
    -- see the random-picked text / emote token.
    local entry = playerEntry(d, normSender)
    if entry then
      entry.total = (entry.total or 0) + 1
      if trigger and trigger ~= "" then inc(entry.triggers, trigger) end
    end
  end
end

-- Sub-map of repliesByWatcher / emotesByWatcher for the given watcher id.
-- Returns nil when there's no id so callers can no-op silently.
local function watcherSubmap(parentMap, watcherId)
  if not parentMap or not watcherId then return nil end
  local m = parentMap[watcherId]
  if not m then
    m = {}
    parentMap[watcherId] = m
  end
  return m
end

local function onReplyText(watcher, sender, resolved, channelKey, _trigger)
  local d = db()
  if not d or not resolved or resolved == "" then return end
  d.repliesTextCount = (d.repliesTextCount or 0) + 1
  inc(d.repliesByText, resolved)
  if watcher and watcher.id then
    local sub = watcherSubmap(d.repliesByWatcher, watcher.id)
    if sub then inc(sub, resolved) end
  end
  if sender then
    local entry = playerEntry(d, normalizeSender(sender, channelKey))
    if entry then inc(entry.replies, resolved) end
  end
end

local function onEmoteFired(watcher, sender, token, channelKey, _trigger)
  local d = db()
  if not d then return end
  d.repliesEmoteCount = (d.repliesEmoteCount or 0) + 1
  if token then inc(d.firesByEmote, token) end
  if watcher and watcher.id and token then
    local sub = watcherSubmap(d.emotesByWatcher, watcher.id)
    if sub then inc(sub, token) end
  end
  if sender and token then
    local entry = playerEntry(d, normalizeSender(sender, channelKey))
    if entry then inc(entry.emotes, token) end
  end
end

local function onActionFired(watcher, _sender, _kind, _channelKey, _trigger)
  local d = db()
  if not d then return end
  d.actionsCount = (d.actionsCount or 0) + 1
  if watcher and watcher.id then
    local sub = d.actionsByWatcher
    if sub then sub[watcher.id] = (sub[watcher.id] or 0) + 1 end
  end
end

-- Subscriber for OnWatcherDeleted. Drop every row keyed by the deleted
-- watcher's id so it doesn't linger as an orphan "w7" entry in the panel
-- after the user removes a watcher. Aggregate maps (repliesByText,
-- firesByEmote, byPlayer) are not keyed by watcher id so they stay
-- untouched — their entries could equally have come from a still-existing
-- watcher with the same reply text or trigger phrase.
local function onWatcherDeleted(watcherId)
  if not watcherId then return end
  local d = db()
  if not d then return end
  if d.firesByWatcherId  then d.firesByWatcherId[watcherId]  = nil end
  if d.repliesByWatcher  then d.repliesByWatcher[watcherId]  = nil end
  if d.emotesByWatcher   then d.emotesByWatcher[watcherId]   = nil end
  if d.actionsByWatcher  then d.actionsByWatcher[watcherId]  = nil end
end

function Stats:Reset()
  local d = db()
  if not d then return end
  d.totalFires        = 0
  d.repliesTextCount  = 0
  d.repliesEmoteCount = 0
  d.actionsCount      = 0
  d.totalPurrs        = 0
  d.firesByWatcherId  = {}
  d.firesBySender     = {}
  d.firesByEmote      = {}
  d.repliesByText     = {}
  d.repliesByWatcher  = {}
  d.emotesByWatcher   = {}
  d.actionsByWatcher  = {}
  d.byPlayer          = {}
end

-- Returns an array of { key, count } pairs sorted by count desc, ties
-- broken by key for stable ordering. Limited to `n` entries when n given.
-- `filter(key) -> truthy` can drop entries before the sort (e.g. to omit
-- the local player from the senders list).
function Stats:TopN(map, n, filter)
  local list = {}
  for k, v in pairs(map or {}) do
    if not filter or filter(k) then
      list[#list + 1] = { k, v }
    end
  end
  table.sort(list, function(a, b)
    if a[2] == b[2] then return tostring(a[1]) < tostring(b[1]) end
    return a[2] > b[2]
  end)
  if n then
    for i = #list, n + 1, -1 do list[i] = nil end
  end
  return list
end

function Stats:CountKeys(map)
  local n = 0
  for _ in pairs(map or {}) do n = n + 1 end
  return n
end

-- ===== Per-player drill-down (Phase 7) =====
-- Helpers the Overview tab in StatsPanel consumes. Kept on the Stats module
-- so the panel doesn't reach into SavedVariables directly.

-- Returns a sorted array of every distinct trigger phrase that's been
-- recorded in byPlayer (sorted asc, case-insensitive). Used to populate
-- the trigger filter dropdown. Empty when nothing has fired yet.
function Stats:AllRecordedTriggers()
  local d = db()
  if not d or not d.byPlayer then return {} end
  local seen, list = {}, {}
  for _, entry in pairs(d.byPlayer) do
    for trigger in pairs(entry.triggers or {}) do
      if not seen[trigger] then
        seen[trigger] = true
        list[#list + 1] = trigger
      end
    end
  end
  table.sort(list, function(a, b) return tostring(a):lower() < tostring(b):lower() end)
  return list
end

-- Returns a filtered + sorted array of { sender = ..., entry = ..., total = ... }
-- tuples for the Overview tab. `opts.search` is a case-insensitive substring
-- against the sender name. `opts.trigger`, if set, requires the player has
-- a non-zero count for that trigger. `opts.excludeSelf` mirrors the senders
-- top-N (drops the local player by name-part). Sort: total desc, sender asc.
function Stats:FilteredPlayers(opts)
  opts = opts or {}
  local d = db()
  if not d or not d.byPlayer then return {} end

  local search = type(opts.search) == "string" and opts.search ~= "" and opts.search:lower() or nil
  local triggerFilter = type(opts.trigger) == "string" and opts.trigger ~= "" and opts.trigger or nil
  local notMe
  if opts.excludeSelf then notMe = self:NotMePredicate() end

  local list = {}
  for sender, entry in pairs(d.byPlayer) do
    local include = true
    if notMe and not notMe(sender) then include = false end
    if include and search then
      include = type(sender) == "string" and sender:lower():find(search, 1, true) ~= nil
    end
    if include and triggerFilter then
      local triggers = entry.triggers or {}
      include = (triggers[triggerFilter] or 0) > 0
    end
    if include then
      list[#list + 1] = { sender = sender, entry = entry, total = entry.total or 0 }
    end
  end
  table.sort(list, function(a, b)
    if a.total == b.total then return tostring(a.sender) < tostring(b.sender) end
    return a.total > b.total
  end)
  return list
end

-- Sort a {[key]=count} sub-map into a stable array of {key, count} pairs
-- for rendering (count desc, key asc on ties). The panel uses this for the
-- per-player triggers/replies/emotes sub-lists.
function Stats:SortSubmap(map)
  local list = {}
  for k, v in pairs(map or {}) do list[#list + 1] = { k, v } end
  table.sort(list, function(a, b)
    if a[2] == b[2] then return tostring(a[1]) < tostring(b[1]) end
    return a[2] > b[2]
  end)
  return list
end

-- Resolves a watcher id to its display name (or the raw id if the watcher
-- has been deleted since the counter was incremented).
function Stats:WatcherName(id)
  if addon.Watchers and addon.Watchers.GetByID then
    local w = addon.Watchers:GetByID(id)
    if w and w.name and w.name ~= "" then return w.name end
  end
  return tostring(id)
end

-- Display form of a stored sender key. Data is always written as
-- "Name-Realm" so cross-realm and same-realm fires from the same player
-- share a row, but in the UI we strip the realm suffix when it matches
-- the player's home realm — it adds noise without information. BNet
-- senders (BattleTags with "#" in them) and cross-realm names from other
-- realms pass through unchanged.
function Stats:DisplaySender(senderKey)
  if type(senderKey) ~= "string" or senderKey == "" then return senderKey end
  local name, realm = senderKey:match("^([^-]+)-(.+)$")
  if not name or not realm then return senderKey end
  local home = GetNormalizedRealmName and GetNormalizedRealmName()
  if home and home ~= "" and realm == home then return name end
  return senderKey
end

-- Returns a predicate that filters out the local player from the senders
-- map. Senders come from chat events as "Name" or "Name-Realm"; UnitName
-- is also "Name". Compare case-insensitive, name part only.
function Stats:NotMePredicate()
  local me = UnitName and UnitName("player")
  if not me or me == "" then return nil end
  local meLower = me:lower()
  return function(key)
    if type(key) ~= "string" then return true end
    local namePart = key:match("^([^-]+)") or key
    return namePart:lower() ~= meLower
  end
end

local PREFIX = "|cffff8000Meower|r"

local function num(n)
  return "|cffff8000" .. tostring(n or 0) .. "|r"
end

local function slashStats()
  local d = db()
  if not d then return false end
  local emDash = "  —  "
  print(string.format("%s: Total triggers fired: %s  (purrs: %s)",
    PREFIX, num(d.totalFires), num(Stats:PurrCount())))
  print(string.format("%s: Replies sent: %s text + %s emote.  Actions: %s.",
    PREFIX, num(d.repliesTextCount), num(d.repliesEmoteCount), num(d.actionsCount)))
  local topW = Stats:TopN(d.firesByWatcherId, 3)
  if #topW > 0 then
    print(PREFIX .. ": Top watchers:")
    for _, p in ipairs(topW) do
      local watcherId = p[1]
      print("  " .. Stats:WatcherName(watcherId) .. emDash .. num(p[2]))
      -- Inline the top reply + top emote this watcher produced (up to 2 of
      -- each) so the chat summary mirrors the panel's "Top 10s" view.
      local topR = Stats:TopN((d.repliesByWatcher or {})[watcherId], 2)
      for _, r in ipairs(topR) do
        print("    \"" .. tostring(r[1]) .. "\"" .. emDash .. num(r[2]))
      end
      local topE = Stats:TopN((d.emotesByWatcher or {})[watcherId], 2)
      for _, e in ipairs(topE) do
        print("    /" .. tostring(e[1]):lower() .. emDash .. num(e[2]))
      end
      local actionsCount = (d.actionsByWatcher or {})[watcherId]
      if actionsCount and actionsCount > 0 then
        print("    actions" .. emDash .. num(actionsCount))
      end
    end
  end
  local topS = Stats:TopN(d.firesBySender, 3, Stats:NotMePredicate())
  if #topS > 0 then
    print(PREFIX .. ": Top senders:")
    for _, p in ipairs(topS) do
      print("  " .. tostring(p[1]) .. emDash .. num(p[2]))
    end
  end
  return true
end

-- /mw meow — sends "purrs softly" as a SAY-style emote so it renders to
-- chat as "<You> purrs softly" (no asterisks, unlike the {purr} placeholder
-- which is plain text). Bumps totalPurrs directly: this path does NOT go
-- through DoEmote, so the hooksecurefunc above can't see it.
local function slashMeow()
  pcall(SendChatMessage, "purrs softly.", "EMOTE")
  local d = db()
  if d then
    d.totalPurrs = (d.totalPurrs or 0) + 1
  end
  return true
end

local STATS_OPT_KEY = "StatsEnabled"

-- Read the StatsEnabled toggle (defaults to true so existing users who
-- predate this setting keep the same behavior). Used to gate hook
-- registration in Init() and the Stats subcategory panel build.
function Stats:IsEnabled()
  if not (addon.MBLib and addon.MBLib.Settings) then return true end
  local v = addon.MBLib.Settings:Get(STATS_OPT_KEY)
  if v == nil then return true end
  return v and true or false
end

-- Register the Stats-related options. Called from Init.lua before MBLib:Init
-- so the options panel picks the definition up on its first build.
-- OnChange just prints a reload notice — the Blizzard Settings API has no
-- "unregister subcategory" path, so toggling the canvas off / on at runtime
-- needs a /reload to fully take effect.
function Stats:RegisterSettings()
  if not (addon.MBLib and addon.MBLib.Settings) then return end
  addon.MBLib.Settings:Add({
    {
      Key = STATS_OPT_KEY,
      Name = L.SETTINGS_STATS_ENABLED_NAME,
      Description = L.SETTINGS_STATS_ENABLED_DESC,
      Group = L.SETTINGS_GROUP_EXTRAS,
      Type = "checkbox",
      Default = true,
      OnChange = function()
        pcall(print, L.SETTINGS_RELOAD_REQUIRED_NOTICE)
      end,
    },
  })
end

function Stats:Init()
  if self._initialized then return end
  self._initialized = true
  -- Bail before wiring hooks when the user has Stats turned off. The
  -- /mw meow command still registers below so it stays available either
  -- way (it doesn't depend on the stats store beyond a single counter
  -- bump that's harmless if no one reads it).
  if not self:IsEnabled() then return end

  -- One-time migration: pre-Profiles builds stored stats at the SV root
  -- (_db.Stats). Move that bucket into the active profile and clear the
  -- legacy slot. Done here (not in db()) so it runs once per session and
  -- doesn't fight with the schema-fill in statsHome() on every call.
  local root = addon.MBLib and addon.MBLib._db
  local P    = addon.MBLib and addon.MBLib.Profiles
  if root and P and P.IsEnabled and P:IsEnabled() then
    local legacy = root.Stats
    local profile = P:GetActive()
    if type(legacy) == "table" and not legacy._migratedToProfile and profile then
      -- Only adopt the legacy bucket when the profile doesn't already
      -- have one (the user might have started fresh on this profile).
      if type(profile.Stats) ~= "table" or next(profile.Stats) == nil then
        profile.Stats = legacy
        profile.Stats._migratedToProfile = true
      end
      root.Stats = nil
    end
  end

  if addon.Hooks then
    addon.Hooks:Register("OnWatcherFired",   onWatcherFired)
    addon.Hooks:Register("OnReplyText",      onReplyText)
    addon.Hooks:Register("OnEmoteFired",     onEmoteFired)
    addon.Hooks:Register("OnActionFired",    onActionFired)
    addon.Hooks:Register("OnWatcherDeleted", onWatcherDeleted)
  end

  -- Stats are character-state, not configuration — never travel with
  -- the profile when it's exported / imported. MBLib strips registered
  -- transient keys from the payload on both sides of the round-trip.
  if addon.MBLib and addon.MBLib.Profiles and addon.MBLib.Profiles.RegisterTransientKey then
    addon.MBLib.Profiles:RegisterTransientKey("Stats")
  end

  -- Stats are profile-scoped: when the active profile flips, the panel
  -- needs to redraw with the new counters. Stats:Get() / db() already
  -- resolves to the active profile on every call, so all we do here is
  -- prod the panel into refreshing.
  if addon.MBLib and addon.MBLib.Profiles and addon.MBLib.Profiles.OnActivated then
    addon.MBLib.Profiles:OnActivated(function()
      local panel = addon.Extras and addon.Extras.StatsPanel
      if panel and panel.refresh then pcall(panel.refresh) end
    end)
  end

  -- Track every /purr in totalPurrs, regardless of who initiated it.
  -- hooksecurefunc fires AFTER the original DoEmote, so a no-op call
  -- (player not allowed to emote, in combat lockdown, etc.) still hits
  -- this — that's intentional: the user's INTENT was to purr.
  if type(DoEmote) == "function" then
    hooksecurefunc("DoEmote", function(token)
      if not token then return end
      if tostring(token):upper() ~= "PURR" then return end
      local d = db()
      if not d then return end
      d.totalPurrs = (d.totalPurrs or 0) + 1
    end)
  end

  if addon.MBLib and addon.MBLib.Commands and addon.MBLib.Commands.Add then
    addon.MBLib.Commands:Add("stats", {
      desc = "Print a condensed stats summary to chat.",
      func = slashStats,
    })
    addon.MBLib.Commands:Add("meow", {
      desc = "Be like a kitten!",
      func = slashMeow,
    })
  end
end

addon.Extras = addon.Extras or {}
addon.Extras.Stats = Stats
