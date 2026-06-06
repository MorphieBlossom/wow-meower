local _, addon = ...

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

local function db()
  local root = addon.MBLib and addon.MBLib._db
  if not root then return nil end
  if type(root.Stats) ~= "table" then
    root.Stats = {}
  end
  -- Fill missing fields so the schema stays consistent across partial /
  -- older save shapes. Cheap to do on every call.
  local s = root.Stats
  s.totalFires        = s.totalFires        or 0
  s.repliesTextCount  = s.repliesTextCount  or 0
  s.repliesEmoteCount = s.repliesEmoteCount or 0
  s.actionsCount      = s.actionsCount      or 0
  s.firesByWatcherId  = s.firesByWatcherId  or {}
  s.firesBySender     = s.firesBySender     or {}
  s.firesByEmote      = s.firesByEmote      or {}
  s.repliesByText     = s.repliesByText     or {}
  -- totalPurrs counts every /purr invocation, whether typed by the player
  -- or dispatched by a watcher. On first migration, seed from the existing
  -- watcher-dispatched count so prior history isn't lost.
  if s.totalPurrs == nil then
    s.totalPurrs = (s.firesByEmote["PURR"] or 0)
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

local function onWatcherFired(watcher, sender, _channelKey, _trigger)
  local d = db()
  if not d then return end
  d.totalFires = (d.totalFires or 0) + 1
  if watcher and watcher.id then inc(d.firesByWatcherId, watcher.id) end
  if sender then inc(d.firesBySender, sender) end
end

local function onReplyText(_watcher, _sender, resolved)
  local d = db()
  if not d or not resolved or resolved == "" then return end
  d.repliesTextCount = (d.repliesTextCount or 0) + 1
  inc(d.repliesByText, resolved)
end

local function onEmoteFired(_watcher, _sender, token)
  local d = db()
  if not d then return end
  d.repliesEmoteCount = (d.repliesEmoteCount or 0) + 1
  if token then inc(d.firesByEmote, token) end
end

local function onActionFired(_watcher, _sender, _kind)
  local d = db()
  if not d then return end
  d.actionsCount = (d.actionsCount or 0) + 1
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

-- Resolves a watcher id to its display name (or the raw id if the watcher
-- has been deleted since the counter was incremented).
function Stats:WatcherName(id)
  if addon.Watchers and addon.Watchers.GetByID then
    local w = addon.Watchers:GetByID(id)
    if w and w.name and w.name ~= "" then return w.name end
  end
  return tostring(id)
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
      print("  " .. Stats:WatcherName(p[1]) .. emDash .. num(p[2]))
    end
  end
  local topS = Stats:TopN(d.firesBySender, 3, Stats:NotMePredicate())
  if #topS > 0 then
    print(PREFIX .. ": Top senders:")
    for _, p in ipairs(topS) do
      print("  " .. tostring(p[1]) .. emDash .. num(p[2]))
    end
  end
  local topR = Stats:TopN(d.repliesByText, 3)
  if #topR > 0 then
    print(PREFIX .. ": Top replies:")
    for _, p in ipairs(topR) do
      print("  " .. tostring(p[1]) .. emDash .. num(p[2]))
    end
  end
  local topE = Stats:TopN(d.firesByEmote, 3)
  if #topE > 0 then
    print(PREFIX .. ": Top emotes:")
    for _, p in ipairs(topE) do
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

function Stats:Init()
  if self._initialized then return end
  self._initialized = true

  if addon.Hooks then
    addon.Hooks:Register("OnWatcherFired", onWatcherFired)
    addon.Hooks:Register("OnReplyText",    onReplyText)
    addon.Hooks:Register("OnEmoteFired",   onEmoteFired)
    addon.Hooks:Register("OnActionFired",  onActionFired)
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
