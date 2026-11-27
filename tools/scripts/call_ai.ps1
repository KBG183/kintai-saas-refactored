<#
.SYNOPSIS
    KINTAI Unified Multi-AI Streaming Runner (call_ai.ps1)
.DESCRIPTION
    Consolidates OpenAI Codex, Anthropic Claude, and Local Qwen 27B into a single,
    deterministic, zero-leak streaming execution interface with multi-lingual verdict parsing
    and fail-closed terminal exit code contracts.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Codex", "Claude", "Qwen")]
    [string]$Provider,

    [Parameter(Mandatory = $false)]
    [string]$Prompt,

    [Parameter(Mandatory = $false)]
    [string]$PromptFile,

    [Parameter(Mandatory = $false)]
    [string]$ContextFile,

    [Parameter(Mandatory = $false)]
    [string]$Model = "",

    [Parameter(Mandatory = $false)]
    [string]$SystemPrompt = "",

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 180,

    [Parameter(Mandatory = $false)]
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
if (-not (Test-Path $projectRoot)) { $projectRoot = (Get-Location).Path }

try {
    # 1. Resolve Effective Prompt & Validate Context
    $finalPrompt = ""
    if ($PromptFile) {
        if (-not (Test-Path -LiteralPath $PromptFile)) {
            throw "FILE_NOT_FOUND: Specified PromptFile does not exist: $PromptFile"
        }
        $finalPrompt = [System.IO.File]::ReadAllText($PromptFile, [System.Text.Encoding]::UTF8)
    } elseif ($Prompt) {
        $finalPrompt = $Prompt
    } else {
        throw "MISSING_PROMPT: Either -Prompt or -PromptFile must be provided."
    }

    if ($ContextFile) {
        if (-not (Test-Path -LiteralPath $ContextFile)) {
            throw "FILE_NOT_FOUND: Specified ContextFile does not exist: $ContextFile"
        }
        $ctx = [System.IO.File]::ReadAllText($ContextFile, [System.Text.Encoding]::UTF8)
        $finalPrompt = "### CONTEXT SPECIFICATION:`n$ctx`n`n### TASK PROMPT:`n$finalPrompt"
    }

    # 2. Allocate Isolated Run Directory (PID & Timestamp Guarantees Zero-Collision)
    $runTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $runDir = Join-Path $projectRoot "scratch\runs\unified_${runTimestamp}_${PID}_$($Provider.ToLowerInvariant())"
    if (-not (Test-Path $runDir)) { New-Item -ItemType Directory -Path $runDir -Force | Out-Null }

    $targetPromptPath = Join-Path $runDir "prompt.txt"
    [System.IO.File]::WriteAllText($targetPromptPath, $finalPrompt, [System.Text.Encoding]::UTF8)

    # 3. Provider-Specific Execution Routing
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $outputText = ""
    $allLogs = ""
    $effectiveModel = $Model

    switch ($Provider) {
        "Codex" {
            if (-not $effectiveModel) {
                if ($finalPrompt -match "(?i)(labor|wage|pessimistic|concurrency|37|ddl)") {
                    $effectiveModel = "gpt-6.2-astra"
                } else {
                    $effectiveModel = "gpt-6.2-sol"
                }
            }
            if (-not $Quiet) { Write-Host "[AI-RUNNER] Launching OpenAI Codex ($effectiveModel, Timeout: ${TimeoutSeconds}s)..." -ForegroundColor Cyan }
            
            $binDir = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin"
            $codexExePath = $null
            if (Test-Path $binDir) {
                $found = Get-ChildItem -Path $binDir -Filter "codex.exe" -Recurse -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 1
                if ($found) { $codexExePath = $found.FullName }
            }
            if (-not $codexExePath) {
                $cmd = Get-Command "codex.exe" -ErrorAction SilentlyContinue
                if ($cmd) { $codexExePath = $cmd.Source }
            }
            if (-not $codexExePath) {
                throw "BINARY_NOT_FOUND: codex.exe binary not found in LocalAppData or PATH."
            }

            $codexOutFile = Join-Path $runDir "codex_last_msg.txt"
            $codexArgs = @(
                "exec",
                "--skip-git-repo-check",
                "--ignore-user-config",
                "--sandbox", "read-only",
                "--cd", $runDir,
                "--ephemeral",
                "--color", "never",
                "-o", $codexOutFile,
                "--model", $effectiveModel,
                "-"
            )
            
            $pinfo = New-Object System.Diagnostics.ProcessStartInfo
            $pinfo.FileName = $codexExePath
            $escapedArgs = $codexArgs | ForEach-Object {
                if ($_ -match '\s' -and -not ($_ -match '^".*"$')) { "`"$_`"" } else { $_ }
            }
            $pinfo.Arguments = ($escapedArgs -join " ")
            $pinfo.RedirectStandardInput = $true
            $pinfo.RedirectStandardOutput = $true
            $pinfo.RedirectStandardError = $true
            $pinfo.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
            $pinfo.StandardErrorEncoding = New-Object System.Text.UTF8Encoding($false)
            $pinfo.UseShellExecute = $false
            $pinfo.CreateNoWindow = $true

            $proc = [System.Diagnostics.Process]::Start($pinfo)
            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask = $proc.StandardError.ReadToEndAsync()

            # Async Stdin byte stream write to avoid deadlock and ANSI corruption
            $promptBytes = [System.Text.Encoding]::UTF8.GetBytes($finalPrompt)
            $writeTask = $proc.StandardInput.BaseStream.WriteAsync($promptBytes, 0, $promptBytes.Length)
            $writeCompleted = $writeTask.Wait($TimeoutSeconds * 1000)
            if (-not $writeCompleted) {
                try { & taskkill /T /F /PID $proc.Id 2>&1 | Out-Null } catch { try { $proc.Kill() } catch {} }
                throw "TIMEOUT: Stdin write to OpenAI Codex timed out after ${TimeoutSeconds}s."
            }
            $proc.StandardInput.BaseStream.Flush()
            $proc.StandardInput.Close()

            $waitSuccess = $proc.WaitForExit($TimeoutSeconds * 1000)
            if (-not $waitSuccess) {
                try {
                    & taskkill /T /F /PID $proc.Id 2>&1 | Out-Null
                } catch {
                    try { $proc.Kill() } catch {}
                }
                throw "TIMEOUT: OpenAI Codex exceeded ${TimeoutSeconds}s execution limit."
            }

            # Bounded wait for output streams to prevent indefinite hang on pipe handles (A01 defense)
            $streamsFinished = [System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 5000)
            if ($streamsFinished) {
                $stdout = $stdoutTask.Result
                $stderr = $stderrTask.Result
            } else {
                try { & taskkill /T /F /PID $proc.Id 2>&1 | Out-Null } catch { try { $proc.Kill() } catch {} }
                $stdout = if ($stdoutTask.IsCompleted) { $stdoutTask.Result } else { "[TIMEOUT_DRAINING_STDOUT]" }
                $stderr = if ($stderrTask.IsCompleted) { $stderrTask.Result } else { "[TIMEOUT_DRAINING_STDERR]" }
            }
            $allLogs = "$stdout`n$stderr"
            $procExit = $proc.ExitCode

            if ($procExit -ne 0) {
                throw "CODEX_PROCESS_ERROR: codex.exe exited with non-zero code $procExit. Details: $stderr"
            }
            
            if (Test-Path $codexOutFile) {
                $outputText = [System.IO.File]::ReadAllText($codexOutFile, [System.Text.Encoding]::UTF8).Trim()
            }
            if ([string]::IsNullOrWhiteSpace($outputText)) {
                throw "EMPTY_OUTPUT: OpenAI Codex finished with empty response."
            }
        }
        "Claude" {
            if (-not $effectiveModel) { $effectiveModel = "claude-sonnet-5-5" }
            if (-not $Quiet) { Write-Host "[AI-RUNNER] Launching Anthropic Claude ($effectiveModel)..." -ForegroundColor Cyan }
            
            $apiKey = $env:ANTHROPIC_API_KEY
            if (-not $apiKey) { $apiKey = [System.Environment]::GetEnvironmentVariable("ANTHROPIC_API_KEY", "User") }
            if (-not $apiKey) { $apiKey = [System.Environment]::GetEnvironmentVariable("ANTHROPIC_API_KEY", "Machine") }
            if (-not $apiKey) { throw "AUTH_ERROR: ANTHROPIC_API_KEY not configured." }

            $defaultSystemPrompt = "You are a concise regulatory and statutory code auditor. Output strictly structured Markdown tables of findings (| Finding ID | Severity | Item | Flaw Analysis | Concrete Code/Rule Fix |) followed by a final line: 'VERDICT: PASS' or 'VERDICT: FAIL'. Keep entire output compact and strictly under 2500 tokens. Never output conversational filler or long discursive essays."
            $effectiveSystem = if ($SystemPrompt) { $SystemPrompt } else { $defaultSystemPrompt }

            $reqObj = @{
                model = $effectiveModel
                max_tokens = 8192
                thinking = @{
                    type = "adaptive"
                }
                system = $effectiveSystem
                messages = @(@{ role = "user"; content = $finalPrompt })
            }
            $requestBody = $reqObj | ConvertTo-Json -Depth 5
            $utf8Body = [System.Text.Encoding]::UTF8.GetBytes($requestBody)

            Add-Type -AssemblyName System.Net.Http
            $client = New-Object System.Net.Http.HttpClient
            $client.Timeout = [System.TimeSpan]::FromSeconds($TimeoutSeconds)
            
            $reqMsg = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, "https://api.anthropic.com/v1/messages")
            $reqMsg.Headers.Add("x-api-key", $apiKey)
            $reqMsg.Headers.Add("anthropic-version", "2023-06-01")
            $stringContent = New-Object System.Net.Http.StringContent($requestBody, [System.Text.Encoding]::UTF8, "application/json")
            $reqMsg.Content = $stringContent

            try {
                $httpTask = $client.SendAsync($reqMsg)
                $httpResponse = $httpTask.GetAwaiter().GetResult()
                $respBytes = $httpResponse.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
                $rawJson = [System.Text.Encoding]::UTF8.GetString($respBytes)
                
                if (-not $httpResponse.IsSuccessStatusCode) {
                    throw "CLAUDE_HTTP_ERROR: StatusCode: $($httpResponse.StatusCode). Details: $rawJson"
                }
                $response = $rawJson | ConvertFrom-Json
            } catch {
                throw "CLAUDE_API_ERROR: $($_.Exception.Message)"
            } finally {
                $client.Dispose()
            }
            $textBlocks = @($response.content | Where-Object { $_.type -eq "text" } | Select-Object -ExpandProperty text -ErrorAction SilentlyContinue)
            if ($textBlocks.Count -gt 0) {
                $outputText = ($textBlocks -join "`n").Trim()
            } elseif ($response.content.text) {
                $outputText = $response.content.text.Trim()
            }
            $allLogs = $response | ConvertTo-Json -Depth 5

            # Immediately preserve raw output to avoid loss on any parsing or truncation failure
            if ($outputText) { [System.IO.File]::WriteAllText((Join-Path $runDir "output_raw.txt"), $outputText, [System.Text.Encoding]::UTF8) }
            if ($allLogs) { [System.IO.File]::WriteAllText((Join-Path $runDir "raw_response.json"), $allLogs, [System.Text.Encoding]::UTF8) }

            # Stop Reason Validation: Strictly require confirmed termination
            $stopReason = $response.stop_reason
            if ($stopReason -eq "max_tokens") {
                throw "CLAUDE_RESPONSE_TRUNCATED: Anthropic Claude response reached max_tokens (8192) and was truncated. Incomplete audit output is rejected (Fail-Closed, G1 Guard)."
            } elseif (-not $stopReason -or ($stopReason -ne "end_turn" -and $stopReason -ne "stop_sequence")) {
                throw "CLAUDE_ABNORMAL_STOP: Response stopped abnormally or incomplete with reason: '$stopReason'"
            }

            if ([string]::IsNullOrWhiteSpace($outputText)) {
                throw "EMPTY_OUTPUT: Anthropic Claude returned an empty response body."
            }
        }
        "Qwen" {
            if (-not $effectiveModel) { $effectiveModel = "qwen27b:latest" }
            if (-not $Quiet) { Write-Host "[AI-RUNNER] Launching Local Qwen 27B ($effectiveModel via RTX 5070 Ti)..." -ForegroundColor Cyan }

            $hermesScript = Join-Path $env:USERPROFILE ".gemini\scripts\audit_with_hermes.ps1"
            if (-not (Test-Path $hermesScript)) {
                throw "SCRIPT_NOT_FOUND: Global audit engine not found: $hermesScript"
            }
            $qwenOut = Join-Path $runDir "qwen_output.md"
            if (Test-Path $qwenOut) { Remove-Item $qwenOut -Force }

            $hermesArgs = @("-TargetFile", $targetPromptPath, "-OutputFile", $qwenOut, "-Model", $effectiveModel, "-AuditMode", "STANDARD")
            if (-not [string]::IsNullOrWhiteSpace($SystemPrompt)) {
                $hermesArgs += @("-SystemPromptOverride", $SystemPrompt)
            }
            & powershell -ExecutionPolicy Bypass -File $hermesScript @hermesArgs
            $qwenExit = $LASTEXITCODE
            if ($qwenExit -ne 0) {
                throw "QWEN_EXECUTION_ERROR: audit_with_hermes.ps1 failed with exit code $qwenExit"
            }

            if (Test-Path $qwenOut) {
                $outputText = [System.IO.File]::ReadAllText($qwenOut, [System.Text.Encoding]::UTF8)
                $outputText = $outputText.Replace($projectRoot, "<WORKSPACE_ROOT>").Replace($env:USERPROFILE, "<USER_HOME>")
            }
            if ([string]::IsNullOrWhiteSpace($outputText)) {
                throw "EMPTY_OUTPUT: Local Qwen 27B produced empty audit output."
            }
        }
    }
    $sw.Stop()

    # Legacy Compatibility Mirroring (Atomic Write)
    $legacyDir = Join-Path $projectRoot "scratch\test_runs"
    if (-not (Test-Path $legacyDir)) { New-Item -ItemType Directory -Path $legacyDir -Force | Out-Null }
    switch ($Provider) {
        "Codex" {
            $legacyFile = Join-Path $legacyDir "codex_last_msg.txt"
            $tmpLegacy = "$legacyFile.tmp.$PID"
            [System.IO.File]::WriteAllText($tmpLegacy, $outputText, [System.Text.Encoding]::UTF8)
            Move-Item $tmpLegacy $legacyFile -Force
        }
        "Claude" {
            $legacyFile = Join-Path $legacyDir "claude_live.log"
            $tmpLegacy = "$legacyFile.tmp.$PID"
            [System.IO.File]::WriteAllText($tmpLegacy, $outputText, [System.Text.Encoding]::UTF8)
            Move-Item $tmpLegacy $legacyFile -Force
        }
        "Qwen" {
            $mutexName = "Global\KintaiQwenLedgerMutex"
            $mutex = $null
            $hasMutex = $false
            try {
                $mutex = New-Object System.Threading.Mutex($false, $mutexName)
                $hasMutex = $mutex.WaitOne(3000)
                $legacyFile = Join-Path $legacyDir "qwen_live.log"
                $tmpLegacy = "$legacyFile.tmp.$PID"
                [System.IO.File]::WriteAllText($tmpLegacy, $outputText, [System.Text.Encoding]::UTF8)
                Move-Item $tmpLegacy $legacyFile -Force
            } catch {
                $legacyFile = Join-Path $legacyDir "qwen_live.log"
                $tmpLegacy = "$legacyFile.tmp.$PID"
                [System.IO.File]::WriteAllText($tmpLegacy, $outputText, [System.Text.Encoding]::UTF8)
                Move-Item $tmpLegacy $legacyFile -Force
            } finally {
                if ($hasMutex -and $mutex -ne $null) {
                    $mutex.ReleaseMutex()
                    $mutex.Dispose()
                }
            }
        }
    }

    # 4. Rigorous Structured Verdict & Findings Extraction (Fail-Closed)
    $detectedVerdict = "HOLD"
    $extractedFindings = @()
    $structuredVerdictFound = $false

    # Priority 1: Structured JSON Block (Minimal 5-Token {"verdict": "PASS"} Contract or Full Findings Schema)
    $jsonCandidate = $null
    if ($outputText -match '(?s)```json\s*(\{[\s\S]*?\})\s*```') {
        $jsonCandidate = $matches[1]
    } elseif ($outputText -match '(?s)(?:^|\n)\s*(\{[\s\r\n]*"(?:verdict|findings)"[\s\S]*?\})\s*(?:$|\n)') {
        $jsonCandidate = $matches[1]
    }

    if ($jsonCandidate) {
        try {
            $parsedJson = $jsonCandidate | ConvertFrom-Json
            if ($null -ne $parsedJson.PSObject.Properties['findings']) {
                $extractedFindings = @($parsedJson.findings)
            } else {
                $extractedFindings = @()
            }
            if ($parsedJson.verdict) {
                $vStr = $parsedJson.verdict.ToString().ToUpperInvariant()
                if ($vStr -match '^(PASS|WARN|HOLD|FAIL)$') {
                    $detectedVerdict = $vStr
                    $structuredVerdictFound = $true
                }
            } elseif ($extractedFindings.Count -eq 0) {
                $detectedVerdict = "PASS"
                $structuredVerdictFound = $true
            } else {
                $detectedVerdict = "WARN"
                $structuredVerdictFound = $true
            }
        } catch {}
    }

    # Priority 2: Text Verdict Regex (Search only if structured verdict was NOT present)
    if (-not $structuredVerdictFound) {
        $linesRev = $outputText -split "`r?`n"
        [array]::Reverse($linesRev)
        foreach ($l in $linesRev) {
            if ($l -match '(?i)(?:Stage\s*\d+\s*)?(?:Verdict|Result|\u7DCF\u5408\u5224\u5B9A|\u5224\u5B9A)\s*[-:*= ]+\s*\b(PASS|WARN|HOLD|FAIL)\b') {
                $detectedVerdict = $matches[1].ToUpperInvariant()
                $structuredVerdictFound = $true
                break
            }
        }
    }

    # Severity Audit: P0/P1 Presence Absolutely Forces FAIL (Executed before missing-verdict throw)
    $p0p1Count = 0
    foreach ($f in $extractedFindings) {
        $sev = "INFO"
        $fVerdict = "FAIL"
        if ($f -ne $null) {
            if ($f -is [PSCustomObject] -and $f.PSObject.Properties['severity']) {
                $sev = $f.severity.ToString().ToUpperInvariant()
            } elseif ($f -is [System.Collections.IDictionary] -and $f.Contains('severity')) {
                $sev = $f['severity'].ToString().ToUpperInvariant()
            }
            if ($f -is [PSCustomObject] -and $f.PSObject.Properties['verdict']) {
                $fVerdict = $f.verdict.ToString().ToUpperInvariant()
            } elseif ($f -is [System.Collections.IDictionary] -and $f.Contains('verdict')) {
                $fVerdict = $f['verdict'].ToString().ToUpperInvariant()
            }
        }
        if (($sev -eq "P0" -or $sev -eq "P1") -and ($fVerdict -ne "PASS" -and $fVerdict -ne "RESOLVED")) { $p0p1Count++ }
    }

    if ($p0p1Count -gt 0) {
        if (-not $Quiet) { Write-Host "  -> [AUDIT OVERRIDE] $p0p1Count high-severity findings detected. Forcing FAIL verdict." -ForegroundColor Yellow }
        $detectedVerdict = "FAIL"
        $structuredVerdictFound = $true
    }

    if (-not $structuredVerdictFound) {
        throw "STRUCTURED_VERDICT_MISSING: Model output did not contain an identifiable structured verdict."
    }

    # 5. Archive and Generate Sidecar via Helper
    $modelSafe = $effectiveModel -replace '[:/\\*?"<>|]', '_'
    $permanentRunDir = Join-Path $projectRoot "audit\runs\${runTimestamp}_${PID}_$($Provider.ToLowerInvariant())_${modelSafe}"
    if (-not (Test-Path $permanentRunDir)) { New-Item -ItemType Directory -Path $permanentRunDir -Force | Out-Null }

    $permReport = Join-Path $permanentRunDir "report.txt"
    $permRaw = Join-Path $permanentRunDir "raw_response.json"
    [System.IO.File]::WriteAllText($permReport, $outputText, [System.Text.Encoding]::UTF8)
    if ($allLogs) { [System.IO.File]::WriteAllText($permRaw, $allLogs, [System.Text.Encoding]::UTF8) }

    $helperModule = Join-Path $scriptDir "AuditVerdictHelper.psm1"
    if (Test-Path $helperModule) {
        Import-Module $helperModule -Force
        $targetRawPath = if (Test-Path $permRaw) { $permRaw } else { $permReport }
        New-AuditVerdictSidecar -OutputDir $permanentRunDir `
            -Auditor $Provider.ToLowerInvariant() `
            -RunId "${runTimestamp}_$($Provider.ToLowerInvariant())" `
            -RawResponsePath $targetRawPath `
            -Verdict $detectedVerdict `
            -Findings $extractedFindings | Out-Null
    }

    # Atomic Manifest Marker (Guarantees Write Completion)
    $manifest = [ordered]@{
        schema         = "audit-manifest/v1"
        run_id         = "${runTimestamp}_${PID}_$($Provider.ToLowerInvariant())"
        auditor        = $Provider.ToLowerInvariant()
        model          = $effectiveModel
        verdict        = $detectedVerdict
        findings_count = $extractedFindings.Count
        created_utc    = [DateTime]::UtcNow.ToString("o")
        report_sha256  = (Get-FileHash -LiteralPath $permReport -Algorithm SHA256).Hash
    }
    $manifestPath = Join-Path $permanentRunDir "manifest.json"
    [System.IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 3), [System.Text.Encoding]::UTF8)

    # Automatic Garbage Collection of Stale Scratch Runs (>7 days)
    try {
        $scratchRunsDir = Join-Path $projectRoot "scratch\runs"
        if (Test-Path $scratchRunsDir) {
            $cutoff = (Get-Date).AddDays(-7)
            Get-ChildItem -Path $scratchRunsDir -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.CreationTime -lt $cutoff } |
                Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch {}

    $dailyAuditLogDir = Join-Path $projectRoot "docs"
    if (Test-Path $dailyAuditLogDir) {
        $dailyAuditLogPath = Join-Path $dailyAuditLogDir "daily_audit_temp.log"
        $targetLabel = if ($ContextFile) { [System.IO.Path]::GetFileName($ContextFile) } else { "inline-prompt" }
        $logEntry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | AI-RUNNER | $targetLabel | $($Provider.ToLowerInvariant()):$Model | $($sw.Elapsed.TotalSeconds.ToString('F2'))s | Verdict:$detectedVerdict | Findings:$($extractedFindings.Count)]`r`n"
        [System.IO.File]::AppendAllText($dailyAuditLogPath, $logEntry, [System.Text.Encoding]::UTF8)
    }

    if (-not $Quiet) {
        Write-Host "[AI-RUNNER] Completed in $($sw.Elapsed.TotalSeconds.ToString('F1'))s | Verdict: $detectedVerdict | Artifact: $permanentRunDir" -ForegroundColor Green
    }

    # 6. Terminal Exit Code Contract (Fail-Closed)
    if ($detectedVerdict -eq "PASS" -or $detectedVerdict -eq "WARN") {
        exit 0
    } else {
        exit 1
    }

} catch {
    Write-Host "[AI-RUNNER ERROR] $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
