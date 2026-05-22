local addonName, addon = ...

addon.MBLib:AddSlashTrigger("/mw")
addon.MBLib:SetIcon("Interface\\AddOns\\" .. addonName .. "\\Media\\meower-icon.png")
addon.MBLib:SetSettingsSubcategoryName("Settings")

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(self, _, name)
  if name == addonName then
    addon.MBLib:Init()
    if addon.Watchers and addon.Watchers.Init then
      addon.Watchers:Init()
    end
    self:UnregisterEvent("ADDON_LOADED")
    self:SetScript("OnEvent", nil)
  end
end)
