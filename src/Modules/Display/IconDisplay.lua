local _, addon = ...

-- ===== addon.IconDisplay =====
-- Wires per-watcher icon notifications to MBLib.IconFrame instances.
-- Each watcher that has notifications.icon.fileID set gets its own
-- IconFrame, registered as a mover via MBLib.Movers so the user can
-- position it through Settings → Movers (bulk) or the per-watcher Mover
-- button in the edit form (single).
--
-- Lifecycle:
--   On dispatch -> IconDisplay:Show(watcher) flashes the icon for the
--                  watcher's configured fadeSeconds.
--   On watcher edit -> WatchersPanel calls Rebuild(watcher) so size /
--                      picked icon / position changes take effect
--                      immediately without a /reload.
--   On watcher delete -> WatchersPanel calls Forget(watcherID) so the
--                        frame is torn down and unregistered from Movers.
--
-- The mover registry id is the watcher id, namespaced. This way two
-- watchers with the same displayName don't collide on the registry side.

local IconDisplay = {}
addon.IconDisplay = IconDisplay

local MBLib = addon.MBLib

-- watcherID -> { iconFrame = <MBLib.IconFrame instance>, registryId = "..." }
IconDisplay._byWatcher = {}

local function moverRegistryId(watcher)
  return "Meower_Icon_" .. tostring(watcher.id)
end

local function moverDisplayName(watcher)
  local L = addon.L
  local name = watcher.name or ""
  if name == "" then
    return L.EDIT_NOTIFY_ICON_MOVER_UNNAMED
  end
  return L.EDIT_NOTIFY_ICON_MOVER_NAME_FMT:format(name)
end

-- ===== Position handling =====
-- watcher.notifications.icon.position is the anchor tuple MBLib.Movers
-- writes back from Save. nil means "never positioned" — we drop the frame
-- at screen center so the user can find it.

local function applyPosition(iconFrame, pos)
  local f = iconFrame:GetIconFrame()
  f:ClearAllPoints()
  if pos and pos.point then
    -- relativeTo defaults to parent when nil. The captured tuple from
    -- MBLib.Movers omits relativeTo (anchors to UIParent implicitly), so
    -- the third positional is the relativePoint.
    f:SetPoint(pos.point, UIParent, pos.relativePoint or pos.point, pos.xOfs or 0, pos.yOfs or 0)
  else
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  end
end

-- ===== Per-watcher frame lifecycle =====

local function makeIconFrame(watcher)
  local name = "Meower_IconFrame_" .. tostring(watcher.id)
  local frame = MBLib.IconFrame:Create(name)
  local ic = watcher.notifications.icon
  frame:SetIcon(ic.fileID)
  frame:SetIconSize(ic.size)
  applyPosition(frame, ic.position)
  -- Frame strata above MEDIUM so the icon sits over most UI but below
  -- modal dialogs; DIALOG would put it over the picker which is wrong.
  frame:GetIconFrame():SetFrameStrata("HIGH")
  return frame
end

local function ensureRecord(watcher)
  local rec = IconDisplay._byWatcher[watcher.id]
  if rec then return rec end
  local iconFrame = makeIconFrame(watcher)
  local registryId = moverRegistryId(watcher)
  rec = { iconFrame = iconFrame, registryId = registryId }
  IconDisplay._byWatcher[watcher.id] = rec

  -- Register as a mover so Settings → Movers can bulk-edit, and the
  -- per-row Show button can drive the single-frame Mover flow. onSave
  -- writes the new position back into the watcher's SavedVariables block.
  -- previewIcon lets the Movers panel render the actual configured icon
  -- next to the row name instead of a generic dot.
  MBLib.Movers:Register(registryId, {
    frame       = iconFrame:GetIconFrame(),
    displayName = moverDisplayName(watcher),
    previewIcon = watcher.notifications.icon.fileID,
    onSave      = function(pos)
      watcher.notifications.icon.position = {
        point         = pos.point,
        relativePoint = pos.relativePoint,
        xOfs          = pos.xOfs,
        yOfs          = pos.yOfs,
      }
    end,
    -- Per-frame size slider routed through the Mover accessory. get/set
    -- read and write the watcher's saved size and live-resize the frame.
    sizeSlider  = {
      min  = addon.Constants.ICON_MIN_SIZE,
      max  = addon.Constants.ICON_MAX_SIZE,
      step = 1,
      get  = function() return watcher.notifications.icon.size or addon.Constants.ICON_DEFAULT_SIZE end,
      set  = function(size)
        watcher.notifications.icon.size = size
        iconFrame:SetIconSize(size)
      end,
    },
  })
  return rec
end

