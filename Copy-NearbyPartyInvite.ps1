# Copies this addon into WoW's Interface\AddOns\NearbyPartyInvite.
# The first run saves the AddOns folder in .addons-path (not committed).
# Later runs, including -Watch, reuse that path.
#
#   powershell -ExecutionPolicy Bypass -File .\Copy-NearbyPartyInvite.ps1 -AddOnsPath "D:\WoW\Interface\AddOns"
#   powershell -ExecutionPolicy Bypass -File .\Copy-NearbyPartyInvite.ps1 -Watch

param(
    [string]$AddOnsPath,
    [switch]$Watch
)

$ErrorActionPreference = "Stop"
$Source = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Source ".addons-path"
$Patterns = @("*.lua", "*.toc", "*.tga", "*.blp", "*.xml")

function Resolve-AddOnsPath {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Folder not found: $Path"
    }
    $full = (Resolve-Path -LiteralPath $Path).Path
    if ((Split-Path -Leaf $full) -eq "NearbyPartyInvite") {
        $full = Split-Path -Parent $full
    }
    if ((Split-Path -Leaf $full) -eq "AddOns") {
        return $full
    }
    $nested = Join-Path $full "Interface\AddOns"
    if (Test-Path -LiteralPath $nested) {
        return (Resolve-Path -LiteralPath $nested).Path
    }
    throw "Pass your Interface\AddOns folder, or the WoW folder that contains it. Got: $full"
}

function Find-AddOnsPath {
    $roots = @(
        $env:USERPROFILE,
        ${env:ProgramFiles},
        ${env:ProgramFiles(x86)}
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -Unique

    $found = New-Object System.Collections.Generic.List[string]
    foreach ($root in $roots) {
        Write-Host "Looking for BuffRadar under $root ..."
        Get-ChildItem -LiteralPath $root -Filter "BuffRadar.toc" -Recurse -Depth 8 -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                $addons = $_.Directory.Parent.FullName
                if ((Split-Path -Leaf $addons) -eq "AddOns" -and -not $found.Contains($addons)) {
                    $found.Add($addons)
                }
            }
    }
    return $found
}

function global:Copy-NPIAddon {
    param([string]$DestinationRoot)
    $dest = Join-Path $DestinationRoot "NearbyPartyInvite"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $files = foreach ($pattern in $Patterns) {
        Get-ChildItem -LiteralPath $Source -Filter $pattern -File -ErrorAction SilentlyContinue
    }
    if (-not $files) {
        throw "No addon files found in $Source"
    }
    foreach ($file in $files) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $dest $file.Name) -Force
    }
    Write-Host ("Copied {0} file(s) to {1}" -f @($files).Count, $dest)
}

if (-not $AddOnsPath -and (Test-Path -LiteralPath $ConfigPath)) {
    $AddOnsPath = (Get-Content -LiteralPath $ConfigPath -Raw).Trim()
}
if (-not $AddOnsPath -and $env:NPI_ADDONS) {
    $AddOnsPath = $env:NPI_ADDONS
}
if (-not $AddOnsPath) {
    $foundFolders = @(Find-AddOnsPath)
    if ($foundFolders.Count -eq 1) {
        $AddOnsPath = $foundFolders[0]
        Write-Host "Using AddOns folder next to BuffRadar: $AddOnsPath"
    } elseif ($foundFolders.Count -gt 1) {
        Write-Host "Found more than one AddOns folder. Run again with -AddOnsPath and one of these:"
        $foundFolders | ForEach-Object { Write-Host "  $_" }
        exit 1
    } else {
        Write-Host "Could not find BuffRadar. Run once with the path to Interface\AddOns:"
        Write-Host "  powershell -ExecutionPolicy Bypass -File .\Copy-NearbyPartyInvite.ps1 -AddOnsPath `"C:\Path\To\Interface\AddOns`""
        exit 1
    }
}

$AddOnsPath = Resolve-AddOnsPath $AddOnsPath
Set-Content -LiteralPath $ConfigPath -Value $AddOnsPath -Encoding ascii
Copy-NPIAddon $AddOnsPath

if (-not $Watch) {
    exit 0
}

Write-Host "Watching $Source for changes. Press Ctrl+C to stop."
$watcher = New-Object System.IO.FileSystemWatcher
$watcher.Path = $Source
$watcher.Filter = "*.*"
$watcher.IncludeSubdirectories = $false
$watcher.NotifyFilter = [System.IO.NotifyFilters]"FileName, LastWrite, Size"
$watcher.EnableRaisingEvents = $true

$copyAction = {
    $name = $Event.SourceEventArgs.Name
    if ($name -notmatch '\.(lua|toc|tga|blp|xml)$') {
        return
    }
    $state = $Event.MessageData
    $now = Get-Date
    if (($now - $state.LastCopy).TotalMilliseconds -lt 500) {
        return
    }
    $state.LastCopy = $now
    Start-Sleep -Milliseconds 200
    $dest = Join-Path $state.AddOnsPath "NearbyPartyInvite"
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    $copied = foreach ($pattern in $state.Patterns) {
        Get-ChildItem -LiteralPath $state.Source -Filter $pattern -File -ErrorAction SilentlyContinue
    }
    foreach ($file in @($copied)) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $dest $file.Name) -Force
    }
    Write-Host ("Copied {0} file(s) to {1}" -f @($copied).Count, $dest)
}
$watchState = [pscustomobject]@{
    Source = $Source
    AddOnsPath = $AddOnsPath
    Patterns = $Patterns
    LastCopy = [datetime]::MinValue
}

$job = Register-ObjectEvent -InputObject $watcher -EventName Changed -MessageData $watchState -Action $copyAction
$job2 = Register-ObjectEvent -InputObject $watcher -EventName Created -MessageData $watchState -Action $copyAction
$job3 = Register-ObjectEvent -InputObject $watcher -EventName Renamed -MessageData $watchState -Action $copyAction
try {
    while ($true) {
        Wait-Event -Timeout 1 | Out-Null
    }
} finally {
    Unregister-Event -SourceIdentifier $job.Name -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $job2.Name -ErrorAction SilentlyContinue
    Unregister-Event -SourceIdentifier $job3.Name -ErrorAction SilentlyContinue
    $watcher.Dispose()
}
