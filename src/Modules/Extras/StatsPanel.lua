local _, addon = ...
local L = addon.L

-- Stats canvas subcategory. Visual language mirrors WatchersPanel's sections
-- (full separator → [+/-] toggle → gold header → muted description → content
-- rows). Each section is collapsible; default state is expanded. Collapse
-- state lives in-memory only (per-session) so the page always opens in a
-- discoverable shape.
--
-- Per refresh we tear down + rebuild the dynamic content rows of each
-- section. The static scaffolding (separator, toggle, header, description,
-- bottomAnchor) is built once at panel construction.

local Panel = {}

local CONTENT_WIDTH = 660
local INNER_WIDTH   = 560
local LEFT_MARGIN   = 16
local TOP_PAD       = 20
local HEADER_H      = 22
local SECTION_PAD   = 14
local TOP_N         = 10
local EXPAND_BTN_W  = 22

local COLOR_HEADING = { r = 1.0, g = 0.82, b = 0.0 }
local COLOR_SOFT    = { r = 0.7, g = 0.7,  b = 0.7 }

-- Orange wrap for counter values so the eye lands on the number first.
-- Matches the |cffff8000Meower|r prefix used elsewhere in the addon.
local function colorNum(n)
  return "|cffff8000" .. tostring(n) .. "|r"
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

-- ===== Section scaffolding =====
-- Each section is built once with: separator, [+/-] toggle, gold header,
-- muted description, and a 1×1 bottomAnchor. The next section's separator
-- anchors to the previous section's bottomAnchor, so collapse → expand
-- naturally reflows the chain. Dynamic content rows live below the
-- description and are recreated on every refresh.
local function buildSection(content, key, headerText, descText, prevAnchor)
  local sec = { key = key, contentRows = {} }
  sec.separator = makeFullSeparator(content, prevAnchor, -10)

  sec.toggleBtn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
  sec.toggleBtn:SetSize(EXPAND_BTN_W, HEADER_H)
  -- Anchor directly to the separator's BOTTOMLEFT so we have ONE anchor
  -- (single set of constraints). The separator's LEFT sits at content.LEFT
  -- + 10, so we offset by (LEFT_MARGIN - 10) to land at content.LEFT +
  -- LEFT_MARGIN. The previous code used two anchors (TOPLEFT to content
  -- and TOP to separator) which conflicted and pinned every section to
  -- content.TOPLEFT.
  sec.toggleBtn:SetPoint("TOPLEFT", sec.separator, "BOTTOMLEFT", LEFT_MARGIN - 10, -8)
  sec.toggleBtn:SetText("-")
  sec.toggleBtn:SetScript("OnClick", function()
    sec.collapsed = not sec.collapsed
    if Panel.refresh then Panel.refresh() end
  end)
  setTooltip(sec.toggleBtn, L.STATS_SECTION_COLLAPSE_TOOLTIP_TITLE)

  sec.header = makeHeader(content, headerText)
  sec.header:SetPoint("LEFT", sec.toggleBtn, "RIGHT", 6, 0)

  -- Description sits inline behind the header (separated by " - "). Wraps
  -- against the right edge of the content if the text is unusually long;
  -- short labels stay on a single line.
  sec.descLabel = makeMutedLabel(content, " - " .. descText)
  sec.descLabel:SetPoint("LEFT",  sec.header, "RIGHT", 6, 0)
  sec.descLabel:SetPoint("RIGHT", content,    "RIGHT", -10, 0)
  sec.descLabel:SetJustifyH("LEFT")

  sec.bottomAnchor = CreateFrame("Frame", nil, content)
  sec.bottomAnchor:SetSize(1, 1)

  return sec
end

-- ===== Panel build =====
local function buildPanel()
  local frame = CreateFrame("Frame")

  local title = makeLabel(frame, L.STATS_TITLE, "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", LEFT_MARGIN + 4, -TOP_PAD)

  local desc = makeLabel(frame, L.STATS_DESC, "GameFontHighlight")
  desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
  desc:SetWidth(INNER_WIDTH)
  desc:SetJustifyH("LEFT")

  -- Reset button sits OUTSIDE the scroll view, anchored bottom-left, so
  -- it stays visible while the user scrolls. The scrollview's bottom
  -- inset leaves room for it.
  local resetBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  resetBtn:SetSize(150, 24)
  resetBtn:SetPoint("BOTTOMLEFT", LEFT_MARGIN + 4, 14)
  resetBtn:SetText(L.STATS_RESET_BTN)
  resetBtn:SetScript("OnClick", function() ensureResetPopup():Show() end)
  Panel._resetBtn = resetBtn

  local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -14)
  scroll:SetPoint("BOTTOMRIGHT", -30, 50)

  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(CONTENT_WIDTH, 200)
  scroll:SetScrollChild(content)

  -- Build sections in display order. Each anchors below the previous
  -- section's bottomAnchor — the first one anchors to a synthetic top
  -- anchor at content's TOPLEFT.
  local topAnchor = CreateFrame("Frame", nil, content)
  topAnchor:SetSize(1, 1)
  topAnchor:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)

  Panel.sections = {}
  local prev = topAnchor
  local function add(key, header, desc_text)
    local sec = buildSection(content, key, header, desc_text, prev)
    table.insert(Panel.sections, sec)
    prev = sec.bottomAnchor
    return sec
  end
  add("overview",  L.STATS_OVERVIEW_HEADER,    L.STATS_OVERVIEW_DESC)
  add("watchers",  L.STATS_TOP_WATCHERS_HEADER, L.STATS_TOP_WATCHERS_DESC)
  add("senders",   L.STATS_TOP_SENDERS_HEADER,  L.STATS_TOP_SENDERS_DESC)
  add("replies",   L.STATS_TOP_REPLIES_HEADER,  L.STATS_TOP_REPLIES_DESC)
  add("emotes",    L.STATS_TOP_EMOTES_HEADER,   L.STATS_TOP_EMOTES_DESC)

  Panel._frame   = frame
  Panel._content = content
  Panel._tailAnchor = prev -- track the final section's bottom for content-height sizing
  return frame
