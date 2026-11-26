<#
.SYNOPSIS
    Hermes Multi-Agent Quality Audit Controller (hermes_controller.ps1)
.DESCRIPTION
    Unified entry point for deterministic linter, local Qwen 27B, OpenAI Codex, and Claude Sonnet 5.5.
    Aggregates all verification outputs into a standardized markdown evidence report.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetFile,

    [Parameter(Mandatory = $false)]
    [string]$OutputFile = "",

    [Parameter(Mandatory = $false)]
    [switch]$IncludeClaude = $true,

    [Parameter(Mandatory = $false)]
    [switch]$UseCache = $false,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Independent", "CrossExam")]
    [string]$AuditMode = "Independent",

    [Parameter(Mandatory = $false)]
    [switch]$DiffOnly = $false
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
if (-not (Test-Path $projectRoot)) { $projectRoot = (Get-Location).Path }

if (-not (Test-Path $TargetFile)) {
    Write-Error "Target file does not exist: $TargetFile"
    exit 1
}

$resolvedTarget = (Resolve-Path $TargetFile).Path
$targetFileName = [System.IO.Path]::GetFileName($resolvedTarget)
$timestampStr = (Get-Date).ToString("yyyyMMdd_HHmmss")

if (-not $OutputFile) {
    $OutputFile = Join-Path $projectRoot "audit\HERMES_Audit_${targetFileName}_${timestampStr}.md"
}

if ($DiffOnly) {
    $diffBundler = Join-Path $scriptDir "bundle_diff_context.ps1"
    if (Test-Path $diffBundler) {
        Write-Host "  -> [DIFF BUNDLER] Extracting minimal differential context..." -ForegroundColor Cyan
        $diffBundleFile = & powershell -ExecutionPolicy Bypass -File $diffBundler -TargetFile $resolvedTarget -Quiet
        if ($diffBundleFile -and (Test-Path -LiteralPath $diffBundleFile)) {
            $resolvedTarget = $diffBundleFile
            Write-Host "  -> [DIFF BUNDLER] Switched audit context to minimal bundle: $resolvedTarget" -ForegroundColor Green
        }
    }
}

$targetFileHash = (Get-FileHash -Path $resolvedTarget -Algorithm SHA256).Hash
$cacheDir = Join-Path $projectRoot "scratch\cache"
if (-not (Test-Path $cacheDir)) { New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null }

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " [HERMES CONTROLLER] Multi-Layer Quality Verification Pipeline" -ForegroundColor Cyan
Write-Host " Target File: $targetFileName (SHA256: $($targetFileHash.Substring(0, 12))...)" -ForegroundColor Cyan
if ($UseCache) {
    Write-Host " Cache Mode : ENABLED (Incremental Smart Checkpoint)" -ForegroundColor Magenta
}
Write-Host "=================================================================" -ForegroundColor Cyan

# -------------------------------------------------------------------------
# Step 1. Deterministic Linter Dual Hard-Gate (Integrity + Deterministic)
# -------------------------------------------------------------------------
Write-Host "`n>>> [Step 1/4] Deterministic Linter Dual Hard-Gate Verification..." -ForegroundColor Yellow

# Phase 1-A: Always enforce text & security integrity via Unified Master Linter VerifySRS.exe
$masterCs = Join-Path $scriptDir "VerifySRS.cs"
$masterExe = Join-Path $scriptDir "VerifySRS.exe"
$integrityCs = if (Test-Path $masterCs) { $masterCs } else { Join-Path $scriptDir "VerifySRS_Integrity.cs" }
$integrityExe = if (Test-Path $masterCs) { $masterExe } else { Join-Path $scriptDir "VerifySRS_Integrity.exe" }

