#requires -Version 5.1
<#
.SYNOPSIS
    Runs the KINTAI SRS preflight, specification lint, and approval gates.

.DESCRIPTION
    Run in a trusted CI checkout with immutable governance, tools, and gate code.
    Protect the manifest and metrics directories from writes by untrusted jobs.
    Consumers must require exit 0 and the manifest from the same CI run.

    The verifier receives the absolute target Markdown paths as separate arguments
    and runs in the repository root. It owns required-field and dependency-graph
    validation, including cycles and dangling references. Its rejection code is 2.

    The AI adapter is a trusted PowerShell script. It receives -RepoRoot, -BundlePath,
    and -RunId. The bundle is UTF-8 JSON containing the target paths and hashes.
    The adapter must independently audit the complete bundle, validate the completed
    model response, and return 3 for rejection or 4 for an incomplete/invalid audit.
    On success its stdout must contain exactly one JSON object, optionally fenced,
    with RunId, BundleSha256, and Verdict ("PASS"). Write diagnostics to stderr.

    Queue formats: an array of finding objects, or an object with a findings array.
    Each finding needs a status. Configure terminal statuses to match queue policy.
    Requirement IDs are case-sensitive. Every matching occurrence in the supplied
    Markdown scope participates in the uniqueness check, including references.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Get-Location).Path,
    [string] $TargetId = '',
    [string[]] $TargetPath = @('config/srs_specification_ssot.md'),
    [string] $AiAuditScript = 'tools/scripts/audit_srs.ps1',
    [string[]] $TerminalStatus = @('CLOSED', 'VERIFIED'),
    [ValidateRange(1, 86400)]
    [int] $TimeoutSeconds = 900,
    [switch] $SkipAi
)

if ($TargetId) {
    $tCfgFile = [System.IO.Path]::Combine($RepoRoot, 'config', 'srs_targets.json')
    if ([System.IO.File]::Exists($tCfgFile)) {
        $tCfgObj = [System.IO.File]::ReadAllText($tCfgFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        if ($TargetId -eq 'all' -or $TargetId -eq 'required') {
            $TargetPath = @($tCfgObj.targets | Where-Object { $_.required -eq $true } | ForEach-Object { $_.ja_path })
        } else {
            $tMatch = $tCfgObj.targets | Where-Object { $_.id -eq $TargetId } | Select-Object -First 1
            if ($tMatch) {
                $TargetPath = @($tMatch.ja_path)
            }
        }
    }
}

if (-not (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue)) {
    $script:IsWindows = [System.Environment]::OSVersion.Platform -match 'Win'
    Set-Variable -Name IsWindows -Value $script:IsWindows -Scope Global -ErrorAction SilentlyContinue
}
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [Text.UTF8Encoding]::new($false, $true)
$runId = [guid]::NewGuid().ToString('D')
$started = [datetimeoffset]::UtcNow
$clock = [Diagnostics.Stopwatch]::StartNew()
$exitCode = 4
$stage = 0
$lock = $null
$manifest = $null
$metrics = $null
$tempManifest = $null
$bundlePath = $null
$files = @()
$pending = 0
$resolved = 0
$lockOwned = $false

function Get-RootPath([string] $Path) {
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($script:root, $Path))
}

function Get-RelativePath([string] $BasePath, [string] $TargetFullPath) {
    if ($TargetFullPath.StartsWith($BasePath, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $TargetFullPath.Substring($BasePath.Length).TrimStart('\', '/')
    }
    return $TargetFullPath
}

function Get-Hash([byte[]] $Bytes) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $hash = ([System.BitConverter]::ToString($sha.ComputeHash($Bytes)) -replace "-", "").ToLowerInvariant()
    $sha.Dispose()
    return $hash
}

function Get-FileHashValue([string] $Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hash = ([System.BitConverter]::ToString($sha.ComputeHash($stream)) -replace "-", "").ToLowerInvariant()
        $sha.Dispose()
        return $hash
    }
    finally { $stream.Dispose() }
}

function Read-StrictText([byte[]] $Bytes) {
    $value = $script:utf8.GetString($Bytes)
    if ($value.StartsWith([string][char]0xFEFF, [StringComparison]::Ordinal)) {
        $value = $value.Substring(1)
    }
    if ($value.Contains([char]0)) {
        throw [IO.InvalidDataException]::new('Unexpected NUL in text input.')
    }
    return $value
}

