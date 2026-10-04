param(
    [ValidateSet("opengl3", "opengl3_angle")]
    [string]$RenderingDriver = "opengl3"
)

$ErrorActionPreference = "Stop"
$deepScript = Join-Path $PSScriptRoot "SpaceMinerWindowsDeepDiagnostics.ps1"
if (-not (Test-Path -LiteralPath $deepScript)) {
    throw "Missing diagnostic script: $deepScript"
}

& $deepScript -RenderingDriver $RenderingDriver

$driverTag = $RenderingDriver -replace '[^A-Za-z0-9_-]', '_'
$files = @(
    "SpaceMinerPerformance.log",
    "SpaceMinerGame.log",
    "SpaceMinerHeartbeat.log",
    "SpaceMinerFrameStages.log"
)

foreach ($name in $files) {
    $source = Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $source)) {
        continue
    }

    $base = [System.IO.Path]::GetFileNameWithoutExtension($name)
    $extension = [System.IO.Path]::GetExtension($name)
    $destination = Join-Path $PSScriptRoot ("{0}-{1}{2}" -f $base, $driverTag, $extension)
    Copy-Item -LiteralPath $source -Destination $destination -Force
}

Write-Host ""
Write-Host "Preserved Godot diagnostics for renderer: $RenderingDriver"
Write-Host "Files are tagged with: $driverTag"
