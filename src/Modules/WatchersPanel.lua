local _, addon = ...

local Constants = addon.Constants
local MBLib = addon.MBLib

local Panel = {}

local CONTENT_WIDTH = 660
local INNER_WIDTH = 560 -- usable width inside the form padding
local TOP_BAR_HEIGHT = 64
local INPUT_HEIGHT = 24
local LEFT_MARGIN = 16 -- consistent left edge for form content
local SUB_INDENT = "  " -- visual indent for sub-lines in list rows

local COLOR_NAME = { r = 1.0,  g = 0.82, b = 0.0  }
local COLOR_SOFT = { r = 0.7,  g = 0.7,  b = 0.7  }
local COLOR_HEADING = { r = 1.0,  g = 0.82, b = 0.0  }
local COLOR_ERROR = { r = 1.0,  g = 0.30, b = 0.30 }

local function colored(text, color)
  if MBLib.Utils and MBLib.Utils.GetTextWithColor then
    return MBLib.Utils:GetTextWithColor(text, color)
  end
  return text
end

local function deepCopy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = deepCopy(v) end
  return out
end

-- Live chat color for a channel def, sourced from Blizzard's global
-- ChatTypeInfo table (keyed by replyChatType: "SAY", "WHISPER", "GUILD", ...).
-- ChatTypeInfo is mutated in place by the Chat options screen, so reading it
-- each render gives the user's current customizations for free. Returns nil
-- when no entry exists (e.g. early load) so callers can fall back gracefully.
local function chatColorFor(def)
  if not def or not def.replyChatType then return nil end
  local c = _G.ChatTypeInfo and _G.ChatTypeInfo[def.replyChatType]
  if not c then return nil end
  return { r = c.r or 1, g = c.g or 1, b = c.b or 1 }
end

local function channelColored(def)
  if not def then return "" end
  local c = chatColorFor(def)
  if c then return colored(def.label, c) end
  return def.label
end

-- Coloring for reply-channel short codes (Constants.REPLY_CHANNELS). These
-- overlap the watch-channel keys for normal chat channels and add the
-- synthetic "same" code, which routes the reply via the trigger source.
-- "same" renders in soft grey so it reads as a metadata/control choice; the
-- rest pick up their live chat color from ChatTypeInfo.
local function replyChannelColored(code)
  local label = Constants.REPLY_CHANNEL_LABEL[code] or tostring(code)
  if code == "same" then
    return colored(label, COLOR_SOFT)
  end
  local def = Constants.CHANNEL_BY_KEY[code]
  if def then
    local c = chatColorFor(def)
    if c then return colored(label, c) end
  end
  return label
end

-- ===== Modern widget primitives =====
-- The codebase standard (set by MBLib.CustomOptionsScreen) is UICheckButtonTemplate
-- for checkboxes and WowStyle1DropdownTemplate for dropdowns. Use those everywhere
-- so this panel matches MBLib's own settings screens visually.

local function makeCheckbox(parent, label)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  if cb.text then
    cb.text:SetText(label)
    cb.text:SetFontObject("GameFontHighlight")
  end
  return cb
end

local function makeLabel(parent, text, fontObject)
  local fs = parent:CreateFontString(nil, "ARTWORK", fontObject or "GameFontNormal")
  fs:SetText(text)
  return fs
end

local function makeMutedLabel(parent, text)
  local fs = makeLabel(parent, text, "GameFontHighlightSmall")
  fs:SetTextColor(COLOR_SOFT.r, COLOR_SOFT.g, COLOR_SOFT.b)
  return fs
end

-- Anchors a small grey "- description text" FontString inline to the right
-- of a checkbox's label, wrapping to the panel's right edge if it overflows.
-- The caller is responsible for spacing the next sibling row far enough below
-- the checkbox to absorb 1-2 lines of wrap; 3+ line descriptions may bleed
-- past the row gap.
local function inlineDesc(content, cb, text)
  if not cb or not cb.text then return nil end
  local desc = makeMutedLabel(content, "- " .. text)
  desc:SetPoint("TOPLEFT", cb.text, "TOPRIGHT", 6, 0)
  desc:SetPoint("RIGHT",   content, "RIGHT", -10, 0)
  desc:SetJustifyH("LEFT")
  desc:SetJustifyV("TOP")
  return desc
end

local function makeHeader(parent, text)
  local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  fs:SetText(text)
  fs:SetTextColor(COLOR_HEADING.r, COLOR_HEADING.g, COLOR_HEADING.b)
  return fs
end

-- Attaches a hover tooltip to a frame. Title renders white; the optional
-- description renders below it with word-wrap. Mirrors the GameTooltip
-- pattern used by MBLib's OptionsScreen so the look matches the rest of
-- the addon's chrome.
local function setTooltip(frame, title, desc)
  if not frame then return end
  frame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(title or "", 1, 1, 1)
    if desc and desc ~= "" then
      GameTooltip:AddLine(desc, nil, nil, nil, true)
    end
    GameTooltip:Show()
  end)
  frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

local function makeInput(parent, width)
  local eb = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  eb:SetSize(width, INPUT_HEIGHT)
  eb:SetAutoFocus(false)
  eb:SetFontObject(ChatFontNormal)
  eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  return eb
end

-- Full-width 1px horizontal rule anchored to the *content* frame so it truly
-- spans the form regardless of the width of the element above. `belowAnchor`
-- only drives the vertical position.
local function makeFullSeparator(content, belowAnchor, yOffset)
  local sep = content:CreateTexture(nil, "ARTWORK")
  sep:SetHeight(1)
  sep:SetPoint("LEFT",  content, "LEFT",  10, 0)
  sep:SetPoint("RIGHT", content, "RIGHT", -10, 0)
  sep:SetPoint("TOP",   belowAnchor, "BOTTOM", 0, yOffset or -10)
  sep:SetColorTexture(1, 1, 1, 0.25)
  return sep
end

-- WowStyle1 dropdown. options = { { value=..., label=... } } (label optional;
-- defaults to value). onSelect(value) fires after the user picks a row.
-- getCurrent() returns the current value (drives the radio bullet on the
-- selected row and the button text).
--
-- Menu rows use CreateRadio so the selected entry shows a filled radio dot
-- on the left. Labels keep their natural color (e.g. per-channel chat color)
-- on every row, including the selected one — selection is indicated only by
-- the bullet, not by overriding the text color.
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

  dd:SetupMenu(function(_, rootDescription)
    -- Cap menu height so long lists (the emote dropdown has 250+ entries)
    -- get a scrollbar instead of overflowing past the screen. Short menus
    -- render below this cap unchanged.
    if rootDescription.SetScrollMode then
      rootDescription:SetScrollMode(10 * 20)
    end
    for _, opt in ipairs(options) do
      local value = opt.value
      local function isSelected() return getCurrent and getCurrent() == value end
      local function setSelected()
        if onSelect then onSelect(value) end
        if dd.GenerateMenu then dd:GenerateMenu() end
        if dd.OverrideText then dd:OverrideText(labelFor(value)) end
      end
      rootDescription:CreateRadio(opt.label or tostring(value), isSelected, setSelected, value)
    end
  end)

  function dd:SyncLabel()
    local v = getCurrent and getCurrent()
    local label = labelFor(v)
    if self.OverrideText then self:OverrideText(label) end
    if self.GenerateMenu then self:GenerateMenu() end
  end

  return dd
