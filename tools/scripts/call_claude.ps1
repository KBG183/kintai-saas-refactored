<#
.SYNOPSIS
    Anthropic Claude API Invocation Forwarder (Redirected to Unified call_ai.ps1)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false, Position = 0)]
    [string]$Prompt,

    [Parameter(Mandatory = $false)]
    [string]$PromptFile,

    [Parameter(Mandatory = $false)]
    [string]$ContextFile,

    [Parameter(Mandatory = $false)]
    [string]$System = "",

    [Parameter(Mandatory = $false)]
    [string]$Model = "claude-sonnet-5-5",

    [Parameter(Mandatory = $false)]
    [int]$MaxTokens = 8192,

    [Parameter(Mandatory = $false)]
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$unifiedRunner = Join-Path $scriptDir "call_ai.ps1"

$runnerParams = @{
    Provider = "Claude"
    Model    = $Model
}
if ($Prompt) { $runnerParams["Prompt"] = $Prompt }
if ($PromptFile) { $runnerParams["PromptFile"] = $PromptFile }
if ($ContextFile) { $runnerParams["ContextFile"] = $ContextFile }
if ($System) { $runnerParams["SystemPrompt"] = $System }
if ($Quiet) { $runnerParams["Quiet"] = $true }

& powershell -ExecutionPolicy Bypass -File $unifiedRunner @runnerParams
exit $LASTEXITCODE
