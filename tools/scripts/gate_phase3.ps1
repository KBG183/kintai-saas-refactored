<#
.SYNOPSIS
    Deterministic Verification & Pre-Write Hard Gate (gate_phase3.ps1)
.DESCRIPTION
    Ensures deterministic linter checks pass before allowing any write operation to canonical files.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetFile,

    [Parameter(Mandatory = $false)]
    [string]$ReportFile = ""
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host ">>> [GATE PHASE 3] Verifying Target File Integrity: $TargetFile" -ForegroundColor Yellow

if (-not (Test-Path $TargetFile)) {
    Write-Error "GATE_FAIL: Target file does not exist: $TargetFile"
    exit 1
}

# Run Deterministic Linter
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$verifyScript = Join-Path $scriptDir "verify_srs.ps1"

if (Test-Path $verifyScript) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File $verifyScript -TargetFile $TargetFile
    if ($LASTEXITCODE -ne 0) {
        Write-Error "GATE_BLOCKED: Deterministic linter verification failed. Canonical write rejected."
        exit $LASTEXITCODE
    }
} else {
    Write-Error "GATE_BLOCKED: Verifier script missing ($verifyScript). Fail-Closed enforcement."
    exit 2
}

Write-Host ">>> [GATE PASS] All hard-gate verifications passed. Canonical write approved." -ForegroundColor Green
exit 0
