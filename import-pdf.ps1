param(
  [string]$PdfPath,

  [string]$CatalogPath,
  [string]$ReviewPath,

  [switch]$Apply,
  [switch]$AutoApply
)

$ErrorActionPreference = "Stop"
$ticketBasePattern = '[A-Z]{2}\d{7}'
if ($AutoApply -and -not $Apply) {
  throw "The -AutoApply switch can only be used together with -Apply."
}
if ([string]::IsNullOrWhiteSpace($CatalogPath)) {
  $CatalogPath = Join-Path $PSScriptRoot "catalog.js"
}
if ([string]::IsNullOrWhiteSpace($ReviewPath)) {
  $ReviewPath = Join-Path $PSScriptRoot "catalog-import-review.json"
}

function Get-WinRtType([string]$Name) {
  $type = [type]::GetType("$Name, Windows, ContentType=WindowsRuntime")
  if (-not $type) {
    throw "Windows API type '$Name' is unavailable. Run this script on Windows 10 or later."
  }
  return $type
}

function Wait-WinRtOperation($Operation, [type]$ResultType) {
  $method = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object {
      $_.Name -eq "AsTask" -and
      $_.IsGenericMethod -and
      $_.GetParameters().Count -eq 1
    } |
    Select-Object -First 1
  $task = $method.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
  return $task.GetAwaiter().GetResult()
}

function Wait-WinRtAction($Action) {
  $method = [System.WindowsRuntimeSystemExtensions].GetMethods() |
    Where-Object {
      $_.Name -eq "AsTask" -and
      -not $_.IsGenericMethod -and
      $_.GetParameters().Count -eq 1
    } |
    Select-Object -First 1
  $task = $method.Invoke($null, @($Action))
  $task.GetAwaiter().GetResult()
}

function Convert-ToCatalogName([string]$Text) {
  $name = [System.Net.WebUtility]::HtmlDecode($Text).Trim()
  $name = [regex]::Replace($name, "\s+", " ")
  $name = [regex]::Replace($name, "\s+\d{1,2}[-/]\d{1,2}[-/]\d{2,4}\b.*$", "")
  $name = [regex]::Replace($name, "\s+\d{4,8}\b.*$", "")
  $name = [regex]::Replace($name, "^[\s:;,. \u2022-]+|[\s:;,. \u2022-]+$", "")
  $name = (Get-Culture).TextInfo.ToTitleCase($name.ToLowerInvariant())
  $name = [regex]::Replace($name, "\bAv\b", "AV")
  $name = [regex]::Replace($name, "\bTv\b", "TV")
  $name = [regex]::Replace($name, "\bPeds?\b", "Pedestals")
  return $name
}

function Get-CategorySuggestion([string]$Name, [string[]]$Categories) {
  $normalized = $Name.ToLowerInvariant()
  $suggestion = $null
  $confidence = 0
  if ($normalized -match "\b(chair|chairs)\b" -and $normalized -match "\b(table|tables)\b") {
    $suggestion = "Sets"
    $confidence = 0.9
  } elseif ($normalized -match "\b(av|audio.visual|salamander)\b") {
    $suggestion = "AV Cabinets"
    $confidence = 0.98
  } elseif ($normalized -match "\b(soft seating|sofa|couch|lounge seating)\b") {
    $suggestion = "Soft Seating"
    $confidence = 0.95
  } elseif ($normalized -match "\b(chair|chairs|stool|stools|seating)\b") {
    $suggestion = "Chairs"
    $confidence = 0.95
  } elseif ($normalized -match "\b(desk|desks|workstation|workstations|station|stations)\b") {
    $suggestion = "Desks & Workstations"
    $confidence = 0.95
  } elseif ($normalized -match "\b(table|tables)\b") {
    $suggestion = "Tables"
    $confidence = 0.9
  } elseif ($normalized -match "\b(rectangular)\b") {
    $suggestion = "Tables"
    $confidence = 0.65
  } elseif ($normalized -match "\b(pedestal|pedestals|credenza|laterals|cabinet|cabinets)\b") {
    $suggestion = "Storage"
    $confidence = 0.95
  } elseif ($normalized -match "\b(peds)\b") {
    $suggestion = "Storage"
    $confidence = 0.65
  }

  if ($suggestion -and $Categories -notcontains $suggestion) {
    return [pscustomobject]@{ Category = $null; Confidence = 0; Note = "Suggested category '$suggestion' is not in the catalog's category list." }
  }
  if (-not $suggestion) {
    return [pscustomobject]@{ Category = $null; Confidence = 0; Note = "No reliable category keyword was found; choose a category manually." }
  }
  return [pscustomobject]@{ Category = $suggestion; Confidence = $confidence; Note = $null }
}

