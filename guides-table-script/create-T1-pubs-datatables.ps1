<#
create-T1-pubs-datatables.ps1

Standalone script that runs the full T1 publications workflow:
1) Generate EN/FR HTML table files from templates.
2) Validate bilingual links and normalize unavailable cells.

Defaults are resolved from this script's folder so it can be executed
from any current working directory.
#>

[CmdletBinding()]
param(
  [string]$PubsListPath = ".\recent-T1-pubs-9yrs.txt",
  [string]$TemplateEnPath = ".\pubs-table-template-e.htm",
  [string]$TemplateFrPath = ".\pubs-table-template-f.htm",
  [string]$OutputDir,
  [int]$TimeoutSec = 12,
  [switch]$DryRun
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Resolve-ExistingPath {
  param(
    [Parameter(Mandatory)] [string]$PathValue,
    [Parameter(Mandatory)] [string]$BaseDir
  )

  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    if (-not (Test-Path -LiteralPath $PathValue)) {
      throw "Required file not found: $PathValue"
    }
    return (Resolve-Path -LiteralPath $PathValue).Path
  }

  $scriptRelative = Join-Path $BaseDir $PathValue
  if (Test-Path -LiteralPath $scriptRelative) {
    return (Resolve-Path -LiteralPath $scriptRelative).Path
  }

  if (Test-Path -LiteralPath $PathValue) {
    return (Resolve-Path -LiteralPath $PathValue).Path
  }

  throw "Required file not found: $PathValue"
}

function Resolve-DirectoryPath {
  param(
    [Parameter(Mandatory)] [string]$PathValue,
    [Parameter(Mandatory)] [string]$BaseDir
  )

  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return $PathValue
  }

  return (Join-Path $BaseDir $PathValue)
}

function Resolve-TablePath {
  param(
    [Parameter(Mandatory)] [string]$ResultsFolder,
    [Parameter(Mandatory)] [string]$PubName,
    [Parameter(Mandatory)] [ValidateSet('e', 'f')] [string]$Lang
  )
  # Prefer .htm outputs but accept .html if present.
  $candidates = @(
    (Join-Path $ResultsFolder "$PubName-table-$Lang.htm"),
    (Join-Path $ResultsFolder "$PubName-table-$Lang.html")
  )
  foreach ($p in $candidates) {
    if (Test-Path -LiteralPath $p) { return $p }
  }
  return $candidates[0]
}

function Get-PubsList {
  param([Parameter(Mandatory)] [string]$Path)

  # Ignore empty lines and comments.
  return Get-Content -LiteralPath $Path |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and -not $_.StartsWith('#') }
}

function Get-TBodyMatch {
  param([string]$Html)
  return [regex]::Match($Html, '<tbody\b[^>]*>(?<tb>.*?)</tbody>', 'Singleline,IgnoreCase')
}

function Split-RowMatches {
  param([string]$TbodyHtml)
  return [regex]::Matches($TbodyHtml, '<tr\b[^>]*>.*?</tr>', 'Singleline,IgnoreCase')
}

function Split-CellMatches {
  param([string]$RowHtml)
  # Capture both <th> and <td> cell wrappers and inner HTML.
  return [regex]::Matches(
    $RowHtml,
    '<(?<tag>th|td)(?<attrs>\s+[^>]*)?>(?<cell>.*?)</\k<tag>>',
    'Singleline,IgnoreCase'
  )
}

function Get-EffectiveCellContent {
  param(
    [Parameter(Mandatory)] [hashtable]$Replacements,
    [Parameter(Mandatory)] [int]$CellIndex,
    [Parameter(Mandatory)] [object[]]$Cells
  )

  if ($Replacements.ContainsKey($CellIndex)) { return [string]$Replacements[$CellIndex] }
  return $Cells[$CellIndex].Groups['cell'].Value
}

