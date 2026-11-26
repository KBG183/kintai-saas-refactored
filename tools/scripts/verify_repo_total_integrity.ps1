<#
.SYNOPSIS
    KINTAI Repository Total Integrity Master Auditor
.DESCRIPTION
    Runs exhaustive deterministic multi-point verification across all Git tracked files:
    1. Sensitive Pattern & Private IP Scan (Zero tolerance)
    2. Zero-Korean Unicode Hard-Gate (Zero tolerance in public files)
    3. CSV Column Cardinality & RFC 4180 Integrity
    4. Dashboard vs Audit Ledger State Alignment
    5. Dual-Linter Pipeline Hard-Gate Wiring
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Fix,
    [Parameter(Mandatory = $false)]
    [switch]$NoLog
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
if (-not (Test-Path $projectRoot)) { $projectRoot = (Get-Location).Path }

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " [MASTER AUDITOR] Running Repository Total Integrity Verification" -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

$hasFailure = $false

# -------------------------------------------------------------------------
# Test 1: Tracked Files Sensitive Data & Zero-Korean Scan
# -------------------------------------------------------------------------
Write-Host "`n>>> [Check 1/12] Scanning Git Tracked Files for Leaks & Korean..." -ForegroundColor Yellow
$trackedFiles = git ls-files
if (-not $trackedFiles -or $trackedFiles.Count -eq 0) {
    Write-Host "  [FATAL ERROR] git ls-files returned 0 files! Repository unreadable." -ForegroundColor Red
    exit 1
}

# Generalized private IP ranges (RFC 1918 + Tailscale CGNAT range) & dynamic local user token + local path leaks
$privateIpPattern = '\b(10\.\d{1,3}\.\d{1,3}\.\d{1,3}|192\.168\.\d{1,3}\.\d{1,3}|172\.(1[6-9]|2[0-9]|3[0-1])\.\d{1,3}\.\d{1,3}|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3})\b'
$localPathPattern = '([a-zA-Z]:[\\/](Users|dev)[\\/][a-zA-Z0-9_\-]+)'
$userPatterns = @()
if ($env:USERNAME) { $userPatterns += [regex]::Escape($env:USERNAME) }
if ($env:AUDIT_SENSITIVE_KEYWORDS) {
    $env:AUDIT_SENSITIVE_KEYWORDS.Split('|;,') | Where-Object { $_.Trim() } | ForEach-Object { $userPatterns += [regex]::Escape($_.Trim()) }
}
$allPatterns = @($privateIpPattern, $localPathPattern)
if ($userPatterns.Count -gt 0) {
    $allPatterns += ($userPatterns -join '|')
}
$sensitivePattern = "(" + ($allPatterns -join '|') + ")"
$koreanPattern = '[\uAC00-\uD7A3\u1100-\u11FF\u3130-\u318F\uA960-\uA97F\uD7B0-\uD7FF\uFFA0-\uFFDC]'

$sensitiveHits = 0
$koreanHits = 0

foreach ($f in $trackedFiles) {
    $fullPath = Join-Path $projectRoot $f
    if (-not (Test-Path $fullPath)) { continue }
    if ($f -match '\.(exe|dll|png|jpg|ico)$') { continue }
    if ($f -match '_KO\.|_ko\.') { continue }

    $lines = [System.IO.File]::ReadAllLines($fullPath, [System.Text.Encoding]::UTF8)
    for ($i = 0; $i -lt $lines.Length; $i++) {
        $line = $lines[$i]
        if ($line -match $sensitivePattern) {
            if ($f -notmatch 'VerifySRS.*\.cs' -and $f -notmatch 'pre-commit') {
                Write-Host "  [LEAK] ${f}:$($i+1) : $($line.Trim())" -ForegroundColor Red
                $sensitiveHits++
            }
        }
        if ($line -match $koreanPattern) {
            Write-Host "  [KOREAN] ${f}:$($i+1) : $($line.Trim())" -ForegroundColor Red
            $koreanHits++
        }
    }
}

if ($sensitiveHits -eq 0 -and $koreanHits -eq 0) {
    Write-Host "  -> PASS: 0 Sensitive patterns, 0 Korean characters detected across $($trackedFiles.Count) files." -ForegroundColor Green
} else {
    Write-Host "  -> FAIL: Found $sensitiveHits sensitive leaks and $koreanHits Korean characters." -ForegroundColor Red
    $hasFailure = $true
}

# -------------------------------------------------------------------------
# Test 2: CSV Column Cardinality & RFC 4180 Integrity
# -------------------------------------------------------------------------
Write-Host "`n>>> [Check 2/12] Validating CSV Column Cardinality & Format..." -ForegroundColor Yellow
# Ensure VerifySRS.exe is compiled via verify_srs.ps1 wrapper
$verifyScript = Join-Path $scriptDir "verify_srs.ps1"
$integrityExe = Join-Path $scriptDir "VerifySRS.exe"
if (-not (Test-Path $integrityExe)) {
    Write-Host "  [AUTO-BUILD] Compiling VerifySRS.exe via verify_srs.ps1..." -ForegroundColor Cyan
    & powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $verifyScript 2>&1 | Out-Null
}
if (-not (Test-Path $integrityExe)) {
    Write-Host "  [FATAL] Failed to locate or compile VerifySRS.exe" -ForegroundColor Red
    $hasFailure = $true
}
$csvFiles = @("logs\local_token_ledger.csv", "logs\cloud_api_token_ledger.csv", "logs\codex_token_ledger.csv", "logs\pipeline_metrics.csv", "logs\enterprise_audit_ledger.csv")
$csvFail = $false

foreach ($csv in $csvFiles) {
    $fullPath = Join-Path $projectRoot $csv
    $out = & $integrityExe $fullPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [CSV ERROR] $csv failed integrity check." -ForegroundColor Red
        $csvFail = $true
    }
}

if (-not $csvFail) {
    Write-Host "  -> PASS: All CSV ledgers strictly conform to column cardinality rules." -ForegroundColor Green
} else {
    $hasFailure = $true
}

# -------------------------------------------------------------------------
# Test 3: Dashboard Matrix Mathematical & Logical Consistency
# -------------------------------------------------------------------------
Write-Host "`n>>> [Check 3/12] Verifying Dashboard Matrix Logical Coherence & SSOT Cardinality..." -ForegroundColor Yellow
$metricsPath = Join-Path $projectRoot "logs\pipeline_metrics.md"
$metricsContent = [System.IO.File]::ReadAllText($metricsPath, [System.Text.Encoding]::UTF8)

$tableLines = $metricsContent -split "`r?`n" | Where-Object { $_ -match '^\|\s*REQ-[A-Z]+-\d+\s*\|' }
$matrixError = $false

