local _, addon = ...
local MBLib = addon.MBLib

local Changelog = {}
Changelog.list = {}

-- Replace the changelog entries. Each entry is:
--   { version = "X.Y.Z", date = "YYYY-MM-DD", notify = bool, categories = { ["Cat"] = { "line", ... } } }
function Changelog:Set(list)
  if type(list) ~= "table" then return end
  self.list = list
end

-- Renders the changelog into a scroll-content frame. Uses BOTTOMLEFT-relative
-- anchoring rather than a manual totalHeight counter because GetStringHeight()
-- returns 0 before a layout pass — when a long bullet wraps to a second line,
-- the previous code under-counted its height and the next line was anchored
-- on top of the wrap. With relative anchors the engine resolves wrap-height
-- at layout time, so wrapped bullets push the next element down correctly.
--
-- Final contentFrame height is computed in a deferred pass for the same
-- reason: it depends on the bottom edge of the last laid-out element, which
-- isn't resolved until the first layout pass completes.
function Changelog:Build(contentFrame)
  local width = contentFrame:GetWidth() - 40
  local leftPadding = 15

  local prev, prevIndent = nil, leftPadding

  local function anchorBelow(fs, indent, gap)
    if not prev then
      fs:SetPoint("TOPLEFT", contentFrame, "TOPLEFT", indent, -10)
    else
      fs:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", indent - prevIndent, -gap)
    end
    prev, prevIndent = fs, indent
  end

  for entryIdx, entry in ipairs(self.list or {}) do
    local v = contentFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    v:SetWidth(width)
    v:SetJustifyH("LEFT")
    v:SetText("|cffffd200" .. entry.version .. "|r (" .. entry.date .. ")")
    anchorBelow(v, leftPadding, entryIdx == 1 and 0 or 20)

    for catName, changes in pairs(entry.categories) do
      local cat = contentFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
      cat:SetWidth(width)
      cat:SetJustifyH("LEFT")
      cat:SetText("|cffffffff" .. catName .. ":|r")
      anchorBelow(cat, leftPadding + 5, 8)

      for _, text in ipairs(changes) do
        local chg = contentFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        chg:SetWidth(width - 20)
        chg:SetJustifyH("LEFT")
        chg:SetText("|cffcccccc- " .. text .. "|r")
        anchorBelow(chg, leftPadding + 10, 4)
      end
    end
  end

  if not prev then return end
  C_Timer.After(0, function()
    local cTop = contentFrame:GetTop()
    local lBot = prev:GetBottom()
    if cTop and lBot then
      contentFrame:SetHeight((cTop - lBot) + 30)
    end
  end)
end

MBLib.Changelog = Changelog
