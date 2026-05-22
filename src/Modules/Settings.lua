local _, addon = ...

-- Consumer-side settings registered with MBLib. No behavior here — each module
-- that needs a value reads it via addon.MBLib.Settings:Get(<Key>).

local function refreshWatchersList()
  if addon.WatchersPanel and addon.WatchersPanel.RefreshList then
    addon.WatchersPanel:RefreshList()
  end
end

addon.MBLib.Settings:Add({
  {
    Key = "SpamCooldown",
    Name = "Spam Cooldown (in seconds)",
    Description = "After a watcher fires on someone, ignore further messages from that sender for this many seconds. Set to 0 to disable.",
    Group = "General",
    Type = "slider",
    Default = 60,
    Min = 0,
    Max = 600,
    Step = 1,
  },
  {
    Key = "MinimalisticList",
    Name = "Minimalistic list",
    Description = "Only show the watcher names in the list, not the configured details. Each row gets an expand/collapse button next to Delete to reveal its details on demand.",
    Group = "General",
    Type = "checkbox",
    Default = false,
    OnChange = refreshWatchersList,
  },
  {
    Key = "SortList",
    Name = "Sort list",
    Description = "Sort the watchers list alphabetically by name.",
    Group = "General",
    Type = "checkbox",
    Default = false,
    OnChange = refreshWatchersList,
  },
})
