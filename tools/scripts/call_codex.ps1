<#
.SYNOPSIS
    OpenAI Codex CLI Invocation Forwarder (Redirected to Unified call_ai.ps1)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$Prompt = "",

    [Parameter(Mandatory = $false)]
    [string]$PromptFile = "",

    [Parameter(Mandatory = $false)]
    [string]$ContextFile = "",

    [Parameter(Mandatory = $false)]
    [string]$Model = "",

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 180,

    [Parameter(Mandatory = $false)]
    [switch]$VerboseOutput = $false
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$unifiedRunner = Join-Path $scriptDir "call_ai.ps1"

$runnerParams = @{
    Provider       = "Codex"
    TimeoutSeconds = $TimeoutSeconds
}
$tempPromptFile = $null
try {
    if ($Prompt -and -not $PromptFile) {
        $tempPromptFile = [System.IO.Path]::GetTempFileName()
        [System.IO.File]::WriteAllText($tempPromptFile, $Prompt, [System.Text.Encoding]::UTF8)
        $runnerParams["PromptFile"] = $tempPromptFile
    } elseif ($PromptFile) {
        $runnerParams["PromptFile"] = $PromptFile
    }
    if ($ContextFile) { $runnerParams["ContextFile"] = $ContextFile }
    if ($Model) { $runnerParams["Model"] = $Model }

    & $unifiedRunner @runnerParams
    exit $LASTEXITCODE
} finally {
    if ($tempPromptFile -and (Test-Path -LiteralPath $tempPromptFile)) {
        Remove-Item -LiteralPath $tempPromptFile -Force -ErrorAction SilentlyContinue
    }
}