end

-- ===== Placeholder copy popup =====
-- Custom (addon-owned) popup frame instead of Blizzard's StaticPopup. The
-- StaticPopup framework pools StaticPopup1..N across all addons AND
-- Blizzard's own confirmation dialogs (AcceptSpellConfirmationPrompt,
-- duel/trade prompts, etc.). Mutating the pooled frame's editBox here
-- (SetText / HighlightText / SetFocus) taints that slot; the next time
-- Blizzard reuses it for a protected confirmation, the secure call gets
-- blocked with ADDON_ACTION_FORBIDDEN blaming Meower. Owning our own
-- frame avoids the shared pool entirely.

local placeholderPopup

local function buildPlaceholderPopup()
  local f = CreateFrame("Frame", "Meower_PlaceholderPopup", UIParent, "BackdropTemplate")
  f:SetSize(300, 120)
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

  local title = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  title:SetPoint("TOP", 0, -16)
  title:SetText("Copy placeholder (Ctrl+C):")

  local editBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  editBox:SetSize(220, 24)
  editBox:SetPoint("TOP", title, "BOTTOM", 0, -16)
  editBox:SetAutoFocus(false)
  editBox:SetFontObject(ChatFontNormal)
  editBox:SetScript("OnEnterPressed",  function() f:Hide() end)
  editBox:SetScript("OnEscapePressed", function() f:Hide() end)
  f.editBox = editBox

  local closeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  closeBtn:SetSize(96, 22)
  closeBtn:SetPoint("BOTTOM", 0, 14)
  closeBtn:SetText(CLOSE or "Close")
  closeBtn:SetScript("OnClick", function() f:Hide() end)

  return f
end

local function showPlaceholderPopup(token)
  placeholderPopup = placeholderPopup or buildPlaceholderPopup()
  placeholderPopup:Show()
  placeholderPopup.editBox:SetText(token or "")
  placeholderPopup.editBox:HighlightText()
  placeholderPopup.editBox:SetFocus()
end

-- Builds a clickable placeholder-doc row. Clicking opens the copy popup with
-- the matching {key} token. Hover lightens the text so the row reads as
-- interactive.
local function makePlaceholderRow(parent, prevAnchor, ph)
  local row = CreateFrame("Button", nil, parent)
  row:SetSize(INNER_WIDTH, 16)
  row:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", 0, -2)

  local text = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  text:SetPoint("TOPLEFT",  row, "TOPLEFT",  0, 0)
  text:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
  text:SetJustifyH("LEFT")
  text:SetJustifyV("TOP")
  text:SetTextColor(COLOR_SOFT.r, COLOR_SOFT.g, COLOR_SOFT.b)
  text:SetText(" • " .. colored("{" .. ph.key .. "}", COLOR_HEADING) .. "  " .. ph.doc)
  row.text = text

  row:RegisterForClicks("LeftButtonUp")
  row:SetScript("OnClick", function()
    showPlaceholderPopup("{" .. ph.key .. "}")
  end)
  row:SetScript("OnEnter", function() text:SetTextColor(1, 1, 1) end)
  row:SetScript("OnLeave", function() text:SetTextColor(COLOR_SOFT.r, COLOR_SOFT.g, COLOR_SOFT.b) end)

  return row
end

-- ===== Edit-form state =====
Panel.state = nil
Panel.view  = "list"
Panel._listRows = {}

-- Forward decls
local refreshList
local refreshEditForm
local enterEdit
local exitEdit

-- ===== Status text (top-bar) =====
-- Doubles as error (red) and as a disabled-save hint (gray).
local function setStatus(f, text, isError)
  if not f or not f.errorText then return end
  f.errorText:SetText(text or "")
  local c = isError and COLOR_ERROR or COLOR_SOFT
  f.errorText:SetTextColor(c.r, c.g, c.b)
end

-- ===== List view =====

local function releaseListRows()
  for _, row in ipairs(Panel._listRows) do row:Hide() row:SetParent(nil) end
  Panel._listRows = {}
end

-- Returns a list of pre-formatted lines describing this watcher for the list
-- view. Indented lines use SUB_INDENT to show grouping (Channels under Trigger,
-- In/Emote/Actions under Reply). A blank-ish line separates the trigger group
-- from the reply group. When only actions are configured (no text/emote), the
-- Actions line sits at the top level — there is nothing to nest it under.
local function describeWatcher(w)
  local lines = {}

  -- Field labels render yellow so they stand out from the value text.
  local function labelled(label, value)
    return colored(label .. ":", COLOR_HEADING) .. " " .. value
  end

  -- Triggers join on one line using a yellow "•" with double spaces on each
  -- side as a visually distinct separator (commas would be ambiguous since
  -- phrases can contain them). The FontString wraps to additional lines if
  -- the join overflows the row's info width.
  local triggerList  = w.triggers or {}
  local triggerLabel = w.exact and "Trigger (exact)" or "Trigger"
  if #triggerList == 0 then
    table.insert(lines, labelled(triggerLabel, "-"))
  else
    local sep = "  " .. colored("•", COLOR_HEADING) .. "  "
    table.insert(lines, labelled(triggerLabel, table.concat(triggerList, sep)))
  end

  -- Channel labels: each rendered in the live chat color (sourced from
  -- ChatTypeInfo so Chat-options customizations apply automatically). Guild
  -- is overridden to grey when the player isn't currently in a guild, since
  -- the channel won't fire until they join one.
  local channelLabels = {}
  local inGuild = IsInGuild()
  for _, def in ipairs(Constants.CHANNEL_ORDER) do
    if w.channels and w.channels[def.key] then
      local label
      if def == Constants.CHANNELS.GUILD and not inGuild then
        label = colored(def.label, COLOR_SOFT)
      else
        label = channelColored(def)
      end
      table.insert(channelLabels, label)
    end
  end
  local channels = #channelLabels > 0 and table.concat(channelLabels, ", ") or "-"
  table.insert(lines, SUB_INDENT .. labelled("Channels", channels))

  -- Visual gap between trigger group and reply group. A single space keeps the
  -- FontString from collapsing the blank line.
  table.insert(lines, " ")

  local replyText  = (w.reply and w.reply.text)  or ""
  local replyEmote = (w.reply and w.reply.emote) or ""
  local hasText    = replyText  ~= ""
  local hasEmote   = replyEmote ~= ""

  local actionList = {}
  if w.reply and w.reply.invite then table.insert(actionList, "invite") end
  if w.reply and w.reply.kick   then table.insert(actionList, "kick")   end
  local hasActions = #actionList > 0

  if hasText then
    table.insert(lines, labelled("Reply", replyText))
    local chKey = (w.reply and w.reply.ch) or "same"
    table.insert(lines, SUB_INDENT .. labelled("In", replyChannelColored(chKey)))
    if hasEmote   then table.insert(lines, SUB_INDENT .. labelled("Emote",   replyEmote)) end
    if hasActions then table.insert(lines, SUB_INDENT .. labelled("Actions", table.concat(actionList, ", "))) end
  elseif hasEmote then
    table.insert(lines, labelled("Reply emote", replyEmote))
    if hasActions then table.insert(lines, SUB_INDENT .. labelled("Actions", table.concat(actionList, ", "))) end
  elseif hasActions then
    table.insert(lines, labelled("Actions", table.concat(actionList, ", ")))
  else
    table.insert(lines, labelled("Reply", "-"))
  end

  return lines
