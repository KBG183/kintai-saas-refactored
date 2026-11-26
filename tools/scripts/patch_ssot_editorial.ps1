<#
.SYNOPSIS
    Fast-Track Editorial Patch Forwarder (Redirected to Unified patch_ssot.ps1)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TargetText,

    [Parameter(Mandatory = $true)]
    [string]$ReplacementText,

    [Parameter(Mandatory = $false)]
    [string]$TargetFile = "config/srs_specification_ssot.md"
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$unifiedPatcher = Join-Path $scriptDir "patch_ssot.ps1"

& powershell -ExecutionPolicy Bypass -File $unifiedPatcher -TargetFile $TargetFile -TargetText $TargetText -ReplacementText $ReplacementText
exit $LASTEXITCODE