# Verify SSOT requirements count matches dashboard matrix rows
$ssotPath = Join-Path $projectRoot "config\srs_specification_ssot.md"
$ssotContent = [System.IO.File]::ReadAllText($ssotPath, [System.Text.Encoding]::UTF8)
$ssotReqMatches = [regex]::Matches($ssotContent, '(?m)^#{3,4}\s*\[(REQ-[A-Z0-9\-]+)\]')
$expectedReqCount = $ssotReqMatches.Count

if ($tableLines.Count -ne $expectedReqCount) {
    Write-Host "  [DASHBOARD DESYNC] Dashboard row count ($($tableLines.Count)) does not match SSOT requirement count ($expectedReqCount)!" -ForegroundColor Red
    $matrixError = $true
}

foreach ($row in $tableLines) {
    $cols = $row.Split('|') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
    if ($cols.Count -ge 7) {
        $id = $cols[0]
        $linter = $cols[2]
        $qwen = $cols[3]
        $codex = $cols[4]
        $claude = $cols[5]
        $finalVerdict = $cols[6]

        $hasAnyFinding = ($linter -ne "PASS") -or ($qwen -like "*FINDINGS*") -or ($codex -like "*FINDINGS*") -or ($claude -like "*FINDINGS*")
        $expectedVerdict = if ($hasAnyFinding) { "**REVISE_PENDING**" } else { "**PASS**" }

        if ($finalVerdict -ne $expectedVerdict) {
            Write-Host "  [DASHBOARD ERROR] Row $id verdict mismatch! Expected: $expectedVerdict, Found: $finalVerdict" -ForegroundColor Red
            $matrixError = $true
        }
    }
}

if ($matrixError) {
    $hasFailure = $true
} elseif ($tableLines.Count -eq 0) {
    Write-Host "  [DASHBOARD ERROR] No requirement verification rows found in pipeline_metrics.md table." -ForegroundColor Red
    $hasFailure = $true
} else {
    Write-Host "  -> PASS: All $($tableLines.Count) requirement matrix rows satisfy Fail-Closed boolean logic coherence." -ForegroundColor Green
}

