<#
.SYNOPSIS
    KINTAI Dashboard Automated Single Source of Truth Synchronization Script
.DESCRIPTION
    Dynamically parses config/srs_specification_ssot.md to extract all requirements (REQ-*),
    cross-references latest audit reports and enterprise_audit_ledger.csv,
    and deterministically renders pipeline_metrics.md and CURRENT_STATUS.md.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$SsotFile = "config\srs_specification_ssot.md",

    [Parameter(Mandatory = $false)]
    [string]$LedgerFile = "logs\enterprise_audit_ledger.csv",

    [Parameter(Mandatory = $false)]
    [string]$StatusFile = "logs\CURRENT_STATUS.md",

    [Parameter(Mandatory = $false)]
    [string]$MetricsFile = "logs\pipeline_metrics.md",

    [Parameter(Mandatory = $false)]
    [string]$AuditDir = "audit"
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
if (-not (Test-Path $projectRoot)) { $projectRoot = (Get-Location).Path }

$ssotPath = Join-Path $projectRoot $SsotFile
$ledgerPath = Join-Path $projectRoot $LedgerFile
$statusPath = Join-Path $projectRoot $StatusFile
$metricsPath = Join-Path $projectRoot $MetricsFile
$auditDirPath = Join-Path $projectRoot $AuditDir

if (-not (Test-Path $ssotPath)) {
    Write-Error "SSOT specification file not found: $ssotPath"
    exit 1
}

<# Step 1. Parse SSOT Specification (Single Source of Truth) #>
$ssotLines = [System.IO.File]::ReadAllLines($ssotPath, [System.Text.Encoding]::UTF8)
$reqList = @()
$reqRegex = [System.Text.RegularExpressions.Regex]::new('^#{3,4}\s*\[(REQ-[A-Z0-9\-]+)\]\s*(.+)')

foreach ($line in $ssotLines) {
    $match = $reqRegex.Match($line.Trim())
    if ($match.Success) {
        $reqList += [PSCustomObject]@{
            Id    = $match.Groups[1].Value.Trim()
            Title = $match.Groups[2].Value.Trim()
        }
    }
}

$totalReqCount = $reqList.Count
if ($totalReqCount -eq 0) {
    Write-Error "No requirements (REQ-*) found in $ssotPath"
    exit 1
}

Write-Host ">>> [SSOT PARSE] Detected $totalReqCount requirements in $SsotFile" -ForegroundColor Cyan

<# Step 2. Parse Audit Ledger & Latest Audit Report #>
$lastBatchId = "BATCH-01"
$lastStatus = "AUDIT_FINDINGS_REPORTED"
$lastNotes = "Initial verification state"

if (Test-Path $ledgerPath) {
    $rawLines = [System.IO.File]::ReadAllLines($ledgerPath, [System.Text.Encoding]::UTF8)
    $validRows = @()
    foreach ($l in $rawLines) {
        $trimmed = $l.Trim()
        if ($trimmed.Length -gt 0) { $validRows += $trimmed }
    }
    if ($validRows.Count -gt 1) {
        $lastRow = $validRows[$validRows.Count - 1]
        $lastCols = $lastRow -split ","
        if ($lastCols.Count -ge 4) {
            $lastBatchId = $lastCols[1]
            $lastStatus = $lastCols[3]
        }
        if ($lastCols.Count -ge 12) {
            $lastNotes = $lastCols[11]
        }
    }
}

# Scan latest HERMES audit report for requirement findings
$latestAuditReport = ""
if (Test-Path $auditDirPath) {
    $auditFiles = Get-ChildItem -Path $auditDirPath -Filter "HERMES_Audit_*.md" | Sort-Object LastWriteTime -Descending
    if ($auditFiles.Count -gt 0) {
        $latestAuditReport = $auditFiles[0].FullName
    }
}

$reportContent = ""
if ($latestAuditReport -and (Test-Path $latestAuditReport)) {
    $reportContent = [System.IO.File]::ReadAllText($latestAuditReport, [System.Text.Encoding]::UTF8)
    Write-Host ">>> [AUDIT REPORT] Scanning findings from: $([System.IO.Path]::GetFileName($latestAuditReport))" -ForegroundColor Cyan
}

<# Step 3. Determine Verification Matrix for Each Requirement #>
$matrixRows = @()

