local _, addon = ...

local Debug = {}

local function makeLabel(parent, text, fontObj)
  local fs = parent:CreateFontString(nil, "ARTWORK", fontObj or "GameFontNormal")
  fs:SetText(text)
  return fs
end

local function makeButton(parent, label, width, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width or 110, 22)
  b:SetText(label)
  if onClick then b:SetScript("OnClick", onClick) end
  return b
end

local function makeEdit(parent, width)
  local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  eb:SetSize(width, 22)
  eb:SetAutoFocus(false)
  eb:SetFontObject(ChatFontNormal)
  eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  eb:SetScript("OnEnterPressed",  function(self) self:ClearFocus() end)
  return eb
end

local function makeDropdown(parent, width, options, onSelect, getCurrent)
  local dd = CreateFrame("DropdownButton", nil, parent, "WowStyle1DropdownTemplate")
  dd:SetWidth(width)
  local function labelFor(value)
    for _, opt in ipairs(options) do
      if opt.value == value then return opt.label or tostring(opt.value) end
    end
    return ""
  end
  dd:SetDefaultText(labelFor(getCurrent and getCurrent()))
  dd:SetupMenu(function(_, root)
    for _, opt in ipairs(options) do
      local v = opt.value
      root:CreateRadio(opt.label or tostring(v),
        function() return getCurrent and getCurrent() == v end,
        function()
          if onSelect then onSelect(v) end
          if dd.OverrideText then dd:OverrideText(labelFor(v)) end
        end, v)
    end
  end)
  function dd:Sync()
    if self.OverrideText then self:OverrideText(labelFor(getCurrent and getCurrent())) end
  end
  return dd
end

local function dbReady()
  return addon.MBLib and addon.MBLib._db
end

function Debug:IsEnabled()
  if not dbReady() then return false end
  return addon.MBLib._db.DebugMode == true
end

function Debug:SetEnabled(on)
  if not dbReady() then return end
  addon.MBLib._db.DebugMode = on and true or false
  -- Mirror into MBLib so opt-modules that gate on debug (the icon
  -- picker's auto-dump pipeline, for instance) self-toggle without
  -- needing to register a callback.
  if addon.MBLib.SetDebugEnabled then
    addon.MBLib:SetDebugEnabled(on)
  end
end

local DATE_PRESETS = {
  { value = "real",      label = "Real (system date)" },
  { value = "april1",    label = "April 1 (April Fool's)" },
  { value = "catday",    label = "August 8 (Cat Day)" },
  { value = "pirate",    label = "September 19 (Pirate Day)" },
  { value = "halloween", label = "October 31 (Halloween)" },
}

local DATE_BUILDERS = {
  april1    = function() return { year = 2026, month = 4,  day = 1 } end,
  catday    = function() return { year = 2026, month = 8,  day = 8 } end,
  pirate    = function() return { year = 2026, month = 9,  day = 19 } end,
  halloween = function() return { year = 2026, month = 10, day = 31 } end,
}

local realGetNow = nil -- captured on first override
local currentDatePreset = "real"

local function applyDateOverride(preset)
  if not addon.Hooks then return end
  if preset == "real" or not DATE_BUILDERS[preset] then
    if realGetNow then addon.Hooks.GetNow = realGetNow end
    currentDatePreset = "real"
    return
  end
  if not realGetNow then realGetNow = addon.Hooks.GetNow end
  local builder = DATE_BUILDERS[preset]
  addon.Hooks.GetNow = function() return builder() end
  currentDatePreset = preset
end

local resetPopup

local function buildResetPopup()
  local f = CreateFrame("Frame", "Meower_DebugResetPopup", UIParent, "BackdropTemplate")
  f:SetSize(360, 130)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetToplevel(true)
  f:EnableMouse(true)
  f:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })
  f:Hide()

  local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -18)
  title:SetText("Reset all Meower data?")

  local body = f:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  body:SetPoint("TOPLEFT", 20, -48)
  body:SetPoint("TOPRIGHT", -20, -48)
  body:SetJustifyH("CENTER")
  body:SetText("Wipes every watcher and setting. There is no undo.")

  local cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  cancelBtn:SetSize(110, 22)
  cancelBtn:SetPoint("BOTTOMLEFT", f, "BOTTOM", -8, 16)
  cancelBtn:SetText(CANCEL or "Cancel")
  cancelBtn:SetScript("OnClick", function() f:Hide() end)

  local confirmBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  confirmBtn:SetSize(110, 22)
  confirmBtn:SetPoint("BOTTOMRIGHT", f, "BOTTOM", 8, 16)
  confirmBtn:SetText("Reset")
  confirmBtn:SetScript("OnClick", function()
    local name = (addon.MBLib and addon.MBLib._addonName) or "Meower"
    _G[name .. "Data"] = {}
    if addon.MBLib then addon.MBLib._db = _G[name .. "Data"] end
    f:Hide()
    print("|cffff8000Meower|r: SavedVariables cleared. /reload to rebuild defaults.")
  end)

  return f