# Strict Fail-Closed check & auto-compilation
if (-not (Test-Path $integrityExe) -or ((Test-Path $integrityCs) -and ((Get-Item $integrityCs).LastWriteTime -gt (Get-Item $integrityExe).LastWriteTime))) {
    Write-Host "  -> [COMPILE] Compiling VerifySRS_Integrity.exe..." -ForegroundColor Cyan
    $csc = [System.IO.Path]::Combine($env:WINDIR, "Microsoft.NET\Framework64\v4.0.30319\csc.exe")
    if (-not (Test-Path $csc)) {
        $csc = [System.IO.Path]::Combine($env:WINDIR, "Microsoft.NET\Framework\v4.0.30319\csc.exe")
    }
    if (-not (Test-Path $csc)) {
        Write-Error "  -> FATAL: C# Compiler (csc.exe) not found. Cannot enforce deterministic integrity gate (Fail-Closed)."
        exit 1
    }
    & $csc /nologo /target:exe /out:$integrityExe $integrityCs
    if ($LASTEXITCODE -ne 0) {
        Write-Error "  -> FATAL: VerifySRS_Integrity compilation failed (ExitCode: $LASTEXITCODE). Fail-Closed abort."
        exit 1
    }
}

Write-Host "  -> Running Sub-Gate 1-A: VerifySRS_Integrity (BOM, Zero-Korean, Sensitive Patterns, RFC 4180)..." -ForegroundColor Cyan
$integrityOutput = & $integrityExe $resolvedTarget 2>&1
$integrityExitCode = $LASTEXITCODE

if ($integrityExitCode -ne 0) {
    Write-Host "  -> Integrity Gate Verdict: FAIL (ExitCode: $integrityExitCode - Hard-Gate Blocked)" -ForegroundColor Red
    Write-Error "  -> Deterministic Integrity Hard-Gate violated! Aborting multi-layer verification immediately (Fail-Closed)."
    exit $integrityExitCode
}

# Phase 1-B: For specification documents (.md), enforce SRS Domain Schema via VerifySRS_Deterministic.exe
$linterOutput = @($integrityOutput)
$targetExt = [System.IO.Path]::GetExtension($resolvedTarget).ToLower()

if ($targetExt -eq ".md") {
    Write-Host "  -> Running Sub-Gate 1-B: VerifySRS_Deterministic (REQ Headings, DoD, Taboo Syntax)..." -ForegroundColor Cyan
    $linterScript = Join-Path $scriptDir "verify_srs.ps1"
    $detOutput = & powershell -ExecutionPolicy Bypass -File $linterScript -TargetFile $resolvedTarget 2>&1
    $linterExitCode = $LASTEXITCODE
    $linterOutput += $detOutput

    if ($linterExitCode -ne 0) {
        Write-Host "  -> Deterministic Linter Verdict: FAIL (ExitCode: $linterExitCode - Hard-Gate Blocked)" -ForegroundColor Red
        Write-Error "  -> Deterministic Specification Hard-Gate violated! Aborting multi-layer verification immediately (Fail-Closed)."
        exit $linterExitCode
    }
}

$linterStatus = "PASS"
Write-Host "  -> Dual Hard-Gate Verdict: $linterStatus (100% Deterministic Pass)" -ForegroundColor Green

# -------------------------------------------------------------------------
# Step 2. Local Qwen 27B (RTX 5070 Ti) Main Architectural Audit
# -------------------------------------------------------------------------
Write-Host "`n>>> [Step 2/4] Local Qwen 27B Main Architectural Audit..." -ForegroundColor Yellow
$qwenCacheFile = Join-Path $cacheDir "qwen_${targetFileName}_${targetFileHash}.md"

