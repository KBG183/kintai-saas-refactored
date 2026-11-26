<#
.SYNOPSIS
    Local / Remote Qwen 27B Invocation Forwarder (Redirected to Unified call_ai.ps1)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Prompt,

    [Parameter(Mandatory = $false)]
    [string]$PromptFile,

    [Parameter(Mandatory = $false)]
    [string]$System = "",

    [Parameter(Mandatory = $false)]
    [string]$Model = "qwen3.8:27b",

    [Parameter(Mandatory = $false)]
    [int]$TimeoutSeconds = 300,

    [Parameter(Mandatory = $false)]
    [double]$Temperature = 0.1,

    [Parameter(Mandatory = $false)]
    [int]$Seed = 42,

    [Parameter(Mandatory = $false)]
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$unifiedRunner = Join-Path $scriptDir "call_ai.ps1"

$runnerParams = @{
    Provider       = "Qwen"
    Model          = $Model
    TimeoutSeconds = $TimeoutSeconds
}
if ($Prompt) { $runnerParams["Prompt"] = $Prompt }
if ($PromptFile) { $runnerParams["PromptFile"] = $PromptFile }
if ($Quiet) { $runnerParams["Quiet"] = $true }

& powershell -ExecutionPolicy Bypass -File $unifiedRunner @runnerParams
exit $LASTEXITCODE
