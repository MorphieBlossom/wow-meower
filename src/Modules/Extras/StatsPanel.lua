local _, addon = ...
local L = addon.L

-- Stats canvas subcategory. Two tabs:
--   Top 10s   — totals + top-N lists (the historical view)
--   Overview  — per-player drill-down: search + trigger filter, then an
--               expandable row per player showing every trigger they hit,
--               every reply they got back, and every emote that fired.
--               Lazy-loaded in batches so a long roster doesn't stall the
--               UI on first render.
--
-- Reset button sticks outside the tab bodies (bottom-left of the panel) so
-- it stays reachable in either tab and resets the whole Stats store, not
-- just the active tab.

local Panel = {}

local CONTENT_WIDTH    = 660
local INNER_WIDTH      = 560
local LEFT_MARGIN      = 16
local TOP_PAD          = 20
local HEADER_H         = 22
local SECTION_PAD      = 14
local TOP_N            = 10
local EXPAND_BTN_W     = 22
-- Lazy-load knobs for the Overview tab. We render this many player blocks
-- per batch; when the user scrolls within SCROLL_TRIGGER_PX of the bottom,
-- we render the next batch. Tuned to keep the first paint cheap and
-- subsequent appends imperceptible.
local OVERVIEW_BATCH       = 20
local OVERVIEW_SCROLL_TRIGGER_PX = 80

local COLOR_HEADING = { r = 1.0, g = 0.82, b = 0.0 }
local COLOR_SOFT    = { r = 0.7, g = 0.7,  b = 0.7 }

-- Orange wrap for counter values so the eye lands on the number first.
-- Matches the |cffff8000Meower|r prefix used elsewhere in the addon.
local function colorNum(n)
  return "|cffff8000" .. tostring(n) .. "|r"
end

-- Muted gray wrap (matches COLOR_SOFT) for secondary text like the channel
-- suffix on a trigger row.
local function colorSoft(text)
  return "|cffb3b3b3" .. tostring(text) .. "|r"
end

-- Top-list rows read "1.   5 x  -  Name". A single proportional-font
-- FontString can't line the columns up vertically (rank/count widths vary),
-- so each row is a frame of fixed-width, justified columns: the rank dots,
-- the orange counts, and the names each start at the same x down the list.
local TOPROW_H        = 14
local TOPROW_RANK_W   = 24   -- left-justified; "1." and "10." share a left edge
local TOPROW_COUNT_X  = 26
-- Right-justified so counts' right edges line up. Word-wrap is off on the
-- count FontString, so this width is a hard clip — too narrow and a high
-- count renders as "2..." instead of "27 x". Sized wide enough to hold large
-- counts plus the " x" suffix; the name column derives from it, so widening
-- this shifts every name in lockstep and alignment is preserved.
local TOPROW_COUNT_W  = 60
local TOPROW_NAME_X   = TOPROW_COUNT_X + TOPROW_COUNT_W + 6

local function makeTopListRow(content, rank, count, name)
  local row = CreateFrame("Frame", nil, content)
  row:SetSize(INNER_WIDTH - 4, TOPROW_H)

  local rankFS = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  rankFS:SetPoint("TOPLEFT", 0, 0)
  rankFS:SetWidth(TOPROW_RANK_W)
  rankFS:SetJustifyH("LEFT")
  rankFS:SetText(rank .. ".")

  local countFS = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  countFS:SetPoint("TOPLEFT", TOPROW_COUNT_X, 0)
  countFS:SetWidth(TOPROW_COUNT_W)
  countFS:SetJustifyH("RIGHT")
  countFS:SetWordWrap(false)
  countFS:SetText(colorNum(count) .. " x")

  local nameFS = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  nameFS:SetPoint("TOPLEFT", TOPROW_NAME_X, 0)
  nameFS:SetPoint("RIGHT", row, "RIGHT", 0, 0)
  nameFS:SetJustifyH("LEFT")
  nameFS:SetText("-  " .. tostring(name))

  return row
end

-- ===== Primitives =====
local function makeLabel(parent, text, fontObject)
  local fs = parent:CreateFontString(nil, "ARTWORK", fontObject or "GameFontNormal")
  fs:SetText(text)
  return fs
end

local function makeHeader(parent, text)
  local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  fs:SetText(text)
  fs:SetTextColor(COLOR_HEADING.r, COLOR_HEADING.g, COLOR_HEADING.b)
  return fs
end

