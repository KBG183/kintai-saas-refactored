<#
.SYNOPSIS
    KINTAI SRS Automated AI Audit Adapter for gate_master_srs.ps1 (audit_srs.ps1)
.DESCRIPTION
    Receives -RepoRoot, -BundlePath, and -RunId from gate_master_srs.ps1 (Stage 3).
    1. Independently verifies bundle SHA-256, Article 0 constitution checksum, and finding queue status.
    2. Inspects every target Markdown file in the bundle against its recorded SHA-256 hash,
       Article 0 requirement structure rules, and the 5 mandatory KINTAI domain alignment axes.
    3. Invokes call_ai.ps1 to execute live AI audit against Article 0 and validates the completed
       model response and sidecar receipt (verdict.json).
    4. Writes all diagnostics exclusively to stderr and outputs exactly one JSON object to stdout:
       { "RunId": "...", "BundleSha256": "...", "Verdict": "PASS" }
    Exit codes: 0 = PASS, 3 = REJECT (specification or AI audit rejection), 4 = incomplete/invalid audit.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RepoRoot,

    [Parameter(Mandatory = $true)]
    [string]$BundlePath,

    [Parameter(Mandatory = $true)]
    [string]$RunId,

    [Parameter(Mandatory = $false)]
    [ValidateSet("Qwen", "Codex", "Claude")]
    [string]$Provider = $(if ($env:SRS_AI_PROVIDER) { $env:SRS_AI_PROVIDER } else { "Qwen" }),

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
$utf8NoBom = New-Object System.Text.UTF8Encoding($false, $true)

