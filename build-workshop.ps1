<#
.SYNOPSIS
    Rebuild the Steam Workshop staging folder for ModHotReload from this mod folder.

.DESCRIPTION
    The in-game PZ uploader (Main Menu -> Workshop -> "Create and update items") only reads
    Zomboid\Workshop\. This script regenerates that staging tree from 42.0\.

    It applies the one dev-vs-published difference automatically:
        * mod.info : id/name forced to the PUBLISHED values. The local copy uses
                     ModHotReloadLocal / "... (local)" so it can coexist with the subscribed
                     Workshop copy without an id collision.

    ModHotReload has no DEBUG flag and carries no reload.trigger / reload.filelist of its own
    (it's the watcher, not a consumer), so there is nothing else to fix up.

    Run it, then launch PZ and upload. workshop.txt is copied verbatim; preview.png if present.

.EXAMPLE
    pwsh .\build-workshop.ps1
#>
[CmdletBinding()]
param(
    # Published identity written into the staged mod.info (must match the Workshop item).
    [string]$PublishedId   = "ModHotReload",
    [string]$PublishedName = "[Dev] Hot Reload Mods"
)

$ErrorActionPreference = "Stop"

# --- resolve paths (all derived from where this script lives) --------------------------
$modRoot = $PSScriptRoot                                    # ...\Zomboid\mods\ModHotReload
$srcVer  = Join-Path $modRoot "42.0"                        # the mod payload (mod.info + media)
$zomboid = Split-Path (Split-Path $modRoot)                 # ...\Zomboid
$stage   = Join-Path $zomboid "Workshop\ModHotReload"       # what the uploader reads
$inner   = Join-Path $stage   "Contents\mods\ModHotReload\42"

$workshopTxt = Join-Path $modRoot "workshop.txt"
foreach ($p in @($srcVer, $workshopTxt)) {
    if (-not (Test-Path $p)) { throw "missing required source: $p" }
}

# --- clean rebuild so no stale files survive -------------------------------------------
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force -Confirm:$false }
New-Item -ItemType Directory -Path $inner -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $stage "Contents\mods\ModHotReload\common") -Force | Out-Null

# --- copy the mod payload (42.0\* -> Contents\...\42\); .git / this script / workshop.txt stay behind ---
Copy-Item (Join-Path $srcVer "*") $inner -Recurse -Force

# --- copy Workshop metadata to the staging root ----------------------------------------
Copy-Item $workshopTxt (Join-Path $stage "workshop.txt") -Force
$preview = Join-Path $modRoot "preview.png"
if (Test-Path $preview) {
    Copy-Item $preview (Join-Path $stage "preview.png") -Force
} else {
    Write-Host "note: no preview.png in $modRoot -- add one for a Workshop thumbnail (optional)." -ForegroundColor Yellow
}

# --- fixup: published id/name in the staged mod.info (local copy uses ModHotReloadLocal) ---
$modInfo = Join-Path $inner "mod.info"
$mi = Get-Content $modInfo -Raw
$mi = $mi -replace '(?m)^\s*name\s*=.*$', "name=$PublishedName"
$mi = $mi -replace '(?m)^\s*id\s*=.*$',   "id=$PublishedId"
Set-Content $modInfo $mi -NoNewline -Encoding utf8   # PS7 utf8 = no BOM

# --- report ----------------------------------------------------------------------------
Write-Host "Staged -> $stage" -ForegroundColor Green
Write-Host ("  mod.info : {0}" -f (Select-String -Path $modInfo -Pattern '^(id|name|modversion)=' | ForEach-Object { $_.Line.Trim() } | Join-String -Separator '  '))
Write-Host "Now launch PZ -> Workshop -> Create and update items."
