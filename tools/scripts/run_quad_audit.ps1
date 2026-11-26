<#
.SYNOPSIS
    KINTAI 5-Tier Multi-Audit Master Orchestrator (Fail-Fast & Role-Swap Runner)
.DESCRIPTION
    Runs integrated multi-AI hybrid audit strictly adhering to GEMINI.md Art 1:
    - Stage 1: Deterministic Linter Gate (VerifySRS.exe) [Fail-Fast 0-cost cutoff]
    - Stage 2: Track-aware Auditor (Fast: Codex / Heavy: Antigravity 1st-Auditor)
    - Stage 3: Anthropic Claude (claude-sonnet-5-5) [Labor Law Art 34/37 Deep Reasoning]
    - Stage 4: Local Qwen 27B (qwen3.8:27b via RTX 5070 Ti) [State Machine & Regression]
    - Stage 5: Master 12-Gate Total Integrity Verifier (verify_repo_total_integrity.ps1)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TargetFile = "config/srs_specification_ssot.md",

    [Parameter(Mandatory = $false)]
    [ValidateSet("HEAVY", "FAST")]
    [string]$Track = "HEAVY",

    [Parameter(Mandatory = $false)]
    [string]$LineRange = "",

    [Parameter(Mandatory = $false)]
    [string]$CustomPrompt = "",

    [Parameter(Mandatory = $false)]
    [ValidateSet("RELAY", "PARALLEL")]
    [string]$Mode = "RELAY",

    [Parameter(Mandatory = $false)]
    [switch]$SkipLinter,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCodex,

    [Parameter(Mandatory = $false)]
    [switch]$SkipClaude,

    [Parameter(Mandatory = $false)]
    [switch]$SkipQwen
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
if (-not (Test-Path $projectRoot)) { $projectRoot = (Get-Location).Path }

$timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$runMasterDir = Join-Path $projectRoot "audit\runs\${timestamp}_quad_master_run"
if (-not (Test-Path $runMasterDir)) { New-Item -ItemType Directory -Path $runMasterDir -Force | Out-Null }

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " [5-TIER AUDITOR] Starting $Mode Multi-AI Cross-Verification Pipeline" -ForegroundColor Cyan
Write-Host " Target: $TargetFile $(if ($LineRange) { "(Lines $LineRange)" })" -ForegroundColor Cyan
Write-Host " Track : $Track (Role-Swap Protocol Enforced)" -ForegroundColor Cyan
Write-Host " Output: $runMasterDir" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

$auditSummary = [ordered]@{
    timestamp = $timestamp
    target = $TargetFile
    track = $Track
    line_range = $LineRange
    mode = $Mode
    stages = @()
}

$targetResolved = Join-Path $projectRoot $TargetFile
if (-not (Test-Path $targetResolved)) {
    Write-Error "[FATAL] Target file not found: $targetResolved"
    exit 1
}

# -------------------------------------------------------------------------
# Stage 1: Deterministic Linter Fail-Fast Gate (VerifySRS.exe)
# -------------------------------------------------------------------------
if (-not $SkipLinter) {
    Write-Host "`n>>> [Stage 1/5] Running Deterministic Linter Fail-Fast Gate (VerifySRS.exe)..." -ForegroundColor Yellow
    $linterBin = Join-Path $scriptDir "VerifySRS.exe"
    $linterWrapper = Join-Path $scriptDir "verify_srs.ps1"
    
    if (-not (Test-Path $linterBin)) {
        Write-Host "  -> Compiling VerifySRS.exe via verify_srs.ps1..."
        & powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $linterWrapper -Files @() 2>&1 | Out-Null
    }
    
    if (-not (Test-Path $linterBin)) {
        Write-Error "[FAIL-CLOSED] VerifySRS.exe binary unavailable. Aborting."
        exit 4
    }
    
    $swLint = [System.Diagnostics.Stopwatch]::StartNew()
    $lintOutput = & $linterBin $targetResolved
    $linterExit = $LASTEXITCODE
    $swLint.Stop()
    
    $lintReportPath = Join-Path $runMasterDir "01_linter_report.txt"
    $lintOutput | Out-File -FilePath $lintReportPath -Encoding UTF8
    
    $fatalMatches = @($lintOutput | Select-String -Pattern '\[FATAL\]')
    if ($linterExit -ne 0 -or $fatalMatches.Count -gt 0) {
        Write-Host "  -> [FATAL ERROR DETECTED] Stage 1 Linter rejected target file!" -ForegroundColor Red
        $lintOutput | Select-Object -First 10 | ForEach-Object { Write-Host "     $_" -ForegroundColor Red }
        Write-Error "[FAIL-FAST ABORT] Deterministic linting failed ($($fatalMatches.Count) FATALs). Terminating pipeline before calling LLMs to prevent token waste."
        exit 1
    }
    
    Write-Host "  -> Deterministic Linter Gate PASSED in $($swLint.Elapsed.TotalSeconds.ToString('F2'))s (0 FATAL errors)." -ForegroundColor Green
    $auditSummary.stages += [ordered]@{
        stage = 1
        auditor = "VerifySRS.exe (Roslyn Deterministic Linter)"
        verdict = "PASS"
        duration_s = [math]::Round($swLint.Elapsed.TotalSeconds, 2)
        artifact = $lintReportPath
    }
}

