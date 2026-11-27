<#
.SYNOPSIS
    KINTAI 4-Role Local AI Multi-Auditor Pipeline (run_local_multi_audit.ps1)
.DESCRIPTION
    Executes targeted, specialized audit passes on Local Qwen 27B (Remote RTX 5070 Ti)
    using intelligent diff-based file routing across 4 specialized domain roles:
    1. Role 1: IDOR & RBAC Security (audit_idor_security.md)
    2. Role 2: Business State Machine & Idempotency (audit_state_machine.md)
    3. Role 3: SQL & Concurrency Lock (audit_concurrency_lock.md)
    4. Role 4: Labor Standards Act Art. 37 Precision (audit_labor_law_37.md)

    Hardened with strict Fail-Closed engine contracts:
    - Non-zero exit on auditor timeout, crash, empty report, or JSON schema failure.
    - Captures untracked (??) and staged/unstaged changes via git status --porcelain.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string[]]$Files = @(),

    [Parameter(Mandatory = $false)]
    [switch]$All = $false,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir = "",

    [Parameter(Mandatory = $false)]
    [string]$Model = "qwen3.8:27b"
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
if (-not (Test-Path (Join-Path $projectRoot "build.gradle"))) {
    $projectRoot = (Get-Location).Path
}

$timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$runGuid = [guid]::NewGuid().ToString().Substring(0, 8)
if (-not $OutputDir) {
    $OutputDir = Join-Path $projectRoot "scratch\runs\multi_audit_${timestamp}_${runGuid}"
}
if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }

Write-Host "==========================================================================" -ForegroundColor Cyan
Write-Host " [KINTAI LOCAL MULTI-AUDITOR v1.1] Hardened 4-Role Pipeline" -ForegroundColor Cyan
Write-Host " Engine  : $Model (Remote RTX 5070 Ti, think=false)" -ForegroundColor Cyan
Write-Host " Output  : $OutputDir" -ForegroundColor Cyan
Write-Host "==========================================================================" -ForegroundColor Cyan

# 1. Target File Resolution (including untracked and staged files)
$targetFiles = @()
if ($Files -and $Files.Count -gt 0) {
    foreach ($f in $Files) {
        $p = if ([System.IO.Path]::IsPathRooted($f)) { $f } else { Join-Path $projectRoot $f }
        if (Test-Path $p) { $targetFiles += (Resolve-Path $p).Path }
    }
} elseif ($All) {
    $targetFiles = @(Get-ChildItem -Path (Join-Path $projectRoot "src") -Recurse -File | 
        Where-Object { $_.FullName -match '\.(java|xml|sql)$' } | 
        Select-Object -ExpandProperty FullName)
} else {
    try {
        # 1.1 Diff against HEAD
        $rawDiff = & git -C $projectRoot diff --name-only HEAD
        foreach ($line in ($rawDiff -split "`r?`n")) {
            $trimmed = $line.Trim()
            if ($trimmed -and ($trimmed -match '\.(java|xml|sql)$')) {
                $p = Join-Path $projectRoot $trimmed
                if (Test-Path $p) { $targetFiles += (Resolve-Path $p).Path }
            }
        }

        # 1.2 Untracked and staged files via git status --porcelain
        $rawStatus = & git -C $projectRoot status --porcelain
        foreach ($statusLine in ($rawStatus -split "`r?`n")) {
            if ($statusLine.Length -ge 4) {
                $statusFile = $statusLine.Substring(3).Trim().Trim('"')
                if ($statusFile -match '\.(java|xml|sql)$') {
                    $p = Join-Path $projectRoot $statusFile
                    if (Test-Path $p) { $targetFiles += (Resolve-Path $p).Path }
                }
            }
        }
    } catch {
        Write-Warning "Git detection encountered: $($_.Exception.Message)"
    }
}

$targetFiles = @($targetFiles | Select-Object -Unique)
if ($targetFiles.Count -eq 0) {
    Write-Host "[NOTICE] No Java/XML/SQL files to audit. Terminating cleanly." -ForegroundColor Yellow
    exit 0
}

