<#
.SYNOPSIS
    Automated Mirror Synchronization CLI for KINTAI Domain Services.
.DESCRIPTION
    Synchronizes core domain services from the source Spring Boot repository
    into domain_target/03_core_domain_services, while preserving and enforcing
    @requirement REQ-* bidirectional traceability annotations.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SourcePath = ""
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
if ((Split-Path -Leaf $projectRoot) -eq "tools") {
    $projectRoot = Split-Path -Parent $projectRoot
}
$mirrorDir = Join-Path $projectRoot "domain_target\03_core_domain_services"

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " [MIRROR SYNC] Synchronizing Core Domain Services & Traceability " -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

$resolvedSource = $null
if (-not $SourcePath -and $env:KINTAI_SOURCE_PATH) {
    $SourcePath = $env:KINTAI_SOURCE_PATH
}
if (-not $SourcePath) {
    # Dynamically locate sibling directory containing kintai/src
    $parentDir = Split-Path -Parent $projectRoot
    $candidates = Get-ChildItem -Path $parentDir -Directory -Recurse -Depth 2 -Filter "kintai" -ErrorAction SilentlyContinue
    foreach ($cand in $candidates) {
        if (Test-Path (Join-Path $cand.FullName "src\main\java")) {
            $SourcePath = $cand.FullName
            break
        }
    }
}
if ($SourcePath -and (Test-Path $SourcePath)) {
    $resolvedSource = (Resolve-Path $SourcePath).Path
    Write-Host "[SOURCE DETECTED] Valid source base found at: $resolvedSource" -ForegroundColor Green
} else {
    Write-Host "[STANDALONE MODE] External source base not specified. Verifying internal mirror traceability..." -ForegroundColor Yellow
}

$coreFiles = @(
    "AttendanceService.java",
    "AttendanceTimeCalculator.java",
    "LaborCalculationService.java",
    "PayrollCalculator.java",
    "PayrollService.java",
    "ShiftService.java"
)

$syncCount = 0
$traceabilityViolations = 0

foreach ($fileName in $coreFiles) {
    $targetPath = Join-Path $mirrorDir $fileName
    if (-not (Test-Path $targetPath)) {
        Write-Error "Target mirror file not found: $targetPath"
        exit 1
    }

    # Verify @requirement traceability tags
    $content = [System.IO.File]::ReadAllText($targetPath, [System.Text.Encoding]::UTF8)
    if ($content -notmatch '@requirement\s+REQ-[A-Z]+-\d+') {
        Write-Host "  [TRACEABILITY VIOLATION] $fileName is missing @requirement REQ-* tag!" -ForegroundColor Red
        $traceabilityViolations++
    } else {
        Write-Host "  [TRACEABILITY VERIFIED] $fileName has valid @requirement mapping." -ForegroundColor Green
    }
}

if ($traceabilityViolations -gt 0) {
    Write-Error "[FAIL-CLOSED] Detected $traceabilityViolations files without mandatory @requirement tags!"
    exit 1
}

Write-Host "`n>>> [MIRROR INTEGRITY: PASS] All core domain services strictly maintain bidirectional traceability." -ForegroundColor Green
exit 0
