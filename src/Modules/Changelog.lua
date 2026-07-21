local _, addon = ...

addon.MBLib.Changelog:Set({
  {
    version = "12.1.0.1",
    date = "2026-07-21",
    notify = false,
    categories = {
      ["Fixed"] = {
        "TOC file version",
      },
    },
  },
  {
    version = "12.1.0.0",
    date = "2026-07-20",
    notify = true,
    categories = {
      ["New"] = {
        "New {name} placeholder for your current character's name — use it in replies, or in a trigger phrase to match your own name without typing it in.",
        "New \"Trigger on any message\" option — a watcher can now fire on every message with no trigger phrase.",
      },
    },
  },
  {
    version = "12.0.7.3",
    date = "2026-07-02",
    notify = false,
    categories = {
      ["Fixed"] = {
        "Stats page: high trigger and sender counts are no longer cut off — the count column now fits larger numbers while staying aligned.",
      },
    },
  },
  {
    version = "12.0.7.2",
    date = "2026-06-25",
    notify = false,
    categories = {
      ["New"] = {
        "Watcher filter: Only fire while you are AFK, in Do Not Disturb, or PvP enabled.",
      },
      ["Changed"] = {
        "Reworked the layout of the lists on the Stats page.",
      },
      ["Fixed"] = {
        "Invites to players on another realm now work — the invite keeps their realm name.",
      },
    },
  },
  {
    version = "12.0.7.1",
    date = "2026-06-25",
    notify = false,
    categories = {
      ["Fixed"] = {
        "Fixed an issue on the Stats page that could cause some Lua errors.",
      },
    },
  },
  {
    version = "12.0.5.3",
    date = "2026-06-15",
    notify = true,
    categories = {
      ["New"] = {
        "Profiles: Per-character configurations. Each character can have its own watcher set — switch between them from the new Profiles page. Profiles can be copied, exported as a shareable string, and imported from another player. Each watcher can also be marked Account-wide so it follows you across every character.",
        "Stats page: See how often each watcher fires and who triggers it. Two tabs — \"Top 10s\" with totals and the top watchers / senders, and \"Overview\" with a per-player drill-down (search by name, filter by trigger, expand any player to see every trigger they hit and every reply / emote you sent back). Can be turned off entirely from the new \"Extras\" settings group.",
        "Watchers list: Two tabs — Global (account-wide) and Profile. Per-watcher Export button and a list-level Import button for sharing single watchers.",
      },
      ["Fixed"] = {
        "Combat error: Chat messages tagged with Blizzard's new \"secret value\" during combat no longer crash the dispatcher.",
        "Chat coloring: Your own outgoing messages are no longer color-highlighted when they contain a trigger phrase.",
      },
    },
  },
  {
    version = "12.0.5.2",
    date = "2026-06-06",
    notify = false,
    categories = {
      ["New"] = {
        "Trigger config: New per-trigger \"Partial match\" checkbox — when ticked, the phrase matches anywhere inside a word (e.g. \"meow\" triggers on \"meower\"). Mutually exclusive with \"Exact match\".",
        "Notifications: New per-watcher \"Show icon on trigger\" config. Pick any in-game icon (search by name or ID), set its size and fade duration, and position it anywhere on screen via the Mover button.",
        "Movers: A new options page where you can manage and reposition every configured display frame from one place.",
        "Reply placeholders: New {purr} token — substitutes a random cat-flavored action (*purr*, *purrs*, *purrs softly*) into your reply text each time the watcher fires.",
      },
      ["Changed"] = {
        "Notifications tab: Sound, Icon, and Coloring sections are now collapsible. Each section has a master checkbox; unticking it hides the section's controls and clears its data so the watcher cleanly stops emitting that signal.",
        "Reply tab: Text reply, Emote reply, and Actions sections are now collapsible — same pattern as Notifications. New watchers open with all three sections collapsed; tick a section's master checkbox to configure it.",
      },
      ["Fixed"] = {
        "Sound-picker speaker icons no longer leak into other Blizzard / addon dropdowns; the speaker now only appears in the watcher's notification sound dropdown.",
      },
    },
  },
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
