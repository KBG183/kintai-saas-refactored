#requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    } finally {
        $sha.Dispose()
    }
}

function Get-FileSha256Hex {
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) { return "NONE" }
    return Get-Sha256Hex ([System.IO.File]::ReadAllBytes($FilePath))
}

function Get-GitTreeHash {
    try {
        $tree = (git rev-parse HEAD^{tree} 2>$null)
        if ($tree) { return $tree.Trim() }
    } catch {}
    return "WORKING_TREE"
}

function New-AuditVerdictSidecar {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputDir,

        [Parameter(Mandatory = $true)]
        [string]$Auditor,

        [Parameter(Mandatory = $true)]
        [string]$RunId,

        [Parameter(Mandatory = $true)]
        [string]$RawResponsePath,

        [Parameter(Mandatory = $true)]
        [ValidateSet("PASS", "WARN", "HOLD", "FAIL")]
        [string]$Verdict,

        [Parameter(Mandatory = $false)]
        [array]$Findings = @()
    )

    if (-not (Test-Path $OutputDir)) {
        [void][System.IO.Directory]::CreateDirectory($OutputDir)
    }

    $responseSha = Get-FileSha256Hex $RawResponsePath
    $treeHash = Get-GitTreeHash

    # Invariant A-2 enforcement:
    # PASS must not carry unresolved P0/P1 findings
    # HOLD/FAIL must have at least one unresolved P0/P1 finding
    $p0p1Count = 0
    foreach ($f in $Findings) {
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
        if (($sev -eq "P0" -or $sev -eq "P1") -and ($fVerdict -ne "PASS" -and $fVerdict -ne "RESOLVED")) {
            $p0p1Count++
        }
    }

    if ($Verdict -eq "PASS" -and $p0p1Count -gt 0) {
        throw "INVARIANT_VIOLATION: Verdict cannot be PASS when P0/P1 findings ($p0p1Count) exist."
    }

    $sidecarObj = [ordered]@{
        schema          = "audit-verdict/v1"
        auditor         = $Auditor.ToLowerInvariant()
        run_id          = $RunId
        tree_hash       = $treeHash
        response_sha256 = $responseSha
        verdict         = $Verdict
        findings_count  = $Findings.Count
        p0_p1_count     = $p0p1Count
        findings        = $Findings
        created_utc     = [System.DateTime]::UtcNow.ToString("o")
    }

    $jsonStr = $sidecarObj | ConvertTo-Json -Depth 10
    $verdictJsonPath = Join-Path $OutputDir "verdict.json"
    [System.IO.File]::WriteAllText($verdictJsonPath, $jsonStr, $script:Utf8NoBom)

    return $verdictJsonPath
}

Export-ModuleMember -Function Get-Sha256Hex, Get-FileSha256Hex, Get-GitTreeHash, New-AuditVerdictSidecar