function Get-TicketNumber([string]$Base, [string]$Suffix) {
  if (-not $Suffix) {
    return $Base.ToUpperInvariant()
  }
  $number = [int]$Suffix
  if ($number -in @(1, 3, 4, 6)) {
    return "$($Base.ToUpperInvariant())-D$number"
  }
  return "$($Base.ToUpperInvariant())-$($number.ToString('00'))"
}

function Get-JobSiteLocation($Pages) {
  foreach ($page in $Pages) {
    $label = [regex]::Match($page.Text, "(?i)Job\s*Site\W{0,4}Origin")
    if (-not $label.Success) {
      continue
    }

    $originText = $page.Text.Substring($label.Index + $label.Length)
    $nextTicket = [regex]::Match($originText, "(?i)\b$ticketBasePattern(?:\.\d{1,2})?\b")
    if ($nextTicket.Success) {
      $originText = $originText.Substring(0, $nextTicket.Index)
    }
    $originText = [regex]::Replace($originText, "\s+", " ").Trim()

    $address = [regex]::Match(
      $originText,
      "(?i)\b(?<street>\d{1,6}\s+(?:[A-Za-z0-9.'-]+\s+){1,7}(?:Street|St|Avenue|Ave|Road|Rd|Drive|Dr|Court|Ct|Boulevard|Blvd|Lane|Ln|Way|Parkway|Pkwy)\.?)\s+(?<unit>(?:Unit|Suite|Ste|Apt|Apartment)\s+[A-Za-z0-9-]+\s+)?(?<city>[A-Za-z][A-Za-z .'-]*?),?\s+(?<state>[A-Z]{2})\s+(?<zip>\d{5}(?:-\d{4})?)\b"
    )
    if ($address.Success) {
      $textInfo = (Get-Culture).TextInfo
      $street = $textInfo.ToTitleCase($address.Groups["street"].Value.ToLowerInvariant())
      $street = [regex]::Replace(
        $street,
        "\b(\d+)(St|Nd|Rd|Th)\b",
        [System.Text.RegularExpressions.MatchEvaluator]{
          param($match)
          return $match.Groups[1].Value + $match.Groups[2].Value.ToLowerInvariant()
        },
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
      )
      $city = $textInfo.ToTitleCase($address.Groups["city"].Value.Trim().ToLowerInvariant())
      $unit = if ($address.Groups["unit"].Success) {
        $textInfo.ToTitleCase($address.Groups["unit"].Value.Trim().ToLowerInvariant())
      } else {
        $null
      }
      if ($unit) {
        $location = "{0}, {1}, {2}, {3} {4}" -f $street, $unit, $city, $address.Groups["state"].Value.ToUpperInvariant(), $address.Groups["zip"].Value
      } else {
        $location = "{0}, {1}, {2} {3}" -f $street, $city, $address.Groups["state"].Value.ToUpperInvariant(), $address.Groups["zip"].Value
      }
      return [pscustomobject]@{
        Location = $location
        OriginText = $originText
        Confidence = "high"
      }
    }

    return [pscustomobject]@{
      Location = $null
      OriginText = $originText
      Confidence = "unmatched"
    }
  }

  return [pscustomobject]@{
    Location = $null
    OriginText = $null
    Confidence = "unmatched"
  }
}

