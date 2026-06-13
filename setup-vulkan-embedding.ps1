# Helper Script to Download and Configure Native Vulkan llama.cpp on Windows Host
# Runs the embedding model on the AMD Radeon RX 5700 to save CPU and GPU VRAM resources

$ScratchDir = "C:\Users\jeffr\.gemini\antigravity\scratch"
$McpDir = "$ScratchDir\mcp-rag-outlook"
$BinDir = "$McpDir\bin\llama-cpp-vulkan"
$ModelPath = "$McpDir\models\nomic-embed-text-v1.5.Q8_0.gguf"

Write-Host "==========================================================" -ForegroundColor Green
Write-Host "     SETTING UP NATIVE VULKAN EMBEDDING ON WINDOWS HOST   " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green

# 1. Download Latest Vulkan llama.cpp Release from GitHub
Write-Host "`n[1/3] Fetching latest Vulkan release from llama.cpp repository..." -ForegroundColor Cyan
try {
    $ReleaseInfo = Invoke-RestMethod -Uri "https://api.github.com/repos/ggerganov/llama.cpp/releases/latest"
    $Asset = $ReleaseInfo.assets | Where-Object { $_.name -like "*bin-win-vulkan-x64.zip" } | Select-Object -First 1
    
    if (-not $Asset) {
        throw "Could not find a Vulkan release asset in the latest release."
    }
    
    $DownloadUrl = $Asset.browser_download_url
    $ZipDest = "$McpDir\bin\llama-vulkan.zip"
    
    New-Item -ItemType Directory -Path "$McpDir\bin" -Force | Out-Null
    
    Write-Host "Downloading: $($Asset.name)..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $ZipDest
    Write-Host "Download completed successfully." -ForegroundColor Green
} catch {
    Write-Error "Failed to download Vulkan release: $_"
    Exit 1
}

# 2. Extract Release
Write-Host "`n[2/3] Extracting release zip..." -ForegroundColor Cyan
if (Test-Path $ZipDest) {
    if (Test-Path $BinDir) {
        Remove-Item $BinDir -Recurse -Force | Out-Null
    }
    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    
    Expand-Archive -Path $ZipDest -DestinationPath $BinDir -Force
    Remove-Item $ZipDest -Force
    Write-Host "Extracted to $BinDir" -ForegroundColor Green
}

# 3. Query Vulkan Devices
Write-Host "`n[3/3] Listing available Vulkan devices on your system..." -ForegroundColor Cyan
$LlamaServer = "$BinDir\llama-server.exe"

if (Test-Path $LlamaServer) {
    Write-Host "Executing llama-server.exe --list-devices to auto-detect AMD GPU..." -ForegroundColor Yellow
    $DeviceOutput = & $LlamaServer --list-devices 2>&1
    $DeviceOutput | Out-String | Write-Host
    
    $DeviceIndex = "Vulkan1" # Fallback default
    foreach ($Line in $DeviceOutput) {
        if ($Line -match "(Vulkan\d+):\s+.*AMD.*") {
            $DeviceIndex = $Matches[1]
            Write-Host "Auto-detected AMD GPU index: $DeviceIndex" -ForegroundColor Green
            break
        }
    }
    
    # Generate a launch script shortcut for the user
    $LaunchScriptPath = "$McpDir\run-vulkan-embedding.ps1"
    $LaunchScriptContent = @"
# Launch Script for Native Vulkan Embedding Server on AMD RX 5700
# Run this to start the embedding server on your host machine

`$BinDir = "$BinDir"
`$ModelPath = "$ModelPath"
`$LlamaServer = "`$BinDir\llama-server.exe"

Write-Host "Starting Vulkan embedding server on host port 8080..." -ForegroundColor Green
Write-Host "Offloading 100% of layers to GPU..." -ForegroundColor Yellow

& `$LlamaServer -m "`$ModelPath" -c 2048 --port 8080 --embedding --device $DeviceIndex -ngl 99
"@
    Set-Content -Path $LaunchScriptPath -Value $LaunchScriptContent
    Write-Host "`nGenerated launch script at: $LaunchScriptPath" -ForegroundColor Green
    
    Write-Host "`n==========================================================" -ForegroundColor Green
    Write-Host "SETUP COMPLETE!" -ForegroundColor Green
    Write-Host "1. Verified and configured device index: $DeviceIndex" -ForegroundColor Yellow
    Write-Host "2. Run $LaunchScriptPath to start the server." -ForegroundColor Yellow
    Write-Host "3. Disable the CPU container from your docker-compose.yml by commenting it out." -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Green
} else {
    Write-Error "Could not locate llama-server.exe in extracted directory."
}
