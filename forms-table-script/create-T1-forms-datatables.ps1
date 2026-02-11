<#
create-T1-forms-datatables.ps1

Standalone script that runs the full T1 workflow:
1) Generate EN/FR HTML table files from templates.
2) Validate bilingual links and normalize unavailable/not applicable cells.

Defaults are resolved from this script's folder so it can be executed
from any current working directory.
#>

[CmdletBinding()]
param(
  [string]$FormsListPath = ".\recent-T1-forms-9yrs.txt",
  [string]$TemplateEnPath = ".\5000-s2-table-e.htm",
  [string]$TemplateFrPath = ".\5000-s2-table-f.htm",
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
    [Parameter(Mandatory)] [string]$FormName,
    [Parameter(Mandatory)] [ValidateSet('e', 'f')] [string]$Lang
  )
  $candidates = @(
    (Join-Path $ResultsFolder "$FormName-table-$Lang.htm"),
    (Join-Path $ResultsFolder "$FormName-table-$Lang.html")
  )
  foreach ($p in $candidates) {
    if (Test-Path -LiteralPath $p) { return $p }
  }
  return $candidates[0]
}

function Get-FormsList {
  param(
    [Parameter(Mandatory)] [string]$Path,
    [switch]$SkipComments
  )

  $forms = Get-Content -LiteralPath $Path |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -and $_ -ne '' }

  if ($SkipComments) {
    $forms = $forms | Where-Object { -not $_.StartsWith('#') }
  }

  return $forms
}

function Get-EffectiveCellContent {
  param(
    [Parameter(Mandatory)] [hashtable]$Replacements,
    [Parameter(Mandatory)] [int]$CellIndex,
    [Parameter(Mandatory)] [object[]]$Cells
  )

  if ($Replacements.ContainsKey($CellIndex)) {
    return [string]$Replacements[$CellIndex]
  }
  return $Cells[$CellIndex].Groups['cell'].Value
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
  return [regex]::Matches(
    $RowHtml,
    '<(?<tag>th|td)(?<attrs>\s+[^>]*)?>(?<cell>.*?)</\k<tag>>',
    'Singleline,IgnoreCase'
  )
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
  $m = [regex]::Match($CellHtml, 'href\s*=\s*"([^"]+)"', 'IgnoreCase')
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
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

function Is-NotAvailableCell {
  param([string]$CellHtml)
  return [regex]::IsMatch(
    $CellHtml,
    '<span\s+class\s*=\s*"small\s+text-muted"\s*>\s*(Not\s+available|Pas\s+disponible)\s*</span>',
    'IgnoreCase'
  )
}

function Test-Url200 {
  param([Parameter(Mandatory)] [string]$Url, [int]$TimeoutSec = 10)
  try {
    $resp = Invoke-WebRequest -Uri $Url -Method Head -TimeoutSec $TimeoutSec -MaximumRedirection 0 -ErrorAction Stop
    if ($resp.StatusCode -eq 200) { return $true }
  } catch {
    try {
      $resp2 = Invoke-WebRequest -Uri $Url -Method Get -TimeoutSec $TimeoutSec -MaximumRedirection 0 -ErrorAction Stop
      if ($resp2.StatusCode -eq 200) { return $true }
    } catch {
      return $false
    }
  }
  return $false
}

$EN_NA = '<span class="small text-muted">Not available</span>'
$FR_NA = '<span class="small text-muted">Pas disponible</span>'
$EN_NAP = '<span class="small text-muted">Not applicable</span>'
$FR_NAP = '<span class="small text-muted">Pas applicable</span>'

$FormsListPath = Resolve-ExistingPath -PathValue $FormsListPath -BaseDir $scriptRoot
$TemplateEnPath = Resolve-ExistingPath -PathValue $TemplateEnPath -BaseDir $scriptRoot
$TemplateFrPath = Resolve-ExistingPath -PathValue $TemplateFrPath -BaseDir $scriptRoot

if (-not $PSBoundParameters.ContainsKey('OutputDir') -or [string]::IsNullOrWhiteSpace($OutputDir)) {
  $OutputDir = Join-Path $scriptRoot 'results'
} else {
  $OutputDir = Resolve-DirectoryPath -PathValue $OutputDir -BaseDir $scriptRoot
}
[System.IO.Directory]::CreateDirectory($OutputDir) | Out-Null

Write-Host "Step 1/2: Generating EN/FR tables..." -ForegroundColor Cyan

$formsForGeneration = Get-FormsList -Path $FormsListPath -SkipComments

if (-not $formsForGeneration) {
  throw "No form codes found in $FormsListPath"
}

$templateEn = Get-Content -LiteralPath $TemplateEnPath -Raw
$templateFr = Get-Content -LiteralPath $TemplateFrPath -Raw
$generatedTotal = 0

foreach ($form in $formsForGeneration) {
  if ($form -notmatch '^\d{4}-.+$') {
    Write-Warning "Skipping invalid form code: '$form'"
    continue
  }

  $first4 = [int]$form.Substring(0,4)
  $suffix = $form.Substring(4)
  $frPre2019 = ($first4 + 100).ToString() + $suffix

  $enOut = $templateEn.Replace('5000-s2', $form)
  $frOut = $templateFr.Replace('5000-s2', $form).Replace('5100-s2', $frPre2019)

  $outEnPath = Join-Path $OutputDir "$form-table-e.htm"
  $outFrPath = Join-Path $OutputDir "$form-table-f.htm"

  [System.IO.File]::WriteAllText($outEnPath, $enOut, [System.Text.UTF8Encoding]::new($false))
  [System.IO.File]::WriteAllText($outFrPath, $frOut, [System.Text.UTF8Encoding]::new($false))
  $generatedTotal++
}

Write-Host "Done. Created $generatedTotal form pair(s) in '$OutputDir'." -ForegroundColor Cyan

Write-Host "Step 2/2: Validating bilingual links..." -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $OutputDir)) {
  throw "Results folder not found: $OutputDir"
}

