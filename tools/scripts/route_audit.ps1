#requires -Version 5.1
<#
.SYNOPSIS
    KINTAI Intelligent AI Audit Router & Token Diet Dispatcher (route_audit.ps1)
.DESCRIPTION
    Implements a multi-tiered token-saving routing policy:
    1. Tier 0: Deterministic Roslyn linter (VerifySRS.exe). Fast-fails with 0 AI tokens ($0) on syntax/DoD defects.
    2. Static Domain Analysis: Inspects target specification against critical statutory/concurrency rules.
    3. Tier 1: Local Qwen 27B primary audit (qwen3.8:27b via RTX 5070 Ti, cost $0) with 5-token PASS contract.
    4. Tier 2: Escalates to external paid models (OpenAI Codex / Anthropic Claude) ONLY IF critical domain is modified,
       or Qwen reports WARN/FAIL/ESCALATE, or -ForceExternal is specified.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TargetFile = "config/srs_specification_ssot.md",

    [Parameter(Mandatory = $false)]
    [string]$Prompt = "",

    [Parameter(Mandatory = $false)]
    [string]$PromptFile = "",

    [Parameter(Mandatory = $false)]
    [string]$ContextFile = "",

    [Parameter(Mandatory = $false)]
    [switch]$ForceExternal,

    [Parameter(Mandatory = $false)]
    [switch]$SkipTier0,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Codex", "Claude")]
    [string]$ExternalProvider = "Codex",

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 180,

    [Parameter(Mandatory = $false)]
    [switch]$ReportOnly,

    [Parameter(Mandatory = $false)]
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
if (-not (Test-Path $projectRoot)) { $projectRoot = (Get-Location).Path }

$swTotal = [System.Diagnostics.Stopwatch]::StartNew()
$routingResult = [ordered]@{
    timestamp           = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    target              = $TargetFile
    tier0_linter        = "SKIPPED"
    critical_domain     = $false
    critical_reasons    = @()
    tier1_qwen_verdict  = "NOT_RUN"
    tier2_escalation    = $false
    tier2_provider      = "NONE"
    tier2_verdict       = "NONE"
    final_verdict       = "HOLD"
    tokens_saved_ratio  = "0%"
    duration_seconds    = 0.0
}

function Log-RouterTemp([string]$msg) {
    try {
        $tempLog = Join-Path $projectRoot "docs\daily_audit_temp.log"
        [System.IO.File]::AppendAllText($tempLog, "$msg`r`n", [System.Text.Encoding]::UTF8)
    } catch {}
}

