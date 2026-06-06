local _, addon = ...

local Helpers = {}

-- ===== Phrase matching =====
-- Ported from PurgeTheRude/Modules/PurgeTheRude.lua. Whole-word, case-insensitive
-- contains. Both args must already be lowercased. Phrases that start/end with a
-- non-word character (e.g. "!gg", "f*ck") relax the corresponding boundary.

-- Treats the ASCII apostrophe as a word char so contractions read as single
-- tokens: phrase "I" must NOT match inside "I'm", phrase "isn" must NOT
-- match inside "isn't". Without this, the matcher saw the apostrophe as a
-- word boundary and accepted those as whole-word hits.
local function isWordChar(ch)
  return ch ~= "" and ch:match("[%w_']") ~= nil
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

-- Returns the first phrase from `list` that matches `message`, or nil. All
-- per-phrase flags are parallel arrays indexed alongside `list`:
--   exactList[i]            truthy -> the trimmed message must equal phrase i
--   partialList[i]          truthy -> phrase i needs to appear as a plain
--                                     substring (no word-boundary check —
--                                     "test" matches inside "testest")
--   (neither flag)                 -> phrase i needs to appear as a whole word
--                                     (the historical default)
--   caseSensitiveList[i]    truthy -> match phrase i with exact casing
--                           else   -> match phrase i case-insensitively
-- exact and partial are mutually exclusive at the UI layer; if both end up
-- set on the same row anyway, exact wins (it's the stricter constraint).
-- The phrase is returned in its original casing so callers can substitute it
-- back into reply templates verbatim.
function Helpers.findIn(message, list, exactList, caseSensitiveList, partialList)
  if not list then return nil end
  local lower = message:lower()
  local lowerTrimmed = lower:match("^%s*(.-)%s*$") or lower
  local origTrimmed  = message:match("^%s*(.-)%s*$") or message

  for i, phrase in ipairs(list) do
    if phrase ~= "" then
      local cs = caseSensitiveList and caseSensitiveList[i] or false
      local ex = exactList and exactList[i] or false
      local pm = partialList and partialList[i] or false
      local hit
      if ex then
        if cs then
          hit = (origTrimmed == phrase)
        else
          hit = (lowerTrimmed == phrase:lower())
        end
      elseif pm then
        -- Plain substring contains, no word boundary requirement.
        if cs then
          hit = (message:find(phrase, 1, true) ~= nil)
        else
          hit = (lower:find(phrase:lower(), 1, true) ~= nil)
        end
      else
        if cs then
          -- Case-sensitive whole-word: feed the matcher the original strings.
          hit = Helpers.matchWholeWord(message, phrase)
        else
          hit = Helpers.matchWholeWord(lower, phrase:lower())
        end
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