function Replace-CellsInRow {
  param(
    [string]$RowHtml,
    [object[]]$CellMatches,
    [hashtable]$Replacements
  )

  if ($Replacements.Count -eq 0) { return $RowHtml }

  $sb = [System.Text.StringBuilder]::new()
  $cursor = 0
  for ($i = 0; $i -lt $CellMatches.Count; $i++) {
    $m = $CellMatches[$i]
    $null = $sb.Append($RowHtml.Substring($cursor, $m.Index - $cursor))

    if ($Replacements.ContainsKey($i)) {
      $tag = $m.Groups['tag'].Value
      $attrs = $m.Groups['attrs'].Value
      $inner = [string]$Replacements[$i]
      $null = $sb.Append("<$tag$attrs>$inner</$tag>")
    } else {
      $null = $sb.Append($m.Value)
    }
    $cursor = $m.Index + $m.Length
  }

  $null = $sb.Append($RowHtml.Substring($cursor))
  return $sb.ToString()
}

function Replace-RowsInTBody {
  param(
    [string]$TbodyHtml,
    [object[]]$RowMatches,
    [hashtable]$UpdatedRows
  )

  if ($UpdatedRows.Count -eq 0) { return $TbodyHtml }

  $sb = [System.Text.StringBuilder]::new()
  $cursor = 0
  for ($i = 0; $i -lt $RowMatches.Count; $i++) {
    $m = $RowMatches[$i]
    $null = $sb.Append($TbodyHtml.Substring($cursor, $m.Index - $cursor))
    if ($UpdatedRows.ContainsKey($i)) {
      $null = $sb.Append([string]$UpdatedRows[$i])
    } else {
      $null = $sb.Append($m.Value)
    }
    $cursor = $m.Index + $m.Length
  }
  $null = $sb.Append($TbodyHtml.Substring($cursor))
  return $sb.ToString()
}

function Replace-TBodyInHtml {
  param(
    [string]$Html,
    [System.Text.RegularExpressions.Match]$TBodyMatch,
    [string]$NewInner
  )

  $originalTbody = $TBodyMatch.Value
  $newTbody = [regex]::Replace(
    $originalTbody,
    '^(\s*<tbody\b[^>]*>).*?(</tbody>\s*)$',
    "`$1$NewInner`$2",
    'Singleline,IgnoreCase'
  )

  return $Html.Substring(0, $TBodyMatch.Index) + $newTbody + $Html.Substring($TBodyMatch.Index + $TBodyMatch.Length)
}

