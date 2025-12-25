local addonName, addon = ...

local configFrame
local replyListScroll -- Reference for updating the list

function addon:CreateConfig()
    if configFrame then return configFrame end
    
    -- Main Frame
    local f = CreateFrame("Frame", "MeowerConfigFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(600, 500) -- Increased size for list
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
    
    -- Version
    local version = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    version:SetPoint("BOTTOMRIGHT", -15, 10)
    version:SetText("Version: " .. addon.version)
    version:SetTextColor(0.5, 0.5, 0.5)
    
    -- Content Container
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", 20, -40)
    content:SetPoint("BOTTOMRIGHT", -20, 20)
    
    -- == General Settings Section ==
    local generalHeader = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    generalHeader:SetPoint("TOPLEFT", 0, 0)
    generalHeader:SetText("General Settings")
    
    local enableCb = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    enableCb:SetPoint("TOPLEFT", generalHeader, "BOTTOMLEFT", 0, -5)
    enableCb.text:SetText("Enable Addon")
    enableCb:SetChecked(MeowerDB.enabled)
    enableCb:SetScript("OnClick", function(self) MeowerDB.enabled = self:GetChecked() end)
    
    local welcomeCb = CreateFrame("CheckButton", nil, content, "UICheckButtonTemplate")
    welcomeCb:SetPoint("LEFT", enableCb.text, "RIGHT", 20, 0)
    welcomeCb.text:SetText("Show Welcome Message")
    welcomeCb:SetChecked(MeowerDB.showWelcome)
    welcomeCb:SetScript("OnClick", function(self) MeowerDB.showWelcome = self:GetChecked() end)
    
    -- == Auto Replies Section ==
    local replyHeader = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    replyHeader:SetPoint("TOPLEFT", enableCb, "BOTTOMLEFT", 0, -20)
    replyHeader:SetText("Auto Replies")
    
    -- List Container (ScrollFrame)
    local scrollFrame = CreateFrame("ScrollFrame", nil, content, "UIPanelScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", replyHeader, "BOTTOMLEFT", 0, -10)
    scrollFrame:SetPoint("BOTTOMRIGHT", -30, 40)
    
    -- Background for list
    local listBg = scrollFrame:CreateTexture(nil, "BACKGROUND")
    listBg:SetAllPoints()
    listBg:SetColorTexture(0, 0, 0, 0.3)
    
    local scrollChild = CreateFrame("Frame")
    scrollChild:SetSize(scrollFrame:GetWidth(), 400) -- Height dynamic?
    scrollFrame:SetScrollChild(scrollChild)
    replyListScroll = scrollChild
    
    -- Refresh Function
    local function RefreshReplyList()
        -- Clear existing children (simple way: hide them and reuse or just recreate for this basic example)
        -- For a proper efficient list, we'd use a hybrid scroll frame or object pool. 
        -- For "Basics", we'll just wipe and recreate (careful with memory, but acceptable for small lists).
        
        local kids = { scrollChild:GetChildren() }
        for _, kid in ipairs(kids) do
            kid:Hide()
            kid:SetParent(nil)
        end
        
        local yOffset = 0
        local rowHeight = 40
        
        for i, reply in ipairs(MeowerDB.replies) do
            local row = CreateFrame("Frame", nil, scrollChild, "BackdropTemplate")
            row:SetSize(520, rowHeight)
            row:SetPoint("TOPLEFT", 0, yOffset)
            row:SetBackdrop({bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background", tile = true, tileSize = 16})
            row:SetBackdropColor(0.2, 0.2, 0.2, 0.5)
            
            -- Label: When I receive...
            local triggerLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            triggerLabel:SetPoint("LEFT", 10, 0)
            triggerLabel:SetText("Trigger: " .. (reply.trigger or "?"))
            
            -- Label: I reply with...
            local responseLabel = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            responseLabel:SetPoint("LEFT", 150, 0)
            if reply.replyType == "EMOTE" then
                 responseLabel:SetText("Emote: " .. reply.replyValue)
            else
                 responseLabel:SetText("Custom: " .. reply.replyValue)
            end
            
            -- Delete Button
            local delBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            delBtn:SetSize(60, 20)
            delBtn:SetPoint("RIGHT", -10, 0)
            delBtn:SetText("Delete")
            delBtn:SetScript("OnClick", function()
                table.remove(MeowerDB.replies, i)
                RefreshReplyList()
            end)
            
            yOffset = yOffset - rowHeight - 2
        end
        
        scrollChild:SetHeight(math.abs(yOffset))
    end
    
    addon.RefreshReplyList = RefreshReplyList
    RefreshReplyList()
    
    -- == Add New Reply Controls (Bottom) ==
    local addPanel = CreateFrame("Frame", nil, content)
    addPanel:SetHeight(40)
    addPanel:SetPoint("TOPLEFT", scrollFrame, "BOTTOMLEFT", 0, -5)
    addPanel:SetPoint("RIGHT", 0, 0)
    
    -- Dropdown: Trigger Emote
    -- Simplified "dropdown" as a button that cycles or a hybrid
    -- Implementing a full UIDropDownMenu in Lua without XML is verbose.
    -- We'll use a simpler EditBox approach for "Trigger Token" for now, or assume usage of LibUIDropDownMenu if available.
    -- Since we want "Basics", we'll make a helper for a simple selector.
    
    -- Let's use a "Select Trigger" button that shows a list? 
    -- Or just an EditBox where user types "POKE"? 
    -- The user requirement: "Select from available emotes".
    
    -- Trigger Selection
    local triggerInput = CreateFrame("EditBox", nil, addPanel, "InputBoxTemplate")
    triggerInput:SetSize(100, 20)
    triggerInput:SetPoint("LEFT", 5, 0)
    triggerInput:SetAutoFocus(false)
    triggerInput:SetText("POKE") -- Default
    
    local triggerLabel = addPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    triggerLabel:SetPoint("BOTTOMLEFT", triggerInput, "TOPLEFT", 0, 2)
    triggerLabel:SetText("Trigger (Token)")
    
    -- Reply Type
    local typeBtn = CreateFrame("Button", nil, addPanel, "UIPanelButtonTemplate")
    typeBtn:SetSize(80, 20)
    typeBtn:SetPoint("LEFT", triggerInput, "RIGHT", 10, 0)
    typeBtn:SetText("EMOTE")
    typeBtn.value = "EMOTE"
    typeBtn:SetScript("OnClick", function(self)
        if self.value == "EMOTE" then
            self.value = "CUSTOM"
            self:SetText("CUSTOM")
        else
            self.value = "EMOTE"
            self:SetText("EMOTE")
        end
    end)
    
    local typeLabel = addPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    typeLabel:SetPoint("BOTTOMLEFT", typeBtn, "TOPLEFT", 0, 2)
    typeLabel:SetText("Reply Type")

    -- Reply Value
    local valInput = CreateFrame("EditBox", nil, addPanel, "InputBoxTemplate")
    valInput:SetSize(150, 20)
    valInput:SetPoint("LEFT", typeBtn, "RIGHT", 10, 0)
    valInput:SetAutoFocus(false)
    valInput:SetText("PURR") -- Default
    
    local valLabel = addPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    valLabel:SetPoint("BOTTOMLEFT", valInput, "TOPLEFT", 0, 2)
    valLabel:SetText("Reply (Token/Text)")
    
    -- Add Button
    local addBtn = CreateFrame("Button", nil, addPanel, "UIPanelButtonTemplate")
    addBtn:SetSize(80, 20)
    addBtn:SetPoint("LEFT", valInput, "RIGHT", 10, 0)
    addBtn:SetText("Add Rule")
    addBtn:SetScript("OnClick", function()
        local trig = triggerInput:GetText():upper()
        local rType = typeBtn.value
        local rVal = valInput:GetText()
        
        if trig and rVal and trig ~= "" and rVal ~= "" then
            tinsert(MeowerDB.replies, {
                trigger = trig,
                replyType = rType,
                replyValue = rVal
            })
            RefreshReplyList()
            triggerInput:SetText("")
            valInput:SetText("")
        else
            print("Invalid input")
        end
    end)

    -- Helper to show available emotes? 
    -- We can add a "List Emotes" button that prints them to chat for now to keep UI code "basic".
    local listBtn = CreateFrame("Button", nil, addPanel, "UIPanelButtonTemplate")
    listBtn:SetSize(80, 20)
    listBtn:SetPoint("LEFT", addBtn, "RIGHT", 10, 0)
    listBtn:SetText("Help")
    listBtn:SetScript("OnClick", function()
        print("Available Emote Tokens:")
        local list = addon.EmoteProvider:GetAvailableEmotes()
        for i=1, 10 do -- just show first few
             if list[i] then print(list[i].token) end
        end
        print("... see EmoteProvider.lua for more.")
    end)
    
    configFrame = f
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
        if addon.RefreshReplyList then addon.RefreshReplyList() end
    end
end
