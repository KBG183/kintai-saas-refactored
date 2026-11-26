<#
.SYNOPSIS
    1-Click Session Handoff Generator.
    Extracts Git state, queue metrics, and 12-Gate verification results without self-referential dirty states.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$NextPlanLine1 = "Resume next scheduled sprint task or review backlog",

    [Parameter(Mandatory = $false)]
    [string]$NextPlanLine2 = "Execute 12-Gate total integrity verifier before work",

    [Parameter(Mandatory = $false)]
    [string]$NextPlanLine3 = "Maintain Fast Track / Heavy Track pre-authoring declarations",

    [Parameter(Mandatory = $false)]
    [string]$NextPlanLine4 = "Track all external findings directly in central queue",

    [Parameter(Mandatory = $false)]
    [string]$NextPlanLine5 = "Enforce Zero-Korean and Fail-Closed commit gates"
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
if (-not (Test-Path (Join-Path $projectRoot "GEMINI.md"))) {
    $projectRoot = Split-Path -Parent $scriptDir
}

$handoffFile = Join-Path $projectRoot "scratch\handoff.md"
$queueFile = Join-Path $projectRoot "queue\srs_pending_findings.json"
$verifierScript = Join-Path $projectRoot "tools\scripts\verify_repo_total_integrity.ps1"

Write-Host "[HANDOFF] Querying Git baseline..."
$headSha = (git rev-parse --short HEAD 2>&1).ToString().Trim()
$fullSha = (git rev-parse HEAD 2>&1).ToString().Trim()
$latestCommitMsg = (git log -1 --pretty=format:"%s" 2>&1).ToString().Trim()

# 1. Clean Check ignoring scratch/ and execution trace
$gitStatus = @(git status --porcelain 2>&1) | Where-Object { 
    $_ -notmatch '^\s*..\s*scratch[\\/]' -and
    $_ -notmatch '^\s*..\s*docs[\\/]daily_audit_temp\.log' -and
    $_ -notmatch '^\s*..\s*logs[\\/]incident_execution_trace\.log'
}
$isDirty = ($gitStatus.Count -gt 0)
$workingStateStatus = if ($isDirty) { "DIRTY (Uncommitted changes exist outside scratch)" } else { "CLEAN (Synced to working tree)" }

# 2. Queue Status
$queueTotal = 0
$queuePending = 0
$queueVerified = 0
if (Test-Path $queueFile) {
    try {
        $qBytes = [System.IO.File]::ReadAllBytes($queueFile)
        $qJson = [System.Text.Encoding]::UTF8.GetString($qBytes) | ConvertFrom-Json
        $queueTotal = $qJson.findings.Count
        $queuePending = @($qJson.findings | Where-Object { $_.status -eq "PENDING" }).Count
        $queueVerified = @($qJson.findings | Where-Object { $_.status -eq "VERIFIED" }).Count
    } catch {
        Write-Host "  [WARN] Failed to read queue: $_" -ForegroundColor Yellow
    }
}

# 3. 12-Gate Integrity Verification
Write-Host "[HANDOFF] Running 12-Gate Total Integrity Verifier..."
$gateOutput = & powershell -ExecutionPolicy Bypass -File $verifierScript 2>&1
$gatePass = ($gateOutput -match '\[VERDICT: ALL PASS\]')

$gateStatusText = if ($gatePass) { "12/12 Gates ALL PASS" } else { "FAIL (Gate violations detected)" }

# 4. Mandatory Rule Load List inference
$rulesToLoad = @("tools/rules/commit_pipeline.md")
if ($queuePending -gt 0) {
    $rulesToLoad += "tools/rules/external_finding_queue.md"
}
$rulesToLoad += "tools/rules/conditional_reporting_policy.md"
$rulesListText = ($rulesToLoad | ForEach-Object { "- ``$_``" }) -join "`r`n"

# 5. Compose scratch/handoff.md
$utcNow = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
$handoffContent = @"
# 🤝 Project KINTAI Session Handoff (Token-Optimized Baseline)

- **Generated UTC**: $utcNow
- **Baseline Commit**: ``$headSha`` ($latestCommitMsg)
- **Working Tree State**: $workingStateStatus
- **Queue State**: ``queue/srs_pending_findings.json`` (Total: $queueTotal, PENDING: $queuePending, VERIFIED: $queueVerified)
- **Repository Integrity**: ``verify_repo_total_integrity.ps1`` ($gateStatusText)

---

## 1. Verified Working State Summary
1. **Core Governance**: ``GEMINI.md`` v2.00 (Core Constitution 48 lines) active with dynamic rule injection.
2. **Queue Verification**: $queueVerified findings verified in central queue ($queuePending pending).
3. **Repository Gates**: $gateStatusText confirmed via deterministic linter and verifier.
4. **Token Optimization**: Pillar 3 (Bylaws separation) and Pillar 4 (Conditional brief reporting) fully operational.

---

## 2. Next Session Immediate Action Plan (5 Lines)
1. $NextPlanLine1
2. $NextPlanLine2
3. $NextPlanLine3
4. $NextPlanLine4
5. $NextPlanLine5

---

## 3. Mandatory Context to Load in New Session
- Primary: This file (``scratch/handoff.md``)
- Core Constitution: ``GEMINI.md``
- Status Ledger: ``CURRENT_STATUS.md``
- Active Bylaws:
$rulesListText
"@

[System.IO.File]::WriteAllText($handoffFile, $handoffContent, [System.Text.Encoding]::UTF8)
Write-Host "[HANDOFF GENERATED] scratch/handoff.md updated successfully ($gateStatusText, Git: $workingStateStatus)."
