$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-OrderedParity {
    param(
        [Parameter(Mandatory)]
        [string]$Label,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$JapaneseValues,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$KoreanValues,

        [Parameter(Mandatory)]
        [string]$JapanesePath,

        [Parameter(Mandatory)]
        [string]$KoreanPath
    )

    if ($JapaneseValues.Count -ne $KoreanValues.Count) {
        throw ('[{0}] Count mismatch: {1} has {2}, {3} has {4}.' -f
            $Label, $JapanesePath, $JapaneseValues.Count,
            $KoreanPath, $KoreanValues.Count)
    }

    for ($index = 0; $index -lt $JapaneseValues.Count; $index++) {
        if ($JapaneseValues[$index] -cne $KoreanValues[$index]) {
            throw ('[{0}] Position {1}: {2} has "{3}", {4} has "{5}".' -f
                $Label, ($index + 1),
                $JapanesePath, $JapaneseValues[$index],
                $KoreanPath, $KoreanValues[$index])
        }
    }
}

function Get-HeadingValues {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [regex]$Pattern
    )

    $lines = Get-Content -LiteralPath $Path -Encoding UTF8
    foreach ($line in $lines) {
        $match = $Pattern.Match($line)
        if ($match.Success) {
            $match.Groups[1].Value
        }
    }
}

$locationPushed = $false
try {
    $repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).ProviderPath
    Push-Location -LiteralPath $repositoryRoot
    $locationPushed = $true

    $dashboardPath = Join-Path $PSScriptRoot 'sync_dashboard.ps1'
    if (-not (Test-Path -LiteralPath $dashboardPath -PathType Leaf)) {
        throw "[FATAL DASHBOARD SYNC] Script missing: $dashboardPath"
    }

    $shellName = if ($PSVersionTable.PSEdition -eq 'Desktop') {
        'powershell.exe'
    }
    elseif ([System.IO.Path]::DirectorySeparatorChar -eq '\') {
        'pwsh.exe'
    }
    else {
        'pwsh'
    }
    $shellPath = Join-Path $PSHOME $shellName

    # Check the child process exit code explicitly on all supported hosts.
    $PSNativeCommandUseErrorActionPreference = $false
    & $shellPath -NoLogo -NoProfile -NonInteractive -File $dashboardPath
    if ($LASTEXITCODE -ne 0) {
        throw "[FATAL DASHBOARD SYNC] Dashboard sync exited with code $LASTEXITCODE."
    }

    $configPath = Join-Path $repositoryRoot 'config/srs_targets.json'
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 |
        ConvertFrom-Json

    if ($null -eq $config -or
        $null -eq $config.PSObject.Properties['targets'] -or
        $config.targets -isnot [array] -or
        $config.targets.Count -eq 0) {
        throw "[FATAL TARGET CONFIG] Expected a non-empty targets array in $configPath."
    }

    $requirementPattern = [regex]'^#{3,4}\s*\[((?:REQ|CC)-[A-Z0-9_-]+)\]'

    foreach ($target in $config.targets) {
        if ($null -eq $target -or
            $null -eq $target.PSObject.Properties['ja_path'] -or
            $null -eq $target.PSObject.Properties['ko_path'] -or
            $target.ja_path -isnot [string] -or
            $target.ko_path -isnot [string] -or
            [string]::IsNullOrWhiteSpace($target.ja_path) -or
            [string]::IsNullOrWhiteSpace($target.ko_path)) {
            throw "[FATAL TARGET CONFIG] Each target must define non-empty ja_path and ko_path strings."
        }

        $japanesePath = Join-Path $repositoryRoot $target.ja_path
        $koreanPath = Join-Path $repositoryRoot $target.ko_path

        if (-not (Test-Path -LiteralPath $japanesePath)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $japanesePath -PathType Leaf)) {
            throw "[FATAL TARGET CONFIG] Expected a file at $japanesePath."
        }
        if (-not (Test-Path -LiteralPath $koreanPath -PathType Leaf)) {
            Write-Host "[SKIP] Korean mirror not present in clean checkout: $koreanPath" -ForegroundColor DarkGray
            continue
        }

        $japaneseIds = @(Get-HeadingValues -Path $japanesePath -Pattern $requirementPattern)
        $koreanIds = @(Get-HeadingValues -Path $koreanPath -Pattern $requirementPattern)
        Assert-OrderedParity -Label 'FATAL REQUIREMENT PARITY' `
            -JapaneseValues $japaneseIds -KoreanValues $koreanIds `
            -JapanesePath $japanesePath -KoreanPath $koreanPath
    }

    $geminiJapanesePath = Join-Path $repositoryRoot 'GEMINI.md'
    $geminiKoreanPath = Join-Path $repositoryRoot 'GEMINI_KO.md'
    if (Test-Path -LiteralPath $geminiJapanesePath -PathType Leaf) {
        if (Test-Path -LiteralPath $geminiKoreanPath -PathType Leaf) {
            $articlePattern = [regex]'^## (\d+)\.'
            $japaneseArticles = @(Get-HeadingValues -Path $geminiJapanesePath -Pattern $articlePattern)
            $koreanArticles = @(Get-HeadingValues -Path $geminiKoreanPath -Pattern $articlePattern)
            Assert-OrderedParity -Label 'FATAL GEMINI PARITY' `
                -JapaneseValues $japaneseArticles -KoreanValues $koreanArticles `
                -JapanesePath $geminiJapanesePath -KoreanPath $geminiKoreanPath
        } else {
            Write-Host "[SKIP] GEMINI_KO.md not present in clean checkout." -ForegroundColor DarkGray
        }
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
finally {
    if ($locationPushed) {
        Pop-Location
    }
}

Write-Output '[PASS] Dashboard sync and mirror parity checks completed.'
exit 0