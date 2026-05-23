local _, addon = ...

local Constants = addon.Constants
local MBLib = addon.MBLib
local L = addon.L

local Panel = {}

-- Sentinel value stored in reply.emotes to represent an "empty" row in the
-- editor. Mirrors how empty reply-text rows are persisted as "" and dropped
-- at save time. The dropdown surfaces this as "(none)" so the first emote
-- row can always be visible without forcing the user to pick something.
Panel.EMOTE_NONE = "__none__"

local CONTENT_WIDTH = 660
local INNER_WIDTH = 560 -- usable width inside the form padding
-- Width reserved for the left column of the Reply tab (description text and
-- reply-text input rows). The "Reply in" dropdown sits in the right column
-- to the right of this width.
local REPLY_LEFT_COL_WIDTH = 380
-- TOP_BAR_HEIGHT covers two stacked rows inside the sticky edit-form
-- header: action buttons (Back / Cancel / Save) on row 1, and the
-- Trigger/Reply tab buttons (PanelTopTabButtonTemplate) anchored to the
-- topBar's bottom line so they visually tuck into the form content
-- below. The per-tab description lives in each panel; the "what's
-- missing to save" hint is a tooltip on the disabled Save button.
local TOP_BAR_HEIGHT = 76
local INPUT_HEIGHT = 24
local LEFT_MARGIN = 16 -- consistent left edge for form content
local SUB_INDENT = "  " -- visual indent for sub-lines in list rows

local COLOR_NAME = { r = 1.0,  g = 0.82, b = 0.0  }
local COLOR_SOFT = { r = 0.7,  g = 0.7,  b = 0.7  }
local COLOR_HEADING = { r = 1.0,  g = 0.82, b = 0.0  }

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