try {
    # -------------------------------------------------------------------------
    # Stage 0: Resolve Target File & Context
    # -------------------------------------------------------------------------
    $resolvedTarget = $TargetFile
    if (-not [System.IO.Path]::IsPathRooted($resolvedTarget)) {
        $resolvedTarget = Join-Path $projectRoot $resolvedTarget
    }

    $targetContent = ""
    if (Test-Path -LiteralPath $resolvedTarget) {
        $targetContent = [System.IO.File]::ReadAllText($resolvedTarget, [System.Text.Encoding]::UTF8)
    }

    $effectivePrompt = $Prompt
    if ($PromptFile -and (Test-Path -LiteralPath $PromptFile)) {
        $effectivePrompt = [System.IO.File]::ReadAllText($PromptFile, [System.Text.Encoding]::UTF8)
    }
    if ([string]::IsNullOrWhiteSpace($effectivePrompt)) {
        $effectivePrompt = 'Verify compliance with Article 0 Constitution. ZERO-PROSE CONTRACT: If fully compliant, respond strictly {"verdict": "PASS"}. If defects exist, output fenced json with verdict and findings array.'
    }

    # -------------------------------------------------------------------------
    # Stage 1: Tier 0 Deterministic Roslyn Linter (VerifySRS.exe)
    # -------------------------------------------------------------------------
    if (-not $SkipTier0 -and (Test-Path -LiteralPath $resolvedTarget) -and ($resolvedTarget.EndsWith(".md", [System.StringComparison]::OrdinalIgnoreCase))) {
        if (-not $Quiet) { Write-Host "[ROUTER] Stage 1: Running Tier 0 Deterministic Roslyn Linter (VerifySRS.exe)..." -ForegroundColor Cyan }
        $linterExe = Join-Path $scriptDir "VerifySRS.exe"
        if (-not (Test-Path $linterExe)) {
            $verifyScript = Join-Path $scriptDir "verify_srs.ps1"
            if (Test-Path $verifyScript) {
                & powershell -ExecutionPolicy Bypass -File $verifyScript -TargetFile $resolvedTarget | Out-Null
            }
        }
        if (Test-Path $linterExe) {
            $linterOut = & $linterExe $resolvedTarget 2>&1
            $linterCode = $LASTEXITCODE
            if ($linterCode -ne 0) {
                $routingResult.tier0_linter = "FAIL"
                $routingResult.final_verdict = "FAIL"
                $swTotal.Stop()
                $routingResult.duration_seconds = [math]::Round($swTotal.Elapsed.TotalSeconds, 2)
                $routingResult.tokens_saved_ratio = "100% (Tier 0 deterministic exit: 0 tokens spent)"
                
                Log-RouterTemp "[$($routingResult.timestamp) | ROUTE-AUDIT | $(Split-Path $resolvedTarget -Leaf) | Tier 0 Linter FAIL (ExitCode: $linterCode) | Duration: $($routingResult.duration_seconds)s]"
                if (-not $Quiet) {
                    Write-Host "[ROUTER FAIL-FAST] Tier 0 Deterministic Linter rejected specification. Aborting with 0 AI tokens spent ($0)." -ForegroundColor Red
                    $linterOut | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkRed }
                }
                if ($ReportOnly) {
                    $routingResult | ConvertTo-Json -Depth 5
                    exit 0
                }
                exit 1
            }
            $routingResult.tier0_linter = "PASS"
            if (-not $Quiet) { Write-Host "  -> Tier 0 Linter PASS (0 tokens spent)." -ForegroundColor Green }
        } else {
            Write-Host "[ROUTER FATAL] Tier 0 Deterministic Linter (VerifySRS.exe) not found and could not be built. Fail-Closed abort." -ForegroundColor Red
            exit 1
        }
    }

    # -------------------------------------------------------------------------
    # Stage 2: Static Critical Domain Analysis
    # -------------------------------------------------------------------------
    $corpus = "$targetContent`n$effectivePrompt"
    $critReasons = New-Object System.Collections.Generic.List[string]

    # Rule A: Labor Standards Act Article 37 & Statutory Wage/Rounding
    if ($corpus -match '(?i)(?:労働基準法第37条|割増賃金|25%|35%|50%|端数処理|1分単位|15分単位|30分単位)') {
        $critReasons.Add("Labor Standards Act Article 37 Statutory Wage/Rounding detected")
    }

    # Rule B: Pessimistic Concurrency & Lock Inversion
    if ($corpus -match '(?i)(?:SELECT\s+.*?\s+FOR\s+UPDATE|FOR\s+UPDATE|悲観的ロック|排他制御|デッドロック)') {
        $critReasons.Add("Pessimistic Concurrency Lock (FOR UPDATE) detected")
    }

    # Rule C: DDL Schema 14-Column & Constraint Invariants
    if ($corpus -match '(?i)(?:schema\.sql|FOREIGN\s+KEY|CHECK\s+制約|14列)') {
        $critReasons.Add("DDL Schema Structural Constraints detected")
    }

    if ($critReasons.Count -gt 0) {
        $routingResult.critical_domain = $true
        $routingResult.critical_reasons = @($critReasons)
        if (-not $Quiet) {
            Write-Host "  -> Critical domain triggers detected: $($critReasons -join '; ')" -ForegroundColor Yellow
        }
    }

    # -------------------------------------------------------------------------
    # Stage 3: Tier 1 Local Qwen 27B Primary Audit (Cost $0)
    # -------------------------------------------------------------------------
    $callAiScript = Join-Path $scriptDir "call_ai.ps1"
    if (-not (Test-Path $callAiScript)) {
        throw "SCRIPT_NOT_FOUND: call_ai.ps1 not found at $callAiScript"
    }

    $qwenRunSuccess = $false
    $qwenVerdict = "HOLD"

    if (-not $ForceExternal) {
        if (-not $Quiet) { Write-Host "[ROUTER] Stage 2: Launching Tier 1 Primary Audit via Local Qwen 27B (RTX 5070 Ti, Cost $0)..." -ForegroundColor Cyan }
        
        $qwenArgs = @(
            "-Provider", "Qwen",
            "-Prompt", $effectivePrompt,
            "-TimeoutSeconds", $TimeoutSeconds
        )
        if (Test-Path -LiteralPath $resolvedTarget) {
            $qwenArgs += @("-ContextFile", $resolvedTarget)
        }
        if ($Quiet) { $qwenArgs += "-Quiet" }

        $qwenSw = [System.Diagnostics.Stopwatch]::StartNew()
        & powershell -ExecutionPolicy Bypass -File $callAiScript @qwenArgs
        $qwenExit = $LASTEXITCODE
        $qwenSw.Stop()

        # Parse latest Qwen verdict from scratch test_runs
        $qwenLog = Join-Path $projectRoot "scratch\test_runs\qwen_live.log"
        if (Test-Path $qwenLog) {
            $qwenRaw = [System.IO.File]::ReadAllText($qwenLog, [System.Text.Encoding]::UTF8)
            if ($qwenRaw -match '(?i)"verdict"\s*:\s*"(PASS|WARN|HOLD|FAIL)"') {
                $qwenVerdict = $matches[1].ToUpperInvariant()
            } elseif ($qwenRaw -match '(?i)\bVerdict:\s*(PASS|WARN|HOLD|FAIL)\b') {
                $qwenVerdict = $matches[1].ToUpperInvariant()
            }
        }
        $routingResult.tier1_qwen_verdict = $qwenVerdict

        if ($qwenExit -eq 0 -and $qwenVerdict -eq "PASS" -and -not $routingResult.critical_domain) {
            # FAST-PATH RESOLUTION: Local Qwen 27B clean PASS on non-critical domain
            $routingResult.tier2_escalation = $false
            $routingResult.final_verdict = "PASS"
            $routingResult.tokens_saved_ratio = "100% (External API calls: 0, $0 cost)"
            $swTotal.Stop()
            $routingResult.duration_seconds = [math]::Round($swTotal.Elapsed.TotalSeconds, 2)

            Log-RouterTemp "[$($routingResult.timestamp) | ROUTE-AUDIT | $(Split-Path $resolvedTarget -Leaf) | Tier 1 Qwen27B PASS (0 External Calls) | Duration: $($routingResult.duration_seconds)s]"
            if (-not $Quiet) {
                Write-Host "[ROUTER SUCCESS] Tier 1 Local Qwen 27B verified PASS with 0 external API calls ($0 spent, 100% external tokens saved)." -ForegroundColor Green
            }
            if ($ReportOnly) {
                $routingResult | ConvertTo-Json -Depth 5
                exit 0
            }
            exit 0
        }
    }

    # -------------------------------------------------------------------------
    # Stage 4: Tier 2 Escalation (OpenAI Codex / Anthropic Claude)
    # -------------------------------------------------------------------------
    $escalateReasons = New-Object System.Collections.Generic.List[string]
    if ($ForceExternal) { $escalateReasons.Add("User explicitly passed -ForceExternal") }
    if ($routingResult.critical_domain) { $escalateReasons.Add("Critical domain triggered ($($critReasons -join ', '))") }
    if ($qwenVerdict -ne "PASS") { $escalateReasons.Add("Tier 1 Local Qwen returned verdict '$qwenVerdict'") }

    $routingResult.tier2_escalation = $true
    $routingResult.tier2_provider = $ExternalProvider
    if (-not $Quiet) {
        Write-Host "[ROUTER] Stage 3: Escalating to Tier 2 ($ExternalProvider) due to: $($escalateReasons -join '; ')..." -ForegroundColor Yellow
    }

    $extArgs = @(
        "-Provider", $ExternalProvider,
        "-Prompt", $effectivePrompt,
        "-TimeoutSeconds", $TimeoutSeconds
    )
    if (Test-Path -LiteralPath $resolvedTarget) {
        $extArgs += @("-ContextFile", $resolvedTarget)
    }
    if ($Quiet) { $extArgs += "-Quiet" }

    $extSw = [System.Diagnostics.Stopwatch]::StartNew()
    & powershell -ExecutionPolicy Bypass -File $callAiScript @extArgs
    $extExit = $LASTEXITCODE
    $extSw.Stop()

    $extVerdict = "HOLD"
    $extLog = if ($ExternalProvider -eq "Codex") {
        Join-Path $projectRoot "scratch\test_runs\codex_last_msg.txt"
    } else {
        Join-Path $projectRoot "scratch\test_runs\claude_live.log"
    }
    if (Test-Path $extLog) {
        $extRaw = [System.IO.File]::ReadAllText($extLog, [System.Text.Encoding]::UTF8)
        if ($extRaw -match '(?i)"verdict"\s*:\s*"(PASS|WARN|HOLD|FAIL)"') {
            $extVerdict = $matches[1].ToUpperInvariant()
        } elseif ($extRaw -match '(?i)\bVerdict:\s*(PASS|WARN|HOLD|FAIL)\b') {
            $extVerdict = $matches[1].ToUpperInvariant()
        }
    }

    $routingResult.tier2_verdict = $extVerdict
    $routingResult.final_verdict = $extVerdict
    $routingResult.tokens_saved_ratio = "50% (Escalated to Tier 2 on critical domain)"
    $swTotal.Stop()
    $routingResult.duration_seconds = [math]::Round($swTotal.Elapsed.TotalSeconds, 2)

    Log-RouterTemp "[$($routingResult.timestamp) | ROUTE-AUDIT | $(Split-Path $resolvedTarget -Leaf) | Qwen:$qwenVerdict -> $($ExternalProvider):$extVerdict | Duration: $($routingResult.duration_seconds)s]"

    if (-not $Quiet) {
        if ($extVerdict -eq "PASS") {
            Write-Host "[ROUTER COMPLETE] Tier 2 ($ExternalProvider) verified PASS." -ForegroundColor Green
        } else {
            Write-Host "[ROUTER WARN/FAIL] Tier 2 ($ExternalProvider) returned verdict: $extVerdict." -ForegroundColor Red
        }
    }

    if ($ReportOnly) {
        $routingResult | ConvertTo-Json -Depth 5
        exit 0
    }

    if ($extExit -ne 0 -or $extVerdict -eq "FAIL") {
        exit 1
    }
    exit 0
}
catch {
    $swTotal.Stop()
    $routingResult.final_verdict = "FAIL"
    $routingResult.duration_seconds = [math]::Round($swTotal.Elapsed.TotalSeconds, 2)
    Log-RouterTemp "[$($routingResult.timestamp) | ROUTE-AUDIT EXCEPTION | $($_.Exception.Message)]"
    [Console]::Error.WriteLine("[ROUTER EXCEPTION] $($_.Exception.Message)")
    exit 2
}