local function makeMutedLabel(parent, text)
  local fs = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  fs:SetText(text)
  fs:SetTextColor(COLOR_SOFT.r, COLOR_SOFT.g, COLOR_SOFT.b)
  return fs
end

local function makeFullSeparator(content, belowAnchor, yOffset)
  local sep = content:CreateTexture(nil, "ARTWORK")
  sep:SetHeight(1)
  sep:SetPoint("LEFT",  content, "LEFT",  10, 0)
  sep:SetPoint("RIGHT", content, "RIGHT", -10, 0)
  sep:SetPoint("TOP",   belowAnchor, "BOTTOM", 0, yOffset or -10)
  sep:SetColorTexture(1, 1, 1, 0.25)
  return sep
end

local function setTooltip(frame, title)
  if not frame then return end
  frame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(title or "", 1, 1, 1)
    GameTooltip:Show()
  end)
  frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- ===== Reset confirmation popup =====
-- Addon-owned frame (not StaticPopup) so we don't drag in Blizzard's popup
-- chrome / styling. Built lazily on first click and reused thereafter.
local function ensureResetPopup()
  if Panel._resetPopup then return Panel._resetPopup end
  local f = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
  f:SetSize(360, 130)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetBackdrop({
    bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 16,
    insets   = { left = 4, right = 4, top = 4, bottom = 4 },
  })
  f:SetBackdropColor(0, 0, 0, 0.9)
  f:EnableMouse(true)
  f:Hide()

  local title = makeLabel(f, L.STATS_RESET_TITLE, "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -14)
  title:SetTextColor(COLOR_HEADING.r, COLOR_HEADING.g, COLOR_HEADING.b)

  local msg = makeLabel(f, L.STATS_RESET_DESC, "GameFontHighlight")
  msg:SetPoint("TOPLEFT", 16, -42)
  msg:SetPoint("TOPRIGHT", -16, -42)
  msg:SetJustifyH("CENTER")

  local confirm = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  confirm:SetSize(110, 24)
  confirm:SetPoint("BOTTOMRIGHT", -16, 14)
  confirm:SetText(L.STATS_RESET_CONFIRM)
  confirm:SetScript("OnClick", function()
    if addon.Extras.Stats and addon.Extras.Stats.Reset then addon.Extras.Stats:Reset() end
    f:Hide()
    if Panel.refresh then Panel.refresh() end
  end)

  local cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  cancel:SetSize(110, 24)
  cancel:SetPoint("RIGHT", confirm, "LEFT", -8, 0)
  cancel:SetText(L.STATS_RESET_CANCEL)
  cancel:SetScript("OnClick", function() f:Hide() end)

  Panel._resetPopup = f
  return f
end

-- ===== Top 10s tab: section scaffolding =====
-- Each section is built once with: separator, [+/-] toggle, gold header,
-- muted description, and a 1×1 bottomAnchor. The next section's separator
-- anchors to the previous section's bottomAnchor, so collapse → expand
-- naturally reflows the chain. Dynamic content rows live below the
-- description and are recreated on every refresh.
--
-- `skipSeparator` is set on the first section because the panel-level
-- top separator (the one the tabs visibly attach to) already plays that
-- role — drawing another line 10px below it produced a double-line look
-- and pushed the first section's toggle further from the tab bottom.
local function buildSection(content, key, headerText, descText, prevAnchor, skipSeparator)
  local sec = { key = key, contentRows = {} }
  if not skipSeparator then
    sec.separator = makeFullSeparator(content, prevAnchor, -10)
  end

  sec.toggleBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
  sec.toggleBtn:SetSize(EXPAND_BTN_W, HEADER_H)
  if sec.separator then
    sec.toggleBtn:SetPoint("TOPLEFT", sec.separator, "BOTTOMLEFT", LEFT_MARGIN - 10, -8)
  else
    sec.toggleBtn:SetPoint("TOPLEFT", prevAnchor, "BOTTOMLEFT", LEFT_MARGIN, -8)
  end
  sec.toggleBtn:SetText("-")
  sec.toggleBtn:SetScript("OnClick", function()
    sec.collapsed = not sec.collapsed
    if Panel.refresh then Panel.refresh() end
  end)
  setTooltip(sec.toggleBtn, L.STATS_SECTION_COLLAPSE_TOOLTIP_TITLE)

  sec.header = makeHeader(content, headerText)
  sec.header:SetPoint("LEFT", sec.toggleBtn, "RIGHT", 6, 0)

  -- Description trails the header on the same line. Word-wrap stays on so an
  -- over-long string drops onto a second line rather than clipping at the
  -- panel edge, but with the now-terse copy it stays on one line.
  sec.descLabel = makeMutedLabel(content, " - " .. descText)
  sec.descLabel:SetPoint("LEFT",  sec.header, "RIGHT", 6, 0)
  sec.descLabel:SetPoint("RIGHT", content,    "RIGHT", -10, 0)
  sec.descLabel:SetJustifyH("LEFT")
  sec.descLabel:SetWordWrap(true)

  sec.bottomAnchor = CreateFrame("Frame", nil, content)
  sec.bottomAnchor:SetSize(1, 1)

  return sec
end

local function releaseSectionRows(sec)
  for _, w in ipairs(sec.contentRows) do
    w:Hide()
    w:SetParent(nil)
  end
  sec.contentRows = {}
end

local function makeSectionLine(content, text)
  local l = makeLabel(content, text, "GameFontHighlight")
  l:SetWidth(INNER_WIDTH - 4)
  l:SetJustifyH("LEFT")
  return l
end

local function makeSectionMuted(content, text)
  local l = makeMutedLabel(content, text)
  l:SetWidth(INNER_WIDTH - 4)
  l:SetJustifyH("LEFT")
  return l
end

-- ===== Top 10s tab =====
local function buildTop10sTab(parent)
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetAllPoints(parent)

  local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 0, 0)
  scroll:SetPoint("BOTTOMRIGHT", -26, 0)

  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(CONTENT_WIDTH, 200)
  scroll:SetScrollChild(content)

  -- Build sections in display order.
  local topAnchor = CreateFrame("Frame", nil, content)
  topAnchor:SetSize(1, 1)
  topAnchor:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)

  Panel.sections = {}
  local prev = topAnchor
  local function add(key, header, desc_text)
    local skipSep = (#Panel.sections == 0) -- first section reuses panel topSep
    local sec = buildSection(content, key, header, desc_text, prev, skipSep)
    table.insert(Panel.sections, sec)
    prev = sec.bottomAnchor
    return sec
  end
  add("overview",  L.STATS_OVERVIEW_HEADER,     L.STATS_OVERVIEW_DESC)
  add("watchers",  L.STATS_TOP_WATCHERS_HEADER, L.STATS_TOP_WATCHERS_DESC)
  add("senders",   L.STATS_TOP_SENDERS_HEADER,  L.STATS_TOP_SENDERS_DESC)

  frame._content    = content
  frame._tailAnchor = prev
  return frame
end

local function refreshTop10s()
  local frame = Panel._top10sFrame
  if not frame or not frame._content then return end
  local Stats = addon.Extras and addon.Extras.Stats
  if not Stats then return end
  local content = frame._content
  local data = Stats:Get() or {}
  local notMe = Stats:NotMePredicate()

  for idx, sec in ipairs(Panel.sections) do
    releaseSectionRows(sec)
    sec.toggleBtn:SetText(sec.collapsed and "+" or "-")
    setTooltip(sec.toggleBtn,
      sec.collapsed and L.STATS_SECTION_EXPAND_TOOLTIP_TITLE
                     or L.STATS_SECTION_COLLAPSE_TOOLTIP_TITLE)

    local prevSec = Panel.sections[idx - 1]
    sec.toggleBtn:ClearAllPoints()
    if prevSec and prevSec.collapsed then
      if sec.separator then sec.separator:Hide() end
      sec.toggleBtn:SetPoint("TOPLEFT", prevSec.bottomAnchor, "BOTTOMLEFT", 0, -2)
    else
      if sec.separator then
        sec.separator:Show()
        sec.toggleBtn:SetPoint("TOPLEFT", sec.separator, "BOTTOMLEFT", LEFT_MARGIN - 10, -8)
      else
        -- Section with no separator (the first one) anchors directly
        -- below the previous section's bottomAnchor (or, for idx 1,
        -- to its parent's TOPLEFT via the original buildSection call).
        if prevSec then
          sec.toggleBtn:SetPoint("TOPLEFT", prevSec.bottomAnchor, "BOTTOMLEFT", 0, -8)
        else
          sec.toggleBtn:SetPoint("TOPLEFT", content, "TOPLEFT", LEFT_MARGIN, -8)
        end
      end
    end

    if not sec.collapsed then
      sec.descLabel:Show()
      -- Content rows stack below the toggle/header line (the description
      -- trails the header on that same line).
      local prev = sec.toggleBtn
      local function addWidget(w)
        if prev == sec.toggleBtn then
          w:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 4, -6)
        else
          w:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -2)
        end
        table.insert(sec.contentRows, w)
        prev = w
      end
      local function addRow(builder, text)
        addWidget(builder(content, text))
      end

      if sec.key == "overview" then
        addRow(makeSectionLine, string.format(L.STATS_OVERVIEW_TOTAL,    colorNum(data.totalFires or 0)))
        addRow(makeSectionLine, string.format(L.STATS_OVERVIEW_REPLIES,  colorNum((data.repliesTextCount or 0) + (data.repliesEmoteCount or 0))))
        addRow(makeSectionLine, string.format(L.STATS_OVERVIEW_ACTIONS,  colorNum(data.actionsCount or 0)))
        addRow(makeSectionLine, string.format(L.STATS_OVERVIEW_SENDERS,  colorNum(Stats:CountKeys(data.firesBySender))))
        addRow(makeSectionLine, string.format(L.STATS_OVERVIEW_PURRS,    colorNum(Stats:PurrCount())))
      elseif sec.key == "watchers" then
        local top = Stats:TopN(data.firesByWatcherId, TOP_N)
        if #top == 0 then
          addRow(makeSectionMuted, L.STATS_EMPTY)
        else
          for i, p in ipairs(top) do
            local watcherId = p[1]
            addWidget(makeTopListRow(content, i, p[2], Stats:WatcherName(watcherId)))
          end
        end
      elseif sec.key == "senders" then
        local top = Stats:TopN(data.firesBySender, TOP_N, notMe)
        if #top == 0 then
          addRow(makeSectionMuted, L.STATS_EMPTY)
        else
          for i, p in ipairs(top) do
            addWidget(makeTopListRow(content, i, p[2], Stats:DisplaySender(p[1])))
          end
        end
      end

      sec.bottomAnchor:ClearAllPoints()
      sec.bottomAnchor:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -SECTION_PAD)
    else
      -- Collapsed: only the toggle/header line shows. The description trails
      -- the header on that line, so it stays visible.
      sec.descLabel:Show()
      sec.bottomAnchor:ClearAllPoints()
      sec.bottomAnchor:SetPoint("TOPLEFT", sec.toggleBtn, "BOTTOMLEFT", 0, -2)
    end
  end

  C_Timer.After(0, function()
    if not frame._content or not frame._tailAnchor then return end
    local cTop = frame._content:GetTop()
    local aBot = frame._tailAnchor:GetBottom()
    if cTop and aBot then
      local used = (cTop - aBot) + 30
      if used < 200 then used = 200 end
      frame._content:SetHeight(used)
    end
  end)
