param(
  [string]$ReviewPath
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Windows.Forms

$reviewDirectory = Join-Path $PSScriptRoot "PDF Review"
if (-not (Test-Path -LiteralPath $reviewDirectory -PathType Container)) {
  [System.Windows.Forms.MessageBox]::Show(
    "No review folder exists yet. Run the PDF drop setup first, then drop a PDF into the PDF Drop folder.",
    "PDF review",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
  ) | Out-Null
  exit 0
}

if ([string]::IsNullOrWhiteSpace($ReviewPath)) {
  $dialog = New-Object System.Windows.Forms.OpenFileDialog
  $dialog.Title = "Choose a PDF inventory draft to review"
  $dialog.Filter = "Review drafts (*.json)|*.json"
  $dialog.InitialDirectory = $reviewDirectory
  $dialog.Multiselect = $false
  if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
    exit 0
  }
  $ReviewPath = $dialog.FileName
} elseif (-not (Test-Path -LiteralPath $ReviewPath -PathType Leaf)) {
  [System.Windows.Forms.MessageBox]::Show(
    "The review draft was not found:`r`n$ReviewPath",
    "PDF review",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Error
  ) | Out-Null
  exit 1
}
$reviewPath = $ReviewPath

$escapedReviewPath = $reviewPath.Replace('"', '\"')
Start-Process -FilePath (Join-Path $env:SystemRoot "System32\notepad.exe") -ArgumentList ('"' + $escapedReviewPath + '"')

$message = "The selected draft is open in Notepad:`r`n$reviewPath`r`n`r`nCheck the item names, Job Site/Origin locations, categories, quantities, and photos. Press Ctrl+End and change `"approveAll`": false to `"approveAll`": true to approve every checked item at once. Alternatively, change `"approved`": false to `"approved`": true on individual items. Save and close Notepad, then click OK to add new items, update matching ticket locations, and add reviewed photos to existing tickets in catalog.js, or Cancel to stop."
$confirmation = [System.Windows.Forms.MessageBox]::Show(
  $message,
  "Review and import PDF draft",
  [System.Windows.Forms.MessageBoxButtons]::OKCancel,
  [System.Windows.Forms.MessageBoxIcon]::Information
)
if ($confirmation -ne [System.Windows.Forms.DialogResult]::OK) {
  exit 0
}

$importerPath = Join-Path $PSScriptRoot "import-pdf.ps1"
$powerShellPath = Join-Path $PSHOME "powershell.exe"
$output = @(& $powerShellPath -NoProfile -ExecutionPolicy Bypass -File $importerPath -Apply -ReviewPath $reviewPath 2>&1)
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
  $errorText = ($output | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join "`r`n"
  [System.Windows.Forms.MessageBox]::Show(
    "The draft was not applied.`r`n`r`n$errorText",
    "PDF import failed",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Error
  ) | Out-Null
  exit $exitCode
}

$result = ($output | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join "`r`n"
[System.Windows.Forms.MessageBox]::Show(
  "$result`r`n`r`nReview drafts are not published automatically. Commit and push catalog.js to publish website changes.",
  "PDF import complete",
  [System.Windows.Forms.MessageBoxButtons]::OK,
  [System.Windows.Forms.MessageBoxIcon]::Information
) | Out-Null