function Get-PageRecords([string]$Text, [int]$PageNumber, [string[]]$Categories, [string[]]$ImageNames, $JobSite) {
  $starts = [regex]::Matches(
    $Text,
    "(?i)\b(?<base>$ticketBasePattern)(?:\.(?<suffix>\d{1,2}))?\s*(?:[-\u2013\u2022]\s*)?"
  )
  for ($index = 0; $index -lt $starts.Count; $index++) {
    $match = $starts[$index]
    $segmentEnd = if ($index + 1 -lt $starts.Count) { $starts[$index + 1].Index } else { $Text.Length }
    $segment = $Text.Substring($match.Index, $segmentEnd - $match.Index)
    $headerEnd = [regex]::Match($segment, "(?i)\s+Customer\s+Warehouse\b")
    if (-not $headerEnd.Success) {
      continue
    }

    $title = $segment.Substring($match.Length, $headerEnd.Index - $match.Length)
    $title = [regex]::Replace($title, "(?i)^\s*(?:[-\u2013\u2022]\s*)?", "")
    if ($title -match "(?i)\bDonatable\s+Items\b") {
      continue
    }

    $quantity = $null
    $quantityConfidence = 0
    if ($title -match "^\s*(?<quantity>\d{1,4})\s+(?<name>.+)$") {
      $quantity = [int]$Matches.quantity
      $quantityConfidence = 0.95
      $title = $Matches.name
    } else {
      $form = [regex]::Match($segment, "(?is)Receiving\s+Form(?<fields>.*?)(?:Documents|$)")
      if ($form.Success -and $form.Groups["fields"].Value -match "(?i)\b(?:chairs?|tables?|pieces?|quantity|qty)\s*[:\-]?\s*(?<quantity>\d{1,4})\b") {
        $quantity = [int]$Matches.quantity
        $quantityConfidence = 0.75
      }
    }

    $descriptionParts = [System.Collections.Generic.List[string]]::new()
    $dimensionMatch = [regex]::Match(
      $title,
      "(?i)\b(?<dimensions>\d{1,3}(?:\.\d+)?\s*(?:[""\u201d]|in(?:ches)?)?\s*[x\u00d7]\s*\d{1,3}(?:\.\d+)?(?:\s*(?:[""\u201d]|in(?:ches)?))?)"
    )
    if ($dimensionMatch.Success) {
      $dimensions = [regex]::Replace($dimensionMatch.Groups["dimensions"].Value, "\s+", " ")
      $dimensions = [regex]::Replace($dimensions, "(?i)\s*[x\u00d7]\s*", " x ")
      $descriptionParts.Add("Dimensions: $dimensions")
      $title = $title.Remove($dimensionMatch.Index, $dimensionMatch.Length)
    } else {
      $singleDimension = [regex]::Match($title, "(?i)\b\d{1,3}(?:\.\d+)?\s*(?:[""\u201d]|in(?:ches)?)")
      if ($singleDimension.Success) {
        $descriptionParts.Add("Dimensions: $($singleDimension.Value.Trim())")
        $title = $title.Remove($singleDimension.Index, $singleDimension.Length)
      }
    }

    $damageNotes = [regex]::Match($segment, "(?is)Damage\s+Notes\s+(?<notes>.*?)(?:Documents|$)")
    if ($damageNotes.Success) {
      $damageDescription = [regex]::Replace($damageNotes.Groups["notes"].Value, "\s+", " ").Trim()
      if ($damageDescription) {
        $descriptionParts.Add("Damage: $damageDescription")
      }
    }

    $name = Convert-ToCatalogName $title
    if ($name.Length -lt 2) {
      continue
    }

    $base = $match.Groups["base"].Value
    $suffix = $match.Groups["suffix"].Value
    $ticketNumber = Get-TicketNumber $base $suffix
    $idSuffix = if ($suffix -and [int]$suffix -in @(1, 3, 4, 6)) {
      "d$([int]$suffix)"
    } elseif ($suffix) {
      ([int]$suffix).ToString("00")
    } else {
      ""
    }
    $id = ($base.ToLowerInvariant() + $(if ($idSuffix) { "-$idSuffix" }))
    $category = Get-CategorySuggestion $name $Categories
    if ($id -eq $base.ToLowerInvariant()) {
      $imagePattern = "(?i)^" + [regex]::Escape($id) + "-\d{2,}\.(?:jpe?g|png)$"
    } else {
      $imagePattern = "(?i)^" + [regex]::Escape($id) + "-.*\.(?:jpe?g|png)$"
    }
    $images = @($ImageNames | Where-Object { $_ -match $imagePattern } | Sort-Object)
    $notes = [System.Collections.Generic.List[string]]::new()
    $notes.Add("Verify the OCR'd item name against the PDF before approving.")
    if ($JobSite.Confidence -eq "unmatched") {
      $notes.Add("Could not read the PDF's Job Site/Origin address; enter and verify the location manually.")
    }
    if ($category.Note) { $notes.Add($category.Note) }
    if ($category.Confidence -gt 0 -and $category.Confidence -lt 0.9) {
      $notes.Add("Category is a best-guess; verify it against the PDF.")
    }
    if ($quantityConfidence -eq 0) { $notes.Add("Quantity was not stated clearly; verify it or leave it null.") }
    if ($images.Count -eq 0) { $notes.Add("No matching image filename was found; add photos if available.") }

    [pscustomobject]@{
      approved = $false
      id = $id
      name = $name
      category = $category.Category
      location = $JobSite.Location
      jobSiteOriginText = $JobSite.OriginText
      ticketNumber = $ticketNumber
      quantity = $quantity
      description = $descriptionParts -join "; "
      images = @($images | ForEach-Object { "images/$_" })
      sourcePage = $PageNumber
      matchQuality = [pscustomobject]@{
        category = if ($category.Confidence -ge 0.9) { "high" } elseif ($category.Confidence -gt 0) { "medium" } else { "unmatched" }
        quantity = if ($quantityConfidence -gt 0) { "explicit" } else { "unverified" }
        location = $JobSite.Confidence
      }
      reviewNotes = @($notes)
    }
  }
}