# Check 3.2: Repository-wide JA/KO Markdown Structure Parity Gate
# Enforces strict 1:1 structural skeleton match (heading-level sequence & markdown table row count)
# while strictly ignoring lines inside fenced code blocks (``` or ~~~).
$koPairFiles = @(Get-ChildItem -LiteralPath $projectRoot -Filter "*_KO.md" -Recurse -File -ErrorAction Stop | Where-Object {
    $rel = $_.FullName.Substring($projectRoot.Length).TrimStart('\', '/')
    $rel -notmatch '^(scratch|\.git|node_modules)[\\/]' -and
    $rel -notmatch '^audit[\\/]runs[\\/]' -and
    $rel -notmatch '^docs[\\/]audit_runs[\\/]'
})

$hdrLevelPattern = [regex]'^(#{1,6})\s+'
$tblRowPattern = [regex]'^\s*\|.*\|\s*$'

# Standalone KO documents permitted without direct JA counterpart (e.g. developer internal retrospectives/historical raw dumps)
$allowedStandaloneKo = @(
    'audit/audit_hermes_verify_humanize_KO.md',
    'audit/HERMES_Audit_srs_specification_ssot_20261117_174430_KO.md',
    'audit/HERMES_Audit_VerifySRS_Integrity.cs_20261118_135026_KO.md',
    'audit/HERMES_Audit_VerifySRS_Integrity.cs_20261118_135145_KO.md',
    'audit/hermes_integrated_audit_slice4_20261115_KO.md',
    'audit/qwen_rfc_audit_KO.md',
    'docs/audit_report_plan_a_qwen_KO.md',
    'docs/daily_retrospective_20261123_KO.md',
    'docs/sprint_schedule_KO.md',
    'docs/srs_diff_analysis_slice1_KO.md',
    'docs/srs_diff_analysis_slice2_KO.md',
    'docs/srs_diff_analysis_slice3_KO.md',
    'docs/srs_diff_analysis_slice4_KO.md',
    'docs/srs_governance_upgrade_analysis_report_KO.md',
    'logs/project_evolution_ledger_KO.md'
)

# Established static fixtures excluded from active structural skeleton drift checking
$excludedFixturePairs = @(
    'domain_target/01_specifications_and_rtm/kintai_master_srs_KO.md'
)

function Get-MarkdownSkeleton {
    param([string]$FilePath)
    $lines = [System.IO.File]::ReadAllLines($FilePath, [System.Text.Encoding]::UTF8)
    $inFence = $false
    $levels = [System.Collections.Generic.List[int]]::new()
    $tableRows = 0
    foreach ($line in $lines) {
        if ($line -match '^\s*(```|~~~)') {
            $inFence = -not $inFence
            continue
        }
        if ($inFence) { continue }
        if ($line -match '^(#{1,6})\s+') {
            $levels.Add($Matches[1].Length)
        }
        if ($line -match '^\s*\|.*\|\s*$') {
            $tableRows++
        }
    }
    return [PSCustomObject]@{
        Levels    = $levels.ToArray()
        TableRows = $tableRows
    }
}

$pairCount = 0
$pairError = $false

if ($koPairFiles.Count -eq 0) {
    Write-Host "  -> [SKIP: CLEAN CLONE] No local Korean (*_KO.md) mirrors present (standard Git clone with .gitignore). Remote JA SSOT is authoritative." -ForegroundColor Cyan
} else {
    foreach ($koPairFile in $koPairFiles) {
        $relKo = $koPairFile.FullName.Substring($projectRoot.Length).TrimStart('\', '/').Replace('\', '/')
        $jaPairPath = $koPairFile.FullName -replace '_KO\.md$', '.md'
        $relJa = $jaPairPath.Substring($projectRoot.Length).TrimStart('\', '/').Replace('\', '/')

        if ($excludedFixturePairs -contains $relKo) {
            continue
        }

        if (-not (Test-Path -LiteralPath $jaPairPath -PathType Leaf)) {
            if ($allowedStandaloneKo -contains $relKo) {
                continue
            } else {
                Write-Host "  [MIRROR ORPHAN] Unregistered standalone KO mirror without source: $relKo" -ForegroundColor Red
                $pairError = $true
                continue
            }
        }

        $pairCount++
        try {
            $jaSkel = Get-MarkdownSkeleton -FilePath $jaPairPath
            $koSkel = Get-MarkdownSkeleton -FilePath $koPairFile.FullName

            if (($jaSkel.Levels -join ',') -cne ($koSkel.Levels -join ',')) {
                Write-Host "  [MIRROR STRUCTURE MISMATCH] $relKo headings: JA=$($jaSkel.Levels.Count) vs KO=$($koSkel.Levels.Count) (level sequence differs)!" -ForegroundColor Red
                $pairError = $true
            }
            if ($jaSkel.TableRows -ne $koSkel.TableRows) {
                Write-Host "  [MIRROR STRUCTURE MISMATCH] $relKo table rows: JA=$($jaSkel.TableRows) vs KO=$($koSkel.TableRows)!" -ForegroundColor Red
                $pairError = $true
            }
        } catch {
            Write-Host "  [MIRROR READ ERROR] Failed to parse markdown skeleton for $($relKo) - $($_.Exception.Message)" -ForegroundColor Red
            $pairError = $true
        }
    }

    if ($pairError) {
        $hasFailure = $true
    } elseif ($pairCount -lt 15) {
        Write-Host "  [MIRROR GATE FAIL-CLOSED] Insufficient paired mirrors scanned: only $pairCount pairs found (expected >= 15 in local development environment)." -ForegroundColor Red
        $hasFailure = $true
    } else {
        Write-Host "  -> PASS: All $pairCount JA/KO markdown pairs match on fence-aware heading sequence and table row count." -ForegroundColor Green
    }
}

# Check 3.1: Multi-Track JA/KO Mirror Parity Gate (config/srs_targets.json)
$targetsConfigPath = Join-Path $projectRoot "config\srs_targets.json"
if (Test-Path $targetsConfigPath) {
    $tCfg = [System.IO.File]::ReadAllText($targetsConfigPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $reqHdrPattern = [regex]'(?m)^#{3,4}\s*\[((?:REQ|CC)-[A-Z0-9_-]+)\]'
    foreach ($tgt in $tCfg.targets) {
        $jaFull = Join-Path $projectRoot $tgt.ja_path
        $koFull = Join-Path $projectRoot $tgt.ko_path
        if (Test-Path $jaFull) {
            if (-not (Test-Path $koFull)) {
                if ($koPairFiles.Count -eq 0) {
                    Write-Host "  -> [SKIP] Target '$($tgt.id)' KO mirror not present in clean checkout." -ForegroundColor DarkGray
                } else {
                    Write-Host "  [MIRROR MISSING] Korean mirror missing for $($tgt.ja_path): expected $($tgt.ko_path)!" -ForegroundColor Red
                    $hasFailure = $true
                }
            } else {
                $jaReqs = @([regex]::Matches([System.IO.File]::ReadAllText($jaFull, [System.Text.Encoding]::UTF8), $reqHdrPattern) | ForEach-Object { $_.Groups[1].Value })
                $koReqs = @([regex]::Matches([System.IO.File]::ReadAllText($koFull, [System.Text.Encoding]::UTF8), $reqHdrPattern) | ForEach-Object { $_.Groups[1].Value })
                if ($jaReqs.Count -ne $koReqs.Count -or (($jaReqs -join ',') -cne ($koReqs -join ','))) {
                    Write-Host "  [MIRROR DESYNC] Target '$($tgt.id)' JA ($($jaReqs.Count) reqs) vs KO ($($koReqs.Count) reqs) requirement ID parity mismatch!" -ForegroundColor Red
                    $hasFailure = $true
                } else {
                    Write-Host "  -> PASS: Target '$($tgt.id)' JA/KO mirror parity verified ($($jaReqs.Count) requirements 1:1 matched)." -ForegroundColor Green
                }
            }
        }
    }
}

# -------------------------------------------------------------------------
# Test 4: Dual-Linter Pipeline Hard-Gate Wiring
# -------------------------------------------------------------------------
Write-Host "`n>>> [Check 4/12] Verifying Dual-Linter Wiring in hermes_controller.ps1..." -ForegroundColor Yellow
$controllerPath = Join-Path $scriptDir "hermes_controller.ps1"
$controllerText = [System.IO.File]::ReadAllText($controllerPath, [System.Text.Encoding]::UTF8)

$hasIntegrity = $controllerText.Contains("VerifySRS.exe") -or $controllerText.Contains("VerifySRS_Integrity.exe")
$hasDeterministic = $controllerText.Contains("verify_srs.ps1")

if ($hasIntegrity -and $hasDeterministic) {
    Write-Host "  -> PASS: Both VerifySRS_Integrity and VerifySRS_Deterministic are firmly wired in pipeline." -ForegroundColor Green
} else {
    Write-Host "  [WIRING ERROR] hermes_controller.ps1 is missing dual-linter execution logic." -ForegroundColor Red
    $hasFailure = $true
}

# -------------------------------------------------------------------------
# Test 5: C# Deterministic Regression Testbed (11/11)
# -------------------------------------------------------------------------
Write-Host "`n>>> [Check 5/12] Running Deterministic Regression Testbed (11/11)..." -ForegroundColor Yellow
$regExe = Join-Path $scriptDir "TestV52Suite_Regression.exe"
$regCs = Join-Path $scriptDir "TestV52Suite_Regression.cs"
if (-not (Test-Path $regExe)) {
    Write-Host "  [AUTO-BUILD] Compiling TestV52Suite_Regression.exe..." -ForegroundColor Cyan
    $csc = [System.IO.Path]::Combine($env:WINDIR, "Microsoft.NET\Framework64\v4.0.30319\csc.exe")
    if (-not (Test-Path $csc)) {
        $csc = [System.IO.Path]::Combine($env:WINDIR, "Microsoft.NET\Framework\v4.0.30319\csc.exe")
    }
    if (Test-Path $csc) {
        & $csc /nologo /target:exe /out:$regExe $regCs 2>&1 | Out-Null
    }
}

if (-not (Test-Path $regExe)) {
    Write-Host "  [REGRESSION ERROR] TestV52Suite_Regression.exe could not be found or compiled." -ForegroundColor Red
    $hasFailure = $true
} else {
    $regOut = & $regExe 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  -> PASS: All 11 boundary regression test cases deterministically passed." -ForegroundColor Green
    } else {
        Write-Host "  [REGRESSION FAIL] Regression suite returned exit code $LASTEXITCODE." -ForegroundColor Red
        $hasFailure = $true
    }
}

# -------------------------------------------------------------------------
# Test 6: UTF-8 BOM & Encoding Integrity Hard-Gate
# -------------------------------------------------------------------------
Write-Host "`n>>> [Check 6/12] Scanning Tracked Text Files for UTF-8 BOM & Mojibake..." -ForegroundColor Yellow
$bomHits = 0
$mojibakeHits = 0
$mojibakeRegex = [regex]'(?:\u00E3|\u00E7|\u00E9|\u00E8|\u00E5)[\u0080-\u00BF\u201A-\u203A]|\uFFFD'
foreach ($f in $trackedFiles) {
    $fullPath = Join-Path $projectRoot $f
    if (-not (Test-Path $fullPath)) { continue }
    if ($f -match '\.(exe|dll|png|jpg|ico)$') { continue }
    $b = [System.IO.File]::ReadAllBytes($fullPath)
    if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
        if ($Fix) {
            $newBytes = New-Object byte[] ($b.Length - 3)
            [System.Array]::Copy($b, 3, $newBytes, 0, $newBytes.Length)
            [System.IO.File]::WriteAllBytes($fullPath, $newBytes)
            Write-Host "  [AUTO-FIXED] ${f}: Stripped UTF-8 BOM." -ForegroundColor Cyan
        } else {
            Write-Host "  [BOM VIOLATION] $f has UTF-8 BOM!" -ForegroundColor Red
            $bomHits++
        }
    }
    # Mojibake pattern scan for text files
    if ($f -match '\.(md|txt|json|csv|ps1|cs)$') {
        $content = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8)
        if ($content -match $mojibakeRegex) {
            Write-Host "  [MOJIBAKE VIOLATION] $f contains UTF-8 double-encoding mojibake patterns!" -ForegroundColor Red
            $mojibakeHits++
        }
    }
}
if ($bomHits -eq 0 -and $mojibakeHits -eq 0) {
    Write-Host "  -> PASS: 0 UTF-8 BOM and 0 mojibake patterns detected across all tracked text files." -ForegroundColor Green
} else {
    Write-Host "  -> FAIL: Found $bomHits BOM violations and $mojibakeHits mojibake violations." -ForegroundColor Red
    $hasFailure = $true
}

# -------------------------------------------------------------------------
# Test 7: PowerShell Scripts Syntax & Fail-Fast Gate
# -------------------------------------------------------------------------
Write-Host "`n>>> [Check 7/12] Verifying PowerShell Scripts Syntax & Fail-Fast..." -ForegroundColor Yellow
$ps1Files = Get-ChildItem -Path (Join-Path $projectRoot "tools\scripts") -Filter "*.ps1"
$ps1Fail = 0
foreach ($ps in $ps1Files) {
    # 1. AST Syntax Parse
    $parseErrors = $null
    $parseTokens = $null
    $psContent = [System.IO.File]::ReadAllText($ps.FullName, [System.Text.Encoding]::UTF8)
    $null = [System.Management.Automation.Language.Parser]::ParseInput($psContent, $ps.FullName, [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors.Count -gt 0) {
        Write-Host "  [SYNTAX ERROR] $($ps.Name): $($parseErrors[0].Message)" -ForegroundColor Red
        $ps1Fail++
        continue
    }

    # 2. Fail-Fast Declaration Check
    $psContent = [System.IO.File]::ReadAllText($ps.FullName, [System.Text.Encoding]::UTF8)
    if ($psContent -notmatch "\`$ErrorActionPreference\s*=\s*['""]Stop['""]") {
        Write-Host "  [FAIL-FAST MISSING] $($ps.Name) is missing `$ErrorActionPreference = 'Stop' declaration." -ForegroundColor Red
        $ps1Fail++
    }
}
if ($ps1Fail -eq 0) {
    Write-Host "  -> PASS: All $($ps1Files.Count) PowerShell scripts are syntax-valid and enforce Fail-Fast (`$ErrorActionPreference = 'Stop')." -ForegroundColor Green
} else {
    Write-Host "  -> FAIL: Found $ps1Fail scripts with syntax or Fail-Fast defects." -ForegroundColor Red
    $hasFailure = $true
}

# -------------------------------------------------------------------------
# Test 8: Status Ledger Duplicate Bullet & Integrity Gate
# -------------------------------------------------------------------------
Write-Host "`n>>> [Check 8/12] Verifying CURRENT_STATUS.md Bullet Line Integrity..." -ForegroundColor Yellow
$csPath = Join-Path $projectRoot "logs\CURRENT_STATUS.md"
if (-not (Test-Path $csPath)) {
    Write-Host "  [INTEGRITY ERROR] CURRENT_STATUS.md does not exist at: $csPath" -ForegroundColor Red
    $hasFailure = $true
} else {
    $csLines = [System.IO.File]::ReadAllLines($csPath, [System.Text.Encoding]::UTF8)
    $healthLineCount = 0
    $jaHealthLabel = [System.Text.Encoding]::UTF8.GetString(@(0xE6, 0x9C, 0x80, 0xE6, 0x96, 0xB0, 0xE3, 0x83, 0x98, 0xE3, 0x83, 0xAB, 0xE3, 0x82, 0xB9, 0xE3, 0x83, 0x81, 0xE3, 0x82, 0xA7, 0xE3, 0x83, 0x83, 0xE3, 0x82, 0xAF, 0xE5, 0x88, 0xA4, 0xE5, 0xAE, 0x9A))
    $healthPattern = "^- \*\*" + [regex]::Escape($jaHealthLabel) + "\*\*:"
    foreach ($line in $csLines) {
        if ($line -match $healthPattern) {
            $healthLineCount++
        }
    }
    if ($healthLineCount -ne 1) {
        Write-Host "  [INTEGRITY ERROR] CURRENT_STATUS.md expected exactly 1 health check line, but found: $healthLineCount!" -ForegroundColor Red
        $hasFailure = $true
    } else {
        Write-Host "  -> PASS: CURRENT_STATUS.md has exactly $healthLineCount health check line (Zero duplication, Valid structure)." -ForegroundColor Green
    }
}

# -------------------------------------------------------------------------
# Test 8.1: Daily Audit Evidence Dossier Freshness Gate (JA & KO Dual-Gate)
# -------------------------------------------------------------------------
$dossierPath = Join-Path $projectRoot "docs\audit_evidence_dossier.md"
if (Test-Path $dossierPath) {
    $todayStr = (Get-Date).ToString("yyyy-MM-dd")
    $dossierText = [System.IO.File]::ReadAllText($dossierPath, [System.Text.Encoding]::UTF8)
    if ($dossierText -notmatch [regex]::Escape($todayStr)) {
        Write-Host "  [FATAL DOSSIER STALE] audit_evidence_dossier.md is missing today's date ($todayStr) section!" -ForegroundColor Red
        $hasFailure = $true
    } else {
        Write-Host "  -> PASS: audit_evidence_dossier.md firmly contains today's ($todayStr) audit evidence section." -ForegroundColor Green
    }
}

$koDossierPath = Join-Path $projectRoot "docs\audit_evidence_dossier_KO.md"
if (Test-Path $koDossierPath) {
    $todayStr = (Get-Date).ToString("yyyy-MM-dd")
    $koDossierText = [System.IO.File]::ReadAllText($koDossierPath, [System.Text.Encoding]::UTF8)
    if ($koDossierText -notmatch [regex]::Escape($todayStr)) {
        Write-Host "  [FATAL DOSSIER STALE] audit_evidence_dossier_KO.md is missing today's date ($todayStr) section!" -ForegroundColor Red
        $hasFailure = $true
    } else {
        Write-Host "  -> PASS: audit_evidence_dossier_KO.md firmly contains today's ($todayStr) audit evidence section." -ForegroundColor Green
    }
}

# -------------------------------------------------------------------------
# Test 9: Invisible Control Characters Gate (BEL/BS/FF/ESC etc.)
# -------------------------------------------------------------------------
Write-Host "`n>>> [Check 9/12] Scanning Tracked Source & Markdown Files for Control Characters..." -ForegroundColor Yellow
$ctrlScanFiles = $trackedFiles | Where-Object { $_ -match '\.(md|java|json|ps1|csv)$' }
$ctrlHits = 0
foreach ($f in $ctrlScanFiles) {
    $fullPath = Join-Path $projectRoot $f
    if (-not (Test-Path $fullPath)) { continue }
    $bytes = [System.IO.File]::ReadAllBytes($fullPath)
    
    # 1. Guard against UTF-16 BOM (LE: 0xFF 0xFE, BE: 0xFE 0xFF)
    # Avoid stripping 0x00 (NUL) bytes in UTF-16 encoded files
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) -or ($bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF))) {
        continue
    }

    $hasCtrl = $false
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $b = $bytes[$i]
        if ($b -lt 32 -and $b -ne 9 -and $b -ne 10 -and $b -ne 13) {
            $hasCtrl = $true
            break
        }
    }
    if ($hasCtrl) {
        if ($Fix) {
            $cleaned = New-Object System.Collections.Generic.List[byte]
            for ($i = 0; $i -lt $bytes.Length; $i++) {
                $byteVal = $bytes[$i]
                if ($byteVal -ge 32 -or $byteVal -eq 9 -or $byteVal -eq 10 -or $byteVal -eq 13) {
                    $cleaned.Add($byteVal)
                }
            }
            # Atomic file replace (Avoid in-place write corruption)
            $tempPath = "$fullPath.tmp.$([System.Guid]::NewGuid().ToString('N'))"
            try {
                [System.IO.File]::WriteAllBytes($tempPath, $cleaned.ToArray())
                [System.IO.File]::Copy($tempPath, $fullPath, $true)
                Remove-Item -Force $tempPath -ErrorAction SilentlyContinue
                Write-Host "  [AUTO-FIXED] ${f}: Stripped invisible control characters." -ForegroundColor Cyan
            } finally {
                if (Test-Path $tempPath) {
                    Remove-Item -Force $tempPath -ErrorAction SilentlyContinue
                }
            }
        } else {
            Write-Host "  [CONTROL CHAR DETECTED] ${f} has non-printable control characters!" -ForegroundColor Red
            $ctrlHits++
        }
    }
}
if ($ctrlHits -eq 0) {
    Write-Host "  -> PASS: 0 Invisible control characters detected across $($ctrlScanFiles.Count) text/source files." -ForegroundColor Green
} else {
    Write-Host "  -> FAIL: Found $ctrlHits files contaminated with non-printable control characters." -ForegroundColor Red
    $hasFailure = $true
}

