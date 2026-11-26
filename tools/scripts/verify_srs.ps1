<#
.SYNOPSIS
    KINTAI SRS Unified Deterministic Linter Wrapper (verify_srs.ps1)
.DESCRIPTION
    Compiles VerifySRS.cs to VerifySRS.exe when missing or outdated (clean checkout fallback),
    and executes deterministic specification and integrity verification across target files.
    Returns 0 on PASS, 2 on lint rejection, or 4 on execution/compilation error.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, Position = 0, ValueFromRemainingArguments = $true)]
    [Alias("TargetFiles", "Path", "Files")]
    [string[]]$TargetFile = @()
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$csFile = Join-Path $scriptDir "VerifySRS.cs"
$exeFile = Join-Path $scriptDir "VerifySRS.exe"

if (-not (Test-Path -LiteralPath $csFile)) {
    [Console]::Error.WriteLine("[FATAL] C# linter source file not found: $csFile")
    exit 4
}

# C# compilation (when VerifySRS.exe is missing in clean checkout or VerifySRS.cs was updated)
if (-not (Test-Path -LiteralPath $exeFile) -or ((Get-Item -LiteralPath $csFile).LastWriteTimeUtc -gt (Get-Item -LiteralPath $exeFile).LastWriteTimeUtc)) {
    $csc = [System.IO.Path]::Combine($env:WINDIR, "Microsoft.NET\Framework64\v4.0.30319\csc.exe")
    if (-not (Test-Path -LiteralPath $csc)) {
        $csc = [System.IO.Path]::Combine($env:WINDIR, "Microsoft.NET\Framework\v4.0.30319\csc.exe")
    }
    if (-not (Test-Path -LiteralPath $csc)) {
        [Console]::Error.WriteLine("[FATAL] C# compiler (csc.exe) not found.")
        exit 4
    }

    Write-Host "[COMPILE] Compiling Unified C# Deterministic Linter (VerifySRS.cs -> VerifySRS.exe)..." -ForegroundColor Cyan
    $compileOut = & $csc /nologo /target:exe /out:$exeFile $csFile 2>&1
    if ($LASTEXITCODE -ne 0) {
        [Console]::Error.WriteLine("[FATAL] C# linter compilation failed:`n$($compileOut -join "`n")")
        exit 4
    }
}

$overallExit = 0
foreach ($target in $TargetFile) {
    if ([string]::IsNullOrWhiteSpace($target)) { continue }
    if (-not (Test-Path -LiteralPath $target)) {
        [Console]::Error.WriteLine("[EXECUTION ERROR] Target file not found: $target")
        exit 4
    }

    & $exeFile $target
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        if ($code -eq 3 -or $code -eq 4) {
            exit 4
        }
        $overallExit = 2
    }
}

exit $overallExit