Write-Host "Target files detected: $($targetFiles.Count) files" -ForegroundColor Cyan

# 2. File Routing by Role
$roleAssignments = [ordered]@{
    "ROLE_1_SECURITY" = [ordered]@{
        Name       = "IDOR & RBAC Security"
        PromptFile = Join-Path $projectRoot "tools\prompts\audit_idor_security.md"
        Files      = @()
    }
    "ROLE_2_STATE_MACHINE" = [ordered]@{
        Name       = "Business State Machine & Idempotency"
        PromptFile = Join-Path $projectRoot "tools\prompts\audit_state_machine.md"
        Files      = @()
    }
    "ROLE_3_SQL_LOCK" = [ordered]@{
        Name       = "SQL & Concurrency Lock"
        PromptFile = Join-Path $projectRoot "tools\prompts\audit_concurrency_lock.md"
        Files      = @()
    }
    "ROLE_4_LABOR_LAW" = [ordered]@{
        Name       = "Labor Standards Act Art. 37 Precision"
        PromptFile = Join-Path $projectRoot "tools\prompts\audit_labor_law_37.md"
        Files      = @()
    }
}

foreach ($tf in $targetFiles) {
    $content = [System.IO.File]::ReadAllText($tf, [System.Text.Encoding]::UTF8)
    $fileName = [System.IO.Path]::GetFileName($tf)

    # Role 1: Security
    if ($fileName -match 'Controller\.java$' -or $fileName -match 'Security' -or 
        $content -match '@PreAuthorize' -or $content -match 'storeId' -or $content -match '@RestController') {
        $roleAssignments["ROLE_1_SECURITY"].Files += $tf
    }

    # Role 2: State Machine
    if ($fileName -match 'Attendance' -or $fileName -match 'Shift' -or $fileName -match 'Punch' -or
        $content -match 'PunchStatus' -or $content -match 'ShiftStatus' -or $content -match 'Status') {
        $roleAssignments["ROLE_2_STATE_MACHINE"].Files += $tf
    }

    # Role 3: SQL & Concurrency Lock
    if ($fileName -match '\.xml$' -or $fileName -match 'Mapper' -or $content -match '@Transactional' -or 
        $content -match 'FOR UPDATE' -or $content -match '<select' -or $content -match '<update') {
        $roleAssignments["ROLE_3_SQL_LOCK"].Files += $tf
    }

    # Role 4: Labor Law 37
    if ($fileName -match 'Payroll' -or $fileName -match 'Wage' -or $fileName -match 'Calc' -or
        $content -match 'BigDecimal' -or $content -match 'RoundingMode' -or $content -match 'overtime') {
        $roleAssignments["ROLE_4_LABOR_LAW"].Files += $tf
    }
}

# 3. Execution of Active Roles via audit_with_hermes.ps1
$auditScript = "C:\Users\klad3\.gemini\scripts\audit_with_hermes.ps1"
if (-not (Test-Path $auditScript)) {
    throw "Global audit script not found: $auditScript"
}

$allFindings = New-Object System.Collections.Generic.List[PSObject]
$engineFailures = New-Object System.Collections.Generic.List[string]
$roleMetrics = [ordered]@{}

