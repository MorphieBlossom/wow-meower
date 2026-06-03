local _, addon = ...

addon.MBLib.Changelog:Set({
  {
    version = "12.0.5.1",
    date = "2026-06-04",
    notify = true,
    categories = {
      ["New"] = {
        "Trigger config: Per trigger you can now decide if it should be \"Case sensitive\" and/or exact matching.",
        "Reply config: New \"Guild invite\" action — sends /ginvite via a confirm popup.",
        "Notifications: \"No reply needed\" toggle that skips the entire Reply tab at fire time — pair with a sound for a pure notification watcher.",
        "Notifications: Pick a sound to play locally when a watcher fires (built-in WoW sounds + LibSharedMedia).",
        "Notifications: Highlight matched phrases in the chat with a color.",
      },
      ["Changed"] = {
        "Edit form header shows the watcher's name (\"Edit 'name'\") and updates as you type.",
        "Removed the activate/deactive button in favor of just clicking the status dot to toggle.",
      },
    },
  },
  {
    version = "12.0.5.0",
    date = "2026-05-24",
    notify = false,
    categories = {
      ["New"] = {
        "Initial release of the addon!",
      },
    },
  },
})
