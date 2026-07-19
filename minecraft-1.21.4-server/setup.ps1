$ErrorActionPreference = "Stop"

$Version = "1.21.4"
$ExpectedSha1 = "4707d00eb834b446575d89a61a11b5d548d8c001"
$ServerJarUrl = "https://piston-data.mojang.com/v1/objects/$ExpectedSha1/server.jar"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$JarPath = Join-Path $Root "server.jar"

Set-Location $Root

function Get-FileSha1([string]$Path) {
    $hash = Get-FileHash -Path $Path -Algorithm SHA1
    return $hash.Hash.ToLowerInvariant()
}

if (Test-Path $JarPath) {
    $current = Get-FileSha1 $JarPath
    if ($current -eq $ExpectedSha1) {
        Write-Host "server.jar already present and verified ($Version)."
        exit 0
    }
    Write-Host "Existing server.jar checksum mismatch; re-downloading..."
    Remove-Item -Force $JarPath
}

Write-Host "Downloading Minecraft $Version server.jar..."
Invoke-WebRequest -Uri $ServerJarUrl -OutFile $JarPath

$actual = Get-FileSha1 $JarPath
if ($actual -ne $ExpectedSha1) {
    Write-Host "Checksum verification failed."
    Write-Host "  expected: $ExpectedSha1"
    Write-Host "  actual:   $actual"
    Remove-Item -Force $JarPath
    exit 1
}

Write-Host "Downloaded and verified Minecraft $Version server.jar"
Write-Host "Next: accept the EULA in eula.txt (set eula=true), then run .\start.ps1"
