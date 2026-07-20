local _, addon = ...

local Constants = {}

Constants.CHANNELS = {
  WHISPER = {
    key = "w",
    label = "Whisper",
    events = { "CHAT_MSG_WHISPER" },
    replyChatType = "WHISPER",
    isGroupChannel = false
  },
  BNET = {
    key = "b",
    label = "BNet Whisper",
    events = { "CHAT_MSG_BN_WHISPER" },
    replyChatType = "BN_WHISPER",
    isGroupChannel = false,
    isBnet = true
  },
  GUILD = {
    key = "g",
    label = "Guild",
    events = { "CHAT_MSG_GUILD" },
    replyChatType = "GUILD",
    isGroupChannel = false
  },
  SAY = {
    key = "s",
    label = "Say",
    events = { "CHAT_MSG_SAY" },
    replyChatType = "SAY",
    isGroupChannel = false
  },
  EMOTE = {
    key = "e",
    label = "Emote",
    events = { "CHAT_MSG_EMOTE", "CHAT_MSG_TEXT_EMOTE" },
    replyChatType = "EMOTE",
    isGroupChannel = false
  },
  PARTY = {
    key = "p",
    label = "Party",
    events = { "CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER" },
    replyChatType = "PARTY",
    isGroupChannel = true
  },
  RAID = {
    key = "r",
    label = "Raid",
    events = { "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING" },
    replyChatType = "RAID",
    isGroupChannel = true
  },
  INSTANCE = {
    key = "i",
    label = "Instance",
    events = { "CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER" },
    replyChatType = "INSTANCE_CHAT",
    isGroupChannel = true
  },
  -- World/city channels. They all share the CHAT_MSG_CHANNEL event; the
  -- dispatcher reads CHAT_MSG_CHANNEL's arg9 (channelBaseName) to figure
  -- out which one this row corresponds to. SendChatMessage uses chat
  -- type "CHANNEL" with a channelIndex resolved via GetChannelName(name)
  -- at fire time.
  GENERAL = {
    key = "cg",
    label = "General",
    events = { "CHAT_MSG_CHANNEL" },
    replyChatType = "CHANNEL",
    channelName = "General",
    isGroupChannel = false,
    isWorldChannel = true,
  },
  TRADE = {
    key = "ct",
    label = "Trade",
    events = { "CHAT_MSG_CHANNEL" },
    replyChatType = "CHANNEL",
    channelName = "Trade",
    isGroupChannel = false,
    isWorldChannel = true,
  },
  SERVICES = {
    key = "cs",
    label = "Services",
    events = { "CHAT_MSG_CHANNEL" },
    replyChatType = "CHANNEL",
    channelName = "Services",
    isGroupChannel = false,
    isWorldChannel = true,
  },
}

Constants.CHANNEL_ORDER = {
  Constants.CHANNELS.WHISPER,
  Constants.CHANNELS.BNET,
  Constants.CHANNELS.GUILD,
  Constants.CHANNELS.SAY,
  Constants.CHANNELS.EMOTE,
  Constants.CHANNELS.PARTY,
  Constants.CHANNELS.RAID,
  Constants.CHANNELS.INSTANCE,
  Constants.CHANNELS.GENERAL,
  Constants.CHANNELS.TRADE,
  Constants.CHANNELS.SERVICES,
}

Constants.CHANNEL_BY_KEY = {}
for _, def in pairs(Constants.CHANNELS) do
  Constants.CHANNEL_BY_KEY[def.key] = def
end

-- World channels share CHAT_MSG_CHANNEL; the dispatcher resolves which one
-- fired by matching arg9 (channelBaseName) against this lookup.
Constants.WORLD_CHANNEL_BY_NAME = {}
for _, def in pairs(Constants.CHANNELS) do
  if def.isWorldChannel and def.channelName then
    Constants.WORLD_CHANNEL_BY_NAME[def.channelName] = def
  end
end

-- Channels a watcher may fire on for EVERY message (the per-watcher matchAny
-- toggle), keyed by channel key. Restricted to direct / small-audience
-- channels so "reply to anything" can't be pointed at a firehose like Trade
-- or a world channel. BNet whisper rides along with Whisper — both are direct
-- messages, which is the case this mode was added for.
Constants.MATCH_ANY_CHANNELS = { w = true, b = true, g = true, p = true, s = true, e = true }

-- Reply-target codes a match-any watcher may send to, keyed by the reply
-- short code (Constants.REPLY_CHANNELS). Mirrors MATCH_ANY_CHANNELS so a
-- "reply to anything" watcher can't be pointed at a spammy reply target
-- either. "same" is always allowed — it just echoes back the source channel,
-- which is itself already restricted. There is no "b" here: BNet replies go
-- out via "same".
Constants.MATCH_ANY_REPLY_CHANNELS = { same = true, w = true, g = true, p = true, s = true, e = true }

-- Stand-in "matched phrase" for a match-any fire. There is no real trigger
-- phrase, so this is what {trigger} resolves to and what Stats groups the
-- fire under (a stable constant keeps the Stats key from exploding into one
-- entry per distinct incoming message).
Constants.MATCH_ANY_TRIGGER = "(any message)"

