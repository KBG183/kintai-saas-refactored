<#
.SYNOPSIS
    Automated Local Auditor Benchmark (LAB) Runner.
.DESCRIPTION
    Executes deterministic performance benchmarking across test fixtures in tools/fixtures/
    and calculates precision, hash throughput, and verification latency.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [int]$Iterations = 3
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir
if ((Split-Path -Leaf $projectRoot) -eq "tools") {
    $projectRoot = Split-Path -Parent $projectRoot
}

$fixtureDir = Join-Path $projectRoot "tools\fixtures"
$benchmarkCsv = Join-Path $projectRoot "logs\evidence_benchmark.csv"
$linterExe = Join-Path $projectRoot "tools\scripts\VerifySRS.exe"

Write-Host "=================================================================" -ForegroundColor Cyan
Write-Host " [LAB BENCHMARK] Running Local Auditor Deterministic Benchmark   " -ForegroundColor Cyan
Write-Host "=================================================================" -ForegroundColor Cyan

if (-not (Test-Path $fixtureDir)) {
    Write-Error "Fixture directory not found: $fixtureDir"
    exit 1
}

$fixtureFiles = Get-ChildItem -Path $fixtureDir -Filter "*.md"
if ($fixtureFiles.Count -eq 0) {
    Write-Error "No benchmark fixture files found in: $fixtureDir"
    exit 1
}

$hasher = [System.Security.Cryptography.SHA256]::Create()
$readTimes = @()
$hashTimes = @()

# Warmup run
$swWarmup = [System.Diagnostics.Stopwatch]::StartNew()
$null = [System.IO.File]::ReadAllBytes($fixtureFiles[0].FullName)
$swWarmup.Stop()
$warmupMs = [Math]::Max(1, [int]$swWarmup.ElapsedMilliseconds)

for ($i = 0; $i -lt $Iterations; $i++) {
    foreach ($f in $fixtureFiles) {
        $swRead = [System.Diagnostics.Stopwatch]::StartNew()
        $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
        $swRead.Stop()
        $readTimes += $swRead.Elapsed.TotalMilliseconds

        $swHash = [System.Diagnostics.Stopwatch]::StartNew()
        $null = $hasher.ComputeHash($bytes)
        $swHash.Stop()
        $hashTimes += $swHash.Elapsed.TotalMilliseconds
    }
}

$avgRead = [Math]::Round(($readTimes | Measure-Object -Average).Average, 2)
$avgHash = [Math]::Round(($hashTimes | Measure-Object -Average).Average, 2)

# Full Linter Run
$swTotal = [System.Diagnostics.Stopwatch]::StartNew()
if (Test-Path $linterExe) {
    & $linterExe (Join-Path $projectRoot "config\srs_specification_ssot.md") | Out-Null
}
$swTotal.Stop()
$totalMs = [Math]::Max(1, [int]$swTotal.ElapsedMilliseconds)

# Write standardized benchmark CSV matching schema: "WarmupReadMs","AvgReadMs","AvgHashMs","TotalAuditMs"
$csvLine = '"{0}","{1}","{2}","{3}"' -f $warmupMs, [int]$avgRead, $avgHash, $totalMs
$csvContent = '"WarmupReadMs","AvgReadMs","AvgHashMs","TotalAuditMs"`r`n' + $csvLine + "`r`n"

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($benchmarkCsv, $csvContent, $utf8NoBom)

Write-Host "Benchmark completed successfully:" -ForegroundColor Green
Write-Host "  WarmupReadMs : $warmupMs ms" -ForegroundColor Green
Write-Host "  AvgReadMs    : $avgRead ms" -ForegroundColor Green
Write-Host "  AvgHashMs    : $avgHash ms" -ForegroundColor Green
Write-Host "  TotalAuditMs : $totalMs ms" -ForegroundColor Green
Write-Host "  -> Updated: $benchmarkCsv" -ForegroundColor Green

exit 0
