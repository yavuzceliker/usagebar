$ErrorActionPreference = "Stop"
$dest = Join-Path $env:LOCALAPPDATA "UsageBar"
$startup = [Environment]::GetFolderPath("Startup")

# Stop any running copy (including the old "CursorExtraSpend" version).
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like "*UsageBar.ps1*" -or $_.CommandLine -like "*CursorExtraSpend.ps1*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep -Seconds 1

# Remove the old version.
$oldLnk = Join-Path $startup "Cursor Extra Spend.lnk"
if (Test-Path -LiteralPath $oldLnk) { Remove-Item -LiteralPath $oldLnk -Force }
$oldDir = Join-Path $env:LOCALAPPDATA "CursorExtraSpend"
if (Test-Path -LiteralPath $oldDir) { Remove-Item -LiteralPath $oldDir -Recurse -Force -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "UsageBar.ps1") -Destination $dest -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot "sqlite3.exe") -Destination $dest -Force

$script = Join-Path $dest "UsageBar.ps1"
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut((Join-Path $startup "UsageBar.lnk"))
$lnk.TargetPath = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$lnk.Arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
$lnk.WorkingDirectory = $dest
$lnk.WindowStyle = 7
$lnk.Description = "UsageBar: Cursor ve Claude kullanimi"
$lnk.Save()

Start-Process -FilePath $lnk.TargetPath -ArgumentList $lnk.Arguments -WorkingDirectory $dest -WindowStyle Hidden
Write-Output "Kuruldu. Cubuk ust ortada acildi ve Windows ile birlikte baslayacak."
