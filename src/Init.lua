local addonName, addon = ...

addon.MBLib:AddSlashTrigger("/mw")
addon.MBLib:SetIcon("Interface\\AddOns\\" .. addonName .. "\\Media\\meower-icon.png")
-- Opt into the MBLib profile system. Has to be called BEFORE MBLib:Init
-- so the active profile is bound before Watchers / Stats / Movers ask
-- for their backing stores. No-op on builds without Profiles.
if addon.MBLib.Profiles and addon.MBLib.Profiles.Enable then
  addon.MBLib.Profiles:Enable()
  -- Drop schema-agnostic empties ("" / {}) from export strings so the
  -- exported watcher / profile dump is shorter. Lossless: Meower's
  -- normalizeWatcher fills missing fields with defaults on import.
  if addon.MBLib.Profiles.SetExportCompact then
    addon.MBLib.Profiles:SetExportCompact(true)
  end
end
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
    -- Conditional Settings entries have to register BEFORE MBLib:Init():
    -- the Options panel is built inside Init() and isn't rebuilt after.
    if addon.Extras and addon.Extras.Woofer and addon.Extras.Woofer.RegisterSettings then
      addon.Extras.Woofer:RegisterSettings()
    end
    if addon.Extras and addon.Extras.Stats and addon.Extras.Stats.RegisterSettings then
      addon.Extras.Stats:RegisterSettings()
    end
    addon.MBLib:Init()
    if addon.Debug and addon.Debug.Init then
      addon.Debug:Init()
    end
    if addon.Watchers and addon.Watchers.Init then
      addon.Watchers:Init()
    end
    -- Display layer (Phase 2). IconDisplay must come after Watchers:Init
    -- because it walks the watcher list to pre-create icon frames + their
    -- mover registrations.
    if addon.IconDisplay and addon.IconDisplay.Init then
      addon.IconDisplay:Init()
    end
    -- Stats hooks listen for OnWatcherFired / OnEmoteFired; init after
    -- Watchers so the hook system is wired and after MBLib so the
    -- /mw stats slash registration finds Commands ready.
    if addon.Extras and addon.Extras.Stats and addon.Extras.Stats.Init then
      addon.Extras.Stats:Init()
    end
    -- Extras register against addon.Hooks AFTER core init so they see
    -- a fully-formed addon table. Each Extra is responsible for its own
    -- enabled-gating; we just hand it the chance to wire up.
    if addon.Extras and addon.Extras.Woofer and addon.Extras.Woofer.Register then
      addon.Extras.Woofer:Register()
    end
    self:UnregisterEvent("ADDON_LOADED")
    self:SetScript("OnEvent", nil)
  end
end)