# -------------------------------------------------------------------------
# Stage 2: Track-Aware Auditor Execution (Role-Swap)
# -------------------------------------------------------------------------
if ($Track -eq "FAST") {
    if (-not $SkipCodex) {
        Write-Host "`n>>> [Stage 2/5] Running OpenAI Codex Cross-Auditor (gpt-6.2-astra)..." -ForegroundColor Yellow
        $callCodex = Join-Path $scriptDir "call_codex.ps1"
        $codexPrompt = if ($CustomPrompt) { $CustomPrompt } else { "Perform strict adversarial audit on target requirements focusing on concurrency, DDL integrity, and Japanese labor law." }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & powershell -ExecutionPolicy Bypass -File $callCodex -Prompt $codexPrompt -ContextFile $targetResolved -Model "gpt-6.2-astra"
        $sw.Stop()
        
        $codexMsg = Join-Path $projectRoot "scratch\test_runs\codex_last_msg.txt"
        $destReport = Join-Path $runMasterDir "02_codex_report.txt"
        if (Test-Path $codexMsg) { Copy-Item $codexMsg $destReport -Force }
        $auditSummary.stages += [ordered]@{
            stage = 2
            auditor = "OpenAI Codex (gpt-6.2-astra)"
            role = "Independent Cross-Auditor"
            duration_s = [math]::Round($sw.Elapsed.TotalSeconds, 2)
            artifact = $destReport
        }
        Write-Host "  -> Codex cross-audit completed in $($sw.Elapsed.TotalSeconds.ToString('F2'))s." -ForegroundColor Green
    }
} else {
    Write-Host "`n>>> [Stage 2/5] Role-Swap Active: Antigravity designated as First Auditor (Direct CLI audit skipped)..." -ForegroundColor Yellow
    $destReport = Join-Path $runMasterDir "02_antigravity_first_audit.txt"
    $antiLog = "Antigravity First-Auditor: Direct CLI execution skipped. Orchestrator operates as supervisory controller; independent external CLI audit not executed in this stage."
    [System.IO.File]::WriteAllText($destReport, $antiLog, [System.Text.Encoding]::UTF8)
    $auditSummary.stages += [ordered]@{
        stage = 2
        auditor = "Antigravity (Gemini)"
        role = "First Auditor (Supervisory Orchestrator)"
        verdict = "SKIPPED"
        reason = "Direct external CLI audit skipped under Heavy Track role-swap; supervisory orchestrator verification only."
        artifact = $destReport
    }
    Write-Host "  -> Stage 2 marked as SKIPPED (Supervisory orchestrator role-swap; no standalone CLI audit executed)." -ForegroundColor Yellow
}

