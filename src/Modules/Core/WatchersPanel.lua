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

-- Sound-picker variant of makeDropdown. Each option marked `playable = true`
-- gets a small speaker button on the right edge of its row; clicking the
-- speaker calls playFn(value) without changing selection (no menu close).
-- Selection itself is still driven by the row's radio click. Same option /
-- callback shape as makeDropdown plus the extra `playFn`.
--
-- Built on Blizzard's modern menu system (DropdownButton + SetupMenu): each
-- CreateRadio returns a description proxy whose AddInitializer hook lets us
-- attach a child Button to the row frame the framework builds. Without
-- AddInitializer we'd have to reskin the dropdown template wholesale.
local function makeSoundDropdown(parent, width, options, onSelect, getCurrent, playFn)
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
      local desc = rootDescription:CreateRadio(opt.label or tostring(value), isSelected, setSelected, value)

      if opt.playable and playFn then
        desc:AddInitializer(function(frame, description, menu)
          -- Parent the button to the row frame so it inherits show/hide
          -- with the menu and gets cleaned up on close. SetFrameLevel +1
          -- so the speaker reliably captures clicks instead of the row.
          local btn = CreateFrame("Button", nil, frame)
          btn:SetSize(16, 16)
          btn:SetPoint("RIGHT", frame, "RIGHT", -4, 0)
          btn:SetFrameLevel(frame:GetFrameLevel() + 1)

          local tex = btn:CreateTexture(nil, "ARTWORK")
          tex:SetAllPoints()
          -- Blizzard's built-in speaker icon. Same texture BigWigs uses
          -- for its sound previews so the affordance reads consistently.
          tex:SetTexture("Interface\\COMMON\\VoiceChat-Speaker")
          tex:SetVertexColor(1, 0.82, 0) -- gold; matches our COLOR_HEADING

          btn:SetScript("OnEnter", function() tex:SetVertexColor(1, 1, 1) end)
          btn:SetScript("OnLeave", function() tex:SetVertexColor(1, 0.82, 0) end)
          btn:RegisterForClicks("LeftButtonUp")
          btn:SetScript("OnClick", function()
            playFn(value)
            -- No menu close: we don't call any selection setter and the
            -- click was consumed by the button rather than the row.
          end)

          -- Reserve a bit of extra horizontal space on the row so the label
          -- text doesn't overlap the speaker.
          return frame:GetWidth(), nil
        end)
      end
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
  -- Per-phrase exactness isn't surfaced in the list row (too granular for a
  -- one-line summary) — the editor exposes it.
  local triggerLabel = L.LIST_ROW_FIELD_TRIGGER
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

  -- Notification cue + noReply gate, surfaced up top so a "sound only" watcher
  -- doesn't look like it has nothing configured. When noReply is on, the reply
  -- group below is suppressed in favor of a single "(no reply)" placeholder so
  -- the row reflects what actually happens at fire time.
  local notif       = w.notifications or {}
  local sv          = notif.sound
  local hasSound    = sv ~= nil
    and sv ~= Constants.SOUND_NONE
    and not (type(sv) == "string" and sv == "")
  local noReplyMode = notif.noReply and true or false
  if hasSound then
    -- Resolve to a label: first the curated catalogue, otherwise the raw
    -- value (FileDataID-encoded strings stripped to just the ID, LSM names
    -- shown verbatim). Numbers not in the catalogue fall back to "Sound #ID".
    local soundLabel
    for _, s in ipairs(Constants.SOUNDS) do
      if s.value == sv then soundLabel = s.label break end
    end
    if not soundLabel then
      if type(sv) == "string" then
        local fileID = sv:match("^file:(%d+)$")
        soundLabel = fileID and ("Sound #" .. fileID) or sv
      else
        soundLabel = "Sound #" .. tostring(sv)
      end
    end
    table.insert(lines, labelled(L.LIST_ROW_FIELD_NOTIFY_SOUND, soundLabel))
  end

  if noReplyMode then
    table.insert(lines, labelled(L.LIST_ROW_FIELD_REPLY, colored(L.LIST_ROW_NOTIFY_NOREPLY_SUFFIX, COLOR_SOFT)))
    return lines
  end

  local replyTexts  = (w.reply and w.reply.texts)  or {}
  local replyEmotes = (w.reply and w.reply.emotes) or {}
  local hasText     = #replyTexts  > 0
  local hasEmote    = #replyEmotes > 0

  local actionList = {}
  if w.reply and w.reply.invite      then table.insert(actionList, "group invite") end
  if w.reply and w.reply.guildInvite then table.insert(actionList, "guild invite") end
  if w.reply and w.reply.kick        then table.insert(actionList, "kick")         end
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
  elseif hasSound then
    -- Pure-notification watcher (sound only, no reply config). Skip the dash
    -- placeholder so the row doesn't read as "nothing configured".
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
  local DOT_SIZE         = 18
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

  -- Status dot replaces the right-side ACTIVE/INACTIVE text badge. Button so
  -- clicking it toggles the watcher's enabled state — duplicates the right-
  -- side Activate/Deactivate button but gives a much larger, always-visible
  -- hit target right next to the name.
  local dotLeft = leftCursor
  local statusDot = CreateFrame("Button", nil, row)
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
  statusDot:RegisterForClicks("LeftButtonUp")
  statusDot:SetScript("OnClick", function()
    addon.Watchers:SetEnabled(watcher.id, not watcher.enabled)
    refreshList()
  end)
  leftCursor = dotLeft + DOT_SIZE + 6

  local headerLeft = leftCursor
  -- Header is a Button so clicking the watcher name expands/collapses the
  -- detail block (mirrors the +/- expand button visible in minimalistic
  -- mode). The Activate/Deactivate toggle moved to the status dot to its
  -- left. The hit-area extends all the way from the name to the Edit button
  -- (anchored further down) so any blank space between the name and the
  -- right-side buttons is also clickable. The FontString stays at the
  -- LEFT, so the visible text doesn't drift even though the Button grows.
  local headerBtn = CreateFrame("Button", nil, row)
  headerBtn:SetPoint("TOPLEFT", headerLeft, 0)
  headerBtn:SetHeight(LIST_HEADER_HEIGHT)
  -- BOTTOMRIGHT is reattached to the Edit button after it's created below.

  local header = headerBtn:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  header:SetPoint("LEFT", headerBtn, "LEFT", 0, 0)
  local name = (watcher.name and watcher.name ~= "") and watcher.name or L.LIST_ROW_UNTITLED
  -- Plain text + SetTextColor (instead of colored() escape codes) so OnEnter
  -- hover styling can override the color without re-templating the string.
  header:SetText(name)
  header:SetTextColor(COLOR_NAME.r, COLOR_NAME.g, COLOR_NAME.b)

  headerBtn:RegisterForClicks("LeftButtonUp")
  headerBtn:SetScript("OnClick", function()
    -- Same effect as the +/- expand button (visible in minimalistic mode).
    -- In non-minimalistic mode the flag has no visual effect but it's still
    -- safe to flip — the state is harmless and persists for when the user
    -- switches to minimalistic.
    Panel._expanded[watcher.id] = not Panel._expanded[watcher.id]
    refreshList()
  end)
  headerBtn:SetScript("OnEnter", function()
    header:SetTextColor(1, 1, 1) -- white on hover, signals interactivity
  end)
  headerBtn:SetScript("OnLeave", function()
    header:SetTextColor(COLOR_NAME.r, COLOR_NAME.g, COLOR_NAME.b)
  end)

  -- Sound indicator: small speaker icon right of the name when the watcher
  -- has a notification sound configured. Matches the polymorphic sound
  -- value shape (kit ID / file:/lsm:) used everywhere else.
  local sv = watcher.notifications and watcher.notifications.sound
  local hasSound = sv ~= nil
    and sv ~= Constants.SOUND_NONE
    and not (type(sv) == "string" and sv == "")
  if hasSound then
    local icon = row:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", header, "RIGHT", 6, 0)
    -- VoiceChat-On is the speaker-with-soundwaves variant, reading as
    -- "audio enabled" — more legible at small sizes than the bare speaker.
    icon:SetTexture("Interface\\COMMON\\VoiceChat-On")
    icon:SetVertexColor(1, 0.82, 0) -- gold, matches COLOR_NAME / accents
  end

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

  -- Activate/Deactivate button retired — the status dot to the left of the
  -- name is now the toggle affordance (clickable, with a tooltip explaining
  -- the action). Edit + Delete remain on the right; the -109 keeps roughly
  -- the same right margin (~38 px) as the pre-removal layout so the pair
  -- doesn't crowd the panel edge.
  local editBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  editBtn:SetSize(65, 22)
  editBtn:SetPoint("TOPRIGHT", -109, -2)

  -- Now that the Edit button exists, finish anchoring the header hit-area:
  -- its right edge meets the Edit button's left, with a small gap so a
  -- careless click near Edit doesn't accidentally toggle expansion.
  headerBtn:SetPoint("BOTTOMRIGHT", editBtn, "BOTTOMLEFT", -8, 0)
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
  if tab ~= "trigger" and tab ~= "reply" and tab ~= "notify" then tab = "trigger" end
  Panel.editTab = tab

  if f.triggerPanel and f.replyPanel and f.notifyPanel then
    f.triggerPanel:SetShown(tab == "trigger")
    f.replyPanel:SetShown(tab == "reply")
    f.notifyPanel:SetShown(tab == "notify")
  end

  -- Visual state on the tab buttons. PanelTopTabButtonTemplate has its
  -- own selected/unselected texture treatment — Select hides the body
  -- texture so the tab visually merges with the content below; Deselect
  -- restores the lighter, raised look.
  if f.triggerTabBtn and f.replyTabBtn and f.notifyTabBtn then
    PanelTemplates_DeselectTab(f.triggerTabBtn)
    PanelTemplates_DeselectTab(f.replyTabBtn)
    PanelTemplates_DeselectTab(f.notifyTabBtn)
    if tab == "trigger" then
      PanelTemplates_SelectTab(f.triggerTabBtn)
    elseif tab == "reply" then
      PanelTemplates_SelectTab(f.replyTabBtn)
    else
      PanelTemplates_SelectTab(f.notifyTabBtn)
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

  local notifyTabBtn = CreateFrame("Button", nil, topBar, "PanelTopTabButtonTemplate")
  notifyTabBtn:SetID(3)
  notifyTabBtn:SetText(L.EDIT_TAB_NOTIFY)
  notifyTabBtn:SetPoint("LEFT", replyTabBtn, "RIGHT", -3, 0)
  notifyTabBtn:SetScript("OnClick", function() Panel:setEditTab("notify") end)

  frame.triggerTabBtn = triggerTabBtn
  frame.replyTabBtn   = replyTabBtn
  frame.notifyTabBtn  = notifyTabBtn

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

  local notifyPanel = CreateFrame("Frame", nil, content)
  notifyPanel:SetPoint("TOPLEFT",  content, "TOPLEFT",  0, 0)
  notifyPanel:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
  notifyPanel:SetHeight(1)
  notifyPanel:Hide()
  frame.notifyPanel = notifyPanel

  -- ===== TRIGGER tab (lives on triggerPanel) =====
  -- Sections separated by full-width rules. Each section: large gold header
  -- + muted description + controls. The tab description sits at the top.
  local triggerDesc = makeLabel(triggerPanel, L.EDIT_TRIGGER_DESC, "GameFontHighlight")
  triggerDesc:SetPoint("TOPLEFT", triggerPanel, "TOPLEFT", LEFT_MARGIN, -10)
  triggerDesc:SetWidth(INNER_WIDTH)
  triggerDesc:SetJustifyH("LEFT")

  -- ----- Name section -----
  local nameSep = makeFullSeparator(triggerPanel, triggerDesc, -16)

  local nameHeader = makeHeader(triggerPanel, L.EDIT_NAME_LABEL)
  nameHeader:SetPoint("LEFT", triggerPanel, "LEFT", LEFT_MARGIN, 0)
  nameHeader:SetPoint("TOP",  nameSep, "BOTTOM", 0, -10)

  local nameDesc = makeMutedLabel(triggerPanel, L.EDIT_NAME_DESC)
  nameDesc:SetPoint("TOPLEFT", nameHeader, "BOTTOMLEFT", 0, -4)
  nameDesc:SetWidth(INNER_WIDTH)
  nameDesc:SetJustifyH("LEFT")

  local nameInput = makeInput(triggerPanel, INNER_WIDTH)
  nameInput:SetPoint("TOPLEFT", nameDesc, "BOTTOMLEFT", 0, -8)
  nameInput:SetScript("OnTextChanged", function(self)
    if Panel.state then Panel.state.name = self:GetText() or "" end
    -- Live-update the edit-form's top-bar title so it tracks the name input.
    if not Panel._isNewWatcher and Panel._updateEditHeader then
      Panel._updateEditHeader(false)
    end
    Panel:updateSaveButton()
  end)
  frame.nameInput = nameInput

  -- ----- Trigger phrases section -----
  -- One phrase per dynamic input row so a phrase can contain a comma (no CSV
  -- splitting). Rows are rebuilt by rebuildTriggerInputs() whenever the
  -- trigger list changes; +Add appends a new empty row, the per-row X removes
  -- that row. Each row also carries its own "Case sensitive" and "Exact
  -- match" toggles (per-trigger) directly beneath the input.
  local trigSep = makeFullSeparator(triggerPanel, nameInput, -18)

  local trigHeader = makeHeader(triggerPanel, L.EDIT_PHRASES_LABEL)
  trigHeader:SetPoint("LEFT", triggerPanel, "LEFT", LEFT_MARGIN, 0)
  trigHeader:SetPoint("TOP",  trigSep, "BOTTOM", 0, -10)

  local trigDesc = makeMutedLabel(triggerPanel, L.EDIT_PHRASES_DESC)
  trigDesc:SetPoint("TOPLEFT", trigHeader, "BOTTOMLEFT", 0, -4)
  trigDesc:SetWidth(INNER_WIDTH)
  trigDesc:SetJustifyH("LEFT")

  -- Column layout for the grid of trigger rows. The X (remove) button sits
  -- right after the input — they belong together as "this row" — while the
  -- modifier checkboxes (Case sensitive, Exact match) are pushed all the
  -- way to the panel's right edge. All per-row widgets and the column
  -- header labels share these positions so the headers line up with the
  -- column they describe.
  local TRIG_PHRASE_W   = 410                   -- input width
  local TRIG_REMOVE_X   = TRIG_PHRASE_W + 8     -- left edge of X, snug against input
  local TRIG_EXACT_X    = INNER_WIDTH - 10      -- left edge of the exact-match checkbox
  local TRIG_CASE_X     = TRIG_EXACT_X - 64     -- left edge of the case-sensitive checkbox
  local TRIG_CB_VIS_W   = 24                   -- approximate visible checkbox width
  frame.trigCols = {
    phraseW  = TRIG_PHRASE_W,
    caseX    = TRIG_CASE_X,
    exactX   = TRIG_EXACT_X,
    removeX  = TRIG_REMOVE_X,
  }

  -- Column header row sits above the first input. Small font, centered over
  -- each column. The checkbox labels wrap to two lines (literal "\n" in the
  -- string) so they fit the column width without bleeding sideways.
  local trigColHeader = CreateFrame("Frame", nil, triggerPanel)
  trigColHeader:SetPoint("TOPLEFT", trigDesc, "BOTTOMLEFT", 0, -8)
  trigColHeader:SetHeight(28)
  trigColHeader:SetWidth(TRIG_REMOVE_X + 30)

  -- The InputBoxTemplate's Left texture overhangs the frame by ~5 px, so
  -- the input's *visible* left sits a few pixels left of its frame's LEFT.
  -- Nudge the Phrase header left to line up with that visible edge — the
  -- column header now reads as a column over the input, not floating
  -- between it and the +Add phrase button below.
  local phraseColLabel = trigColHeader:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  phraseColLabel:SetPoint("LEFT", trigColHeader, "LEFT", -5, 0)
  phraseColLabel:SetText(L.EDIT_PHRASES_COL_PHRASE)

  local function makeColLabel(x, text)
    local fs = trigColHeader:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", trigColHeader, "LEFT", x + TRIG_CB_VIS_W / 2 - 35, 0)
    fs:SetSize(70, 28)
    fs:SetJustifyH("CENTER")
    fs:SetJustifyV("MIDDLE")
    fs:SetSpacing(1)
    fs:SetText(text)
    return fs
  end
  makeColLabel(TRIG_CASE_X,  L.EDIT_PHRASES_COL_CASE)
  makeColLabel(TRIG_EXACT_X, L.EDIT_PHRASES_COL_EXACT)

  local trigArea = CreateFrame("Frame", nil, triggerPanel)
  trigArea:SetPoint("TOPLEFT", trigColHeader, "BOTTOMLEFT", 0, -4)
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

  -- ----- Channels section -----
  -- 2-column grid: w/b/s/e/(em) on the left, p/r/i on the right, "Only when
  -- leader/assist" tucked into the right column at row 4 so it sits next to
  -- the group channels (p/r/i) it actually gates.
  local chSep = makeFullSeparator(triggerPanel, trigAddBtn, -18)

  local chHeader = makeHeader(triggerPanel, L.EDIT_CHANNELS_LABEL)
  chHeader:SetPoint("LEFT", triggerPanel, "LEFT", LEFT_MARGIN, 0)
  chHeader:SetPoint("TOP",  chSep, "BOTTOM", 0, -10)

  local chDesc = makeMutedLabel(triggerPanel, L.EDIT_CHANNELS_DESC)
  chDesc:SetPoint("TOPLEFT", chHeader, "BOTTOMLEFT", 0, -4)
  chDesc:SetWidth(INNER_WIDTH)
  chDesc:SetJustifyH("LEFT")

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
  grid:SetPoint("TOPLEFT", chDesc, "BOTTOMLEFT", 0, -8)
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

  -- ===== REPLY tab (lives on replyPanel) =====
  -- Same section pattern as the Trigger tab: tab description, then sections
  -- separated by full-width rules. Each section: large gold header + muted
  -- description + controls.
  local replyDesc = makeLabel(replyPanel, L.EDIT_REPLY_DESC, "GameFontHighlight")
  replyDesc:SetPoint("TOPLEFT", replyPanel, "TOPLEFT", LEFT_MARGIN, -10)
  replyDesc:SetWidth(INNER_WIDTH)
  replyDesc:SetJustifyH("LEFT")

  -- ----- Text reply section -----
  local replyTextSep = makeFullSeparator(replyPanel, replyDesc, -16)

  local replyLabel = makeHeader(replyPanel, L.EDIT_REPLY_TEXT_LABEL)
  replyLabel:SetPoint("LEFT", replyPanel, "LEFT", LEFT_MARGIN, 0)
  replyLabel:SetPoint("TOP",  replyTextSep, "BOTTOM", 0, -10)

  local replyDescText = makeMutedLabel(replyPanel, L.EDIT_REPLY_TEXT_DESC)
  replyDescText:SetPoint("TOPLEFT", replyLabel, "BOTTOMLEFT", 0, -4)
  -- Narrower than the trigger-tab descriptions because the right column
  -- (the "Reply in" dropdown) eats into the panel's horizontal budget.
  replyDescText:SetWidth(REPLY_LEFT_COL_WIDTH)
  replyDescText:SetJustifyH("LEFT")

  -- replyArea anchors the FIRST reply row only; rebuildReplyInputs chains
  -- the rest from each previous row. replyBlockBottom is a 1×1 placeholder
  -- frame that the rebuild repositions to sit right below the +Add button,
  -- so anything anchored to it (placeholders / notes) reflows automatically.
  local replyArea = CreateFrame("Frame", nil, replyPanel)
  replyArea:SetPoint("TOPLEFT", replyDescText, "BOTTOMLEFT", 0, -6)
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
  placeholderHeader:SetPoint("TOPLEFT", replyBlockBottom, "BOTTOMLEFT", 0, -8)

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

  -- ----- Emote reply section -----
  -- emoteOptions is shared across all dropdown rows. Each row builds its own
  -- DropdownButton but reuses this option list to avoid copying 250+ entries
  -- per row. The "(none)" sentinel sits at the top so the first row reads as
  -- "no emote yet" by default — saveEdit drops EMOTE_NONE entries before
  -- persisting, mirroring how empty reply-text rows are dropped.
  local emoteSep = makeFullSeparator(replyPanel, noteEmoteLine, -18)

  local emoteLabel = makeHeader(replyPanel, L.EDIT_REPLY_EMOTE_LABEL)
  emoteLabel:SetPoint("LEFT", replyPanel, "LEFT", LEFT_MARGIN, 0)
  emoteLabel:SetPoint("TOP",  emoteSep, "BOTTOM", 0, -10)

  local emoteDescText = makeMutedLabel(replyPanel, L.EDIT_REPLY_EMOTE_DESC)
  emoteDescText:SetPoint("TOPLEFT", emoteLabel, "BOTTOMLEFT", 0, -4)
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

  -- ----- Actions to do section -----
  -- Each action is a checkbox with its description on the line BELOW (full
  -- width muted label) rather than inline to the right of the label. Reads
  -- more naturally when descriptions wrap to multiple lines.
  local actionsSep = makeFullSeparator(replyPanel, emoteBlockBottom, -18)

  local actionsHeader = makeHeader(replyPanel, L.EDIT_ACTIONS_LABEL)
  actionsHeader:SetPoint("LEFT", replyPanel, "LEFT", LEFT_MARGIN, 0)
  actionsHeader:SetPoint("TOP",  actionsSep, "BOTTOM", 0, -10)

  local actionsDesc = makeMutedLabel(replyPanel, L.EDIT_ACTIONS_DESC)
  actionsDesc:SetPoint("TOPLEFT", actionsHeader, "BOTTOMLEFT", 0, -4)
  actionsDesc:SetWidth(INNER_WIDTH)
  actionsDesc:SetJustifyH("LEFT")

  -- Helper: anchors a full-width muted description directly below a
  -- checkbox. Returns the description so callers can show/hide it together
  -- with the checkbox in the invite-cascade logic.
  local function descBelow(check, text, leftIndent)
    local d = makeMutedLabel(replyPanel, text)
    d:SetPoint("TOPLEFT", check, "BOTTOMLEFT", leftIndent or 24, -2)
    d:SetPoint("RIGHT",   replyPanel, "RIGHT", -20, 0)
    d:SetJustifyH("LEFT")
    return d
  end

  -- Group invite block (party / raid).
  local inviteCheck = makeCheckbox(replyPanel, L.EDIT_INVITE_LABEL)
  inviteCheck:SetPoint("TOPLEFT", actionsDesc, "BOTTOMLEFT", 0, -10)
  inviteCheck:SetScript("OnClick", function(self)
    if Panel.state then
      Panel.state.reply.invite = self:GetChecked() and true or false
      refreshEditForm()
    end
  end)
  frame.inviteCheck = inviteCheck
  frame.inviteDesc  = descBelow(inviteCheck, L.EDIT_INVITE_DESC)

  -- Sub-rows live at +20 indent from the parent "Group invite" to read as a
  -- sub-group. Each sub-row also gets a description on the line below it.
  local inviteConfirmCheck = makeCheckbox(replyPanel, L.EDIT_INVITE_CONFIRM_LABEL)
  inviteConfirmCheck:SetPoint("TOPLEFT", frame.inviteDesc, "BOTTOMLEFT", 20, -6)
  inviteConfirmCheck:SetScript("OnClick", function(self)
    if Panel.state then
      Panel.state.reply.inviteConfirm = self:GetChecked() and true or false
      refreshEditForm()
    end
  end)
  frame.inviteConfirmCheck = inviteConfirmCheck
  frame.inviteConfirmDesc  = descBelow(inviteConfirmCheck, L.EDIT_INVITE_CONFIRM_DESC)

  local inviteQueueCheck = makeCheckbox(replyPanel, L.EDIT_INVITE_QUEUE_LABEL)
  -- inviteConfirmDesc sits at +24 from inviteConfirmCheck (descBelow's
  -- default left indent); walk back -24 so the Queue checkbox lines up
  -- horizontally with "Confirm before inviting" above it.
  inviteQueueCheck:SetPoint("TOPLEFT", frame.inviteConfirmDesc, "BOTTOMLEFT", -24, -6)
  inviteQueueCheck:SetScript("OnClick", function(self)
    if Panel.state then Panel.state.reply.inviteQueue = self:GetChecked() and true or false end
  end)
  frame.inviteQueueCheck = inviteQueueCheck
  frame.inviteQueueDesc  = descBelow(inviteQueueCheck, L.EDIT_INVITE_QUEUE_DESC)

  -- Anchor for the guild-invite + kick blocks - collapses up when the invite
  -- sub-tree is hidden so downstream rows don't float in empty space. The
  -- block bottom now points at the bottom description (descriptions are
  -- below-the-checkbox in this layout, not inline).
  local afterInvite = CreateFrame("Frame", nil, replyPanel)
  afterInvite:SetSize(1, 1)
  frame.afterInvite       = afterInvite
  frame.inviteBlockBottom = frame.inviteQueueDesc
  frame.inviteBlockTop    = frame.inviteDesc

  -- Guild invite block. Sibling action to the party invite above — separate
  -- because guild invite has different gating (IsInGuild + CanGuildInvite)
  -- and a different runtime path (C_GuildInfo.Invite, not party invite).
  -- Hidden when the player isn't in a guild; refreshEditForm syncs that
  -- state on every redraw so joining/leaving updates the UI.
  local guildInviteCheck = makeCheckbox(replyPanel, L.EDIT_GUILD_INVITE_LABEL)
  guildInviteCheck:SetPoint("TOPLEFT", afterInvite, "BOTTOMLEFT", 0, 0)
  guildInviteCheck:SetScript("OnClick", function(self)
    if Panel.state then
      Panel.state.reply.guildInvite = self:GetChecked() and true or false
      refreshEditForm()
    end
  end)
  frame.guildInviteCheck = guildInviteCheck
  frame.guildInviteDesc  = descBelow(guildInviteCheck, L.EDIT_GUILD_INVITE_DESC)

  -- afterGuildInvite anchors the Kick block; collapses up when guild invite
  -- is hidden (e.g. player not in a guild).
  local afterGuildInvite = CreateFrame("Frame", nil, replyPanel)
  afterGuildInvite:SetSize(1, 1)
  frame.afterGuildInvite = afterGuildInvite

  -- Kick block
  local kickCheck = makeCheckbox(replyPanel, L.EDIT_KICK_LABEL)
  kickCheck:SetPoint("TOPLEFT", afterGuildInvite, "BOTTOMLEFT", 0, 0)
  kickCheck:SetScript("OnClick", function(self)
    if Panel.state then
      Panel.state.reply.kick = self:GetChecked() and true or false
      refreshEditForm()
    end
  end)
  frame.kickCheck = kickCheck

  frame.kickBlockBottom = descBelow(kickCheck, L.EDIT_KICK_DESC)

  -- ===== FILTERS section (lives on triggerPanel) =====
  -- Filters gate WHEN the trigger fires, so they belong with the trigger
  -- group, not the reply. Optional gates layered on top of the channel +
  -- trigger match — each filter has a checkbox that reveals its editor,
  -- shown/hidden in refreshEditForm. Off filters don't enforce anything.
  -- Separator ABOVE the section header (matches the rest of the tab's
  -- section pattern). The -18 absorbs the bottom padding of the channels grid.
  local filtersSep = makeFullSeparator(triggerPanel, grid, -18)

  local filtersHeader = makeHeader(triggerPanel, L.EDIT_FILTERS_HEADER)
  filtersHeader:SetPoint("LEFT", triggerPanel, "LEFT", LEFT_MARGIN, 0)
  filtersHeader:SetPoint("TOP",  filtersSep, "BOTTOM", 0, -10)

  local filtersDesc = makeMutedLabel(triggerPanel, L.EDIT_FILTERS_DESC)
  filtersDesc:SetPoint("TOPLEFT", filtersHeader, "BOTTOMLEFT", 0, -4)
  filtersDesc:SetWidth(INNER_WIDTH)
  filtersDesc:SetJustifyH("LEFT")

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
  -- First filter block chains off the section's description; later blocks
  -- chain off each previous block's bottomAnchor in turn.
  local lastFilterBottom = filtersDesc

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

  -- ===== NOTIFICATIONS section (lives on notifyPanel) =====
  -- Layout follows the shared section pattern: tab description at top, then
  -- sections separated by full-width rules. Each section has a large gold
  -- header + a muted description + its controls. The "No reply needed"
  -- toggle is pinned at the top (under the tab description) as a quick
  -- access switch — promoting it visually since it changes runtime behavior
  -- significantly.
  local notifyDesc = makeLabel(notifyPanel, L.EDIT_NOTIFY_DESC, "GameFontHighlight")
  notifyDesc:SetPoint("TOPLEFT", notifyPanel, "TOPLEFT", LEFT_MARGIN, -10)
  notifyDesc:SetWidth(INNER_WIDTH)
  notifyDesc:SetJustifyH("LEFT")

  -- ----- No reply needed (top-of-tab quick toggle) -----
  local noReplyCheck = makeCheckbox(notifyPanel, L.EDIT_NOTIFY_NOREPLY_LABEL)
  noReplyCheck:SetPoint("TOPLEFT", notifyDesc, "BOTTOMLEFT", 0, -16)
  noReplyCheck:SetScript("OnClick", function(self)
    if Panel.state and Panel.state.notifications then
      Panel.state.notifications.noReply = self:GetChecked() and true or false
      Panel:updateSaveButton()
    end
  end)
  frame.notifyNoReplyCheck = noReplyCheck

  local noReplyDesc = makeMutedLabel(notifyPanel, L.EDIT_NOTIFY_NOREPLY_DESC)
  noReplyDesc:SetPoint("TOPLEFT", noReplyCheck, "BOTTOMLEFT", 0, -4)
  noReplyDesc:SetWidth(INNER_WIDTH)
  noReplyDesc:SetJustifyH("LEFT")

  -- ----- Sound section -----
  local soundSep = makeFullSeparator(notifyPanel, noReplyDesc, -16)

  local soundHeader = makeHeader(notifyPanel, L.EDIT_NOTIFY_SOUND_LABEL)
  soundHeader:SetPoint("LEFT", notifyPanel, "LEFT", LEFT_MARGIN, 0)
  soundHeader:SetPoint("TOP",  soundSep, "BOTTOM", 0, -10)

  local soundDescText = makeMutedLabel(notifyPanel, L.EDIT_NOTIFY_SOUND_DESC)
  soundDescText:SetPoint("TOPLEFT", soundHeader, "BOTTOMLEFT", 0, -4)
  soundDescText:SetWidth(INNER_WIDTH)
  soundDescText:SetJustifyH("LEFT")

  -- Returns true when there's an actually-playable sound configured.
  -- Value shape mirrors Constants.SOUNDS:
  --   number != SOUND_NONE -> SoundKit ID
  --   string "file:<id>"   -> FileDataID
  --   other non-empty str  -> LSM media name
  local function isPlayableSound(value)
    if value == nil or value == Constants.SOUND_NONE then return false end
    if type(value) == "number" then return value ~= Constants.SOUND_NONE end
    if type(value) == "string" then return value ~= "" end
    return false
  end
  frame.isPlayableSound = isPlayableSound

  -- Plays the configured sound via the right API. Mirrors the dispatcher
  -- in Watchers.lua exactly so the in-editor preview matches the in-game
  -- behavior. pcall-wrapped so a bad value never throws into the UI.
  local function playSoundValue(value)
    if not isPlayableSound(value) then return end
    if type(value) == "number" then
      pcall(PlaySound, value, "Master")
      return
    end
    if type(value) == "string" then
      local fileID = value:match("^file:(%d+)$")
      if fileID then
        pcall(PlaySoundFile, tonumber(fileID), "Master")
        return
      end
      local LSM
      pcall(function() LSM = LibStub and LibStub("LibSharedMedia-3.0", true) end)
      if not LSM then return end
      local path
      pcall(function() path = LSM:Fetch("sound", value) end)
      if path and path ~= "" then
        pcall(PlaySoundFile, path, "Master")
      end
    end
  end
  frame.playSoundValue = playSoundValue

  -- Sound options: built-ins from Constants.SOUNDS plus any LSM-registered
  -- sounds, merged into one alphabetical list with "(none)" pinned at the
  -- top. LSM probe is soft: when LSM isn't installed, only the built-ins
  -- show. No "LSM:" prefix on labels — the source isn't user-relevant.
  local soundOptions = { { value = Constants.SOUND_NONE, label = "(none)" } }
  local merged = {}
  for _, s in ipairs(Constants.SOUNDS) do
    table.insert(merged, { value = s.value, label = s.label, playable = true })
  end
  do
    local LSM
    pcall(function() LSM = LibStub and LibStub("LibSharedMedia-3.0", true) end)
    if LSM and LSM.HashTable then
      local ht = LSM:HashTable("sound")
      if type(ht) == "table" then
        for name in pairs(ht) do
          table.insert(merged, { value = name, label = name, playable = true })
        end
      end
    end
  end
  table.sort(merged, function(a, b) return a.label:lower() < b.label:lower() end)
  for _, opt in ipairs(merged) do table.insert(soundOptions, opt) end

  local soundDd = makeSoundDropdown(notifyPanel, 220, soundOptions,
    function(value)
      if Panel.state and Panel.state.notifications then
        Panel.state.notifications.sound = value
        -- Full refresh so the Test button's enabled-state updates alongside
        -- the dropdown label.
        refreshEditForm()
      end
    end,
    function()
      return Panel.state and Panel.state.notifications and Panel.state.notifications.sound
    end,
    playSoundValue)
  soundDd:SetPoint("TOPLEFT", soundDescText, "BOTTOMLEFT", 0, -8)
  frame.notifySoundDd = soundDd

  local testBtn = CreateFrame("Button", nil, notifyPanel, "UIPanelButtonTemplate")
  testBtn:SetSize(70, 22)
  testBtn:SetPoint("LEFT", soundDd, "RIGHT", 10, 0)
  testBtn:SetText(L.EDIT_NOTIFY_SOUND_TEST_BTN)
  testBtn:SetScript("OnClick", function()
    if not Panel.state or not Panel.state.notifications then return end
    playSoundValue(Panel.state.notifications.sound)
  end)
  frame.notifyTestBtn = testBtn

  -- ----- Coloring section -----
  -- One row per trigger phrase, rebuilt every refreshEditForm so changes on
  -- the Trigger tab (add/remove/edit) flow into the row list. Each row lets
  -- the user pick an explicit hex color, open the WoW ColorPicker, or check
  -- "Class color" to use the player's class color at render time.
  local coloringSep = makeFullSeparator(notifyPanel, soundDd, -18)

  local coloringHeader = makeHeader(notifyPanel, L.EDIT_NOTIFY_COLORING_HEADER)
  coloringHeader:SetPoint("LEFT", notifyPanel, "LEFT", LEFT_MARGIN, 0)
  coloringHeader:SetPoint("TOP",  coloringSep, "BOTTOM", 0, -10)

  local coloringDesc = makeMutedLabel(notifyPanel, L.EDIT_NOTIFY_COLORING_DESC)
  coloringDesc:SetPoint("TOPLEFT", coloringHeader, "BOTTOMLEFT", 0, -4)
  coloringDesc:SetWidth(INNER_WIDTH)
  coloringDesc:SetJustifyH("LEFT")

  -- Anchor for the first coloring row. rebuildColoringRows chains the rest
  -- off each previous row. The empty hint sits at the same anchor for when
  -- the watcher has no trigger phrases yet.
  local coloringArea = CreateFrame("Frame", nil, notifyPanel)
  coloringArea:SetPoint("TOPLEFT", coloringDesc, "BOTTOMLEFT", 0, -10)
  coloringArea:SetSize(INNER_WIDTH, 1)
  frame.coloringArea = coloringArea
  frame.coloringRows = {}

  local coloringEmpty = makeMutedLabel(notifyPanel, L.EDIT_NOTIFY_COLORING_EMPTY)
  coloringEmpty:SetPoint("TOPLEFT", coloringArea, "TOPLEFT", 0, 0)
  coloringEmpty:SetWidth(INNER_WIDTH)
  coloringEmpty:SetJustifyH("LEFT")
  coloringEmpty:Hide()
  frame.coloringEmptyHint = coloringEmpty

  -- A 1x1 placeholder that rebuildColoringRows repositions to sit just below
  -- the last row. Anything below the Coloring section (currently nothing,
  -- but reserved for future use) anchors to this so the layout reflows.
  local coloringBottom = CreateFrame("Frame", nil, notifyPanel)
  coloringBottom:SetSize(1, 1)
  coloringBottom:SetPoint("TOPLEFT", coloringArea, "TOPLEFT", 0, 0)
  frame.coloringBottom = coloringBottom

  frame.notifyBlockBottom = coloringBottom

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
  -- the invite block, not standalone text). afterInvite uses split LEFT/TOP
  -- anchors so x is fixed at the section's left margin while y tracks the
  -- bottom-most visible widget of the invite block.
  f.inviteCheck:SetChecked(s.reply.invite and true or false)
  f.afterInvite:ClearAllPoints()
  f.afterInvite:SetPoint("LEFT", f.replyPanel, "LEFT", LEFT_MARGIN, 0)
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
    f.afterInvite:SetPoint("TOP", f.inviteBlockBottom, "BOTTOM", 0, -10)
  else
    f.inviteConfirmCheck:Hide()
    f.inviteConfirmDesc:Hide()
    f.inviteQueueCheck:Hide()
    f.inviteQueueDesc:Hide()
    f.afterInvite:SetPoint("TOP", f.inviteBlockTop, "BOTTOM", 0, -10)
  end

  -- Guild invite is gated on guild membership. When the player isn't in a
  -- guild we hide both the checkbox and its inline description, force the
  -- state off (so a watcher set up while guilded doesn't silently fire a
  -- no-op invite after the user leaves), and collapse afterGuildInvite up
  -- to afterInvite so the Kick row tucks back under the (party) Invite block.
  f.afterGuildInvite:ClearAllPoints()
  f.afterGuildInvite:SetPoint("LEFT", f.replyPanel, "LEFT", LEFT_MARGIN, 0)
  if IsInGuild() then
    f.guildInviteCheck:Show()
    if f.guildInviteDesc then f.guildInviteDesc:Show() end
    f.guildInviteCheck:SetChecked(s.reply.guildInvite and true or false)
    -- Anchor below the guild-invite description so the kick row clears it.
    f.afterGuildInvite:SetPoint("TOP", f.guildInviteDesc or f.guildInviteCheck, "BOTTOM", 0, -10)
  else
    s.reply.guildInvite = false
    f.guildInviteCheck:Hide()
    if f.guildInviteDesc then f.guildInviteDesc:Hide() end
    f.afterGuildInvite:SetPoint("TOP", f.afterInvite, "TOP", 0, 0)
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

  -- Notifications tab (state -> widgets). Cheap one-way sync; the widgets
  -- themselves push back to state in their OnClick / dropdown callbacks.
  s.notifications = s.notifications or { sound = Constants.SOUND_NONE, noReply = false }
  if f.notifySoundDd and f.notifySoundDd.SyncLabel then f.notifySoundDd:SyncLabel() end
  if f.notifyNoReplyCheck then
    f.notifyNoReplyCheck:SetChecked(s.notifications.noReply and true or false)
  end

  -- Reply tab title reflects whether the reply config is honored at runtime.
  -- When noReply is on, the reply tab is bypassed — grey the tab name and
  -- attach a tooltip explaining why. The tab is still clickable so the user
  -- can inspect / edit the reply config, it just won't fire while noReply
  -- stays on.
  if f.replyTabBtn then
    local fs = f.replyTabBtn.Text or (f.replyTabBtn.GetFontString and f.replyTabBtn:GetFontString())
    if s.notifications.noReply then
      if fs then fs:SetTextColor(0.55, 0.55, 0.55) end
      setTooltip(f.replyTabBtn,
        L.EDIT_TAB_REPLY_DISABLED_TOOLTIP_TITLE,
        L.EDIT_TAB_REPLY_DISABLED_TOOLTIP_DESC)
    else
      if fs then fs:SetTextColor(1, 0.82, 0) end -- default tab gold
      -- Clear the tooltip handlers so hovering doesn't show a stale message.
      f.replyTabBtn:SetScript("OnEnter", nil)
      f.replyTabBtn:SetScript("OnLeave", nil)
    end
  end
  if f.notifyTestBtn then
    local playable = f.isPlayableSound and f.isPlayableSound(s.notifications.sound) or false
    if playable then f.notifyTestBtn:Enable() else f.notifyTestBtn:Disable() end
  end

  -- Coloring rows mirror the live trigger list. Rebuilding every refresh is
  -- cheap (typically 1-3 phrases per watcher) and avoids needing per-row
  -- tab-switch wiring.
  Panel:rebuildColoringRows()

  Panel:updateSaveButton()

  -- Resize the scroll content to the actual bottom of the laid-out form so
  -- the scrollbar doesn't leave a huge empty area when most filters are
  -- collapsed. Deferred to the next frame because BOTTOM is anchor-derived
  -- and only resolves after the layout pass. The "last" widget depends on
  -- which tab is active: trigger tab ends at the last filter block; reply
  -- tab ends at the kick row; notify tab ends at the noReply checkbox.
  C_Timer.After(0, function()
    if not f.scrollContent then return end
    local last
    if Panel.editTab == "reply" then
      last = f.kickBlockBottom or f.kickCheck
    elseif Panel.editTab == "notify" then
      last = f.notifyBlockBottom or f.notifyNoReplyCheck
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
  s.triggerCaseSensitive = s.triggerCaseSensitive or {}
  s.triggerExact         = s.triggerExact or {}

  -- Tear down every previous row.
  for _, row in ipairs(f.trigRows) do
    for _, w in ipairs(row.widgets) do
      w:Hide(); w:SetParent(nil)
    end
  end
  f.trigRows = {}

  local cols = f.trigCols
  local removeBtnWidth = 24
  local rowChainGap    = 8 -- vertical gap between successive rows

  for i = 1, #s.triggers do
    -- ----- Phrase input -----
    local input = makeInput(f.trigArea, cols.phraseW)
    if i == 1 then
      input:SetPoint("TOPLEFT", f.trigArea, "TOPLEFT", 0, 0)
    else
      input:SetPoint("TOPLEFT", f.trigRows[i - 1].input, "BOTTOMLEFT", 0, -rowChainGap)
    end
    input:SetText(s.triggers[i] or "")
    input:SetScript("OnTextChanged", function(editBox)
      if Panel.state and Panel.state.triggers then
        Panel.state.triggers[i] = editBox:GetText() or ""
        Panel:updateSaveButton()
      end
    end)

    -- ----- Case-sensitive checkbox (no inline label — column header above) -----
    -- Anchor LEFT-to-RIGHT against the input so the checkbox's vertical
    -- centre lines up with the input's vertical centre (rather than TOP
    -- aligning, which left the checkbox visually high above the input).
    local caseCheck = makeCheckbox(f.trigArea, "")
    caseCheck:SetPoint("LEFT", input, "RIGHT", cols.caseX - cols.phraseW, 0)
    caseCheck:SetChecked(s.triggerCaseSensitive[i] and true or false)
    caseCheck:SetScript("OnClick", function(self)
      if not Panel.state then return end
      Panel.state.triggerCaseSensitive = Panel.state.triggerCaseSensitive or {}
      Panel.state.triggerCaseSensitive[i] = self:GetChecked() and true or false
    end)
    setTooltip(caseCheck, L.EDIT_PHRASE_CASE_TOOLTIP_TITLE, L.EDIT_PHRASE_CASE_TOOLTIP_DESC)

    -- ----- Exact match checkbox (no inline label) -----
    local exactCheck = makeCheckbox(f.trigArea, "")
    exactCheck:SetPoint("LEFT", input, "RIGHT", cols.exactX - cols.phraseW, 0)
    exactCheck:SetChecked(s.triggerExact[i] and true or false)
    exactCheck:SetScript("OnClick", function(self)
      if not Panel.state then return end
      Panel.state.triggerExact = Panel.state.triggerExact or {}
      Panel.state.triggerExact[i] = self:GetChecked() and true or false
      Panel:updateSaveButton()
    end)
    setTooltip(exactCheck, L.EDIT_EXACT_LABEL, L.EDIT_EXACT_DESC)

    -- ----- X remove button -----
    local removeBtn = CreateFrame("Button", nil, f.trigArea, "UIPanelButtonTemplate")
    removeBtn:SetSize(removeBtnWidth, 22)
    removeBtn:SetText("X")
    removeBtn:SetPoint("LEFT", input, "RIGHT", cols.removeX - cols.phraseW, 0)
    removeBtn:SetScript("OnClick", function()
      if not Panel.state or not Panel.state.triggers then return end
      if #Panel.state.triggers <= 1 then return end
      Panel:syncTriggersFromInputs()
      table.remove(Panel.state.triggers, i)
      -- Keep parallel arrays index-aligned — drop the matching slot in each
      -- per-trigger array so a later phrase doesn't inherit settings.
      if Panel.state.triggerCaseSensitive then
        table.remove(Panel.state.triggerCaseSensitive, i)
      end
      if Panel.state.triggerExact then
        table.remove(Panel.state.triggerExact, i)
      end
      if Panel.state.notifications and Panel.state.notifications.triggerColors then
        table.remove(Panel.state.notifications.triggerColors, i)
      end
      Panel:rebuildTriggerInputs()
    end)
    if #s.triggers <= 1 then removeBtn:Hide() end

    table.insert(f.trigRows, {
      input = input, removeBtn = removeBtn,
      caseCheck = caseCheck, exactCheck = exactCheck,
      widgets = { input, removeBtn, caseCheck, exactCheck },
    })
  end

  local lastRow = f.trigRows[#f.trigRows]
  -- +Add button anchors below the last input — column-grid layout means we
  -- don't need to walk past per-row flag rows anymore.
  f.trigAddBtn:ClearAllPoints()
  f.trigAddBtn:SetPoint("TOPLEFT", lastRow.input, "BOTTOMLEFT", 0, -12)

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
  f.replyAddBtn:SetPoint("TOPLEFT", lastRow.input, "BOTTOMLEFT", 0, -10)

  -- Reposition replyBlockBottom so downstream UI (placeholder docs, notes)
  -- flows correctly.
  f.replyBlockBottom:ClearAllPoints()
  f.replyBlockBottom:SetPoint("TOPLEFT", f.replyAddBtn, "BOTTOMLEFT", 0, -2)

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

-- ===== Coloring rows (Notifications tab) =====
-- One row per trigger phrase, rebuilt from Panel.state.triggers. Each row
-- shows: [phrase label] [swatch] [hex input] [Class color check]. State is
-- mirrored back into Panel.state.notifications.triggerColors at index i,
-- where: nil/"" = no color, "class" = use sender class color, "RRGGBB" = hex.

local function parseHex6(text)
  if type(text) ~= "string" then return nil end
  text = text:gsub("^#", ""):gsub("%s+", ""):lower()
  if text:match("^%x%x%x%x%x%x$") then return text end
  return nil
end

local function hexToRGB01(hex)
  if not hex or #hex ~= 6 then return 1, 1, 1 end
  return tonumber(hex:sub(1, 2), 16) / 255,
         tonumber(hex:sub(3, 4), 16) / 255,
         tonumber(hex:sub(5, 6), 16) / 255
end

local function rgb01ToHex(r, g, b)
  return string.format("%02x%02x%02x",
    math.floor((r or 0) * 255 + 0.5),
    math.floor((g or 0) * 255 + 0.5),
    math.floor((b or 0) * 255 + 0.5))
end

-- Player's own class color as RGB01. Used as the swatch preview when "Class
-- color" is checked — at edit time the actual sender is unknown, but showing
-- the editor's own class color makes the affordance read as "a class color
-- will be used" rather than a neutral grey that looks like "off".
local function playerClassColor01()
  local _, englishClass = UnitClass("player")
  local rgb = englishClass and _G.RAID_CLASS_COLORS and _G.RAID_CLASS_COLORS[englishClass]
  if not rgb then return 0.7, 0.7, 0.7 end
  return rgb.r or 0.7, rgb.g or 0.7, rgb.b or 0.7
end

-- Opens Blizzard's ColorPickerFrame seeded with the row's current explicit
-- color (or white if blank), and pipes user changes back into state via
-- onPick. Uses the modern SetupColorPickerAndShow API.
local function openColorPickerForRow(currentHex, onPick)
  local r, g, b = hexToRGB01(currentHex or "ffffff")
  local previous = { r = r, g = g, b = b }
  local opts = {
    r = r, g = g, b = b,
    swatchFunc = function()
      local nr, ng, nb = ColorPickerFrame:GetColorRGB()
      onPick(rgb01ToHex(nr, ng, nb))
    end,
    cancelFunc = function()
      onPick(rgb01ToHex(previous.r, previous.g, previous.b))
    end,
    hasOpacity = false,
  }
  if ColorPickerFrame.SetupColorPickerAndShow then
    ColorPickerFrame:SetupColorPickerAndShow(opts)
  else
    -- Legacy fallback for older clients without the modern setup helper.
    ColorPickerFrame.func        = opts.swatchFunc
    ColorPickerFrame.cancelFunc  = opts.cancelFunc
    ColorPickerFrame.hasOpacity  = false
    ColorPickerFrame.previousValues = previous
    ColorPickerFrame:SetColorRGB(r, g, b)
    ShowUIPanel(ColorPickerFrame)
  end
end

function Panel:rebuildColoringRows()
  local f = Panel._editFrame
  local s = Panel.state
  if not f or not s or not f.coloringArea then return end
  s.notifications = s.notifications or {}
  s.notifications.triggerColors = s.notifications.triggerColors or {}

  -- Tear down previous rows. Each row stores its child widgets in a flat
  -- array under `.widgets` so we can hide+unparent them generically.
  for _, row in ipairs(f.coloringRows or {}) do
    for _, w in ipairs(row.widgets) do
      w:Hide(); w:SetParent(nil)
    end
  end
  f.coloringRows = {}

  -- Trim triggerColors to match the trigger count so saved data doesn't drift
  -- when phrases are removed. Out-of-range entries are dropped silently.
  for i = #s.triggers + 1, #s.notifications.triggerColors do
    s.notifications.triggerColors[i] = nil
  end

  -- Empty-state: hint sits in for the row list when no phrases are configured.
  if #s.triggers == 0 then
    f.coloringEmptyHint:Show()
    f.coloringBottom:ClearAllPoints()
    f.coloringBottom:SetPoint("TOPLEFT", f.coloringEmptyHint, "BOTTOMLEFT", 0, -2)
    return
  end
  f.coloringEmptyHint:Hide()

  local ROW_H        = 26
  local PHRASE_W     = 220
  local SWATCH_SIZE  = 18
  local HEX_W        = 70
  local prevRow

  for i, phrase in ipairs(s.triggers) do
    local row = CreateFrame("Frame", nil, f.coloringArea)
    row:SetSize(INNER_WIDTH, ROW_H)
    if i == 1 then
      row:SetPoint("TOPLEFT", f.coloringArea, "TOPLEFT", 0, 0)
    else
      row:SetPoint("TOPLEFT", prevRow, "BOTTOMLEFT", 0, -4)
    end

    -- Phrase label (truncated visually by SetWidth — full phrase fits on
    -- screen via tooltip if we wanted; for now we just clip).
    local label = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("LEFT", row, "LEFT", 0, 0)
    label:SetSize(PHRASE_W, ROW_H)
    label:SetJustifyH("LEFT")
    local displayed = (phrase ~= "" and phrase) or L.LIST_ROW_PLACEHOLDER_DASH
    label:SetText(colored(displayed, COLOR_HEADING))

    local current = s.notifications.triggerColors[i]
    local isClass = current == "class"
    local explicitHex = (type(current) == "string" and current ~= "class") and parseHex6(current) or nil

    -- Color swatch — small framed Button so we can show a border around the
    -- color square and capture clicks. The inner texture is repainted to the
    -- current hex (or grey/neutral when class color is on or unset).
    local swatchBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
    swatchBtn:SetSize(SWATCH_SIZE, SWATCH_SIZE)
    swatchBtn:SetPoint("LEFT", label, "RIGHT", 8, 0)
    swatchBtn:SetBackdrop({
      bgFile   = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = false, edgeSize = 8,
      insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })

    -- hex input
    local hexInput = CreateFrame("EditBox", nil, row, "InputBoxTemplate")
    hexInput:SetSize(HEX_W, INPUT_HEIGHT)
    hexInput:SetAutoFocus(false)
    hexInput:SetMaxLetters(7)
    hexInput:SetFontObject(ChatFontNormal)
    hexInput:SetPoint("LEFT", swatchBtn, "RIGHT", 10, 0)
    hexInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    hexInput:SetScript("OnEnterPressed",  function(self) self:ClearFocus() end)

    -- Class color checkbox
    local classCheck = makeCheckbox(row, L.EDIT_NOTIFY_COLORING_CLASS_LABEL)
    classCheck:SetPoint("LEFT", hexInput, "RIGHT", 18, 0)

    -- ----- Row state plumbing -----
    -- repaint() updates the swatch backdrop color, the hex input text, and
    -- the input's enabled state. Reads from `Panel.state.notifications.
    -- triggerColors[i]` so calling repaint after any state change just works.
    local function repaint()
      local v = Panel.state.notifications.triggerColors[i]
      local class = (v == "class")
      local hex = (type(v) == "string" and v ~= "class") and parseHex6(v) or nil

      if class then
        local cr, cg, cb = playerClassColor01()
        swatchBtn:SetBackdropColor(cr, cg, cb, 1)
        hexInput:SetText("")
        hexInput:Disable()
        if not classCheck:GetChecked() then classCheck:SetChecked(true) end
      elseif hex then
        local rr, gg, bb = hexToRGB01(hex)
        swatchBtn:SetBackdropColor(rr, gg, bb, 1)
        if hexInput:GetText() ~= hex then hexInput:SetText(hex) end
        hexInput:Enable()
        if classCheck:GetChecked() then classCheck:SetChecked(false) end
      else
        -- Neither set: neutral swatch, empty input, checkbox off.
        swatchBtn:SetBackdropColor(0.2, 0.2, 0.2, 1)
        if hexInput:GetText() ~= "" then hexInput:SetText("") end
        hexInput:Enable()
        if classCheck:GetChecked() then classCheck:SetChecked(false) end
      end
    end

    -- Seed initial visuals from saved state.
    if isClass then
      classCheck:SetChecked(true)
      hexInput:Disable()
    elseif explicitHex then
      hexInput:SetText(explicitHex)
    end
    repaint()

    swatchBtn:SetScript("OnClick", function()
      -- Class-color mode owns the swatch — clicking it shouldn't open the
      -- picker since the result wouldn't be persisted anyway.
      if Panel.state.notifications.triggerColors[i] == "class" then return end
      openColorPickerForRow(parseHex6(Panel.state.notifications.triggerColors[i]) or "ffffff",
        function(newHex)
          if newHex then
            Panel.state.notifications.triggerColors[i] = newHex
            repaint()
          end
        end)
    end)
    setTooltip(swatchBtn, L.EDIT_NOTIFY_COLORING_PICK_TOOLTIP, nil)

    hexInput:SetScript("OnTextChanged", function(self)
      if Panel.state.notifications.triggerColors[i] == "class" then return end
      local text = self:GetText() or ""
      if text == "" then
        Panel.state.notifications.triggerColors[i] = nil
        swatchBtn:SetBackdropColor(0.2, 0.2, 0.2, 1)
        return
      end
      local hex = parseHex6(text)
      if hex then
        Panel.state.notifications.triggerColors[i] = hex
        local rr, gg, bb = hexToRGB01(hex)
        swatchBtn:SetBackdropColor(rr, gg, bb, 1)
      end
      -- Invalid intermediate text: leave state alone so the user can finish
      -- typing without losing the previously-applied color.
    end)
    setTooltip(hexInput, L.EDIT_NOTIFY_COLORING_HEX_TOOLTIP_TITLE, L.EDIT_NOTIFY_COLORING_HEX_TOOLTIP_DESC)

    classCheck:SetScript("OnClick", function(self)
      if self:GetChecked() then
        Panel.state.notifications.triggerColors[i] = "class"
      else
        Panel.state.notifications.triggerColors[i] = nil
      end
      repaint()
    end)

    table.insert(f.coloringRows, {
      widgets = { row, label, swatchBtn, hexInput, classCheck },
    })
    prevRow = row
  end

  f.coloringBottom:ClearAllPoints()
  f.coloringBottom:SetPoint("TOPLEFT", prevRow, "BOTTOMLEFT", 0, -2)
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
  local hasAction = hasReplyText or hasEmote or s.reply.invite or s.reply.guildInvite or s.reply.kick

  -- Notification sound counts as an observable effect, so a watcher with a
  -- sound but no reply action is still savable. When "No reply needed" is
  -- on, the reply action doesn't count (it'd be ignored at runtime anyway),
  -- so the sound is the only thing that can satisfy the requirement. Sound
  -- value is either a numeric kit ID or an LSM name string.
  local notif = s.notifications or {}
  local sv = notif.sound
  local hasSound = sv ~= nil
    and sv ~= Constants.SOUND_NONE
    and not (type(sv) == "string" and sv == "")
  local effectiveAction = hasSound or (not notif.noReply and hasAction)

  -- The full requirements list is on the Save button's hover tooltip
  -- (set up in buildEditForm). Here we only toggle enabled-ness — the
  -- tooltip surfaces only while the button is disabled, which exactly
  -- matches "form is incomplete".
  if hasTrigger and anyChannel and effectiveAction then
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
  local hasAction = (#s.reply.texts > 0) or hasEmote or s.reply.invite or s.reply.guildInvite or s.reply.kick
  -- Sound is either a numeric kit ID (built-in) or a string LSM name; either
  -- one counts as a configured effect. SOUND_NONE (0) is the explicit
  -- "no sound" sentinel.
  local notif = s.notifications or {}
  local soundValue = notif.sound
  local hasSound = soundValue ~= nil
    and soundValue ~= Constants.SOUND_NONE
    and not (type(soundValue) == "string" and soundValue == "")
  local effectiveAction = hasSound or (not notif.noReply and hasAction)
  if not effectiveAction then
    reportSaveError(L.EDIT_ERR_NO_EFFECT)
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

-- Updates the edit-form's top-bar title from the current state. New watchers
-- show "Add new watcher"; existing watchers show "Edit '<name>'", or an
-- "Edit (unnamed)" placeholder when the name input is empty. Called from
-- enterEdit and from the name input's OnTextChanged so the title tracks the
-- name as the user types.
--
-- Long names get truncated with an ellipsis so the title doesn't run into
-- the Cancel/Save buttons on the top bar. The cap is a character count
-- (not a pixel width) so the truncation is deterministic across fonts.
local EDIT_HEADER_NAME_MAX = 30
local function updateEditHeader(isNew)
  local f = Panel._editFrame
  if not f or not f.header then return end
  if isNew then
    f.header:SetText(L.EDIT_HEADER_NEW)
    return
  end
  local nm = Panel.state and Panel.state.name or ""
  nm = nm:match("^%s*(.-)%s*$") or ""
  if nm == "" then
    f.header:SetText(L.EDIT_HEADER_EDIT_UNNAMED)
    return
  end
  if #nm > EDIT_HEADER_NAME_MAX then
    nm = nm:sub(1, EDIT_HEADER_NAME_MAX - 1) .. "…"
  end
  f.header:SetText(string.format(L.EDIT_HEADER_EDIT_FMT, nm))
end
Panel._updateEditHeader = updateEditHeader

enterEdit = function(id)
  if id then
    local existing = addon.Watchers:GetByID(id)
    if not existing then return end
    Panel.state = deepCopy(existing)
    Panel._isNewWatcher = false
    updateEditHeader(false)
  else
    Panel.state = Constants.NEW_WATCHER_DEFAULTS()
    Panel._isNewWatcher = true
    updateEditHeader(true)
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
