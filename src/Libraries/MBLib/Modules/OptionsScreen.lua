local addonName, addon = ...
local MBLib = addon.MBLib

local OptionsScreen = {}

local function IsAddonInstalled(name)
  if C_AddOns and C_AddOns.GetAddOnInfo then
    local resolved = C_AddOns.GetAddOnInfo(name)
    return resolved ~= nil
  end
  return false
end

local function GetDefaultValueLabel(def)
  if not def then return "" end
  if def.Type == "dropdown" and def.Options and #def.Options > 0 then
    for _, opt in ipairs(def.Options) do
      if type(opt) == "table" and opt.value ~= nil and opt.name ~= nil then
        if opt.value == def.Default then
          return tostring(opt.name)
        end
      elseif opt == def.Default then
        return tostring(opt)
      end
    end
  end
  return tostring(def.Default)
end

local function BuildSettingDescription(def)
  local base = def.Description or ""
  local defaultLabel = GetDefaultValueLabel(def)
  local suffix = "(Default: " .. defaultLabel .. ")"
  if base == "" then return suffix end
  return base .. "\n" .. suffix
end

local function CreateCommandList(parent, anchor, startOffsetX)
  local triggers = MBLib.Commands:GetTriggers()
  local usageText = "Usage: " .. table.concat(triggers, " [command] or ") .. " [command]"

  local usageFS = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  usageFS:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", startOffsetX, -5)
  usageFS:SetTextColor(0.7, 0.7, 0.7)
  usageFS:SetText(usageText)

  local lastCmd = usageFS
  if MBLib.Commands and MBLib.Commands.list then
    local keys = {}
    for k, info in pairs(MBLib.Commands.list) do
      if not info.hidden then table.insert(keys, k) end
    end
    table.sort(keys)

    for i, cmd in ipairs(keys) do
      local info = MBLib.Commands.list[cmd]
      local cmdText = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
      if i == 1 then
        cmdText:SetPoint("TOPLEFT", lastCmd, "BOTTOMLEFT", 0, -15)
      else
        cmdText:SetPoint("TOPLEFT", lastCmd, "TOPLEFT", 0, -18)
      end
      cmdText:SetText(MBLib.Commands:GetFormattedCommandStr(cmd, info.desc))
      lastCmd = cmdText
    end
  end
  return lastCmd
end

local function CreateSeparatorBelow(parent, anchor, offsetX, offsetY)
  local line = parent:CreateTexture(nil, "ARTWORK")
  line:SetHeight(1)
  line:SetColorTexture(1, 1, 1, 0.2)
  line:SetPoint("LEFT", parent, "LEFT", offsetX, 0)
  line:SetPoint("RIGHT", parent, "RIGHT", -offsetX, 0)
  line:SetPoint("TOP", anchor, "BOTTOM", 0, offsetY)
  return line
end

local function CreateAddonRow(parent, lastAnchor, isFirst, info)
  local installed = IsAddonInstalled(info.name)

  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(24)
  if isFirst then
    row:SetPoint("TOPLEFT", lastAnchor, "BOTTOMLEFT", 10, -10)
  else
    row:SetPoint("TOPLEFT", lastAnchor, "BOTTOMLEFT", 0, -6)
  end
  row:SetPoint("RIGHT", parent, "RIGHT", -20, 0)

  -- Status icon (checkmark if installed, cross otherwise) with hover tooltip.
  local statusBtn = CreateFrame("Button", nil, row)
  statusBtn:SetSize(16, 16)
  statusBtn:SetPoint("LEFT", 0, 0)
  local statusFS = statusBtn:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  statusFS:SetAllPoints()
  statusFS:SetText(installed and MBLib.ICON_CHECKMARK or MBLib.ICON_CROSS)
  local tooltipText = installed
    and "You already have this addon"
    or "You don't have this addon yet"
  statusBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText(tooltipText, 1, 1, 1)
    GameTooltip:Show()
  end)
  statusBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- Addon name — always a Blizzard-style Button. Installed addons jump to
  -- their settings page; missing ones open a CopyPopup with the CurseForge
  -- author link so the user can grab the download URL.
  local nameBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  nameBtn:SetPoint("LEFT", statusBtn, "RIGHT", 6, 0)
  nameBtn:SetText(info.name)
  nameBtn:SetHeight(22)
  nameBtn:SetWidth(nameBtn:GetTextWidth() + 20)
  if installed then
    nameBtn:SetScript("OnClick", function()
      local handler = SlashCmdList[info.name:upper()]
      if handler then handler("settings") end
    end)
  else
    nameBtn:SetScript("OnClick", function()
      if MBLib.CopyPopup and MBLib.CopyPopup.Show then
        MBLib.CopyPopup:Show({
          title       = "Get " .. info.name,
          description = "Copy the link below and open it in your browser to find this addon on CurseForge.",
          text        = MBLib.AUTHOR_URL,
        })
      end
    end)
  end
  local nameAnchor = nameBtn

  -- Description fills the rest of the row.
  local desc = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  desc:SetPoint("LEFT", nameAnchor, "RIGHT", 6, 0)
  desc:SetPoint("RIGHT", row, "RIGHT", 0, 0)
  desc:SetJustifyH("LEFT")
  desc:SetJustifyV("MIDDLE")
  desc:SetWordWrap(true)
  desc:SetText("— " .. info.description)
  local h = desc:GetStringHeight()
  if h and h > row:GetHeight() then row:SetHeight(h + 4) end

  return row
