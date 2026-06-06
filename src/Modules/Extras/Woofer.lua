local _, addon = ...
local L = addon.L

-- Conditional post-reply text rewrites. Registered as a single callback on
-- the ReplyTransforms hook; date source goes through addon.Hooks.GetNow.

local Woofer = {}

local OPT_KEY   = "WooferEnabled"
local USER_FLAG = "WooferActive"

local function optedIn()
  if not (addon.MBLib and addon.MBLib.Settings) then return true end
  local v = addon.MBLib.Settings:Get(OPT_KEY)
  if v == nil then return true end
  return v and true or false
end

local function userFlagSet()
  if not (addon.MBLib and addon.MBLib.Settings) then return false end
  return addon.MBLib.Settings:Get(USER_FLAG) and true or false
end

local function ctxNow()
  local ok, t = pcall(addon.Hooks.GetNow)
  if ok and type(t) == "table" then return t end
  return date("*t")
end

local WORD = "(%w[%w']*)"

local function carryCase(src, dst)
  if src == "" or dst == "" then return dst end
  if src == src:upper() and src ~= src:lower() then return dst:upper() end
  local h = src:sub(1, 1)
  if h == h:upper() and h ~= h:lower() then
    return dst:sub(1, 1):upper() .. dst:sub(2):lower()
  end
  return dst:lower()
end

local P_A = {
  "*creak*", "boo!", "mwahaha~", "*shiver*", "*ooo~*", "*cackle*",
}

local P_B = {
  "meow", "mew", "mreow", "mrrp", "prrrt", "mrow", "nya", "mrrrrow",
}

