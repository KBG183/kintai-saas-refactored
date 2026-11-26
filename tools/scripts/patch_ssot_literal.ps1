<#
.SYNOPSIS
    Deterministic Pure Literal Text Patch Forwarder (Redirected to Unified patch_ssot.ps1)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TargetFile = "config/srs_specification_ssot.md",

    [Parameter(Mandatory = $false)]
    [string]$TargetText = "",

    [Parameter(Mandatory = $false)]
    [string]$TargetTextFile = "",

    [Parameter(Mandatory = $false)]
    [string]$ReplacementText = "",

    [Parameter(Mandatory = $false)]
    [string]$ReplacementTextFile = "",

    [Parameter(Mandatory = $false)]
    [switch]$AllowMultiple = $false
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$unifiedPatcher = Join-Path $scriptDir "patch_ssot.ps1"

$patcherArgs = @{
    TargetFile = $TargetFile
}
if ($TargetText) { $patcherArgs["TargetText"] = $TargetText }
if ($TargetTextFile) { $patcherArgs["TargetTextFile"] = $TargetTextFile }
if ($ReplacementText) { $patcherArgs["ReplacementText"] = $ReplacementText }
if ($ReplacementTextFile) { $patcherArgs["ReplacementTextFile"] = $ReplacementTextFile }
if ($AllowMultiple) { $patcherArgs["AllowMultiple"] = $true }

& powershell -ExecutionPolicy Bypass -File $unifiedPatcher @patcherArgs
exit $LASTEXITCODE
