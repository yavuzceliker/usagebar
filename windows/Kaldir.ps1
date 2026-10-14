$ErrorActionPreference = "Continue"
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like "*UsageBar.ps1*" -or $_.CommandLine -like "*CursorExtraSpend.ps1*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1

$startup = [Environment]::GetFolderPath("Startup")
foreach ($name in "UsageBar.lnk", "Cursor Extra Spend.lnk") {
    $lnk = Join-Path $startup $name
    if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
}
foreach ($name in "UsageBar", "CursorExtraSpend") {
    $dir = Join-Path $env:LOCALAPPDATA $name
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
}
Write-Output "Kaldirildi. Windows acilisindan da silindi. (Ayarlar da silindi.)"