# -------------------------------------------------------------------------
# Stage 3: Anthropic Claude Cross-Audit
# -------------------------------------------------------------------------
if (-not $SkipClaude) {
    Write-Host "`n>>> [Stage 3/5] Running Anthropic Claude (claude-sonnet-5-5)..." -ForegroundColor Yellow
    $callClaude = Join-Path $scriptDir "call_claude.ps1"
    if (Test-Path $callClaude) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $defaultClaudePrompt = @"
Perform an adversarial domain & statutory audit on the target specification.
Check Japanese Labor Standards Act Article 37, split shift aggregation, concurrency locks, and boundary edge cases.
OUTPUT CONSTRAINT: Keep response strictly compact and structured.
1. Markdown table of findings (| Finding ID | Severity | Item | Flaw Analysis | Concrete Code/Rule Fix |)
2. Final Verdict: 'VERDICT: PASS' or 'VERDICT: FAIL' (with reasons).
Do not output verbose discursive essays. Maximum length 3000 tokens.
"@
        $claudePrompt = if ($CustomPrompt) { $CustomPrompt } else { $defaultClaudePrompt }
        & powershell -ExecutionPolicy Bypass -File $callClaude -Prompt $claudePrompt -ContextFile $targetResolved
        $sw.Stop()
        Write-Host "  -> Claude stage completed in $($sw.Elapsed.TotalSeconds.ToString('F2'))s." -ForegroundColor Green
        $destReport = Join-Path $runMasterDir "03_claude_report.txt"
        $claudeMsg = Join-Path $projectRoot "scratch\test_runs\claude_last_msg.txt"
        if (Test-Path $claudeMsg) { Copy-Item $claudeMsg $destReport -Force }
        $auditSummary.stages += [ordered]@{
            stage = 3
            auditor = "Anthropic Claude (claude-sonnet-5-5)"
            role = "Labor Law & Algebraic Deduction Auditor"
            duration_s = [math]::Round($sw.Elapsed.TotalSeconds, 2)
            artifact = $destReport
        }
    } else {
        Write-Host "  -> Claude script not found, skipping." -ForegroundColor DarkGray
    }
}

# -------------------------------------------------------------------------
# Stage 4: Local Qwen 27B Audit
# -------------------------------------------------------------------------
if (-not $SkipQwen) {
    Write-Host "`n>>> [Stage 4/5] Running Local Qwen 27B (RTX 5070 Ti Remote)..." -ForegroundColor Yellow
    $hermesScript = Join-Path $env:USERPROFILE ".gemini\scripts\audit_with_hermes.ps1"
    if (Test-Path $hermesScript) {
        $qwenOut = Join-Path $runMasterDir "04_qwen_report.md"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $qwenArgs = @("-TargetFile", $targetResolved, "-OutputFile", $qwenOut, "-Model", "qwen3.8:27b", "-AuditMode", "STANDARD")
        if ($LineRange) { $qwenArgs += @("-LineRange", $LineRange) }
        & powershell -ExecutionPolicy Bypass -File $hermesScript @qwenArgs
        $sw.Stop()
        Write-Host "  -> Qwen stage completed in $($sw.Elapsed.TotalSeconds.ToString('F2'))s." -ForegroundColor Green
        $auditSummary.stages += [ordered]@{
            stage = 4
            auditor = "Local Qwen 27B (qwen3.8:27b)"
            role = "State Machine & Regression Auditor"
            duration_s = [math]::Round($sw.Elapsed.TotalSeconds, 2)
            artifact = $qwenOut
        }
    }
}

# -------------------------------------------------------------------------
# Stage 5: Master Repository Total Integrity Verifier
# -------------------------------------------------------------------------
Write-Host "`n>>> [Stage 5/5] Running Master Total Integrity Verifier..." -ForegroundColor Yellow
$masterLinter = Join-Path $scriptDir "verify_repo_total_integrity.ps1"
& powershell -ExecutionPolicy Bypass -File $masterLinter
$linterExit = $LASTEXITCODE

if ($linterExit -ne 0) {
    Write-Host "`n[FATAL] Stage 5 Master Verifier failed with exit code $linterExit!" -ForegroundColor Red
    exit $linterExit
}

$doneMarker = Join-Path $runMasterDir ".done"
if (Test-Path $doneMarker) { Remove-Item $doneMarker -Force }

$gitSha = try { (git rev-parse HEAD).Trim() } catch { "UNKNOWN" }
$doneMeta = [ordered]@{
    timestamp = $timestamp
    target = $TargetFile
    track = $Track
    git_sha = $gitSha
    mode = $Mode
    stages = $auditSummary.stages
    linter_exit = $linterExit
} | ConvertTo-Json -Depth 5

[System.IO.File]::WriteAllText($doneMarker, $doneMeta, [System.Text.Encoding]::UTF8)
Write-Host "`n=== [5-TIER MULTI-AUDIT PIPELINE COMPLETED] ===" -ForegroundColor Green
Write-Host "All audit artifacts firmly archived in: $runMasterDir"