end

-- Crude per-line height estimate for GameFontHighlightSmall with SetSpacing(2).
local LIST_LINE_HEIGHT      = 14
local LIST_HEADER_HEIGHT    = 22
local LIST_HEADER_GAP       = 4
local LIST_BOTTOM_PAD       = 12
-- Compact row height used when MinimalisticList is on and the row is not
-- expanded. Just enough for the header line and the 22px button row.
local LIST_COLLAPSED_HEIGHT = 30

local function rowHeightFor(numInfoLines)
  return LIST_HEADER_HEIGHT + LIST_HEADER_GAP + numInfoLines * LIST_LINE_HEIGHT + LIST_BOTTOM_PAD
end

-- infoLines = nil signals a collapsed row (no detail text). minimalistic
-- gates the +/- expand button that sits to the left of the name; expanded
-- sets the button's label.
local function buildListRow(content, watcher, yOffset, infoLines, height, minimalistic, expanded)
  local row = CreateFrame("Frame", nil, content)
  row:SetSize(CONTENT_WIDTH - 30, height)
  -- TOPLEFT at x=0 lines the row up with the title and the separator above
  -- (both anchor at the content frame's left edge).
  row:SetPoint("TOPLEFT", 0, -yOffset)

  -- Left edge cursor: shifts right as we lay out the expand button (when
  -- minimalistic), the status dot, then the name header.
  local EXPAND_BTN_WIDTH = 22
  local DOT_SIZE         = 14
  local leftCursor = 0

  if minimalistic then
    local expandBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    expandBtn:SetSize(EXPAND_BTN_WIDTH, 22)
    expandBtn:SetPoint("TOPLEFT", leftCursor, 0)
    expandBtn:SetText(expanded and "-" or "+")
    expandBtn:SetScript("OnClick", function()
      Panel._expanded[watcher.id] = not Panel._expanded[watcher.id]
      refreshList()
    end)
    setTooltip(expandBtn,
      expanded and "Collapse details" or "Expand details",
      expanded
        and "Hide this watcher's configured triggers, channels, and reply."
        or  "Show this watcher's configured triggers, channels, and reply.")
    leftCursor = leftCursor + EXPAND_BTN_WIDTH + 6
  end

  -- Status dot replaces the right-side ACTIVE/INACTIVE text badge. Frame
  -- (with EnableMouse) wraps the texture so the tooltip fires on hover.
  local dotLeft = leftCursor
  local statusDot = CreateFrame("Frame", nil, row)
  statusDot:EnableMouse(true)
  statusDot:SetSize(DOT_SIZE, DOT_SIZE)
  statusDot:SetPoint("TOPLEFT", dotLeft, -4)
  local dotTex = statusDot:CreateTexture(nil, "ARTWORK")
  dotTex:SetAllPoints()
  dotTex:SetTexture(watcher.enabled
    and "Interface\\COMMON\\Indicator-Green"
    or  "Interface\\COMMON\\Indicator-Red")
  setTooltip(statusDot,
    watcher.enabled and "Active" or "Inactive",
    watcher.enabled
      and "This watcher is currently reacting to chat. Click 'Deactivate' on the right to pause it."
      or  "This watcher is paused and ignoring chat. Click 'Activate' on the right to resume it.")
  leftCursor = dotLeft + DOT_SIZE + 6

  local headerLeft = leftCursor
  local header = row:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  header:SetPoint("TOPLEFT", headerLeft, 0)
  local name = (watcher.name and watcher.name ~= "") and watcher.name or "Untitled"
  header:SetText(colored(name, COLOR_NAME))

  if infoLines then
    -- Info text indents to the second slot from the left so it reads as
    -- nested one column in: under the dot when the +/- expand button takes
    -- the leftmost slot, under the name when no expand button is present.
    local infoLeft = minimalistic and dotLeft or headerLeft
    local info = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    info:SetPoint("TOPLEFT", infoLeft, -(LIST_HEADER_HEIGHT + LIST_HEADER_GAP))
    info:SetWidth(CONTENT_WIDTH - 30 - infoLeft)
    info:SetJustifyH("LEFT")
    info:SetSpacing(2)
    info:SetText(table.concat(infoLines, "\n"))

    -- If the reply (or any line) wrapped, grow the row so its bottom separator
    -- still sits below the rendered text. GetStringHeight returns 0 before the
    -- FontString has been through a layout pass, so we defer one frame.
    C_Timer.After(0, function()
      local rendered = info:GetStringHeight()
      if rendered and rendered > 0 then
        local needed = LIST_HEADER_HEIGHT + LIST_HEADER_GAP + rendered + LIST_BOTTOM_PAD
        if needed > row:GetHeight() then row:SetHeight(needed) end
      end
    end)
  end

  local toggleBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  toggleBtn:SetSize(95, 22)
  toggleBtn:SetPoint("TOPRIGHT", -180, -2)
  toggleBtn:SetText(watcher.enabled and "Deactivate" or "Activate")
  toggleBtn:SetScript("OnClick", function()
    addon.Watchers:SetEnabled(watcher.id, not watcher.enabled)
    refreshList()
  end)
  setTooltip(toggleBtn,
    watcher.enabled and "Deactivate watcher" or "Activate watcher",
    watcher.enabled
      and "Stop this watcher from reacting to chat. Its configuration is kept."
      or  "Enable this watcher so it reacts to its trigger phrases again.")

  local editBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  editBtn:SetSize(65, 22)
  editBtn:SetPoint("LEFT", toggleBtn, "RIGHT", 6, 0)
  editBtn:SetText("Edit")
  editBtn:SetScript("OnClick", function() enterEdit(watcher.id) end)
  setTooltip(editBtn, "Edit watcher",
    "Open this watcher to change its name, triggers, channels, or reply.")

  local delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  delBtn:SetSize(65, 22)
  delBtn:SetPoint("LEFT", editBtn, "RIGHT", 6, 0)
  delBtn:SetText("Delete")
  delBtn:SetScript("OnClick", function()
    Panel._expanded[watcher.id] = nil
    addon.Watchers:Delete(watcher.id)
    refreshList()
  end)
  setTooltip(delBtn, "Delete watcher",
    "Permanently remove this watcher. There is no undo.")

  local sep = row:CreateTexture(nil, "ARTWORK")
  sep:SetHeight(1)
  sep:SetPoint("BOTTOMLEFT", 0, 0)
  sep:SetPoint("BOTTOMRIGHT", 0, 0)
  sep:SetColorTexture(1, 1, 1, 0.2)

  return row
end

local function buildListView(parent)
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetAllPoints(parent)

  local title = makeLabel(frame, "Meower Watchers", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 20, -20)

  local desc = makeLabel(frame,
    "Each watcher reacts to a set of phrases in chat. Add, edit, or toggle entries here.",
    "GameFontHighlight")
  desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
  desc:SetWidth(CONTENT_WIDTH - 30)
  desc:SetJustifyH("LEFT")

  local addBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  addBtn:SetSize(110, 24)
  addBtn:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -10)
  addBtn:SetText("Add New")
  addBtn:SetScript("OnClick", function() enterEdit(nil) end)
  setTooltip(addBtn, "Add new watcher",
    "Open the editor to create a new watcher with its own triggers, channels, and reply.")

  -- Session-only toggle (not persisted to SavedVariables) — when on, the list
  -- filter in refreshList skips watchers with .enabled == false. `frame` is
  -- sized to the full Settings subcategory width which extends past the
  -- addon's visible content; anchoring to desc's RIGHT edge (which uses
  -- CONTENT_WIDTH) keeps the checkbox inside the visible area. The -90
  -- offset leaves room for the "Hide inactive" label to render to the right
  -- of the checkbox icon without spilling past the content edge.
  local hideInactiveCheck = makeCheckbox(frame, "Hide inactive")
  hideInactiveCheck:SetPoint("RIGHT", desc, "RIGHT", -90, 0)
  hideInactiveCheck:SetPoint("TOP",   addBtn, "TOP", 0, 0)
  hideInactiveCheck:SetChecked(Panel.hideInactive and true or false)
  hideInactiveCheck:SetScript("OnClick", function(self)
    Panel.hideInactive = self:GetChecked() and true or false
    refreshList()
  end)
  setTooltip(hideInactiveCheck, "Hide inactive",
    "Only show watchers that are currently active. Deactivated watchers stay in your list but are hidden from view.")
  frame.hideInactiveCheck = hideInactiveCheck

  local topSep = frame:CreateTexture(nil, "ARTWORK")
  topSep:SetHeight(1)
  topSep:SetPoint("TOPLEFT", addBtn, "BOTTOMLEFT", 0, -10)
  topSep:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -30, 0)
  topSep:SetColorTexture(1, 1, 1, 0.3)

  local scrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
  scrollFrame:SetPoint("TOPLEFT", topSep, "BOTTOMLEFT", 0, -8)
  scrollFrame:SetPoint("BOTTOMRIGHT", -30, 10)

  local content = CreateFrame("Frame", nil, scrollFrame)
  content:SetSize(CONTENT_WIDTH, 1)
  scrollFrame:SetScrollChild(content)

  frame.content = content
  return frame
