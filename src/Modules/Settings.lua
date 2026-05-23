local _, addon = ...
local L = addon.L

-- Consumer-side settings registered with MBLib. No behavior here — each module
-- that needs a value reads it via addon.MBLib.Settings:Get(<Key>).
--
-- Settings are grouped by subject so the options page reads as topical
-- sections rather than a flat list. Groups render in the order their first
-- setting is added (see MBLib.Settings.groupOrder). All user-visible labels
-- (group names, setting names, descriptions) come from addon.L — edit
-- src/Modules/Strings.lua to rename or translate.

local function refreshWatchersList()
  if addon.WatchersPanel and addon.WatchersPanel.RefreshList then
    addon.WatchersPanel:RefreshList()
  end
end

addon.MBLib.Settings:Add({
  {
    Key = "MinimalisticList",
    Name = L.SETTINGS_MINIMALISTIC_LIST_NAME,
    Description = L.SETTINGS_MINIMALISTIC_LIST_DESC,
    Group = L.SETTINGS_GROUP_DISPLAY,
    Type = "checkbox",
    Default = false,
    OnChange = refreshWatchersList,
  },
  {
    Key = "SortList",
    Name = L.SETTINGS_SORT_LIST_NAME,
    Description = L.SETTINGS_SORT_LIST_DESC,
    Group = L.SETTINGS_GROUP_DISPLAY,
    Type = "checkbox",
    Default = false,
    OnChange = refreshWatchersList,
  },
  {
    Key = "SpamCooldown",
    Name = L.SETTINGS_SPAM_COOLDOWN_NAME,
    Description = L.SETTINGS_SPAM_COOLDOWN_DESC,
    Group = L.SETTINGS_GROUP_OUTPUT,
    Type = "slider",
    Default = 10,
    Min = 0,
    Max = 600,
    Step = 1,
  },
  {
    Key = "RepeatCooldown",
    Name = L.SETTINGS_REPEAT_COOLDOWN_NAME,
    Description = L.SETTINGS_REPEAT_COOLDOWN_DESC,
    Group = L.SETTINGS_GROUP_OUTPUT,
    Type = "slider",
    Default = 10,
    Min = 0,
    Max = 600,
    Step = 1,
  },
})
