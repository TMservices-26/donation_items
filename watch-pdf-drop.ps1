param(
  [string]$DropDirectory = (Join-Path $PSScriptRoot "PDF Drop"),
  [string]$ReviewDirectory = (Join-Path $PSScriptRoot "PDF Review")
)

$ErrorActionPreference = "Stop"
$dropDirectory = [System.IO.Path]::GetFullPath($DropDirectory)
$reviewDirectory = [System.IO.Path]::GetFullPath($ReviewDirectory)
$processedDirectory = Join-Path $dropDirectory "Processed"
$logPath = Join-Path $reviewDirectory "import-log.txt"
$importerPath = Join-Path $PSScriptRoot "import-pdf.ps1"
$statusScriptPath = Join-Path $PSScriptRoot "show-pdf-import-status.ps1"
$publishScriptPath = Join-Path $PSScriptRoot "publish-catalog.ps1"

foreach ($directory in @($dropDirectory, $reviewDirectory, $processedDirectory)) {
  New-Item -ItemType Directory -Path $directory -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $importerPath -PathType Leaf)) {
  throw "PDF importer not found: $importerPath"
}
if (-not (Test-Path -LiteralPath $statusScriptPath -PathType Leaf)) {
  throw "PDF status window script not found: $statusScriptPath"
}

$mutex = [System.Threading.Mutex]::new($false, "Local\TandMCatalogPdfDropWatcher")
try {
  $ownsMutex = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
  $ownsMutex = $true
}
if (-not $ownsMutex) {
  Add-Content -LiteralPath $logPath -Value ("{0}  Watcher is already running." -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss")) -Encoding utf8
  $mutex.Dispose()
  exit 0
}

function Write-ImportLog([string]$Message) {
  $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
  Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
}

function Get-FileFingerprint([System.IO.FileInfo]$File) {
  return "{0}:{1}" -f $File.Length, $File.LastWriteTimeUtc.Ticks
}

function Get-AvailablePath([string]$Directory, [string]$FileName) {
  $path = Join-Path $Directory $FileName
  if (-not (Test-Path -LiteralPath $path)) {
    return $path
  }
  $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
  $extension = [System.IO.Path]::GetExtension($FileName)
  return Join-Path $Directory ("{0}-{1}{2}" -f $baseName, [guid]::NewGuid().ToString("N").Substring(0, 8), $extension)
}

function Show-ImportStatus([string]$Status, [string]$PdfName, [string]$Details) {
  $powerShellPath = Join-Path $PSHOME "powershell.exe"
  $arguments = '-NoProfile -ExecutionPolicy Bypass -NoExit -File "{0}" -Status "{1}" -PdfName "{2}"' -f
    $statusScriptPath, $Status, $PdfName
  if (-not [string]::IsNullOrWhiteSpace($Details)) {
    $arguments += ' -Details "{0}"' -f ($Details -replace '"', "'")
  }
  Start-Process -FilePath $powerShellPath -ArgumentList $arguments -WindowStyle Normal
}

function Get-CatalogSignature {
  $catalogHash = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot "catalog.js") -Algorithm SHA256).Hash
  $imagesPath = Join-Path $PSScriptRoot "images"
  $images = @()
  if (Test-Path -LiteralPath $imagesPath) {
    $images = @(Get-ChildItem -LiteralPath $imagesPath -File | Sort-Object Name | ForEach-Object { "{0}:{1}:{2}" -f $_.Name, $_.Length, $_.LastWriteTimeUtc.Ticks })
  }
  return "$catalogHash|" + ($images -join ",")
}

$publishedSignature = $null
$nextPublishAttempt = [datetime]::MinValue

