$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $Root

$MinRam = if ($env:MIN_RAM) { $env:MIN_RAM } else { "1G" }
$MaxRam = if ($env:MAX_RAM) { $env:MAX_RAM } else { "2G" }

if (-not (Test-Path "server.jar")) {
    Write-Error "server.jar missing. Run .\setup.ps1 first."
}

$eula = Get-Content "eula.txt" -Raw
if ($eula -notmatch '(?im)^\s*eula\s*=\s*true\s*$') {
    Write-Error "EULA not accepted. Edit eula.txt and set eula=true after reading https://aka.ms/MinecraftEULA"
}

if (-not (Get-Command java -ErrorAction SilentlyContinue)) {
    Write-Error "Java not found. Minecraft 1.21.4 requires Java 21+."
}

Write-Host "Starting Minecraft 1.21.4 ( -Xms$MinRam -Xmx$MaxRam )..."
& java "-Xms$MinRam" "-Xmx$MaxRam" -jar server.jar nogui