end

-- ===== Overview tab =====
-- Per-player drill-down. State lives on Panel._ov for clarity.
--
-- Lazy load: each refresh builds the matching player list, then renders
-- _renderedCount of those. The ScrollFrame's OnVerticalScroll handler
-- pushes the next batch when the user scrolls within ~80px of the bottom.
-- Releasing rows on filter change happens via a single recycle pass — we
-- detach and clear all existing rows, then re-render from the top.

local function clearOverviewRows()
  local ov = Panel._ov
  if not ov then return end
  for _, b in ipairs(ov.blocks or {}) do
    b:Hide()
    b:SetParent(nil)
    b:ClearAllPoints()
  end
  ov.blocks = {}
end

-- Per-character block. A toggle + name/total header; expanding it reveals a
-- table-aligned log of the triggers that player hit (count + phrase). Only
-- triggers are logged — replies and emotes belong to the trigger that
-- produced them, so they'd just be noise here. The batch loader keeps long
-- rosters cheap to render. Returns the frame + its measured height so the
-- caller can stack the next block below.
local OVLOG_INDENT    = EXPAND_BTN_W + 8
local OVLOG_VALUE_GAP = 6
local OVLOG_ROW_H     = 14

local function buildPlayerBlock(parent, sender, entry, isExpanded, onToggle)
  local block = CreateFrame("Frame", nil, parent)
  block:SetWidth(INNER_WIDTH + 30)

  local toggleBtn = CreateFrame("Button", nil, block, "UIPanelButtonTemplate")
  toggleBtn:SetSize(EXPAND_BTN_W, HEADER_H)
  toggleBtn:SetText(isExpanded and "-" or "+")
  toggleBtn:SetPoint("TOPLEFT", 0, 0)
  toggleBtn:SetScript("OnClick", onToggle)
  setTooltip(toggleBtn,
    isExpanded and L.STATS_SECTION_COLLAPSE_TOOLTIP_TITLE
                or L.STATS_SECTION_EXPAND_TOOLTIP_TITLE)

  local Stats = addon.Extras and addon.Extras.Stats
  local displaySender = (Stats and Stats.DisplaySender) and Stats:DisplaySender(sender) or sender

  local label = block:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  label:SetPoint("LEFT", toggleBtn, "RIGHT", 6, 0)
  label:SetPoint("RIGHT", block, "RIGHT", -10, 0)
  label:SetJustifyH("LEFT")
  label:SetText(string.format(L.STATS_OVERVIEW_PLAYER_TOTAL_FMT, displaySender, colorNum(entry.total or 0)))

  if not isExpanded then
    block:SetHeight(HEADER_H + 4)
    return block, HEADER_H + 4
  end

  -- Expanded: one table-aligned row per trigger (count column + phrase),
  -- matching the Top-10 lists' column geometry. When a trigger fired in
  -- more than one channel it gets one row per channel so the per-channel
  -- counts stay accurate; the channel name trails the phrase in gray.
  local y = HEADER_H + 4
  local function logRow(count, phrase, channelLabel)
    local countFS = block:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    countFS:SetPoint("TOPLEFT", OVLOG_INDENT, -y)
    countFS:SetWidth(TOPROW_COUNT_W)
    countFS:SetJustifyH("RIGHT")
    countFS:SetWordWrap(false)
    countFS:SetText(colorNum(count) .. " x")

    local valFS = block:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    valFS:SetPoint("TOPLEFT", OVLOG_INDENT + TOPROW_COUNT_W + OVLOG_VALUE_GAP, -y)
    valFS:SetPoint("RIGHT", block, "RIGHT", -10, 0)
    valFS:SetJustifyH("LEFT")
    local text = "-  " .. tostring(phrase)
    if channelLabel then text = text .. "   " .. colorSoft("(" .. channelLabel .. ")") end
    valFS:SetText(text)
    y = y + OVLOG_ROW_H
  end

  local triggers = Stats and Stats:SortSubmap(entry.triggers) or {}
  if #triggers == 0 then
    local r = block:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    r:SetPoint("TOPLEFT", OVLOG_INDENT, -y)
    r:SetPoint("RIGHT", block, "RIGHT", -10, 0)
    r:SetJustifyH("LEFT")
    r:SetTextColor(COLOR_SOFT.r, COLOR_SOFT.g, COLOR_SOFT.b)
    r:SetText(L.STATS_OVERVIEW_PLAYER_NO_DATA)
    y = y + OVLOG_ROW_H
  else
    for _, p in ipairs(triggers) do
      local phrase = p[1]
      local chans = Stats and Stats:SortSubmap(entry.triggerChannels and entry.triggerChannels[phrase]) or {}
      if #chans == 0 then
        -- Pre-tracking (or channel-less) fire: show the trigger total alone.
        logRow(p[2], phrase, nil)
      else
        for _, c in ipairs(chans) do
          logRow(c[2], phrase, Stats:ChannelLabel(c[1]))
        end
      end
    end
  end

  y = y + 6
  block:SetHeight(y)
  return block, y
