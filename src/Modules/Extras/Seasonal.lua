local _, addon = ...

-- ===== Seasonal =====
-- Extras layer: registers calendar-bound text transforms against the core
-- reply pipeline via addon.Hooks. The Watcher pipeline knows nothing about
-- dates — it just walks ReplyTransforms in order.
--
-- Each entry in `transforms` has:
--   - matches(now): boolean  - does this entry apply today?
--   - transform(text, ctx): text  - rewrite the reply text
--
-- The single combined transform registered against the hook walks the list
-- and chains every match. New seasonal effects added in future phases drop
-- into this same array without touching anything else.
--
-- Date source: addon.Hooks.GetNow() (not date() directly) so the Debug
-- module can override the current date for testing.

local Seasonal = {}

local function isEnabled()
  -- Gating setting; default on. The Settings module may not have run yet
  -- at file-load time, so we re-check on every transform invocation.
  if not (addon.MBLib and addon.MBLib.Settings) then return true end
  local v = addon.MBLib.Settings:Get("ExtraSeasonalEnabled")
  if v == nil then return true end
  return v and true or false
end

-- Returns the table {year=, month=, day=, ...} for the current effective
-- date. Defaults to date("*t") via Hooks.GetNow when nothing has been
-- overridden.
local function now()
  local ok, t = pcall(addon.Hooks.GetNow)
  if ok and type(t) == "table" then return t end
  return date("*t")
end

Seasonal.transforms = {
  {
    name = "0104",
    matches = function(t) return t.month == 4 and t.day == 1 end,
    transform = function(text)
      return string.reverse(text)
    end,
  },
}

-- Returns a short label of whatever seasonal effect is active right now,
-- or nil if none. Used by the "Hide today's flair" surface in later phases.
function Seasonal:GetActiveLabel()
  local t = now()
  for _, entry in ipairs(self.transforms) do
    if entry.matches(t) then
      return entry.name
    end
  end
  return nil
end

-- The single ReplyTransforms callback. Walks `transforms` and chains every
-- match in order. Pure: doesn't mutate state, only returns transformed text.
local function combinedTransform(text, ctx)
  if not isEnabled() then return text end
  if type(text) ~= "string" or text == "" then return text end
  local t = now()
  local out = text
  for _, entry in ipairs(Seasonal.transforms) do
    if entry.matches(t) then
      local ok, result = pcall(entry.transform, out, ctx)
      if ok and type(result) == "string" then
        out = result
      end
    end
  end
  return out
end

function Seasonal:Register()
  if self._registered then return end
  self._registered = true
  addon.Hooks:Register("ReplyTransforms", combinedTransform)
end

addon.Extras = addon.Extras or {}
addon.Extras.Seasonal = Seasonal