foreach ($roleKey in $roleAssignments.Keys) {
    $roleInfo = $roleAssignments[$roleKey]
    $rFiles = @($roleInfo.Files | Select-Object -Unique)
    if ($rFiles.Count -eq 0) {
        Write-Host "`n>>> [SKIPPED] $($roleInfo.Name): No matching files in diff." -ForegroundColor DarkGray
        continue
    }

    Write-Host "`n>>> [AUDIT] Launching $($roleInfo.Name) ($($rFiles.Count) files)..." -ForegroundColor Yellow
    
    # Create role bundle
    $roleBundleDir = Join-Path $OutputDir $roleKey
    New-Item -ItemType Directory -Path $roleBundleDir -Force | Out-Null
    $bundleFile = Join-Path $roleBundleDir "target_bundle.java"

    $sb = New-Object System.Text.StringBuilder
    foreach ($rf in $rFiles) {
        $rel = $rf.Replace($projectRoot, "").TrimStart("\/")
        $sb.AppendLine("/* ========================================================================= */") | Out-Null
        $sb.AppendLine("/* FILE: $rel */") | Out-Null
        $sb.AppendLine("/* ========================================================================= */") | Out-Null
        $sb.AppendLine([System.IO.File]::ReadAllText($rf, [System.Text.Encoding]::UTF8)) | Out-Null
        $sb.AppendLine("") | Out-Null
    }
    [System.IO.File]::WriteAllText($bundleFile, $sb.ToString(), [System.Text.Encoding]::UTF8)

    $rolePrompt = [System.IO.File]::ReadAllText($roleInfo.PromptFile, [System.Text.Encoding]::UTF8)
    $roleOutputFile = Join-Path $roleBundleDir "report.md"

    $passStart = Get-Date
    try {
        & powershell -ExecutionPolicy Bypass -File $auditScript `
            -TargetFile $bundleFile `
            -OutputDir $roleBundleDir `
            -OutputFile $roleOutputFile `
            -SystemPromptOverride $rolePrompt `
            -Model $Model
        
        $hermesExit = $LASTEXITCODE
        if ($hermesExit -ne 0) {
            $errMsg = "$($roleInfo.Name) execution returned non-zero exit code: $hermesExit"
            Write-Host "  [FAIL] $errMsg" -ForegroundColor Red
            $engineFailures.Add($errMsg)
            $roleMetrics[$roleInfo.Name] = "FAILED (Exit $hermesExit)"
            continue
        }

        $duration = [Math]::Round(((Get-Date) - $passStart).TotalSeconds, 2)
        $roleMetrics[$roleInfo.Name] = "${duration}s ($($rFiles.Count) files)"
        Write-Host "  [DONE] $($roleInfo.Name) completed in ${duration}s" -ForegroundColor Green

        # Harvest findings and validate JSON schema strictly (Fail-Closed)
        if (-not (Test-Path $roleOutputFile)) {
            $errMsg = "$($roleInfo.Name) produced no output report file."
            $engineFailures.Add($errMsg)
            continue
        }

        $rawText = [System.IO.File]::ReadAllText($roleOutputFile, [System.Text.Encoding]::UTF8)
        if ($rawText -match '(?s)```json\s*(\[\s*\{.*?\}\s*\])\s*```') {
            try {
                $parsed = $matches[1] | ConvertFrom-Json
                foreach ($item in $parsed) {
                    $allFindings.Add($item)
                }
            } catch {
                $errMsg = "$($roleInfo.Name) JSON schema parsing failed: $($_.Exception.Message)"
                Write-Host "  [FAIL] $errMsg" -ForegroundColor Red
                $engineFailures.Add($errMsg)
            }
        } elseif ($rawText -match '(?s)```json\s*\[\s*\]\s*```' -or $rawText -match '(?i)verdict[\s\*:]+pass') {
            Write-Host "  [CLEAN] $($roleInfo.Name) returned 0 findings (VERDICT: PASS)." -ForegroundColor Green
        } else {
            $errMsg = "$($roleInfo.Name) output missing structured JSON block and clean verdict."
            Write-Host "  [FAIL] $errMsg" -ForegroundColor Red
            $engineFailures.Add($errMsg)
        }
    } catch {
        $errMsg = "$($roleInfo.Name) invocation exception: $($_.Exception.Message)"
        Write-Host "  [FAIL] $errMsg" -ForegroundColor Red
        $engineFailures.Add($errMsg)
        $roleMetrics[$roleInfo.Name] = "FAILED"
    }
}

# 4. Generate Master Report
$reportFile = Join-Path $OutputDir "unified_audit_report.md"
$rep = New-Object System.Text.StringBuilder
$rep.AppendLine("# KINTAI Local Multi-Auditor Unified Report") | Out-Null
$rep.AppendLine("**Generated:** $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | **Model:** $Model") | Out-Null
$rep.AppendLine("") | Out-Null
$rep.AppendLine("## Execution Summary") | Out-Null
$rep.AppendLine("| Auditor Role | Status / Duration | Files Analyzed |") | Out-Null
$rep.AppendLine("|---|---|---|") | Out-Null
foreach ($k in $roleMetrics.Keys) {
    $rep.AppendLine("| $k | $($roleMetrics[$k]) | - |") | Out-Null
}
$rep.AppendLine("") | Out-Null

$criticalCount = 0
$highCount = 0
$mediumCount = 0
$lowCount = 0

foreach ($f in $allFindings) {
    $sev = if ($f.severity) { $f.severity.ToString().ToUpperInvariant() } else { "INFO" }
    switch ($sev) {
        "CRITICAL" { $criticalCount++ }
        "P0"       { $criticalCount++ }
        "HIGH"     { $highCount++ }
        "P1"       { $highCount++ }
        "MEDIUM"   { $mediumCount++ }
        "P2"       { $mediumCount++ }
        default    { $lowCount++ }
    }
}

$rep.AppendLine("## Findings Overview") | Out-Null
$rep.AppendLine("- **Total Findings**: $($allFindings.Count)") | Out-Null
$rep.AppendLine("- **Critical**: $criticalCount | **High**: $highCount | **Medium**: $mediumCount | **Low**: $lowCount") | Out-Null
if ($engineFailures.Count -gt 0) {
    $rep.AppendLine("- **Engine Failures (Fail-Closed)**: $($engineFailures.Count)") | Out-Null
}
$rep.AppendLine("") | Out-Null

if ($engineFailures.Count -gt 0) {
    $rep.AppendLine("## Engine & Schema Failures (Blocking)") | Out-Null
    foreach ($ef in $engineFailures) {
        $rep.AppendLine("- ❌ $ef") | Out-Null
    }
    $rep.AppendLine("") | Out-Null
}

if ($allFindings.Count -gt 0) {
    $rep.AppendLine("## Prioritized Findings") | Out-Null
    $rep.AppendLine("| ID | Role | Severity | File:Line | Assertion / Defect | Failure Scenario |") | Out-Null
    $rep.AppendLine("|---|---|---|---|---|---|") | Out-Null
    foreach ($f in $allFindings) {
        $id = if ($f.finding_id) { $f.finding_id } else { "N/A" }
        $role = if ($f.role) { $f.role } else { "GENERAL" }
        $sev = if ($f.severity) { $f.severity } else { "INFO" }
        $fl = if ($f.file_line) { $f.file_line } else { "N/A" }
        $asrt = if ($f.assertion) { ($f.assertion -replace '\|', '\|') } else { "N/A" }
        $scen = if ($f.failure_scenario -and $f.failure_scenario.wrong_result) { $f.failure_scenario.wrong_result } else { "N/A" }
        $rep.AppendLine("| $id | $role | **$sev** | '$fl' | $asrt | $scen |") | Out-Null
    }
} else {
    $rep.AppendLine("All specialized auditor passes returned ZERO defects. System state: CLEAN.") | Out-Null
}

[System.IO.File]::WriteAllText($reportFile, $rep.ToString(), [System.Text.Encoding]::UTF8)

Write-Host "`n==========================================================================" -ForegroundColor Cyan
Write-Host " Unified Report Generated: $reportFile" -ForegroundColor Cyan
Write-Host " Findings: Total $($allFindings.Count) (Critical: $criticalCount, High: $highCount, Medium: $mediumCount)" -ForegroundColor Cyan
if ($engineFailures.Count -gt 0) {
    Write-Host " Engine Failures: $($engineFailures.Count)" -ForegroundColor Red
}
Write-Host "==========================================================================" -ForegroundColor Cyan

# Fail-Closed Exit Contract
if ($engineFailures.Count -gt 0) {
    Write-Host "[FAIL-CLOSED] Auditor engine or schema failures detected. Exiting with code 1." -ForegroundColor Red
    exit 1
}

if ($criticalCount -gt 0 -or $highCount -gt 0) {
    Write-Host "[FAIL-CLOSED] Critical or High findings detected. Exiting with code 1." -ForegroundColor Red
    exit 1
} else {
    Write-Host "[PASS] No Critical or High findings. Exiting with code 0." -ForegroundColor Green
    exit 0
}
