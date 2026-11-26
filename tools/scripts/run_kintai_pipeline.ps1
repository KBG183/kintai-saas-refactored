<#
.SYNOPSIS
    KINTAI Project 3 Unified Hybrid AI QA Pipeline v2.0 (run_kintai_pipeline.ps1)
.DESCRIPTION
    5-Tier Fail-Closed Verification Pipeline:
    - Stage 1: Deterministic Gate (./gradlew check: Compile + JUnit 5 + ArchUnit + MyBatis ${} + Zero-Korean)
    - Stage 2: Local Qwen 27B Funnel Screening (git diff target selection + SHA-256 snapshot)
    - Stage 3: Cloud AI Cross-Audit (Claude Labor Law Art. 37 + Codex Concurrency/Locking)
    - Stage 4: Proof-First Citation Verifier & Stale-Context Check (Java/XML/SQL)
    - Stage 5: Fail-Closed Gate & Master Receipt Generation (with -HumanOverrideReason escape hatch)
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
    [int]$TimeoutSeconds = 180,

    [Parameter(Mandatory = $false)]
    [string]$HumanOverrideReason = ""
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
Write-Host " [KINTAI HYBRID QA v2.0] Deterministic + Multi-AI Cross-Verification" -ForegroundColor Cyan
Write-Host " Target Domain : $Domain" -ForegroundColor Cyan
Write-Host " Output Master : $runMasterDir" -ForegroundColor Cyan
Write-Host "==========================================================================" -ForegroundColor Cyan

$pipelineResults = [ordered]@{}
$failClosedReasons = New-Object System.Collections.Generic.List[string]