function Set-CatalogItemLocation([string]$Catalog, [string]$TicketNumber, [string]$Location) {
  $ticketPattern = '"?ticketNumber"?\s*:\s*"' + [regex]::Escape($TicketNumber) + '"'
  $ticketMatches = [regex]::Matches($Catalog, $ticketPattern)
  if ($ticketMatches.Count -ne 1) {
    throw "Expected one catalog entry for ticket '$TicketNumber', found $($ticketMatches.Count). No changes were written."
  }

  $ticketMatch = $ticketMatches[0]
  $itemStart = $Catalog.LastIndexOf([char]"{", $ticketMatch.Index)
  $itemEnd = $Catalog.IndexOf([char]"}", $ticketMatch.Index)
  if ($itemStart -lt 0 -or $itemEnd -lt $ticketMatch.Index) {
    throw "Could not safely locate catalog entry for ticket '$TicketNumber'. No changes were written."
  }

  $itemText = $Catalog.Substring($itemStart, $itemEnd - $itemStart + 1)
  if ($itemText -notmatch '(?m)^\s*"?id"?\s*:\s*"') {
    throw "Could not safely identify the catalog item for ticket '$TicketNumber'. No changes were written."
  }
  $locationMatch = [regex]::Match($itemText, '(?m)^(\s*"?location"?\s*:\s*)"([^"]*)"')
  if (-not $locationMatch.Success) {
    throw "Catalog item for ticket '$TicketNumber' has no location field. No changes were written."
  }
  if ($locationMatch.Groups[2].Value -eq $Location) {
    return [pscustomobject]@{ Catalog = $Catalog; Changed = $false }
  }

  $encodedLocation = ConvertTo-Json -InputObject $Location -Compress
  $replacement = $locationMatch.Groups[1].Value + $encodedLocation
  $itemText = $itemText.Remove($locationMatch.Index, $locationMatch.Length).Insert($locationMatch.Index, $replacement)
  $Catalog = $Catalog.Remove($itemStart, $itemEnd - $itemStart + 1).Insert($itemStart, $itemText)
  return [pscustomobject]@{ Catalog = $Catalog; Changed = $true }
}

function Add-CatalogItemImages([string]$Catalog, [string]$TicketNumber, [string[]]$Images) {
  if ($Images.Count -eq 0) {
    return [pscustomobject]@{ Catalog = $Catalog; Changed = $false }
  }

  $ticketPattern = '"?ticketNumber"?\s*:\s*"' + [regex]::Escape($TicketNumber) + '"'
  $ticketMatches = [regex]::Matches($Catalog, $ticketPattern)
  if ($ticketMatches.Count -ne 1) {
    throw "Expected one catalog entry for ticket '$TicketNumber', found $($ticketMatches.Count). No changes were written."
  }

  $ticketMatch = $ticketMatches[0]
  $itemStart = $Catalog.LastIndexOf([char]"{", $ticketMatch.Index)
  $itemEnd = $Catalog.IndexOf([char]"}", $ticketMatch.Index)
  if ($itemStart -lt 0 -or $itemEnd -lt $ticketMatch.Index) {
    throw "Could not safely locate catalog entry for ticket '$TicketNumber'. No changes were written."
  }

  $itemText = $Catalog.Substring($itemStart, $itemEnd - $itemStart + 1)
  $imagesMatch = [regex]::Match($itemText, '(?m)^(\s*"?images"?\s*:\s*)(\[[\s\S]*?\])')
  if (-not $imagesMatch.Success) {
    throw "Catalog item for ticket '$TicketNumber' has no readable images field. No changes were written."
  }

  $mergedImages = [System.Collections.Generic.List[string]]::new()
  $existingImages = ConvertFrom-Json -InputObject $imagesMatch.Groups[2].Value
  foreach ($image in $existingImages) {
    if (-not [string]::IsNullOrWhiteSpace([string]$image)) {
      $mergedImages.Add([string]$image)
    }
  }
  $changed = $false
  foreach ($image in $Images) {
    if (-not [string]::IsNullOrWhiteSpace($image) -and $mergedImages -notcontains $image) {
      $mergedImages.Add($image)
      $changed = $true
    }
  }
  if (-not $changed) {
    return [pscustomobject]@{ Catalog = $Catalog; Changed = $false }
  }

  $encodedImages = ConvertTo-Json -InputObject ([string[]]$mergedImages.ToArray()) -Compress
  $replacement = $imagesMatch.Groups[1].Value + $encodedImages
  $itemText = $itemText.Remove($imagesMatch.Index, $imagesMatch.Length).Insert($imagesMatch.Index, $replacement)
  $Catalog = $Catalog.Remove($itemStart, $itemEnd - $itemStart + 1).Insert($itemStart, $itemText)
  return [pscustomobject]@{ Catalog = $Catalog; Changed = $true }
}

