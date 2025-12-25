local addonName, addon = ...
addon.EmoteProvider = {}
local EP = addon.EmoteProvider

-- Expanded list of emote tokens based on WoW API
local emoteTokens = {
    "ABSORB", "AGREE", "AMAZE", "ANGRY", "APOLOGIZE", "APPLAUD", "ATTACKTARGET", 
    "BARK", "BASHFUL", "BECKON", "BEG", "BELCH", "BITE", "BLEED", "BLINK", "BLOODSPORT",
    "BLUSH", "BOGGLE", "BONK", "BORED", "BOUNCE", "BOW", "BRB", "BURP", "BYE", 
    "CACKLE", "CALM", "CAT", "CHARGE", "CHEER", "CHEW", "CHICKEN", "CHUCKLE", "CLAP", 
    "COLD", "COMFORT", "COMMEND", "CONFUSED", "CONGRATULATE", "COUGH", "COWER", "CRACK", 
    "CRINGE", "CRY", "CUDDLE", "CURIOUS", "CURTSEY", "DANCE", "DISAPPOINT", "DOH", "DOOM", 
    "DRINK", "DROOL", "DUCK", "EAT", "EXCITED", "EYE", "FACEPALM", "FAREWELL", "FART", 
    "FEAR", "FEAST", "FIDGET", "FLAP", "FLEX", "FLIRT", "FOLLOW", "GASP", "GAZE", 
    "GIGGLE", "GLAD", "GLARE", "GLOAT", "GOODBYE", "GREET", "GRIN", "GROAN", "GROVEL", 
    "GROWL", "GUFFAW", "HAIL", "HAPPY", "HEALME", "HELLO", "HELPME", "HUG", "HUNGRY", 
    "IMPATIENT", "INCOMING", "INSULT", "INTRODUCE", "JK", "KISS", "KNEEL", "LAUGH", 
    "LAYDOWN", "LICK", "LISTEN", "LOST", "LOVE", "MASSAGE", "MOAN", "MOCK", "MOO", 
    "MOURN", "NO", "NOD", "NOSEPICK", "OOM", "OPENFIRE", "PANIC", "PAT", "PEER", 
    "PITY", "PLEAD", "POINT", "POKE", "PONDER", "POUNCE", "PRAISE", "PRAY", "PURR", 
    "PUZZLE", "QUESTION", "RAISE", "RASP", "READY", "ROAR", "ROFL", "RUDE", "SALUTE", 
    "SCARED", "SCRATCH", "SEXY", "SHAKE", "SHIMMY", "SHIVER", "SHOO", "SHOUT", "SHRUG", 
    "SHY", "SIGH", "SING", "SIT", "SLAP", "SLEEP", "SMILE", "SMIRK", "SNARL", "SNICKER", 
    "SNIFF", "SNUB", "SOOTHE", "SPIT", "STAND", "STARE", "SURPRISED", "SURRENDER", 
    "TALK", "TALKEX", "TALKQ", "TAP", "TAUNT", "TEASE", "THANK", "THANKS", "THIRSTY", 
    "THREATEN", "TICKLE", "TIRED", "TRAIN", "VETO", "VICTORY", "VIOLIN", "VOLUNTEER", 
    "WAIT", "WAVE", "WEEP", "WELCOME", "WHINE", "WHISTLE", "WINK", "WORK", "WRATH", 
    "YAWN", "YAY", "YES"
}

-- Map localized message pattern -> Emote Token
local msgToToken = {}
local availableEmotes = {}

function EP:Initialize()
    wipe(msgToToken)
    wipe(availableEmotes)
    
    for _, token in ipairs(emoteTokens) do
        -- Globals:
        -- EMOTE_TOKEN_NONE -> "Player dances."
        -- EMOTE_TOKEN_YOU  -> "Player dances with you." (This is what we match against usually)
        
        local patternYou = _G["EMOTE_" .. token .. "_YOU"]
        local patternNone = _G["EMOTE_" .. token .. "_NONE"]
        
        if patternYou then
            -- Store for matching logic (someone emotes ON us)
            msgToToken[patternYou] = token
            
            -- Prepare data for UI or other uses
            -- We store the raw patterns too so we can display them if needed
            tinsert(availableEmotes, {
                token = token,
                command = "/" .. token:lower(),
                label = token:lower(),
                textNone = patternNone or "",
                textYou = patternYou
            })
        elseif patternNone then
             -- Some emotes might not have a "YOU" version (uncommon for targeted ones, but possible)
             -- If we only care about targeted replies, we might skip these, but let's include them for the list.
             tinsert(availableEmotes, {
                token = token,
                command = "/" .. token:lower(),
                label = token:lower(),
                textNone = patternNone,
                textYou = ""
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
