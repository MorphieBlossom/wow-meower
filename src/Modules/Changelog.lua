local _, addon = ...

addon.MBLib.Changelog:Set({
  {
    version = "1.0.0",
    date = "2026-05-21",
    notify = true,
    categories = {
      ["New"] = {
        "Rebuilt around a generic Watcher model: register any number of phrase/channel/reply rules.",
        "Watches Whisper, BNet Whisper, Say, Emote, Party, Raid, and Instance chat.",
        "Per-watcher reply: free-text message with {sender}/{trigger}/{channel} placeholders, plus optional emote, group invite, and kick popup.",
        "Inline Add/Edit form on the settings page.",
      },
    },
  },
})
