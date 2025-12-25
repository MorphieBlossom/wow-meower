local addonName, addon = ...

-- Global reference for debugging
_G[addonName] = addon

addon.version = GetAddOnMetadata(addonName, "Version") or "1.0.0"
addon.title = GetAddOnMetadata(addonName, "Title") or "Meower"

-- DB Defaults
local defaults = {
    enabled = true,
    showWelcome = true,
    replies = {}, -- List of { trigger = "TOKEN", replyType = "EMOTE"|"CUSTOM", replyValue = "..." }
}

-- Event Frame
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("CHAT_MSG_TEXT_EMOTE")

f:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == addonName then
            -- Initialize DB
            MeowerDB = MeowerDB or {}
            
            -- Apply defaults
            for k, v in pairs(defaults) do
                if MeowerDB[k] == nil then
                    MeowerDB[k] = v
                end
            end
            
            addon:OnInitialize()
            f:UnregisterEvent("ADDON_LOADED")
        end
    elseif event == "PLAYER_LOGIN" then
        addon:OnEnable()
        f:UnregisterEvent("PLAYER_LOGIN")
    elseif event == "CHAT_MSG_TEXT_EMOTE" then
        if MeowerDB.enabled then
            addon:HandleEmote(...)
        end
    end
end)

function addon:OnInitialize()
    if addon.EmoteProvider then
        addon.EmoteProvider:Initialize()
    end
end

function addon:OnEnable()
    if MeowerDB.showWelcome then
        print(format("|cff00ccff%s|r %s loaded. Type /meower for settings.", addon.title, addon.version))
    end
end

function addon:HandleEmote(text, sender, language, channelString, target, flags, unknown, channelNumber, channelName, unknown2, counter, guid)
    -- Check if we are the target
    if target == UnitName("player") then
        -- Attempt to match the emote
        local token = addon.EmoteProvider:MatchEmote(text, sender)
        
        if token then
            -- Check for configured reply
            self:ProcessReply(token, sender)
        end
    end
end

function addon:ProcessReply(triggerToken, sender)
    if not MeowerDB.replies then return end
    
    for _, reply in ipairs(MeowerDB.replies) do
        if reply.trigger == triggerToken then
            -- Execute Reply
            if reply.replyType == "EMOTE" then
                DoEmote(reply.replyValue, sender)
            elseif reply.replyType == "CUSTOM" then
                 -- SendChatMessage(msg, chatType, language, channel);
                 -- For /me we use "EMOTE" chatType
                 SendChatMessage(reply.replyValue, "EMOTE")
            end
            return -- Respond only once? Or allow multiple? Usually once.
        end
    end
end

-- Slash Command
SLASH_MEOWER1 = "/meower"
SlashCmdList["MEOWER"] = function(msg)
    if addon.ToggleConfig then
        addon:ToggleConfig()
    else
        print("|cffff0000Meower:|r Config module not loaded.")
    end
end