function Get-Targets {
    $names = [Collections.Generic.HashSet[string]]::new(
        $(if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase }
          else { [StringComparer]::Ordinal })
    )
    foreach ($entry in $TargetPath) {
        if ([string]::IsNullOrWhiteSpace($entry)) { throw 'Blank target selector.' }
        $path = Get-RootPath $entry
        if ([IO.Directory]::Exists($path)) {
            foreach ($item in Get-ChildItem -LiteralPath $path -Recurse -File -Force -Filter '*.md') {
                [void]$names.Add($item.FullName)
            }
        }
        elseif ([IO.File]::Exists($path) -and [IO.Path]::GetExtension($path) -ieq '.md') {
            [void]$names.Add($path)
        }
        else { throw "Missing or invalid Markdown target: $path" }
    }
    $sorted = [string[]]@($names)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    foreach ($path in $sorted) {
        $relative = Get-RelativePath $script:root $path
        if ([IO.Path]::IsPathRooted($relative) -or $relative -match '^\.\.([\\/]|$)') {
            throw "Target outside repository: $path"
        }
        $path
    }
}

function Read-JsonDocument([string] $Text) {
    $json = $Text.Trim()
    if ($json.StartsWith('```')) {
        $match = [regex]::Match($json, '(?is)\A```(?:json)?[ \t]*\r?\n(?<body>.*?)\r?\n```[ \t]*\z')
        if (!$match.Success) { throw 'Invalid JSON fence.' }
        $json = $match.Groups['body'].Value
    }
    return ($json | ConvertFrom-Json)
}

function Get-JsonField($Object, [string] $Name) {
    $val = $Object.$Name
    if ($null -eq $val) { throw "Missing JSON field: $Name" }
    return $val
}

function Get-JsonString($Object, [string] $Name) {
    $val = $Object.$Name
    if ($null -eq $val) { throw "Missing string field: $Name" }
    return $val.ToString()
}

function Invoke-Stage {
    param(
        [string] $Executable,
        [string[]] $Arguments,
        [ValidateRange(1, 3)][int] $FailCode
    )
    $process = [Diagnostics.Process]::new()
    $running = $false
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $Executable
        $info.WorkingDirectory = $script:root
        $info.UseShellExecute = $false
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.StandardOutputEncoding = $script:utf8
        $info.StandardErrorEncoding = $script:utf8
        $escapedArgs = @()
        foreach ($argValue in $Arguments) {
            if ($argValue -match '[\s"]') {
                $escapedArgs += '"{0}"' -f ($argValue -replace '"', '\"')
            } else {
                $escapedArgs += $argValue
            }
        }
        $info.Arguments = ($escapedArgs -join ' ')
        $process.StartInfo = $info
        if (!$process.Start()) { throw "Could not start $Executable." }
        $running = $true
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $limit = $TimeoutSeconds * 1000
        if (!$process.WaitForExit($limit)) { throw "Process timed out: $Executable" }
        $remaining = [int][Math]::Max(0L, $limit - $timer.ElapsedMilliseconds)
        if (![Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout, $stderr), $remaining)) {
            throw "Process streams timed out: $Executable"
        }
        if ($stderr.Result) { [Console]::Error.WriteLine($stderr.Result) }
        $code = $process.ExitCode
        if ($code -notin @(0, $FailCode, 4)) {
            [Console]::Error.WriteLine("Unexpected exit code $code from $Executable.")
            $code = 4
        }
        return @{ Code = $code; Output = $stdout.Result }
    }
    catch {
        [Console]::Error.WriteLine($_.Exception.Message)
        return @{ Code = 4; Output = '' }
    }
    finally {
        try {
            if ($running -and !$process.HasExited) {
                $process.Kill($true)
                if (!$process.WaitForExit(5000)) { throw 'Child termination failed.' }
            }
        }
        finally { $process.Dispose() }
    }
}

function Get-Commit {
    $gitResult = Invoke-Stage $script:git @('rev-parse', '--verify', 'HEAD^{commit}') 3
    $sha = $gitResult.Output.Trim()
    if ($gitResult.Code -ne 0 -or $sha -cnotmatch '\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z') {
        throw 'Unable to establish the Git commit SHA.'
    }
    return $sha
}