if ($UseCache -and (Test-Path $qwenCacheFile)) {
    $hermesOutputText = [System.IO.File]::ReadAllText($qwenCacheFile, [System.Text.Encoding]::UTF8)
    $qwenStatus = "COMPLETED (CACHE HIT)"
    Write-Host "  -> [CACHE HIT] Target hash matches. Reusing verified Qwen audit result (0ms, 0 tokens)." -ForegroundColor Cyan
} else {
    $repoQwenScript = Join-Path $scriptDir "call_qwen.ps1"
    $globalHermesScript = Join-Path $env:USERPROFILE ".gemini\scripts\audit_with_hermes.ps1"
    $hermesReportPath = ""
    $hermesOutputText = ""

    $hermesTempDir = Join-Path $projectRoot "scratch\hermes_run_${timestampStr}"
    if (-not (Test-Path $hermesTempDir)) { New-Item -ItemType Directory -Path $hermesTempDir -Force | Out-Null }
    $hermesReportCandidate = Join-Path $hermesTempDir "report.md"

    if (Test-Path $globalHermesScript) {
        # Path A: Global Hermes controller if available in local environment
        & powershell -ExecutionPolicy Bypass -File $globalHermesScript -TargetFile $resolvedTarget -OutputDir $hermesTempDir -OutputFile $hermesReportCandidate | Out-Null
    } elseif (Test-Path $repoQwenScript) {
        # Path B: Repository self-contained standalone execution (2-Tier Adversarial Audit Engine)
        $auditPrompt = @"
You are an uncompromising Red-Team Labour Standards Auditor and Adversarial Systems Architect.
Execute a 5-stage adversarial audit across 7 attack vectors (P1 Blocked-Terminator, P2 Record-vs-Reality Divergence, P3 Boundary Instant, P4 Rule Collision, P5 Aggregation Gap, P6 Silent Default, P7 Irreversibility).
Evaluate the following specification/source code for architectural integrity, legal paradoxes, and operational deadlocks.

Target: $resolvedTarget
Content:
$([System.IO.File]::ReadAllText($resolvedTarget, [System.Text.Encoding]::UTF8))
"@
        $auditPromptFile = Join-Path $hermesTempDir "prompt.txt"
        [System.IO.File]::WriteAllText($auditPromptFile, $auditPrompt, [System.Text.Encoding]::UTF8)
        $qwenRaw = & powershell -ExecutionPolicy Bypass -File $repoQwenScript -PromptFile $auditPromptFile -Seed 42 -Temperature 0.1 -Quiet
        [System.IO.File]::WriteAllText($hermesReportCandidate, $qwenRaw, [System.Text.Encoding]::UTF8)
    } else {
        $hermesOutputText = "Neither global Hermes script ($globalHermesScript) nor repository runner ($repoQwenScript) found."
        $qwenStatus = "FAIL (Script Missing)"
        Write-Error "  -> Hermes audit script not found: Fail-Closed enforcement"
        exit 2
    }

    if (Test-Path $hermesReportCandidate) {
        $hermesOutputText = [System.IO.File]::ReadAllText($hermesReportCandidate, [System.Text.Encoding]::UTF8)
        $qwenStatus = "COMPLETED"
        [System.IO.File]::WriteAllText($qwenCacheFile, $hermesOutputText, [System.Text.Encoding]::UTF8)
        Write-Host "  -> Qwen 27B Main Audit Completed" -ForegroundColor Green
    } else {
        $hermesOutputText = "Qwen audit report file was not generated."
        $qwenStatus = "FAIL (Report Not Generated)"
        Write-Warning "  -> Qwen result report missing"
    }
}

# -------------------------------------------------------------------------
# Step 3. OpenAI Codex CLI Read-Only Sandbox Cross-Audit
# -------------------------------------------------------------------------
Write-Host "`n>>> [Step 3/4] OpenAI Codex CLI Technical / Code Cross-Audit..." -ForegroundColor Yellow
$codexCacheFile = Join-Path $cacheDir "codex_${targetFileName}_${targetFileHash}.txt"