end

local function refreshOverview(resetScroll)
  local frame = Panel._overviewFrame
  if not frame then return end
  local Stats = addon.Extras and addon.Extras.Stats
  if not Stats then return end
  local ov = Panel._ov
  if not ov then return end

  clearOverviewRows()
  ov.matches = Stats:FilteredPlayers({
    search       = ov.search,
    trigger      = ov.triggerFilter ~= "" and ov.triggerFilter or nil,
    excludeSelf  = false,
  })
  ov.renderedCount = 0

  if resetScroll and ov.scroll then ov.scroll:SetVerticalScroll(0) end

  -- Empty state messages — different copy when filters are active vs the
  -- "nothing ever fired" baseline, so the user knows whether to clear
  -- filters or wait for a trigger.
  if #ov.matches == 0 then
    local hasAny = next(Stats:Get() and Stats:Get().byPlayer or {}) ~= nil
    local text = hasAny and L.STATS_OVERVIEW_NO_MATCHES or L.STATS_OVERVIEW_EMPTY
    local msg = makeMutedLabel(ov.content, text)
    msg:SetPoint("TOPLEFT", 16, -12)
    msg:SetPoint("TOPRIGHT", -16, -12)
    msg:SetJustifyH("LEFT")
    table.insert(ov.blocks, msg)
    ov.content:SetHeight(60)
    if ov.statusLabel then ov.statusLabel:SetText("") end
    return
  end

  Panel._appendOverviewBatch()