end

local function CreateOtherAddonsList(parent, anchor)
  -- The header is itself a clickable Button that opens the CopyPopup with the
  -- author's CurseForge page — same affordance as the per-addon name buttons
  -- below, so the whole section reads as "click anywhere to get the link".
  local titleBtn = CreateFrame("Button", nil, parent)
  titleBtn:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 20, -20)
  titleBtn:SetHeight(18)

  local title = titleBtn:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  title:SetPoint("LEFT", titleBtn, "LEFT", 0, 0)
  title:SetText("Other Addons by MorphieBlossom:")

  -- Fit the hit region to the rendered text. GetStringWidth returns 0 before
  -- the FontString has been through a layout pass (which only happens when
  -- the canvas is first shown), so retry on the next frame until populated.
  local function fitBtn()
    local w = title:GetStringWidth()
    if w and w > 0 then
      titleBtn:SetWidth(w)
    else
      C_Timer.After(0, fitBtn)
    end
  end
  fitBtn()

  titleBtn:RegisterForClicks("LeftButtonUp")
  titleBtn:SetScript("OnClick", function()
    if MBLib.CopyPopup and MBLib.CopyPopup.Show then
      MBLib.CopyPopup:Show({
        title       = "Other addons by MorphieBlossom",
        description = "Copy the link below and open it in your browser to see all of my addons on CurseForge.",
        text        = MBLib.AUTHOR_URL,
      })
    end
  end)
  titleBtn:SetScript("OnEnter", function() title:SetTextColor(1, 1, 1) end)
  titleBtn:SetScript("OnLeave", function() title:SetTextColor(1, 0.82, 0) end)

  local lastAnchor = titleBtn
  local isFirst = true
  ---@diagnostic disable-next-line: undefined-global, undefined-field
  for _, info in ipairs(MBLib.OTHER_ADDONS or {}) do
    if info.name ~= addonName then
      lastAnchor = CreateAddonRow(parent, lastAnchor, isFirst, info)
      isFirst = false
    end
  end
  return lastAnchor
end