function Read-PdfOcr([string]$Path) {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $storageFileType = Get-WinRtType "Windows.Storage.StorageFile"
  $pdfType = Get-WinRtType "Windows.Data.Pdf.PdfDocument"
  $engineType = Get-WinRtType "Windows.Media.Ocr.OcrEngine"
  $streamType = Get-WinRtType "Windows.Storage.Streams.InMemoryRandomAccessStream"
  $decoderType = Get-WinRtType "Windows.Graphics.Imaging.BitmapDecoder"
  $bitmapType = Get-WinRtType "Windows.Graphics.Imaging.SoftwareBitmap"
  $resultType = Get-WinRtType "Windows.Media.Ocr.OcrResult"

  $fileMethod = $storageFileType.GetMethods() |
    Where-Object { $_.Name -eq "GetFileFromPathAsync" -and $_.GetParameters().Count -eq 1 } |
    Select-Object -First 1
  $pdfMethod = $pdfType.GetMethods() |
    Where-Object { $_.Name -eq "LoadFromFileAsync" -and $_.GetParameters().Count -eq 1 } |
    Select-Object -First 1
  $file = Wait-WinRtOperation ($fileMethod.Invoke($null, @((Resolve-Path $Path).Path))) $storageFileType
  $document = Wait-WinRtOperation ($pdfMethod.Invoke($null, @($file))) $pdfType
  $engine = $engineType.GetMethod("TryCreateFromUserProfileLanguages").Invoke($null, @())
  if (-not $engine) {
    throw "Windows OCR is unavailable. Install an English OCR language pack in Windows Settings > Time & language > Language & region."
  }

  $decoderMethod = $decoderType.GetMethods() |
    Where-Object { $_.Name -eq "CreateAsync" -and $_.GetParameters().Count -eq 1 } |
    Select-Object -First 1
  $bitmapMethod = $decoderType.GetMethods() |
    Where-Object { $_.Name -eq "GetSoftwareBitmapAsync" -and $_.GetParameters().Count -eq 0 } |
    Select-Object -First 1
  $pages = [System.Collections.Generic.List[object]]::new()
  for ($pageIndex = 0; $pageIndex -lt [int]$document.PageCount; $pageIndex++) {
    $page = $document.GetPage([uint32]$pageIndex)
    $stream = [Activator]::CreateInstance($streamType)
    Wait-WinRtAction ($page.RenderToStreamAsync($stream))
    $stream.Seek(0)
    $decoder = Wait-WinRtOperation ($decoderMethod.Invoke($null, @($stream))) $decoderType
    $bitmap = Wait-WinRtOperation ($bitmapMethod.Invoke($decoder, @())) $bitmapType
    $result = Wait-WinRtOperation ($engine.RecognizeAsync($bitmap)) $resultType
    $pages.Add([pscustomobject]@{ Number = $pageIndex + 1; Text = $result.Text })
    $page.Dispose()
    $stream.Dispose()
  }
  return $pages
}

