$ErrorActionPreference = "Stop"

$dropDirectory = Join-Path $PSScriptRoot "PDF Drop"
$reviewDirectory = Join-Path $PSScriptRoot "PDF Review"
$watcherPath = Join-Path $PSScriptRoot "watch-pdf-drop.ps1"
$statusScriptPath = Join-Path $PSScriptRoot "show-pdf-import-status.ps1"
$startupDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Startup)
$shortcutPath = Join-Path $startupDirectory "T&M Catalog PDF Drop.lnk"
$powerShellPath = Join-Path $PSHOME "powershell.exe"

foreach ($directory in @($dropDirectory, $reviewDirectory, (Join-Path $dropDirectory "Processed"))) {
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $watcherPath -PathType Leaf)) {
  throw "PDF watcher not found: $watcherPath"
}
if (-not (Test-Path -LiteralPath $statusScriptPath -PathType Leaf)) {
  throw "PDF completion window script not found: $statusScriptPath"
}
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if (-not $pythonCommand) {
  throw "Python 3 is required to extract embedded PDF photos. Install Python, then run 'python -m pip install -r `"$PSScriptRoot\requirements.txt`"'."
}
$pythonOutput = @(& $pythonCommand.Source -c "import pypdf, PIL" 2>&1)
if ($LASTEXITCODE -ne 0) {
  throw "The pypdf and Pillow packages are required to extract embedded PDF photos. Run 'python -m pip install -r `"$PSScriptRoot\requirements.txt`"' and run setup again. $($pythonOutput -join ' ')"
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $powerShellPath
$shortcut.Arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $watcherPath + '"'
$shortcut.WorkingDirectory = $PSScriptRoot
$shortcut.WindowStyle = 7
$shortcut.Description = "Watch the T&M catalog PDF drop folder for new inventory PDFs."
$shortcut.Save()

$watcherCommandPattern = '(?i)-File\s+["'']?' + [regex]::Escape($watcherPath) + '["'']?(?:\s|$)'
$runningWatchers = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
  Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -match $watcherCommandPattern })
foreach ($runningWatcher in $runningWatchers) {
  Stop-Process -Id ([int]$runningWatcher.ProcessId) -Force
}
if ($runningWatchers.Count -gt 0) {
  Start-Sleep -Seconds 1
}

$launchStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Start-Process -FilePath $powerShellPath -ArgumentList (
  '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $watcherPath + '"'
) -WindowStyle Hidden

$logPath = Join-Path $reviewDirectory "import-log.txt"
$ready = $false
for ($attempt = 0; $attempt -lt 15; $attempt++) {
  Start-Sleep -Seconds 1
  if (Test-Path -LiteralPath $logPath) {
    $lastLogLine = Get-Content -LiteralPath $logPath -Tail 1
    if ($lastLogLine.Length -ge 19 -and
      $lastLogLine.Substring(0, 19) -ge $launchStamp -and
      $lastLogLine -match "Started watching|Watcher is already running") {
      $ready = $true
      break
    }
  }
}
if (-not $ready) {
  throw "The watcher did not start. Check '$logPath' for errors and run setup again."
}

Write-Output "PDF drop automation is ready."
Write-Output "Drop PDFs into: $dropDirectory"
Write-Output "Import status and review drafts appear in: $reviewDirectory"
Write-Output "A watcher shortcut was added to your Windows Startup folder."