# Dynamically run deterministic integrity linter via wrapper/binary
$linterWrapper = Join-Path $scriptDir "verify_srs.ps1"
$linterExe = Join-Path $scriptDir "VerifySRS.exe"
if (-not (Test-Path $linterExe)) {
    & powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $linterWrapper -Files @() 2>&1 | Out-Null
}
$ssotPath = Join-Path $projectRoot "config\srs_specification_ssot.md"
$linterVerdict = "UNKNOWN"
if (Test-Path $linterExe) {
    & $linterExe $ssotPath | Out-Null
    if ($LASTEXITCODE -ne 0) { 
        $linterVerdict = "FAIL" 
    } else {
        $linterVerdict = "PASS"
    }
} else {
    $linterVerdict = "FAIL"
}

foreach ($req in $reqList) {
    $id = $req.Id
    $title = $req.Title

    $qwenVerdict = "PASS"
    $codexVerdict = "PASS"
    $claudeVerdict = "PASS"

    if ($reportContent) {
        # Check Qwen findings section dynamically
        if ($reportContent -match "(?ms)##\s*3\.[^#]+?($id)[^#]*?(FINDING|WARN|FAIL|CRITICAL|\u6B20\u9665|\u6307\u6458)") {
            $qwenVerdict = "FINDINGS (P1)"
        }

        # Check Codex findings section dynamically
        if ($reportContent -match "(?ms)##\s*4\.[^#]+?($id)[^#]*?(FINDING|WARN|FAIL|CRITICAL|\u6B20\u9665|\u6307\u6458)") {
            $codexVerdict = "FINDINGS"
        }

        # Check Claude findings section dynamically
        if ($reportContent -match "(?ms)##\s*5\.[^#]+?($id)[^#]*?(FINDING|WARN|FAIL|CRITICAL|\u6B20\u9665|\u6307\u6458)") {
            $claudeVerdict = "FINDINGS (Critical)"
        }
    }

    $finalVerdict = "**PASS**"
    if ($linterVerdict -ne "PASS" -or $qwenVerdict -like "FINDINGS*" -or $codexVerdict -like "FINDINGS*" -or $claudeVerdict -like "FINDINGS*") {
        $finalVerdict = "**REVISE_PENDING**"
    }

    $matrixRows += "| $id | $title | $linterVerdict | $qwenVerdict | $codexVerdict | $claudeVerdict | $finalVerdict |"
}

<# Step 4. Render pipeline_metrics.md via UTF-8 Template #>
$templatePath = Join-Path $projectRoot "tools\templates\pipeline_metrics_template.md"
if (-not (Test-Path $templatePath)) {
    Write-Error "Metrics template file not found: $templatePath"
    exit 1
}

$today = (Get-Date).ToString("yyyy-MM-dd")
$matrixTableText = $matrixRows -join "`n"

$templateContent = [System.IO.File]::ReadAllText($templatePath, [System.Text.Encoding]::UTF8)
$renderedMetrics = $templateContent.Replace("{{TODAY}}", $today)
$renderedMetrics = $renderedMetrics.Replace("{{TOTAL_REQ_COUNT}}", $totalReqCount.ToString())
$renderedMetrics = $renderedMetrics.Replace("{{LAST_STATUS}}", $lastStatus)
$renderedMetrics = $renderedMetrics.Replace("{{LAST_BATCH_ID}}", $lastBatchId)
$renderedMetrics = $renderedMetrics.Replace("{{LAST_NOTES}}", $lastNotes)
$renderedMetrics = $renderedMetrics.Replace("{{MATRIX_TABLE}}", $matrixTableText)
$renderedMetrics = $renderedMetrics.Replace("../../logs/", "")

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($metricsPath, $renderedMetrics, $utf8NoBom)
Write-Host "  -> Successfully re-rendered: $MetricsFile (All $totalReqCount requirements synchronized via template)" -ForegroundColor Green