end

refreshList = function()
  if not Panel._listFrame then return end
  releaseListRows()
  local content     = Panel._listFrame.content
  local allWatchers = addon.Watchers:GetAll()
  Panel._expanded   = Panel._expanded or {}

  local minimalistic = MBLib.Settings and MBLib.Settings:Get("MinimalisticList") and true or false
  local sortList     = MBLib.Settings and MBLib.Settings:Get("SortList")         and true or false

  -- Apply the "Hide inactive" filter and optional alphabetical sort. Always
  -- copy into a new table — sorting allWatchers in place would persist a
  -- new order to SavedVariables.
  local visible = {}
  for _, w in ipairs(allWatchers) do
    if not Panel.hideInactive or w.enabled then
      table.insert(visible, w)
    end
  end
  if sortList then
    table.sort(visible, function(a, b)
      local na = (a.name and a.name ~= "") and a.name or "Untitled"
      local nb = (b.name and b.name ~= "") and b.name or "Untitled"
      return na:lower() < nb:lower()
    end)
  end

  if #visible == 0 then
    local empty = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    empty:SetPoint("TOPLEFT", 0, -10)
    if #allWatchers == 0 then
      empty:SetText("No watchers yet. Click \"Add New\" to create one.")
    else
      empty:SetText("No active watchers. Untick \"Hide inactive\" to see disabled ones.")
    end
    empty:SetTextColor(COLOR_SOFT.r, COLOR_SOFT.g, COLOR_SOFT.b)
    table.insert(Panel._listRows, empty)
    content:SetHeight(40)
    return
  end
  local y = 10
  for _, w in ipairs(visible) do
    local expanded = Panel._expanded[w.id] and true or false
    local showInfo = (not minimalistic) or expanded
    local lines    = showInfo and describeWatcher(w) or nil
    local h        = showInfo and rowHeightFor(#lines) or LIST_COLLAPSED_HEIGHT
    local row      = buildListRow(content, w, y, lines, h, minimalistic, expanded)
    table.insert(Panel._listRows, row)
    y = y + h + 10
  end
  content:SetHeight(y + 10)
end

-- Public entry point so settings OnChange callbacks (declared in
-- src/Modules/Settings.lua) can trigger a redraw without reaching into
-- this file's locals.
function Panel:RefreshList()
  if Panel.view == "list" then refreshList() end
end

-- ===== Edit view =====
-- Structure:
--   editFrame
--   |-- topBar (sticky; not in scrollview)
--   |   |-- backBtn   "< Back"
--   |   |-- header    "Add new watcher" / "Edit watcher"
--   |   |-- cancelBtn (right)
--   |   |-- saveBtn   (right of cancel)
--   |   '-- errorText (under buttons, doubles as a disabled-save hint)
--   '-- scrollFrame
--       '-- content (form fields, grouped into Trigger and Reply sections)

local function buildEditForm(parent)
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetAllPoints(parent)
  frame:Hide()

  -- ----- Sticky top bar -----
  local topBar = CreateFrame("Frame", nil, frame)
  topBar:SetPoint("TOPLEFT", 10, -10)
  topBar:SetPoint("TOPRIGHT", -10, -10)
  topBar:SetHeight(TOP_BAR_HEIGHT)

  local topBg = topBar:CreateTexture(nil, "BACKGROUND")
  topBg:SetAllPoints()
  topBg:SetColorTexture(0, 0, 0, 0.25)

  local topUnderline = topBar:CreateTexture(nil, "ARTWORK")
  topUnderline:SetHeight(1)
  topUnderline:SetPoint("BOTTOMLEFT", 0, 0)
  topUnderline:SetPoint("BOTTOMRIGHT", 0, 0)
  topUnderline:SetColorTexture(1, 1, 1, 0.25)

  local backBtn = CreateFrame("Button", nil, topBar, "UIPanelButtonTemplate")
  backBtn:SetSize(80, 22)
  backBtn:SetPoint("TOPLEFT", 8, -8)
  backBtn:SetText("< Back")
  backBtn:SetScript("OnClick", function() exitEdit() end)

  local header = makeLabel(topBar, "Add new watcher", "GameFontNormalLarge")
  header:SetPoint("LEFT", backBtn, "RIGHT", 14, 0)
  frame.header = header

  local saveBtn = CreateFrame("Button", nil, topBar, "UIPanelButtonTemplate")
  saveBtn:SetSize(96, 22)
  saveBtn:SetPoint("TOPRIGHT", -8, -8)
  saveBtn:SetText("Save")
  saveBtn:SetScript("OnClick", function() Panel:saveEdit() end)
  frame.saveBtn = saveBtn

  local cancelBtn = CreateFrame("Button", nil, topBar, "UIPanelButtonTemplate")
  cancelBtn:SetSize(96, 22)
  cancelBtn:SetPoint("RIGHT", saveBtn, "LEFT", -8, 0)
  cancelBtn:SetText("Cancel")
  cancelBtn:SetScript("OnClick", function() exitEdit() end)

  local errorText = topBar:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  errorText:SetPoint("TOPLEFT", backBtn, "BOTTOMLEFT", 0, -6)
  errorText:SetPoint("RIGHT", topBar, "RIGHT", -8, 0)
  errorText:SetJustifyH("LEFT")
  errorText:SetTextColor(COLOR_ERROR.r, COLOR_ERROR.g, COLOR_ERROR.b)
  errorText:SetText("")
  frame.errorText = errorText

  -- ----- Scrollable content -----
  local scrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
  scrollFrame:SetPoint("TOPLEFT", topBar, "BOTTOMLEFT", 0, -8)
  scrollFrame:SetPoint("BOTTOMRIGHT", -30, 10)

  local content = CreateFrame("Frame", nil, scrollFrame)
  content:SetSize(CONTENT_WIDTH, 1060)
  scrollFrame:SetScrollChild(content)

  -- ===== TRIGGER section =====
  local triggerHeader = makeHeader(content, "Trigger")
  triggerHeader:SetPoint("TOPLEFT", content, "TOPLEFT", LEFT_MARGIN, -10)

  local triggerDesc = makeMutedLabel(content,
    "Which phrases should trigger this watcher, and what chat channels to watch.")
  triggerDesc:SetPoint("TOPLEFT", triggerHeader, "BOTTOMLEFT", 0, -4)
  triggerDesc:SetWidth(INNER_WIDTH)
  triggerDesc:SetJustifyH("LEFT")

  local triggerSep = makeFullSeparator(content, triggerDesc, -8)

  -- Name
  local nameLabel = makeLabel(content, "Name")
  nameLabel:SetPoint("LEFT", content, "LEFT", LEFT_MARGIN, 0)
  nameLabel:SetPoint("TOP",  triggerSep, "BOTTOM", 0, -10)
  local nameInput = makeInput(content, INNER_WIDTH)
  nameInput:SetPoint("TOPLEFT", nameLabel, "BOTTOMLEFT", 6, -6)
  nameInput:SetScript("OnTextChanged", function(self)
    if Panel.state then Panel.state.name = self:GetText() or "" end
    Panel:updateSaveButton()
  end)
  frame.nameInput = nameInput

  -- Trigger phrases. One phrase per dynamic input row so a phrase can contain
  -- a comma (no CSV splitting). Rows are rebuilt by rebuildTriggerInputs()
  -- whenever the trigger list changes; +Add appends a new empty row, the
  -- per-row X removes that row. The X is hidden whenever there's only one row
  -- so there's always something to type into.
  local trigLabel = makeLabel(content, "Trigger phrases")
  trigLabel:SetPoint("TOPLEFT", nameInput, "BOTTOMLEFT", -6, -16)
  local trigDesc = makeMutedLabel(content,
    "One word/phrase per field, click + to add another phrase.")
  trigDesc:SetPoint("TOPLEFT", trigLabel, "BOTTOMLEFT", 0, -2)

  -- trigArea is a positional anchor for the first row only; the chain
  -- (rows -> trigAddBtn -> exactCheck) reflows automatically as rows are
  -- added or removed because each link anchors to the previous one.
  local trigArea = CreateFrame("Frame", nil, content)
  trigArea:SetPoint("TOPLEFT", trigDesc, "BOTTOMLEFT", 6, -6)
  trigArea:SetSize(1, 1)
  frame.trigArea = trigArea
  frame.trigRows = {}

  local trigAddBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
  trigAddBtn:SetSize(130, 22)
  trigAddBtn:SetText("+ Add phrase")
  trigAddBtn:SetScript("OnClick", function()
    if not Panel.state then return end
    Panel:syncTriggersFromInputs()
    table.insert(Panel.state.triggers, "")
    Panel:rebuildTriggerInputs()
  end)
  frame.trigAddBtn = trigAddBtn

  -- Exact match: when checked, the whole message must equal a trigger phrase
  -- (still case-insensitive). When unchecked, the phrase only needs to appear
  -- as a whole word somewhere in the message — the historical behavior.
  local exactCheck = makeCheckbox(content, "Exact match")
  exactCheck:SetPoint("TOPLEFT", trigAddBtn, "BOTTOMLEFT", -6, -10)
  exactCheck:SetScript("OnClick", function(self)
    if Panel.state then
      Panel.state.exact = self:GetChecked() and true or false
      Panel:updateSaveButton()
    end
  end)
  frame.exactCheck = exactCheck

  inlineDesc(content, exactCheck,
    "When on, the message must equal a phrase exactly (no extra words before or after). Always case-insensitive.")

  -- Channels grid: w/b/s/e on the left, p/r/i on the right, "Only when
  -- leader/assist" tucked into the right column at row 4 so it sits next to
  -- the group channels (p/r/i) it actually gates.
  local chLabel = makeLabel(content, "Channels to watch")
  -- Anchor to exactCheck rather than the (now inline) description so we don't
  -- pull chLabel up into the description's TOPLEFT when wrap is short. The
  -- extra -22 gap absorbs up to 2 lines of wrapped description text.
  chLabel:SetPoint("TOPLEFT", exactCheck, "BOTTOMLEFT", 0, -22)

  local CHANNEL_LAYOUT = {
    { def = Constants.CHANNELS.WHISPER,  col = 0, row = 0 },
    { def = Constants.CHANNELS.BNET,     col = 0, row = 1 },
    { def = Constants.CHANNELS.GUILD,    col = 0, row = 2 },
    { def = Constants.CHANNELS.SAY,      col = 0, row = 3 },
    { def = Constants.CHANNELS.EMOTE,    col = 0, row = 4 },
    { def = Constants.CHANNELS.PARTY,    col = 1, row = 0 },
    { def = Constants.CHANNELS.RAID,     col = 1, row = 1 },
    { def = Constants.CHANNELS.INSTANCE, col = 1, row = 2 },
  }
  local GRID_COLS  = 2
  local GRID_ROWS  = 5
  local rowHeight  = 26
  local colWidth   = INNER_WIDTH / GRID_COLS
  local LEADER_COL = 1
  local LEADER_ROW = 3

  local grid = CreateFrame("Frame", nil, content)
  grid:SetSize(INNER_WIDTH, GRID_ROWS * rowHeight)
  grid:SetPoint("TOPLEFT", chLabel, "BOTTOMLEFT", 6, -4)

  local channelChecks = {}
  for _, item in ipairs(CHANNEL_LAYOUT) do
    local def = item.def
    local key = def.key
    local cb  = makeCheckbox(grid, channelColored(def))
    cb:SetPoint("TOPLEFT", item.col * colWidth, -item.row * rowHeight)
    cb:SetScript("OnClick", function(self)
      if Panel.state then
        if self:GetChecked() then
          Panel.state.channels[key] = true
        else
          Panel.state.channels[key] = nil
        end
        refreshEditForm()
      end
    end)
    channelChecks[key] = cb
  end
  frame.channelChecks = channelChecks

  local leaderCheck = makeCheckbox(grid, "Only when leader/assist")
  -- +20 indent so it reads as a sub-option of the group channels (Party/Raid/
  -- Instance) it actually gates, rather than another peer channel.
  leaderCheck:SetPoint("TOPLEFT", LEADER_COL * colWidth + 20, -LEADER_ROW * rowHeight)
  leaderCheck:SetScript("OnClick", function(self)
    if Panel.state then Panel.state.onlyLead = self:GetChecked() and true or false end
  end)
  frame.leaderCheck = leaderCheck

  -- ===== REPLY section =====
  local replyHeader = makeHeader(content, "Reply")
  replyHeader:SetPoint("LEFT", content, "LEFT", LEFT_MARGIN, 0)
  replyHeader:SetPoint("TOP",  grid, "BOTTOM", 0, -18)

  local replyDesc = makeMutedLabel(content, "What to do when the trigger fires. Set at least one: reply text, reply emote, or an action. Combining them works too.")
  replyDesc:SetPoint("TOPLEFT", replyHeader, "BOTTOMLEFT", 0, -4)
  replyDesc:SetWidth(INNER_WIDTH)
  replyDesc:SetJustifyH("LEFT")

  local replySep = makeFullSeparator(content, replyDesc, -8)

  -- Reply text + reply channel dropdown
  local replyLabel = makeLabel(content, "Reply with text")
  replyLabel:SetPoint("LEFT", content, "LEFT", LEFT_MARGIN, 0)
  replyLabel:SetPoint("TOP",  replySep, "BOTTOM", 0, -12)

  local replyInput = makeInput(content, INNER_WIDTH - 200)
  replyInput:SetPoint("TOPLEFT", replyLabel, "BOTTOMLEFT", 6, -6)
  replyInput:SetScript("OnTextChanged", function(self)
    if Panel.state then
      Panel.state.reply.text = self:GetText() or ""
      refreshEditForm()
    end
  end)
  frame.replyInput = replyInput

  -- Pre-color the dropdown labels here so each row in the menu (and the
  -- button text once a choice is made) renders in the channel's chat color.
  -- "same" comes back soft grey via replyChannelColored, marking it as a
  -- meta-option rather than a real channel.
  local replyChOptions = {}
  for _, code in ipairs(Constants.REPLY_CHANNELS) do
    table.insert(replyChOptions, { value = code, label = replyChannelColored(code) })
  end
  local replyChBtn = makeDropdown(content, 170, replyChOptions,
    function(value)
      if Panel.state then Panel.state.reply.ch = value end
    end,
    function() return Panel.state and Panel.state.reply.ch end)
  replyChBtn:SetPoint("LEFT", replyInput, "RIGHT", 14, 0)
  frame.replyChBtn = replyChBtn

  -- Placeholder docs (one line per placeholder)
  local placeholderHeader = makeLabel(content, "Placeholders:", "GameFontHighlight")
  placeholderHeader:SetPoint("TOPLEFT", replyInput, "BOTTOMLEFT", -6, -10)

  local placeholderDesc = makeMutedLabel(content, "Tokens you can drop into the text — each one is swapped for the matching value.")
  placeholderDesc:SetPoint("TOPLEFT", placeholderHeader, "BOTTOMLEFT", 0, -4)
  placeholderDesc:SetWidth(INNER_WIDTH)
  placeholderDesc:SetJustifyH("LEFT")

  -- Clickable placeholder rows, sourced from Constants.PLACEHOLDERS so adding
  -- a new placeholder there is enough to surface it in the UI. Each click
  -- opens the copy popup with the matching {key} token pre-selected.
  local prevPh = placeholderDesc
  for _, ph in ipairs(Constants.PLACEHOLDERS) do
    prevPh = makePlaceholderRow(content, prevPh, ph)
  end

  -- Notes split into two lines, stacked
  local notePartyLine = makeMutedLabel(content, " • Replies in the Party / Instance / Raid channels are only done when you're in that group.")
  notePartyLine:SetPoint("TOPLEFT", prevPh, "BOTTOMLEFT", 0, -6)
  notePartyLine:SetWidth(INNER_WIDTH)
  notePartyLine:SetJustifyH("LEFT")

  local noteEmoteLine = makeMutedLabel(content, " • Replies in the Emote channel are sent as /me.")
  noteEmoteLine:SetPoint("TOPLEFT", notePartyLine, "BOTTOMLEFT", 0, -2)
  noteEmoteLine:SetWidth(INNER_WIDTH)
  noteEmoteLine:SetJustifyH("LEFT")

  -- Reply emote (extra distance from above)
  local emoteLabel = makeLabel(content, "Reply with standard emote")
  emoteLabel:SetPoint("TOPLEFT", noteEmoteLine, "BOTTOMLEFT", 0, -22)

  local emoteOptions = { { value = "__none__", label = "None" } }
  if addon.EmoteProvider and addon.EmoteProvider.GetAvailableEmotes then
    local ok, emotes = pcall(addon.EmoteProvider.GetAvailableEmotes, addon.EmoteProvider)
    if ok and type(emotes) == "table" then
      for _, e in ipairs(emotes) do
        table.insert(emoteOptions, { value = e.token, label = e.label or e.token })
      end
    end
  end
  local emoteBtn = makeDropdown(content, 220, emoteOptions,
    function(value)
      if Panel.state then
        Panel.state.reply.emote = (value == "__none__") and nil or value
        refreshEditForm()
      end
    end,
    function()
      if Panel.state and Panel.state.reply.emote then return Panel.state.reply.emote end
      return "__none__"
    end)
  emoteBtn:SetPoint("TOPLEFT", emoteLabel, "BOTTOMLEFT", 0, -6)
  frame.emoteBtn = emoteBtn

  local emoteFirstCheck = makeCheckbox(content, "Do emote before reply text")
  emoteFirstCheck:SetPoint("LEFT", emoteBtn, "RIGHT", 18, 0)
  emoteFirstCheck:SetScript("OnClick", function(self)
    if Panel.state then Panel.state.reply.emoteFirst = self:GetChecked() and true or false end
  end)
  frame.emoteFirstCheck = emoteFirstCheck

  -- ----- Actions subsection (lives inside Reply; no separator above) -----
  local actionsHeader = makeLabel(content, "Reply with actions")
  actionsHeader:SetPoint("LEFT", content, "LEFT", LEFT_MARGIN, 0)
  actionsHeader:SetPoint("TOP",  emoteBtn, "BOTTOM", 0, -22)

  -- Invite block. Descriptions sit at +30 to align under their checkbox label.
  -- The "Confirm" and "Queue" sub-checkboxes are intentionally indented +20
  -- past their parent "Invite sender" so it reads as a sub-group. The kick
  -- block (further down) compensates via the afterInvite anchor offset.
  local inviteCheck = makeCheckbox(content, "Invite")
  inviteCheck:SetPoint("TOPLEFT", actionsHeader, "BOTTOMLEFT", 0, -8)
  inviteCheck:SetScript("OnClick", function(self)
    if Panel.state then
      Panel.state.reply.invite = self:GetChecked() and true or false
      refreshEditForm()
    end
  end)
  frame.inviteCheck = inviteCheck

  inlineDesc(content, inviteCheck, "Invite them to the party/raid.")

  -- Sub-rows live at +20 indent from the parent ("Invite sender") to read as
  -- a sub-group. The -4 gap is tight on purpose so the Confirm/Queue pair
  -- reads as one cluster under Invite; 2-line wrapped descriptions on the
  -- parent row may brush very close but shouldn't overlap given current text.
  local inviteConfirmCheck = makeCheckbox(content, "Confirm before inviting")
  inviteConfirmCheck:SetPoint("TOPLEFT", inviteCheck, "BOTTOMLEFT", 20, -4)
  inviteConfirmCheck:SetScript("OnClick", function(self)
    if Panel.state then
      Panel.state.reply.inviteConfirm = self:GetChecked() and true or false
      refreshEditForm()
    end
  end)
  frame.inviteConfirmCheck = inviteConfirmCheck
  frame.inviteConfirmDesc  = inlineDesc(content, inviteConfirmCheck,
    "Opens a confirm popup instead of inviting immediately.")

  local inviteQueueCheck = makeCheckbox(content, "Queue invite during combat")
  inviteQueueCheck:SetPoint("TOPLEFT", inviteConfirmCheck, "BOTTOMLEFT", 0, -4)
  inviteQueueCheck:SetScript("OnClick", function(self)
    if Panel.state then Panel.state.reply.inviteQueue = self:GetChecked() and true or false end
  end)
  frame.inviteQueueCheck = inviteQueueCheck
  frame.inviteQueueDesc  = inlineDesc(content, inviteQueueCheck,
    "When on, mid-combat invites wait until combat ends. Off = invite anyway (no popup mode only).")

  -- Anchor for the kick block - collapses up to inviteCheck when the invite
  -- sub-tree is hidden, so the kick row doesn't float in empty space. The
  -- block top/bottom references now point at the checkboxes themselves
  -- (descriptions are inline on the right side and would resolve to the
  -- wrong vertical bottom if anchored to).
  local afterInvite = CreateFrame("Frame", nil, content)
  afterInvite:SetSize(1, 1)
  frame.afterInvite       = afterInvite
  frame.inviteBlockBottom = inviteQueueCheck
  frame.inviteBlockTop    = inviteCheck

  -- Kick block
  local kickCheck = makeCheckbox(content, "Kick")
  kickCheck:SetPoint("TOPLEFT", afterInvite, "BOTTOMLEFT", 0, 0)
  kickCheck:SetScript("OnClick", function(self)
    if Panel.state then
      Panel.state.reply.kick = self:GetChecked() and true or false
      refreshEditForm()
    end
  end)
  frame.kickCheck = kickCheck

  frame.kickBlockBottom = inlineDesc(content, kickCheck,
    "Opens a confirm popup to remove the sender from the group. Requires leader/assist and a non-LFG group. Always queues during combat.")

  return frame
end

-- ===== Edit-form refresh =====

refreshEditForm = function()
  local f = Panel._editFrame
  local s = Panel.state
  if not f or not s then return end

  -- Channel checks (state -> widgets). Re-color the label every refresh so
  -- live edits in the Chat options screen propagate the next time the panel
  -- is opened without needing a /reload.
  for key, cb in pairs(f.channelChecks) do
    cb:SetChecked(s.channels[key] and true or false)
    local def = Constants.CHANNEL_BY_KEY[key]
    if def and cb.text then cb.text:SetText(channelColored(def)) end
  end

  -- Guild can only be configured while the player is actually in a guild — the
  -- CHAT_MSG_GUILD event won't fire and the SendChatMessage reply will silently
  -- drop otherwise. Disable the checkbox when guildless so the gating is
  -- obvious in the UI.
  local guildCb = f.channelChecks[Constants.CHANNELS.GUILD.key]
  if guildCb then
    if IsInGuild() then guildCb:Enable() else guildCb:Disable() end
  end

  -- Exact match (state -> widget)
  if f.exactCheck then
    f.exactCheck:SetChecked(s.exact and true or false)
  end

  -- "Only when leader/assist" is only meaningful when a group channel is
  -- ticked. The checkbox lives inside the channel grid (right column, row 4)
  -- so we just Show/Hide it in place - the grid's height does not change.
  local anyGroup = false
  for _, key in ipairs({ "p", "r", "i" }) do
    if s.channels[key] then anyGroup = true break end
  end
  if anyGroup then
    f.leaderCheck:Show()
    f.leaderCheck:SetChecked(s.onlyLead and true or false)
  else
    s.onlyLead = false
    f.leaderCheck:Hide()
  end

  -- Reply channel + emote dropdown labels
  if f.replyChBtn and f.replyChBtn.SyncLabel then f.replyChBtn:SyncLabel() end
  if f.emoteBtn   and f.emoteBtn.SyncLabel   then f.emoteBtn:SyncLabel()   end

  -- emoteFirst checkbox (only when BOTH text and emote are set)
  local hasText  = s.reply.text  and s.reply.text  ~= ""
  local hasEmote = s.reply.emote and s.reply.emote ~= ""
  if hasText and hasEmote then
    f.emoteFirstCheck:Show()
    f.emoteFirstCheck:SetChecked(s.reply.emoteFirst and true or false)
  else
    s.reply.emoteFirst = false
    f.emoteFirstCheck:Hide()
  end

  -- Invite cascade + kick anchor reflow. When invite is off, hide *both* the
  -- sub-checkboxes AND their descriptions (the descriptions are children of
  -- the invite block, not standalone text).
  f.inviteCheck:SetChecked(s.reply.invite and true or false)
  f.afterInvite:ClearAllPoints()
  if s.reply.invite then
    f.inviteConfirmCheck:Show()
    f.inviteConfirmDesc:Show()
    f.inviteQueueCheck:Show()
    f.inviteQueueDesc:Show()
    f.inviteConfirmCheck:SetChecked(s.reply.inviteConfirm and true or false)
    if s.reply.inviteConfirm then
      s.reply.inviteQueue = true
      f.inviteQueueCheck:SetChecked(true)
      f.inviteQueueCheck:Disable()
    else
      f.inviteQueueCheck:SetChecked(s.reply.inviteQueue ~= false)
      f.inviteQueueCheck:Enable()
    end
    -- inviteQueueCheck is sub-indented +20 from inviteCheck. Walk back -20
    -- so the kick checkbox lines back up with "Invite sender". The -8 gap
    -- matches the tightened sub-row spacing above.
    f.afterInvite:SetPoint("TOPLEFT", f.inviteBlockBottom, "BOTTOMLEFT", -20, -8)
  else
    f.inviteConfirmCheck:Hide()
    f.inviteConfirmDesc:Hide()
    f.inviteQueueCheck:Hide()
    f.inviteQueueDesc:Hide()
    -- inviteCheck is at parent x already; no horizontal adjustment needed.
    f.afterInvite:SetPoint("TOPLEFT", f.inviteBlockTop, "BOTTOMLEFT", 0, -8)
  end

  f.kickCheck:SetChecked(s.reply.kick and true or false)

  Panel:updateSaveButton()
end

-- ===== Save button gating =====
-- Re-evaluates the form's validity and toggles the Save button. Reads the
-- live edit-box text directly (not the in-flight Panel.state) because some
-- inputs only sync to state on focus-loss. Reuses the top-bar errorText as
-- a soft (gray) hint when the form is incomplete, and clears it otherwise.

-- Pulls the live text from every per-phrase input row back into
-- Panel.state.triggers so subsequent rebuilds, validation checks, and saves
-- see the user's in-flight edits (the rows only update OnTextChanged for the
-- *currently focused* row's index slot, but +Add and X both need the full
-- snapshot first).
function Panel:syncTriggersFromInputs()
  local f = Panel._editFrame
  if not f or not Panel.state or not f.trigRows then return end
  local out = {}
  for _, row in ipairs(f.trigRows) do
    table.insert(out, row.input:GetText() or "")
  end
  Panel.state.triggers = out