end

local function showResetPopup()
  resetPopup = resetPopup or buildResetPopup()
  resetPopup:Show()
end

local function buildDebugPanel()
  local panel = CreateFrame("Frame")
  panel:Hide()

  local title = makeLabel(panel, "Meower Debug", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 20, -20)

  local desc = makeLabel(panel,
    "Developer tools. Visible only when debug mode is on (/mw debug on). "
    .. "These widgets bypass the chat-event filters and write directly to "
    .. "internal state — not for general use.",
    "GameFontHighlight")
  desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
  desc:SetWidth(640)
  desc:SetJustifyH("LEFT")

  -- === Simulate chat ===
  local simHeader = makeLabel(panel, "Simulate incoming chat", "GameFontNormalLarge")
  simHeader:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -24)

  local channelOpts = {}
  if addon.Constants and addon.Constants.CHANNEL_ORDER then
    for _, def in ipairs(addon.Constants.CHANNEL_ORDER) do
      table.insert(channelOpts, { value = def.key, label = def.label })
    end
  end
  local simChannel = "w"
  local channelDD = makeDropdown(panel, 160, channelOpts,
    function(v) simChannel = v end,
    function() return simChannel end)
  channelDD:SetPoint("TOPLEFT", simHeader, "BOTTOMLEFT", 0, -8)

  local senderLabel = makeLabel(panel, "Sender")
  senderLabel:SetPoint("LEFT", channelDD, "RIGHT", 12, 0)
  local senderInput = makeEdit(panel, 140)
  senderInput:SetPoint("LEFT", senderLabel, "RIGHT", 8, 0)
  senderInput:SetText("Tester-TestRealm")

  local msgLabel = makeLabel(panel, "Message")
  msgLabel:SetPoint("TOPLEFT", channelDD, "BOTTOMLEFT", 0, -14)
  local msgInput = makeEdit(panel, 360)
  msgInput:SetPoint("LEFT", msgLabel, "RIGHT", 8, 0)

  local fireSimBtn = makeButton(panel, "Fire", 80, function()
    if not addon.Watchers or not addon.Watchers.ProcessMessage then return end
    addon.Watchers:ProcessMessage(simChannel,
      senderInput:GetText() or "",
      msgInput:GetText() or "",
      nil)
  end)
  fireSimBtn:SetPoint("LEFT", msgInput, "RIGHT", 10, 0)

  local forceHeader = makeLabel(panel, "Force-fire a watcher", "GameFontNormalLarge")
  forceHeader:SetPoint("TOPLEFT", msgLabel, "BOTTOMLEFT", 0, -24)

  local forceWatcherId
  local watcherDD
  local function watcherOpts()
    local opts = {}
    if addon.Watchers and addon.Watchers.GetAll then
      for _, w in ipairs(addon.Watchers:GetAll()) do
        local name = (w.name and w.name ~= "") and w.name or ("(id " .. tostring(w.id) .. ")")
        table.insert(opts, { value = w.id, label = name })
      end
    end
    return opts
  end
  watcherDD = makeDropdown(panel, 220, watcherOpts(),
    function(v) forceWatcherId = v end,
    function() return forceWatcherId end)
  watcherDD:SetPoint("TOPLEFT", forceHeader, "BOTTOMLEFT", 0, -8)

  local refreshBtn = makeButton(panel, "Refresh list", 110, function()
    -- Rebuild the dropdown options after the user has added/removed watchers.
    local opts = watcherOpts()
    watcherDD:SetupMenu(function(_, root)
      for _, opt in ipairs(opts) do
        local v = opt.value
        root:CreateRadio(opt.label,
          function() return forceWatcherId == v end,
          function() forceWatcherId = v end, v)
      end
    end)
  end)
  refreshBtn:SetPoint("LEFT", watcherDD, "RIGHT", 10, 0)

  local fireForceBtn = makeButton(panel, "Fire", 80, function()
    if not addon.Watchers or not forceWatcherId then return end
    addon.Watchers:ForceFire(forceWatcherId, "w", UnitName("player") or "Tester")
  end)
  fireForceBtn:SetPoint("LEFT", refreshBtn, "RIGHT", 6, 0)

  -- === Date override ===
  local dateHeader = makeLabel(panel, "Date override (for seasonal Extras)", "GameFontNormalLarge")
  dateHeader:SetPoint("TOPLEFT", forceHeader, "BOTTOMLEFT", 0, -56)

  local dateDD = makeDropdown(panel, 260, DATE_PRESETS,
    function(v) applyDateOverride(v) end,
    function() return currentDatePreset end)
  dateDD:SetPoint("TOPLEFT", dateHeader, "BOTTOMLEFT", 0, -8)

  -- === SavedVariables tools ===
  local svHeader = makeLabel(panel, "SavedVariables", "GameFontNormalLarge")
  svHeader:SetPoint("TOPLEFT", dateHeader, "BOTTOMLEFT", 0, -56)

  local dumpBtn = makeButton(panel, "Dump to chat", 130, function()
    local name = (addon.MBLib and addon.MBLib._addonName) or "Meower"
    local db = _G[name .. "Data"]
    if type(db) ~= "table" then print("|cffff8000Meower|r: no SavedVariables yet."); return end
    local function dump(t, indent)
      indent = indent or ""
      for k, v in pairs(t) do
        if type(v) == "table" then
          print(indent .. tostring(k) .. " = {")
          dump(v, indent .. "  ")
          print(indent .. "}")
        else
          print(indent .. tostring(k) .. " = " .. tostring(v))
        end
      end
    end
    print("|cffff8000Meower|r SavedVariables:")
    dump(db, "  ")
  end)
  dumpBtn:SetPoint("TOPLEFT", svHeader, "BOTTOMLEFT", 0, -8)

  local resetBtn = makeButton(panel, "Reset all data...", 140, showResetPopup)
  resetBtn:SetPoint("LEFT", dumpBtn, "RIGHT", 8, 0)

  return panel
