<#
.SYNOPSIS
    Installs Git pre-commit hooks for KINTAI Quality Pipeline.
.DESCRIPTION
    Copies tools/hooks/pre-commit into .git/hooks/pre-commit and ensures executable permissions.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent (Split-Path -Parent $scriptDir)
if (-not (Test-Path (Join-Path $projectRoot ".git"))) {
    $projectRoot = (Get-Location).Path
}

$sourceHook = Join-Path $projectRoot "tools\hooks\pre-commit"
$targetGitHooksDir = Join-Path $projectRoot ".git\hooks"
$targetHook = Join-Path $targetGitHooksDir "pre-commit"

if (-not (Test-Path $sourceHook)) {
    Write-Error "Source hook file not found: $sourceHook"
    exit 1
}

if (-not (Test-Path $targetGitHooksDir)) {
    Write-Error ".git/hooks directory not found. Is this a valid git repository?"
    exit 1
}

Copy-Item -Path $sourceHook -Destination $targetHook -Force
Write-Host "[SUCCESS] Pre-commit hook successfully installed to: $targetHook" -ForegroundColor Green
exit 0