end

-- Tears down and recreates the per-phrase input rows from Panel.state.triggers.
-- Always keeps at least one row visible so there's somewhere to type. The X
-- remove button is hidden whenever there's only one row (and its OnClick is a
-- no-op in that case too, belt-and-suspenders against rapid clicks). +Add and
-- the Exact match block re-anchor to whatever the new last row is.
function Panel:rebuildTriggerInputs()
  local f = Panel._editFrame
  local s = Panel.state
  if not f or not s then return end

  if type(s.triggers) ~= "table" then s.triggers = {} end
  if #s.triggers == 0 then s.triggers = { "" } end

  for _, row in ipairs(f.trigRows) do
    row.input:Hide();     row.input:SetParent(nil)
    row.removeBtn:Hide(); row.removeBtn:SetParent(nil)
  end
  f.trigRows = {}

  local removeBtnWidth = 24
  local rowGap         = 6
  local inputWidth     = INNER_WIDTH - removeBtnWidth - rowGap - 6

  for i = 1, #s.triggers do
    local input = makeInput(f.trigArea, inputWidth)
    if i == 1 then
      input:SetPoint("TOPLEFT", f.trigArea, "TOPLEFT", 0, 0)
    else
      input:SetPoint("TOPLEFT", f.trigRows[i - 1].input, "BOTTOMLEFT", 0, -rowGap)
    end
    input:SetText(s.triggers[i] or "")
    input:SetScript("OnTextChanged", function(editBox)
      if Panel.state and Panel.state.triggers then
        Panel.state.triggers[i] = editBox:GetText() or ""
        Panel:updateSaveButton()
      end
    end)

    local removeBtn = CreateFrame("Button", nil, f.trigArea, "UIPanelButtonTemplate")
    removeBtn:SetSize(removeBtnWidth, 22)
    removeBtn:SetText("X")
    removeBtn:SetPoint("LEFT", input, "RIGHT", rowGap, 0)
    removeBtn:SetScript("OnClick", function()
      if not Panel.state or not Panel.state.triggers then return end
      if #Panel.state.triggers <= 1 then return end
      Panel:syncTriggersFromInputs()
      table.remove(Panel.state.triggers, i)
      Panel:rebuildTriggerInputs()
    end)
    if #s.triggers <= 1 then removeBtn:Hide() end

    table.insert(f.trigRows, { input = input, removeBtn = removeBtn })
  end

  local lastRow = f.trigRows[#f.trigRows]
  f.trigAddBtn:ClearAllPoints()
  f.trigAddBtn:SetPoint("TOPLEFT", lastRow.input, "BOTTOMLEFT", -6, -10)

  Panel:updateSaveButton()
end

function Panel:updateSaveButton()
  local f = Panel._editFrame
  local s = Panel.state
  if not f or not s or not f.saveBtn then return end

  local hasTrigger = false
  if f.trigRows then
    for _, row in ipairs(f.trigRows) do
      local txt = row.input:GetText() or ""
      if txt:match("%S") then hasTrigger = true break end
    end
  end

  local anyChannel = false
  for _, def in ipairs(Constants.CHANNEL_ORDER) do
    if s.channels[def.key] then anyChannel = true break end
  end

  local replyText = (f.replyInput and f.replyInput:GetText()) or ""
  local hasAction = (replyText ~= "")
                 or (s.reply.emote and s.reply.emote ~= "")
                 or s.reply.invite
                 or s.reply.kick

  -- Status text stays static so the user always sees the full requirements
  -- list, not a moving subset that shifts as fields are filled in. The Save
  -- button still toggles based on validity.
  setStatus(f, "Add a trigger phrase, a channel, an action (reply text, emote, invite, or kick) to enable Save.", false)
  if hasTrigger and anyChannel and hasAction then
    f.saveBtn:Enable()
  else
    f.saveBtn:Disable()
  end
end

-- ===== Save / cancel =====

function Panel:saveEdit()
  local f = Panel._editFrame
  local s = Panel.state
  if not f or not s then return end

  -- Snap edit-boxes that may not have lost focus yet
  s.name      = (f.nameInput:GetText() or ""):match("^%s*(.-)%s*$") or ""
  Panel:syncTriggersFromInputs()
  s.reply.text = f.replyInput:GetText() or ""

  -- Filter empty / whitespace-only phrases before persisting.
  local cleanTriggers = {}
  for _, phrase in ipairs(s.triggers) do
    local trimmed = phrase:match("^%s*(.-)%s*$") or ""
    if trimmed ~= "" then table.insert(cleanTriggers, trimmed) end
  end
  s.triggers = cleanTriggers

  if #s.triggers == 0 then
    setStatus(f, "Add at least one trigger phrase.", true)
    return
  end
  local anyChannel = false
  for _, def in ipairs(Constants.CHANNEL_ORDER) do
    if s.channels[def.key] then anyChannel = true break end
  end
  if not anyChannel then
    setStatus(f, "Tick at least one channel to watch.", true)
    return
  end
  local hasAction = (s.reply.text ~= "")
                 or (s.reply.emote and s.reply.emote ~= "")
                 or s.reply.invite or s.reply.kick
  if not hasAction then
    setStatus(f, "Set at least one action: reply text, emote, invite, or kick.", true)
    return
  end

  if s.name == "" then
    -- Auto-name with a unique placeholder
    local takenNames = {}
    for _, w in ipairs(addon.Watchers:GetAll()) do takenNames[(w.name or ""):lower()] = true end
    local n = 1
    while takenNames[("Untitled watcher " .. n):lower()] do n = n + 1 end
    s.name = "Untitled watcher " .. n
  else
    -- Duplicate-name check (case-insensitive, ignoring self)
    local lowerName = s.name:lower()
    for _, w in ipairs(addon.Watchers:GetAll()) do
      if w.id ~= s.id and (w.name or ""):lower() == lowerName then
        setStatus(f, "Another watcher is already named \"" .. s.name .. "\". Pick a different name.", true)
        return
      end
    end
  end

  setStatus(f, "")
  addon.Watchers:Upsert(s)
  exitEdit()
end

-- ===== View transitions =====

local function populateEditWidgets()
  local f = Panel._editFrame
  local s = Panel.state
  if not f or not s then return end
  f.nameInput:SetText(s.name or "")
  Panel:rebuildTriggerInputs()
  f.replyInput:SetText(s.reply.text or "")
  setStatus(f, "")
  refreshEditForm()
end

enterEdit = function(id)
  if id then
    local existing = addon.Watchers:GetByID(id)
    if not existing then return end
    Panel.state = deepCopy(existing)
    Panel._editFrame.header:SetText("Edit watcher")
  else
    Panel.state = Constants.NEW_WATCHER_DEFAULTS()
    Panel._editFrame.header:SetText("Add new watcher")
  end
  Panel.view = "edit"
  Panel._listFrame:Hide()
  Panel._editFrame:Show()
  populateEditWidgets()
end

exitEdit = function()
  Panel.state = nil
  Panel.view = "list"
  Panel._editFrame:Hide()
  Panel._listFrame:Show()
  refreshList()
end

-- ===== Subcategory registration =====

local function build()
  if not (Settings and Settings.RegisterCanvasLayoutSubcategory) then return end
  local mainCategory = MBLib._optionsCategory
  if not mainCategory then return end

  local panel = CreateFrame("Frame")
  panel:Hide()
  panel:SetScript("OnShow", function()
    if Panel.view == "list" then refreshList() end
  end)

  Panel._panel = panel
  Panel._listFrame = buildListView(panel)
  Panel._editFrame = buildEditForm(panel)

  Panel._editFrame:Hide()
  Panel._listFrame:Show()

  Settings.RegisterCanvasLayoutSubcategory(mainCategory, panel, "Watchers")
  refreshList()
end

local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function(self)
  build()
  self:UnregisterEvent("PLAYER_LOGIN")
  self:SetScript("OnEvent", nil)
end)

addon.WatchersPanel = Panel