end

-- ===== Refresh =====
local function releaseSectionRows(sec)
  for _, w in ipairs(sec.contentRows) do
    w:Hide()
    w:SetParent(nil)
  end
  sec.contentRows = {}
end

-- Content row builders. Anchoring is owned by addRow (refresh) so we
-- don't end up with the widget carrying two conflicting anchors.
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

local function refresh()
  if not Panel._content then return end
  local Stats = addon.Extras and addon.Extras.Stats
  if not Stats then return end
  local content = Panel._content
  local data = Stats:Get() or {}
  local notMe = Stats:NotMePredicate()

  for idx, sec in ipairs(Panel.sections) do
    releaseSectionRows(sec)
    sec.toggleBtn:SetText(sec.collapsed and "+" or "-")
    setTooltip(sec.toggleBtn,
      sec.collapsed and L.STATS_SECTION_EXPAND_TOOLTIP_TITLE
                     or L.STATS_SECTION_COLLAPSE_TOOLTIP_TITLE)

    -- A section's separator sits ABOVE its header. When the previous
    -- section is collapsed, hide this section's separator AND re-anchor
    -- the toggle directly to the previous bottomAnchor so collapsed
    -- sections butt up against each other without leaving a vertical
    -- "ghost" gap where the separator would have been.
    local prevSec = Panel.sections[idx - 1]
    sec.toggleBtn:ClearAllPoints()
    if prevSec and prevSec.collapsed then
      sec.separator:Hide()
      -- prevSec.bottomAnchor already sits in the column's left edge
      -- (anchored to prev.toggleBtn.BOTTOMLEFT). Use a 0 x-offset so
      -- collapsed sections stack flush instead of indenting further
      -- each step.
      sec.toggleBtn:SetPoint("TOPLEFT", prevSec.bottomAnchor, "BOTTOMLEFT", 0, -2)
    else
      sec.separator:Show()
      sec.toggleBtn:SetPoint("TOPLEFT", sec.separator, "BOTTOMLEFT", LEFT_MARGIN - 10, -8)
    end

    if not sec.collapsed then
      -- Build content rows for this section. Each row anchors to the
      -- previous one (or to toggleBtn for the first row, which puts the
      -- first content line directly below the inline-description header).
      local prev = sec.toggleBtn
      local function addRow(builder, text)
        local w = builder(content, text)
        if prev == sec.toggleBtn then
          -- First row: indent slightly from the toggle button's left
          -- edge so the column reads as nested under the header row.
          w:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 4, -6)
        else
          w:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -2)
        end
        table.insert(sec.contentRows, w)
        prev = w
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
            addRow(makeSectionLine, string.format("%d. %s  —  %s", i, Stats:WatcherName(p[1]), colorNum(p[2])))
          end
        end
      elseif sec.key == "senders" then
        local top = Stats:TopN(data.firesBySender, TOP_N, notMe)
        if #top == 0 then
          addRow(makeSectionMuted, L.STATS_EMPTY)
        else
          for i, p in ipairs(top) do
            addRow(makeSectionLine, string.format("%d. %s  —  %s", i, tostring(p[1]), colorNum(p[2])))
          end
        end
      elseif sec.key == "replies" then
        local top = Stats:TopN(data.repliesByText, TOP_N)
        if #top == 0 then
          addRow(makeSectionMuted, L.STATS_EMPTY)
        else
          for i, p in ipairs(top) do
            addRow(makeSectionLine, string.format("%d. %s  —  %s", i, tostring(p[1]), colorNum(p[2])))
          end
        end
      elseif sec.key == "emotes" then
        local top = Stats:TopN(data.firesByEmote, TOP_N)
        if #top == 0 then
          addRow(makeSectionMuted, L.STATS_EMPTY)
        else
          for i, p in ipairs(top) do
            addRow(makeSectionLine, string.format("%d. %s  —  %s", i, tostring(p[1]), colorNum(p[2])))
          end
        end
      end

      -- Bottom anchor sits below the last row when expanded.
      sec.bottomAnchor:ClearAllPoints()
      sec.bottomAnchor:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -SECTION_PAD)
    else
      -- Collapsed: snap bottomAnchor right under the header row so the
      -- next section's separator (or, when hidden, its toggle) pulls up
      -- tight against this one. Minimal pad — no breathing room needed
      -- when there's no content above to separate from.
      sec.bottomAnchor:ClearAllPoints()
      sec.bottomAnchor:SetPoint("TOPLEFT", sec.toggleBtn, "BOTTOMLEFT", 0, -2)
    end
  end

  -- Resize the scroll content to the final section's bottom + a pad.
  -- Anchor-derived positions only resolve after a layout pass, so defer.
  C_Timer.After(0, function()
    if not Panel._content or not Panel._tailAnchor then return end
    local cTop = Panel._content:GetTop()
    local aBot = Panel._tailAnchor:GetBottom()
    if cTop and aBot then
      local used = (cTop - aBot) + 30
      if used < 200 then used = 200 end
      Panel._content:SetHeight(used)
    end
  end)
end

Panel.refresh = refresh

-- ===== Subcategory registration =====
local function build()
  if not (Settings and Settings.RegisterCanvasLayoutSubcategory) then return end
  local mainCategory = addon.MBLib and addon.MBLib._optionsCategory
  if not mainCategory then return end

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
