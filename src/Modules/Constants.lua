local _, addon = ...

local Constants = {}

-- ===== Watch channels =====
-- Single source of truth for everything channel-related: the events Watchers
-- subscribes to, the labels rendered in the UI, and the chat type used when a
-- watcher replies in the same channel.
--
-- Each entry's table key is the *code-facing* name (Constants.CHANNELS.WHISPER)
-- — readable in source. The `key` field on each entry is the *storage-facing*
-- short code (one letter) that lives in SavedVariables under
-- watcher.channels[<key>]. Short codes keep the savedvariables file compact;
-- the named keys keep the code self-explanatory. CHANNEL_BY_KEY bridges the
-- two: when we receive a saved short code we resolve it to the full def.
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
}

-- Display / iteration order. ipairs yields full channel defs, so consumers
-- write `for _, def in ipairs(CHANNEL_ORDER) do ... def.label / def.key end`.
Constants.CHANNEL_ORDER = {
  Constants.CHANNELS.WHISPER,
  Constants.CHANNELS.BNET,
  Constants.CHANNELS.GUILD,
  Constants.CHANNELS.SAY,
  Constants.CHANNELS.EMOTE,
  Constants.CHANNELS.PARTY,
  Constants.CHANNELS.RAID,
  Constants.CHANNELS.INSTANCE,
}

-- Reverse lookup: short SavedVariables code -> full channel def. Use this when
-- you have a saved channelKey (e.g. from watcher.channels or an event map) and
-- need the def.
Constants.CHANNEL_BY_KEY = {}
for _, def in pairs(Constants.CHANNELS) do
  Constants.CHANNEL_BY_KEY[def.key] = def
end

-- ===== Reply channel options =====
-- "same" routes the reply via the channel the trigger fired in; the other codes
-- pin the reply to a specific channel regardless of trigger source. These reuse
-- the same short codes as Constants.CHANNELS.*.key for channels that can both
-- be watched and replied in.
Constants.REPLY_CHANNELS = { "same", "w", "g", "s", "p", "i", "r", "e" }
Constants.REPLY_CHANNEL_LABEL = {
  same = "Same channel",
  w    = "Whisper",
  g    = "Guild",
  s    = "Say",
  p    = "Party",
  i    = "Instance",
  r    = "Raid",
  e    = "Emote",
}

-- ===== Placeholders =====
-- Tokens of the form {key} that Helpers.applyPlaceholders substitutes into
-- reply text at fire time. The list is also the source of truth for the
-- placeholder-docs UI in WatchersPanel: add a new entry here and it shows up
-- as a clickable copy-paste row automatically.
Constants.PLACEHOLDERS = {
  { key = "sender",  doc = "Sender character name (BattleTag for BNet whispers)." },
  { key = "trigger", doc = "The matched phrase, verbatim from your trigger list." },
  { key = "channel", doc = "Label of the channel the trigger fired in (Whisper, Party, Raid, ...)." },
}

-- ===== New-watcher defaults =====
-- Returns a fresh table each call so callers can mutate freely without
-- bleeding into other in-flight edits.
function Constants.NEW_WATCHER_DEFAULTS()
  return {
    name = "",
    enabled = true,
    triggers = {},
    exact = false,
    channels = {},
    onlyLead = false,
    reply = {
      text = "",
      ch = "same",
      emote = nil,
      emoteFirst = false,
      invite = false,
      inviteConfirm = false,
      inviteQueue = true,
      kick = false,
    },
  }
end

addon.Constants = Constants