function Invoke-Gate {
    $script:stage = 1
    $failure = 0
    $article = Get-RootPath 'governance/ARTICLE_0_SRS.md'
    $checksum = Get-RootPath 'governance/ARTICLE_0_SRS.sha256'
    $queue = Get-RootPath 'queue/srs_pending_findings.json'
    foreach ($essential in @($article, $checksum, $queue)) {
        if (![IO.File]::Exists($essential)) {
            [Console]::Error.WriteLine("Missing essential file: $essential")
            $failure = 1
        }
    }
    if ([IO.File]::Exists($article) -and [IO.File]::Exists($checksum)) {
        try {
            $articleHash = Get-FileHashValue $article
            $checksumBytes = [IO.File]::ReadAllBytes($checksum)
            $checksumHash = Get-Hash $checksumBytes
            $line = (Read-StrictText $checksumBytes).Trim()
            if ($line -notmatch '\A([0-9a-fA-F]{64})(?:[ \t]+\*?(?:\./)?ARTICLE_0_SRS\.md)?\z' -or
                $Matches[1] -ine $articleHash) { throw 'Article 0 checksum mismatch or malformed digest.' }
        }
        catch { [Console]::Error.WriteLine($_.Exception.Message); $failure = 1 }
    }

    $script:files = @(Get-Targets)
    if (!$files.Count) { [Console]::Error.WriteLine('Zero Markdown targets.'); $failure = 4 }
    $records = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $duplicates = [Collections.Generic.List[string]]::new()
    $scanComplete = $true
    foreach ($path in $files) {
        try {
            $bytes = [IO.File]::ReadAllBytes($path)
            $body = Read-StrictText $bytes
            $relative = (Get-RelativePath $script:root $path).Replace('\', '/')
            $records.Add([ordered]@{ Path = $relative; Sha256 = Get-Hash $bytes })
            foreach ($m in [regex]::Matches($body, '(?m)^#{2,4}\s*\[?(REQ-[A-Z0-9_-]+)\]?')) {
                $reqId = $m.Groups[1].Value
                if (-not $seen.ContainsKey($reqId)) {
                    $seen[$reqId] = $relative
                } else {
                    $duplicates.Add("$reqId in $relative (first seen in $($seen[$reqId]))")
                }
            }
        }
        catch {
            [Console]::Error.WriteLine("$path - $($_.Exception.Message)")
            $scanComplete = $false
            $failure = [Math]::Max(1, $failure)
        }
    }
    if ($scanComplete -and !$seen.Count) {
        [Console]::Error.WriteLine('Zero requirement IDs.')
        $failure = 4
    }
    $exe = Get-RootPath 'tools/scripts/VerifySRS.exe'
    $verifierScript = Get-RootPath 'tools/scripts/verify_srs.ps1'
    $adapter = Get-RootPath $AiAuditScript
    $pwsh = (Get-Command pwsh, powershell -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    $gitCommand = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$gitCommand -or ![IO.File]::Exists($pwsh) -or
        (![IO.File]::Exists($exe) -and ![IO.File]::Exists($verifierScript)) -or
        (!$SkipAi -and ![IO.File]::Exists($adapter))) {
        [Console]::Error.WriteLine('Missing required pipeline tool.')
        $failure = 4
    }
    if ($failure) { return $failure }
    $script:git = $gitCommand.Source
    $shellArgs = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File')

    $script:stage = 2
    foreach ($duplicate in $duplicates) { [Console]::Error.WriteLine("Duplicate requirement: $duplicate") }
    if ([IO.File]::Exists($exe)) {
        $lint = Invoke-Stage $exe $files 2
    }
    else {
        $lint = Invoke-Stage $pwsh ($shellArgs + @($verifierScript) + $files) 2
    }
    if ($lint.Output) { [Console]::Error.WriteLine($lint.Output) }
    if ($lint.Code) { return $lint.Code }
    if ($duplicates.Count) { return 2 }

    $script:stage = 3
    if ($SkipAi) { [Console]::Error.WriteLine('Approval blocked: AI audit required.'); return 3 }

    try {
        $queueBytes = [IO.File]::ReadAllBytes($queue)
        $queueHash = Get-Hash $queueBytes
        $doc = Read-JsonDocument (Read-StrictText $queueBytes)
        $items = if ($null -ne $doc.findings) { $doc.findings } else { @() }
        if ($null -ne $items -and $items.Count -gt 0) {
            foreach ($item in $items) {
                $status = (Get-JsonString $item 'status').Trim().ToUpperInvariant()
                switch ($status) {
                    'PENDING'  { $script:pending++ }
                    'RESOLVED' { $script:resolved++ }
                    default {
                        if (!$status -or $status -notin $TerminalStatus) { throw "Unknown finding status: $status" }
                    }
                }
            }
        }
        if ($pending + $resolved -gt 0) {
            [Console]::Error.WriteLine("Approval blocked: PENDING=$pending RESOLVED=$resolved")
            $failure = 3
        }
    }
    catch { [Console]::Error.WriteLine($_.Exception.Message); $failure = 4 }

    $commit = Get-Commit
    $bundle = [ordered]@{
        RunId = $runId
        GitCommitSha = $commit
        ConstitutionSha256 = $articleHash
        Files = $records.ToArray()
    }
    [IO.File]::WriteAllText($script:bundlePath, ($bundle | ConvertTo-Json -Depth 8), $script:utf8)
    $bundleHash = Get-FileHashValue $script:bundlePath
    $audit = Invoke-Stage $pwsh ($shellArgs + @(
        $adapter, '-RepoRoot', $script:root, '-BundlePath', $script:bundlePath, '-RunId', $runId
    )) 3
    $failure = [Math]::Max($failure, [int]$audit.Code)
    if ($audit.Code -eq 0) {
        $report = Read-JsonDocument $audit.Output
        try {
            $verdict = Get-JsonString $report 'Verdict'
            if ((Get-JsonString $report 'RunId') -cne $runId -or
                (Get-JsonString $report 'BundleSha256') -ine $bundleHash) {
                throw 'AI report does not match this run and bundle.'
            }
            switch -CaseSensitive ($verdict) {
                'PASS' {}
                'REJECT' { $failure = [Math]::Max($failure, 3) }
                default { throw "Invalid AI verdict: $verdict" }
            }
        }
        catch { [Console]::Error.WriteLine($_.Exception.Message); $failure = 4 }
    }
    if ($failure) { return $failure }

    $current = @(Get-Targets)
    if ($current.Count -ne $files.Count -or (Get-Commit) -cne $commit -or
        (Get-FileHashValue $article) -cne $articleHash -or
        (Get-FileHashValue $checksum) -cne $checksumHash -or
        (Get-FileHashValue $queue) -cne $queueHash -or
        (Get-FileHashValue $script:bundlePath) -cne $bundleHash) {
        throw 'Gate inputs changed during validation.'
    }
    for ($i = 0; $i -lt $files.Count; $i++) {
        if ($current[$i] -cne $files[$i] -or
            (Get-FileHashValue $files[$i]) -cne $records[$i].Sha256) {
            throw "Markdown target changed during validation: $($files[$i])"
        }
    }
    $bundle['Timestamp'] = [datetimeoffset]::UtcNow.ToString('o')
    $bundle['AuditBundleSha256'] = $bundleHash
    [IO.File]::WriteAllText($script:tempManifest, ($bundle | ConvertTo-Json -Depth 8), $script:utf8)
    return 0
}

try {
    $script:root = (Get-Item -LiteralPath $RepoRoot).FullName; $root = $script:root
    $metricsDir = Get-RootPath 'metrics'
    [void][IO.Directory]::CreateDirectory($metricsDir)
    $metrics = Join-Path $metricsDir 'srs_pipeline_metrics.csv'
    $lock = [IO.File]::Open((Join-Path $metricsDir 'srs_pipeline.lock'),
        [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $lockOwned = $true
    $approved = Get-RootPath 'approved'
    [void][IO.Directory]::CreateDirectory($approved)
    $manifest = Join-Path $approved 'approval_manifest.json'
    [IO.File]::Delete($manifest)
    $tempManifest = Join-Path $approved ".$runId.manifest.tmp"
    $bundlePath = Join-Path $metricsDir ".$runId.bundle.json"
    $exitCode = Invoke-Gate
    if ($exitCode -isnot [int] -or $exitCode -notin @(0, 1, 2, 3, 4)) {
        throw 'Invalid gate result.'
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.ToString())
    $exitCode = 4
}
finally {
    try {
        if ($bundlePath) { [IO.File]::Delete($bundlePath) }
        if ($exitCode -eq 0) { [IO.File]::Move($tempManifest, $manifest) }
    }
    catch { [Console]::Error.WriteLine($_.Exception.ToString()); $exitCode = 4 }

    try {
        if ($tempManifest) { [IO.File]::Delete($tempManifest) }
    }
    catch { [Console]::Error.WriteLine($_.Exception.ToString()); $exitCode = 4 }

    try {
        if (!$metrics) { throw 'Metrics path unavailable.' }
        $stream = [IO.File]::Open($metrics, [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try {
            $header = if ($stream.Length -eq 0) {
                "RunId,StartedUtc,DurationMs,LastStage,Targets,PendingObserved,ResolvedObserved,ExitCode`n"
            } else { '' }
            [void]$stream.Seek(0, [IO.SeekOrigin]::End)
            $line = @($runId, $started.ToString('o'), $clock.ElapsedMilliseconds,
                $stage, $files.Count, $pending, $resolved, $exitCode) -join ','
            $data = $utf8.GetBytes("$header$line`n")
            $stream.Write($data, 0, $data.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
    }
    catch { [Console]::Error.WriteLine($_.Exception.ToString()); $exitCode = 4 }

    try {
        if ($lockOwned -and $exitCode -ne 0 -and $manifest) { [IO.File]::Delete($manifest) }
    }
    catch { [Console]::Error.WriteLine($_.Exception.ToString()); $exitCode = 4 }
    finally { if ($lock) { $lock.Dispose() } }
}
exit $exitCode