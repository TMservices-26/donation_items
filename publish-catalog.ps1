param(
  [string]$RemoteUrl = "https://github.com/TMservices-26/donation_items.git",
  [string]$Branch = "main",
  [string]$PublishClone = (Join-Path $env:LOCALAPPDATA "TMCatalogPublish\donation_items"),
  [string]$Message = "Update catalog"
)

# Mirrors catalog.js and images from this folder into a private git clone and pushes it,
# so items added, edited, or removed locally are reflected on GitHub Pages.
$ErrorActionPreference = "Continue"

function Invoke-Git {
  param([string[]]$GitArgs)
  $output = & git -C $PublishClone @GitArgs 2>&1
  if ($LASTEXITCODE -ne 0) {
    throw "git $($GitArgs -join ' ') failed: $($output -join ' ')"
  }
  return $output
}

if (-not (Test-Path -LiteralPath (Join-Path $PublishClone ".git"))) {
  New-Item -ItemType Directory -Path (Split-Path $PublishClone -Parent) -Force | Out-Null
  $output = & git clone --branch $Branch $RemoteUrl $PublishClone 2>&1
  if ($LASTEXITCODE -ne 0) { throw "git clone failed: $($output -join ' ')" }
}

Invoke-Git @("fetch", "origin", $Branch) | Out-Null
Invoke-Git @("checkout", $Branch) | Out-Null
Invoke-Git @("reset", "--hard", "origin/$Branch") | Out-Null

Copy-Item -LiteralPath (Join-Path $PSScriptRoot "catalog.js") -Destination (Join-Path $PublishClone "catalog.js") -Force

$sourceImages = Join-Path $PSScriptRoot "images"
$targetImages = Join-Path $PublishClone "images"
New-Item -ItemType Directory -Path $targetImages -Force | Out-Null
$null = & robocopy $sourceImages $targetImages /MIR /NFL /NDL /NJH /NJS /NP
if ($LASTEXITCODE -ge 8) { throw "Copying images failed (robocopy exit code $LASTEXITCODE)." }

Invoke-Git @("add", "-A", "--", "catalog.js", "images") | Out-Null
$pending = Invoke-Git @("status", "--porcelain")
if (-not $pending) {
  Write-Output "Catalog already up to date on GitHub."
  exit 0
}

Invoke-Git @("-c", "user.name=T&M Catalog Automation", "-c", "user.email=catalog-automation@users.noreply.github.com", "commit", "-m", $Message) | Out-Null
Invoke-Git @("push", "origin", $Branch) | Out-Null
Write-Output "Published catalog changes to GitHub."
