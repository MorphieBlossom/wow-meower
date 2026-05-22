local _, addon = ...
addon.EmoteProvider = {}
local EP = addon.EmoteProvider

-- Map localized message pattern -> Emote Token
local msgToToken = {}
local availableEmotes = {}

-- Fallback for clients that don't expose MAXEMOTEINDEX (older flavors, very
-- early load). Retail (TWW) is at 628 today; 800 leaves room for additions
-- before a refresh is needed.
local MAX_INDEX_FALLBACK = 800

function EP:Init()
  wipe(msgToToken)
  wipe(availableEmotes)

  -- Blizzard's ChatEmoteConstants.lua publishes EMOTE<i>_TOKEN globals (with
  -- MAXEMOTEINDEX as the upper bound). Iterating those is the canonical way
  -- to enumerate every emote the client knows about — it auto-tracks tokens
  -- added in future patches without a code change here. Indices are
  -- non-contiguous (gaps past 455 for faction shouts and recent additions),
  -- so the loop tolerates missing slots.
  local maxIndex = _G.MAXEMOTEINDEX or MAX_INDEX_FALLBACK
  for i = 1, maxIndex do
    local token = _G["EMOTE" .. i .. "_TOKEN"]
    if token and token ~= "UNUSED" then
      -- EMOTE_<TOKEN>_NONE -> "%s waves."        (caster, no target)
      -- EMOTE_<TOKEN>_YOU  -> "%s waves at you." (caster targets the player)
      -- Other variants exist (_OTHER, _SELF, _TARGET) — add here if needed.
      local patternYou = _G["EMOTE_" .. token .. "_YOU"]
      local patternNone = _G["EMOTE_" .. token .. "_NONE"]

      if patternYou then
        msgToToken[patternYou] = token
      end

      -- Show in the dropdown if the token produces any displayable text or has
      -- a slash command bound. Tokens with neither are unfinished/internal and
      -- aren't useful as a reply.
      if patternYou or patternNone or _G["EMOTE" .. i .. "_CMD1"] then
        tinsert(availableEmotes, {
          token = token,
          command = "/" .. token:lower(),
          label = token:lower(),
          textNone = patternNone or "",
          textYou = patternYou or "",
        })
      end
    end
  end

  -- Sort available emotes for UI
  table.sort(availableEmotes, function(a, b) return a.label < b.label end)
end

function EP:GetAvailableEmotes()
  if #availableEmotes == 0 then
    self:Init()
  end
  return availableEmotes
end

-- Matches a chat message to an emote token
-- @param msg: The full localized chat message received
-- @param sender: The name of the sender
function EP:MatchEmote(msg, sender)
  if #availableEmotes == 0 then
    self:Init()
  end

  -- The messages are usually formatted like "%s pokes you."
  for pattern, token in pairs(msgToToken) do
    -- Replace %s with sender name to create the expected string
    -- Note: format() might fail if the pattern contains multiple %s or other formatting,
    -- but standard emotes are usually just "%s ...".

    -- Use pcall to avoid errors if pattern is weird
    local success, expected = pcall(format, pattern, sender)

    if success and expected == msg then
      return token
    end
  end

  return nil
end

function EP:GetEmoteCommand(token)
  return "/" .. token:lower()
end
