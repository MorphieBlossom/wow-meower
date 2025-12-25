local addonName, addon = ...
addon.EmoteResponder = {}
local ER = addon.EmoteResponder

-- Dependencies
local EP = addon.EmoteProvider

local f = CreateFrame("Frame")

function ER:Initialize()
    f:RegisterEvent("CHAT_MSG_TEXT_EMOTE")
    f:SetScript("OnEvent", function(self, event, ...)
        if event == "CHAT_MSG_TEXT_EMOTE" then
            ER:OnChatMsgEmote(...)
        end
    end)
end

function ER:OnChatMsgEmote(text, sender, language, channelString, target, flags, unknown, channelNumber, channelName, unknown2, counter, guid)
    -- 1. Check if disabled globally
    if not MeowerDB.enabled then return end
    
    -- 2. Check if we are the target
    -- Note: target is the localized name of the target unit
    local myName = UnitName("player")
    if target ~= myName then return end

    -- 3. Attempt to match the emote
    local token = EP:MatchEmote(text, sender)
    
    if token then
        -- 4. Check for configured reply
        self:ProcessReply(token, sender)
    end
end

function ER:ProcessReply(triggerToken, sender)
    if not MeowerDB.replies then return end
    
    for _, reply in ipairs(MeowerDB.replies) do
        if reply.trigger == triggerToken then
            -- Execute Reply
            if reply.replyType == "EMOTE" then
                -- DoEmote(token, [target])
                DoEmote(reply.replyValue, sender)
            elseif reply.replyType == "CUSTOM" then
                 -- SendChatMessage(msg, chatType, language, channel);
                 -- For /me we use "EMOTE" chatType
                 SendChatMessage(reply.replyValue, "EMOTE")
            end
            
            -- Stop after finding the first matching rule?
            -- Usually yes, to avoid double replies for same trigger.
            return 
        end
    end
end