# -------------------------------------------------------------------------
# Test 10: Markdown Relative Link & Manifest Table Physical Integrity Gate
# -------------------------------------------------------------------------
Write-Host "`n>>> [Check 10/12] Verifying Relative Hyperlinks & Executive Table Declarations Physical Existence..." -ForegroundColor Yellow
$allMdFiles = Get-ChildItem -Path $projectRoot -Filter "*.md" -Recurse | Where-Object { 
    $_.FullName -notmatch '\\\.git\\' -and 
    $_.FullName -notmatch '\\scratch\\' -and
    $_.FullName -notmatch '\\audit\\runs\\' -and
    $_.FullName -notmatch '\\docs\\audit_runs\\'
}
$brokenCount = 0
$checkedLinkCount = 0
$checkedTableDeclCount = 0

foreach ($mf in $allMdFiles) {
    $content = [System.IO.File]::ReadAllText($mf.FullName, [System.Text.Encoding]::UTF8)
    $dir = $mf.DirectoryName
    
    # 1. Check markdown hyperlinks [text](url)
    $linkMatches = [regex]::Matches($content, '\[([^\]]+)\]\(([^)]+)\)')
    foreach ($m in $linkMatches) {
        $linkPath = $m.Groups[2].Value.Trim()
        if ($linkPath -match '^(http|https|mailto|ftp):' -or $linkPath -match '^#') { continue }
        $checkedLinkCount++
        $cleanPath = $linkPath.Split('#')[0]
        if (-not $cleanPath) { continue }
        
        $resolved = [System.IO.Path]::Combine($dir, $cleanPath)
        if (-not (Test-Path $resolved)) {
            Write-Host "  [BROKEN LINK] $($mf.Name) -> '$linkPath' (Cannot resolve: $resolved)" -ForegroundColor Red
            $brokenCount++
        }
    }

    # 2. Check declared deliverables/specs in markdown tables (e.g. `srs_track2_asbuilt_slice4.md`, `srs_diff_analysis_total_master.md`)
    # Target only core index/synthesis/spec documents to prevent false positives on historical narrative notes
    $isCoreIndexDoc = ($mf.Name -match '^(srs_|CURRENT_STATUS|audit_evidence|README|GEMINI)')
    if ($isCoreIndexDoc) {
        $tableLines = $content -split "`r?`n" | Where-Object { $_ -match '^\s*\|.*\|\s*$' }
        foreach ($tl in $tableLines) {
            $colMatches = [regex]::Matches($tl, '`([a-zA-Z0-9_\-\.]+\.md)`')
            foreach ($cm in $colMatches) {
                $rawFile = $cm.Groups[1].Value.Trim()
                # Skip local development mirrors (*_KO.md) which are intentionally gitignored in clean checkout/CI
                if ($rawFile -match '_KO\.md$') {
                    continue
                }

                $checkedTableDeclCount++
                $found = (Test-Path (Join-Path $dir $rawFile)) -or (Test-Path (Join-Path $projectRoot $rawFile)) -or (Test-Path (Join-Path $projectRoot "docs\$rawFile")) -or (Test-Path (Join-Path $projectRoot "config\$rawFile"))
                if (-not $found) {
                    $foundMatch = Get-ChildItem -Path $projectRoot -Filter $rawFile -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\\.git\\' -and $_.FullName -notmatch '\\scratch\\' }
                    if ($foundMatch) { $found = $true }
                }

                if (-not $found) {
                    Write-Host "  [UNDEFINED TABLE DELIVERABLE] $($mf.Name) table declares non-existent deliverable file: '$rawFile'" -ForegroundColor Red
                    $brokenCount++
                }
            }
        }
    }
}
if ($brokenCount -eq 0) {
    Write-Host "  -> PASS: All $checkedLinkCount relative hyperlinks and $checkedTableDeclCount table deliverable declarations physically exist across $($allMdFiles.Count) markdown files." -ForegroundColor Green
} else {
    Write-Host "  -> FAIL: Found $brokenCount broken relative hyperlinks or undefined table deliverable declarations in repository." -ForegroundColor Red
    $hasFailure = $true
}

