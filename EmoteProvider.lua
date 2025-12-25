local addonName, addon = ...
addon.EmoteProvider = {}
local EP = addon.EmoteProvider

-- A list of common emote tokens. In a full production addon, 
-- we might want to mine these from the game client or include a comprehensive library.
-- These keys correspond to "EMOTE_KEY_YOU" global strings usually.
local commonEmotes = {
    "POKE", "WAVE", "DANCE", "CHEER", "CLAP", "HUG", "KISS", "BOW", "SALUTE", 
    "SLAP", "LAUGH", "CRY", "EAT", "DRINK", "SLEEP", "SIT", "STAND", "TALK", 
    "QUESTION", "RUDE", "SHY", "FLEX", "ROAR", "BARK", "MOO", "CHICKEN"
}

-- Map localized message pattern -> Emote Token
local msgToToken = {}
local availableEmotes = {}

function EP:Initialize()
    wipe(msgToToken)
    wipe(availableEmotes)
    
    for _, token in ipairs(commonEmotes) do
        -- Typically, the string for "Player uses EMOTE on You" is stored in _G["EMOTE_" .. token .. "_YOU"]
        -- Example: EMOTE_POKE_YOU -> "%s pokes you."
        local pattern = _G["EMOTE_" .. token .. "_YOU"]
        
        if pattern then
            -- Store for matching logic
            msgToToken[pattern] = token
            
            -- Store for UI list
            -- We try to get the command, which is usually found via other means, 
            -- but simple assumption: /lower(token)
            tinsert(availableEmotes, {
                token = token,
                command = "/" .. token:lower(),
                label = token:lower() -- Could be prettier
            })
        end
    end
    
    -- Sort available emotes for UI
    table.sort(availableEmotes, function(a, b) return a.label < b.label end)
end

function EP:GetAvailableEmotes()
    if #availableEmotes == 0 then
        self:Initialize()
    end
    return availableEmotes
end

-- Matches a chat message to an emote token
-- @param msg: The full localized chat message received
-- @param sender: The name of the sender
function EP:MatchEmote(msg, sender)
    if #availableEmotes == 0 then
        self:Initialize()
    end

    -- The messages are usually formatted like "%s pokes you."
    -- We can try to reconstruct the expected message for each emote given the sender
    -- and see if it matches the received msg.
    
    for pattern, token in pairs(msgToToken) do
        local expected = format(pattern, sender)
        if expected == msg then
            return token
        end
    end
    
    return nil
end

function EP:GetEmoteCommand(token)
    return "/" .. token:lower()
end
