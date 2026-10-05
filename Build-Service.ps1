<#
.SYNOPSIS
    Builds SakuFix04.Service.exe with the C# compiler that ships with .NET Framework.

.DESCRIPTION
    No SDK is required: csc.exe from the installed .NET Framework 4.x is used directly.
    The release workflow runs this script before packing the ZIP.

.PARAMETER OutputDirectory
    Where to write SakuFix04.Service.exe (default: this directory).
#>
[CmdletBinding()]
param(
    [string]$OutputDirectory = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $compiler)) {
    throw 'The .NET Framework C# compiler (csc.exe) was not found; install .NET Framework 4.x or build on Windows.'
}

$source = Join-Path $PSScriptRoot 'src\SakuFix04.Service.cs'
if (-not (Test-Path -LiteralPath $source)) {
    throw ('{0} not found.' -f $source)
}

if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$output = Join-Path $OutputDirectory 'SakuFix04.Service.exe'
& $compiler /nologo /target:exe /platform:anycpu /optimize+ /out:$output $source
if ($LASTEXITCODE -ne 0) {
    throw ('csc.exe failed with exit code {0}.' -f $LASTEXITCODE)
}

Write-Host ('Built {0}' -f $output)