Constants.REPLY_CHANNELS = { "same", "w", "g", "s", "p", "i", "r", "e", "cg", "ct", "cs" }
Constants.REPLY_CHANNEL_LABEL = {
  same = "Same channel",
  w    = "Whisper",
  g    = "Guild",
  s    = "Say",
  p    = "Party",
  i    = "Instance",
  r    = "Raid",
  e    = "Emote",
  cg   = "General",
  ct   = "Trade",
  cs   = "Services",
}

Constants.PLACEHOLDERS = {
  { key = "sender",  doc = "Sender character name (BattleTag for BNet whispers)." },
  { key = "trigger", doc = "The matched phrase, verbatim from your trigger list." },
  { key = "channel", doc = "Label of the channel the trigger fired in (Whisper, Party, Raid, ...)." },
  { key = "purr",    doc = "A random cat-flavored action — *purr*, *purrs*, or *purrs softly*." },
  { key = "name",    doc = "Your current character's name." },
}

-- Pool the {purr} placeholder picks from at fire time. Plain strings sent
-- inline with the reply, so authors can drop {purr} mid-sentence and have
-- a different flavor each fire.
Constants.PURR_PHRASES = {
  "*purr*",
  "*purrs*",
  "*purrs softly*",
}

Constants.FRIENDS_MODES = { "anyone", "friends", "strangers" }
Constants.FRIENDS_MODE_LABEL = {
  anyone    = "Anyone",
  friends   = "Friends only",
  strangers = "Strangers only",
}

Constants.DAY_OF_WEEK_ORDER = { 2, 3, 4, 5, 6, 7, 1 }
Constants.DAY_OF_WEEK_LABEL = {
  [1] = "Sunday",
  [2] = "Monday",
  [3] = "Tuesday",
  [4] = "Wednesday",
  [5] = "Thursday",
  [6] = "Friday",
  [7] = "Saturday",
}

-- Single source of truth for the form filter. `formIDs` are the values GetShapeshiftFormID()
Constants.DRUID_FORMS = {
  { key = "BEAR",     label = "Bear",     formIDs = { 5 } },
  { key = "CAT",      label = "Cat",      formIDs = { 1 } },
  { key = "TRAVEL",   label = "Travel",   formIDs = { 3, 27 } },
  { key = "MOONKIN",  label = "Moonkin",  formIDs = { 31 } },
  { key = "TREE",     label = "Tree",     formIDs = { 2, 36 } },
  { key = "STAG",     label = "Stag",     formIDs = { 29 } },
  { key = "HUMANOID", label = "Humanoid", formIDs = { 0 } },
}

-- Reverse lookup: form ID -> form key. Built once at file load.
Constants.DRUID_FORM_ID_TO_KEY = {}
for _, form in ipairs(Constants.DRUID_FORMS) do
  for _, id in ipairs(form.formIDs) do
    Constants.DRUID_FORM_ID_TO_KEY[id] = form.key
  end
end

-- Player status states the watcher can gate on. `key` is the stored token
-- (also drives the WoW API read in Filters.lua); `label` is the UI text.
Constants.PLAYER_STATES = {
  { key = "AFK", label = "AFK" },
  { key = "DND", label = "Do Not Disturb (DND)" },
  { key = "PVP", label = "PvP enabled" },
}

local function newFilterDefaults()
  return {
    zone = {
      enabled = false,
      mapIDs = {},
    },
    friends = {
      enabled = false,
      mode = "anyone",
    },
    timeOfDay = {
      enabled = false,
      startHour = 0,
      startMin = 0,
      endHour = 23,
      endMin = 59,
    },
    dayOfWeek = {
      enabled = false,
      days = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true },
    },
    druidForm = {
      enabled = false,
      forms = {},
    },
    playerState = {
      enabled = false,
      states = {}, -- map of PLAYER_STATES key -> true; fire only when in any selected state
    },
    cooldown = {
      enabled = false,
      seconds = 60, -- overrides SpamCooldown when on
    },
  }
end

Constants.NEW_FILTER_DEFAULTS = newFilterDefaults

-- Curated list of built-in WoW sound kit IDs that read well as a notification
-- cue. Stored as raw IDs so the same list works on Retail and Classic flavors
-- (the SOUNDKIT.* table differs across clients; numeric IDs are stable).
-- "(none)" is represented by storing nil / SOUND_NONE in the watcher's
-- notifications.sound field — the dropdown surfaces the sentinel so the
-- "no sound" choice is always selectable.
-- Notification sound catalogue. Each entry's `value` is what gets stored in
-- the watcher's notifications.sound field. The value's *type* discriminates
-- which API plays it back (see playNotificationSound in Watchers.lua):
--   number              -> PlaySound(value, "Master")        SoundKit ID
--   string "file:<id>"  -> PlaySoundFile(<id>, "Master")     FileDataID
--   other string        -> LSM:Fetch("sound", value) then PlaySoundFile path
-- SOUND_NONE = 0 is the "no sound" sentinel; treated as nil at runtime.
-- IDs verified against https://www.wowhead.com/sounds (URL form /sound=ID/...);
-- add new entries only after confirming the ID resolves to the right clip.
Constants.SOUND_NONE = 0