<# Step 5. Synchronize CURRENT_STATUS.md #>
if (Test-Path $statusPath) {
    $statusContent = [System.IO.File]::ReadAllText($statusPath, [System.Text.Encoding]::UTF8)
    $jaHealthLabel = [System.Text.Encoding]::UTF8.GetString(@(0xE6, 0x9C, 0x80, 0xE6, 0x96, 0xB0, 0xE3, 0x83, 0x98, 0xE3, 0x83, 0xAB, 0xE3, 0x82, 0xB9, 0xE3, 0x83, 0x81, 0xE3, 0x82, 0xA7, 0xE3, 0x83, 0x83, 0xE3, 0x82, 0xAF, 0xE5, 0x88, 0xA4, 0xE5, 0xAE, 0x9A))
    $newHealth = "- **$jaHealthLabel**: ``$lastStatus`` (enterprise_audit_ledger.csv ${lastBatchId}: $lastNotes)"
    $pattern = "(?m)^- \*\*" + [regex]::Escape($jaHealthLabel) + "\*\*:.+$"
    if ($statusContent -match $pattern) {
        $statusUpdated = [System.Text.RegularExpressions.Regex]::Replace($statusContent, $pattern, $newHealth)
    } else {
        $statusUpdated = $statusContent
    }
    [System.IO.File]::WriteAllText($statusPath, $statusUpdated, $utf8NoBom)
    Write-Host "  -> Successfully synchronized: $StatusFile" -ForegroundColor Green
}

<# Step 6. Automatically Synchronize Local Developer Korean Mirrors (*_KO.md) #>
$koMetricsPath = Join-Path $projectRoot "logs\pipeline_metrics_KO.md"
$koTemplatePath = Join-Path $projectRoot "tools\templates\pipeline_metrics_template_KO.md"
if (Test-Path $koTemplatePath) {
    $koTemplateContent = [System.IO.File]::ReadAllText($koTemplatePath, [System.Text.Encoding]::UTF8)
    $renderedKoMetrics = $koTemplateContent.Replace("{{TODAY}}", $today)
    $renderedKoMetrics = $renderedKoMetrics.Replace("{{TOTAL_REQ_COUNT}}", $totalReqCount.ToString())
    $renderedKoMetrics = $renderedKoMetrics.Replace("{{LAST_STATUS}}", $lastStatus)
    $renderedKoMetrics = $renderedKoMetrics.Replace("{{LAST_BATCH_ID}}", $lastBatchId)
    $renderedKoMetrics = $renderedKoMetrics.Replace("{{LAST_NOTES}}", $lastNotes)
    $renderedKoMetrics = $renderedKoMetrics.Replace("{{MATRIX_TABLE}}", $matrixTableText)
    [System.IO.File]::WriteAllText($koMetricsPath, $renderedKoMetrics, $utf8NoBom)
    Write-Host "  -> Successfully synchronized Korean mirror: logs\pipeline_metrics_KO.md" -ForegroundColor Cyan
}

$koStatusPath = Join-Path $projectRoot "logs\CURRENT_STATUS_KO.md"
if (Test-Path $koStatusPath) {
    $koStatusContent = [System.IO.File]::ReadAllText($koStatusPath, [System.Text.Encoding]::UTF8)
    $koHealthLabel = [System.Text.Encoding]::UTF8.GetString(@(0xEC, 0xB5, 0x9C, 0xEC, 0x8B, 0xA0, 0x20, 0xED, 0x97, 0xAC, 0xEC, 0x8A, 0xA4, 0xEC, 0xB2, 0xB4, 0xED, 0x81, 0xAC, 0x20, 0xED, 0x8C, 0x90, 0xEC, 0xA0, 0x95))
    $koHealthLine = "- **$koHealthLabel**: ``$lastStatus`` (enterprise_audit_ledger.csv ${lastBatchId}: $lastNotes)"
    $koPattern = "(?m)^- \*\*" + [regex]::Escape($koHealthLabel) + "\*\*:.+$"
    if ($koStatusContent -match $koPattern) {
        $koStatusUpdated = [System.Text.RegularExpressions.Regex]::Replace($koStatusContent, $koPattern, $koHealthLine)
    } else {
        $koStatusUpdated = $koStatusContent
    }
    [System.IO.File]::WriteAllText($koStatusPath, $koStatusUpdated, $utf8NoBom)
    Write-Host "  -> Successfully synchronized Korean mirror: logs\CURRENT_STATUS_KO.md" -ForegroundColor Cyan
}

if ($linterVerdict -eq "FAIL") {
    Write-Host "[SYNC FATAL] Linter verification failed during dashboard sync. Aborting Fail-Closed." -ForegroundColor Red
    exit 1
}

Write-Host ">>> [SYNC COMPLETE] All dashboards & Korean mirrors 100% aligned with SSOT ($totalReqCount requirements)." -ForegroundColor Green
exit 0