end

-- Renders the next batch of OVERVIEW_BATCH player blocks. Anchors each
-- block to the previous one's BOTTOMLEFT. Updates content height + the
-- "Showing N of M" status label.
local function appendOverviewBatch()
  local ov = Panel._ov
  if not ov or not ov.matches then return end
  local total = #ov.matches
  if ov.renderedCount >= total then return end

  local prev = ov.blocks[#ov.blocks]

  local i = ov.renderedCount
  local stopAt = math.min(total, i + OVERVIEW_BATCH)
  while i < stopAt do
    i = i + 1
    local row = ov.matches[i]
    local sender, entry = row.sender, row.entry
    local expanded = ov.expanded[sender] == true
    local function onToggle()
      ov.expanded[sender] = not expanded
      refreshOverview(false)
    end
    local block = buildPlayerBlock(ov.content, sender, entry, expanded, onToggle)
    if prev then
      block:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -4)
      block:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -4)
    else
      block:SetPoint("TOPLEFT", ov.content, "TOPLEFT", 6, -8)
      block:SetPoint("TOPRIGHT", ov.content, "TOPRIGHT", -6, -8)
    end
    table.insert(ov.blocks, block)
    prev = block
  end
  ov.renderedCount = i

  -- Resize the scroll child to fit the rendered chain (plus a little
  -- breathing room so the last block's bottom isn't flush against the
  -- scroll edge).
  C_Timer.After(0, function()
    if not ov.content then return end
    local tail = ov.blocks[#ov.blocks]
    if not tail then return end
    local cTop = ov.content:GetTop()
    local bBot = tail:GetBottom()
    if cTop and bBot then
      local used = (cTop - bBot) + 20
      if used < 60 then used = 60 end
      ov.content:SetHeight(used)
    end
  end)

  if ov.statusLabel then
    ov.statusLabel:SetText(string.format(L.STATS_OVERVIEW_STATUS_FMT, ov.renderedCount, total))
  end
end
Panel._appendOverviewBatch = appendOverviewBatch

local function buildOverviewTab(parent)
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetAllPoints(parent)

  -- Initialize the overview state table up front. SetupMenu (below) invokes
  -- its populate callback synchronously during registration, and that
  -- callback reads Panel._ov — so the table must exist before the dropdown
  -- is created. Frame references (scroll/content/statusLabel/...) are filled
  -- in as those frames come into being further down.
  Panel._ov = {
    search         = "",
    triggerFilter  = "",
    matches        = {},
    blocks         = {},
    expanded       = {},
    renderedCount  = 0,
  }

  -- Search box (Blizzard's SearchBoxTemplate gives us the magnifying-glass
  -- icon and an X clear button for free).
  local searchBox = CreateFrame("EditBox", nil, frame, "SearchBoxTemplate")
  searchBox:SetSize(220, 22)
  searchBox:SetPoint("TOPLEFT", 8, -4)
  searchBox:SetAutoFocus(false)
  searchBox:SetMaxLetters(60)
  searchBox:SetScript("OnTextChanged", function(self, userInput)
    if not userInput then return end
    Panel._ov.search = (self:GetText() or ""):match("^%s*(.-)%s*$")
    refreshOverview(true)
  end)
  searchBox:HookScript("OnEditFocusLost", function(self) self:HighlightText(0, 0) end)

  -- Trigger filter — a Blizzard DropdownButton (same modern menu system
  -- the watcher edit form uses). Default option "All triggers" clears the
  -- filter; everything else is sourced from Stats:AllRecordedTriggers().
  local TRIGGER_ALL = ""
  local triggerDd = CreateFrame("DropdownButton", nil, frame, "WowStyle1DropdownTemplate")
  triggerDd:SetWidth(220)
  triggerDd:SetPoint("LEFT", searchBox, "RIGHT", 12, 0)
  triggerDd:SetDefaultText(L.STATS_OVERVIEW_TRIGGER_FILTER_ALL)
  triggerDd:SetupMenu(function(_, rootDescription)
    if rootDescription.SetScrollMode then
      rootDescription:SetScrollMode(10 * 20)
    end
    local Stats = addon.Extras and addon.Extras.Stats
    local current = Panel._ov.triggerFilter or TRIGGER_ALL
    local function isSelectedAll() return current == TRIGGER_ALL end
    local function setAll()
      Panel._ov.triggerFilter = TRIGGER_ALL
      triggerDd:OverrideText(L.STATS_OVERVIEW_TRIGGER_FILTER_ALL)
      refreshOverview(true)
    end
    rootDescription:CreateRadio(L.STATS_OVERVIEW_TRIGGER_FILTER_ALL, isSelectedAll, setAll, TRIGGER_ALL)
    if Stats then
      for _, trigger in ipairs(Stats:AllRecordedTriggers()) do
        local t = trigger
        rootDescription:CreateRadio(t,
          function() return current == t end,
          function()
            Panel._ov.triggerFilter = t
            triggerDd:OverrideText(t)
            refreshOverview(true)
          end, t)
      end
    end
  end)

  -- Status line: "Showing N of M". Sits to the right of the trigger
  -- dropdown so the user can read the filter result count without
  -- having to scroll the list to the bottom.
  local status = makeMutedLabel(frame, "")
  status:SetPoint("LEFT", triggerDd, "RIGHT", 12, 0)
  status:SetPoint("RIGHT", frame, "RIGHT", -30, 0)
  status:SetJustifyH("LEFT")

  -- Scroll area for the player blocks.
  local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", 0, -10)
  scroll:SetPoint("BOTTOMRIGHT", -26, 0)

  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(CONTENT_WIDTH, 100)
  scroll:SetScrollChild(content)

  -- Lazy-load trigger: when the user scrolls within OVERVIEW_SCROLL_TRIGGER_PX
  -- of the bottom AND there are more players to render, append the next
  -- batch. We compare scroll position against (max - threshold) so the
  -- batch lands before the user hits the floor.
  scroll:SetScript("OnVerticalScroll", function(self, _offset)
    local max = self:GetVerticalScrollRange()
    local cur = self:GetVerticalScroll()
    if max - cur <= OVERVIEW_SCROLL_TRIGGER_PX then
      appendOverviewBatch()
    end
  end)

  Panel._ov.scroll      = scroll
  Panel._ov.content     = content
  Panel._ov.statusLabel = status
  Panel._ov.searchBox   = searchBox
  Panel._ov.triggerDd   = triggerDd

  return frame
end

-- ===== Tab switching =====
local function setTab(name)
  if name ~= "top10s" and name ~= "overview" then name = "top10s" end
  Panel.tab = name
  if Panel._top10sFrame and Panel._overviewFrame then
    Panel._top10sFrame:SetShown(name == "top10s")
    Panel._overviewFrame:SetShown(name == "overview")
  end
  if Panel._top10sTabBtn and Panel._overviewTabBtn then
    PanelTemplates_DeselectTab(Panel._top10sTabBtn)
    PanelTemplates_DeselectTab(Panel._overviewTabBtn)
    if name == "top10s" then
      PanelTemplates_SelectTab(Panel._top10sTabBtn)
    else
      PanelTemplates_SelectTab(Panel._overviewTabBtn)
    end
  end
  if Panel.refresh then Panel.refresh() end
end
Panel.setTab = setTab

-- ===== Refresh dispatcher =====
local function refresh()
  if Panel.tab == "overview" then
    refreshOverview(false)
  else
    refreshTop10s()
  end
end
Panel.refresh = refresh

-- ===== Panel build =====
local function buildPanel()
  local frame = CreateFrame("Frame")

  local title = makeLabel(frame, L.STATS_TITLE, "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", LEFT_MARGIN + 4, -TOP_PAD)

  local desc = makeLabel(frame, L.STATS_DESC, "GameFontHighlight")
  desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
  desc:SetWidth(INNER_WIDTH + 80)
  desc:SetJustifyH("LEFT")

  -- Tab buttons: PanelTopTabButtonTemplate matches the watcher edit form's
  -- tabs so the visual language stays consistent across the addon.
  -- PanelTemplates_TabResize sizes each button to its label text — without
  -- it the buttons keep their default fixed width and the next-tab offset
  -- ends up landing wherever that default starts. The -3 LEFT/RIGHT spacing
  -- between tabs is the canonical Blizzard tab-button overlap (the side
  -- caps blend into each other on purpose).
  -- Panel-level top separator. The tabs visibly attach to this line —
  -- selected tab's body extends down across the separator so it merges
  -- with the content below. The first Top-10s section (when built)
  -- skips its own internal separator so we don't end up with a
  -- double-drawn line at the same y.
  local topSep = frame:CreateTexture(nil, "ARTWORK")
  topSep:SetHeight(1)
  topSep:SetPoint("TOPLEFT",  desc,  "BOTTOMLEFT", 0,   -42)
  topSep:SetPoint("TOPRIGHT", frame, "TOPRIGHT",  -30,  0)
  topSep:SetColorTexture(1, 1, 1, 0.3)

  local top10sTabBtn = CreateFrame("Button", nil, frame, "PanelTopTabButtonTemplate")
  top10sTabBtn:SetID(1)
  top10sTabBtn:SetText(L.STATS_TAB_TOP10S)
  PanelTemplates_TabResize(top10sTabBtn, 0)
  top10sTabBtn:SetPoint("BOTTOMLEFT", topSep, "TOPLEFT", 18, 0)
  top10sTabBtn:SetScript("OnClick", function() setTab("top10s") end)

  local overviewTabBtn = CreateFrame("Button", nil, frame, "PanelTopTabButtonTemplate")
  overviewTabBtn:SetID(2)
  overviewTabBtn:SetText(L.STATS_TAB_OVERVIEW)
  PanelTemplates_TabResize(overviewTabBtn, 0)
  overviewTabBtn:SetPoint("LEFT", top10sTabBtn, "RIGHT", -3, 0)
  overviewTabBtn:SetScript("OnClick", function() setTab("overview") end)

  -- Reset button sits OUTSIDE the tab bodies, anchored bottom-left, so it
  -- stays visible while the user scrolls either tab. Both tab bodies leave
  -- room above this for it.
  local resetBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  resetBtn:SetSize(150, 24)
  resetBtn:SetPoint("BOTTOMLEFT", LEFT_MARGIN + 4, 14)
  resetBtn:SetText(L.STATS_RESET_BTN)
  resetBtn:SetScript("OnClick", function() ensureResetPopup():Show() end)
  Panel._resetBtn = resetBtn

  -- Tab body container starts just below the panel-level top separator
  -- (the line the tabs visibly attach to). Both tab content frames
  -- anchor inside this area; swapping tabs is just a visibility flip.
  local body = CreateFrame("Frame", nil, frame)
  body:SetPoint("TOPLEFT",     topSep, "BOTTOMLEFT",  0, -6)
  body:SetPoint("BOTTOMRIGHT", frame,  "BOTTOMRIGHT", -10, 50)

  Panel._top10sTabBtn   = top10sTabBtn
  Panel._overviewTabBtn = overviewTabBtn
  Panel._top10sFrame   = buildTop10sTab(body)
  Panel._overviewFrame = buildOverviewTab(body)

  setTab("top10s")
  Panel._frame = frame
  return frame
end

-- ===== Subcategory registration =====
local function build()
  if not (Settings and Settings.RegisterCanvasLayoutSubcategory) then return end
  local mainCategory = addon.MBLib and addon.MBLib._optionsCategory
  if not mainCategory then return end
  -- Honor the Stats master toggle. Skipping registration here keeps the
  -- Stats subcategory out of the options tree entirely when disabled —
  -- there's no Blizzard Settings API to unregister a subcategory after
  -- the fact, which is why the toggle requires /reload to fully apply.
  local Stats = addon.Extras and addon.Extras.Stats
  if Stats and Stats.IsEnabled and not Stats:IsEnabled() then return end

  local frame = buildPanel()
  frame:SetScript("OnShow", refresh)

  Settings.RegisterCanvasLayoutSubcategory(mainCategory, frame, L.STATS_SUBCATEGORY_NAME)

  -- Run refresh once at build time so the section chain is fully laid
  -- out before the user navigates to the page. OnShow alone isn't enough
  -- after /reload — Blizzard's Settings system caches the active
  -- subcategory and doesn't always re-fire OnShow on restore. Deferred
  -- one frame so anchor positions have resolved.
  C_Timer.After(0, function() pcall(refresh) end)
end

local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function(self)
  build()
  self:UnregisterEvent("PLAYER_LOGIN")
  self:SetScript("OnEvent", nil)
end)

addon.Extras = addon.Extras or {}
addon.Extras.StatsPanel = Panel
