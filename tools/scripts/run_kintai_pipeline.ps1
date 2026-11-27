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
# Target Selection (Pure git diff Funnel) & SHA-256 Context Snapshot
# -----------------------------------------------------------------------------
$diffFiles = @()
try {
    $rawDiff = & git -C $projectRoot diff --name-only HEAD
    $diffFiles = @($rawDiff | Where-Object { $_ -match '\.(java|xml|sql|ya?ml)$' -and (Test-Path (Join-Path $projectRoot $_)) })
} catch {
    Write-Host "[WARN] Git diff detection encountered: $($_.Exception.Message)" -ForegroundColor Yellow
}

$selectedRelPaths = @($diffFiles | Select-Object -Unique | Where-Object { Test-Path (Join-Path $projectRoot $_) })
if ($selectedRelPaths.Count -eq 0) {
    Write-Host "`n[NOTICE] No Java/XML/SQL/YAML changes detected in git diff against HEAD." -ForegroundColor Yellow
}
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
# MULTI-AI PARALLEL AUDIT EXECUTION (Qwen 27B + Claude + Codex)
# -----------------------------------------------------------------------------
$qwenOutFile = Join-Path $runMasterDir "qwen_funnel_report.md"
$aiReportFiles = New-Object System.Collections.Generic.List[string]

