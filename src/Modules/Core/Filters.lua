local _, addon = ...

-- ===== Filters =====
-- Per-watcher gates evaluated by Watchers:ProcessMessage before dispatch.
-- Each gate sources its data from a different WoW API; together they let a
-- watcher narrow when it reacts (in this zone, only at night, only to
-- strangers, only while in Bear form, etc.).
--
-- Filters return ALLOW (true) or DENY (false). A filter that is not enabled
-- in the watcher config is always ALLOW — `enabled = false` is the "off"
-- state, the rest of the block is configuration that's just not enforced.
--
-- Every enabled filter must allow for the watcher to fire (logical AND).
-- Errors in a filter (missing API, secret value, etc.) are treated as ALLOW
-- so a bad filter can't suppress all replies — same fail-open philosophy as
-- the rest of the addon.

local Filters = {}

local function isTrue(v) return v == true end

-- ----- Zone -----
-- Player's current map ID, sourced from C_Map.GetBestMapForUnit. Returns
-- nil during loading screens / between zones; that nil case is treated as
-- "not in any of the watcher's zones" so the filter denies. Players who
-- want their watcher to fire during zone transitions should leave the
-- filter off.
local function allowZone(f)
  if not f or not f.enabled then return true end
  local list = f.mapIDs
  if type(list) ~= "table" or #list == 0 then return false end
  if not (C_Map and C_Map.GetBestMapForUnit) then return true end
  local ok, mapID = pcall(C_Map.GetBestMapForUnit, "player")
  if not ok or not mapID then return false end
  for _, id in ipairs(list) do
    if id == mapID then return true end
  end
  return false
end

-- ----- Friends -----
-- "friends" passes when the sender is on the player's WoW friends list OR
-- the message came via BNet (BNet whispers are by definition from a BNet
-- friend, so we accept them unconditionally for the "friends" branch).
-- "strangers" is the inverse.
local function nameOnly(sender)
  if not sender or sender == "" then return nil end
  return sender:match("^([^-]+)") or sender
end

local function isBnetFriend(name)
  if not name or name == "" then return false end
  if not (BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendAccountInfo) then return false end
  local ok, total = pcall(BNGetNumFriends)
  if not ok or not total or total == 0 then return false end
  for i = 1, total do
    local info = (C_BattleNet.GetFriendAccountInfo and C_BattleNet.GetFriendAccountInfo(i)) or nil
    if type(info) == "table" and type(info.gameAccountInfo) == "table" then
      if info.gameAccountInfo.characterName == name then return true end
    end
  end
  return false
end

local function isWowFriend(name)
  if not name or name == "" then return false end
  if not (C_FriendList and C_FriendList.GetFriendInfo) then return false end
  local ok, info = pcall(C_FriendList.GetFriendInfo, name)
  return ok and info ~= nil
end

local function senderIsFriend(sender, bnSenderID)
  if bnSenderID and bnSenderID ~= 0 then return true end
  local name = nameOnly(sender)
  if not name then return false end
  if isWowFriend(name) then return true end
  if isBnetFriend(name) then return true end
  return false
end

local function allowFriends(f, sender, bnSenderID)
  if not f or not f.enabled then return true end
  local mode = f.mode or "anyone"
  if mode == "anyone" then return true end
  local friend = senderIsFriend(sender, bnSenderID)
  if mode == "friends" then return friend end
  if mode == "strangers" then return not friend end
  return true
end

-- ----- Time of day -----
-- Uses server time (GetGameTime returns hour, minute). Wrap-around windows
-- (e.g. 22:00 -> 02:00) are allowed: when end < start, the window spans
-- midnight and the check becomes "after start OR before end". Equal start
-- and end is treated as a 24-hour window (always allow), since a zero-width
-- range would never match.
local function minutesOf(h, m)
  return (tonumber(h) or 0) * 60 + (tonumber(m) or 0)
end

local function allowTimeOfDay(f)
  if not f or not f.enabled then return true end
  if not GetGameTime then return true end
  local ok, hour, minute = pcall(GetGameTime)
  if not ok or not hour then return true end
  local nowM   = minutesOf(hour, minute)
  local startM = minutesOf(f.startHour, f.startMin)
  local endM   = minutesOf(f.endHour, f.endMin)
  if startM == endM then return true end
  if startM < endM then
    return nowM >= startM and nowM < endM
  end
  -- Wrap-around window: passes after start (until midnight) OR before end.
  return nowM >= startM or nowM < endM
end

-- ----- Day of week -----
-- date("*t").wday is 1=Sunday..7=Saturday — same indexing used in the
-- watcher's filters.dayOfWeek.days table. All-true is treated as "no gate"
-- and short-circuits via the enabled check (the UI keeps the toggle off
-- when no days are ticked-off; we still handle the case defensively).
local function allowDayOfWeek(f)
  if not f or not f.enabled then return true end
  if type(f.days) ~= "table" then return true end
  local ok, t = pcall(date, "*t")
  if not ok or not t then return true end
  return f.days[t.wday] == true
end

-- ----- Druid shapeshift -----
-- Only meaningful for druid characters. For non-druids the filter is a
-- no-op (always allow), matching the UI which only renders the section on
-- druid players. GetShapeshiftFormID returns 0 in humanoid form.
local function allowDruidForm(f)
  if not f or not f.enabled then return true end
  if not GetShapeshiftFormID then return true end
  if not addon.Constants then return true end
  local ok, formID = pcall(GetShapeshiftFormID)
  if not ok then return true end
  formID = formID or 0
  local key = addon.Constants.DRUID_FORM_ID_TO_KEY and addon.Constants.DRUID_FORM_ID_TO_KEY[formID]
  if not key then return false end
  return f.forms and f.forms[key] == true
end

-- ----- Combined check -----
-- ANDs all enabled filters together. ctx carries the per-message context
-- (sender, bnSenderID); the other filters source player-state directly.
function Filters:Allow(watcher, ctx)
  if not watcher then return true end
  local f = watcher.filters
  if not f then return true end
  ctx = ctx or {}

  if not allowZone(f.zone) then return false end
  if not allowFriends(f.friends, ctx.sender, ctx.bnSenderID) then return false end
  if not allowTimeOfDay(f.timeOfDay) then return false end
  if not allowDayOfWeek(f.dayOfWeek) then return false end
  if not allowDruidForm(f.druidForm) then return false end

  return true
end

-- ----- Player class helper -----
-- Used by WatchersPanel to decide whether to render the druid-form section
-- in the filter editor. Lives here so the class-detection logic doesn't
-- get duplicated; UI just asks "should I show the druid section?".
function Filters:PlayerIsDruid()
  if not UnitClass then return false end
  local ok, _, classToken = pcall(UnitClass, "player")
  if not ok then return false end
  return classToken == "DRUID"
end

addon.Filters = Filters
