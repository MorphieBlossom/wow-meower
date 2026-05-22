local addonName, addon = ...
local MBLib = addon.MBLib

local Fonts = {}

-- Fonts MBLib ships and registers with LibSharedMedia on behalf of every consumer.
-- Path is relative to the consumer's Interface\AddOns\<addonName>\ root because
-- MBLib is always embedded under Libraries\MBLib\.
local EMBEDDED_FONTS = {
  Expressway = "Libraries\\MBLib\\Media\\Fonts\\Expressway.ttf",
}

local function embeddedPath(relPath)
  return ("Interface\\AddOns\\%s\\%s"):format(MBLib._addonName, relPath)
end

-- Register MBLib's bundled fonts with LibSharedMedia-3.0 if it is available.
-- Idempotent: safe to call from Init() and from any GetAvailableFonts() lookup.
function Fonts:RegisterEmbeddedFonts()
  if self._embeddedRegistered then return end
  local LSM
  pcall(function() LSM = LibStub("LibSharedMedia-3.0", true) end)
  if not LSM then return end
  self._embeddedRegistered = true
  for name, relPath in pairs(EMBEDDED_FONTS) do
    pcall(LSM.Register, LSM, "font", name, embeddedPath(relPath))
  end
end

-- Return available fonts as a list of names; second return is name -> path map.
-- Uses LibSharedMedia-3.0 via LibStub when available.
function Fonts:GetAvailableFonts()
  if self._fontList then return self._fontList, self._fontMap end

  self:RegisterEmbeddedFonts()

  local LSM
  if type(LibStub) == "table" or type(LibStub) == "function" then
    pcall(function() LSM = LibStub("LibSharedMedia-3.0", true) end)
  end
  self.LSM = LSM

  -- Fallback list when LSM is missing: always include MBLib's embedded fonts so
  -- consumers can still pick them up by name.
  local fonts = { "Friz Quadrata TT", "Expressway" }
  local fontMap = {
    ["Friz Quadrata TT"] = "Fonts\\FRIZQT__.TTF",
    ["Expressway"]       = embeddedPath(EMBEDDED_FONTS.Expressway),
  }

  if LSM then
    local ht = LSM:HashTable("font")
    if ht then
      fonts = {}
      fontMap = {}
      for name, path in pairs(ht) do
        table.insert(fonts, name)
        fontMap[name] = path
      end
      table.sort(fonts)
    end
  end

  for _, name in ipairs(fonts) do
    if not fontMap[name] and LSM then
      local ok, p = pcall(LSM.Fetch, LSM, "font", name)
      if ok and p then fontMap[name] = p end
    end
  end

  self._fontList = fonts
  self._fontMap = fontMap
  return fonts, fontMap
end

MBLib.Fonts = Fonts