# Multi-domain prompt collector for Qwen
$promptDir = Join-Path $projectRoot "tools\prompts"
$matchingPrompts = [System.Collections.Generic.List[string]]::new()
if ($Domain -eq "PAYROLL" -or ($selectedRelPaths -match "Payroll|Calculator")) {
    $p = Join-Path $promptDir "audit_labor_law_37.md"
    if (Test-Path $p) { $matchingPrompts.Add($p) }
}
if ($Domain -eq "SHIFT" -or ($selectedRelPaths -match "Shift|Mapper\.xml|\.sql")) {
    $p = Join-Path $promptDir "audit_concurrency_lock.md"
    if (Test-Path $p) { $matchingPrompts.Add($p) }
}
if ($Domain -eq "ATTENDANCE" -or ($selectedRelPaths -match "Attendance|Security|Controller|application.*\.ya?ml")) {
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

$claudePrompt = @"
Audit the attached KINTAI Java files strictly against Japanese Labor Standards Act Art. 37:
1. Overtime (+25%), Night (+25%), Night-Overtime (+50% / 150% total without double-counting), Holiday (+35%), Holiday-Night (+60%).
2. HALF_UP 50-sen rounding and BigDecimal precision.
3. Confirmed payroll overwrite guards and unresolved attendance checks.

OUTPUT CONSTRAINTS:
- Do NOT write conversational prose, verbose essays, or redundant full-file quotes.
- Output a markdown findings table followed by a structured JSON array.
- Keep the entire response strictly concise (under 2000 tokens) to guarantee zero truncation.
- Each finding must cite [RelativeFilePath:LineNumber], assertion, and concrete failure scenario.
- Conclude strictly with either 'VERDICT: PASS' or 'VERDICT: FAIL'.
"@

$codexPrompt = @"
Audit the attached KINTAI Spring Boot 4 / MyBatis services strictly for:
1. Pessimistic locking (SELECT ... FOR UPDATE) serialization and deadlock prevention order.
2. Transaction boundaries (@Transactional) and double-confirm overwrite guards.
3. Tenant isolation (storeId / IDOR checks).
Cite evidence using [RelativeFilePath:LineNumber] and end with 'VERDICT: PASS' or 'VERDICT: FAIL'.
"@

$claudePromptPath = Join-Path $runMasterDir "Claude_prompt.txt"
[System.IO.File]::WriteAllText($claudePromptPath, $claudePrompt, [System.Text.Encoding]::UTF8)

$codexPromptPath = Join-Path $runMasterDir "Codex_prompt.txt"
[System.IO.File]::WriteAllText($codexPromptPath, $codexPrompt, [System.Text.Encoding]::UTF8)

$auditScript = Join-Path $env:USERPROFILE ".gemini\scripts\audit_with_hermes.ps1"
if (-not (Test-Path $auditScript)) {
    $auditScript = Join-Path (Split-Path -Parent $env:USERPROFILE) "$($env:USERNAME)\.gemini\scripts\audit_with_hermes.ps1"
}
$callerClaude = Join-Path $scriptDir "call_claude.ps1"
$callerCodex = Join-Path $scriptDir "call_codex.ps1"

$jobs = @{}
$jobStartTimes = @{}
Write-Host "`n>>> [Stages 2 & 3] Launching Multi-AI Parallel Outer Gate (Fan-out)..." -ForegroundColor Yellow

# 1. Launch Qwen Job
if (-not $SkipQwen -and (Test-Path $auditScript)) {
    Write-Host "  [FAN-OUT] Launching Local Qwen 27B (Remote RTX 5070 Ti)..." -ForegroundColor Cyan
    $jobStartTimes["Qwen"] = Get-Date
    $qwenBlock = {
        param($auditScript, $bundleFile, $qwenOutFile, $sysPrompt, $workDir)
        Set-Location $workDir
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $OutputEncoding = [System.Text.Encoding]::UTF8
        $qwenOutputDir = Split-Path -Parent $qwenOutFile
        if (-not [string]::IsNullOrWhiteSpace($sysPrompt)) {
            & $auditScript -TargetFile $bundleFile -OutputFile $qwenOutFile -OutputDir $qwenOutputDir -SystemPromptOverride $sysPrompt
        } else {
            & $auditScript -TargetFile $bundleFile -OutputFile $qwenOutFile -OutputDir $qwenOutputDir
        }
        return $LASTEXITCODE
    }
    $jobs["Qwen"] = Start-Job -ScriptBlock $qwenBlock -ArgumentList $auditScript, $bundleFile, $qwenOutFile, $specializedSystemPrompt, $projectRoot
} else {
    $pipelineResults["Stage 2: Local Qwen Funnel"] = if ($SkipQwen) { "SKIPPED" } else { "SKIPPED_NO_SCRIPT" }
}

# 2. Launch Claude Job
$claudeBeforeDirs = @(Get-ChildItem -Path (Join-Path $projectRoot "audit\runs") -Directory | Select-Object -ExpandProperty FullName)
if (-not $SkipClaude) {
    Write-Host "  [FAN-OUT] Launching Anthropic Claude Sonnet 5.5 (Cloud API)..." -ForegroundColor Cyan
    $jobStartTimes["Claude"] = Get-Date
    $cloudBlock = {
        param($caller, $promptPath, $bundleFile, $timeout)
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $OutputEncoding = [System.Text.Encoding]::UTF8
        & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $caller -PromptFile $promptPath -ContextFile $bundleFile -TimeoutSeconds $timeout
        return $LASTEXITCODE
    }
    $jobs["Claude"] = Start-Job -ScriptBlock $cloudBlock -ArgumentList $callerClaude, $claudePromptPath, $bundleFile, $TimeoutSeconds
} else {
    $pipelineResults["Stage 3: Claude"] = "SKIPPED"
}

# 3. Launch Codex Job
$codexBeforeDirs = @(Get-ChildItem -Path (Join-Path $projectRoot "audit\runs") -Directory | Select-Object -ExpandProperty FullName)
if (-not $SkipCodex) {
    Write-Host "  [FAN-OUT] Launching OpenAI Codex CLI (CLI Engine)..." -ForegroundColor Cyan
    $jobStartTimes["Codex"] = Get-Date
    $cloudBlock = {
        param($caller, $promptPath, $bundleFile, $timeout)
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $OutputEncoding = [System.Text.Encoding]::UTF8
        & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $caller -PromptFile $promptPath -ContextFile $bundleFile -TimeoutSeconds $timeout
        return $LASTEXITCODE
    }
    $jobs["Codex"] = Start-Job -ScriptBlock $cloudBlock -ArgumentList $callerCodex, $codexPromptPath, $bundleFile, $TimeoutSeconds
} else {
    $pipelineResults["Stage 3: Codex"] = "SKIPPED"
}

# Wait for all parallel jobs to complete
if ($jobs.Count -gt 0) {
    Write-Host "  [SYNC] Waiting for all $($jobs.Count) AI audit engines to finish concurrently..." -ForegroundColor Yellow
    $allJobsList = @($jobs.Values)
    $null = Wait-Job -Job $allJobsList -Timeout ($TimeoutSeconds + 60)
}

# Harvest Qwen Results
if ($jobs.ContainsKey("Qwen")) {
    $job = $jobs["Qwen"]
    $jobState = $job.State
    $qwenExit = Receive-Job -Job $job
    Remove-Job -Job $job -Force
    $dur = [Math]::Round(((Get-Date) - $jobStartTimes["Qwen"]).TotalSeconds, 2)
    
    if ($jobState -ne "Completed") {
        $failClosedReasons.Add("Local Qwen 27B background job terminated abnormally (JobState: $jobState).")
    }
    
    if (Test-Path $qwenOutFile) {
        $aiReportFiles.Add($qwenOutFile)
        $qwenReportText = [System.IO.File]::ReadAllText($qwenOutFile, [System.Text.Encoding]::UTF8)
        $tableRowPattern = '\|\s*(?<id>[A-Z]{3}-\d+)\s*\|\s*(?<item>[^|]+)\s*\|\s*(?<sev>P0|P1|P2|Info)\s*\|\s*(?<verdict>PASS|WARN|FAIL|N/A)\s*\|\s*(?<evidence>[^|]+)\s*\|\s*(?<desc>[^|]+)\|'
        $matches = [regex]::Matches($qwenReportText, $tableRowPattern)
        $p0p1Failures = [System.Collections.Generic.List[string]]::new()

        foreach ($m in $matches) {
            $sev = $m.Groups['sev'].Value.Trim()
            $verdict = $m.Groups['verdict'].Value.Trim()
            $id = $m.Groups['id'].Value.Trim()
            $item = $m.Groups['item'].Value.Trim()
            $evidence = $m.Groups['evidence'].Value.Trim()

            if (($sev -eq 'P0' -or $sev -eq 'P1') -and ($verdict -match 'FAIL|WARN')) {
                $p0p1Failures.Add("[$id] $item ($sev $verdict at $evidence)")
            }
        }

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
                $pipelineResults["Stage 2: Local Qwen Funnel"] = "WARN_OVERRIDDEN (${dur}s)"
            } else {
                $failClosedReasons.Add("Local Qwen 27B detected $($p0p1Failures.Count) critical P0/P1 defect(s): $($p0p1Failures -join '; ')")
                $pipelineResults["Stage 2: Local Qwen Funnel"] = "FAIL_CLOSED (${dur}s, $($p0p1Failures.Count) findings)"
            }
        } else {
            $pipelineResults["Stage 2: Local Qwen Funnel"] = "DONE (${dur}s)"
        }
    } else {
        $pipelineResults["Stage 2: Local Qwen Funnel"] = "FAIL_NO_OUTPUT (${dur}s)"
        $failClosedReasons.Add("Local Qwen 27B did not generate output file.")
    }
}