-- Returns the display string for a list-shaped reply field. Empty list ->
-- empty string. Single entry -> the entry verbatim. Multi-entry -> first
-- entry with a " (+N more)" suffix so the list row stays one line. The full
-- contents are visible in the edit form's multi-row inputs; this is just the
-- compact summary for the watchers list.
local function describeList(list)
  if type(list) ~= "table" or #list == 0 then return "" end
  if #list == 1 then return tostring(list[1] or "") end
  return tostring(list[1] or "") .. "  " .. colored("(+" .. (#list - 1) .. " more)", COLOR_SOFT)
end

-- Returns a display string that joins every entry with a yellow "•" separator
-- (double spaces on each side). Same pattern triggers use — for short tokens
-- like emote names where showing all values fits on a row without truncation.
local function describeListJoined(list)
  if type(list) ~= "table" or #list == 0 then return "" end
  if #list == 1 then return tostring(list[1] or "") end
  local sep = "  " .. colored("•", COLOR_HEADING) .. "  "
  return table.concat(list, sep)
end

-- (Macro pickup lives in MBLib's MacroButton module now, rendered on the
-- addon's main settings page. The list-header "Get macro" button has been
-- retired in favor of that.)

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

-- Builds a clickable placeholder-doc row. Clicking opens MBLib's CopyPopup
-- with the matching {key} token pre-filled. Hover lightens the text so the
-- row reads as interactive.
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
    MBLib.CopyPopup:Show({
      title = L.EDIT_PLACEHOLDERS_COPY_HEADER,
      text  = "{" .. ph.key .. "}",
    })
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

-- ===== Save-failure reporter =====
-- The "Add a trigger phrase..." hint now lives as a tooltip on the
-- disabled Save button, so there's no longer a topbar status line. The
-- only validation that can still fail at save time is the duplicate-name
-- check (every other criterion gates the Save button itself). We print
-- those rare errors to chat with the Meower prefix so the user gets
-- feedback even without a topbar line.
local function reportSaveError(text)
  if not text or text == "" then return end
  print("|cffff8000Meower|r: " .. text)
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
  local triggerLabel = w.exact and L.LIST_ROW_FIELD_TRIGGER_EXACT or L.LIST_ROW_FIELD_TRIGGER
  if #triggerList == 0 then
    table.insert(lines, labelled(triggerLabel, L.LIST_ROW_PLACEHOLDER_DASH))
  else
    table.insert(lines, labelled(triggerLabel, describeListJoined(triggerList)))
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
  local channels = #channelLabels > 0 and table.concat(channelLabels, ", ") or L.LIST_ROW_PLACEHOLDER_DASH
  table.insert(lines, SUB_INDENT .. labelled(L.LIST_ROW_FIELD_CHANNELS, channels))

  -- Filters detail block: one sub-line per enabled filter with its actual
  -- configured value (zone names, friend mode, time window, etc.). Lives
  -- with the trigger group because filters are gates on the trigger, not
  -- on the reply — they belong with "what makes this watcher fire" rather
  -- than "what it does when it fires". Off filters are skipped.
  if w.filters then
    if w.filters.zone and w.filters.zone.enabled then
      local names = {}
      for _, id in ipairs(w.filters.zone.mapIDs or {}) do
        local name
        if C_Map and C_Map.GetMapInfo then
          local ok, info = pcall(C_Map.GetMapInfo, id)
          if ok and type(info) == "table" then name = info.name end
        end
        table.insert(names, (name and name ~= "") and name or string.format(L.LIST_ROW_PLACEHOLDER_MAP_ID_FMT, id))
      end
      table.insert(lines, SUB_INDENT .. labelled(L.LIST_ROW_FIELD_ZONE,
        #names > 0 and table.concat(names, ", ") or L.LIST_ROW_PLACEHOLDER_NONE))
    end

    if w.filters.friends and w.filters.friends.enabled then
      local mode = w.filters.friends.mode or "anyone"
      table.insert(lines, SUB_INDENT .. labelled(L.LIST_ROW_FIELD_FRIENDS,
        Constants.FRIENDS_MODE_LABEL[mode] or mode))
    end

    if w.filters.timeOfDay and w.filters.timeOfDay.enabled then
      local t = w.filters.timeOfDay
      table.insert(lines, SUB_INDENT .. labelled(L.LIST_ROW_FIELD_TIME, string.format(
        "%02d:%02d – %02d:%02d",
        t.startHour or 0, t.startMin or 0, t.endHour or 0, t.endMin or 0)))
    end

    if w.filters.dayOfWeek and w.filters.dayOfWeek.enabled then
      local days = w.filters.dayOfWeek.days or {}
      local allOn = true
      local picked = {}
      for _, wday in ipairs(Constants.DAY_OF_WEEK_ORDER) do
        if days[wday] then
          table.insert(picked, (Constants.DAY_OF_WEEK_LABEL[wday] or "?"):sub(1, 3))
        else
          allOn = false
        end
      end
      table.insert(lines, SUB_INDENT .. labelled(L.LIST_ROW_FIELD_DAYS,
        allOn and L.LIST_ROW_DAYS_ALL
          or (#picked > 0 and table.concat(picked, ", ") or L.LIST_ROW_PLACEHOLDER_NONE)))
    end

    if w.filters.druidForm and w.filters.druidForm.enabled then
      local picked = {}
      for _, form in ipairs(Constants.DRUID_FORMS) do
        if w.filters.druidForm.forms and w.filters.druidForm.forms[form.key] then
          table.insert(picked, form.label)
        end
      end
      table.insert(lines, SUB_INDENT .. labelled(L.LIST_ROW_FIELD_FORM,
        #picked > 0 and table.concat(picked, ", ") or L.LIST_ROW_PLACEHOLDER_NONE))
    end

    if w.filters.cooldown and w.filters.cooldown.enabled then
      table.insert(lines, SUB_INDENT .. labelled(L.LIST_ROW_FIELD_COOLDOWN,
        tostring(w.filters.cooldown.seconds or 0) .. "s"))
    end
  end

  -- Visual gap between trigger group and reply group. A single space keeps the
  -- FontString from collapsing the blank line.
  table.insert(lines, " ")

  local replyTexts  = (w.reply and w.reply.texts)  or {}
  local replyEmotes = (w.reply and w.reply.emotes) or {}
  local hasText     = #replyTexts  > 0
  local hasEmote    = #replyEmotes > 0

  local actionList = {}
  if w.reply and w.reply.invite then table.insert(actionList, "invite") end
  if w.reply and w.reply.kick   then table.insert(actionList, "kick")   end
  local hasActions = #actionList > 0

  if hasText then
    table.insert(lines, labelled(L.LIST_ROW_FIELD_REPLY, describeList(replyTexts)))
    local chKey = (w.reply and w.reply.ch) or "same"
    table.insert(lines, SUB_INDENT .. labelled(L.LIST_ROW_FIELD_REPLY_IN, replyChannelColored(chKey)))
    if hasEmote   then table.insert(lines, SUB_INDENT .. labelled(L.LIST_ROW_FIELD_REPLY_EMOTE_LABEL, describeListJoined(replyEmotes))) end
    if hasActions then table.insert(lines, SUB_INDENT .. labelled(L.LIST_ROW_FIELD_ACTIONS, table.concat(actionList, ", "))) end
  elseif hasEmote then
    table.insert(lines, labelled(L.LIST_ROW_FIELD_REPLY_EMOTE, describeListJoined(replyEmotes)))
    if hasActions then table.insert(lines, SUB_INDENT .. labelled(L.LIST_ROW_FIELD_ACTIONS, table.concat(actionList, ", "))) end
  elseif hasActions then
    table.insert(lines, labelled(L.LIST_ROW_FIELD_ACTIONS, table.concat(actionList, ", ")))
  else
    table.insert(lines, labelled(L.LIST_ROW_FIELD_REPLY, L.LIST_ROW_PLACEHOLDER_DASH))
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
      expanded and L.LIST_ROW_EXPAND_TOOLTIP_TITLE_OPEN or L.LIST_ROW_EXPAND_TOOLTIP_TITLE_CLOSED,
      expanded and L.LIST_ROW_EXPAND_TOOLTIP_DESC_OPEN  or L.LIST_ROW_EXPAND_TOOLTIP_DESC_CLOSED)
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
    watcher.enabled and L.LIST_ROW_STATUS_ACTIVE_TITLE or L.LIST_ROW_STATUS_INACTIVE_TITLE,
    watcher.enabled and L.LIST_ROW_STATUS_ACTIVE_DESC  or L.LIST_ROW_STATUS_INACTIVE_DESC)
  leftCursor = dotLeft + DOT_SIZE + 6

  local headerLeft = leftCursor
  local header = row:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  header:SetPoint("TOPLEFT", headerLeft, 0)
  local name = (watcher.name and watcher.name ~= "") and watcher.name or L.LIST_ROW_UNTITLED
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
  toggleBtn:SetText(watcher.enabled and L.LIST_ROW_DEACTIVATE_BTN or L.LIST_ROW_ACTIVATE_BTN)
  toggleBtn:SetScript("OnClick", function()
    addon.Watchers:SetEnabled(watcher.id, not watcher.enabled)
    refreshList()
  end)
  setTooltip(toggleBtn,
    watcher.enabled and L.LIST_ROW_TOGGLE_ACTIVE_TOOLTIP_TITLE or L.LIST_ROW_TOGGLE_INACTIVE_TOOLTIP_TITLE,
    watcher.enabled and L.LIST_ROW_TOGGLE_ACTIVE_TOOLTIP_DESC  or L.LIST_ROW_TOGGLE_INACTIVE_TOOLTIP_DESC)

  local editBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  editBtn:SetSize(65, 22)
  editBtn:SetPoint("LEFT", toggleBtn, "RIGHT", 6, 0)
  editBtn:SetText(L.LIST_ROW_EDIT_BTN)
  editBtn:SetScript("OnClick", function() enterEdit(watcher.id) end)
  setTooltip(editBtn, L.LIST_ROW_EDIT_TOOLTIP_TITLE, L.LIST_ROW_EDIT_TOOLTIP_DESC)

  local delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  delBtn:SetSize(65, 22)
  delBtn:SetPoint("LEFT", editBtn, "RIGHT", 6, 0)
  delBtn:SetText(L.LIST_ROW_DELETE_BTN)
  delBtn:SetScript("OnClick", function()
    Panel._expanded[watcher.id] = nil
    addon.Watchers:Delete(watcher.id)
    refreshList()
  end)
  setTooltip(delBtn, L.LIST_ROW_DELETE_TOOLTIP_TITLE, L.LIST_ROW_DELETE_TOOLTIP_DESC)

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

  local title = makeLabel(frame, L.LIST_TITLE, "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 20, -20)

  local desc = makeLabel(frame, L.LIST_DESC, "GameFontHighlight")
  desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
  desc:SetWidth(CONTENT_WIDTH - 30)
  desc:SetJustifyH("LEFT")

  local addBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  addBtn:SetSize(110, 24)
  addBtn:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -10)
  addBtn:SetText(L.LIST_ADD_NEW_BTN)
  addBtn:SetScript("OnClick", function() enterEdit(nil) end)
  setTooltip(addBtn, L.LIST_ADD_NEW_TOOLTIP_TITLE, L.LIST_ADD_NEW_TOOLTIP_DESC)

  -- (The "Get macro" button moved to the addon's main settings page, served
  -- by MBLib.MacroButton. See src/Init.lua's SetMacroButton call.)

  -- Session-only toggle (not persisted to SavedVariables) — when on, the list
  -- filter in refreshList skips watchers with .enabled == false. `frame` is
  -- sized to the full Settings subcategory width which extends past the
  -- addon's visible content; anchoring to desc's RIGHT edge (which uses
  -- CONTENT_WIDTH) keeps the checkbox inside the visible area. The -90
  -- offset leaves room for the "Hide inactive" label to render to the right
  -- of the checkbox icon without spilling past the content edge.
  local hideInactiveCheck = makeCheckbox(frame, L.LIST_HIDE_INACTIVE_LABEL)
  hideInactiveCheck:SetPoint("RIGHT", desc, "RIGHT", -90, 0)
  hideInactiveCheck:SetPoint("TOP",   addBtn, "TOP", 0, 0)
  hideInactiveCheck:SetChecked(Panel.hideInactive and true or false)
  hideInactiveCheck:SetScript("OnClick", function(self)
    Panel.hideInactive = self:GetChecked() and true or false
    refreshList()
  end)
  setTooltip(hideInactiveCheck, L.LIST_HIDE_INACTIVE_TOOLTIP_TITLE, L.LIST_HIDE_INACTIVE_TOOLTIP_DESC)
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
      empty:SetText(L.LIST_EMPTY_NONE)
    else
      empty:SetText(L.LIST_EMPTY_FILTERED)
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

-- Swaps the visible tab inside the edit form. Trigger tab holds Name,
-- Trigger phrases, Channels, and the Filters sub-section (the gates that
-- decide WHEN this watcher fires). Reply tab holds the reply channel /
-- text / emote / actions (what it DOES when it fires). The inactive tab
-- panel is Hide()-en so its children don't render at all — child
-- visibility cascades from the panel.
function Panel:setEditTab(tab)
  local f = Panel._editFrame
  if not f then return end
  if tab ~= "trigger" and tab ~= "reply" then tab = "trigger" end
  Panel.editTab = tab

  if f.triggerPanel and f.replyPanel then
    f.triggerPanel:SetShown(tab == "trigger")
    f.replyPanel:SetShown(tab == "reply")
  end

  -- Visual state on the tab buttons. PanelTopTabButtonTemplate has its
  -- own selected/unselected texture treatment — Select hides the body
  -- texture so the tab visually merges with the content below; Deselect
  -- restores the lighter, raised look.
  if f.triggerTabBtn and f.replyTabBtn then
    if tab == "trigger" then
      PanelTemplates_SelectTab(f.triggerTabBtn)
      PanelTemplates_DeselectTab(f.replyTabBtn)
    else
      PanelTemplates_DeselectTab(f.triggerTabBtn)
      PanelTemplates_SelectTab(f.replyTabBtn)
    end
  end

  -- Force a refresh so the deferred scroll-content resize picks the right
  -- bottom widget for the new tab and the scrollbar tracks the visible
  -- panel rather than the previous one.
  if refreshEditForm then refreshEditForm() end
end

-- ===== Edit view =====
-- Structure:
--   editFrame
--   |-- topBar (sticky; not in scrollview)
--   |   |-- backBtn       "< Back"
--   |   |-- header        "Add new watcher" / "Edit watcher"
--   |   |-- cancelBtn     (right)
--   |   |-- saveBtn       (right of cancel; tooltip carries the "what's
--   |   |                  missing" hint when disabled)
--   |   |-- triggerTabBtn (row 2, left half)
--   |   '-- replyTabBtn   (row 2, right half)
--   '-- scrollFrame
--       '-- content
--           |-- triggerPanel (Trigger config: Name, phrases, channels,
--           |                  Filters)
--           '-- replyPanel   (Reply config:   channel, text, emote, actions)

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
  backBtn:SetText(L.EDIT_BACK_BTN)
  backBtn:SetScript("OnClick", function() exitEdit() end)

  local header = makeLabel(topBar, L.EDIT_HEADER_NEW, "GameFontNormalLarge")
  header:SetPoint("LEFT", backBtn, "RIGHT", 14, 0)
  frame.header = header

  local saveBtn = CreateFrame("Button", nil, topBar, "UIPanelButtonTemplate")
  saveBtn:SetSize(96, 22)
  saveBtn:SetPoint("TOPRIGHT", -8, -8)
  saveBtn:SetText(L.EDIT_SAVE_BTN)
  saveBtn:SetScript("OnClick", function() Panel:saveEdit() end)
  -- The validation hint ("Add a trigger phrase...") lives on the Save
  -- button as a tooltip — only meaningful when the button is disabled,
  -- which is precisely when the form is incomplete. Buttons don't fire
  -- OnEnter/OnLeave while disabled by default, so we opt-in to motion
  -- scripts so the tooltip still triggers on hover in that state.
  saveBtn:SetMotionScriptsWhileDisabled(true)
  saveBtn:SetScript("OnEnter", function(self)
    if self:IsEnabled() then return end
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText(L.EDIT_SAVE_BTN, 1, 1, 1)
    GameTooltip:AddLine(L.EDIT_SAVE_HINT, nil, nil, nil, true)
    GameTooltip:Show()
  end)
  saveBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
  frame.saveBtn = saveBtn

  local cancelBtn = CreateFrame("Button", nil, topBar, "UIPanelButtonTemplate")
  cancelBtn:SetSize(96, 22)
  cancelBtn:SetPoint("RIGHT", saveBtn, "LEFT", -8, 0)
  cancelBtn:SetText(L.EDIT_CANCEL_BTN)
  cancelBtn:SetScript("OnClick", function() exitEdit() end)

  -- ----- Tab buttons (anchored to the bottom of the sticky top bar) -----
  local triggerTabBtn = CreateFrame("Button", nil, topBar, "PanelTopTabButtonTemplate")
  triggerTabBtn:SetID(1)
  triggerTabBtn:SetText(L.EDIT_TAB_TRIGGER)
  triggerTabBtn:SetPoint("BOTTOMLEFT", topBar, "BOTTOMLEFT", 12, 0)
  triggerTabBtn:SetScript("OnClick", function() Panel:setEditTab("trigger") end)

  local replyTabBtn = CreateFrame("Button", nil, topBar, "PanelTopTabButtonTemplate")
  replyTabBtn:SetID(2)
  replyTabBtn:SetText(L.EDIT_TAB_REPLY)
  replyTabBtn:SetPoint("LEFT", triggerTabBtn, "RIGHT", -3, 0)
  replyTabBtn:SetScript("OnClick", function() Panel:setEditTab("reply") end)

  frame.triggerTabBtn = triggerTabBtn
  frame.replyTabBtn   = replyTabBtn

  -- ----- Scrollable content -----
  local scrollFrame = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
  scrollFrame:SetPoint("TOPLEFT", topBar, "BOTTOMLEFT", 0, -8)
  scrollFrame:SetPoint("BOTTOMRIGHT", -30, 10)

  local content = CreateFrame("Frame", nil, scrollFrame)
  -- Starting height is a lower bound; refreshEditForm dynamically resizes
  -- to fit the laid-out form so the scrollbar tracks actual content and
  -- doesn't leave a big empty pad below the last visible widget.
  content:SetSize(CONTENT_WIDTH, 800)
  scrollFrame:SetScrollChild(content)
  frame.scrollContent = content

  -- Two sibling sub-panels overlaying each other at content TOPLEFT. All
  -- trigger + filter widgets are children of triggerPanel; all reply +
  -- actions widgets are children of replyPanel. setEditTab toggles which
  -- one is shown — children inherit visibility, so a single SetShown on
  -- the panel switches the whole form's view.
  local triggerPanel = CreateFrame("Frame", nil, content)
  triggerPanel:SetPoint("TOPLEFT",  content, "TOPLEFT",  0, 0)
  triggerPanel:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
  triggerPanel:SetHeight(1)
  frame.triggerPanel = triggerPanel

  local replyPanel = CreateFrame("Frame", nil, content)
  replyPanel:SetPoint("TOPLEFT",  content, "TOPLEFT",  0, 0)
  replyPanel:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
  replyPanel:SetHeight(1)
  replyPanel:Hide() -- default to the trigger tab; enterEdit re-asserts this
  frame.replyPanel = replyPanel

  -- ===== TRIGGER section (lives on triggerPanel) =====
  -- White, standard-size lead-in describing what this tab configures.
  -- GameFontHighlight ships white-on-default at a slightly larger size
  -- than the muted GameFontHighlightSmall used for hints elsewhere.
  local triggerDesc = makeLabel(triggerPanel, L.EDIT_TRIGGER_DESC, "GameFontHighlight")
  triggerDesc:SetPoint("TOPLEFT", triggerPanel, "TOPLEFT", LEFT_MARGIN, -10)
  triggerDesc:SetWidth(INNER_WIDTH)
  triggerDesc:SetJustifyH("LEFT")

  -- Name
  local nameLabel = makeLabel(triggerPanel, L.EDIT_NAME_LABEL)
  nameLabel:SetPoint("TOPLEFT", triggerDesc, "BOTTOMLEFT", 0, -24)
  local nameInput = makeInput(triggerPanel, INNER_WIDTH)
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
  local trigLabel = makeLabel(triggerPanel, L.EDIT_PHRASES_LABEL)
  trigLabel:SetPoint("TOPLEFT", nameInput, "BOTTOMLEFT", -6, -16)
  local trigDesc = makeMutedLabel(triggerPanel, L.EDIT_PHRASES_DESC)
  trigDesc:SetPoint("TOPLEFT", trigLabel, "BOTTOMLEFT", 0, -2)
  trigDesc:SetWidth(INNER_WIDTH)
  trigDesc:SetJustifyH("LEFT")

  -- trigArea is a positional anchor for the first row only; the chain
  -- (rows -> trigAddBtn -> exactCheck) reflows automatically as rows are
  -- added or removed because each link anchors to the previous one.
  local trigArea = CreateFrame("Frame", nil, triggerPanel)
  trigArea:SetPoint("TOPLEFT", trigDesc, "BOTTOMLEFT", 6, -6)
  trigArea:SetSize(1, 1)
  frame.trigArea = trigArea
  frame.trigRows = {}

  local trigAddBtn = CreateFrame("Button", nil, triggerPanel, "UIPanelButtonTemplate")
  trigAddBtn:SetSize(130, 22)
  trigAddBtn:SetText(L.EDIT_PHRASES_ADD_BTN)
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
  local exactCheck = makeCheckbox(triggerPanel, L.EDIT_EXACT_LABEL)
  exactCheck:SetPoint("TOPLEFT", trigAddBtn, "BOTTOMLEFT", -6, -10)
  exactCheck:SetScript("OnClick", function(self)
    if Panel.state then
      Panel.state.exact = self:GetChecked() and true or false
      Panel:updateSaveButton()
    end
  end)
  frame.exactCheck = exactCheck

  inlineDesc(triggerPanel, exactCheck, L.EDIT_EXACT_DESC)

  -- Channels grid: w/b/s/e on the left, p/r/i on the right, "Only when
  -- leader/assist" tucked into the right column at row 4 so it sits next to
  -- the group channels (p/r/i) it actually gates.
  local chLabel = makeLabel(triggerPanel, L.EDIT_CHANNELS_LABEL)
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

  local grid = CreateFrame("Frame", nil, triggerPanel)
  grid:SetSize(INNER_WIDTH, GRID_ROWS * rowHeight)
  grid:SetPoint("TOPLEFT", chLabel, "BOTTOMLEFT", 6, -4)
  frame.grid = grid -- exposed so the FILTERS section can anchor its header below it

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

  local leaderCheck = makeCheckbox(grid, L.EDIT_ONLY_LEAD_LABEL)
  -- +20 indent so it reads as a sub-option of the group channels (Party/Raid/
  -- Instance) it actually gates, rather than another peer channel.
  leaderCheck:SetPoint("TOPLEFT", LEADER_COL * colWidth + 20, -LEADER_ROW * rowHeight)
  leaderCheck:SetScript("OnClick", function(self)
    if Panel.state then Panel.state.onlyLead = self:GetChecked() and true or false end
  end)
  frame.leaderCheck = leaderCheck

  -- ===== REPLY section (lives on replyPanel) =====
  -- White, standard-size lead-in — same styling as triggerDesc on the
  -- other tab so the two tabs read as visual peers.
  local replyDesc = makeLabel(replyPanel, L.EDIT_REPLY_DESC, "GameFontHighlight")
  replyDesc:SetPoint("TOPLEFT", replyPanel, "TOPLEFT", LEFT_MARGIN, -10)
  replyDesc:SetWidth(INNER_WIDTH)
  replyDesc:SetJustifyH("LEFT")

  -- ----- Multi-row reply text (LEFT column) -----
  local replyLabel = makeLabel(replyPanel, L.EDIT_REPLY_TEXT_LABEL)
  replyLabel:SetPoint("TOPLEFT", replyDesc, "BOTTOMLEFT", 0, -24)
  local replyDescText = makeMutedLabel(replyPanel, L.EDIT_REPLY_TEXT_DESC)
  replyDescText:SetPoint("TOPLEFT", replyLabel, "BOTTOMLEFT", 0, -2)
  -- Narrower than the trigger-tab descriptions because the right column
  -- (the "Reply in" dropdown) eats into the panel's horizontal budget.
  replyDescText:SetWidth(REPLY_LEFT_COL_WIDTH)
  replyDescText:SetJustifyH("LEFT")

  -- replyArea anchors the FIRST reply row only; rebuildReplyInputs chains
  -- the rest from each previous row. replyBlockBottom is a 1×1 placeholder
  -- frame that the rebuild repositions to sit right below the +Add button,
  -- so anything anchored to it (placeholders / notes) reflows automatically.
  local replyArea = CreateFrame("Frame", nil, replyPanel)
  replyArea:SetPoint("TOPLEFT", replyDescText, "BOTTOMLEFT", 6, -6)
  replyArea:SetSize(1, 1)
  frame.replyArea = replyArea
  frame.replyRows = {}

  -- ----- Reply-channel selector (RIGHT column) -----
  -- Single dropdown for the whole watcher — when a text is picked at fire
  -- time, this channel is where it goes. Sits to the right of the first
  -- reply-text input row with its label on top. Pre-color the dropdown
  -- labels here so each row in the menu (and the button text once a
  -- choice is made) renders in the channel's chat color. "same" comes
  -- back soft grey via replyChannelColored, marking it as a meta-option
  -- rather than a real channel.
  local replyChOptions = {}
  for _, code in ipairs(Constants.REPLY_CHANNELS) do
    table.insert(replyChOptions, { value = code, label = replyChannelColored(code) })
  end
  local replyChBtn = makeDropdown(replyPanel, 170, replyChOptions,
    function(value)
      if Panel.state then Panel.state.reply.ch = value end
    end,
    function() return Panel.state and Panel.state.reply.ch end)
  -- Aligns the dropdown's top edge with the first input row's top — both
  -- anchor to replyArea TOPLEFT, with the dropdown offset right by the
  -- left column's full width plus a small gap.
  replyChBtn:SetPoint("TOPLEFT", replyArea, "TOPLEFT", REPLY_LEFT_COL_WIDTH + 14, 0)
  frame.replyChBtn = replyChBtn

  local replyChLabel = makeLabel(replyPanel, L.EDIT_REPLY_CH_LABEL)
  replyChLabel:SetPoint("BOTTOMLEFT", replyChBtn, "TOPLEFT", 0, 4)

  local replyAddBtn = CreateFrame("Button", nil, replyPanel, "UIPanelButtonTemplate")
  replyAddBtn:SetSize(130, 22)
  replyAddBtn:SetText(L.EDIT_REPLY_TEXT_ADD_BTN)
  replyAddBtn:SetScript("OnClick", function()
    if not Panel.state then return end
    Panel:syncRepliesFromInputs()
    table.insert(Panel.state.reply.texts, "")
    Panel:rebuildReplyInputs()
  end)
  frame.replyAddBtn = replyAddBtn

  local replyBlockBottom = CreateFrame("Frame", nil, replyPanel)
  replyBlockBottom:SetSize(1, 1)
  frame.replyBlockBottom = replyBlockBottom

  -- Placeholder docs (one line per placeholder)
  local placeholderHeader = makeLabel(replyPanel, L.EDIT_PLACEHOLDERS_HEADER, "GameFontHighlight")
  placeholderHeader:SetPoint("TOPLEFT", replyBlockBottom, "BOTTOMLEFT", -6, -8)

  local placeholderDesc = makeMutedLabel(replyPanel, L.EDIT_PLACEHOLDERS_DESC)
  placeholderDesc:SetPoint("TOPLEFT", placeholderHeader, "BOTTOMLEFT", 0, -4)
  placeholderDesc:SetWidth(INNER_WIDTH)
  placeholderDesc:SetJustifyH("LEFT")

  -- Clickable placeholder rows, sourced from Constants.PLACEHOLDERS so adding
  -- a new placeholder there is enough to surface it in the UI. Each click
  -- opens the copy popup with the matching {key} token pre-selected.
  local prevPh = placeholderDesc
  for _, ph in ipairs(Constants.PLACEHOLDERS) do
    prevPh = makePlaceholderRow(replyPanel, prevPh, ph)
  end

  -- Notes split into two lines, stacked
  local notePartyLine = makeMutedLabel(replyPanel, L.EDIT_NOTE_GROUP_CHANNELS)
  notePartyLine:SetPoint("TOPLEFT", prevPh, "BOTTOMLEFT", 0, -6)
  notePartyLine:SetWidth(INNER_WIDTH)
  notePartyLine:SetJustifyH("LEFT")

  local noteEmoteLine = makeMutedLabel(replyPanel, L.EDIT_NOTE_EMOTE_CHANNEL)
  noteEmoteLine:SetPoint("TOPLEFT", notePartyLine, "BOTTOMLEFT", 0, -2)
  noteEmoteLine:SetWidth(INNER_WIDTH)
  noteEmoteLine:SetJustifyH("LEFT")

  -- ----- Multi-row reply emote -----
  -- emoteOptions is shared across all dropdown rows. Each row builds its own
  -- DropdownButton but reuses this option list to avoid copying 250+ entries
  -- per row. The "(none)" sentinel sits at the top so the first row reads as
  -- "no emote yet" by default — saveEdit drops EMOTE_NONE entries before
  -- persisting, mirroring how empty reply-text rows are dropped.
  local emoteLabel = makeLabel(replyPanel, L.EDIT_REPLY_EMOTE_LABEL)
  emoteLabel:SetPoint("TOPLEFT", noteEmoteLine, "BOTTOMLEFT", 0, -28)
  local emoteDescText = makeMutedLabel(replyPanel, L.EDIT_REPLY_EMOTE_DESC)
  emoteDescText:SetPoint("TOPLEFT", emoteLabel, "BOTTOMLEFT", 0, -2)
  emoteDescText:SetWidth(INNER_WIDTH)
  emoteDescText:SetJustifyH("LEFT")

  local emoteOptions = { { value = Panel.EMOTE_NONE, label = L.EDIT_REPLY_EMOTE_NONE } }
  if addon.EmoteProvider and addon.EmoteProvider.GetAvailableEmotes then
    local ok, emotes = pcall(addon.EmoteProvider.GetAvailableEmotes, addon.EmoteProvider)
    if ok and type(emotes) == "table" then
      for _, e in ipairs(emotes) do
        table.insert(emoteOptions, { value = e.token, label = e.label or e.token })
      end
    end
  end
  frame.emoteOptions = emoteOptions

  local emoteArea = CreateFrame("Frame", nil, replyPanel)
  emoteArea:SetPoint("TOPLEFT", emoteDescText, "BOTTOMLEFT", 0, -6)
  emoteArea:SetSize(1, 1)
  frame.emoteArea = emoteArea
  frame.emoteRows = {}

  local emoteAddBtn = CreateFrame("Button", nil, replyPanel, "UIPanelButtonTemplate")
  emoteAddBtn:SetSize(130, 22)
  emoteAddBtn:SetText(L.EDIT_REPLY_EMOTE_ADD_BTN)
  emoteAddBtn:SetScript("OnClick", function()
    if not Panel.state then return end
    -- Pick the first concrete emote (not the (none) sentinel) that isn't
    -- already on another row — keeps +Add from creating duplicate rows the
    -- user would have to manually change.
    local used = {}
    for _, v in ipairs(Panel.state.reply.emotes or {}) do used[v] = true end
    local pick
    for _, opt in ipairs(emoteOptions) do
      if opt.value ~= Panel.EMOTE_NONE and not used[opt.value] then
        pick = opt.value
        break
      end
    end
    if not pick then return end -- all emotes already used (very unlikely)
    table.insert(Panel.state.reply.emotes, pick)
    Panel:rebuildEmoteInputs()
    refreshEditForm()
  end)
  frame.emoteAddBtn = emoteAddBtn

  local emoteBlockBottom = CreateFrame("Frame", nil, replyPanel)
  emoteBlockBottom:SetSize(1, 1)
  frame.emoteBlockBottom = emoteBlockBottom

  -- emoteFirstCheck rides alongside the +Add button rather than below the
  -- whole block. When the checkbox is hidden (no text or no emote chosen)
  -- it doesn't leave a vertical gap, so the actions section sits at a
  -- consistent distance regardless of state.
  local emoteFirstCheck = makeCheckbox(replyPanel, L.EDIT_EMOTE_FIRST_LABEL)
  emoteFirstCheck:SetPoint("LEFT", emoteAddBtn, "RIGHT", 18, 0)
  emoteFirstCheck:SetScript("OnClick", function(self)
    if Panel.state then Panel.state.reply.emoteFirst = self:GetChecked() and true or false end
  end)
  frame.emoteFirstCheck = emoteFirstCheck

  -- ----- Actions subsection (lives inside Reply; no separator above) -----
  -- Anchored to emoteBlockBottom (which sits just below +Add emote) rather
  -- than emoteFirstCheck — the checkbox is now inline with +Add and may be
  -- hidden, so anchoring to it left an inconsistent vertical gap. The -28
  -- matches the gap above "Reply with standard emote" so the section spacing
  -- reads as even.
  local actionsHeader = makeLabel(replyPanel, L.EDIT_ACTIONS_LABEL)
  actionsHeader:SetPoint("LEFT", replyPanel, "LEFT", LEFT_MARGIN, 0)
  actionsHeader:SetPoint("TOP",  emoteBlockBottom, "BOTTOM", 0, -28)

  -- Invite block. Descriptions sit at +30 to align under their checkbox label.
  -- The "Confirm" and "Queue" sub-checkboxes are intentionally indented +20
  -- past their parent "Invite sender" so it reads as a sub-group. The kick
  -- block (further down) compensates via the afterInvite anchor offset.
  local inviteCheck = makeCheckbox(replyPanel, L.EDIT_INVITE_LABEL)
  inviteCheck:SetPoint("TOPLEFT", actionsHeader, "BOTTOMLEFT", 0, -8)
  inviteCheck:SetScript("OnClick", function(self)
    if Panel.state then
      Panel.state.reply.invite = self:GetChecked() and true or false
      refreshEditForm()
    end
  end)
  frame.inviteCheck = inviteCheck

  inlineDesc(replyPanel, inviteCheck, L.EDIT_INVITE_DESC)

  -- Sub-rows live at +20 indent from the parent ("Invite sender") to read as
  -- a sub-group. The -4 gap is tight on purpose so the Confirm/Queue pair
  -- reads as one cluster under Invite; 2-line wrapped descriptions on the
  -- parent row may brush very close but shouldn't overlap given current text.
  local inviteConfirmCheck = makeCheckbox(replyPanel, L.EDIT_INVITE_CONFIRM_LABEL)
  inviteConfirmCheck:SetPoint("TOPLEFT", inviteCheck, "BOTTOMLEFT", 20, -4)
  inviteConfirmCheck:SetScript("OnClick", function(self)
    if Panel.state then
      Panel.state.reply.inviteConfirm = self:GetChecked() and true or false
      refreshEditForm()
    end
  end)
  frame.inviteConfirmCheck = inviteConfirmCheck
  frame.inviteConfirmDesc  = inlineDesc(replyPanel, inviteConfirmCheck, L.EDIT_INVITE_CONFIRM_DESC)

  local inviteQueueCheck = makeCheckbox(replyPanel, L.EDIT_INVITE_QUEUE_LABEL)
  inviteQueueCheck:SetPoint("TOPLEFT", inviteConfirmCheck, "BOTTOMLEFT", 0, -4)
  inviteQueueCheck:SetScript("OnClick", function(self)
    if Panel.state then Panel.state.reply.inviteQueue = self:GetChecked() and true or false end
  end)
  frame.inviteQueueCheck = inviteQueueCheck
  frame.inviteQueueDesc  = inlineDesc(replyPanel, inviteQueueCheck, L.EDIT_INVITE_QUEUE_DESC)

  -- Anchor for the kick block - collapses up to inviteCheck when the invite
  -- sub-tree is hidden, so the kick row doesn't float in empty space. The
  -- block top/bottom references now point at the checkboxes themselves
  -- (descriptions are inline on the right side and would resolve to the
  -- wrong vertical bottom if anchored to).
  local afterInvite = CreateFrame("Frame", nil, replyPanel)
  afterInvite:SetSize(1, 1)
  frame.afterInvite       = afterInvite
  frame.inviteBlockBottom = inviteQueueCheck
  frame.inviteBlockTop    = inviteCheck

  -- Kick block
  local kickCheck = makeCheckbox(replyPanel, L.EDIT_KICK_LABEL)
  kickCheck:SetPoint("TOPLEFT", afterInvite, "BOTTOMLEFT", 0, 0)
  kickCheck:SetScript("OnClick", function(self)
    if Panel.state then
      Panel.state.reply.kick = self:GetChecked() and true or false
      refreshEditForm()
    end
  end)
  frame.kickCheck = kickCheck

  frame.kickBlockBottom = inlineDesc(replyPanel, kickCheck, L.EDIT_KICK_DESC)

  -- ===== FILTERS section (lives on triggerPanel) =====
  -- Filters gate WHEN the trigger fires, so they belong with the trigger
  -- group, not the reply. Optional gates layered on top of the channel +
  -- trigger match — each filter has a checkbox that reveals its editor,
  -- shown/hidden in refreshEditForm. Off filters don't enforce anything.
  local filtersHeader = makeHeader(triggerPanel, L.EDIT_FILTERS_HEADER)
  filtersHeader:SetPoint("LEFT", triggerPanel, "LEFT", LEFT_MARGIN, 0)
  -- Anchored below the channels grid (the last widget in the trigger
  -- subsection) with a generous gap to absorb the channel grid's bottom
  -- padding.
  filtersHeader:SetPoint("TOP",  grid, "BOTTOM", 0, -18)

  local filtersDesc = makeMutedLabel(triggerPanel, L.EDIT_FILTERS_DESC)
  filtersDesc:SetPoint("TOPLEFT", filtersHeader, "BOTTOMLEFT", 0, -4)
  filtersDesc:SetWidth(INNER_WIDTH)
  filtersDesc:SetJustifyH("LEFT")

  local filtersSep = makeFullSeparator(triggerPanel, filtersDesc, -8)

  -- buildFilterBlock factors the "checkbox + revealable editor" pattern. It
  -- returns the editor frame (caller anchors it to the toggle and populates
  -- children) AND a bottomAnchor frame the caller can move when the editor's
  -- internal layout changes height. The next filter block anchors to this
  -- bottomAnchor so the section reflows correctly when filters open/close.
  local function buildFilterBlock(prevBottom, label, key)
    local cb = makeCheckbox(triggerPanel, label)
    cb:SetPoint("TOPLEFT", prevBottom, "BOTTOMLEFT", 0, -10)
    cb:SetScript("OnClick", function(self)
      if Panel.state and Panel.state.filters[key] then
        Panel.state.filters[key].enabled = self:GetChecked() and true or false
        refreshEditForm()
      end
    end)

    local editor = CreateFrame("Frame", nil, triggerPanel)
    editor:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 20, -4)
    editor:SetPoint("RIGHT",   triggerPanel, "RIGHT", -20, 0)
    editor:SetHeight(1) -- caller sets the actual height after populating

    -- bottomAnchor sits just below the editor when open, or right below the
    -- checkbox when closed. The block-builder repositions it.
    local bottomAnchor = CreateFrame("Frame", nil, triggerPanel)
    bottomAnchor:SetSize(1, 1)

    return { checkbox = cb, editor = editor, bottomAnchor = bottomAnchor, key = key }
  end

  frame.filterBlocks = {}
  local lastFilterBottom = filtersSep

  -- ----- Zone filter -----
  local zoneBlock = buildFilterBlock(lastFilterBottom, L.EDIT_FILTER_ZONE_LABEL, "zone")
  do
    local editor = zoneBlock.editor
    local hint = makeMutedLabel(editor, L.EDIT_FILTER_ZONE_DESC)
    hint:SetPoint("TOPLEFT", 0, 0)
    hint:SetWidth(INNER_WIDTH - 40)
    hint:SetJustifyH("LEFT")

    local addBtn = CreateFrame("Button", nil, editor, "UIPanelButtonTemplate")
    addBtn:SetSize(150, 22)
    addBtn:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -6)
    addBtn:SetText(L.EDIT_FILTER_ZONE_ADD_CURRENT_BTN)
    addBtn:SetScript("OnClick", function()
      if not Panel.state then return end
      local zone = Panel.state.filters.zone
      local mapID
      if C_Map and C_Map.GetBestMapForUnit then
        local ok, v = pcall(C_Map.GetBestMapForUnit, "player")
        if ok then mapID = v end
      end
      if not mapID then return end
      for _, existing in ipairs(zone.mapIDs) do
        if existing == mapID then return end
      end
      table.insert(zone.mapIDs, mapID)
      refreshEditForm()
    end)
    zoneBlock.addBtn = addBtn

    -- Manual map-ID entry: small numeric input + "Add ID" button. Sits on
    -- the same row as the "Add current zone" button so the two ways to add
    -- a zone read as peers. Pressing Enter inside the input also commits.
    local idLabel = makeMutedLabel(editor, L.EDIT_FILTER_ZONE_BY_ID_LABEL)
    idLabel:SetPoint("LEFT", addBtn, "RIGHT", 12, 0)

    local idInput = CreateFrame("EditBox", nil, editor, "InputBoxTemplate")
    idInput:SetSize(70, INPUT_HEIGHT)
    idInput:SetAutoFocus(false)
    idInput:SetNumeric(true)
    idInput:SetMaxLetters(6)
    idInput:SetFontObject(ChatFontNormal)
    idInput:SetPoint("LEFT", idLabel, "RIGHT", 8, 0)
    idInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local function commitID()
      if not Panel.state then return end
      local id = tonumber(idInput:GetText() or "")
      if not id or id <= 0 then return end
      local zone = Panel.state.filters.zone
      for _, existing in ipairs(zone.mapIDs) do
        if existing == id then idInput:SetText(""); return end
      end
      table.insert(zone.mapIDs, id)
      idInput:SetText("")
      idInput:ClearFocus()
      refreshEditForm()
    end

    idInput:SetScript("OnEnterPressed", commitID)

    local idAddBtn = CreateFrame("Button", nil, editor, "UIPanelButtonTemplate")
    idAddBtn:SetSize(70, 22)
    idAddBtn:SetPoint("LEFT", idInput, "RIGHT", 6, 0)
    idAddBtn:SetText(L.EDIT_FILTER_ZONE_ADD_ID_BTN)
    idAddBtn:SetScript("OnClick", commitID)
    zoneBlock.idInput = idInput

    -- rowsArea hosts a stack of "<zone name> [X]" rows rebuilt every refresh.
    -- Stored on the block so refresh can reach in and rebuild without
    -- needing closure state. Anchored below addBtn (which sets the row
    -- height) so the zone list always begins on a fresh line.
    local rowsArea = CreateFrame("Frame", nil, editor)
    rowsArea:SetPoint("TOPLEFT", addBtn, "BOTTOMLEFT", 0, -8)
    rowsArea:SetSize(INNER_WIDTH - 40, 1)
    zoneBlock.rowsArea = rowsArea
    zoneBlock.rows = {}
  end
  table.insert(frame.filterBlocks, zoneBlock)
  lastFilterBottom = zoneBlock.bottomAnchor

  -- ----- Friends filter -----
  local friendsBlock = buildFilterBlock(lastFilterBottom, L.EDIT_FILTER_FRIENDS_LABEL, "friends")
  do
    local editor = friendsBlock.editor
    local friendsOptions = {}
    for _, mode in ipairs(Constants.FRIENDS_MODES) do
      table.insert(friendsOptions, { value = mode, label = Constants.FRIENDS_MODE_LABEL[mode] or mode })
    end
    local dd = makeDropdown(editor, 180, friendsOptions,
      function(value)
        if Panel.state and Panel.state.filters.friends then
          Panel.state.filters.friends.mode = value
        end
      end,
      function()
        return Panel.state and Panel.state.filters.friends and Panel.state.filters.friends.mode
      end)
    dd:SetPoint("TOPLEFT", 0, 0)
    friendsBlock.dd = dd

    local hint = makeMutedLabel(editor, L.EDIT_FILTER_FRIENDS_DESC)
    hint:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -4)
    hint:SetWidth(INNER_WIDTH - 40)
    hint:SetJustifyH("LEFT")
    friendsBlock.hint = hint
  end
  table.insert(frame.filterBlocks, friendsBlock)
  lastFilterBottom = friendsBlock.bottomAnchor

  -- ----- Time-of-day filter -----
  local timeBlock = buildFilterBlock(lastFilterBottom, L.EDIT_FILTER_TIME_LABEL, "timeOfDay")
  do
    local editor = timeBlock.editor
    local function makeTimeInput(width)
      local eb = CreateFrame("EditBox", nil, editor, "InputBoxTemplate")
      eb:SetSize(width, INPUT_HEIGHT)
      eb:SetAutoFocus(false)
      eb:SetNumeric(true)
      eb:SetMaxLetters(2)
      eb:SetFontObject(ChatFontNormal)
      eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
      eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
      return eb
    end
    local function clampHM(value, maxVal)
      value = tonumber(value) or 0
      if value < 0 then value = 0 end
      if value > maxVal then value = maxVal end
      return value
    end

    local fromLbl = makeLabel(editor, L.EDIT_FILTER_TIME_FROM)
    fromLbl:SetPoint("TOPLEFT", 0, -2)
    local fromH = makeTimeInput(34)
    fromH:SetPoint("LEFT", fromLbl, "RIGHT", 8, 0)
    fromH:SetScript("OnTextChanged", function(self)
      if Panel.state then
        Panel.state.filters.timeOfDay.startHour = clampHM(self:GetText(), 23)
      end
    end)
    local fromSep = makeLabel(editor, ":")
    fromSep:SetPoint("LEFT", fromH, "RIGHT", 4, 0)
    local fromM = makeTimeInput(34)
    fromM:SetPoint("LEFT", fromSep, "RIGHT", 4, 0)
    fromM:SetScript("OnTextChanged", function(self)
      if Panel.state then
        Panel.state.filters.timeOfDay.startMin = clampHM(self:GetText(), 59)
      end
    end)

    local toLbl = makeLabel(editor, L.EDIT_FILTER_TIME_TO)
    toLbl:SetPoint("LEFT", fromM, "RIGHT", 12, 0)
    local toH = makeTimeInput(34)
    toH:SetPoint("LEFT", toLbl, "RIGHT", 8, 0)
    toH:SetScript("OnTextChanged", function(self)
      if Panel.state then
        Panel.state.filters.timeOfDay.endHour = clampHM(self:GetText(), 23)
      end
    end)
    local toSep = makeLabel(editor, ":")
    toSep:SetPoint("LEFT", toH, "RIGHT", 4, 0)
    local toM = makeTimeInput(34)
    toM:SetPoint("LEFT", toSep, "RIGHT", 4, 0)
    toM:SetScript("OnTextChanged", function(self)
      if Panel.state then
        Panel.state.filters.timeOfDay.endMin = clampHM(self:GetText(), 59)
      end
    end)

    local hint = makeMutedLabel(editor, L.EDIT_FILTER_TIME_DESC)
    hint:SetPoint("TOPLEFT", fromLbl, "BOTTOMLEFT", 0, -10)
    hint:SetPoint("RIGHT",   editor, "RIGHT", 0, 0)
    hint:SetJustifyH("LEFT")

    timeBlock.fromH, timeBlock.fromM = fromH, fromM
    timeBlock.toH,   timeBlock.toM   = toH,   toM
    timeBlock.hint = hint
  end
  table.insert(frame.filterBlocks, timeBlock)
  lastFilterBottom = timeBlock.bottomAnchor

  -- ----- Day-of-week filter -----
  -- 2-column grid with full day names (column 1: Mon–Thu, column 2: Fri–Sun).
  -- Matches the druid-form layout below so the two checkbox-grid filters
  -- read as siblings. Full names so wide labels (Wednesday) don't get
  -- clipped by the editor edge.
  local dayBlock = buildFilterBlock(lastFilterBottom, L.EDIT_FILTER_DAY_LABEL, "dayOfWeek")
  do
    local editor = dayBlock.editor
    dayBlock.dayChecks = {}
    local DAY_COL_WIDTH = 130
    local DAY_ROW_HEIGHT = 28
    local order = Constants.DAY_OF_WEEK_ORDER
    local rowsPerCol = math.ceil(#order / 2)
    for i, wday in ipairs(order) do
      local col = (i - 1) >= rowsPerCol and 1 or 0
      local row = (i - 1) % rowsPerCol
      local cb = makeCheckbox(editor, Constants.DAY_OF_WEEK_LABEL[wday] or "?")
      cb:SetPoint("TOPLEFT", col * DAY_COL_WIDTH, -row * DAY_ROW_HEIGHT)
      cb:SetScript("OnClick", function(self)
        if Panel.state then
          Panel.state.filters.dayOfWeek.days[wday] = self:GetChecked() and true or false
        end
      end)
      dayBlock.dayChecks[wday] = cb
    end
    dayBlock.rowsPerCol = rowsPerCol
    dayBlock.rowHeight  = DAY_ROW_HEIGHT
  end
  table.insert(frame.filterBlocks, dayBlock)
  lastFilterBottom = dayBlock.bottomAnchor

  -- ----- Druid shapeshift filter -----
  -- Only the block.checkbox / editor are rendered; non-druid players never
  -- see this block (refreshEditForm hides the whole block). We still build
  -- the widget tree so changing class (rare) doesn't need a /reload.
  --
  -- Laid out as 2 columns: each column gets ~half the forms (col 1: top
  -- half, col 2: bottom half). 130px column width is enough for "Humanoid"
  -- with the checkbox plus a comfortable spacing gap before the next col.
  local druidBlock = buildFilterBlock(lastFilterBottom, L.EDIT_FILTER_FORM_LABEL, "druidForm")
  do
    local editor = druidBlock.editor
    druidBlock.formChecks = {}
    local DRUID_COL_WIDTH = 130
    local DRUID_ROW_HEIGHT = 24
    local forms = Constants.DRUID_FORMS
    local rowsPerCol = math.ceil(#forms / 2)
    for i, form in ipairs(forms) do
      local col = (i - 1) >= rowsPerCol and 1 or 0
      local row = (i - 1) % rowsPerCol
      local cb = makeCheckbox(editor, form.label)
      cb:SetPoint("TOPLEFT", col * DRUID_COL_WIDTH, -row * DRUID_ROW_HEIGHT)
      cb:SetScript("OnClick", function(self)
        if Panel.state then
          Panel.state.filters.druidForm.forms[form.key] = self:GetChecked() and true or false
        end
      end)
      druidBlock.formChecks[form.key] = cb
    end
    druidBlock.rowsPerCol = rowsPerCol
    druidBlock.rowHeight  = DRUID_ROW_HEIGHT
  end
  table.insert(frame.filterBlocks, druidBlock)
  lastFilterBottom = druidBlock.bottomAnchor

  -- ----- Per-watcher cooldown override -----
  local cdBlock = buildFilterBlock(lastFilterBottom, L.EDIT_FILTER_CD_LABEL, "cooldown")
  do
    local editor = cdBlock.editor
    local hint = makeMutedLabel(editor, L.EDIT_FILTER_CD_DESC)
    hint:SetPoint("TOPLEFT", 0, 0)
    hint:SetWidth(INNER_WIDTH - 40)
    hint:SetJustifyH("LEFT")

    local lbl = makeLabel(editor, L.EDIT_FILTER_CD_INPUT_LABEL)
    lbl:SetPoint("TOPLEFT", hint, "BOTTOMLEFT", 0, -8)

    local input = CreateFrame("EditBox", nil, editor, "InputBoxTemplate")
    input:SetSize(60, INPUT_HEIGHT)
    input:SetAutoFocus(false)
    input:SetNumeric(true)
    input:SetMaxLetters(4)
    input:SetFontObject(ChatFontNormal)
    input:SetPoint("LEFT", lbl, "RIGHT", 12, 0)
    input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    input:SetScript("OnEnterPressed",  function(self) self:ClearFocus() end)
    input:SetScript("OnTextChanged", function(self)
      if Panel.state then
        local v = tonumber(self:GetText()) or 0
        if v < 0 then v = 0 end
        if v > 3600 then v = 3600 end
        Panel.state.filters.cooldown.seconds = v
      end
    end)
    cdBlock.input = input
  end
  table.insert(frame.filterBlocks, cdBlock)
  lastFilterBottom = cdBlock.bottomAnchor

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

  -- Reply channel dropdown label (single, applies to the whole watcher).
  if f.replyChBtn and f.replyChBtn.SyncLabel then f.replyChBtn:SyncLabel() end

  -- emoteFirst checkbox (only when BOTH a non-empty text and a non-empty
  -- emote list are configured — picking one of each is necessary for the
  -- "do emote first" ordering to mean anything). We snapshot live input
  -- text into the texts list before deciding so the toggle reacts as the
  -- user types into the last empty reply row.
  Panel:syncRepliesFromInputs()
  local hasText  = type(s.reply.texts)  == "table" and (function()
    for _, t in ipairs(s.reply.texts) do
      if t and t:match("%S") then return true end
    end
    return false
  end)()
  local hasEmote = false
  if type(s.reply.emotes) == "table" then
    for _, e in ipairs(s.reply.emotes) do
      if e and e ~= Panel.EMOTE_NONE then hasEmote = true break end
    end
  end
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

  -- ===== Filter blocks =====
  -- Each block: show editor when enabled, hide when off. The bottomAnchor
  -- frame sits below the editor when shown, immediately below the checkbox
  -- when hidden, so the next block reflows without gaps.
  s.filters = s.filters or {}

  -- Per-block height estimates. We size each editor explicitly because the
  -- bottomAnchor anchors to the editor's BOTTOMLEFT; a Frame with no height
  -- collapses to its top edge and the next block would overlap.
  -- Per-block height estimates. dayOfWeek and druidForm both use 2-column
  -- grids with ceil(N/2) rows × 28px (matching UICheckButtonTemplate's
  -- effective per-row height with our label font). The +12 trailing pad
  -- keeps the next filter block from butting right against the last row.
  local FILTER_BLOCK_HEIGHTS = {
    zone      = 110, -- hint + 2 buttons row + id input row
    friends   = 76,
    timeOfDay = 64,
    dayOfWeek = math.ceil(#Constants.DAY_OF_WEEK_ORDER / 2) * 28 + 12,
    druidForm = math.ceil(#Constants.DRUID_FORMS / 2) * 28 + 12,
    cooldown  = 56,
  }

  for _, block in ipairs(f.filterBlocks or {}) do
    local fState = s.filters[block.key]
    if not fState then
      block.checkbox:Hide()
      block.editor:Hide()
      block.bottomAnchor:ClearAllPoints()
      block.bottomAnchor:SetPoint("TOPLEFT", block.checkbox, "BOTTOMLEFT", 0, 0)
    else
      block.checkbox:Show()
      block.checkbox:SetChecked(fState.enabled and true or false)

      if fState.enabled then
        block.editor:Show()
        block.editor:SetHeight(FILTER_BLOCK_HEIGHTS[block.key] or 60)
        block.bottomAnchor:ClearAllPoints()
        block.bottomAnchor:SetPoint("TOPLEFT", block.editor, "BOTTOMLEFT", -20, -4)
      else
        block.editor:Hide()
        block.bottomAnchor:ClearAllPoints()
        block.bottomAnchor:SetPoint("TOPLEFT", block.checkbox, "BOTTOMLEFT", 0, 0)
      end
    end

    -- Per-block widget syncing from state. Each branch only runs when its
    -- editor is visible; hidden editors don't need their widgets updated.
    if fState and fState.enabled then
      if block.key == "zone" then
        -- Tear down old rows and rebuild from state. Cheap — typically 0-3
        -- zones per watcher — and avoids stale per-row closures pointing
        -- into a previous index of state.mapIDs.
        for _, row in ipairs(block.rows or {}) do
          row.text:Hide();      row.text:SetParent(nil)
          row.removeBtn:Hide(); row.removeBtn:SetParent(nil)
        end
        block.rows = {}
        local prev
        for idx, mapID in ipairs(fState.mapIDs or {}) do
          local rowFrame = CreateFrame("Frame", nil, block.rowsArea)
          rowFrame:SetSize(INNER_WIDTH - 40, 18)
          if idx == 1 then
            rowFrame:SetPoint("TOPLEFT", 0, 0)
          else
            rowFrame:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -4)
          end
          local name = (C_Map and C_Map.GetMapInfo) and (function()
            local ok, info = pcall(C_Map.GetMapInfo, mapID)
            if ok and type(info) == "table" and info.name then return info.name end
            return nil
          end)() or string.format(L.LIST_ROW_PLACEHOLDER_MAP_ID_FMT, mapID)
          local txt = rowFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
          txt:SetPoint("LEFT", 0, 0)
          txt:SetText(name .. " " .. colored(string.format(L.EDIT_FILTER_ZONE_ROW_ID_FMT, mapID), COLOR_SOFT))

          local rm = CreateFrame("Button", nil, rowFrame, "UIPanelButtonTemplate")
          rm:SetSize(24, 18)
          rm:SetText("X")
          rm:SetPoint("RIGHT", rowFrame, "RIGHT", 0, 0)
          rm:SetScript("OnClick", function()
            if Panel.state and Panel.state.filters and Panel.state.filters.zone then
              table.remove(Panel.state.filters.zone.mapIDs, idx)
              refreshEditForm()
            end
          end)
          prev = rowFrame
          table.insert(block.rows, { text = txt, removeBtn = rm, frame = rowFrame })
        end

        -- Grow the editor to absorb the rows. The base height covers hint +
        -- add button; each row adds ~22px.
        block.editor:SetHeight((FILTER_BLOCK_HEIGHTS.zone or 80) + math.max(0, #(fState.mapIDs or {})) * 22)
        block.bottomAnchor:ClearAllPoints()
        block.bottomAnchor:SetPoint("TOPLEFT", block.editor, "BOTTOMLEFT", -20, -4)

      elseif block.key == "friends" then
        if block.dd and block.dd.SyncLabel then block.dd:SyncLabel() end

      elseif block.key == "dayOfWeek" then
        for wday, cb in pairs(block.dayChecks or {}) do
          cb:SetChecked(fState.days and fState.days[wday] and true or false)
        end

      elseif block.key == "druidForm" then
        for _, form in ipairs(Constants.DRUID_FORMS) do
          local cb = block.formChecks[form.key]
          if cb then cb:SetChecked(fState.forms and fState.forms[form.key] and true or false) end
        end
      end
    end
  end

  -- Druid filter block: hide the WHOLE block (checkbox + editor + anchor)
  -- when the player isn't a druid. Other blocks remain visible regardless
  -- of class — only the shapeshift one is class-gated.
  local isDruid = addon.Filters and addon.Filters.PlayerIsDruid and addon.Filters:PlayerIsDruid() or false
  for _, block in ipairs(f.filterBlocks or {}) do
    if block.key == "druidForm" and not isDruid then
      block.checkbox:Hide()
      block.editor:Hide()
      block.bottomAnchor:ClearAllPoints()
      -- Anchor the bottom to the previous block's bottom so the chain doesn't
      -- gap. The chain order is fixed at build time; we re-derive the
      -- previous block by walking the filterBlocks list.
      local prev
      for _, b in ipairs(f.filterBlocks) do
        if b == block then break end
        prev = b
      end
      if prev then
        block.bottomAnchor:SetPoint("TOPLEFT", prev.bottomAnchor, "BOTTOMLEFT", 0, 0)
      end
    end
  end

  Panel:updateSaveButton()

  -- Resize the scroll content to the actual bottom of the laid-out form so
  -- the scrollbar doesn't leave a huge empty area when most filters are
  -- collapsed. Deferred to the next frame because BOTTOM is anchor-derived
  -- and only resolves after the layout pass. The "last" widget depends on
  -- which tab is active: trigger tab ends at the last filter block; reply
  -- tab ends at the kick row.
  C_Timer.After(0, function()
    if not f.scrollContent then return end
    local last
    if Panel.editTab == "reply" then
      last = f.kickBlockBottom or f.kickCheck
    else
      if f.filterBlocks and #f.filterBlocks > 0 then
        last = f.filterBlocks[#f.filterBlocks].bottomAnchor
      else
        last = f.grid
      end
    end
    if not last then return end
    local cTop  = f.scrollContent:GetTop()
    local lBot  = last:GetBottom()
    if not cTop or not lBot then return end
    local used = (cTop - lBot) + 40 -- bottom padding
    if used < 200 then used = 200 end
    f.scrollContent:SetHeight(used)
  end)
end

-- ===== Save button gating =====
-- Re-evaluates the form's validity and toggles the Save button. Reads the
-- live edit-box text directly (not the in-flight Panel.state) because some
-- inputs only sync to state on focus-loss. The "what's missing" hint
-- lives as a tooltip on the disabled Save button (set up in
-- buildEditForm), so there's nothing else to render here.

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

-- ===== Multi-row reply text =====
-- Mirrors the trigger rows: each row is an InputBox + X remove button. The
-- per-row X is hidden when there is only one row so users always have
-- somewhere to type. +Add and the placeholder docs anchor downstream of
-- replyBlockBottom, which we reposition every rebuild.
function Panel:syncRepliesFromInputs()
  local f = Panel._editFrame
  if not f or not Panel.state or not f.replyRows then return end
  Panel.state.reply = Panel.state.reply or {}
  local out = {}
  for _, row in ipairs(f.replyRows) do
    table.insert(out, row.input:GetText() or "")
  end
  Panel.state.reply.texts = out
end

function Panel:rebuildReplyInputs()
  local f = Panel._editFrame
  local s = Panel.state
  if not f or not s then return end
  s.reply = s.reply or {}

  if type(s.reply.texts) ~= "table" then s.reply.texts = {} end
  if #s.reply.texts == 0 then s.reply.texts = { "" } end

  for _, row in ipairs(f.replyRows) do
    row.input:Hide();     row.input:SetParent(nil)
    row.removeBtn:Hide(); row.removeBtn:SetParent(nil)
  end
  f.replyRows = {}

  local removeBtnWidth = 24
  local rowGap         = 6
  -- Reply inputs fit within REPLY_LEFT_COL_WIDTH (the rest of the panel
  -- width is reserved for the "Reply in" dropdown next to row 1).
  local inputWidth     = REPLY_LEFT_COL_WIDTH - removeBtnWidth - rowGap - 6

  for i = 1, #s.reply.texts do
    local input = makeInput(f.replyArea, inputWidth)
    if i == 1 then
      input:SetPoint("TOPLEFT", f.replyArea, "TOPLEFT", 0, 0)
    else
      input:SetPoint("TOPLEFT", f.replyRows[i - 1].input, "BOTTOMLEFT", 0, -rowGap)
    end
    input:SetText(s.reply.texts[i] or "")
    input:SetScript("OnTextChanged", function(editBox)
      if Panel.state and Panel.state.reply and Panel.state.reply.texts then
        Panel.state.reply.texts[i] = editBox:GetText() or ""
        Panel:updateSaveButton()
      end
    end)

    local removeBtn = CreateFrame("Button", nil, f.replyArea, "UIPanelButtonTemplate")
    removeBtn:SetSize(removeBtnWidth, 22)
    removeBtn:SetText("X")
    removeBtn:SetPoint("LEFT", input, "RIGHT", rowGap, 0)
    removeBtn:SetScript("OnClick", function()
      if not Panel.state or not Panel.state.reply or not Panel.state.reply.texts then return end
      if #Panel.state.reply.texts <= 1 then return end
      Panel:syncRepliesFromInputs()
      table.remove(Panel.state.reply.texts, i)
      Panel:rebuildReplyInputs()
    end)
    if #s.reply.texts <= 1 then removeBtn:Hide() end

    table.insert(f.replyRows, { input = input, removeBtn = removeBtn })
  end

  local lastRow = f.replyRows[#f.replyRows]
  f.replyAddBtn:ClearAllPoints()
  f.replyAddBtn:SetPoint("TOPLEFT", lastRow.input, "BOTTOMLEFT", -6, -10)

  -- Reposition replyBlockBottom so downstream UI (placeholder docs, notes)
  -- flows correctly. The -2 padding aligns visually with the original
  -- single-input layout.
  f.replyBlockBottom:ClearAllPoints()
  f.replyBlockBottom:SetPoint("TOPLEFT", f.replyAddBtn, "BOTTOMLEFT", 6, -2)

  Panel:updateSaveButton()
end

-- ===== Multi-row reply emote =====
-- Each row is a dropdown + X remove button. Mirrors the reply-text pattern:
-- always at least one row, with the per-row X hidden when only one row is
-- present. Empty rows carry the EMOTE_NONE sentinel ("(none)" in the
-- dropdown); saveEdit filters those out before persisting so an "empty"
-- emote row doesn't end up as a configured emote on the watcher.
function Panel:rebuildEmoteInputs()
  local f = Panel._editFrame
  local s = Panel.state
  if not f or not s then return end
  s.reply = s.reply or {}
  if type(s.reply.emotes) ~= "table" then s.reply.emotes = {} end
  if #s.reply.emotes == 0 then s.reply.emotes = { Panel.EMOTE_NONE } end

  for _, row in ipairs(f.emoteRows) do
    row.dd:Hide();        row.dd:SetParent(nil)
    row.removeBtn:Hide(); row.removeBtn:SetParent(nil)
  end
  f.emoteRows = {}

  local removeBtnWidth = 24
  local rowGap         = 6
  local ddWidth        = 220

  for i = 1, #s.reply.emotes do
    -- Per-row option list excludes values picked by OTHER rows so the user
    -- can't end up with duplicates. EMOTE_NONE is always available — it
    -- represents "no emote in this slot" and is filtered out at save.
    local usedByOthers = {}
    for j, v in ipairs(s.reply.emotes) do
      if j ~= i and v ~= Panel.EMOTE_NONE then
        usedByOthers[v] = true
      end
    end
    local rowOptions = {}
    for _, opt in ipairs(f.emoteOptions) do
      if not usedByOthers[opt.value] then
        table.insert(rowOptions, opt)
      end
    end

    -- Each dropdown closes over `i` so its onSelect / getCurrent reach
    -- back into the array slot by index. After a row removal we rebuild the
    -- whole list so indices are always fresh — no need to update closures
    -- for surviving rows. Picking a value also rebuilds (via refreshEditForm)
    -- so siblings' filtered options refresh too.
    local dd = makeDropdown(f.emoteArea, ddWidth, rowOptions,
      function(value)
        if Panel.state and Panel.state.reply and Panel.state.reply.emotes then
          Panel.state.reply.emotes[i] = value
          Panel:rebuildEmoteInputs()
          refreshEditForm()
        end
      end,
      function()
        return Panel.state and Panel.state.reply and Panel.state.reply.emotes
          and Panel.state.reply.emotes[i]
      end)
    if i == 1 then
      dd:SetPoint("TOPLEFT", f.emoteArea, "TOPLEFT", 0, 0)
    else
      dd:SetPoint("TOPLEFT", f.emoteRows[i - 1].dd, "BOTTOMLEFT", 0, -rowGap)
    end
    if dd.SyncLabel then dd:SyncLabel() end

    local removeBtn = CreateFrame("Button", nil, f.emoteArea, "UIPanelButtonTemplate")
    removeBtn:SetSize(removeBtnWidth, 22)
    removeBtn:SetText("X")
    removeBtn:SetPoint("LEFT", dd, "RIGHT", rowGap, 0)
    removeBtn:SetScript("OnClick", function()
      if not Panel.state or not Panel.state.reply or not Panel.state.reply.emotes then return end
      if #Panel.state.reply.emotes <= 1 then return end -- always keep one row
      table.remove(Panel.state.reply.emotes, i)
      Panel:rebuildEmoteInputs()
      refreshEditForm()
    end)
    if #s.reply.emotes <= 1 then removeBtn:Hide() end

    table.insert(f.emoteRows, { dd = dd, removeBtn = removeBtn })
  end

  -- +Add anchors to the last row (always present now). emoteBlockBottom
  -- tracks just below +Add so the actions section reflows even when emote
  -- rows get added or removed.
  f.emoteAddBtn:ClearAllPoints()
  f.emoteAddBtn:SetPoint("TOPLEFT", f.emoteRows[#f.emoteRows].dd, "BOTTOMLEFT", 0, -10)

  f.emoteBlockBottom:ClearAllPoints()
  f.emoteBlockBottom:SetPoint("TOPLEFT", f.emoteAddBtn, "BOTTOMLEFT", 0, -2)
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

  -- Read live text from the in-flight reply rows (OnTextChanged only updates
  -- the row's own slot, but +Add and X also need the latest snapshot — keep
  -- this conservative and walk the row inputs directly).
  local hasReplyText = false
  if f.replyRows then
    for _, row in ipairs(f.replyRows) do
      local txt = row.input:GetText() or ""
      if txt:match("%S") then hasReplyText = true break end
    end
  end
  -- A row carrying the EMOTE_NONE sentinel doesn't count as "configured" —
  -- it's the placeholder state for the always-present first row.
  local hasEmote = false
  if type(s.reply.emotes) == "table" then
    for _, e in ipairs(s.reply.emotes) do
      if e and e ~= Panel.EMOTE_NONE then hasEmote = true break end
    end
  end
  local hasAction = hasReplyText or hasEmote or s.reply.invite or s.reply.kick

  -- The full requirements list is on the Save button's hover tooltip
  -- (set up in buildEditForm). Here we only toggle enabled-ness — the
  -- tooltip surfaces only while the button is disabled, which exactly
  -- matches "form is incomplete".
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
  Panel:syncRepliesFromInputs()

  -- Filter empty / whitespace-only phrases before persisting.
  local cleanTriggers = {}
  for _, phrase in ipairs(s.triggers) do
    local trimmed = phrase:match("^%s*(.-)%s*$") or ""
    if trimmed ~= "" then table.insert(cleanTriggers, trimmed) end
  end
  s.triggers = cleanTriggers

  -- Same filter pass for reply texts: trim each row and drop empties.
  local cleanTexts = {}
  for _, t in ipairs(s.reply.texts or {}) do
    local trimmed = (t or ""):match("^%s*(.-)%s*$") or ""
    if trimmed ~= "" then table.insert(cleanTexts, trimmed) end
  end
  s.reply.texts = cleanTexts

  -- Drop the EMOTE_NONE sentinel rows. The dispatcher reads reply.emotes
  -- straight, so a saved sentinel would be a runtime bug.
  local cleanEmotes = {}
  for _, e in ipairs(s.reply.emotes or {}) do
    if e and e ~= Panel.EMOTE_NONE then table.insert(cleanEmotes, e) end
  end
  s.reply.emotes = cleanEmotes

  -- These three checks are defensive — updateSaveButton already gates
  -- Save on the same conditions, so users normally can't reach them. If
  -- somehow they do (race / out-of-sync state), surface the reason in
  -- chat rather than silently no-op.
  if #s.triggers == 0 then
    reportSaveError(L.EDIT_ERR_NO_TRIGGER)
    return
  end
  local anyChannel = false
  for _, def in ipairs(Constants.CHANNEL_ORDER) do
    if s.channels[def.key] then anyChannel = true break end
  end
  if not anyChannel then
    reportSaveError(L.EDIT_ERR_NO_CHANNEL)
    return
  end
  local hasEmote = #s.reply.emotes > 0
  local hasAction = (#s.reply.texts > 0) or hasEmote or s.reply.invite or s.reply.kick
  if not hasAction then
    reportSaveError(L.EDIT_ERR_NO_ACTION)
    return
  end

  if s.name == "" then
    -- Auto-name with a unique placeholder
    local takenNames = {}
    for _, w in ipairs(addon.Watchers:GetAll()) do takenNames[(w.name or ""):lower()] = true end
    local n = 1
    while takenNames[string.format(L.EDIT_AUTONAME_FMT, n):lower()] do n = n + 1 end
    s.name = string.format(L.EDIT_AUTONAME_FMT, n)
  else
    -- Duplicate-name check (case-insensitive, ignoring self). Only error
    -- the user can actually hit at this point — Save can't pre-check name
    -- conflicts without rebuilding name validation into updateSaveButton.
    local lowerName = s.name:lower()
    for _, w in ipairs(addon.Watchers:GetAll()) do
      if w.id ~= s.id and (w.name or ""):lower() == lowerName then
        reportSaveError(string.format(L.EDIT_ERR_DUPLICATE_NAME_FMT, s.name))
        return
      end
    end
  end

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
  Panel:rebuildReplyInputs()
  Panel:rebuildEmoteInputs()
  -- Time inputs (one-time push from state; subsequent edits live-update via
  -- OnTextChanged). Done here rather than in refreshEditForm so re-opening
  -- the editor for the same watcher doesn't fight an in-progress edit.
  local timeBlock
  for _, block in ipairs(f.filterBlocks or {}) do
    if block.key == "timeOfDay" then timeBlock = block break end
  end
  if timeBlock then
    local t = s.filters and s.filters.timeOfDay
    if t then
      timeBlock.fromH:SetText(tostring(t.startHour or 0))
      timeBlock.fromM:SetText(string.format("%02d", t.startMin or 0))
      timeBlock.toH:SetText(tostring(t.endHour or 23))
      timeBlock.toM:SetText(string.format("%02d", t.endMin or 59))
    end
  end
  -- Cooldown numeric input
  for _, block in ipairs(f.filterBlocks or {}) do
    if block.key == "cooldown" and block.input then
      block.input:SetText(tostring((s.filters and s.filters.cooldown and s.filters.cooldown.seconds) or 60))
      break
    end
  end
  refreshEditForm()
end

enterEdit = function(id)
  if id then
    local existing = addon.Watchers:GetByID(id)
    if not existing then return end
    Panel.state = deepCopy(existing)
    Panel._editFrame.header:SetText(L.EDIT_HEADER_EDIT)
  else
    Panel.state = Constants.NEW_WATCHER_DEFAULTS()
    Panel._editFrame.header:SetText(L.EDIT_HEADER_NEW)
  end
  Panel.view = "edit"
  Panel._listFrame:Hide()
  Panel._editFrame:Show()
  populateEditWidgets()
  -- Always land on the Trigger tab when opening (or reopening) a watcher
  -- — that's the configuration users most often want to verify first.
  Panel:setEditTab("trigger")
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