end

local function registerSubcategory()
  if Debug._subcategoryRegistered then return end
  if not (Settings and Settings.RegisterCanvasLayoutSubcategory) then return end
  if not (addon.MBLib and addon.MBLib._optionsCategory) then return end

  local panel = buildDebugPanel()
  Settings.RegisterCanvasLayoutSubcategory(addon.MBLib._optionsCategory, panel, "Debug")
  Debug._subcategoryRegistered = true
end

local function slashHandler(arg)
  arg = (arg or ""):lower():match("^%s*(.-)%s*$") or ""
  local was = Debug:IsEnabled()
  local target
  if arg == "" or arg == "toggle" then
    target = not was
  elseif arg == "on" or arg == "1" or arg == "true" then
    target = true
  elseif arg == "off" or arg == "0" or arg == "false" then
    target = false
  else
    return false -- triggers /mw debug usage hint
  end
  Debug:SetEnabled(target)
  if target == was then
    print("|cffff8000Meower|r: debug mode already " .. (target and "on" or "off") .. ".")
  else
    print("|cffff8000Meower|r: debug mode " .. (target and "enabled" or "disabled")
      .. ". /reload to apply (the Debug page is added/removed at addon load).")
  end
  return true
end

function Debug:Init()
  if self._initialized then return end
  self._initialized = true

  if addon.MBLib and addon.MBLib.Commands and addon.MBLib.Commands.Add then
    addon.MBLib.Commands:Add("debug", {
      desc = "Toggle debug mode. Adds a Debug page in Settings (requires /reload after toggling).",
      func = slashHandler,
    })
  end

  -- Sync the initial debug state into MBLib. Opt-modules that gate on
  -- it (IconPicker's auto-dump, for instance) read MBLib:IsDebugEnabled
  -- and handle themselves — no per-consumer plumbing.
  if addon.MBLib and addon.MBLib.SetDebugEnabled then
    addon.MBLib:SetDebugEnabled(self:IsEnabled())
  end

  if self:IsEnabled() then
    registerSubcategory()
  end
end

addon.Debug = Debug