# Harvest Claude Results
if ($jobs.ContainsKey("Claude")) {
    $job = $jobs["Claude"]
    $jobState = $job.State
    $rawClaudeOutput = @(Receive-Job -Job $job)
    Remove-Job -Job $job -Force
    $dur = [Math]::Round(((Get-Date) - $jobStartTimes["Claude"]).TotalSeconds, 2)
    
    $afterDirs = @(Get-ChildItem -Path (Join-Path $projectRoot "audit\runs") -Directory | Where-Object { $claudeBeforeDirs -notcontains $_.FullName })
    foreach ($ad in $afterDirs) {
        $rep = Join-Path $ad.FullName "report.txt"
        if (Test-Path $rep) { $aiReportFiles.Add($rep) }
    }
    
    $claudeExit = if ($jobState -ne "Completed") { 1 } else { 0 }
    if ($rawClaudeOutput.Count -gt 0) {
        $lastVal = $rawClaudeOutput[-1]
        if ($lastVal -match '^\d+$') { 
            $claudeExit = [int]$lastVal 
        } elseif ($rawClaudeOutput -match '(?i)(Verdict:\s*FAIL|CLAUDE_API_ERROR|NativeCommandError|AUTH_ERROR|ERROR:|Exception)') { 
            $claudeExit = 1 
        }
    }
    
    if ($claudeExit -ne 0) {
        $pipelineResults["Stage 3: Claude"] = "FAIL_CLOSED (${dur}s, exit code $claudeExit, JobState: $jobState)"
        $failClosedReasons.Add("Claude returned non-zero exit code $claudeExit or encountered execution failure (JobState: $jobState).")
    } else {
        $pipelineResults["Stage 3: Claude"] = "PASS (${dur}s)"
    }
}

