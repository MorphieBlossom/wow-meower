# --- Settings ---
$srcDir       = "./src"
$projectName  = "Meower"

# Define targets here (extend as needed)
$options = @(
  [pscustomobject]@{ Name = "Retail"; Dir = "_retail_";  TocSuffix = ""      }, # uses Meower.toc
  [pscustomobject]@{ Name = "PTR";    Dir = "_ptr_";     TocSuffix = ""      } # uses Meower.toc
)

# Resolve WoW root
$wowRoot = Join-Path ${env:PROGRAMFILES(X86)} "World of Warcraft"

# --- Menu ---
Write-Host "Select target client:"
for ($i = 0; $i -lt $options.Count; $i++) {
  $o = $options[$i]
  Write-Host ("  {0}: {1}" -f ($i + 1), $o.Name)
}
$choice = Read-Host "Enter option index"

if ($choice -notmatch '^\d+$' -or [int]$choice -lt 0 -or [int]$choice -ge $options.Count + 1) {
  Write-Error "Invalid selection."
  exit 1
}
$target = $options[([int]$choice - 1)]

# Determine which TOC file to use from suffix
$tocWanted = if ([string]::IsNullOrWhiteSpace($target.TocSuffix)) {
  Join-Path $srcDir "$projectName.toc"
} else {
  Join-Path $srcDir ("{0}_{1}.toc" -f $projectName, $target.TocSuffix)
}

if (!(Test-Path $tocWanted)) {
  Write-Error "TOC not found: $tocWanted"
  exit 1
}

# Destination AddOns folder
$addonDir = Join-Path (Join-Path (Join-Path $wowRoot $target.Dir) "Interface\AddOns") $projectName

# Ensure destination exists
if (!(Test-Path $addonDir)) {
  New-Item -ItemType Directory -Path $addonDir | Out-Null
}

# Copy payload
Copy-Item -Path (Join-Path $srcDir "*") -Destination $addonDir -Recurse -Force

# Ensure only the chosen TOC is present (rename to HoverName.toc)
Get-ChildItem -Path $addonDir -Filter "$projectName*.toc" -File | Remove-Item -Force
Copy-Item -Path $tocWanted -Destination (Join-Path $addonDir "$projectName.toc") -Force

Write-Host "Installed addon for:"$target.Name -ForegroundColor Green
