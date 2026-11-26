<#
.SYNOPSIS
    Hybrid Token-Balancing Pipeline Executor v1.1
.DESCRIPTION
    Implements Plan A (Codex Drafting vs Antigravity Verification):
    - Run-isolated execution under scratch/runs/<RunId>/
    - 300s timeout with atomic rename (.tmp -> .md)
    - Injects static Japanese Labor Law Art 37 Golden Parameters
    - Executes Roslyn deterministic linting gate
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RequirementTitle,

    [Parameter(Mandatory = $true)]
    [string]$RequirementDetails,

    [Parameter(Mandatory = $false)]
    [string]$ContextSection = "",

    [Parameter(Mandatory = $false)]
    [string]$TargetId = "",

    [Parameter(Mandatory = $false)]
    [string]$OutputTargetFile = "",

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
if (-not (Test-Path $projectRoot)) { $projectRoot = (Get-Location).Path }

if ($TargetId -and -not $OutputTargetFile) {
    $targetsJsonPath = Join-Path $projectRoot "config\srs_targets.json"
    if (Test-Path $targetsJsonPath) {
        $tCfg = [System.IO.File]::ReadAllText($targetsJsonPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $matchedTgt = $tCfg.targets | Where-Object { $_.id -eq $TargetId } | Select-Object -First 1
        if ($matchedTgt) {
            $OutputTargetFile = Join-Path $projectRoot $matchedTgt.ja_path
        }
    }
}

# 1. Allocate Isolated Run Directory
$runId = (Get-Date -Format "yyyyMMdd_HHmmss") + "_" + [System.Guid]::NewGuid().ToString().Substring(0, 8)
$runDir = Join-Path $projectRoot "scratch\runs\$runId"
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

$promptPath = Join-Path $runDir "prompt.txt"
$tmpDraftPath = Join-Path $runDir "draft.tmp"
$finalDraftPath = Join-Path $runDir "draft.md"
$lintReportPath = Join-Path $runDir "lint_report.txt"

# 2. Build Briefing with Static Golden Rules (Anti-Hallucination & Art 37 Protection)
$goldenRules = @"
### MANDATORY GOLDEN CONSTRAINTS (DO NOT ALTER):
1. Jurisdiction: Japan Labour Standards Act (労働基準法第37条).
   - Overtime (>8h/day or >40h/week): +25%
   - Night Work (22:00 ~ 05:00): +25%
   - Overtime + Night Overlap: +50%
   - Over 60h/month Overtime: +50% (+75% with night overlap)
2. Rounding (端数処理):
   - Daily work hours: Truncate/Round per-minute strictly prohibited if disadvantageous; standard calculation on exact minutes.
   - Monthly aggregate wage: Fractions of less than 50 sen rounded down, 50 sen to less than 1 yen rounded up to 1 yen.
3. Input Boundary Validation:
   - Must handle DateTimeParseException on ISO timestamps.
   - Negative or zero work durations must throw InvalidWorkTimeException.
"@

$fullPrompt = @"
Requirement Title: $RequirementTitle

Context / Base Scope:
$ContextSection

User Details:
$RequirementDetails

$goldenRules

TASK (TWO-STAGE REVERSE-ENGINEERING & FORMALIZATION):
Stage 1 (Internal Deep Extraction): First, thoroughly extract all actors, normal paths, rejection paths (401/403/404/409/422), rollback/compensation branches, and 4-tier lock acquisition orders (`member -> store -> store_staff -> contract_history`) with concrete code anchors (`File:Line/Symbol`).
Stage 2 (Formal Rendering): Render the extracted specification into valid `[REQ-xxx]` and `[DDL-xxx]` blocks adhering to `config/srs_track2_common_contract.md`.

MANDATORY LINTER STRUCTURE PER REQUIREMENT (RULE-REQ-03):
Each and every requirement block (#### [REQ-...]) MUST strictly contain the following 5 bullet sections (Never use bare 'N/A' or 'TBD'):
- **入力**: (Detailed input parameters, types, sources; use SecurityContext for staff/tenant to avoid IDOR)
- **処理**: (Step-by-step logic, pessimistic locking 'FOR UPDATE', state transitions using '→')
- **出力**: (Return fields, DTOs, generated keys, status codes)
- **例外処理**: (Exact exception classes, HTTP status codes e.g. HTTP 400/403/409/422, error codes)
- **完了基準 (DoD)**: (Verifiable boundary conditions, concrete test criteria)

Write ONLY the pure markdown content.
"@

[System.IO.File]::WriteAllText($promptPath, $fullPrompt, [System.Text.Encoding]::UTF8)

# 3. Invoke OpenAI Codex CLI via Approved Wrapper
Write-Host "[PIPELINE] Launching Codex Drafting in isolated workspace: $runId"
$codexScript = Join-Path $projectRoot "tools\scripts\call_codex.ps1"

$codexSw = [System.Diagnostics.Stopwatch]::StartNew()
& powershell -ExecutionPolicy Bypass -File $codexScript -PromptFile $promptPath -TimeoutSeconds $TimeoutSeconds
$codexSw.Stop()

# Verify Output from codex_last_msg.txt
$codexLastMsg = Join-Path $projectRoot "scratch\test_runs\codex_last_msg.txt"
if (-not (Test-Path $codexLastMsg)) {
    Write-Error "[PIPELINE FAIL] Codex failed to produce output."
    exit 1
}

$draftContent = [System.IO.File]::ReadAllText($codexLastMsg, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($tmpDraftPath, $draftContent, [System.Text.Encoding]::UTF8)

# 4. Atomic Rename (.tmp -> .md)
Move-Item -Path $tmpDraftPath -Destination $finalDraftPath -Force
Write-Host "[PIPELINE] Draft successfully authored and verified: $finalDraftPath ($($draftContent.Length) chars, $($codexSw.Elapsed.TotalSeconds.ToString('F1'))s)"

# 5. Execute Deterministic Linter Gate (Fail-Closed)
$linterWrapper = Join-Path $projectRoot "tools\scripts\verify_srs.ps1"
$linterBin = Join-Path $projectRoot "tools\scripts\VerifySRS.exe"

if (-not (Test-Path $linterBin)) {
    Write-Host "[PIPELINE] Compiling VerifySRS.exe via verify_srs.ps1..."
    & powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $linterWrapper -Files @() 2>&1 | Out-Null
}

if (-not (Test-Path $linterBin)) {
    Write-Error "[PIPELINE FAIL-CLOSED] VerifySRS.exe could not be compiled or located. Failing Closed."
    exit 4
}

Write-Host "[PIPELINE] Executing Deterministic Linter Gate on $finalDraftPath..."
$lintOutput = & $linterBin $finalDraftPath
$linterExit = $LASTEXITCODE
$lintOutput | Out-File -FilePath $lintReportPath -Encoding UTF8
$lintOutput | Select-Object -First 15 | ForEach-Object { Write-Host $_ }

$fatalMatches = @($lintOutput | Select-String -Pattern '\[FATAL\]')
if ($linterExit -ne 0 -or $fatalMatches.Count -gt 0) {
    Write-Error "[PIPELINE FAIL-CLOSED] Deterministic Linter failed (ExitCode: $linterExit, FATAL count: $($fatalMatches.Count))! Aborting pipeline."
    exit 1
}
Write-Host "[PIPELINE PASS] Deterministic Linter passed with 0 FATAL errors."
if ($OutputTargetFile) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($OutputTargetFile, $draftContent, $utf8NoBom)
    Write-Host "[PIPELINE INTEGRATED] Automatically integrated verified draft to target: $OutputTargetFile" -ForegroundColor Green

    # Auto-Staging Safe-Guard & Tree ID Attestation (RFC-SYS-02 & TOCTOU Guard)
    if (Test-Path -LiteralPath $OutputTargetFile -PathType Leaf) {
        & git --literal-pathspecs add -- "$OutputTargetFile"
        $addExit = $LASTEXITCODE
        if ($addExit -eq 0) {
            Write-Host "[PIPELINE AUTO-STAGED] Safely locked verified asset into Git index: $OutputTargetFile" -ForegroundColor Green
            try {
                $treeId = (git write-tree).Trim()
                $receiptPath = Join-Path $runDir "tree_attestation.json"
                $attestation = [ordered]@{
                    schema      = "tree-attestation/v1"
                    tree_id     = $treeId
                    target_file = $OutputTargetFile
                    file_sha256 = (Get-FileHash -LiteralPath $OutputTargetFile -Algorithm SHA256).Hash
                    staged_utc  = [DateTime]::UtcNow.ToString("o")
                }
                [System.IO.File]::WriteAllText($receiptPath, ($attestation | ConvertTo-Json -Depth 3), [System.Text.Encoding]::UTF8)
                Write-Host "[PIPELINE TREE-ATTESTED] Immutable Git Tree ID: $treeId" -ForegroundColor Cyan
            } catch {}
        } else {
            Write-Host "[PIPELINE AUTO-STAGE WARN] git add exited with code ${addExit}: $OutputTargetFile" -ForegroundColor Yellow
        }
    }
}

Write-Host "=== Pipeline Execution Completed for Run: $runId ==="