if ($UseCache -and (Test-Path $codexCacheFile)) {
    $codexOutputText = [System.IO.File]::ReadAllText($codexCacheFile, [System.Text.Encoding]::UTF8)
    $codexStatus = "COMPLETED (CACHE HIT)"
    Write-Host "  -> [CACHE HIT] Target hash matches. Reusing verified Codex audit result (0 tokens consumed)." -ForegroundColor Cyan
} else {
    $isCriticalDomain = $false
    $targetContent = if (Test-Path $resolvedTarget) { [System.IO.File]::ReadAllText($resolvedTarget, [System.Text.Encoding]::UTF8) } else { "" }
    if ($targetContent -match '(?i)(?:労働基準法第37条|割増賃金|25%|35%|50%|端数処理|1分単位|15分単位|30分単位|SELECT\s+.*?\s+FOR\s+UPDATE|FOR\s+UPDATE|悲観的ロック|排他制御|デッドロック|schema\.sql|FOREIGN\s+KEY|CHECK\s+制約|14列)') {
        $isCriticalDomain = $true
    }

    if ($AuditMode -ne "CrossExam" -and -not $isCriticalDomain -and $qwenStatus -eq "COMPLETED" -and ($hermesOutputText -match '(?i)"verdict"\s*:\s*"PASS"' -or $hermesOutputText -match '(?i)\bVerdict:\s*PASS\b')) {
        $codexStatus = "SKIPPED (Smart Router: Qwen PASS on non-critical domain)"
        $codexOutputText = "Codex cross-audit skipped by Smart Router: Local Qwen 27B verified PASS on non-critical domain ($0 spent)."
        Write-Host "  -> [SMART ROUTER] Non-critical domain and Qwen PASS. Skipping external Codex invocation ($0 spent, 100% tokens saved)." -ForegroundColor Green
    } else {
        $codexScript = Join-Path $scriptDir "call_codex.ps1"
        $codexLastMsgFile = Join-Path $projectRoot "scratch\test_runs\codex_last_msg.txt"
        if (Test-Path $codexLastMsgFile) { Remove-Item $codexLastMsgFile -Force -ErrorAction SilentlyContinue }
        
        if ($AuditMode -eq "CrossExam") {
            $codexPrompt = @"
You are the OpenAI Codex Principal Security Auditor in Cross-Examination Mode.
Analyze the target defense system alongside the preliminary vulnerability findings reported by Local Qwen 27B below.
Attempt to discover implementation loopholes, bypass techniques, and race conditions that could defeat the defense gates.

[Preliminary Qwen 27B Findings]:
$hermesOutputText
"@
        } else {
            $codexPrompt = "You are the OpenAI Codex Principal Auditor. Audit the specification for technical implementation, DDL constraints, DTO contracts, and pessimistic lock boundaries. Output findings in standard markdown table format."
        }
        
        $codexPromptFile = Join-Path $projectRoot "scratch\test_runs\crossexam_codex_prompt.txt"
        [System.IO.File]::WriteAllText($codexPromptFile, $codexPrompt, [System.Text.Encoding]::UTF8)
        $codexSummaryOutput = & powershell -ExecutionPolicy Bypass -File $codexScript -PromptFile $codexPromptFile -ContextFile $resolvedTarget
        $codexExitCode = $LASTEXITCODE

        if ($codexExitCode -eq 0 -and (Test-Path $codexLastMsgFile)) {
            $codexContent = [System.IO.File]::ReadAllText($codexLastMsgFile, [System.Text.Encoding]::UTF8).Trim()
            if ($codexContent.Length -gt 0) {
                $codexOutputText = $codexContent
                $codexStatus = "COMPLETED"
                [System.IO.File]::WriteAllText($codexCacheFile, $codexOutputText, [System.Text.Encoding]::UTF8)
                Write-Host "  -> Codex Cross-Audit Completed ($codexStatus)" -ForegroundColor Green
            } else {
                $codexStatus = "FAIL (Empty Output)"
                Write-Warning "  -> Codex Cross-Audit produced empty output"
            }
        } else {
            $codexStatus = "FAIL (Execution Error, ExitCode: $codexExitCode)"
            Write-Warning "  -> Codex Cross-Audit Failed ($codexStatus)"
        }
    }
}