function Install-EmbeddedImages($Items, [string]$ReviewPath, [string]$CatalogPath) {
  $reviewDirectory = [System.IO.Path]::GetFullPath((Split-Path -Parent $ReviewPath))
  $imageDirectory = Join-Path (Split-Path -Parent $CatalogPath) "images"
  $plans = [System.Collections.Generic.List[object]]::new()
  foreach ($item in $Items) {
    if (-not $item.PSObject.Properties["embeddedImageFiles"]) {
      continue
    }
    foreach ($embeddedImage in @($item.embeddedImageFiles)) {
      if (-not $embeddedImage) {
        continue
      }
      $targetName = [string]$embeddedImage.target
      if ([string]::IsNullOrWhiteSpace($targetName) -or
        [System.IO.Path]::GetFileName($targetName) -ne $targetName -or
        $targetName -match '[\\/]') {
        throw "Invalid embedded image destination '$targetName' in '$ReviewPath'."
      }
      if (@($item.images) -notcontains "images/$targetName") {
        continue
      }

      $stagedRelativePath = [string]$embeddedImage.source
      if ([string]::IsNullOrWhiteSpace($stagedRelativePath) -or
        [System.IO.Path]::IsPathRooted($stagedRelativePath)) {
        throw "Invalid staged image path '$stagedRelativePath' in '$ReviewPath'."
      }
      $stagedPath = [System.IO.Path]::GetFullPath((Join-Path $reviewDirectory $stagedRelativePath))
      if (-not $stagedPath.StartsWith($reviewDirectory + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Staged image path '$stagedRelativePath' is outside the review folder."
      }
      $destinationPath = Join-Path $imageDirectory $targetName
      $plans.Add([pscustomobject]@{
        Source = $stagedPath
        Destination = $destinationPath
      })
    }
  }

  foreach ($plan in $plans) {
    if (-not (Test-Path -LiteralPath $plan.Source -PathType Leaf)) {
      if (Test-Path -LiteralPath $plan.Destination -PathType Leaf) {
        continue
      }
      throw "Staged image not found: $($plan.Source). The review draft may have been moved or its staged images deleted."
    }
    if (Test-Path -LiteralPath $plan.Destination -PathType Leaf) {
      $sourceHash = (Get-FileHash -LiteralPath $plan.Source -Algorithm SHA256).Hash
      $destinationHash = (Get-FileHash -LiteralPath $plan.Destination -Algorithm SHA256).Hash
      if ($sourceHash -ne $destinationHash) {
        throw "Image destination already exists with different content: $($plan.Destination). Rename the image in the draft and try again."
      }
    }
  }

  if ($plans.Count -gt 0) {
    New-Item -ItemType Directory -Path $imageDirectory -Force | Out-Null
  }
  $movedCount = 0
  foreach ($plan in $plans) {
    if (-not (Test-Path -LiteralPath $plan.Source -PathType Leaf)) {
      continue
    }
    if (Test-Path -LiteralPath $plan.Destination -PathType Leaf) {
      Remove-Item -LiteralPath $plan.Source
      continue
    }
    Move-Item -LiteralPath $plan.Source -Destination $plan.Destination
    $movedCount++
  }
  return $movedCount
}

if ($Apply) {
  if (-not (Test-Path -LiteralPath $ReviewPath -PathType Leaf)) {
    throw "Review file not found: $ReviewPath. Run the script without -Apply first."
  }
  if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) {
    throw "Catalog file not found: $CatalogPath"
  }
  $catalog = Get-Content -LiteralPath $CatalogPath -Raw
  $categories = @([regex]::Matches($catalog, '"?category"?\s*:\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
  $reviewDocument = Get-Content -LiteralPath $ReviewPath -Raw | ConvertFrom-Json
  $approveAll = $false
  if ($reviewDocument -is [System.Management.Automation.PSCustomObject] -and
    $reviewDocument.PSObject.Properties["items"]) {
    $reviewItems = @($reviewDocument.items)
    $approveAll = $reviewDocument.approveAll -eq $true
  } else {
    $reviewItems = @($reviewDocument)
  }
  if ($AutoApply) {
    $approved = $reviewItems
  } else {
    $approved = @($reviewItems | Where-Object { $approveAll -or $_.approved -eq $true })
  }
  if ($approved.Count -eq 0) {
    throw "No entries are approved. Set approveAll to true at the end of '$ReviewPath', or set approved to true on individual reviewed entries."
  }
  $existingTickets = @([regex]::Matches($catalog, '"?ticketNumber"?\s*:\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value.ToUpperInvariant() })
  $existingIds = @([regex]::Matches($catalog, '"?id"?\s*:\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value.ToLowerInvariant() })
  $autoCategory = "Needs Review"
  if ($AutoApply -and $categories -notcontains $autoCategory) {
    $categories += $autoCategory
  }
  $newItems = [System.Collections.Generic.List[object]]::new()
  $imagesToInstall = [System.Collections.Generic.List[object]]::new()
  $changedLocations = 0
  $changedImages = 0
  $skippedExistingImages = 0
  foreach ($item in $approved) {
    if ([string]::IsNullOrWhiteSpace([string]$item.ticketNumber)) {
      throw "An approved entry is missing its ticket number."
    }
    if ([string]::IsNullOrWhiteSpace([string]$item.location)) {
      throw "Approved entry '$($item.ticketNumber)' has no location. Enter the verified Job Site/Origin location before applying the draft."
    }
    if ($existingTickets -contains ([string]$item.ticketNumber).ToUpperInvariant()) {
      $locationUpdate = Set-CatalogItemLocation $catalog ([string]$item.ticketNumber) ([string]$item.location)
      $catalog = $locationUpdate.Catalog
      if ($locationUpdate.Changed) {
        $changedLocations++
        Write-Output "Updated Job Site/Origin location for existing ticket '$($item.ticketNumber)'."
      }
      if ($AutoApply) {
        if ($item.PSObject.Properties["embeddedImageFiles"] -and @($item.embeddedImageFiles).Count -gt 0) {
          $skippedExistingImages++
        }
      } else {
        $imageUpdate = Add-CatalogItemImages $catalog ([string]$item.ticketNumber) @($item.images | ForEach-Object { [string]$_ })
        $catalog = $imageUpdate.Catalog
        if ($imageUpdate.Changed) {
          $changedImages++
          Write-Output "Added photo(s) to existing ticket '$($item.ticketNumber)'."
        }
        $imagesToInstall.Add($item)
      }
      continue
    }
    foreach ($field in @("id", "name", "category", "location")) {
      if ([string]::IsNullOrWhiteSpace([string]$item.$field)) {
        if ($AutoApply -and $field -eq "category") {
          $item.category = $autoCategory
          continue
        }
        throw "Approved entry '$($item.id)' is missing required field '$field'."
      }
    }
    if ($item.id -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
      throw "Invalid item id '$($item.id)'. Use lowercase letters, numbers, and hyphens."
    }
    if ($categories -notcontains [string]$item.category) {
      throw "Category '$($item.category)' is not used in the current catalog. Add the category to catalog.js first or correct the review entry."
    }
    if ($null -ne $item.quantity -and ($item.quantity -isnot [int] -or $item.quantity -lt 0)) {
      throw "Quantity for '$($item.id)' must be a non-negative integer or null."
    }
    if ($existingIds -contains ([string]$item.id).ToLowerInvariant()) {
      throw "Item id '$($item.id)' already exists with a different ticket number."
    }
    $newItems.Add([pscustomobject]@{
      id = [string]$item.id
      name = [string]$item.name
      category = [string]$item.category
      location = [string]$item.location
      ticketNumber = [string]$item.ticketNumber
      quantity = $item.quantity
      description = [string]$item.description
      images = @($item.images)
    })
    $imagesToInstall.Add($item)
    $existingTickets += ([string]$item.ticketNumber).ToUpperInvariant()
    $existingIds += ([string]$item.id).ToLowerInvariant()
  }
  $photoNotice = ""
  if ($skippedExistingImages -gt 0) {
    $photoNotice = " Skipped embedded photos for $skippedExistingImages existing ticket(s); review their draft photos before adding them."
  }
  if ($newItems.Count -eq 0) {
    $installedImages = Install-EmbeddedImages $imagesToInstall.ToArray() $ReviewPath $CatalogPath
    if ($changedLocations -gt 0 -or $changedImages -gt 0) {
      Set-Content -LiteralPath $CatalogPath -Value $catalog -NoNewline -Encoding utf8
      Write-Output "Updated $changedLocations existing catalog location(s), added photos to $changedImages existing item(s), and moved $installedImages embedded image(s) to the images folder.$photoNotice"
    } else {
      Write-Output "No new items or catalog changes. Moved $installedImages embedded image(s) to the images folder.$photoNotice"
    }
    exit 0
  }

  $installedImages = Install-EmbeddedImages $imagesToInstall.ToArray() $ReviewPath $CatalogPath
  $arrayEnd = [regex]::Matches($catalog, '(?m)^\];\s*$')
  if ($arrayEnd.Count -ne 1) {
    throw "Could not safely locate the end of the items array in '$CatalogPath'. No changes were made."
  }
  $serialized = @($newItems | ForEach-Object {
    $json = $_ | ConvertTo-Json -Depth 5
    "  " + ($json -replace '(?m)^', "  ")
  }) -join ",`r`n"
  $insert = ",`r`n" + $serialized + "`r`n"
  $catalog = $catalog.Insert($arrayEnd[0].Index, $insert)
  Set-Content -LiteralPath $CatalogPath -Value $catalog -NoNewline -Encoding utf8
  Write-Output "Added $($newItems.Count) approved item(s), updated $changedLocations existing location(s), added photos to $changedImages existing item(s), and moved $installedImages embedded image(s) to the images folder in '$CatalogPath'.$photoNotice"
  exit 0
}

if (-not (Test-Path -LiteralPath $PdfPath -PathType Leaf)) {
  throw "PDF file not found: $PdfPath"
}
if (-not (Test-Path -LiteralPath $CatalogPath -PathType Leaf)) {
  throw "Catalog file not found: $CatalogPath"
}

$catalog = Get-Content -LiteralPath $CatalogPath -Raw
$categories = @([regex]::Matches($catalog, '"?category"?\s*:\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
$imageNames = @()
$imageDirectory = Join-Path (Split-Path -Parent $CatalogPath) "images"
if (Test-Path -LiteralPath $imageDirectory -PathType Container) {
  $imageNames = @(Get-ChildItem -LiteralPath $imageDirectory -File | ForEach-Object { $_.Name })
}
$items = [System.Collections.Generic.List[object]]::new()
$pages = @(Read-PdfOcr $PdfPath)
$extractorPath = Join-Path $PSScriptRoot "extract-pdf-images.py"
if (-not (Test-Path -LiteralPath $extractorPath -PathType Leaf)) {
  throw "PDF image extractor not found: $extractorPath"
}
$pythonCommand = Get-Command python.exe -ErrorAction SilentlyContinue
if (-not $pythonCommand) {
  throw "Python 3 is required to extract PDF photos. Install Python, then run 'python -m pip install -r requirements.txt' from '$PSScriptRoot'."
}
$stagingDirectoryName = [guid]::NewGuid().ToString("N")
$stagingDirectoryRelative = Join-Path "staged-images" $stagingDirectoryName
$stagingDirectory = Join-Path (Split-Path -Parent $ReviewPath) $stagingDirectoryRelative
$manifestPath = Join-Path $stagingDirectory "manifest.json"
$previousErrorActionPreference = $ErrorActionPreference
try {
  $ErrorActionPreference = "Continue"
  $extractOutput = @(& $pythonCommand.Source $extractorPath --pdf (Resolve-Path $PdfPath).Path --output-directory $stagingDirectory --manifest $manifestPath 2>&1)
  $extractExitCode = $LASTEXITCODE
} catch {
  $extractOutput = @($_)
  $extractExitCode = 1
} finally {
  $ErrorActionPreference = $previousErrorActionPreference
}
if ($extractExitCode -ne 0) {
  $extractError = ($extractOutput | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) -join " "
  throw "Could not extract embedded PDF images. Confirm pypdf is installed with 'python -m pip install -r requirements.txt'. $extractError"
}
$imageManifest = ConvertFrom-Json -InputObject (Get-Content -LiteralPath $manifestPath -Raw)
$embeddedImages = @($imageManifest.images)
$embeddedImagesByPage = @{}
foreach ($embeddedImage in $embeddedImages) {
  $pageNumber = [int]$embeddedImage.page
  if (-not $embeddedImagesByPage.ContainsKey($pageNumber)) {
    $embeddedImagesByPage[$pageNumber] = [System.Collections.Generic.List[object]]::new()
  }
  $embeddedImagesByPage[$pageNumber].Add($embeddedImage)
}
$reservedImageNames = [System.Collections.Generic.List[string]]::new()
$reservedImageNames.AddRange([string[]]$imageNames)
$usedStagedImages = @{}
$jobSite = Get-JobSiteLocation $pages
foreach ($page in $pages) {
  $pageItems = @(Get-PageRecords $page.Text $page.Number $categories $imageNames $jobSite)
  foreach ($item in $pageItems) {
    $pageImages = @()
    if ($embeddedImagesByPage.ContainsKey([int]$page.Number)) {
      $pageImages = @($embeddedImagesByPage[[int]$page.Number].ToArray())
    }
    if ($pageItems.Count -gt 1 -and $pageImages.Count -gt 0) {
      $item.reviewNotes += "Multiple inventory items share this PDF page, so embedded photos may need to be assigned manually."
    } elseif ($pageImages.Count -gt 0) {
      $embeddedImageFiles = [System.Collections.Generic.List[object]]::new()
      $embeddedImagePaths = [System.Collections.Generic.List[string]]::new()
      $imageSequence = 1
      foreach ($pageImage in $pageImages) {
        $extension = [System.IO.Path]::GetExtension([string]$pageImage.filename).ToLowerInvariant()
        do {
          $targetName = "{0}-{1:00}{2}" -f $item.id, $imageSequence, $extension
          $imageSequence++
        } while ($reservedImageNames -contains $targetName)
        $reservedImageNames.Add($targetName)
        $embeddedImagePaths.Add("images/$targetName")
        $stagedSource = Join-Path $stagingDirectoryRelative ([string]$pageImage.filename)
        $embeddedImageFiles.Add([pscustomobject]@{
          source = $stagedSource
          target = $targetName
        })
        $usedStagedImages[[string]$pageImage.filename] = $true
      }
      $item.images = @($item.images) + @($embeddedImagePaths.ToArray())
      $item.reviewNotes = @($item.reviewNotes | Where-Object { $_ -notmatch "^No matching image filename was found" })
      $item | Add-Member -NotePropertyName embeddedImageFiles -NotePropertyValue @($embeddedImageFiles.ToArray())
    }
    $items.Add($item)
  }
}
foreach ($embeddedImage in $embeddedImages) {
  if (-not $usedStagedImages.ContainsKey([string]$embeddedImage.filename)) {
    Remove-Item -LiteralPath (Join-Path $stagingDirectory ([string]$embeddedImage.filename)) -ErrorAction SilentlyContinue
  }
}
if ($items.Count -eq 0) {
  Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
  throw "No inventory item records were detected. Confirm the PDF has item detail rows with ticket headings using a two-letter warehouse prefix followed by seven digits. A cover page with only a 'Donatable Items' heading has no item rows to convert."
}
if ($usedStagedImages.Count -eq 0) {
  Remove-Item -LiteralPath $stagingDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

ConvertTo-Json -InputObject ([pscustomobject]@{
  items = @($items.ToArray())
  approveAll = $false
}) -Depth 6 |
  Set-Content -LiteralPath $ReviewPath -Encoding utf8
Write-Output "Created $($items.Count) draft item(s) in '$ReviewPath'. Review the entries, then set approveAll to true at the end of the draft or approve items individually."