local function CreateMainFrame()
  local mainFrame = CreateFrame("Frame", nil)
  mainFrame:Hide()

  local iconPath = MBLib:GetIcon()
  if iconPath then
    local icon = mainFrame:CreateTexture(nil, "ARTWORK")
    icon:SetSize(96, 96)
    icon:SetPoint("TOPLEFT", 15, -15)
    icon:SetTexture(iconPath)
  end

  local title = mainFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalHuge")
  title:SetPoint("LEFT", mainFrame, "TOPLEFT", iconPath and 126 or 20, -32)
  title:SetText(C_AddOns.GetAddOnMetadata(addonName, "Title"))

  -- (The macro pickup button lives on the Settings subcategory, mounted
  -- via the MBLib_MacroButtonRowTemplate initializer in
  -- CreateSettingsCategory below. The main canvas page stays clean —
  -- just identity + version + contacts + commands.)

  -- Anchor description with TOPLEFT + RIGHT so it wraps to fit the panel
  -- width instead of overflowing on long Notes strings.
  local description = mainFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  description:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
  description:SetPoint("RIGHT", mainFrame, "RIGHT", -20, 0)
  description:SetJustifyH("LEFT")
  description:SetJustifyV("TOP")
  description:SetWordWrap(true)
  description:SetText(C_AddOns.GetAddOnMetadata(addonName, "Notes"))

  local line1 = MBLib.Utils:CreateSeparator(mainFrame, mainFrame, 15, -125)

  local creditsData = {
    "|cffffd200Version:|r " .. (C_AddOns.GetAddOnMetadata(addonName, "Version") or ""),
    "|cffffd200Author:|r " .. (C_AddOns.GetAddOnMetadata(addonName, "Author") or ""),
    "|cffffd200Last Updated:|r " .. (C_AddOns.GetAddOnMetadata(addonName, "X-Date") or ""),
  }

  local topCredits = mainFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  topCredits:SetPoint("TOPLEFT", line1, "BOTTOMLEFT", 20, -20)
  topCredits:SetJustifyH("LEFT")
  topCredits:SetSpacing(6)
  topCredits:SetText(table.concat(creditsData, "\n"))

  local contactCTA = mainFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  contactCTA:SetPoint("TOPLEFT", topCredits, "BOTTOMLEFT", 0, -30)
  contactCTA:SetText("Questions or issues? Reach out on:")

  local posAnchor = contactCTA
  local function MaybeLink(label, field, prevAnchor, firstOffsetY)
    local value = C_AddOns.GetAddOnMetadata(addonName, field)
    if value and value ~= "" then
      return MBLib.Utils:CreateCopyableLink(mainFrame, label, value, prevAnchor, 0, prevAnchor == contactCTA and (firstOffsetY or -10) or 0)
    end
    return prevAnchor
  end
  posAnchor = MaybeLink("Github:", "X-Github", posAnchor, -10)
  posAnchor = MaybeLink("CurseForge:", "X-CurseForge", posAnchor)
  posAnchor = MaybeLink("Wago.io:", "X-Wago", posAnchor)

  local predecessor = MBLib:GetPredecessor()
  if predecessor then
    local prevAuthors = {}
    for i = 1, 5 do
      local name = C_AddOns.GetAddOnMetadata(addonName, "X-PrevAuthor" .. i)
      if name and name ~= "" then table.insert(prevAuthors, name) end
    end
    if #prevAuthors > 0 then
      local subCredits = mainFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
      subCredits:SetPoint("TOPLEFT", posAnchor, "BOTTOMLEFT", 0, -25)
      subCredits:SetText("|cffaaaaaaThis is a continuation from the original addon|r |cffffd200"
        .. predecessor .. "|r |cffaaaaaaby|r "
        .. table.concat(prevAuthors, " |cffaaaaaa&|r "))
    end
  end

  local line2 = MBLib.Utils:CreateSeparator(mainFrame, mainFrame, 15, -360)
  local cmdTitle = mainFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  cmdTitle:SetPoint("TOPLEFT", line2, "BOTTOMLEFT", 20, -20)
  cmdTitle:SetText("Available Chat Commands:")
  local lastCmd = CreateCommandList(mainFrame, cmdTitle, 10)

  local line3 = CreateSeparatorBelow(mainFrame, lastCmd or cmdTitle, 15, -20)
  CreateOtherAddonsList(mainFrame, line3)

  return mainFrame
end

local function CreateSettingsCategory(parent)
  -- Collect visible settings up front; if nothing's visible, skip the
  -- subcategory entirely so consumers without configurable settings don't
  -- end up with an empty "Display Settings" page.
  local visibleByGroup = {}
  local visibleGroupOrder = {}
  for _, group in ipairs(MBLib.Settings.groupOrder) do
    local defs = MBLib.Settings.byGroup[group]
    if defs and #defs > 0 then
      local visible = {}
      for _, def in ipairs(defs) do
        if not def.Hide then table.insert(visible, def) end
      end
      if #visible > 0 then
        visibleByGroup[group] = visible
        table.insert(visibleGroupOrder, group)
      end
    end
  end

  if #visibleGroupOrder == 0 then return end

  local subcategoryName = MBLib.GetSettingsSubcategoryName and MBLib:GetSettingsSubcategoryName() or "Display Settings"
  local category, layout = Settings.RegisterVerticalLayoutSubcategory(parent, subcategoryName)
  MBLib._settingsSubcategory = category

  -- Optional macro pickup button — mounted into the chrome of the
  -- SettingsPanel (next to "Defaults"), only visible while this
  -- subcategory is the active one. See MacroButton:MountInTopBar.
  if MBLib._macroButton and MBLib.MacroButton and MBLib.MacroButton.MountInTopBar then
    MBLib.MacroButton:MountInTopBar(category)
  end

  for _, group in ipairs(visibleGroupOrder) do
    layout:AddInitializer(Settings.CreateElementInitializer("SettingsListSectionHeaderTemplate", { name = group }))

    for _, def in ipairs(visibleByGroup[group]) do
      local variable = addonName .. "_" .. def.Key
      local settingDescription = BuildSettingDescription(def)
      local setting = Settings.RegisterProxySetting(
        category,
        variable,
        type(def.Default),
        def.Name,
        def.Default,
        function() return MBLib.Settings:Get(def.Key) end,
        function(value) MBLib.Settings:Set(def.Key, value) end
      )

      if def.Type == "checkbox" then
        Settings.CreateCheckbox(category, setting, settingDescription)
      elseif def.Type == "dropdown" then
        local function GetOptions()
          local container = Settings.CreateControlTextContainer()
          for _, opt in ipairs(def.Options or {}) do
            if type(opt) == "table" and opt.name and opt.value then
              container:Add(opt.value, opt.name)
            else
              container:Add(opt, tostring(opt))
            end
          end
          return container:GetData()
        end
        Settings.CreateDropdown(category, setting, GetOptions, settingDescription)
      elseif def.Type == "slider" then
        local minValue = def.Min or 0
        local maxValue = def.Max or 100
        local step = def.Step or 1
        local options = Settings.CreateSliderOptions(minValue, maxValue, step)
        options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
        Settings.CreateSlider(category, setting, options, settingDescription)
      end
    end
  end