-- Icon notification defaults (per-watcher; in pixels and seconds).
-- Min/Max bound the sliders in the edit form and the Mover size slider.
Constants.ICON_DEFAULT_SIZE = 48
Constants.ICON_MIN_SIZE     = 10
Constants.ICON_MAX_SIZE     = 200
Constants.ICON_DEFAULT_FADE = 3
Constants.ICON_MIN_FADE     = 1
Constants.ICON_MAX_FADE     = 30
Constants.SOUNDS = {
  { value = 12867,         label = "Alarm Clock" },
  { value = 10030,         label = "Bloodlust" },
  { value = 1263,          label = "Human Male Aggro" },
  { value = 120,           label = "Loot Coin" },
  { value = "file:597860", label = "Meow" },
  { value = 416,           label = "Murloc Aggro" },
  { value = 7094,          label = "Peon: More work?" },
  { value = 6192,          label = "Peon: Ready to work" },
  { value = 7194,          label = "Peon Greetings" },
  { value = 8959,          label = "Raid Warning" },
  { value = 8960,          label = "Ready Check" },
  { value = 3081,          label = "Tell Message" },
}
-- Keep alphabetical by label so the dropdown order stays stable when we add
-- entries. (none) is injected at the top of the dropdown by the UI layer.
table.sort(Constants.SOUNDS, function(a, b) return a.label < b.label end)

function Constants.NEW_WATCHER_DEFAULTS()
  return {
    name = "",
    enabled = true,
    -- accountWide picks the storage bucket for this watcher. false (the
    -- default) means it lives in the active profile's Watchers list and
    -- only fires while the local character has that profile selected.
    -- true means it lives in the account-wide bucket and fires on every
    -- character. Toggleable from the Trigger config checkbox.
    accountWide = false,
    -- When true the watcher fires on every message in its ticked channels with
    -- no trigger phrase. Restricted to Constants.MATCH_ANY_CHANNELS at both the
    -- UI and dispatch layers so it can't be aimed at high-traffic channels.
    matchAny = false,
    triggers = {},
    -- Parallel to `triggers`: boolean per phrase. true means the phrase only
    -- matches when message casing matches exactly. nil/false = case-insensitive
    -- (the legacy / default behavior).
    triggerCaseSensitive = {},
    -- Parallel to `triggers`: boolean per phrase. true means the whole message
    -- (after trim) must equal the phrase; false/nil means whole-word substring
    -- match anywhere in the message — the historical default.
    triggerExact = {},
    -- Parallel to `triggers`: boolean per phrase. true means partial-match
    -- (plain substring contains, no word-boundary check), so "test" matches
    -- inside "testest". false/nil means whole-word. Mutually exclusive with
    -- triggerExact at the UI layer.
    triggerPartial = {},
    channels = {},
    onlyLead = false,
    reply = {
      -- Per-section master toggles. Same collapsible UX as the Notifications
      -- tab: each section is hidden by default; ticking the master reveals
      -- the controls; unticking clears the section's data so the reply
      -- pipeline naturally drops it at fire time.
      textEnabled    = false,
      emoteEnabled   = false,
      actionsEnabled = false,
      texts = {},
      ch = "same",
      emotes = {},
      emoteFirst = false,
      -- Parallel array to `emotes`: per-row boolean. When true for an
      -- emote, DoEmote is invoked without the sender target so it reads
      -- as a generic action ("/smile") instead of aimed at the speaker
      -- ("/smile Player"). Default empty — every emote starts targeted.
      emoteNonTargeted = {},
      invite = false,
      inviteConfirm = false,
      inviteQueue = true,
      guildInvite = false,
      kick = false,
    },
    notifications = {
      sound = Constants.SOUND_NONE,
      noReply = false,
      -- Per-section master toggles. Each section's controls are only visible
      -- (and only honored at fire time, by virtue of cleared data) when the
      -- corresponding flag is true. Unticking the master clears the section's
      -- data; ticking it re-opens an empty section the user can configure.
      soundEnabled    = false,
      iconEnabled     = false,
      coloringEnabled = false,
      -- Per-trigger chat coloring. Indexed alongside `triggers`. Each entry
      -- is one of: nil/"" (no coloring), "class" (use sender's class color),
      -- or a 6-digit lowercase hex RRGGBB (no "#" prefix, no alpha).
      triggerColors = {},
      -- Icon notification. fileID is a numeric FileDataID (or nil for "no
      -- icon"); position is the anchor tuple stored by MBLib.Movers. Size
      -- in pixels (square); fadeSeconds is the visible-hold duration.
      icon = {
        fileID      = nil,
        size        = Constants.ICON_DEFAULT_SIZE,
        fadeSeconds = Constants.ICON_DEFAULT_FADE,
        position    = nil, -- {point, relativePoint, xOfs, yOfs}; first Mover save populates this
      },
    },
    filters = newFilterDefaults(),
  }
end

addon.Constants = Constants
