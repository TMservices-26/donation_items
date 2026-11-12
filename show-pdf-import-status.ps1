param(
  [Parameter(Mandatory = $true)]
  [ValidateSet("Completed", "Failed")]
  [string]$Status,

  [Parameter(Mandatory = $true)]
  [string]$PdfName,

  [string]$Details
)

$host.UI.RawUI.WindowTitle = "PDF import $Status"
Write-Host ""
if ($Status -eq "Completed") {
  Write-Host "PDF import completed: $PdfName" -ForegroundColor Green
  Write-Host "The catalog and any extracted photos have been updated."
  Write-Host "Review catalog.js and the images folder when convenient."
} else {
  Write-Host "PDF import failed: $PdfName" -ForegroundColor Red
  if (-not [string]::IsNullOrWhiteSpace($Details)) {
    Write-Host $Details -ForegroundColor Yellow
  }
}
Write-Host ""
Write-Host "A copy of the status is in PDF Review\import-log.txt."
Write-Host "Press Enter to close this window."
[void](Read-Host)