end

local function CreateReleaseNotesCategory(parent)
  local releaseFrame = CreateFrame("Frame", nil)
  releaseFrame:Hide()

  local title = releaseFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 20, -20)
  title:SetText(addonName .. " - Release Notes")

  local settingKey = "GetNotified"
  local def = MBLib.Settings.byKey[settingKey]
  if def then
    local cb = CreateFrame("CheckButton", nil, releaseFrame, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("BOTTOMRIGHT", releaseFrame, "TOPRIGHT", -200, -45)
    cb.Text:SetText(def.Name)
    cb:SetChecked(MBLib.Settings:Get(settingKey))

    cb:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:SetText(def.Name, 1, 1, 1)
      GameTooltip:AddLine(def.Description, nil, nil, nil, true)
      GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    cb:SetScript("OnShow", function(self) self:SetChecked(MBLib.Settings:Get(settingKey)) end)
    cb:SetScript("OnClick", function(self) MBLib.Settings:Set(settingKey, self:GetChecked()) end)
  end

  local line = MBLib.Utils:CreateSeparator(releaseFrame, releaseFrame, 15, -50)

  local scrollFrame = CreateFrame("ScrollFrame", nil, releaseFrame, "UIPanelScrollFrameTemplate")
  scrollFrame:SetPoint("TOPLEFT", line, "BOTTOMLEFT", 0, -10)
  scrollFrame:SetPoint("BOTTOMRIGHT", releaseFrame, "BOTTOMRIGHT", -30, 20)

  local content = CreateFrame("Frame", nil, scrollFrame)
  content:SetSize(650, 1)
  scrollFrame:SetScrollChild(content)
  if MBLib.Changelog and MBLib.Changelog.Build then
    MBLib.Changelog:Build(content)
  end

  Settings.RegisterCanvasLayoutSubcategory(parent, releaseFrame, "Release Notes")
end

function OptionsScreen:Build()
  if not Settings then return end

  local mainFrame = CreateMainFrame()
  local mainCategory = Settings.RegisterCanvasLayoutCategory(mainFrame, addonName)
  CreateSettingsCategory(mainCategory)

  Settings.RegisterAddOnCategory(mainCategory)

  MBLib._optionsCategory = mainCategory
  MBLib._optionsScreenID = mainCategory:GetID()

  -- Release Notes registers LAST so consumer-registered sub-pages (e.g.
  -- canvas sub-categories added on PLAYER_LOGIN by the consumer addon)
  -- sit above it in the Settings list. The Settings API renders children
  -- in registration order with no built-in reorder primitive, so the only
  -- reliable way to land Release Notes at the bottom is to defer until
  -- after consumer PLAYER_LOGIN handlers have run.
  local function registerReleaseNotes()
    C_Timer.After(0, function() CreateReleaseNotesCategory(mainCategory) end)
  end
  if IsLoggedIn() then
    registerReleaseNotes()
  else
    local f = CreateFrame("Frame")
    f:RegisterEvent("PLAYER_LOGIN")
    f:SetScript("OnEvent", function(frame)
      registerReleaseNotes()
      frame:UnregisterEvent("PLAYER_LOGIN")
      frame:SetScript("OnEvent", nil)
    end)
  end

  return mainCategory
end

MBLib.OptionsScreen = OptionsScreen
