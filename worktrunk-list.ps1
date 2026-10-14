param(
    [Parameter(Mandatory = $true)][string]$Worktrunk,
    [Parameter(Mandatory = $true)][string]$Repository
)

# Tern's 50 ms callback budget includes CreateProcess. Starting the large
# Worktrunk executable can exceed it on Windows; PowerShell starts quickly and
# performs that launch outside the plugin callback. Arguments remain literal.
$encoding = New-Object System.Text.UTF8Encoding($false)
[Console]::OutputEncoding = $encoding
$OutputEncoding = $encoding
& $Worktrunk -C $Repository list --format=json
exit $LASTEXITCODE
