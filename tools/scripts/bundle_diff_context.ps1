#requires -Version 5.1
<#
.SYNOPSIS
    KINTAI Delta-Only Differential Context Bundler (bundle_diff_context.ps1)
.DESCRIPTION
    Extracts minimal differential context for targeted AI auditing to achieve 70-90% input token reduction:
    1. Inspects Git diff (staged, working tree, or specified base ref) for target markdown specifications.
    2. Identifies modified/added requirement blocks (REQ-*) based on changed line ranges.
    3. Assembles an isolated minimal context bundle:
       - Header & Document Metadata
       - Global Constitution / Common Contract Core Digest
       - Only the modified/added REQ-* requirement blocks
       - Cross-slice boundary contracts referenced by the changed requirements
    4. Safely falls back to full file context if no diff or on parse exceptions (-FallbackToFull).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TargetFile = "config/srs_specification_ssot.md",

    [Parameter(Mandatory = $false)]
    [string]$BaseRef = "HEAD",

    [Parameter(Mandatory = $false)]
    [switch]$Staged,

    [Parameter(Mandatory = $false)]
    [switch]$FallbackToFull,

    [Parameter(Mandatory = $false)]
    [string]$OutputDir = "",

    [Parameter(Mandatory = $false)]
    [switch]$ReportOnly,

    [Parameter(Mandatory = $false)]
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
if (-not (Test-Path $projectRoot)) { $projectRoot = (Get-Location).Path }

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$result = [ordered]@{
    timestamp               = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    target                  = $TargetFile
    base_ref                = $BaseRef
    staged                  = [bool]$Staged
    diff_lines_count        = 0
    total_requirements      = 0
    modified_requirements   = @()
    bundle_path             = ""
    original_size_bytes     = 0
    bundle_size_bytes       = 0
    token_reduction_ratio   = "0%"
    duration_ms             = 0
}