local function tearDownRecord(watcherID)
  local rec = IconDisplay._byWatcher[watcherID]
  if not rec then return end
  MBLib.Movers:Unregister(rec.registryId)
  rec.iconFrame:CancelFlash()
  -- Remove the frame from the scene. SetParent(nil) detaches; the texture
  -- is GC'd whenever Lua decides. There's no Destroy primitive for
  -- WoW frames, but this is the standard "let it go" pattern.
  local f = rec.iconFrame:GetIconFrame()
  f:Hide()
  f:SetParent(nil)
  IconDisplay._byWatcher[watcherID] = nil
end

-- ===== Public API =====

-- Called from the dispatcher when a watcher fires. No-op when the watcher
-- has no icon configured — fileID == nil means "icon disabled for this
-- watcher".
function IconDisplay:Show(watcher)
  if type(watcher) ~= "table" then return end
  local ic = watcher.notifications and watcher.notifications.icon
  if not ic or not ic.fileID then return end
  local rec = ensureRecord(watcher)
  -- Re-apply icon + size in case the watcher's config changed since the
  -- frame was created (Edit form path is supposed to call Rebuild but
  -- this is cheap defense in depth).
  rec.iconFrame:SetIcon(ic.fileID)
  rec.iconFrame:SetIconSize(ic.size)
  rec.iconFrame:Flash(ic.fadeSeconds or addon.Constants.ICON_DEFAULT_FADE)
end

-- Rebuild a watcher's frame state from its current SavedVariables. Called
-- by WatchersPanel after a Save in the edit form: picks up new icon /
-- size / position without forcing /reload.
function IconDisplay:Rebuild(watcher)
  if type(watcher) ~= "table" then return end
  local ic = watcher.notifications and watcher.notifications.icon
  if not ic or not ic.fileID then
    -- Icon was cleared. Tear down so we don't leak a registered mover
    -- with no icon set on it.
    self:Forget(watcher.id)
    return
  end
  local rec = self._byWatcher[watcher.id]
  if rec then
    -- Existing frame: refresh icon, size, position, and the mover's
    -- displayName in case the watcher was renamed.
    rec.iconFrame:SetIcon(ic.fileID)
    rec.iconFrame:SetIconSize(ic.size)
    applyPosition(rec.iconFrame, ic.position)
    -- Keep the mover-registry spec in sync with the latest watcher
    -- config so the Settings → Movers panel shows the current icon and
    -- display name next time it rebuilds rows.
    local spec = MBLib.Movers:Get(rec.registryId)
    if spec then
      spec.displayName = moverDisplayName(watcher)
      spec.previewIcon = ic.fileID
    end
  else
    ensureRecord(watcher)
  end
end

-- Tear down a watcher's frame entirely. Called on watcher delete.
function IconDisplay:Forget(watcherID)
  tearDownRecord(watcherID)
end

-- ===== Edit-form preview =====
-- Used by WatchersPanel's Test and Mover buttons. The watcher being
-- edited may not exist yet (new watcher) or may have just-changed icon
-- settings that haven't been persisted yet, so we don't reuse the
-- per-watcher IconDisplay frame. A singleton preview frame is enough.

function IconDisplay:GetPreviewFrame(iconConfig)
  if not iconConfig then return nil end
  if not self._preview then
    self._preview = MBLib.IconFrame:Create("Meower_IconPreview")
    self._preview:GetIconFrame():SetFrameStrata("HIGH")
  end
  self._preview:SetIcon(iconConfig.fileID)
  self._preview:SetIconSize(iconConfig.size or addon.Constants.ICON_DEFAULT_SIZE)
  applyPosition(self._preview, iconConfig.position)
  return self._preview
end

-- Flash the preview frame with the given config. Used by the Test button
-- in the edit form so the user can verify the picked icon + fade duration
-- without saving the watcher first.
function IconDisplay:Preview(iconConfig)
  if not iconConfig or not iconConfig.fileID then return end
  local frame = self:GetPreviewFrame(iconConfig)
  if not frame then return end
  frame:Flash(iconConfig.fadeSeconds or addon.Constants.ICON_DEFAULT_FADE)
end

-- Called once from Init.lua after Watchers:Init has normalized watchers
-- and SavedVariables are ready. Walks every existing watcher with an icon
-- configured and pre-creates its frame so the mover registry is populated
-- before the Settings → Movers panel is first opened.
function IconDisplay:Init()
  if self._initialized then return end
  self._initialized = true
  if not (addon.Watchers and addon.Watchers.GetAll) then return end
  for _, w in ipairs(addon.Watchers:GetAll()) do
    local ic = w.notifications and w.notifications.icon
    if ic and ic.fileID then
      ensureRecord(w)
    end
  end
end