$forms = Get-FormsList -Path $FormsListPath

$summary = [System.Collections.Generic.List[object]]::new()

foreach ($form in $forms) {
  $enPath = Resolve-TablePath -ResultsFolder $OutputDir -FormName $form -Lang 'e'
  $frPath = Resolve-TablePath -ResultsFolder $OutputDir -FormName $form -Lang 'f'

  if (-not (Test-Path -LiteralPath $enPath)) {
    Write-Warning "EN file missing for $form ($enPath). Skipping."
    continue
  }
  if (-not (Test-Path -LiteralPath $frPath)) {
    Write-Warning "FR file missing for $form ($frPath). Skipping."
    continue
  }

  $enFile = Read-TextFilePreserveEncoding -Path $enPath
  $frFile = Read-TextFilePreserveEncoding -Path $frPath
  $enHtml = $enFile.Text
  $frHtml = $frFile.Text

  $enTbodyMatch = Get-TBodyMatch $enHtml
  $frTbodyMatch = Get-TBodyMatch $frHtml
  if (-not $enTbodyMatch.Success -or -not $frTbodyMatch.Success) {
    Write-Warning "Could not locate <tbody> in one or both files for $form. Skipping."
    continue
  }

  $enTbody = $enTbodyMatch.Groups['tb'].Value
  $frTbody = $frTbodyMatch.Groups['tb'].Value

  $enRows = Split-RowMatches $enTbody
  $frRows = Split-RowMatches $frTbody

  if ($enRows.Count -ne $frRows.Count) {
    Write-Warning "Row count mismatch for $form (EN=$($enRows.Count), FR=$($frRows.Count)). Using min rows."
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

      $enValid = $false
      $frValid = $false

      if ($enHref) { $enValid = Test-Url200 -Url $enHref -TimeoutSec $TimeoutSec }
      if ($frHref) { $frValid = Test-Url200 -Url $frHref -TimeoutSec $TimeoutSec }

      if (-not ($enValid -and $frValid)) {
        $enCellReplacements[$ci] = $EN_NA
        $frCellReplacements[$ci] = $FR_NA
        $changed++
      }
    }

    $rowHasAnyLink = $false
    for ($ci = 1; $ci -lt $colCount; $ci++) {
      $enFinalCell = Get-EffectiveCellContent -Replacements $enCellReplacements -CellIndex $ci -Cells $enCells
      $frFinalCell = Get-EffectiveCellContent -Replacements $frCellReplacements -CellIndex $ci -Cells $frCells
      if ((Get-LinkHref $enFinalCell) -or (Get-LinkHref $frFinalCell)) {
        $rowHasAnyLink = $true
        break
      }
    }

    if (-not $rowHasAnyLink) {
      for ($ci = 1; $ci -lt $colCount; $ci++) {
        $enFinalCell = Get-EffectiveCellContent -Replacements $enCellReplacements -CellIndex $ci -Cells $enCells
        $frFinalCell = Get-EffectiveCellContent -Replacements $frCellReplacements -CellIndex $ci -Cells $frCells

        $rowCellChanged = $false
        if ($enFinalCell -notmatch $EN_NAP) {
          $enCellReplacements[$ci] = $EN_NAP
          $rowCellChanged = $true
        }
        if ($frFinalCell -notmatch $FR_NAP) {
          $frCellReplacements[$ci] = $FR_NAP
          $rowCellChanged = $true
        }
        if ($rowCellChanged) { $changed++ }
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
    Write-Host "[DRY RUN] $form => would modify $changed cell(s)."
  } else {
    Write-TextFileWithEncoding -Path $enPath -Text $outEnHtml -Encoding $enFile.Encoding -TrailingNewlines $enFile.TrailingNewlines
    Write-TextFileWithEncoding -Path $frPath -Text $outFrHtml -Encoding $frFile.Encoding -TrailingNewlines $frFile.TrailingNewlines
    Write-Host "$form => modified $changed cell(s)."
  }

  $summary.Add([pscustomobject]@{
      Form    = $form
      EN_File = $enPath
      FR_File = $frPath
      Changed = $changed
    })
}

Write-Host "`nSummary:"
$summary | Format-Table -AutoSize
Write-Host "`nAll done." -ForegroundColor Green