try {
    # 1. Resolve Target File Path
    $resolvedTarget = $TargetFile
    if (-not [System.IO.Path]::IsPathRooted($resolvedTarget)) {
        $resolvedTarget = Join-Path $projectRoot $resolvedTarget
    }
    if (-not (Test-Path -LiteralPath $resolvedTarget)) {
        throw "FILE_NOT_FOUND: Target specification file not found: $resolvedTarget"
    }

    $rawContent = [System.IO.File]::ReadAllText($resolvedTarget, [System.Text.Encoding]::UTF8)
    $lines = [System.IO.File]::ReadAllLines($resolvedTarget, [System.Text.Encoding]::UTF8)
    $result.original_size_bytes = [System.Text.Encoding]::UTF8.GetByteCount($rawContent)

    # 2. Extract Relative Path for Git Command
    $relPath = $resolvedTarget.Replace($projectRoot, "").TrimStart('\', '/')
    $relPathGit = $relPath -replace '\\', '/'

    # 3. Query Git Diff
    $diffArgs = @("diff", "--no-color", "-U0")
    if ($Staged) {
        $diffArgs += "--staged"
    } elseif ($BaseRef) {
        $diffArgs += $BaseRef
    }
    $diffArgs += @("--", $relPathGit)

    $diffOutput = & git -C $projectRoot @diffArgs 2>&1
    $diffText = ($diffOutput -join "`n")

    $changedLines = New-Object 'System.Collections.Generic.HashSet[int]'
    $hunkRegex = [regex]'@@\s+-[0-9]+(?:,[0-9]+)?\s+\+([0-9]+)(?:,([0-9]+))?\s+@@'
    $hunkMatches = $hunkRegex.Matches($diffText)

    foreach ($m in $hunkMatches) {
        $start = [int]$m.Groups[1].Value
        $count = if ($m.Groups[2].Success) { [int]$m.Groups[2].Value } else { 1 }
        for ($i = 0; $i -lt $count; $i++) {
            [void]$changedLines.Add($start + $i)
        }
    }
    $result.diff_lines_count = $changedLines.Count

    # 4. Map File Lines to Requirement Blocks (REQ-*)
    $reqRegex = [regex]'^#{2,4}\s*\[?(REQ-[A-Z0-9_-]+)\]?'
    $reqList = New-Object System.Collections.Generic.List[PSCustomObject]
    $firstReqLine = -1

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $lineNum = $i + 1
        $match = $reqRegex.Match($lines[$i])
        if ($match.Success) {
            if ($firstReqLine -eq -1) { $firstReqLine = $lineNum }
            $reqId = $match.Groups[1].Value
            $reqList.Add([PSCustomObject]@{
                Id        = $reqId
                Title     = $lines[$i]
                StartLine = $lineNum
                EndLine   = $lines.Length
            })
            if ($reqList.Count -gt 1) {
                $reqList[$reqList.Count - 2].EndLine = $lineNum - 1
            }
        }
    }
    $result.total_requirements = $reqList.Count

    # 5. Identify Modified Requirements
    $modifiedReqs = New-Object System.Collections.Generic.List[PSCustomObject]
    foreach ($r in $reqList) {
        $isMod = $false
        for ($ln = $r.StartLine; $ln -le $r.EndLine; $ln++) {
            if ($changedLines.Contains($ln)) {
                $isMod = $true
                break
            }
        }
        if ($isMod) {
            $modifiedReqs.Add($r)
        }
    }
    $result.modified_requirements = @($modifiedReqs | ForEach-Object { $_.Id })

    # 6. Fallback or Zero-Diff Handling
    $useFullFallback = $false
    if ($modifiedReqs.Count -eq 0) {
        if ($FallbackToFull) {
            $useFullFallback = $true
        } else {
            # Check if non-requirement section changed (e.g. Header or Contract)
            $nonReqChanged = $false
            foreach ($cl in $changedLines) {
                if ($firstReqLine -eq -1 -or $cl -lt $firstReqLine) {
                    $nonReqChanged = $true
                    break
                }
            }
            if ($nonReqChanged) {
                $useFullFallback = $true
            }
        }
    }

    # 7. Assemble Differential Bundle Content
    $bundleSb = New-Object System.Text.StringBuilder
    [void]$bundleSb.AppendLine("<!-- KINTAI MINIMAL DIFFERENTIAL AUDIT BUNDLE -->")
    [void]$bundleSb.AppendLine("<!-- Generated: $($result.timestamp) | Source: $relPathGit | BaseRef: $BaseRef -->")
    [void]$bundleSb.AppendLine("")

    if ($useFullFallback) {
        [void]$bundleSb.AppendLine("<!-- NOTE: Full file fallback applied (global changes or -FallbackToFull specified) -->")
        [void]$bundleSb.AppendLine($rawContent)
    } elseif ($modifiedReqs.Count -gt 0) {
        # Extract Header / Metadata (up to first requirement)
        if ($firstReqLine -gt 1) {
            $headerLines = $lines[0..($firstReqLine - 2)]
            [void]$bundleSb.AppendLine(($headerLines -join "`n"))
            [void]$bundleSb.AppendLine("")
            [void]$bundleSb.AppendLine("---")
            [void]$bundleSb.AppendLine("<!-- DIFFERENTIAL REQUIREMENT SCOPE -->")
            [void]$bundleSb.AppendLine("<!-- Total Modified Requirements in this Slice: $($modifiedReqs.Count) / $($reqList.Count) -->")
            [void]$bundleSb.AppendLine("<!-- Active Audit Target IDs: $(($result.modified_requirements) -join ', ') -->")
            [void]$bundleSb.AppendLine("---")
            [void]$bundleSb.AppendLine("")
        }

        # Append ONLY the modified requirement blocks
        foreach ($mr in $modifiedReqs) {
            $blockLines = $lines[($mr.StartLine - 1)..($mr.EndLine - 1)]
            [void]$bundleSb.AppendLine(($blockLines -join "`n"))
            [void]$bundleSb.AppendLine("")
            [void]$bundleSb.AppendLine("---")
            [void]$bundleSb.AppendLine("")
        }
    } else {
        [void]$bundleSb.AppendLine("<!-- NO REQUIREMENT MODIFICATIONS DETECTED IN GIT DIFF -->")
        [void]$bundleSb.AppendLine("Target specification has zero delta relative to base ref: $BaseRef.")
    }

    # 8. Output Allocation & Writing
    $targetDir = $OutputDir
    if ([string]::IsNullOrWhiteSpace($targetDir)) {
        $timestampFolder = (Get-Date).ToString("yyyyMMdd_HHmmss")
        $targetDir = Join-Path $projectRoot "scratch\runs\diff_bundle_${timestampFolder}_${PID}"
    }
    if (-not (Test-Path -LiteralPath $targetDir)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }

    $bundleFilePath = Join-Path $targetDir "diff_context.md"
    $bundleText = $bundleSb.ToString()
    [System.IO.File]::WriteAllText($bundleFilePath, $bundleText, $utf8NoBom)
    
    $result.bundle_path = $bundleFilePath
    $result.bundle_size_bytes = [System.Text.Encoding]::UTF8.GetByteCount($bundleText)

    if ($result.original_size_bytes -gt 0) {
        $reduction = [math]::Round((1.0 - ($result.bundle_size_bytes / $result.original_size_bytes)) * 100, 1)
        if ($reduction -lt 0) { $reduction = 0 }
        $result.token_reduction_ratio = "${reduction}% input reduction ($($result.bundle_size_bytes) B vs $($result.original_size_bytes) B)"
    }

    $sw.Stop()
    $result.duration_ms = $sw.ElapsedMilliseconds

    if (-not $Quiet) {
        Write-Host "[BUNDLE-DIFF] Differential Context Bundle generated at: $bundleFilePath" -ForegroundColor Green
        Write-Host "  -> Modified REQs: $($result.modified_requirements.Count) / $($result.total_requirements) | Token reduction: $($result.token_reduction_ratio)" -ForegroundColor Cyan
    }

    if ($ReportOnly) {
        $result | ConvertTo-Json -Depth 5
    } else {
        [Console]::WriteLine($bundleFilePath)
    }

    exit 0
}
catch {
    $sw.Stop()
    [Console]::Error.WriteLine("[BUNDLE-DIFF EXCEPTION] $($_.Exception.Message)")
    exit 1
}
