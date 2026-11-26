<#
.SYNOPSIS
    KINTAI Unified Deterministic SSOT Patch Utility (patch_ssot.ps1)
.DESCRIPTION
    Consolidates editorial and literal patch utilities into a single, secure,
    atomic, zero-BOM, path-traversal-guarded text splicer with concurrency lock,
    reparse-point hierarchy check, and exact byte-level post-write verification.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TargetFile = "config/srs_specification_ssot.md",

    [Parameter(Mandatory = $false)]
    [string]$TargetText = "",

    [Parameter(Mandatory = $false)]
    [string]$TargetTextFile = "",

    [Parameter(Mandatory = $false)]
    [string]$ReplacementText = "",

    [Parameter(Mandatory = $false)]
    [string]$ReplacementTextFile = "",

    [Parameter(Mandatory = $false)]
    [switch]$AllowMultiple = $false
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
if (-not (Test-Path $projectRoot)) { $projectRoot = (Get-Location).Path }

# 1. Hardened Path Traversal Guard (Strict Trailing Separator & Hierarchy Junction Defenses)
$canonicalRoot = [System.IO.Path]::GetFullPath($projectRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
$resolvedTarget = [System.IO.Path]::GetFullPath((Join-Path $projectRoot $TargetFile))

if (-not $resolvedTarget.StartsWith($canonicalRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "SECURITY_PATH_TRAVERSAL: Target path escapes repository root boundary: $resolvedTarget"
}
if (-not (Test-Path -LiteralPath $resolvedTarget)) {
    throw "FILE_NOT_FOUND: Target file does not exist: $resolvedTarget"
}

# ReparsePoint / Junction Defense Across Root and Entire Parent Directory Hierarchy
$rootInfo = New-Object System.IO.DirectoryInfo($projectRoot)
if ($rootInfo.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
    throw "SECURITY_REPARSE_POINT: Repository root cannot be a symbolic link or junction: $projectRoot"
}

$fileInfo = New-Object System.IO.FileInfo($resolvedTarget)
if ($fileInfo.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
    throw "SECURITY_REPARSE_POINT: Target file cannot be a symbolic link or junction: $resolvedTarget"
}

$dirCursor = $fileInfo.Directory
while ($dirCursor -and $dirCursor.FullName.Length -ge $projectRoot.Length) {
    if ($dirCursor.Attributes.HasFlag([System.IO.FileAttributes]::ReparsePoint)) {
        throw "SECURITY_REPARSE_POINT: Parent directory component cannot be a symbolic link or junction: $($dirCursor.FullName)"
    }
    $dirCursor = $dirCursor.Parent
}

# 2. Resolve Parameters with Strict Absence Verification
if ($TargetTextFile) {
    if (-not (Test-Path -LiteralPath $TargetTextFile)) {
        throw "FILE_NOT_FOUND: Specified TargetTextFile does not exist: $TargetTextFile"
    }
    $TargetText = [System.IO.File]::ReadAllText($TargetTextFile, [System.Text.Encoding]::UTF8)
}

if ($ReplacementTextFile) {
    if (-not (Test-Path -LiteralPath $ReplacementTextFile)) {
        throw "FILE_NOT_FOUND: Specified ReplacementTextFile does not exist: $ReplacementTextFile"
    }
    $ReplacementText = [System.IO.File]::ReadAllText($ReplacementTextFile, [System.Text.Encoding]::UTF8)
}

if ([string]::IsNullOrEmpty($TargetText)) {
    throw "EMPTY_TARGET: Target text to replace cannot be empty."
}

# Strict Binary Ordinal Identity Check (Prevents false zero-delta rejection on casing-only edits)
if ([string]::Equals($TargetText, $ReplacementText, [System.StringComparison]::Ordinal)) {
    throw "ZERO_DELTA: TargetText and ReplacementText are 100% identical in binary ordinal. No-op rejected."
}

# 3. File Concurrency Lock (Guarantees Zero-Lost-Update on SSoT with Active Process Liveness Check)
$lockFilePath = "$resolvedTarget.lock"
if (Test-Path -LiteralPath $lockFilePath) {
    $lockItem = Get-Item -LiteralPath $lockFilePath -ErrorAction SilentlyContinue
    if ($lockItem) {
        $lockAge = (Get-Date) - $lockItem.LastWriteTime
        if ($lockAge.TotalSeconds -gt 60) {
            # Inspect PID liveness to avoid deleting lock of long-running active process (TOCTOU defense)
            $isProcessAlive = $false
            try {
                $rawLockContent = [System.IO.File]::ReadAllText($lockFilePath, [System.Text.Encoding]::UTF8).Trim()
                if ($rawLockContent -match '^\d+$') {
                    $lockPid = [int]$rawLockContent
                    $aliveProc = Get-Process -Id $lockPid -ErrorAction SilentlyContinue
                    if ($aliveProc -and -not $aliveProc.HasExited) {
                        $isProcessAlive = $true
                    }
                }
            } catch {}
            if (-not $isProcessAlive) {
                Remove-Item -LiteralPath $lockFilePath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

$lockStream = $null
$maxLockRetries = 10
$lockRetryCount = 0

while ($lockRetryCount -lt $maxLockRetries) {
    try {
        $lockStream = [System.IO.File]::Open($lockFilePath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        # Record current PID into lock file for authoritative liveness tracking
        $lockWriter = New-Object System.IO.StreamWriter($lockStream, [System.Text.Encoding]::UTF8)
        $lockWriter.WriteLine($PID)
        $lockWriter.Flush()
        break
    } catch [System.IO.IOException] {
        $lockRetryCount++
        Start-Sleep -Milliseconds 100
    }
}

if (-not $lockStream) {
    throw "CONCURRENCY_LOCK_TIMEOUT: Failed to acquire exclusive lock on $resolvedTarget after $maxLockRetries retries."
}

try {
    # 4. Read and Verify Content Invariants
    $currentContent = [System.IO.File]::ReadAllText($resolvedTarget, [System.Text.Encoding]::UTF8)
    if ($currentContent.IndexOf($TargetText, [System.StringComparison]::Ordinal) -lt 0) {
        throw "TARGET_NOT_FOUND: The specified TargetText was not found in $resolvedTarget."
    }

    if (-not $AllowMultiple) {
        $firstIdx = $currentContent.IndexOf($TargetText, [System.StringComparison]::Ordinal)
        $secondIdx = $currentContent.IndexOf($TargetText, $firstIdx + $TargetText.Length, [System.StringComparison]::Ordinal)
        if ($secondIdx -ge 0) {
            throw "AMBIGUOUS_MATCH: TargetText occurs multiple times. Provide longer context or use -AllowMultiple."
        }
    }

    # 5. Perform Deterministic Splicing
    $patchedContent = if ($AllowMultiple) {
        $currentContent.Replace($TargetText, $ReplacementText)
    } else {
        $idx = $currentContent.IndexOf($TargetText, [System.StringComparison]::Ordinal)
        $currentContent.Substring(0, $idx) + $ReplacementText + $currentContent.Substring($idx + $TargetText.Length)
    }

    # 6. Atomic Overwrite with Retry and Post-Write Verification
    $tempTarget = "$resolvedTarget.tmp.$PID"
    $backupTarget = "$resolvedTarget.bak.$PID"
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

    [System.IO.File]::WriteAllText($tempTarget, $patchedContent, $utf8NoBom)

    $replaceSucceeded = $false
    $replaceAttempts = 0
    while ($replaceAttempts -lt 5) {
        try {
            [System.IO.File]::Replace($tempTarget, $resolvedTarget, $backupTarget)
            $replaceSucceeded = $true
            break
        } catch [System.IO.IOException] {
            $replaceAttempts++
            Start-Sleep -Milliseconds 200
        }
    }

    if (-not $replaceSucceeded) {
        throw "ATOMIC_REPLACE_FAILED: Failed to atomically replace $resolvedTarget after 5 attempts."
    }

    # 7. Exact SHA-256 Content-Level Post-Write Verification
    $verifiedBytes = [System.IO.File]::ReadAllBytes($resolvedTarget)
    $expectedBytes = $utf8NoBom.GetBytes($patchedContent)
    
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $actualHash = [BitConverter]::ToString($sha.ComputeHash($verifiedBytes))
    $expectedHash = [BitConverter]::ToString($sha.ComputeHash($expectedBytes))
    $sha.Dispose()

    if ($actualHash -ne $expectedHash) {
        # Auto-rollback from backup
        if (Test-Path -LiteralPath $backupTarget) {
            [System.IO.File]::Copy($backupTarget, $resolvedTarget, $true)
        }
        throw "POST_WRITE_CORRUPTION: File SHA-256 hash mismatch after atomic replace. Rolled back."
    }

    # Clean up temp and backup only after 100% verified
    if (Test-Path -LiteralPath $tempTarget) { Remove-Item -LiteralPath $tempTarget -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $backupTarget) { Remove-Item -LiteralPath $backupTarget -Force -ErrorAction SilentlyContinue }

    Write-Host "[PATCH-SSOT] Successfully patched $TargetFile deterministically." -ForegroundColor Green

} finally {
    # Release and remove concurrency lock
    if ($lockStream) {
        $lockStream.Close()
        $lockStream.Dispose()
    }
    if (Test-Path -LiteralPath $lockFilePath) {
        Remove-Item -LiteralPath $lockFilePath -Force -ErrorAction SilentlyContinue
    }
}