# -------------------------------------------------------------------------
# Test 11: External Audit Verdict & Sidecar Fail-Closed Gate (Worst Verdict Wins)
# -------------------------------------------------------------------------
Write-Host "`n>>> [Check 11/12] Verifying External Audit Verdicts & Sidecars (Worst Verdict Wins)..." -ForegroundColor Yellow
$auditRunsDirs = @(
    (Join-Path $projectRoot "audit\runs"),
    (Join-Path $projectRoot "docs\audit_runs")
)

$thresholdTime = [System.DateTime]::UtcNow.AddHours(-24)
$recentVerdicts = @()
$sidecarFails = 0

foreach ($ard in $auditRunsDirs) {
    if (-not (Test-Path $ard)) { continue }
    $verdictFiles = Get-ChildItem -Path $ard -Filter "verdict.json" -Recurse
    foreach ($vf in $verdictFiles) {
        try {
            $vJson = [System.IO.File]::ReadAllText($vf.FullName, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            $isRecent = $false
            if ($vJson.created_utc) {
                $cTime = [System.DateTime]::Parse($vJson.created_utc, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
                $isRecent = ($cTime -ge $thresholdTime)
            } else {
                $isRecent = ($vf.LastWriteTimeUtc -ge $thresholdTime)
            }
            if ($isRecent) {
                if ($vJson.schema -ne "audit-verdict/v1" -or (-not $vJson.verdict)) {
                    Write-Host "  [INVALID SIDECAR] $($vf.FullName) does not conform to audit-verdict/v1 schema." -ForegroundColor Red
                    $sidecarFails++
                    continue
                }

                # Fail-Closed: response_sha256 must be present and valid
                if ([string]::IsNullOrWhiteSpace($vJson.response_sha256) -or $vJson.response_sha256 -eq "NONE") {
                    Write-Host "  [INVALID SIDECAR] $($vf.FullName) has missing or NONE response_sha256! Fail-Closed." -ForegroundColor Red
                    $sidecarFails++
                    continue
                }

                # Find associated raw response artifact
                $runDir = $vf.DirectoryName
                $possibleRaws = Get-ChildItem -Path $runDir | Where-Object { 
                    $_.Name -match '(raw.*\.json|report.*\.txt|raw_response\.txt|codex_report.*\.txt)' -and $_.Name -ne "verdict.json"
                }

                if ($possibleRaws.Count -eq 0) {
                    Write-Host "  [MISSING RAW ARTIFACT] $($vf.FullName) has no associated raw report/response file in $runDir! Fail-Closed." -ForegroundColor Red
                    $sidecarFails++
                    continue
                }

                $matchedRaw = $false
                foreach ($rf in $possibleRaws) {
                    $rawBytes = [System.IO.File]::ReadAllBytes($rf.FullName)
                    $sha = [System.Security.Cryptography.SHA256]::Create()
                    $calcSha = ([BitConverter]::ToString($sha.ComputeHash($rawBytes)) -replace '-', '').ToLowerInvariant()
                    
                    # Also compute canonical LF hash (neutralizing git autocrlf checkout variations)
                    $rawText = [System.Text.Encoding]::UTF8.GetString($rawBytes)
                    $lfText = $rawText.Replace("`r`n", "`n")
                    $lfBytes = [System.Text.Encoding]::UTF8.GetBytes($lfText)
                    $calcShaLf = ([BitConverter]::ToString($sha.ComputeHash($lfBytes)) -replace '-', '').ToLowerInvariant()

                    # And canonical CRLF hash
                    $crlfText = $lfText.Replace("`n", "`r`n")
                    $crlfBytes = [System.Text.Encoding]::UTF8.GetBytes($crlfText)
                    $calcShaCrlf = ([BitConverter]::ToString($sha.ComputeHash($crlfBytes)) -replace '-', '').ToLowerInvariant()
                    $sha.Dispose()

                    $expectedSha = $vJson.response_sha256.ToString().ToLowerInvariant()
                    if ($calcSha -eq $expectedSha -or $calcShaLf -eq $expectedSha -or $calcShaCrlf -eq $expectedSha) {
                        $matchedRaw = $true
                        break
                    }
                }

                if (-not $matchedRaw) {
                    if ($Fix) {
                        $canHeal = $false
                        $healedSha = $null
                        foreach ($rf in $possibleRaws) {
                            $rawBytes = [System.IO.File]::ReadAllBytes($rf.FullName)
                            $bytesWithBom = if ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF) {
                                $rawBytes
                            } else {
                                $tempWithBom = New-Object byte[] ($rawBytes.Length + 3)
                                $tempWithBom[0] = 0xEF; $tempWithBom[1] = 0xBB; $tempWithBom[2] = 0xBF
                                [System.Array]::Copy($rawBytes, 0, $tempWithBom, 3, $rawBytes.Length)
                                $tempWithBom
                            }
                            $sha = [System.Security.Cryptography.SHA256]::Create()
                            $shaBom = ([BitConverter]::ToString($sha.ComputeHash($bytesWithBom)) -replace '-', '').ToLowerInvariant()
                            $shaClean = ([BitConverter]::ToString($sha.ComputeHash($rawBytes)) -replace '-', '').ToLowerInvariant()
                            $sha.Dispose()

                            if ($vJson.response_sha256.ToString().ToLowerInvariant() -eq $shaBom) {
                                $canHeal = $true
                                $healedSha = $shaClean
                                break
                            }
                        }

                        if ($canHeal -and $healedSha) {
                            $vJson.response_sha256 = $healedSha
                            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                            $jsonText = $vJson | ConvertTo-Json -Depth 5
                            [System.IO.File]::WriteAllText($vf.FullName, $jsonText, $utf8NoBom)
                            Write-Host "  [AUTO-HEALED SIDECAR] $($vf.FullName): Synchronized post-canonical SHA-256." -ForegroundColor Cyan
                            $matchedRaw = $true
                        }
                    }

                    if (-not $matchedRaw) {
                        Write-Host "  [TAMPERED ARTIFACT] $($vf.FullName) response_sha256 does not match any raw artifact in $runDir! Fail-Closed." -ForegroundColor Red
                        $sidecarFails++
                        continue
                    }
                }

                # Check 11.1: Raw Artifact Text Encoding & Mojibake Integrity Gate (Fail-Closed)
                $mojibakePattern = [regex]'(?:\u00E3|\u00E7|\u00E9|\u00E8|\u00E5)[\u0080-\u00BF\u201A-\u203A]|\uFFFD'
                foreach ($rf in $possibleRaws) {
                    $rawContent = [System.IO.File]::ReadAllText($rf.FullName, [System.Text.Encoding]::UTF8)
                    if ($rawContent -match $mojibakePattern) {
                        Write-Host "  [MOJIBAKE DETECTED] $($rf.Name) in $runDir contains UTF-8 double-encoding mojibake patterns! Fail-Closed." -ForegroundColor Red
                        $sidecarFails++
                    }
                }

                $recentVerdicts += [PSCustomObject]@{
                    Auditor = $vJson.auditor
                    Verdict = $vJson.verdict.ToString().ToUpperInvariant()
                    RunId = $vJson.run_id
                    P0P1Count = $vJson.p0_p1_count
                    Path = $vf.FullName
                    Time = $vf.LastWriteTimeUtc
                }
            }
        } catch {
            Write-Host "  [CORRUPT SIDECAR] $($vf.FullName): $_" -ForegroundColor Red
            $sidecarFails++
        }
    }
}

# Group by auditor and evaluate Worst Verdict Wins
$hasAdverseVerdict = $false
$auditorGroups = $recentVerdicts | Group-Object -Property Auditor
$queueFile = Join-Path $projectRoot "queue\srs_pending_findings.json"
$queueObj = $null
if (Test-Path $queueFile) {
    try {
        $queueObj = [System.IO.File]::ReadAllText($queueFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if (-not $queueObj.findings -or $queueObj.declared_count -ne $queueObj.findings.Count) {
            Write-Host "  [QUEUE SCHEMA ERROR] srs_pending_findings.json declared_count ($($queueObj.declared_count)) mismatches actual findings count ($($queueObj.findings.Count))!" -ForegroundColor Red
            $sidecarFails++
            $queueObj = $null
        } else {
            $dupIds = $queueObj.findings | Group-Object -Property id | Where-Object { $_.Count -gt 1 }
            if ($dupIds) {
                Write-Host "  [QUEUE DUPLICATE ID] srs_pending_findings.json contains duplicate finding ID: $($dupIds[0].Name)" -ForegroundColor Red
                $sidecarFails++
                $queueObj = $null
            }
            foreach ($qf in $queueObj.findings) {
                if (-not $qf.id -or -not $qf.status -or -not $qf.evidence -or $qf.evidence.ToString().Trim().Length -lt 10) {
                    Write-Host "  [QUEUE EVIDENCE MISSING] Finding '$($qf.id)' has empty or insufficient physical evidence!" -ForegroundColor Red
                    $sidecarFails++
                    $queueObj = $null
                    break
                }
                if ($qf.closure_predicates) {
                    foreach ($pred in $qf.closure_predicates) {
                        $predFile = Join-Path $projectRoot $pred.file
                        if (-not (Test-Path $predFile)) {
                            Write-Host "  [CLOSURE PREDICATE FAIL] Finding '$($qf.id)' target file missing: $($pred.file)" -ForegroundColor Red
                            $sidecarFails++
                            $queueObj = $null
                            break
                        }
                        $predContent = [System.IO.File]::ReadAllText($predFile, [System.Text.Encoding]::UTF8)
                        if ($pred.must_contain_regex -and ($predContent -notmatch $pred.must_contain_regex)) {
                            Write-Host "  [CLOSURE PREDICATE FAIL] Finding '$($qf.id)' regex '$($pred.must_contain_regex)' not satisfied in $($pred.file)!" -ForegroundColor Red
                            $sidecarFails++
                            $queueObj = $null
                            break
                        }
                    }
                }
            }
        }
    } catch {
        Write-Host "  [QUEUE PARSE ERROR] srs_pending_findings.json is malformed JSON! Fail-Closed." -ForegroundColor Red
        $sidecarFails++
        $queueObj = $null
    }
}

foreach ($ag in $auditorGroups) {
    $latest = $ag.Group | Sort-Object -Property Time -Descending | Select-Object -First 1
    # Check if latest verdict in the active window on this auditor issued HOLD or FAIL
    if ($latest.Verdict -eq "HOLD" -or $latest.Verdict -eq "FAIL") {
        # Check if all adverse findings have been formalized and verified in the central queue
        $allResolvedInQueue = $false
        if ($queueObj -and $queueObj.findings) {
            $unresolvedCount = 0
            try {
                $vData = [System.IO.File]::ReadAllText($latest.Path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                if ($vData.findings -and $vData.findings.Count -gt 0) {
                    foreach ($f in $vData.findings) {
                        $fId = if ($f.finding_id) { $f.finding_id } elseif ($f.id) { $f.id } else { "" }
                        if (-not $fId) {
                            $unresolvedCount++
                        } else {
                            $qMatch = $queueObj.findings | Where-Object { $_.id -eq $fId -and ($_.status -eq "VERIFIED" -or $_.status -eq "RESOLVED" -or $_.status -eq "CLOSED") }
                            if (-not $qMatch) {
                                $unresolvedCount++
                            }
                        }
                    }
                    if ($unresolvedCount -eq 0) {
                        $allResolvedInQueue = $true
                    }
                }
            } catch {
                $allResolvedInQueue = $false
            }
        }

        if ($allResolvedInQueue) {
            Write-Host "  [QUEUE-RESOLVED ADVERSE VERDICT] Auditor '$($ag.Name)' adverse verdict in $($latest.Path) is fully VERIFIED in queue. Passing." -ForegroundColor Green
        } else {
            Write-Host "  [UNRESOLVED ADVERSE VERDICT] Auditor '$($ag.Name)' has unresolved $($latest.Verdict) verdict in: $($latest.Path)" -ForegroundColor Red
            $hasAdverseVerdict = $true
        }
    }
}

# Verify Approval Manifest Integrity if present
$manifestPath = Join-Path $projectRoot "approved\approval_manifest.json"
if (Test-Path $manifestPath) {
    try {
        $mJson = [System.IO.File]::ReadAllText($manifestPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if (-not $mJson.GitCommitSha -or -not $mJson.Files) {
            Write-Host "  [MANIFEST INVALID] approval_manifest.json schema invalid." -ForegroundColor Red
            $hasFailure = $true
        } else {
            # Check if GitCommitSha exists in repository history
            $commitExists = (git cat-file -e "$($mJson.GitCommitSha)^{commit}" 2>&1)
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  [MANIFEST COMMIT UNKNOWN] approval_manifest.json GitCommitSha ($($mJson.GitCommitSha)) does not exist in Git history!" -ForegroundColor Red
                $hasFailure = $true
            } else {
                # Check that all required targets from config/srs_targets.json are covered in approved manifest
                $targetsCfgFile = Join-Path $projectRoot "config\srs_targets.json"
                if (Test-Path $targetsCfgFile) {
                    $tCfg = [System.IO.File]::ReadAllText($targetsCfgFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
                    $approvedPaths = @($mJson.Files | ForEach-Object { $_.Path.Replace('\', '/') })
                    foreach ($tgt in $tCfg.targets) {
                        if ($tgt.required -eq $true -and (Test-Path (Join-Path $projectRoot $tgt.ja_path))) {
                            $normPath = $tgt.ja_path.Replace('\', '/')
                            if ($approvedPaths -notcontains $normPath) {
                                Write-Host "  [MANIFEST MISSING REQUIRED TARGET] Required target '$normPath' ($($tgt.id)) is not included in approved manifest!" -ForegroundColor Red
                                $hasFailure = $true
                            }
                        }
                    }
                }

                # Check SHA256 of approved files against manifest
                foreach ($f in $mJson.Files) {
                    $fPath = Join-Path $projectRoot $f.Path
                    if (-not (Test-Path $fPath)) {
                        Write-Host "  [MANIFEST MISSING FILE] Approved file missing: $($f.Path)" -ForegroundColor Red
                        $hasFailure = $true
                    } else {
                        $fBytes = [System.IO.File]::ReadAllBytes($fPath)
                        $sha = [System.Security.Cryptography.SHA256]::Create()
                        $calcSha = ([BitConverter]::ToString($sha.ComputeHash($fBytes)) -replace '-', '').ToLowerInvariant()

                        # Neutralize line-ending checkout differences (LF vs CRLF)
                        $fText = [System.Text.Encoding]::UTF8.GetString($fBytes)
                        $lfText = $fText.Replace("`r`n", "`n")
                        $lfBytes = [System.Text.Encoding]::UTF8.GetBytes($lfText)
                        $calcShaLf = ([BitConverter]::ToString($sha.ComputeHash($lfBytes)) -replace '-', '').ToLowerInvariant()

                        $crlfText = $lfText.Replace("`n", "`r`n")
                        $crlfBytes = [System.Text.Encoding]::UTF8.GetBytes($crlfText)
                        $calcShaCrlf = ([BitConverter]::ToString($sha.ComputeHash($crlfBytes)) -replace '-', '').ToLowerInvariant()
                        $sha.Dispose()

                        $expectedSha = $f.Sha256.ToLowerInvariant()
                        if ($calcSha -ne $expectedSha -and $calcShaLf -ne $expectedSha -and $calcShaCrlf -ne $expectedSha) {
                            Write-Host "  [MANIFEST HASH MISMATCH] $($f.Path) hash mismatch against approved manifest!" -ForegroundColor Red
                            $hasFailure = $true
                        }
                    }
                }
            }
        }
    } catch {
        Write-Host "  [MANIFEST ERROR] Failed to parse approval_manifest.json: $_" -ForegroundColor Red
        $hasFailure = $true
    }
}

if ($sidecarFails -gt 0 -or $hasAdverseVerdict) {
    Write-Host "  -> FAIL: Active adverse external audit verdicts exist! Fix defects and obtain a PASS verdict." -ForegroundColor Red
    $hasFailure = $true
} else {
    Write-Host "  -> PASS: All active external audit sidecars ($($recentVerdicts.Count) found) satisfy Fail-Closed clean integrity." -ForegroundColor Green
}

# -------------------------------------------------------------------------
# Test 12: README Directory Tree Architecture Alignment Gate (Drift Guard)
# -------------------------------------------------------------------------
Write-Host "`n>>> [Check 12/12] Verifying README.md Architecture Tree vs Physical Git Directories..." -ForegroundColor Yellow
$readmePath = Join-Path $projectRoot "README.md"
if (-not (Test-Path $readmePath)) {
    Write-Host "  [MISSING README] README.md does not exist at project root!" -ForegroundColor Red
    $hasFailure = $true
} else {
    $readmeText = [System.IO.File]::ReadAllText($readmePath, [System.Text.Encoding]::UTF8)
    
    # Extract top-level directories declared in README.md directory tree (Pure ASCII regex using Unicode escapes)
    $treeMatch = [regex]::Match($readmeText, '(?s)```text\s*\.\s*(\r?\n[\u251C\u2514]\u2500\u2500\s+.*?)```')
    if (-not $treeMatch.Success) {
        Write-Host "  [INVALID README FORMAT] Could not locate directory tree text code block in README.md" -ForegroundColor Red
        $hasFailure = $true
    } else {
        $treeContent = $treeMatch.Groups[1].Value
        $declaredDirMatches = [regex]::Matches($treeContent, '(?m)^[\u251C\u2514]\u2500\u2500\s+([a-zA-Z0-9_\-\.]+)/')
        $declaredDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($dm in $declaredDirMatches) {
            [void]$declaredDirs.Add($dm.Groups[1].Value)
        }

        # Query actual Git tracked top-level directories
        $actualDirs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $gitTracked = git ls-files
        foreach ($gt in $gitTracked) {
            $parts = $gt.Split('/')
            if ($parts.Length -gt 1) {
                [void]$actualDirs.Add($parts[0])
            }
        }

        $missingInReadme = @($actualDirs | Where-Object { -not $declaredDirs.Contains($_) })
        $extraInReadme = @($declaredDirs | Where-Object { -not $actualDirs.Contains($_) })

        if ($missingInReadme.Count -gt 0 -or $extraInReadme.Count -gt 0) {
            if ($missingInReadme.Count -gt 0) {
                Write-Host "  [DRIFT: MISSING IN README] Physical Git directories not in README: $($missingInReadme -join ', ')" -ForegroundColor Red
            }
            if ($extraInReadme.Count -gt 0) {
                Write-Host "  [DRIFT: EXTRA IN README] README declares non-existent Git directories: $($extraInReadme -join ', ')" -ForegroundColor Red
            }
            $hasFailure = $true
        } else {
            Write-Host "  -> PASS: All $($actualDirs.Count) physical Git top-level directories strictly align with README.md ($($declaredDirs -join ', '))." -ForegroundColor Green
        }
    }
}

Write-Host "`n=================================================================" -ForegroundColor Cyan
$traceLogPath = Join-Path $projectRoot "logs\incident_execution_trace.log"
$timestampUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

if ($hasFailure) {
    if (-not $NoLog -and (Test-Path $traceLogPath)) {
        $logLine = "[$timestampUtc] [VERIFY_REPO] [STATUS: FAIL] [CODE: ERR-INTEGRITY-FAILED] [MSG: Repository total integrity verification detected violations]"
        [System.IO.File]::AppendAllText($traceLogPath, "$logLine`n", [System.Text.Encoding]::UTF8)
    }
    Write-Host " [VERDICT: FAIL] Repository has integrity violations! Abort release." -ForegroundColor Red
    exit 1
} else {
    if (-not $NoLog -and (Test-Path $traceLogPath)) {
        $logLine = "[$timestampUtc] [VERIFY_REPO] [STATUS: PASS] [CODE: OK] [MSG: All 12 repository total integrity checks passed cleanly]"
        [System.IO.File]::AppendAllText($traceLogPath, "$logLine`n", [System.Text.Encoding]::UTF8)
    }
    Write-Host " [VERDICT: ALL PASS] Repository is 100% Clean, Consistent & Verified." -ForegroundColor Green
    exit 0
}
