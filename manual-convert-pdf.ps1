$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms

$reviewDirectory = Join-Path $PSScriptRoot "PDF Review"
New-Item -ItemType Directory -Path $reviewDirectory -Force | Out-Null

$dialog = New-Object System.Windows.Forms.OpenFileDialog
$dialog.Title = "Choose an inventory PDF to convert"
$dialog.Filter = "PDF files (*.pdf)|*.pdf"
$dialog.InitialDirectory = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot "PDF Drop") -PathType Container) {
  Join-Path $PSScriptRoot "PDF Drop"
} else {
  $PSScriptRoot
}
$dialog.Multiselect = $false
if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
  exit 0
}

$pdfPath = $dialog.FileName
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($pdfPath)
$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$reviewPath = Join-Path $reviewDirectory "$baseName-manual-review-$timestamp.json"
if (Test-Path -LiteralPath $reviewPath) {
  $reviewPath = Join-Path $reviewDirectory "$baseName-manual-review-$timestamp-$([guid]::NewGuid().ToString('N').Substring(0, 8)).json"
}

$importerPath = Join-Path $PSScriptRoot "import-pdf.ps1"
$powerShellPath = Join-Path $PSHOME "powershell.exe"
function Invoke-PdfImporter([string[]]$Arguments) {
  $previousErrorActionPreference = $ErrorActionPreference
  try {
    $ErrorActionPreference = "Continue"
    $result = @(& $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $importerPath @Arguments 2>&1)
    $code = $LASTEXITCODE
  } catch {
    $result = @($_)
    $code = 1
  } finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  return [pscustomobject]@{ Output = $result; ExitCode = $code }
}

$conversion = Invoke-PdfImporter @("-PdfPath", $pdfPath, "-ReviewPath", $reviewPath)
$output = $conversion.Output
$exitCode = $conversion.ExitCode
if ($exitCode -ne 0) {
  $errorText = ($output | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join "`r`n"
  [System.Windows.Forms.MessageBox]::Show(
    "The PDF could not be converted.`r`n`r`n$errorText",
    "PDF conversion failed",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Error
  ) | Out-Null
  exit $exitCode
}

$application = Invoke-PdfImporter @("-Apply", "-AutoApply", "-ReviewPath", $reviewPath)
if ($application.ExitCode -ne 0) {
  $errorText = ($application.Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join "`r`n"
  [System.Windows.Forms.MessageBox]::Show(
    "The PDF was converted, but its items and photos could not be added automatically.`r`n`r`n$errorText`r`n`r`nThe draft is saved here:`r`n$reviewPath",
    "PDF import failed",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Error
  ) | Out-Null
  exit $application.ExitCode
}

$statusScript = Join-Path $PSScriptRoot "show-pdf-import-status.ps1"
$summary = ($application.Output | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join " "
& $statusScript -Status "Completed" -PdfName ([System.IO.Path]::GetFileName($pdfPath)) -Details $summary
