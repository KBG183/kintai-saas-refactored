#Requires -Version 5.1
<#
.SYNOPSIS
    test_git_hooks.ps1 - Git Hook Syntax & Governance Verification (DX-05)
.DESCRIPTION
    Validates pre-commit and other git hook scripts in tools/hooks for Bash syntax errors
    and PowerShell command contamination without needing an actual git commit attempt.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not (Test-Path (Join-Path $RepoRoot "tools\hooks"))) {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
}
$HooksDir = Join-Path $RepoRoot "tools\hooks"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " [DX-05] Git Hook Syntax & Governance Verification" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

if (-not (Test-Path $HooksDir)) {
    Write-Error "[FAIL] Hooks directory not found: $HooksDir"
    exit 1
}

# Locate bash.exe from Git for Windows
$GitBash = Get-Command "bash.exe" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1
if (-not $GitBash) {
    $CommonPaths = @(
        "C:\Program Files\Git\bin\bash.exe",
        "C:\Program Files\Git\usr\bin\bash.exe",
        "$env:LOCALAPPDATA\Programs\Git\bin\bash.exe"
    )
    foreach ($p in $CommonPaths) {
        if (Test-Path $p) { $GitBash = $p; break }
    }
}

$Failed = $false
$HookFiles = Get-ChildItem -Path $HooksDir -File

foreach ($hook in $HookFiles) {
    Write-Host "`n[*] Inspecting Hook: $($hook.Name)" -ForegroundColor Yellow
    $content = [System.IO.File]::ReadAllText($hook.FullName, [System.Text.Encoding]::UTF8)

    # 1. Anti-pattern Check: PowerShell syntax mixed into Bash
    if ($content -match '@\(') {
        Write-Host "  [FAIL] Detected PowerShell array literal '@(' in bash hook!" -ForegroundColor Red
        $Failed = $true
    } else {
        Write-Host "  [PASS] No PowerShell array literals found." -ForegroundColor Green
    }

    # 2. Zero-Korean Check
    if ($content -match '[\uAC00-\uD7A3]') {
        Write-Host "  [FAIL] Korean characters detected in hook script!" -ForegroundColor Red
        $Failed = $true
    } else {
        Write-Host "  [PASS] Zero-Korean policy compliant." -ForegroundColor Green
    }

    # 3. Bash Syntax Check (bash -n)
    if ($GitBash) {
        $bashOutput = & $GitBash -n ($hook.FullName -replace '\\', '/') 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  [FAIL] Bash syntax error in $($hook.Name): $bashOutput" -ForegroundColor Red
            $Failed = $true
        } else {
            Write-Host "  [PASS] Bash syntax valid (bash.exe -n verified)." -ForegroundColor Green
        }
    } else {
        Write-Host "  [WARN] bash.exe not found on PATH; skipped bash -n syntax pass." -ForegroundColor Yellow
    }
}

Write-Host "`n------------------------------------------------------------" -ForegroundColor Cyan
if ($Failed) {
    Write-Host "[VERDICT: FAIL] Hook validation failed." -ForegroundColor Red
    exit 1
} else {
    Write-Host "[VERDICT: PASS] All Git hooks syntax and governance verified." -ForegroundColor Green
    exit 0
}
