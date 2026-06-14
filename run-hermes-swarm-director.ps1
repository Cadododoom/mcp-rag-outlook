# Start Hermes Swarm Director backend app, scheduler, and critic daemon
$Dir = "C:\Users\jeffr\.gemini\antigravity\scratch\Hermes-Swarm-Director"
Set-Location $Dir

# Verify venv is set up, if not, create it and install requirements
if (-not (Test-Path "$Dir\venv")) {
    Write-Host "Creating Python virtual environment..." -ForegroundColor Yellow
    python -m venv venv
    & "$Dir\venv\Scripts\pip.exe" install -r "$Dir\requirements.txt"
}

# Start FastAPI backend
Start-Process "$Dir\venv\Scripts\python.exe" -ArgumentList "$Dir\backend\app.py" -NoNewWindow
Write-Host "Started Hermes Swarm Director API on port 9920." -ForegroundColor Green

# Start Scheduler Loop
Start-Process "$Dir\venv\Scripts\python.exe" -ArgumentList "$Dir\backend\scheduler.py" -NoNewWindow
Write-Host "Started Hermes Swarm Director Scheduler loop." -ForegroundColor Green

# Start HR Critic Daemon
Start-Process "$Dir\venv\Scripts\python.exe" -ArgumentList "$Dir\critic\critic_daemon.py" -NoNewWindow
Write-Host "Started Hermes Swarm Director HR Critic daemon." -ForegroundColor Green

# Keep the console window open to monitor logs if run interactively
Write-Host "All Hermes Swarm Director components initialized. Press Ctrl+C to exit launcher." -ForegroundColor Cyan
while ($true) { Start-Sleep -Seconds 3600 }
