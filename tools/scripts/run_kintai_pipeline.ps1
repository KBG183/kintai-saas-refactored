<#
.SYNOPSIS
    KINTAI Project 3 Dedicated 5-Tier Unified Multi-AI Verification Pipeline (run_kintai_pipeline.ps1)
.DESCRIPTION
    Executes all 5 verification stages adhering strictly to GEMINI.md Art. 1 and AGENTS.md:
    - Stage 1: Deterministic Gate (compileJava + gradlew test + Zero-Korean scan)
    - Stage 2: Anthropic Claude (Labor Standards Act Art. 37 Deep Reasoning)
    - Stage 3: OpenAI Codex (Spring Boot 4 / MyBatis / Concurrency Locking Architecture)
    - Stage 4: Local Qwen 27B (State Machine Invariants & Local Regression via RTX 5070 Ti)
    - Stage 5: Unified Audit Dossier & Master Receipt Generation in audit/runs/
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet("ALL", "PAYROLL", "SHIFT", "ATTENDANCE")]
    [string]$Domain = "ALL",

    [Parameter(Mandatory = $false)]
    [switch]$SkipAI = $false,

    [Parameter(Mandatory = $false)]
    [switch]$SkipClaude = $false,

    [Parameter(Mandatory = $false)]
    [switch]$SkipCodex = $false,

    [Parameter(Mandatory = $false)]
    [switch]$SkipQwen = $false,

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 180
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
if (-not (Test-Path $projectRoot)) { $projectRoot = (Get-Location).Path }

$timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$runGuid = [guid]::NewGuid().ToString().Substring(0, 8)
$runMasterDir = Join-Path $projectRoot "audit\runs\${timestamp}_kintai_master_${runGuid}"
if (-not (Test-Path $runMasterDir)) { New-Item -ItemType Directory -Path $runMasterDir -Force | Out-Null }

Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host " [KINTAI 5-TIER PIPELINE] Project 3 Unified Multi-AI Cross-Verification" -ForegroundColor Cyan
Write-Host " Target Domain : $Domain" -ForegroundColor Cyan
Write-Host " Output Master : $runMasterDir" -ForegroundColor Cyan
Write-Host " Timestamp     : $timestamp" -ForegroundColor Cyan
Write-Host "==========================================================================" -ForegroundColor Cyan

$pipelineResults = [ordered]@{}

# -----------------------------------------------------------------------------
# STAGE 1: Deterministic Fail-Fast Gate (Compile + Tests + Zero-Korean)
# -----------------------------------------------------------------------------
Write-Host "`n>>> [Stage 1/5] Running Deterministic Machine Gates (Compile + Test + Zero-Korean)..." -ForegroundColor Yellow
$stage1Start = Get-Date

try {
    # 1.1 Compile check
    Write-Host "  -> Running ./gradlew compileJava..." -ForegroundColor Gray
    $compileOut = & cmd.exe /c "gradlew.bat compileJava --quiet" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "COMPILE_FAIL: ./gradlew compileJava failed with code $LASTEXITCODE`n$compileOut"
    }

    # 1.2 Zero-Korean scan
    Write-Host "  -> Running Zero-Korean Unicode regex scan on tracked sources..." -ForegroundColor Gray
    $koreanRegex = "[\uAC00-\uD7A3]"
    $targetFiles = Get-ChildItem -Path (Join-Path $projectRoot "src") -Recurse -Include "*.java", "*.xml", "*.sql", "*.html"
    $koreanViolations = @()
    foreach ($file in $targetFiles) {
        $lines = [System.IO.File]::ReadAllLines($file.FullName, [System.Text.Encoding]::UTF8)
        for ($i = 0; $i -lt $lines.Length; $i++) {
            if ($lines[$i] -match $koreanRegex) {
                $koreanViolations += "$($file.Name):line $($i + 1): $($lines[$i].Trim())"
            }
        }
    }
    if ($koreanViolations.Count -gt 0) {
        throw "ZERO_KOREAN_FAIL: Found $($koreanViolations.Count) Korean characters in source code:`n" + ($koreanViolations -join "`n")
    }

    # 1.3 Gradle Unit Tests
    Write-Host "  -> Running ./gradlew test..." -ForegroundColor Gray
    $testOut = & cmd.exe /c "gradlew.bat test --quiet" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "TEST_FAIL: ./gradlew test failed with code $LASTEXITCODE`n$testOut"
    }

    $stage1Duration = [Math]::Round(((Get-Date) - $stage1Start).TotalSeconds, 2)
    Write-Host "  [PASS] Stage 1 Passed cleanly in ${stage1Duration}s (Zero-Cost Fail-Fast)" -ForegroundColor Green
    $pipelineResults["Stage 1: Deterministic Gate"] = "PASS (${stage1Duration}s)"
} catch {
    Write-Host "  [FAIL] Stage 1 Failed: $($_.Exception.Message)" -ForegroundColor Red
    $pipelineResults["Stage 1: Deterministic Gate"] = "FAIL"
    exit 1
}