function Publish-CatalogIfChanged {
  if ((Get-Date) -lt $nextPublishAttempt -or -not (Test-Path -LiteralPath $publishScriptPath -PathType Leaf)) {
    return
  }
  try {
    $signature = Get-CatalogSignature
    if ($signature -eq $script:publishedSignature) {
      return
    }
    $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $publishScriptPath 2>&1)
    if ($LASTEXITCODE -ne 0) {
      throw (($output | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join " ")
    }
    $script:publishedSignature = $signature
    Write-ImportLog ("GitHub publish: " + (($output | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join " "))
  } catch {
    $script:nextPublishAttempt = (Get-Date).AddMinutes(5)
    Write-ImportLog "ERROR publishing to GitHub (will retry in 5 minutes): $($_.Exception.Message)"
  }
}
$attemptedFiles = @{}
$lockedFiles = @{}
Write-ImportLog "Started watching '$dropDirectory'. PDFs are imported automatically; completion opens a PowerShell window."

while ($true) {
  $pdfFiles = @(Get-ChildItem -LiteralPath $dropDirectory -Filter "*.pdf" -File | Sort-Object Name)
  foreach ($file in $pdfFiles) {
    $fingerprint = Get-FileFingerprint $file
    if ($attemptedFiles.ContainsKey($file.FullName) -and $attemptedFiles[$file.FullName] -eq $fingerprint) {
      continue
    }

    Start-Sleep -Seconds 2
    $currentFile = Get-Item -LiteralPath $file.FullName -ErrorAction SilentlyContinue
    if (-not $currentFile -or (Get-FileFingerprint $currentFile) -ne $fingerprint) {
      continue
    }
    Start-Sleep -Seconds 2
    $currentFile = Get-Item -LiteralPath $file.FullName -ErrorAction SilentlyContinue
    if (-not $currentFile -or (Get-FileFingerprint $currentFile) -ne $fingerprint) {
      continue
    }

    $fileStream = $null
    try {
      $fileStream = [System.IO.File]::Open(
        $file.FullName,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::None
      )
    } catch [System.IO.IOException] {
      if (-not $lockedFiles.ContainsKey($file.FullName) -or $lockedFiles[$file.FullName] -ne $fingerprint) {
        Write-ImportLog "Waiting for '$($file.Name)' to finish copying."
        $lockedFiles[$file.FullName] = $fingerprint
      }
      continue
    } catch [System.UnauthorizedAccessException] {
      if (-not $lockedFiles.ContainsKey($file.FullName) -or $lockedFiles[$file.FullName] -ne $fingerprint) {
        Write-ImportLog "ERROR accessing '$($file.Name)': $($_.Exception.Message)"
        $lockedFiles[$file.FullName] = $fingerprint
      }
      continue
    } finally {
      if ($fileStream) {
        $fileStream.Dispose()
      }
    }
    $lockedFiles.Remove($file.FullName)

    $draftName = "{0}-review-{1}.json" -f
      [System.IO.Path]::GetFileNameWithoutExtension($file.Name),
      (Get-Date -Format "yyyyMMdd-HHmmss")
    $draftPath = Get-AvailablePath $reviewDirectory $draftName
    $previousErrorActionPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = "Continue"
      $output = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $importerPath -PdfPath $file.FullName -ReviewPath $draftPath 2>&1)
      $exitCode = $LASTEXITCODE
    } catch {
      $output = @($_)
      $exitCode = 1
    } finally {
      $ErrorActionPreference = $previousErrorActionPreference
    }
    $attemptedFiles[$file.FullName] = $fingerprint

    if ($exitCode -ne 0) {
      $errorText = ($output | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join " "
      Write-ImportLog "ERROR processing '$($file.Name)': $errorText Re-drop a corrected copy under a new filename to retry."
      Show-ImportStatus "Failed" $file.Name $errorText
      continue
    }

    $previousErrorActionPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = "Continue"
      $applyOutput = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $importerPath -Apply -AutoApply -ReviewPath $draftPath 2>&1)
      $applyExitCode = $LASTEXITCODE
    } catch {
      $applyOutput = @($_)
      $applyExitCode = 1
    } finally {
      $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($applyExitCode -ne 0) {
      $errorText = ($applyOutput | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join " "
      Write-ImportLog "ERROR applying '$($file.Name)': $errorText The review draft is '$([System.IO.Path]::GetFileName($draftPath))'."
      Show-ImportStatus "Failed" $file.Name $errorText
      continue
    }

    $processedPath = Get-AvailablePath $processedDirectory $file.Name
    try {
      Move-Item -LiteralPath $file.FullName -Destination $processedPath
      $summary = ($applyOutput | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join " "
      Write-ImportLog "Imported '$($file.Name)' automatically. $summary Original PDF moved to Processed."
      Show-ImportStatus "Completed" $file.Name $summary
      Publish-CatalogIfChanged
    } catch {
      Write-ImportLog "ERROR moving '$($file.Name)' to Processed after creating '$([System.IO.Path]::GetFileName($draftPath))': $($_.Exception.Message)"
      Show-ImportStatus "Failed" $file.Name $_.Exception.Message
    }
  }
  Publish-CatalogIfChanged
  Start-Sleep -Seconds 3
}
