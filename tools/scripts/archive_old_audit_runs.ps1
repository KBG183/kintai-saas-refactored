<#
.SYNOPSIS
    Safely archives completed audit runs older than 25 hours to audit/archive/.
    Hardened against concurrency, race conditions, and sidecar search degradation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [int]$HoursThreshold = 25,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun = $false
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
if (-not (Test-Path (Join-Path $projectRoot "GEMINI.md"))) {
    $projectRoot = Split-Path -Parent $scriptDir
}

$auditRunsDir = Join-Path $projectRoot "audit\runs"
$archiveBaseDir = Join-Path $projectRoot "audit\archive"
$lockFile = Join-Path $projectRoot "audit\archive.lock"

if (-not (Test-Path $auditRunsDir)) {
    Write-Host "[ARCHIVE] audit/runs directory does not exist. Exiting."
    exit 0
}

# 1. Acquire Mutual Exclusion Lock
if (Test-Path $lockFile) {
    $lockAge = (Get-Item $lockFile).LastWriteTimeUtc
    if (([DateTime]::UtcNow - $lockAge).TotalMinutes -lt 5) {
        Write-Error "[LOCK CONFLICT] Another archive operation is currently active. Aborting."
        exit 1
    } else {
        Remove-Item -Path $lockFile -Force -ErrorAction SilentlyContinue
    }
}

try {
    [System.IO.File]::WriteAllText($lockFile, "LOCKED at $([DateTime]::UtcNow.ToString('o')) by PID $PID", [System.Text.Encoding]::UTF8)

    $baselineUtc = [DateTime]::UtcNow
    $cutoffUtc = $baselineUtc.AddHours(-$HoursThreshold)

    Write-Host "[ARCHIVE] Scan Baseline UTC: $($baselineUtc.ToString('o')), Cutoff (> $HoursThreshold h): $($cutoffUtc.ToString('o'))"

    $runDirs = Get-ChildItem -Path $auditRunsDir -Directory
    $archivedCount = 0
    $skippedCount = 0

    foreach ($rd in $runDirs) {
        $runPath = $rd.FullName
        $runName = $rd.Name

        # Check completed indicators
        $verdictPath = Join-Path $runPath "verdict.json"
        $donePath = Join-Path $runPath ".done"
        $hasCompletedSign = (Test-Path $verdictPath) -or (Test-Path $donePath)

        if (-not $hasCompletedSign) {
            # Still in-progress or incomplete run; do not touch
            $skippedCount++
            continue
        }

        # Determine effective creation time
        $createdUtc = $rd.CreationTimeUtc
        if (Test-Path $verdictPath) {
            try {
                $vJson = [System.IO.File]::ReadAllText($verdictPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                if ($vJson.created_utc) {
                    $createdUtc = [DateTime]::Parse($vJson.created_utc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
                }
            } catch {}
        }
        $lastWriteUtc = $rd.LastWriteTimeUtc

        # Safe Dual-Time Guard: BOTH created and last write must be older than cutoff
        if ($createdUtc -lt $cutoffUtc -and $lastWriteUtc -lt $cutoffUtc) {
            $dateFolder = $createdUtc.ToString("yyyy-MM-dd")
            $targetDir = Join-Path (Join-Path $archiveBaseDir $dateFolder) $runName

            if (Test-Path $targetDir) {
                Write-Host "  [SKIP COLLISION] Destination exists: $targetDir" -ForegroundColor Yellow
                $skippedCount++
                continue
            }

            if ($DryRun) {
                Write-Host "  [DRY-RUN MOVE] $runName -> audit/archive/$dateFolder/" -ForegroundColor Cyan
                $archivedCount++
            } else {
                $parentDateDir = Split-Path -Parent $targetDir
                if (-not (Test-Path $parentDateDir)) {
                    New-Item -ItemType Directory -Path $parentDateDir -Force | Out-Null
                }
                Move-Item -Path $runPath -Destination $targetDir -Force
                $archivedCount++
            }
        } else {
            $skippedCount++
        }
    }

    Write-Host "[ARCHIVE COMPLETED] Archived: $archivedCount runs, Retained active: $skippedCount runs."
}
finally {
    if (Test-Path $lockFile) {
        Remove-Item -Path $lockFile -Force -ErrorAction SilentlyContinue
    }
}