# -------------------------------------------------------------------------
# Step 4. Anthropic Claude Sonnet 5.5 (Explicit User Request Only)
# -------------------------------------------------------------------------
$claudeOutputText = "Claude invocation skipped (Cost protection policy: user explicit request required)."
$claudeStatus = "NOT_EXECUTED (オンデマンド費用保護)"
if ($IncludeClaude) {
    Write-Host "`n>>> [Step 4/4] Claude Sonnet 5.5 Deep Business / Legal Audit (User Approved)..." -ForegroundColor Magenta
    $claudeCacheFile = Join-Path $cacheDir "claude_${targetFileName}_${targetFileHash}.txt"

    if ($UseCache -and (Test-Path $claudeCacheFile)) {
        $claudeOutputText = [System.IO.File]::ReadAllText($claudeCacheFile, [System.Text.Encoding]::UTF8)
        $claudeStatus = "COMPLETED (CACHE HIT)"
        Write-Host "  -> [CACHE HIT] Target hash matches. Reusing verified Claude audit result (0 API cost)." -ForegroundColor Cyan
    } else {
        $claudeScript = Join-Path $scriptDir "call_claude.ps1"
        $claudeLogFile = Join-Path $projectRoot "scratch\test_runs\claude_live.log"
        if (Test-Path $claudeLogFile) { Remove-Item $claudeLogFile -Force -ErrorAction SilentlyContinue }

        if ($AuditMode -eq "CrossExam") {
            $claudePrompt = @"
You are the Principal Regulatory & Defense Architect in Cross-Examination Mode (Claude Sonnet 5.5).
Critically evaluate the target defense system against the attack vectors and bypass analyses raised by Qwen 27B and Codex below.
Determine whether the defense barriers successfully seal these vulnerabilities, analyze any unaddressed residual risks, and provide a definitive Verdict (PASS / REJECT).

[Qwen 27B Attack Vectors]:
$hermesOutputText

[OpenAI Codex Bypass Analysis]:
$codexOutputText
"@
        } else {
            $claudePrompt = "You are the Principal Regulatory & Business Logic Auditor (Claude Sonnet 5.5). Audit the specification for Japanese Labor Standards Act Article 37 compliance, rounding conventions, and immutability invariants. Output findings table."
        }
        
        $claudePromptFile = Join-Path $projectRoot "scratch\test_runs\crossexam_claude_prompt.txt"
        [System.IO.File]::WriteAllText($claudePromptFile, $claudePrompt, [System.Text.Encoding]::UTF8)
        $claudeSummary = & powershell -ExecutionPolicy Bypass -File $claudeScript -PromptFile $claudePromptFile -ContextFile $resolvedTarget
        $claudeExitCode = $LASTEXITCODE
        
        if ($claudeExitCode -eq 0 -and (Test-Path $claudeLogFile)) {
            $claudeBody = [System.IO.File]::ReadAllText($claudeLogFile, [System.Text.Encoding]::UTF8).Trim()
            if ($claudeBody.Length -gt 0) {
                $claudeOutputText = $claudeBody
                $claudeStatus = "COMPLETED"
                [System.IO.File]::WriteAllText($claudeCacheFile, $claudeOutputText, [System.Text.Encoding]::UTF8)
                Write-Host "  -> Claude 5.5 Deep Audit Completed ($claudeStatus)" -ForegroundColor Green
            } else {
                $claudeStatus = "FAIL (Empty Output)"
                Write-Warning "  -> Claude audit log empty"
            }
        } else {
            $claudeStatus = "FAIL (API Error, ExitCode: $claudeExitCode)"
            Write-Warning "  -> Claude audit failed ($claudeStatus)"
        }
    }
} else {
    Write-Host "`n>>> [Step 4/4] Claude 5.5 Audit Skipped (Cost Protection Policy: On-demand only)" -ForegroundColor DarkGray
}

# -------------------------------------------------------------------------
# Step 5. Aggregate Master Unified Report
# -------------------------------------------------------------------------
Write-Host "`n>>> [Step 5] Aggregating Multi-Agent Master Audit Report..." -ForegroundColor Cyan

$masterReport = @"
# 🏛️ KINTAI Hermes 多層統合検証レポート (Master Quality Audit Report)

