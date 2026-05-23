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
}

Constants.CHANNEL_BY_KEY = {}
for _, def in pairs(Constants.CHANNELS) do
  Constants.CHANNEL_BY_KEY[def.key] = def
end

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

Constants.PLACEHOLDERS = {
  { key = "sender",  doc = "Sender character name (BattleTag for BNet whispers)." },
  { key = "trigger", doc = "The matched phrase, verbatim from your trigger list." },
  { key = "channel", doc = "Label of the channel the trigger fired in (Whisper, Party, Raid, ...)." },
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
    cooldown = {
      enabled = false,
      seconds = 60, -- overrides SpamCooldown when on
    },
  }
end

Constants.NEW_FILTER_DEFAULTS = newFilterDefaults

function Constants.NEW_WATCHER_DEFAULTS()
  return {
    name = "",
    enabled = true,
    triggers = {},
    exact = false,
    channels = {},
    onlyLead = false,
    reply = {
      texts = {},
      ch = "same",
      emotes = {},
      emoteFirst = false,
      invite = false,
      inviteConfirm = false,
      inviteQueue = true,
      kick = false,
    },
    filters = newFilterDefaults(),
  }
end

addon.Constants = Constants
