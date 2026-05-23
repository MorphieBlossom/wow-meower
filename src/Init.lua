local addonName, addon = ...

addon.MBLib:AddSlashTrigger("/mw")
addon.MBLib:SetIcon("Interface\\AddOns\\" .. addonName .. "\\Media\\meower-icon.png")
addon.MBLib:SetSettingsSubcategoryName("Settings")
addon.MBLib:SetMacroButton({
  icon      = "INV_BabyEversongLynx_Black",
  macroName = "Meower settings",
  macroBody = "/mw settings",
  tooltip   = {
    title = "Open Meower settings",
    desc  = "Drop it on your action bar for a shortcut button to open Meower settings.",
  },
})

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(self, _, name)
  if name == addonName then
    addon.MBLib:Init()
    if addon.Debug and addon.Debug.Init then
      addon.Debug:Init()
    end
    if addon.Watchers and addon.Watchers.Init then
      addon.Watchers:Init()
    end
    -- Extras register against addon.Hooks AFTER core init so they see
    -- a fully-formed addon table. Each Extra is responsible for its own
    -- enabled-gating; we just hand it the chance to wire up.
    if addon.Extras and addon.Extras.Seasonal and addon.Extras.Seasonal.Register then
      addon.Extras.Seasonal:Register()
    end
    self:UnregisterEvent("ADDON_LOADED")
    self:SetScript("OnEvent", nil)
  end
end)