# Harvest Codex Results
if ($jobs.ContainsKey("Codex")) {
    $job = $jobs["Codex"]
    $jobState = $job.State
    $rawCodexOutput = @(Receive-Job -Job $job)
    Remove-Job -Job $job -Force
    $dur = [Math]::Round(((Get-Date) - $jobStartTimes["Codex"]).TotalSeconds, 2)
    
    $afterDirs = @(Get-ChildItem -Path (Join-Path $projectRoot "audit\runs") -Directory | Where-Object { $codexBeforeDirs -notcontains $_.FullName })
    foreach ($ad in $afterDirs) {
        $rep = Join-Path $ad.FullName "report.txt"
        if (Test-Path $rep) { $aiReportFiles.Add($rep) }
    }
    
    $codexExit = if ($jobState -ne "Completed") { 1 } else { 0 }
    if ($rawCodexOutput.Count -gt 0) {
        $lastVal = $rawCodexOutput[-1]
        if ($lastVal -match '^\d+$') { 
            $codexExit = [int]$lastVal 
        } elseif ($rawCodexOutput -match '(?i)(Verdict:\s*FAIL|NativeCommandError|AUTH_ERROR|ERROR:|Exception)') { 
            $codexExit = 1 
        }
    }
    
    if ($codexExit -ne 0) {
        $pipelineResults["Stage 3: Codex"] = "FAIL_CLOSED (${dur}s, exit code $codexExit, JobState: $jobState)"
        $failClosedReasons.Add("Codex returned non-zero exit code $codexExit or encountered execution failure (JobState: $jobState).")
    } else {
        $pipelineResults["Stage 3: Codex"] = "PASS (${dur}s)"
    }
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

$receiptRel = "audit/runs/${timestamp}_kintai_master_${runGuid}".Replace('\', '/')
$summaryReport = [ordered]@{
    timestamp             = $timestamp
    domain                = $Domain
    bundled_files         = $selectedRelPaths
    stages                = $pipelineResults
    fail_closed_reasons   = $failClosedReasons
    human_override_reason = $HumanOverrideReason
    receipt               = $receiptRel
}
$summaryJson = $summaryReport | ConvertTo-Json -Depth 5
$summaryJson = $summaryJson -replace [regex]::Escape($projectRoot), "." -replace '[\uAC00-\uD7A3]+', 'Desktop'
[System.IO.File]::WriteAllText((Join-Path $runMasterDir "master_summary.json"), $summaryJson, [System.Text.Encoding]::UTF8)

# Auto-sanitize generated markdown reports to prevent local path leakage
Get-ChildItem -Path $runMasterDir -Filter "*.md" | ForEach-Object {
    $c = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
    $clean = $c -replace [regex]::Escape($projectRoot), "." -replace '[\uAC00-\uD7A3]+', 'Desktop'
    if ($clean -ne $c) {
        [System.IO.File]::WriteAllText($_.FullName, $clean, [System.Text.Encoding]::UTF8)
    }
}

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