# -----------------------------------------------------------------------------
# STAGE 1: Deterministic Gate (./gradlew check)
# -----------------------------------------------------------------------------
Write-Host "`n>>> [Stage 1/5] Running ./gradlew check (Compile + JUnit + ArchUnit + SQL + Zero-Korean)..." -ForegroundColor Yellow
$stage1Start = Get-Date
try {
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $checkOut = & cmd.exe /c "gradlew.bat check --quiet 2>&1"
    $gradleExit = $LASTEXITCODE
    $ErrorActionPreference = $prevEap
    if ($gradleExit -ne 0) {
        throw "GRADLE_CHECK_FAIL (exit $gradleExit):`n$($checkOut -join "`n")"
    }
    $stage1Duration = [Math]::Round(((Get-Date) - $stage1Start).TotalSeconds, 2)
    Write-Host "  [PASS] Stage 1 ./gradlew check passed in ${stage1Duration}s" -ForegroundColor Green
    $pipelineResults["Stage 1: Deterministic Check"] = "PASS (${stage1Duration}s)"
} catch {
    Write-Host "  [FAIL] Stage 1 Failed: $($_.Exception.Message)" -ForegroundColor Red
    $pipelineResults["Stage 1: Deterministic Check"] = "FAIL"
    exit 1
}

if ($SkipAI) {
    Write-Host "`n[NOTICE] SkipAI flag specified. Pipeline terminating cleanly at Stage 1." -ForegroundColor Yellow
    exit 0
}

# -----------------------------------------------------------------------------
# Target Selection (git diff Funnel) & SHA-256 Context Snapshot
# -----------------------------------------------------------------------------
$coreTargets = @(
    "src/main/java/com/example/kintai/domain/payroll/util/PayrollCalculator.java",
    "src/main/java/com/example/kintai/domain/payroll/service/PayrollService.java",
    "src/main/java/com/example/kintai/domain/shift/service/ShiftService.java",
    "src/main/java/com/example/kintai/domain/attendance/service/AttendanceService.java"
)

$diffFiles = @()
try {
    $gitDiffOut = & git -C $projectRoot diff --name-only HEAD 2>$null
    if ($LASTEXITCODE -eq 0 -and $gitDiffOut) {
        $diffFiles = @($gitDiffOut | Where-Object { $_ -match '\.(java|xml|sql)$' -and (Test-Path (Join-Path $projectRoot $_)) })
    }
} catch { }

$selectedRelPaths = @($coreTargets + $diffFiles | Select-Object -Unique | Where-Object { Test-Path (Join-Path $projectRoot $_) })
$fileHashes = [ordered]@{}
$bundleSb = New-Object System.Text.StringBuilder

foreach ($rel in $selectedRelPaths) {
    $abs = Join-Path $projectRoot $rel
    $fileHashes[$rel] = (Get-FileHash -LiteralPath $abs -Algorithm SHA256).Hash
    $lines = [System.IO.File]::ReadAllLines($abs, [System.Text.Encoding]::UTF8)
    [void]$bundleSb.AppendLine("=== [BUNDLE: $rel | LINES: $($lines.Length) | SHA256: $($fileHashes[$rel].Substring(0,12))] ===")
    for ($i = 0; $i -lt $lines.Length; $i++) {
        [void]$bundleSb.AppendLine(("L{0}: {1}" -f ($i + 1), $lines[$i]))
    }
    [void]$bundleSb.AppendLine("")
}

$bundleFile = Join-Path $runMasterDir "context_bundle.txt"
[System.IO.File]::WriteAllText($bundleFile, $bundleSb.ToString(), [System.Text.Encoding]::UTF8)
Write-Host "  [CONTEXT] Bundled $($selectedRelPaths.Count) files with SHA-256 snapshots." -ForegroundColor Gray

# -----------------------------------------------------------------------------
# STAGE 2: Local Qwen 27B Specialized Funnel Screening (RTX 5070 Ti)
# -----------------------------------------------------------------------------
$qwenOutFile = Join-Path $runMasterDir "qwen_funnel_report.md"
if (-not $SkipQwen) {
    Write-Host "`n>>> [Stage 2/5] Running Local Qwen 27B Specialized Screening (Domain-Aware Router)..." -ForegroundColor Yellow
    $stage2Start = Get-Date
    $auditScript = Join-Path $env:USERPROFILE ".gemini\scripts\audit_with_hermes.ps1"
    if (-not (Test-Path $auditScript)) {
        $auditScript = Join-Path (Split-Path -Parent $env:USERPROFILE) "$($env:USERNAME)\.gemini\scripts\audit_with_hermes.ps1"
    }

    # Multi-domain prompt collector & merger (ADV-004 fix)
    $promptDir = Join-Path $projectRoot "tools\prompts"
    $matchingPrompts = [System.Collections.Generic.List[string]]::new()

    if ($Domain -eq "PAYROLL" -or ($selectedRelPaths -match "Payroll|Calculator")) {
        $p = Join-Path $promptDir "audit_labor_law_37.md"
        if (Test-Path $p) { $matchingPrompts.Add($p) }
    }
    if ($Domain -eq "SHIFT" -or ($selectedRelPaths -match "Shift")) {
        $p = Join-Path $promptDir "audit_concurrency_lock.md"
        if (Test-Path $p) { $matchingPrompts.Add($p) }
    }
    if ($Domain -eq "ATTENDANCE" -or ($selectedRelPaths -match "Attendance|Security|Controller")) {
        $p = Join-Path $promptDir "audit_idor_security.md"
        if (Test-Path $p) { $matchingPrompts.Add($p) }
    }

    $specializedSystemPrompt = ""
    if ($matchingPrompts.Count -gt 0) {
        $promptBodies = @()
        foreach ($mp in $matchingPrompts) {
            Write-Host "  [ROUTER] Activated Specialized Prompt: $(Split-Path $mp -Leaf)" -ForegroundColor Cyan
            $promptBodies += [System.IO.File]::ReadAllText($mp, [System.Text.Encoding]::UTF8)
        }
        $specializedSystemPrompt = ($promptBodies -join "`n`n---`n`n")
    }

    $stage2ShortCircuit = $false
    if (Test-Path $auditScript) {
        try {
            if (-not [string]::IsNullOrWhiteSpace($specializedSystemPrompt)) {
                & $auditScript -TargetFile $bundleFile -OutputFile $qwenOutFile -SystemPromptOverride $specializedSystemPrompt
            } else {
                & $auditScript -TargetFile $bundleFile -OutputFile $qwenOutFile
            }
            $stage2Duration = [Math]::Round(((Get-Date) - $stage2Start).TotalSeconds, 2)
            
            # Fail-Closed Table & Ambiguity Parser (ADV-001, ADV-002, ADV-003 fix)
            if (Test-Path $qwenOutFile) {
                $qwenReportText = [System.IO.File]::ReadAllText($qwenOutFile, [System.Text.Encoding]::UTF8)
                
                # Check for P0/P1 FAIL rows with resilient cell matching
                $tableRowPattern = '\|\s*(?<id>[A-Z]{3}-\d+)\s*\|\s*(?<item>[^|]+)\s*\|\s*(?<sev>P0|P1|P2|Info)\s*\|\s*(?<verdict>PASS|WARN|FAIL|N/A)\s*\|\s*(?<evidence>[^|]+)\s*\|\s*(?<desc>[^|]+)\|'
                $matches = [regex]::Matches($qwenReportText, $tableRowPattern)
                $p0p1Failures = [System.Collections.Generic.List[string]]::new()

                foreach ($m in $matches) {
                    $sev = $m.Groups['sev'].Value.Trim()
                    $verdict = $m.Groups['verdict'].Value.Trim()
                    $id = $m.Groups['id'].Value.Trim()
                    $item = $m.Groups['item'].Value.Trim()
                    $evidence = $m.Groups['evidence'].Value.Trim()

                    if (($sev -eq 'P0' -or $sev -eq 'P1') -and $verdict -eq 'FAIL') {
                        $p0p1Failures.Add("[$id] $item ($sev FAIL at $evidence)")
                    }
                }

                # Negative Control check: if text contains FAIL/P0 but regex matched 0 structured rows -> Parse Drift Error
                if ($matches.Count -eq 0 -and ($qwenReportText -match '\bP0\b' -or $qwenReportText -match '\bFAIL\b')) {
                    $p0p1Failures.Add("[PARSE_DRIFT] Report contains unparsed P0/FAIL keywords outside standard markdown table.")
                }

                if ($p0p1Failures.Count -gt 0) {
                    Write-Host "`n  [FAIL-CLOSED ALERT] Critical Findings Detected by Local Qwen 27B:" -ForegroundColor Red
                    foreach ($fail in $p0p1Failures) {
                        Write-Host "    - $fail" -ForegroundColor Red
                    }

                    if (-not [string]::IsNullOrWhiteSpace($HumanOverrideReason)) {
                        Write-Host "  [OVERRIDE ACCEPTED] Proceeding with warning due to -HumanOverrideReason: $HumanOverrideReason" -ForegroundColor Yellow
                        $pipelineResults["Stage 2: Local Qwen Funnel"] = "WARN_OVERRIDDEN (${stage2Duration}s)"
                    } else {
                        $stage2ShortCircuit = $true
                        Write-Host "  [FUNNEL SHORT-CIRCUIT] Stage 2 Local Qwen 27B caught P0/P1 defect(s). Skipping Stage 3 Cloud AI calls to save cost/time." -ForegroundColor Yellow
                        $failClosedReasons.Add("Local Qwen 27B detected $($p0p1Failures.Count) critical P0/P1 defect(s): $($p0p1Failures -join '; ')")
                        $pipelineResults["Stage 2: Local Qwen Funnel"] = "FAIL_CLOSED (${stage2Duration}s)"
                    }
                } else {
                    $pipelineResults["Stage 2: Local Qwen Funnel"] = "DONE (${stage2Duration}s)"
                }
            } else {
                $pipelineResults["Stage 2: Local Qwen Funnel"] = "FAIL_NO_OUTPUT"
                $failClosedReasons.Add("Local Qwen 27B did not generate output file.")
            }
        } catch {
            $pipelineResults["Stage 2: Local Qwen Funnel"] = "WARN_NONZERO"
            $failClosedReasons.Add("Qwen stage returned non-zero: $($_.Exception.Message)")
        }
    } else {
        $pipelineResults["Stage 2: Local Qwen Funnel"] = "SKIPPED_NO_SCRIPT"
    }
} else {
    $pipelineResults["Stage 2: Local Qwen Funnel"] = "SKIPPED"
}

# -----------------------------------------------------------------------------
# STAGE 3: Cloud AI Cross-Audit (Claude + Codex)
# -----------------------------------------------------------------------------
$aiReportFiles = New-Object System.Collections.Generic.List[string]
if (Test-Path $qwenOutFile) { $aiReportFiles.Add($qwenOutFile) }

function Invoke-CloudAuditStage {
    param([string]$Name, [string]$ScriptName, [string]$PromptBody)
    $stageStart = Get-Date
    $promptPath = Join-Path $runMasterDir "${Name}_prompt.txt"
    [System.IO.File]::WriteAllText($promptPath, $PromptBody, [System.Text.Encoding]::UTF8)
    $caller = Join-Path $scriptDir $ScriptName

    $beforeDirs = @(Get-ChildItem -Path (Join-Path $projectRoot "audit\runs") -Directory | Select-Object -ExpandProperty FullName)
    try {
        & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $caller -PromptFile $promptPath -ContextFile $bundleFile -TimeoutSeconds $TimeoutSeconds
        $dur = [Math]::Round(((Get-Date) - $stageStart).TotalSeconds, 2)
        $pipelineResults["Stage 3: $Name"] = "PASS (${dur}s)"
    } catch {
        $dur = [Math]::Round(((Get-Date) - $stageStart).TotalSeconds, 2)
        $pipelineResults["Stage 3: $Name"] = "FAIL_OR_FINDINGS (${dur}s)"
        $failClosedReasons.Add("$Name returned non-zero / findings.")
    }

    $afterDirs = @(Get-ChildItem -Path (Join-Path $projectRoot "audit\runs") -Directory | Where-Object { $beforeDirs -notcontains $_.FullName })
    foreach ($ad in $afterDirs) {
        $rep = Join-Path $ad.FullName "report.txt"
        if (Test-Path $rep) { $aiReportFiles.Add($rep) }
    }
}

if ($stage2ShortCircuit) {
    $pipelineResults["Stage 3: Claude"] = "SKIPPED_BY_STAGE2_FUNNEL"
} elseif (-not $SkipClaude) {
    Write-Host "`n>>> [Stage 3A/5] Running Anthropic Claude (Labor Law Art. 37)..." -ForegroundColor Yellow
    $claudePrompt = @"
Audit the attached KINTAI Java files strictly against Japanese Labor Standards Act Art. 37:
1. Overtime (+25%), Night (+25%), Night-Overtime (+50% / 150% total without double-counting), Holiday (+35%), Holiday-Night (+60%).
2. HALF_UP 50-sen rounding and BigDecimal precision.
3. Confirmed payroll overwrite guards and unresolved attendance checks.
Cite evidence using [RelativeFilePath:LineNumber] and end with 'VERDICT: PASS' or 'VERDICT: FAIL'.
"@
    Invoke-CloudAuditStage -Name "Claude" -ScriptName "call_claude.ps1" -PromptBody $claudePrompt
} else {
    $pipelineResults["Stage 3: Claude"] = "SKIPPED"
}

if ($stage2ShortCircuit) {
    $pipelineResults["Stage 3: Codex"] = "SKIPPED_BY_STAGE2_FUNNEL"
} elseif (-not $SkipCodex) {
    Write-Host "`n>>> [Stage 3B/5] Running OpenAI Codex (Concurrency & Locking)..." -ForegroundColor Yellow
    $codexPrompt = @"
Audit the attached KINTAI Spring Boot 4 / MyBatis services strictly for:
1. Pessimistic locking (SELECT ... FOR UPDATE) serialization and deadlock prevention order.
2. Transaction boundaries (@Transactional) and double-confirm overwrite guards.
3. Tenant isolation (storeId / IDOR checks).
Cite evidence using [RelativeFilePath:LineNumber] and end with 'VERDICT: PASS' or 'VERDICT: FAIL'.
"@
    Invoke-CloudAuditStage -Name "Codex" -ScriptName "call_codex.ps1" -PromptBody $codexPrompt
} else {
    $pipelineResults["Stage 3: Codex"] = "SKIPPED"
}

# -----------------------------------------------------------------------------
# STAGE 4: Proof-First Citation Verifier & Stale-Context Check
# -----------------------------------------------------------------------------
Write-Host "`n>>> [Stage 4/5] Running Proof-First Citation Verifier & Stale-Context Check..." -ForegroundColor Yellow
$staleFiles = @()
foreach ($rel in $fileHashes.Keys) {
    $abs = Join-Path $projectRoot $rel
    $currentHash = (Get-FileHash -LiteralPath $abs -Algorithm SHA256).Hash
    if ($currentHash -ne $fileHashes[$rel]) {
        $staleFiles += $rel
    }
}

if ($staleFiles.Count -gt 0) {
    $failClosedReasons.Add("STALE_CONTEXT: Files modified during AI audit: $($staleFiles -join ', ')")
    $pipelineResults["Stage 4: Proof-First Verifier"] = "STALE_CONTEXT"
} else {
    $citationErrors = 0
    $citationCount = 0
    $citRegex = '\[(?<path>[^\]\r\n]+?\.(?:java|xml|sql))\s*:\s*L?(?<line>\d+)\]'

    foreach ($rf in $aiReportFiles) {
        $txt = [System.IO.File]::ReadAllText($rf, [System.Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($txt) -or $txt.Trim().Length -lt 50) {
            $failClosedReasons.Add("TRUNCATED_OR_EMPTY report: $(Split-Path $rf -Leaf)")
        }
        $matches = [regex]::Matches($txt, $citRegex)
        foreach ($m in $matches) {
            $citationCount++
            $cPath = $m.Groups['path'].Value.Trim().Replace('/', '\')
            $cLine = [int]$m.Groups['line'].Value
            $resolved = if ([System.IO.Path]::IsPathRooted($cPath)) { $cPath } else { Join-Path $projectRoot $cPath }
            if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
                $matchedRel = $selectedRelPaths | Where-Object { $_.Replace('/', '\').EndsWith($cPath) } | Select-Object -First 1
                if ($matchedRel) { $resolved = Join-Path $projectRoot $matchedRel }
            }
            if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
                $citationErrors++
            } else {
                $totalLines = ([System.IO.File]::ReadAllLines($resolved, [System.Text.Encoding]::UTF8)).Length
                if ($cLine -lt 1 -or $cLine -gt $totalLines) {
                    $citationErrors++
                }
            }
        }
    }

    if ($citationErrors -gt 0) {
        $failClosedReasons.Add("PROOF_FIRST_FAIL: $citationErrors invalid/hallucinated line citations detected.")
        $pipelineResults["Stage 4: Proof-First Verifier"] = "FAIL ($citationErrors/$citationCount invalid)"
    } else {
        $pipelineResults["Stage 4: Proof-First Verifier"] = "PASS ($citationCount citations verified)"
    }
}

# -----------------------------------------------------------------------------
# STAGE 5: Fail-Closed Gate & Master Receipt
# -----------------------------------------------------------------------------
$finalGateStatus = "PASS"
$exitCode = 0
if ($failClosedReasons.Count -gt 0) {
    if (-not [string]::IsNullOrWhiteSpace($HumanOverrideReason)) {
        $finalGateStatus = "PASS_WITH_OVERRIDE"
        Write-Host "`n  [OVERRIDE] Fail-Closed overridden by human approval: $HumanOverrideReason" -ForegroundColor Yellow
    } else {
        $finalGateStatus = "FAIL_CLOSED"
        $exitCode = 1
    }
}
$pipelineResults["Stage 5: Final Gate"] = $finalGateStatus

$summaryReport = [ordered]@{
    timestamp             = $timestamp
    domain                = $Domain
    bundled_files         = $selectedRelPaths
    stages                = $pipelineResults
    fail_closed_reasons   = $failClosedReasons
    human_override_reason = $HumanOverrideReason
    receipt               = $runMasterDir
}
$summaryJson = $summaryReport | ConvertTo-Json -Depth 5
[System.IO.File]::WriteAllText((Join-Path $runMasterDir "master_summary.json"), $summaryJson, [System.Text.Encoding]::UTF8)

Write-Host "`n==========================================================================" -ForegroundColor Cyan
Write-Host " [KINTAI HYBRID QA v2.0] Execution Summary" -ForegroundColor Cyan
Write-Host "==========================================================================" -ForegroundColor Cyan
$pipelineResults.GetEnumerator() | ForEach-Object {
    $color = if ($_.Value -match "PASS|DONE") { "Green" } else { "Red" }
    Write-Host (" {0,-32} : {1}" -f $_.Key, $_.Value) -ForegroundColor $color
}
if ($failClosedReasons.Count -gt 0) {
    Write-Host "--------------------------------------------------------------------------" -ForegroundColor Yellow
    $failClosedReasons | ForEach-Object { Write-Host " - $_" -ForegroundColor Yellow }
}
Write-Host " Master Receipt: $runMasterDir" -ForegroundColor Cyan
Write-Host "==========================================================================" -ForegroundColor Cyan

exit $exitCode