function Get-LinkHref {
  param([string]$CellHtml)
  # Extract the first href value from a cell.
  $m = [regex]::Match($CellHtml, 'href\s*=\s*"([^"]+)"', 'IgnoreCase')
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

function Replace-AnchorHrefAndText {
  param(
    [Parameter(Mandatory)] [string]$CellHtml,
    [Parameter(Mandatory)] [string]$NewHref
  )

  # Replace the first <a> tag with the new href and (if applicable) new filename text.
  $anchorMatch = [regex]::Match($CellHtml, '<a\b(?<attrs>[^>]*)>(?<text>.*?)(</a>)?', 'Singleline,IgnoreCase')
  if (-not $anchorMatch.Success) { return $CellHtml }

  $attrs = $anchorMatch.Groups['attrs'].Value
  $text = $anchorMatch.Groups['text'].Value

  if ($attrs -match '\bhref\s*=') {
    $attrs = [regex]::Replace($attrs, '\bhref\s*=\s*"[^"]*"', "href=`"$NewHref`"", 'IgnoreCase')
  } else {
    $attrs = "$attrs href=`"$NewHref`""
  }

  $cleanHref = ($NewHref -split '[?#]')[0]
  $fileName = [System.IO.Path]::GetFileName($cleanHref)
  $newText = $text
  if ($fileName) {
    $isFileText = ($text -notmatch '<' -and $text -match '\.(pdf|txt|zip|htm|html)$' -and $text -notmatch '\s')
    if ($isFileText -or [string]::IsNullOrWhiteSpace($text)) {
      $newText = $fileName
    }
  }

  return "<a$attrs>$newText</a>"
}

function Is-PlaceholderHref {
  param([string]$Href)
  if (-not $Href) { return $false }
  $norm = $Href.Trim().ToLowerInvariant()
  # Treat "#" as a placeholder link that should be ignored.
  return ($norm -eq '#')
}

function Get-AlternatePubUrls {
  param([string]$Href)

  $alternates = [System.Collections.Generic.List[string]]::new()
  if (-not $Href) { return $alternates }

  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  if ($seen.Add($Href)) { $alternates.Add($Href) }

  # Only consider CRA forms/pubs pattern; otherwise, return the original URL.
  $match = [regex]::Match(
    $Href,
    '^(?<base>.*?/pub/)(?<folder>\d{4}-g)/(?<file>[^/?#]+)(?<tail>[?#].*)?$',
    'IgnoreCase'
  )
  if (-not $match.Success) { return $alternates }

  $base = $match.Groups['base'].Value
  $folder = $match.Groups['folder'].Value
  $file = $match.Groups['file'].Value
  $tail = $match.Groups['tail'].Value

  function Add-AltUrl {
    param([string]$FolderValue, [string]$FileValue)
    $url = "$base$FolderValue/$FileValue$tail"
    if ($seen.Add($url)) { $alternates.Add($url) }
  }

  # 5xxx-g sometimes appears as 5xxxg in the filename (folder stays 5xxx-g).
  $fileNoHyphen = $null
  $fileNoHyphenMatch = [regex]::Match($file, '^(?<code>\d{4})-g(?<rest>.*)$', 'IgnoreCase')
  if ($fileNoHyphenMatch.Success) {
    $fileNoHyphen = "$($fileNoHyphenMatch.Groups['code'].Value)g$($fileNoHyphenMatch.Groups['rest'].Value)"
    Add-AltUrl -FolderValue $folder -FileValue $fileNoHyphen
  }

  # Some older filenames swap between 50xx and 51xx.
  $fileSwapMatch = [regex]::Match($file, '^(?<prefix>50|51)(?<rest>.*)$', 'IgnoreCase')
  if ($fileSwapMatch.Success) {
    $swapPrefix = if ($fileSwapMatch.Groups['prefix'].Value -eq '50') { '51' } else { '50' }
    $fileSwap = "$swapPrefix$($fileSwapMatch.Groups['rest'].Value)"
    Add-AltUrl -FolderValue $folder -FileValue $fileSwap
  }

  if ($fileNoHyphen) {
    $fileNoHyphenSwapMatch = [regex]::Match($fileNoHyphen, '^(?<prefix>50|51)(?<rest>.*)$', 'IgnoreCase')
    if ($fileNoHyphenSwapMatch.Success) {
      $swapPrefix = if ($fileNoHyphenSwapMatch.Groups['prefix'].Value -eq '50') { '51' } else { '50' }
      $fileNoHyphenSwap = "$swapPrefix$($fileNoHyphenSwapMatch.Groups['rest'].Value)"
      Add-AltUrl -FolderValue $folder -FileValue $fileNoHyphenSwap
    }
  }

  return $alternates
}

function Is-NotAvailableCell {
  param([string]$CellHtml)
  # Detect standard "Not available" placeholders.
  return [regex]::IsMatch(
    $CellHtml,
    '<span\s+class\s*=\s*"small\s+text-muted"\s*>\s*(Not\s+available|Pas\s+disponible)\s*</span>',
    'IgnoreCase'
  )
}

function Test-Url200 {
  param([Parameter(Mandatory)] [string]$Url, [int]$TimeoutSec = 10)
  # HEAD first, then fall back to GET to accommodate servers that block HEAD.
  try {
    $resp = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec $TimeoutSec -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop
    if ($resp.StatusCode -ge 200 -and $resp.StatusCode -lt 300) { return $true }
  } catch {
    try {
      $resp2 = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec $TimeoutSec -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop
      if ($resp2.StatusCode -ge 200 -and $resp2.StatusCode -lt 300) { return $true }
    } catch {
      return $false
    }
  }
  return $false
}

function Resolve-ValidUrl {
  param([Parameter(Mandatory)] [string]$Url, [int]$TimeoutSec = 10)

  # Try original URL and alternates; return the first that validates.
  foreach ($candidate in (Get-AlternatePubUrls -Href $Url)) {
    if (Test-Url200 -Url $candidate -TimeoutSec $TimeoutSec) {
      return [pscustomobject]@{
        IsValid = $true
        Url     = $candidate
      }
    }
  }
  return [pscustomobject]@{
    IsValid = $false
    Url     = $Url
  }
}

function Read-TextFilePreserveEncoding {
  param([Parameter(Mandatory)] [string]$Path)

  function Get-TrailingNewlines([string]$s) {
    $m = [regex]::Match($s, '((?:\r\n|\n|\r)+)$')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
  }

  $bytes = [System.IO.File]::ReadAllBytes($Path)
  if ($bytes.Length -eq 0) {
    return [pscustomobject]@{
      Text             = ''
      Encoding         = [System.Text.UTF8Encoding]::new($false)
      TrailingNewlines = ''
    }
  }

  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $text = [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    return [pscustomobject]@{
      Text             = $text
      Encoding         = [System.Text.UTF8Encoding]::new($true)
      TrailingNewlines = Get-TrailingNewlines $text
    }
  }
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
    $text = [System.Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    return [pscustomobject]@{
      Text             = $text
      Encoding         = [System.Text.Encoding]::Unicode
      TrailingNewlines = Get-TrailingNewlines $text
    }
  }
  if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
    $text = [System.Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    return [pscustomobject]@{
      Text             = $text
      Encoding         = [System.Text.Encoding]::BigEndianUnicode
      TrailingNewlines = Get-TrailingNewlines $text
    }
  }

  $utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)
  try {
    $text = $utf8Strict.GetString($bytes)
    return [pscustomobject]@{
      Text             = $text
      Encoding         = [System.Text.UTF8Encoding]::new($false)
      TrailingNewlines = Get-TrailingNewlines $text
    }
  } catch {
    $text = [System.Text.Encoding]::Default.GetString($bytes)
    return [pscustomobject]@{
      Text             = $text
      Encoding         = [System.Text.Encoding]::Default
      TrailingNewlines = Get-TrailingNewlines $text
    }
  }
}

function Write-TextFileWithEncoding {
  param(
    [Parameter(Mandatory)] [string]$Path,
    [Parameter(Mandatory)] [string]$Text,
    [Parameter(Mandatory)] [System.Text.Encoding]$Encoding,
    [string]$TrailingNewlines = ''
  )
  $normalized = [regex]::Replace($Text, '(?:\r\n|\n|\r)+$', '')
  $toWrite = $normalized + $TrailingNewlines
  [System.IO.File]::WriteAllText($Path, $toWrite, $Encoding)
}

$EN_NA = '<span class="small text-muted">Not available</span>'
$FR_NA = '<span class="small text-muted">Pas disponible</span>'

$PubsListPath = Resolve-ExistingPath -PathValue $PubsListPath -BaseDir $scriptRoot
$TemplateEnPath = Resolve-ExistingPath -PathValue $TemplateEnPath -BaseDir $scriptRoot
$TemplateFrPath = Resolve-ExistingPath -PathValue $TemplateFrPath -BaseDir $scriptRoot

if (-not $PSBoundParameters.ContainsKey('OutputDir') -or [string]::IsNullOrWhiteSpace($OutputDir)) {
  $OutputDir = Join-Path $scriptRoot 'results'
} else {
  $OutputDir = Resolve-DirectoryPath -PathValue $OutputDir -BaseDir $scriptRoot
}
[System.IO.Directory]::CreateDirectory($OutputDir) | Out-Null

Write-Host "Step 1/2: Generating EN/FR tables..." -ForegroundColor Cyan

$pubs = Get-PubsList -Path $PubsListPath
if (-not $pubs) {
  throw "No publication/form codes found in $PubsListPath"
}

$templateEn = Get-Content -LiteralPath $TemplateEnPath -Raw
$templateFr = Get-Content -LiteralPath $TemplateFrPath -Raw
$generatedTotal = 0

foreach ($pub in $pubs) {
  if ($pub -notmatch '^\d{4}-.+$') {
    Write-Warning "Skipping invalid code: '$pub'"
    continue
  }

  $first4 = [int]$pub.Substring(0, 4)
  $suffix = $pub.Substring(4)
  $frPre2019 = ($first4 + 100).ToString() + $suffix

  $enOut = $templateEn.Replace('5000-s2', $pub)
  $frOut = $templateFr.Replace('5000-s2', $pub).Replace('5007-s2', $pub).Replace('5100-s2', $frPre2019)

  $outEnPath = Join-Path $OutputDir "$pub-table-e.htm"
  $outFrPath = Join-Path $OutputDir "$pub-table-f.htm"

  [System.IO.File]::WriteAllText($outEnPath, $enOut, [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText($outFrPath, $frOut, [System.Text.UTF8Encoding]::new($false))
  $generatedTotal++
}

Write-Host "Done. Created $generatedTotal publication pair(s) in '$OutputDir'." -ForegroundColor Cyan

Write-Host "Step 2/2: Validating bilingual links..." -ForegroundColor Cyan

$summary = [System.Collections.Generic.List[object]]::new()

foreach ($pub in $pubs) {
  $enPath = Resolve-TablePath -ResultsFolder $OutputDir -PubName $pub -Lang 'e'
  $frPath = Resolve-TablePath -ResultsFolder $OutputDir -PubName $pub -Lang 'f'

  if (-not (Test-Path -LiteralPath $enPath)) {
    Write-Warning "EN file missing for $pub ($enPath). Skipping."
    continue
  }
  if (-not (Test-Path -LiteralPath $frPath)) {
    Write-Warning "FR file missing for $pub ($frPath). Skipping."
    continue
  }

  $enFile = Read-TextFilePreserveEncoding -Path $enPath
  $frFile = Read-TextFilePreserveEncoding -Path $frPath
  $enHtml = $enFile.Text
  $frHtml = $frFile.Text

  $enTbodyMatch = Get-TBodyMatch $enHtml
  $frTbodyMatch = Get-TBodyMatch $frHtml
  if (-not $enTbodyMatch.Success -or -not $frTbodyMatch.Success) {
    Write-Warning "Could not locate <tbody> in one or both files for $pub. Skipping."
    continue
  }

  $enTbody = $enTbodyMatch.Groups['tb'].Value
  $frTbody = $frTbodyMatch.Groups['tb'].Value

  $enRows = Split-RowMatches $enTbody
  $frRows = Split-RowMatches $frTbody

  if ($enRows.Count -ne $frRows.Count) {
    Write-Warning "Row count mismatch for $pub (EN=$($enRows.Count), FR=$($frRows.Count)). Using min rows."
  }
  $rowCount = [Math]::Min($enRows.Count, $frRows.Count)

  $changed = 0
  $updatedEnRows = @{}
  $updatedFrRows = @{}

  for ($ri = 0; $ri -lt $rowCount; $ri++) {
    $enRow = $enRows[$ri].Value
    $frRow = $frRows[$ri].Value
    $enCells = Split-CellMatches $enRow
    $frCells = Split-CellMatches $frRow
    if ($enCells.Count -eq 0 -or $frCells.Count -eq 0) { continue }

    $colCount = [Math]::Min($enCells.Count, $frCells.Count)
    $enCellReplacements = @{}
    $frCellReplacements = @{}

    for ($ci = 1; $ci -lt $colCount; $ci++) {
      $enCell = $enCells[$ci].Groups['cell'].Value
      $frCell = $frCells[$ci].Groups['cell'].Value

      $enIsNA = Is-NotAvailableCell $enCell
      $frIsNA = Is-NotAvailableCell $frCell
      if ($enIsNA -or $frIsNA) {
        if ($enCell -notmatch $EN_NA) { $enCellReplacements[$ci] = $EN_NA }
        if ($frCell -notmatch $FR_NA) { $frCellReplacements[$ci] = $FR_NA }
        $changed++
        continue
      }

      $enHref = Get-LinkHref $enCell
      $frHref = Get-LinkHref $frCell

      # Requested behavior: ignore cells with no links at all.
      if (-not $enHref -and -not $frHref) {
        continue
      }

      # Requested behavior: ignore placeholder links.
      if (Is-PlaceholderHref $enHref -or Is-PlaceholderHref $frHref) {
        continue
      }

      # Validate only true EN/FR link pairs.
      if (-not $enHref -or -not $frHref) {
        continue
      }

      $enResult = Resolve-ValidUrl -Url $enHref -TimeoutSec $TimeoutSec
      $frResult = Resolve-ValidUrl -Url $frHref -TimeoutSec $TimeoutSec

      if (-not ($enResult.IsValid -and $frResult.IsValid)) {
        $enCellReplacements[$ci] = $EN_NA
        $frCellReplacements[$ci] = $FR_NA
        $changed++
        continue
      }

      if ($enResult.Url -ne $enHref) {
        $updatedEnCell = Replace-AnchorHrefAndText -CellHtml $enCell -NewHref $enResult.Url
        if ($updatedEnCell -ne $enCell) {
          $enCellReplacements[$ci] = $updatedEnCell
          $changed++
        }
      }

      if ($frResult.Url -ne $frHref) {
        $updatedFrCell = Replace-AnchorHrefAndText -CellHtml $frCell -NewHref $frResult.Url
        if ($updatedFrCell -ne $frCell) {
          $frCellReplacements[$ci] = $updatedFrCell
          $changed++
        }
      }
    }

    if ($enCellReplacements.Count -gt 0) {
      $updatedEnRows[$ri] = Replace-CellsInRow -RowHtml $enRow -CellMatches $enCells -Replacements $enCellReplacements
    }
    if ($frCellReplacements.Count -gt 0) {
      $updatedFrRows[$ri] = Replace-CellsInRow -RowHtml $frRow -CellMatches $frCells -Replacements $frCellReplacements
    }
  }

  $newEnTbody = Replace-RowsInTBody -TbodyHtml $enTbody -RowMatches $enRows -UpdatedRows $updatedEnRows
  $newFrTbody = Replace-RowsInTBody -TbodyHtml $frTbody -RowMatches $frRows -UpdatedRows $updatedFrRows
  $outEnHtml = Replace-TBodyInHtml -Html $enHtml -TBodyMatch $enTbodyMatch -NewInner $newEnTbody
  $outFrHtml = Replace-TBodyInHtml -Html $frHtml -TBodyMatch $frTbodyMatch -NewInner $newFrTbody

  if ($DryRun) {
    Write-Host "[DRY RUN] $pub => would modify $changed cell(s)."
  } else {
    Write-TextFileWithEncoding -Path $enPath -Text $outEnHtml -Encoding $enFile.Encoding -TrailingNewlines $enFile.TrailingNewlines
    Write-TextFileWithEncoding -Path $frPath -Text $outFrHtml -Encoding $frFile.Encoding -TrailingNewlines $frFile.TrailingNewlines
    Write-Host "$pub => modified $changed cell(s)."
  }

  $summary.Add([pscustomobject]@{
      Publication = $pub
      EN_File     = $enPath
      FR_File     = $frPath
      Changed     = $changed
    })
}

Write-Host "`nSummary:"
$summary | Format-Table -AutoSize
Write-Host "`nAll done." -ForegroundColor Green

