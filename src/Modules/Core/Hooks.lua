local _, addon = ...

-- ===== Hooks =====
-- The seam between the core watcher pipeline and Extras. Extras register
-- callbacks against named channels here; core code Dispatches/Transforms
-- through this table. Watchers.lua does not know who is listening — only
-- that something *might* be.
--
-- Two channel shapes:
--   - Dispatch channels: fire-and-forget callbacks invoked in registration
--     order. Each callback is pcall-wrapped so one throwing can't tank the
--     rest. Example: "OnWatcherFired" lets stats / on-screen flair listen
--     without modifying Watchers.lua.
--   - Transform channels: chained `(value, ctx) -> value` callbacks; the
--     output of each becomes the input of the next. pcall-wrapped, with a
--     fallback that drops the callback's contribution if it throws (so the
--     previous value carries through unchanged). Example: "ReplyTransforms"
--     lets Extras rewrite reply text without Watchers.lua knowing about
--     the rules being applied.
--
-- GetNow is a swappable clock so Debug can override the current date for
-- consumers that branch on the date. Extras call addon.Hooks.GetNow()
-- instead of date() directly.

local Hooks = {}

Hooks.ReplyTransforms = {} -- Transform: (text, ctx) -> text
Hooks.OnWatcherFired  = {} -- Dispatch:  (watcher, sender, channelKey, trigger)
Hooks.OnReplyText     = {} -- Dispatch:  (watcher, sender, resolvedText, channelKey, trigger)
Hooks.OnEmoteFired    = {} -- Dispatch:  (watcher, sender, token, channelKey, trigger)
Hooks.OnActionFired   = {} -- Dispatch:  (watcher, sender, actionKind, channelKey, trigger)  -- "invite" | "guildInvite" | "kick"
Hooks.OnKickConfirmed = {} -- Dispatch:  (target, sender, channelKey, trigger)
Hooks.OnAFKChanged    = {} -- Dispatch:  (isAFK)
Hooks.OnWatcherDeleted = {} -- Dispatch: (watcherId)  -- extras drop state keyed by this id

function Hooks.GetNow()
  return date("*t")
end

local function channelOf(name)
  local list = Hooks[name]
  if type(list) ~= "table" then return nil end
  return list
end

-- Append a callback to a named channel. Silently no-ops on unknown channel
-- so consumers can defensively register for hooks that may not exist in
-- older Meower builds.
function Hooks:Register(channel, fn)
  if type(fn) ~= "function" then return end
  local list = channelOf(channel)
  if not list then return end
  table.insert(list, fn)
end

-- Dispatch: invoke every callback in order, passing varargs. Errors are
-- caught per-callback so the rest still run.
function Hooks:Dispatch(channel, ...)
  local list = channelOf(channel)
  if not list then return end
  for _, fn in ipairs(list) do
    pcall(fn, ...)
  end
end

-- Transform: chain `(value, ctx) -> value` through every callback. A
-- callback that errors is skipped and the previous value carries through
-- unchanged — the core pipeline never sees a nil or an exception.
function Hooks:Transform(channel, value, ctx)
  local list = channelOf(channel)
  if not list then return value end
  for _, fn in ipairs(list) do
    local ok, result = pcall(fn, value, ctx)
    if ok and result ~= nil then
      value = result
    end
  end
  return value
end

addon.Hooks = Hooks
