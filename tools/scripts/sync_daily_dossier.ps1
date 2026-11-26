<#
.SYNOPSIS
    Transactional 1-Shot Dossier Synchronizer.
    Parses docs/daily_audit_temp.log, updates JA & KO dossiers, verifies parity, and clears processed rows safely.
#>
[CmdletBinding()]
param(
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

$tempLogPath = Join-Path $projectRoot "docs\daily_audit_temp.log"
$jaDossierPath = Join-Path $projectRoot "docs\audit_evidence_dossier.md"
$koDossierPath = Join-Path $projectRoot "docs\audit_evidence_dossier_KO.md"
$lockFile = Join-Path $projectRoot "logs\dossier_sync.lock"

if (-not (Test-Path $tempLogPath)) {
    Write-Host "[DOSSIER SYNC] No daily_audit_temp.log found. Nothing to sync."
    exit 0
}

$logContent = [System.IO.File]::ReadAllText($tempLogPath, [System.Text.Encoding]::UTF8)
$logLines = @($logContent -split "`r?`n" | Where-Object { $_.Trim() -ne "" })

if ($logLines.Count -eq 0) {
    Write-Host "[DOSSIER SYNC] daily_audit_temp.log is empty. Nothing to sync."
    exit 0
}

# 1. Acquire Lock
if (Test-Path $lockFile) {
    $lockAge = (Get-Item $lockFile).LastWriteTimeUtc
    if (([DateTime]::UtcNow - $lockAge).TotalMinutes -lt 5) {
        Write-Error "[LOCK CONFLICT] Another dossier sync operation is active."
        exit 1
    }
}

try {
    [System.IO.File]::WriteAllText($lockFile, "LOCKED by PID $PID at $([DateTime]::UtcNow.ToString('o'))", [System.Text.Encoding]::UTF8)

    # 2. In-Memory Backup
    $jaBackup = [System.IO.File]::ReadAllText($jaDossierPath, [System.Text.Encoding]::UTF8)
    $koBackup = [System.IO.File]::ReadAllText($koDossierPath, [System.Text.Encoding]::UTF8)

    Write-Host "[DOSSIER SYNC] Found $($logLines.Count) rows to synchronize."

    # Parse rows into table lines
    $newJaRows = @()
    $newKoRows = @()

    foreach ($line in $logLines) {
        # Format: [2026-11-25 13:18:44] [AUDIT-SPLIT-01] Target: GEMINI.md (48 lines) | Model: qwen3.8:27b | Duration: 72.92s | Input: 2231 tokens | Output: 3580 tokens | Speed: 49.9 tokens/s | Verdict: 0 P0, 2 P1(WARN), 3 P2(WARN)
        if ($line -match '\[(.*?)\]\s*\[(.*?)\]\s*Target:\s*(.*?)\s*\|\s*Model:\s*(.*?)\s*\|\s*Duration:\s*(.*?)\s*\|\s*Input:\s*(.*?)\s*\|\s*Output:\s*(.*?)\s*\|\s*Speed:\s*(.*?)\s*\|\s*Verdict:\s*(.*)') {
            $timeStr = $matches[1]
            $tag = $matches[2]
            $target = $matches[3]
            $model = $matches[4]
            $duration = $matches[5]
            $inputTok = $matches[6]
            $outputTok = $matches[7]
            $speed = $matches[8]
            $verdict = $matches[9]

            $phaseJa = "**ローカル監査 ($tag)**"
            $phaseKo = "**ローカル監査 ($tag)**"
            $tokensSummary = "In: $inputTok / Out: $outputTok"
            $envDescJa = "自社 RTX 5070 Ti (Tailscale P2P)"
            $envDescKo = "自社 RTX 5070 Ti (Tailscale P2P)"

            $jaRow = "| $phaseJa | ``$model`` | $envDescJa | **$duration** | $tokensSummary | **$speed** | **$verdict** |"
            $koRow = "| $phaseKo | ``$model`` | $envDescKo | **$duration** | $tokensSummary | **$speed** | **$verdict** |"

            $newJaRows += $jaRow
            $newKoRows += $koRow
        }
    }

    if ($newJaRows.Count -eq 0) {
        Write-Host "  [WARN] No parsable rows found in daily_audit_temp.log." -ForegroundColor Yellow
        exit 0
    }

    if ($DryRun) {
        Write-Host "  [DRY-RUN] Would append $($newJaRows.Count) rows to JA and KO dossiers." -ForegroundColor Cyan
        exit 0
    }

    # 3. Append to JA and KO files at the end of the last table
    $jaUpdated = $jaBackup.TrimEnd() + "`r`n" + ($newJaRows -join "`r`n") + "`r`n"
    $koUpdated = $koBackup.TrimEnd() + "`r`n" + ($newKoRows -join "`r`n") + "`r`n"

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($jaDossierPath, $jaUpdated, $utf8NoBom)
    [System.IO.File]::WriteAllText($koDossierPath, $koUpdated, $utf8NoBom)

    # 4. Verify Check 3.2 Parity
    Write-Host "[DOSSIER SYNC] Validating JA/KO structural parity..."
    $verifierScript = Join-Path $projectRoot "tools\scripts\verify_repo_total_integrity.ps1"
    $checkOutput = & powershell -ExecutionPolicy Bypass -File $verifierScript 2>&1

    if ($checkOutput -match '\[MIRROR STRUCTURE MISMATCH\]') {
        Write-Error "[PARITY ERROR] Heading or table mismatch detected. Rolling back changes!"
        [System.IO.File]::WriteAllText($jaDossierPath, $jaBackup, [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($koDossierPath, $koBackup, [System.Text.Encoding]::UTF8)
        exit 1
    }

    # 5. Success: Prune processed rows from temp log
    [System.IO.File]::WriteAllText($tempLogPath, "", [System.Text.Encoding]::UTF8)
    Write-Host "[DOSSIER SYNC COMPLETED] Successfully injected $($newJaRows.Count) rows. daily_audit_temp.log cleared." -ForegroundColor Green
}
finally {
    if (Test-Path $lockFile) {
        Remove-Item -Path $lockFile -Force -ErrorAction SilentlyContinue
    }
}
