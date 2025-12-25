local addonName, addon = ...

local configFrame

function addon:CreateConfig()
    if configFrame then return configFrame end
    
    -- Main Frame
    -- We use BasicFrameTemplateWithInset for a standard Blizzard UI look
    local f = CreateFrame("Frame", "MeowerConfigFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(400, 300)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()
    
    -- Title
    f.TitleBg:SetHeight(30)
    f.TitleText:SetText(addon.title)
    
    -- Version Display (Bottom Right)
    local version = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    version:SetPoint("BOTTOMRIGHT", -15, 10)
    version:SetText("Version: " .. addon.version)
    version:SetTextColor(0.5, 0.5, 0.5)
    
    -- Content Container
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", 20, -40)
    content:SetPoint("BOTTOMRIGHT", -20, 20)
    
    -- Settings Header
    local header = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    header:SetPoint("TOPLEFT", 0, 0)
    header:SetText("General Settings")
    
    -- Checkbox 1: Enable
    local enableCb = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    enableCb:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -10)
    enableCb.text:SetText("Enable Addon")
    enableCb:SetChecked(MeowerDB.enabled)
    enableCb:SetScript("OnClick", function(self)
        MeowerDB.enabled = self:GetChecked()
        -- In a real addon, you might want to trigger an update here
    end)
    
    -- Checkbox 2: Welcome Message
    local welcomeCb = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    welcomeCb:SetPoint("TOPLEFT", enableCb, "BOTTOMLEFT", 0, -10)
    welcomeCb.text:SetText("Show Welcome Message")
    welcomeCb:SetChecked(MeowerDB.showWelcome)
    welcomeCb:SetScript("OnClick", function(self)
        MeowerDB.showWelcome = self:GetChecked()
    end)
    
    configFrame = f
    
    -- Allow closing with Escape key
    tinsert(UISpecialFrames, "MeowerConfigFrame") 
    
    return f
end

function addon:ToggleConfig()
    if not configFrame then
        self:CreateConfig()
    end
    
    if configFrame:IsShown() then
        configFrame:Hide()
    else
        configFrame:Show()
    end
end
