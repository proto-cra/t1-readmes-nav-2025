<#
create-T1-forms-datatables.ps1

Runs the full T1 table workflow in one command:
1) Generate EN/FR HTML table files from templates.
2) Validate bilingual links and normalize unavailable/not applicable cells.

Defaults are resolved from this script's folder so it can be executed
from any current working directory.
#>

[CmdletBinding()]
param(
  # Form codes list file (one form per line).
  [string]$FormsListPath = ".\recent-T1-forms-9yrs.txt",
  # English source template.
  [string]$TemplateEnPath = ".\5000-s2-table-e.htm",
  # French source template.
  [string]$TemplateFrPath = ".\5000-s2-table-f.htm",
  # Destination folder for generated table files.
  [string]$OutputDir,
  # HTTP timeout used by the validation step.
  [int]$TimeoutSec = 12,
  # If set, validation reports changes without writing them.
  [switch]$DryRun
)

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$generatorScript = Join-Path $scriptRoot "generate-t1-readme-tables-9yrs-v3.ps1"
$validatorScript = Join-Path $scriptRoot "validate-t1-bilingual-links.ps1"

function Resolve-ExistingPath {
  param(
    [Parameter(Mandatory)] [string]$PathValue,
    [Parameter(Mandatory)] [string]$BaseDir
  )

  # If already absolute, validate and return canonical path.
  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    if (-not (Test-Path -LiteralPath $PathValue)) {
      throw "Required file not found: $PathValue"
    }
    return (Resolve-Path -LiteralPath $PathValue).Path
  }

  # Prefer paths relative to this script's folder.
  $scriptRelative = Join-Path $BaseDir $PathValue
  if (Test-Path -LiteralPath $scriptRelative) {
    return (Resolve-Path -LiteralPath $scriptRelative).Path
  }

  # Fallback: allow path relative to current location.
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

  # Keep absolute output directories as-is; otherwise anchor to script folder.
  if ([System.IO.Path]::IsPathRooted($PathValue)) {
    return $PathValue
  }

  return (Join-Path $BaseDir $PathValue)
}

# Verify dependent scripts are present before starting.
if (-not (Test-Path -LiteralPath $generatorScript)) {
  throw "Generator script not found: $generatorScript"
}
if (-not (Test-Path -LiteralPath $validatorScript)) {
  throw "Validator script not found: $validatorScript"
}

# Normalize incoming paths so child scripts receive explicit locations.
$FormsListPath = Resolve-ExistingPath -PathValue $FormsListPath -BaseDir $scriptRoot
$TemplateEnPath = Resolve-ExistingPath -PathValue $TemplateEnPath -BaseDir $scriptRoot
$TemplateFrPath = Resolve-ExistingPath -PathValue $TemplateFrPath -BaseDir $scriptRoot

if (-not $PSBoundParameters.ContainsKey('OutputDir') -or [string]::IsNullOrWhiteSpace($OutputDir)) {
  $OutputDir = Join-Path $scriptRoot 'results'
} else {
  $OutputDir = Resolve-DirectoryPath -PathValue $OutputDir -BaseDir $scriptRoot
}

# Step 1: create per-form EN/FR tables.
Write-Host "Step 1/2: Generating EN/FR tables..." -ForegroundColor Cyan
$genParams = @{
  FormsListPath = $FormsListPath
  TemplateEnPath = $TemplateEnPath
  TemplateFrPath = $TemplateFrPath
  OutputDir = $OutputDir
}
& $generatorScript @genParams
if (-not $?) {
  throw "Generation step failed."
}

# Step 2: validate links in generated tables.
Write-Host "Step 2/2: Validating bilingual links..." -ForegroundColor Cyan
$valParams = @{
  FormsPath = $FormsListPath
  ResultsFolder = $OutputDir
  TimeoutSec = $TimeoutSec
}
if ($DryRun) {
  $valParams.DryRun = $true
}

& $validatorScript @valParams
if (-not $?) {
  throw "Validation step failed."
}

Write-Host "`nAll done." -ForegroundColor Green