if ($SkipAI) {
    Write-Host "`n[NOTICE] SkipAI flag specified. Pipeline terminating at Stage 1." -ForegroundColor Yellow
    exit 0
}

# -----------------------------------------------------------------------------
# Context Bundle Preparation
# -----------------------------------------------------------------------------
$bundleFile = Join-Path $runMasterDir "context_bundle.txt"
$calcSrc = Join-Path $projectRoot "src/main/java/com/example/kintai/domain/payroll/util/PayrollCalculator.java"
$paySrc = Join-Path $projectRoot "src/main/java/com/example/kintai/domain/payroll/service/PayrollService.java"
$shiftSrc = Join-Path $projectRoot "src/main/java/com/example/kintai/domain/shift/service/ShiftService.java"
$attendSrc = Join-Path $projectRoot "src/main/java/com/example/kintai/domain/attendance/service/AttendanceService.java"

$bundleText = "=== [BUNDLE: PayrollCalculator.java] ===`n" + [System.IO.File]::ReadAllText($calcSrc, [System.Text.Encoding]::UTF8) +
              "`n`n=== [BUNDLE: PayrollService.java] ===`n" + [System.IO.File]::ReadAllText($paySrc, [System.Text.Encoding]::UTF8) +
              "`n`n=== [BUNDLE: ShiftService.java] ===`n" + [System.IO.File]::ReadAllText($shiftSrc, [System.Text.Encoding]::UTF8) +
              "`n`n=== [BUNDLE: AttendanceService.java] ===`n" + [System.IO.File]::ReadAllText($attendSrc, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($bundleFile, $bundleText, [System.Text.Encoding]::UTF8)

# -----------------------------------------------------------------------------
# STAGE 2: Anthropic Claude (Labor Standards Act Art. 37 Deep Reasoning)
# -----------------------------------------------------------------------------
if (-not $SkipClaude) {
    Write-Host "`n>>> [Stage 2/5] Running Anthropic Claude (Labor Law Art. 37 Reasoning)..." -ForegroundColor Yellow
    $stage2Start = Get-Date
    $claudePromptFile = Join-Path $runMasterDir "claude_prompt.txt"
    $claudePrompt = @"
以下の日本の労働基準法第37条に基づく割増賃金計算エンジン（PayrollCalculator.java）および給与集計サービス（PayrollService.java）の実装について、法令遵守および計算精度の観点から厳格に監査してください。
主要点:
1. 割増率（深夜25%、時間外25%、深夜時間外50%、休日35%、休日深夜60%）の正確性
2. 深夜時間外（150%）の二重計上防止
3. 50銭四捨五入（RoundingMode.HALF_UP）の法令準拠
4. 確定給与の上書き防止および未解決勤怠ガード
出力形式:
Markdownの指摘表を出力し、最終行に必ず 'VERDICT: PASS' または 'VERDICT: FAIL' を出力してください。
"@
    [System.IO.File]::WriteAllText($claudePromptFile, $claudePrompt, [System.Text.Encoding]::UTF8)

    $callClaude = Join-Path $scriptDir "call_claude.ps1"
    try {
        & powershell -ExecutionPolicy Bypass -File $callClaude -PromptFile $claudePromptFile -ContextFile $bundleFile -TimeoutSeconds $TimeoutSeconds
        $stage2Duration = [Math]::Round(((Get-Date) - $stage2Start).TotalSeconds, 2)
        Write-Host "  [DONE] Stage 2 Claude Completed in ${stage2Duration}s (Artifact preserved in audit/runs/)" -ForegroundColor Green
        $pipelineResults["Stage 2: Anthropic Claude"] = "DONE (${stage2Duration}s)"
    } catch {
        Write-Host "  [WARN] Stage 2 Claude returned non-zero (Review findings in audit/runs/): $($_.Exception.Message)" -ForegroundColor Yellow
        $pipelineResults["Stage 2: Anthropic Claude"] = "REVIEW_REQUIRED"
    }
} else {
    $pipelineResults["Stage 2: Anthropic Claude"] = "SKIPPED"
}

# -----------------------------------------------------------------------------
# STAGE 3: OpenAI Codex (Architecture & Concurrency Locking)
# -----------------------------------------------------------------------------
if (-not $SkipCodex) {
    Write-Host "`n>>> [Stage 3/5] Running OpenAI Codex (Spring Boot 4 / MyBatis / Concurrency Locks)..." -ForegroundColor Yellow
    $stage3Start = Get-Date
    $codexPromptFile = Join-Path $runMasterDir "codex_prompt.txt"
    $codexPrompt = @"
以下のSpring Boot 4 / MyBatisバックエンドサービスにおける排他制御（悲観的ロック SELECT ... FOR UPDATE）、トランザクション境界、および同時実行制御のアーキテクチャについて厳格に監査してください。
対象: ShiftService.java, PayrollService.java, AttendanceService.java
主要点:
1. シフト申請・確定における store_staff 単位の悲観的ロック直列化とデッドロック防止順序
2. 給与計算・確定における二重上書き防止ガード（DRAFT状態検証および更新行数チェック）
3. 未退勤ゴースト打刻に対する強制締めAPI（forceCloseAttendance）の階層型ロック保証
出力形式:
Markdownの指摘表を出力し、最終行に必ず 'VERDICT: PASS' または 'VERDICT: FAIL' を出力してください。
"@
    [System.IO.File]::WriteAllText($codexPromptFile, $codexPrompt, [System.Text.Encoding]::UTF8)

    $callCodex = Join-Path $scriptDir "call_codex.ps1"
    try {
        & powershell -ExecutionPolicy Bypass -File $callCodex -PromptFile $codexPromptFile -ContextFile $bundleFile -TimeoutSeconds $TimeoutSeconds
        $stage3Duration = [Math]::Round(((Get-Date) - $stage3Start).TotalSeconds, 2)
        Write-Host "  [DONE] Stage 3 Codex Completed in ${stage3Duration}s (Artifact preserved in audit/runs/)" -ForegroundColor Green
        $pipelineResults["Stage 3: OpenAI Codex"] = "DONE (${stage3Duration}s)"
    } catch {
        Write-Host "  [WARN] Stage 3 Codex returned non-zero (Review findings in audit/runs/): $($_.Exception.Message)" -ForegroundColor Yellow
        $pipelineResults["Stage 3: OpenAI Codex"] = "REVIEW_REQUIRED"
    }
} else {
    $pipelineResults["Stage 3: OpenAI Codex"] = "SKIPPED"
}

# -----------------------------------------------------------------------------
# STAGE 4: Local Qwen 27B (State Machine & Local Invariants)
# -----------------------------------------------------------------------------
if (-not $SkipQwen) {
    Write-Host "`n>>> [Stage 4/5] Running Local Qwen 27B (RTX 5070 Ti Remote Acceleration)..." -ForegroundColor Yellow
    $stage4Start = Get-Date
    $qwenOutFile = Join-Path $runMasterDir "qwen_audit_report.md"
    $auditScript = Join-Path $env:USERPROFILE ".gemini\scripts\audit_with_hermes.ps1"
    if (-not (Test-Path $auditScript)) {
        $auditScript = "C:\Users\klad3\.gemini\scripts\audit_with_hermes.ps1"
    }

    if (Test-Path $auditScript) {
        try {
            & powershell -ExecutionPolicy Bypass -File $auditScript -TargetFile $calcSrc -OutputFile $qwenOutFile
            $stage4Duration = [Math]::Round(((Get-Date) - $stage4Start).TotalSeconds, 2)
            Write-Host "  [DONE] Stage 4 Local Qwen 27B Completed in ${stage4Duration}s" -ForegroundColor Green
            $pipelineResults["Stage 4: Local Qwen 27B"] = "DONE (${stage4Duration}s)"
        } catch {
            Write-Host "  [WARN] Stage 4 Local Qwen returned non-zero: $($_.Exception.Message)" -ForegroundColor Yellow
            $pipelineResults["Stage 4: Local Qwen 27B"] = "REVIEW_REQUIRED"
        }
    } else {
        Write-Host "  [SKIP] Global audit_with_hermes.ps1 not found." -ForegroundColor Yellow
        $pipelineResults["Stage 4: Local Qwen 27B"] = "NOT_FOUND"
    }
} else {
    $pipelineResults["Stage 4: Local Qwen 27B"] = "SKIPPED"
}

# -----------------------------------------------------------------------------
# STAGE 5: Master Dossier & Unified Summary Table
# -----------------------------------------------------------------------------
Write-Host "`n==========================================================================" -ForegroundColor Cyan
Write-Host " [KINTAI 5-TIER PIPELINE] Execution Summary Dashboard" -ForegroundColor Cyan
Write-Host "==========================================================================" -ForegroundColor Cyan

$summaryReport = [ordered]@{
    timestamp = $timestamp
    domain    = $Domain
    stages    = $pipelineResults
    receipt   = $runMasterDir
}
$summaryJson = $summaryReport | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText((Join-Path $runMasterDir "master_summary.json"), $summaryJson, [System.Text.Encoding]::UTF8)

$pipelineResults.GetEnumerator() | ForEach-Object {
    $color = if ($_.Value -match "PASS|DONE") { "Green" } else { "Yellow" }
    Write-Host (" {0,-35} : {1}" -f $_.Key, $_.Value) -ForegroundColor $color
}
Write-Host "--------------------------------------------------------------------------" -ForegroundColor Gray
Write-Host " Master Receipt Directory: $runMasterDir" -ForegroundColor Cyan
Write-Host "==========================================================================" -ForegroundColor Cyan