function Get-BytesSha256([byte[]]$Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

try {
    if (-not (Test-Path -LiteralPath $RepoRoot)) {
        [Console]::Error.WriteLine("[AI-ADAPTER ERROR] RepoRoot does not exist: $RepoRoot")
        exit 4
    }
    $rootFull = (Get-Item -LiteralPath $RepoRoot).FullName

    if (-not (Test-Path -LiteralPath $BundlePath)) {
        [Console]::Error.WriteLine("[AI-ADAPTER ERROR] BundlePath does not exist: $BundlePath")
        exit 4
    }

    # 1. Read and hash bundle
    $bundleBytes = [System.IO.File]::ReadAllBytes($BundlePath)
    $bundleHash = Get-BytesSha256 $bundleBytes
    $bundleText = $utf8NoBom.GetString($bundleBytes)
    if ($bundleText.StartsWith([string][char]0xFEFF, [System.StringComparison]::Ordinal)) {
        $bundleText = $bundleText.Substring(1)
    }
    $bundleJson = $bundleText | ConvertFrom-Json

    if (-not $bundleJson -or [string]$bundleJson.RunId -cne $RunId) {
        [Console]::Error.WriteLine("[AI-ADAPTER ERROR] Bundle RunId mismatch. Expected '$RunId', got '$($bundleJson.RunId)'.")
        exit 4
    }

    $files = @($bundleJson.Files)
    if (-not $files -or $files.Count -eq 0) {
        [Console]::Error.WriteLine("[AI-ADAPTER ERROR] Zero target files in bundle.")
        exit 4
    }

    [Console]::Error.WriteLine("[AI-ADAPTER] Auditing bundle $BundlePath (SHA256: $bundleHash, Targets: $($files.Count))")

    # 2. Independently verify Article 0 Constitution & Checksum
    $articlePath = Join-Path $rootFull "governance\ARTICLE_0_SRS.md"
    $checksumPath = Join-Path $rootFull "governance\ARTICLE_0_SRS.sha256"
    if (-not (Test-Path -LiteralPath $articlePath) -or -not (Test-Path -LiteralPath $checksumPath)) {
        [Console]::Error.WriteLine("[AI-ADAPTER ERROR] Article 0 constitution or checksum file missing.")
        exit 4
    }

    $articleBytes = [System.IO.File]::ReadAllBytes($articlePath)
    $articleHash = Get-BytesSha256 $articleBytes
    $checksumLine = ($utf8NoBom.GetString([System.IO.File]::ReadAllBytes($checksumPath))).Trim()

    if ($checksumLine -notmatch '\A([0-9a-fA-F]{64})(?:[ \t]+\*?(?:\./)?ARTICLE_0_SRS\.md)?\z' -or
        $Matches[1].ToLowerInvariant() -ne $articleHash -or
        ([string]$bundleJson.ConstitutionSha256).ToLowerInvariant() -ne $articleHash) {
        [Console]::Error.WriteLine("[AI-ADAPTER ERROR] Article 0 constitution SHA-256 verification failed.")
        exit 4
    }
    $articleText = $utf8NoBom.GetString($articleBytes)

    # 3. Independently verify Finding Queue (Article 0 Section 4)
    $queuePath = Join-Path $rootFull "queue\srs_pending_findings.json"
    if (-not (Test-Path -LiteralPath $queuePath)) {
        [Console]::Error.WriteLine("[AI-ADAPTER ERROR] Finding queue missing: $queuePath")
        exit 4
    }
    $queueDoc = ($utf8NoBom.GetString([System.IO.File]::ReadAllBytes($queuePath))) | ConvertFrom-Json
    $qItems = if ($null -ne $queueDoc.findings) { @($queueDoc.findings) } else { @() }
    foreach ($qi in $qItems) {
        $st = ([string]$qi.status).Trim().ToUpperInvariant()
        if ($st -eq 'PENDING' -or $st -eq 'RESOLVED') {
            [Console]::Error.WriteLine("[AI-ADAPTER REJECT] Unverified finding in queue (status=$st). Article 0 Section 4 violation.")
            exit 3
        }
    }

    # 4. Content & Constitution Cross-Verification across all Bundle Files
    $seenReqIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $combinedSpecBuilder = New-Object System.Text.StringBuilder
    $rejectionReasons = New-Object 'System.Collections.Generic.List[string]'

    foreach ($fileEntry in $files) {
        $relPath = [string]$fileEntry.Path
        $expectedSha = ([string]$fileEntry.Sha256).ToLowerInvariant()
        $fullTarget = [System.IO.Path]::GetFullPath((Join-Path $rootFull $relPath))

        if (-not (Test-Path -LiteralPath $fullTarget)) {
            [Console]::Error.WriteLine("[AI-ADAPTER ERROR] Target file listed in bundle does not exist: $relPath")
            exit 4
        }

        $targetBytes = [System.IO.File]::ReadAllBytes($fullTarget)
        $actualSha = Get-BytesSha256 $targetBytes
        if ($actualSha -ne $expectedSha) {
            [Console]::Error.WriteLine("[AI-ADAPTER ERROR] SHA-256 mismatch for '$relPath'. Expected $expectedSha, got $actualSha.")
            exit 4
        }

        $content = $utf8NoBom.GetString($targetBytes)
        if ($content.Contains([char]0)) {
            [Console]::Error.WriteLine("[AI-ADAPTER ERROR] NUL byte detected in '$relPath'.")
            exit 4
        }

        # Check for unfinalized placeholders (Article 0 Section 5)
        $placeholderMatch = [regex]::Match($content, '(?i)\b(TODO|TBD|FIXME)\b|(?:\u672A\u5B9A|\u672A\u78BA\u5B9A|\u8FFD\u3063\u3066\u6C7A\u5B9A)')
        if ($placeholderMatch.Success) {
            $rejectionReasons.Add("[$relPath] Unfinalized placeholder detected: '$($placeholderMatch.Value)'")
        }

        # Extract and validate requirements (Article 0 Section 2)
        $reqMatches = [regex]::Matches($content, '(?m)^#{2,4}\s*\[?(REQ-[A-Z0-9_-]+)\]?[^\r\n]*')
        for ($i = 0; $i -lt $reqMatches.Count; $i++) {
            $reqId = $reqMatches[$i].Groups[1].Value
            if (-not $seenReqIds.Add($reqId)) {
                $rejectionReasons.Add("[$relPath] Duplicate requirement ID detected: $reqId")
            }

            $startIdx = $reqMatches[$i].Index
            $endIdx = if ($i + 1 -lt $reqMatches.Count) { $reqMatches[$i + 1].Index } else { $content.Length }
            $reqBlock = $content.Substring($startIdx, $endIdx - $startIdx)

            $hasInputOrDepends = $reqBlock -match '(-\s*\*\*\u5165\u529B.*?\*\*:|DependsOn|\u5148\u884C\u4F9D\u5B58\u95A2\u4FC2)'
            $hasProcessOrBody = $reqBlock -match '(-\s*\*\*\u51E6\u7406\*\*:|-\s*\*\*\u6982\u8981\*\*:)'
            $hasAcceptanceOrDod = $reqBlock -match '(-\s*\*\*\u5B8C\u4E86\u57FA\u6E96\s*\(DoD\)\*\*:|Acceptance Criteria|\u691C\u8A3C\u57FA\u6E96)'

            if (-not ($hasInputOrDepends -and $hasProcessOrBody -and $hasAcceptanceOrDod)) {
                $rejectionReasons.Add("[$relPath] Requirement '$reqId' is missing mandatory structure (Input/DependsOn, Process/Body, or DoD/Acceptance Criteria).")
            }

            $digestBlock = if ($reqBlock.Length -gt 900) {
                $reqBlock.Substring(0, 900) + "`n... [Verified full block length: $($reqBlock.Length) chars]"
            } else {
                $reqBlock
            }
            [void]$combinedSpecBuilder.AppendLine($digestBlock.Trim())
            [void]$combinedSpecBuilder.AppendLine("---")
        }
    }

    if ($seenReqIds.Count -eq 0) {
        [Console]::Error.WriteLine("[AI-ADAPTER REJECT] Zero requirement IDs (REQ-*) found across bundle files.")
        exit 3
    }

    $allSpecText = [System.IO.File]::ReadAllText((Join-Path $rootFull $files[0].Path), $utf8NoBom)
    foreach ($fe in ($files | Select-Object -Skip 1)) {
        $allSpecText += "`n" + [System.IO.File]::ReadAllText((Join-Path $rootFull $fe.Path), $utf8NoBom)
    }
    $digestSpecText = if ($allSpecText.Length -le 65000) { $allSpecText } else { $combinedSpecBuilder.ToString() }

    # Check Article 0 Section 3: 5 Mandatory KINTAI Domain Alignment Axes
    $domainAxes = @(
        @{ Name = "Axis 1 (Working Hours & Breaks)"; Pattern = '(?:\u4F11\u61A9|30\u5206|60\u5206|\u52B4\u508D\u6642\u9593)' },
        @{ Name = "Axis 2 (Labor Standards Act Art. 37 & Rounding)"; Pattern = '(?:\u52B4\u508D\u57FA\u6E96\u6CD5\u7B2C37\u6761|\u5272\u5897|25%|\u7AEF\u6570)' },
        @{ Name = "Axis 3 (Concurrency & Pessimistic Lock)"; Pattern = '(?:FOR UPDATE|\u60B2\u89B3\u7684\u30ED\u30C3\u30AF)' },
        @{ Name = "Axis 4 (Audit Trail & Immutable History)"; Pattern = '(?:\u76E3\u67FB\u8A3C\u8DE1|audit_log|\u4FEE\u6B63\u7406\u7531|\u5909\u66F4\u5C65\u6574|\u539F\u672C)' },
        @{ Name = "Axis 5 (IDOR & Multi-Tenant Isolation)"; Pattern = '(?:SecurityContext|IDOR|ROLE_OWNER|\u591A\u5E97\u8217|\u30C6\u30CA\u30F3\u30C8)' }
    )
    foreach ($axis in $domainAxes) {
        if ($allSpecText -notmatch $axis.Pattern) {
            $rejectionReasons.Add("Article 0 Section 3 violation: Missing mandatory domain coverage for $($axis.Name).")
        }
    }

    if ($rejectionReasons.Count -gt 0) {
        foreach ($reason in $rejectionReasons) {
            [Console]::Error.WriteLine("[AI-ADAPTER REJECT] $reason")
        }
        exit 3
    }

    # 5. Live AI Audit Execution via call_ai.ps1
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $callAiPath = Join-Path $scriptDir "call_ai.ps1"
    if (-not (Test-Path -LiteralPath $callAiPath)) {
        [Console]::Error.WriteLine("[AI-ADAPTER ERROR] call_ai.ps1 not found at: $callAiPath")
        exit 4
    }

    $scratchDir = Join-Path $rootFull "scratch\runs"
    if (-not (Test-Path -LiteralPath $scratchDir)) {
        New-Item -ItemType Directory -Path $scratchDir -Force | Out-Null
    }
    $promptFile = Join-Path $scratchDir "stage3_audit_prompt_${RunId}.txt"

    $auditPrompt = @"
You are the Stage 3 Constitutional AI Auditor for the KINTAI SRS Approval Gate.
Audit the target SRS specification bundle against the Article 0 Constitution below.

=== ARTICLE 0 CONSTITUTION (SHA256: $articleHash) ===
$articleText

=== AUDIT BUNDLE METADATA ===
RunId: $RunId
BundleSha256: $bundleHash
Total Requirements Extracted: $($seenReqIds.Count)
Requirement IDs: $(($seenReqIds | Sort-Object) -join ', ')

=== TARGET SPECIFICATION CONTENT (ALL $($seenReqIds.Count) REQUIREMENTS) ===
$digestSpecText

=== AUDIT INSTRUCTIONS ===
1. Verify compliance with Article 0 Sections 1 through 5 (Fail-Closed, unique REQ-* IDs, 5 mandatory KINTAI domain axes: working hours/breaks, Labor Standards Act Article 37 overtime/night rates & rounding, SELECT FOR UPDATE pessimistic locking, audit trail preservation, and IDOR/multi-tenant isolation). Note: If the target file is a modular domain slice (e.g. Slice 1 Store/Member/Contract), verify that all 5 domain axes are properly specified either in its requirements or in its cross-slice handoff boundary sections (Sections 2 and 4).
2. ZERO-PROSE 5-TOKEN PASS CONTRACT: If the target specification complies with Article 0 with zero statutory contradictions, respond EXCLUSIVELY with the minimal 5-token JSON:
{"verdict": "PASS"}
Do not include any conversational commentary, introductory text, markdown fences, or explanations.
If and only if defects or statutory contradictions exist (P0/P1/P2), output a fenced json code block with keys "verdict" ("FAIL" or "WARN") and "findings" (array of defect objects with "id", "severity" ["P0","P1","P2","INFO"], and "description"), followed by the final line "Verdict: FAIL" (or "Verdict: WARN").
"@

    [System.IO.File]::WriteAllText($promptFile, $auditPrompt, $utf8NoBom)

    try {
        $pwshExe = (Get-Command pwsh, powershell -ErrorAction SilentlyContinue | Select-Object -First 1).Source
        if (-not $pwshExe) {
            [Console]::Error.WriteLine("[AI-ADAPTER ERROR] PowerShell executable not found.")
            exit 4
        }

        [Console]::Error.WriteLine("[AI-ADAPTER] Invoking call_ai.ps1 (Provider: $Provider, RunId: $RunId)...")

        $stage3SystemPrompt = 'You are the Stage 3 Constitutional AI Auditor for the KINTAI SRS Approval Gate. Respond strictly in English. Verify whether the specification satisfies the Article 0 Constitution (Sections 1-5). ZERO-PROSE CONTRACT: If fully compliant, output strictly and exclusively {"verdict": "PASS"}. If defects exist, output a concise explanation and a fenced json block with keys verdict (FAIL or WARN) and findings (array of defect objects), ending with Verdict: FAIL.'

        $pinfo = New-Object System.Diagnostics.ProcessStartInfo
        $pinfo.FileName = $pwshExe
        $pinfo.WorkingDirectory = $rootFull
        $pinfo.UseShellExecute = $false
        $pinfo.RedirectStandardOutput = $true
        $pinfo.RedirectStandardError = $true
        $pinfo.StandardOutputEncoding = $utf8NoBom
        $pinfo.StandardErrorEncoding = $utf8NoBom
        $pinfo.CreateNoWindow = $true
        $pinfo.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$callAiPath`" -Provider $Provider -PromptFile `"$promptFile`" -SystemPrompt `"$stage3SystemPrompt`" -TimeoutSeconds $TimeoutSeconds"

        $auditStartUtc = [System.DateTime]::UtcNow.AddSeconds(-2)
        $proc = [System.Diagnostics.Process]::Start($pinfo)
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        if (-not $proc.WaitForExit(($TimeoutSeconds + 30) * 1000)) {
            try { $proc.Kill() } catch {}
            [Console]::Error.WriteLine("[AI-ADAPTER ERROR] call_ai.ps1 timed out.")
            exit 4
        }
        [void][System.Threading.Tasks.Task]::WaitAll(@($stdoutTask, $stderrTask), 5000)

        $childOut = $stdoutTask.Result
        $childErr = $stderrTask.Result
        if (-not [string]::IsNullOrWhiteSpace($childOut)) {
            [Console]::Error.WriteLine($childOut.Trim())
        }
        if (-not [string]::IsNullOrWhiteSpace($childErr)) {
            [Console]::Error.WriteLine($childErr.Trim())
        }

        $aiExitCode = $proc.ExitCode
        $proc.Dispose()

        # Locate the newly generated sidecar verdict.json from this audit invocation
        $auditRunsDir = Join-Path $rootFull "audit\runs"
        $latestSidecar = $null
        if (Test-Path -LiteralPath $auditRunsDir) {
            $latestSidecar = Get-ChildItem -Path $auditRunsDir -Filter "verdict.json" -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.LastWriteTimeUtc -ge $auditStartUtc } |
                Sort-Object LastWriteTimeUtc -Descending |
                Select-Object -First 1
        }

        if (-not $latestSidecar) {
            [Console]::Error.WriteLine("[AI-ADAPTER ERROR] AI runner did not produce a fresh verdict.json sidecar (ExitCode: $aiExitCode).")
            exit 4
        }

        $sidecarObj = ($utf8NoBom.GetString([System.IO.File]::ReadAllBytes($latestSidecar.FullName))) | ConvertFrom-Json
        if (-not $sidecarObj -or $sidecarObj.schema -ne "audit-verdict/v1" -or [string]::IsNullOrWhiteSpace($sidecarObj.response_sha256)) {
            [Console]::Error.WriteLine("[AI-ADAPTER ERROR] Invalid or incomplete sidecar schema at: $($latestSidecar.FullName)")
            exit 4
        }

        $aiVerdict = ([string]$sidecarObj.verdict).Trim().ToUpperInvariant()
        $p0p1Count = [int]$sidecarObj.p0_p1_count

        [Console]::Error.WriteLine("[AI-ADAPTER] AI Sidecar verified: $($latestSidecar.FullName) (Verdict: $aiVerdict, P0/P1: $p0p1Count, ResponseSHA256: $($sidecarObj.response_sha256))")

        if ($aiVerdict -ne "PASS" -or $p0p1Count -gt 0) {
            $rejectOut = ([ordered]@{
                RunId        = $RunId
                BundleSha256 = $bundleHash
                Verdict      = if ($aiVerdict -eq "WARN") { "WARN" } else { "REJECT" }
            }) | ConvertTo-Json -Compress
            [Console]::WriteLine($rejectOut)
            exit 3
        }

        if ($aiExitCode -ne 0) {
            [Console]::Error.WriteLine("[AI-ADAPTER ERROR] AI audit process exited with non-zero code ($aiExitCode).")
            exit 4
        }

        $passOut = ([ordered]@{
            RunId        = $RunId
            BundleSha256 = $bundleHash
            Verdict      = "PASS"
        }) | ConvertTo-Json -Compress
        [Console]::WriteLine($passOut)
        exit 0
    }
    finally {
        if (Test-Path -LiteralPath $promptFile) {
            Remove-Item -LiteralPath $promptFile -Force -ErrorAction SilentlyContinue
        }
    }
}
catch {
    [Console]::Error.WriteLine("[AI-ADAPTER EXCEPTION] $($_.Exception.Message)")
    exit 4
}
