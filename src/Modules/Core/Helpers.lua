local _, addon = ...

local Helpers = {}

-- ===== Phrase matching =====
-- Ported from PurgeTheRude/Modules/PurgeTheRude.lua. Whole-word, case-insensitive
-- contains. Both args must already be lowercased. Phrases that start/end with a
-- non-word character (e.g. "!gg", "f*ck") relax the corresponding boundary.

local function isWordChar(ch)
  return ch ~= "" and ch:match("[%w_]") ~= nil
end

function Helpers.matchWholeWord(lower, phraseLower)
  local needLeft = isWordChar(phraseLower:sub(1, 1))
  local needRight = isWordChar(phraseLower:sub(-1))
  local start = 1
  while true do
    local s, e = lower:find(phraseLower, start, true)
    if not s then return false end
    local leftOK = not needLeft or s == 1 or not isWordChar(lower:sub(s - 1, s - 1))
    local rightOK = not needRight or e == #lower or not isWordChar(lower:sub(e + 1, e + 1))
    if leftOK and rightOK then return true end
    start = s + 1
  end
end

-- Returns the first phrase from `list` that matches `lower`, or nil. When
-- `exact` is truthy the entire message (trimmed of surrounding whitespace) must
-- equal the phrase; otherwise the phrase only needs to appear as a whole word
-- somewhere in the message. Both sides are case-insensitive — callers pass
-- `lower` already lower-cased and we lower the phrase here. The phrase is
-- returned in its original (un-lowercased) form so callers can substitute it
-- back into reply templates verbatim.
function Helpers.findIn(lower, list, exact)
  if not list then return nil end
  local trimmed = exact and (lower:match("^%s*(.-)%s*$") or lower) or nil
  for _, phrase in ipairs(list) do
    if phrase ~= "" then
      local phraseLower = phrase:lower()
      local hit
      if exact then
        hit = (trimmed == phraseLower)
      else
        hit = Helpers.matchWholeWord(lower, phraseLower)
      end
      if hit then return phrase end
    end
  end
  return nil
end

-- ===== CSV =====

function Helpers.splitCsv(text)
  local list = {}
  for part in (text or ""):gmatch("([^,]+)") do
    part = part:match("^%s*(.-)%s*$")
    if part ~= "" then table.insert(list, part) end
  end
  return list
end

function Helpers.joinCsv(list)
  if type(list) ~= "table" then return "" end
  return table.concat(list, ", ")
end

-- ===== Placeholder substitution =====
-- gsub with a replacement *function* so user-supplied values can't introduce
-- Lua capture references (%1, %0) into the output.
function Helpers.applyPlaceholders(template, values)
  if type(template) ~= "string" or template == "" then return template or "" end
  values = values or {}
  return (template:gsub("{(%w+)}", function(key)
    local v = values[key]
    if v == nil then return "{" .. key .. "}" end
    return tostring(v)
  end))
end

-- ===== ID generation =====
-- Monotonic id derived from the existing set, so we don't need a separate
-- counter in SavedVariables. Format: "wN" where N is the next free integer.
function Helpers.newId(takenIds)
  local max = 0
  for id in pairs(takenIds or {}) do
    local n = tonumber(id:match("^w(%d+)$"))
    if n and n > max then max = n end
  end
  return ("w%d"):format(max + 1)
end

addon.Helpers = Helpers
