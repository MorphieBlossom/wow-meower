local addonName, addon = ...

-- Global reference for debugging
_G[addonName] = addon

addon.version = GetAddOnMetadata(addonName, "Version") or "1.0.0"
addon.title = GetAddOnMetadata(addonName, "Title") or "Meower"

-- DB Defaults
local defaults = {
    enabled = true,
    showWelcome = true,
}

-- Event Frame
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")

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
    end
end)

function addon:OnInitialize()
    -- Initial setup
end

function addon:OnEnable()
    if MeowerDB.showWelcome then
        print(format("|cff00ccff%s|r %s loaded. Type /meower for settings.", addon.title, addon.version))
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