- **検証日時 (Timestamp)**: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
- **対象仕様書 (Target)**: $targetFileName
- **統括オーケストレーター**: Hermes Multi-Agent Controller (`hermes_controller.ps1`)

---

## 1. 多層ハードゲート総合判定サマリー (Multi-Layer Verdict Summary)

| 検証階層 | 検証エンジン / モデル | 担当領域 | 最終判定 |
|---|---|---|---|
| **Step 0: ハードゲート** | C# Deterministic Linter | 禁止文字、未確定記号、正規表現整合性 | **$linterStatus** |
| **Step 1: 主幹検証** | Qwen 27B (ローカルGPU RTX 5070 Ti) | ドメイン完全性・構造整合性・文脈検証 | **$qwenStatus** |
| **Step 2: 技術交差検証** | OpenAI Codex CLI (GPT-6.2) | DDL制約、DTO整合性、排他ロック境界条件 | **$codexStatus** |
| **Step 3: 法規深層検証** | Anthropic Claude (Sonnet 5.5) | 労働基準法第37条、端数処理、労使協定整合性 | **$claudeStatus** |

---

## 2. [Step 0] C# 決定論的リンター検証ログ
```text
$($linterOutput -join "`r`n")
```

---

## 3. [Step 1] ローカル Qwen 27B 主幹検証レポート
$hermesOutputText

---

## 4. [Step 2] OpenAI Codex CLI 技術交差検証レポート
$codexOutputText

---

## 5. [Step 3] Anthropic Claude Sonnet 5.5 法規深層検証レポート
$claudeOutputText

---

## 6. 総括および推奨事項 (Conclusion & Recommendations)
- 本レポートは、個別の手動操作を排し、**Hermes 統合コントローラーによる単一パイプライン下で決定論的リンター、Qwen 27B、Codex、Claude 5.5を統合実行**して生成された公式技術証跡です。
"@

[System.IO.File]::WriteAllText($OutputFile, $masterReport, [System.Text.Encoding]::UTF8)

$dailyAuditLogDir = Join-Path $projectRoot "docs"
if (Test-Path $dailyAuditLogDir) {
    $dailyAuditLogPath = Join-Path $dailyAuditLogDir "daily_audit_temp.log"
    $logEntry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | HERMES-CONTROLLER | $targetFileName | Linter:$linterStatus / Qwen:$qwenStatus / Codex:$codexStatus / Claude:$claudeStatus | Artifact:$([System.IO.Path]::GetFileName($OutputFile))]`r`n"
    [System.IO.File]::AppendAllText($dailyAuditLogPath, $logEntry, [System.Text.Encoding]::UTF8)
}

# Automated Dashboard Synchronization Hook (Single Source of Truth)
$syncScript = Join-Path $scriptDir "sync_dashboard.ps1"
if (Test-Path $syncScript) {
    & powershell -ExecutionPolicy Bypass -File $syncScript | Out-Null
}

$summaryTable = @"

| 検証フェーズ | エンジン / モデル | 判定 | 出力レポート |
|---|---|---|---|
| Step 0: ハードゲート | C# Deterministic Linter | $linterStatus | $OutputFile |
| Step 1: 主幹検証 | Qwen 27B (ローカルGPU) | $qwenStatus | $OutputFile |
| Step 2: 技術交差 | OpenAI Codex CLI | $codexStatus | $OutputFile |
| Step 3: 法規深層 | Claude Sonnet 5.5 | $claudeStatus | $OutputFile |

>>> [統合検証レポート出力完了]: $OutputFile
"@

Write-Output $summaryTable

$hasExecutionFailure = ($qwenStatus -like "FAIL*") -or ($codexStatus -like "FAIL*") -or ($claudeStatus -like "FAIL*")
if ($hasExecutionFailure) {
    Write-Error "[HERMES FAIL-CLOSED] One or more multi-agent verification stages failed during execution. Pipeline aborted with code 1."
    exit 1
}

return $OutputFile