local function _strv(word)
  local positions = {}
  for i = 1, #word do
    local ch = word:sub(i, i):lower()
    if ch == "a" or ch == "e" or ch == "i" or ch == "o" or ch == "u" then
      positions[#positions + 1] = i
    end
  end
  if #positions == 0 then return word end
  local pos = positions[math.random(1, #positions)]
  local v = word:sub(pos, pos)
  return word:sub(1, pos - 1) .. v:rep(math.random(3, 6)) .. word:sub(pos + 1)
end

local P_B_TAIL = { "~", "-purr", "-purrr", "-purrrr" }

local function _build_b()
  local w = P_B[math.random(1, #P_B)]
  if math.random() < 0.30 then w = _strv(w) end
  if math.random() < 0.18 then
    w = w .. "-" .. P_B[math.random(1, #P_B)]
  end
  if math.random() < 0.13 then
    w = w .. P_B_TAIL[math.random(1, #P_B_TAIL)]
  end
  return w
end

local P_C = {
  ["you"] = "ye", ["your"] = "yer", ["yours"] = "yers",
  ["is"] = "be", ["are"] = "be", ["am"] = "be",
  ["my"] = "me", ["yes"] = "aye", ["no"] = "nay", ["the"] = "th'",
  ["hello"] = "ahoy", ["hi"] = "ahoy",
  ["friend"] = "matey", ["friends"] = "mateys",
  ["there"] = "yonder", ["here"] = "hither",
  ["left"] = "port", ["right"] = "starboard",
  ["front"] = "bow", ["back"] = "aft", ["behind"] = "astern",
  ["everywhere"] = "from stem to stern",
  ["man"] = "lad", ["guy"] = "lad", ["dude"] = "lad",
  ["woman"] = "lass", ["girl"] = "wench",
  ["boss"] = "captain", ["leader"] = "skipper",
  ["enemy"] = "scallywag", ["enemies"] = "scallywags",
  ["sailor"] = "sea dog", ["crew"] = "hands",
  ["person"] = "landlubber",
  ["stop"] = "avast", ["look"] = "spy", ["see"] = "behold",
  ["listen"] = "hark", ["throw"] = "heave", ["toss"] = "heave",
  ["leave"] = "scurry", ["steal"] = "plunder", ["take"] = "pillage",
  ["cheat"] = "hornswoggle", ["trick"] = "hornswoggle",
  ["hurry"] = "smartly",
  ["money"] = "doubloons", ["cash"] = "booty",
  ["food"] = "grub", ["snack"] = "rations", ["snacks"] = "grub",
  ["cookie"] = "hardtack", ["cookies"] = "hardtack",
  ["drink"] = "grog", ["alcohol"] = "rum",
  ["clothes"] = "garbs",
}

local P_C_X = {
  { "over there", "yonder" },
  { "go away", "walk the plank" },
}

local P_C_E = {
  ["ever"] = "e'er", ["never"] = "ne'er", ["over"] = "o'er",
  ["however"] = "howe'er", ["whenever"] = "whene'er",
  ["whatever"] = "whate'er",
}

local P_C_TAIL = { "arr!", "yarrr!", "**Hic!**", "blimey!", "shiver me timbers!" }

local function _cisub(s, needle, repl)
  if s == "" or needle == "" then return s end
  local lowerN = needle:lower()
  local nlen = #needle
  local out, i = {}, 1
  while i <= #s do
    local pos = s:lower():find(lowerN, i, true)
    if not pos then
      out[#out + 1] = s:sub(i)
      break
    end
    out[#out + 1] = s:sub(i, pos - 1)
    out[#out + 1] = carryCase(s:sub(pos, pos + nlen - 1), repl)
    i = pos + nlen
  end
  return table.concat(out)
end

local function _build_c(w)
  local lower = w:lower()
  local hit = P_C[lower]
  if hit then return carryCase(w, hit) end
  local el = P_C_E[lower]
  if el then return carryCase(w, el) end
  if #lower >= 6 and lower:sub(-3) == "ing" then
    return w:sub(1, -2) .. "'"
  end
  return w
end

Woofer.rules = {
  {
    when = function(t) return t.month == 4 and t.day == 1 end,
    apply = function(s) return string.reverse(s) end,
  },
  {
    when = function(t) return t.month == 8 and t.day == 8 end,
    apply = function(s)
      return (s:gsub(WORD, function(w)
        return carryCase(w, _build_b())
      end))
    end,
  },
  {
    when = function(t) return t.month == 9 and t.day == 19 end,
    apply = function(s)
      local out = s
      for _, pair in ipairs(P_C_X) do
        out = _cisub(out, pair[1], pair[2])
      end
      out = out:gsub(WORD, _build_c)
      if math.random() < 0.30 then
        out = out .. " " .. P_C_TAIL[math.random(1, #P_C_TAIL)]
      end
      return out
    end,
  },
  {
    when = function(t) return t.month == 10 and t.day == 31 end,
    apply = function(s)
      if math.random() > 0.35 then return s end
      local frag = P_A[math.random(1, #P_A)]
      if math.random() < 0.5 then return frag .. " " .. s end
      return s .. " " .. frag
    end,
  },
}

function Woofer:HasActiveRule()
  local t = ctxNow()
  for _, r in ipairs(self.rules) do
    if r.when(t) then return true end
  end
  return false
end

local function run(text, ctx)
  if not optedIn() then return text end
  if userFlagSet() then return text end
  if type(text) ~= "string" or text == "" then return text end
  local t = ctxNow()
  local out = text
  for _, r in ipairs(Woofer.rules) do
    if r.when(t) then
      local ok, res = pcall(r.apply, out, ctx)
      if ok and type(res) == "string" then out = res end
    end
  end
  return out
end

function Woofer:Register()
  if self._registered then return end
  self._registered = true
  addon.Hooks:Register("ReplyTransforms", run)
end

function Woofer:RegisterSettings()
  if not (addon.MBLib and addon.MBLib.Settings) then return end
  if not self:HasActiveRule() then return end
  addon.MBLib.Settings:Add({
    {
      Key = USER_FLAG,
      Name = L.SETTINGS_HIDE_FLAIR_NAME,
      Description = L.SETTINGS_HIDE_FLAIR_DESC,
      Group = L.SETTINGS_GROUP_DISPLAY,
      Type = "checkbox",
      Default = false,
    },
  })
end

addon.Extras = addon.Extras or {}
addon.Extras.Woofer = Woofer
