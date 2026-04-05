# Backend lives outside this Flutter repo by default. Override path if needed:
#   .\scripts\run_backend.ps1 -BackendRoot 'D:\my-backend'
param(
    [string]$BackendRoot = 'C:\pipe-layout-backend'
)

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $BackendRoot

$activatePs1 = Join-Path $BackendRoot '.venv\Scripts\Activate.ps1'
$activateBat = Join-Path $BackendRoot '.venv\Scripts\activate.bat'

if (-not (Test-Path -LiteralPath $activatePs1)) {
    Write-Error "Missing venv script: $activatePs1 (create .venv in BackendRoot first)."
}

$venvOk = $false
try {
    . $activatePs1
    $venvOk = $true
} catch {
    Write-Host "Activate.ps1 failed (often execution policy). If so, run once as admin or CurrentUser:"
    Write-Host "  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned"
    Write-Host "Falling back to cmd.exe + activate.bat ..."
}

if (-not $venvOk) {
    Write-Host "LAN URL (use ipconfig for this PC's IPv4): http://<THIS-PC-IP>:8000"
    cmd /c "call `"$activateBat`" && python -m uvicorn app:app --host 0.0.0.0 --port 8000"
    exit $LASTEXITCODE
}

Write-Host "LAN URL (use ipconfig for IPv4): http://<THIS-PC-IP>:8000"
python -m uvicorn app:app --host 0.0.0.0 --port 8000
