param(
    [string]$PackageRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($PackageRoot)) {
    throw "PackageRoot is required."
}

$psFiles = @(
    Get-ChildItem -LiteralPath $PackageRoot -Filter "*.ps1" -File -Recurse
)

$errors = New-Object System.Collections.ArrayList

foreach ($file in $psFiles) {
    $content = [System.IO.File]::ReadAllText($file.FullName)

    # PowerShell 5.1 regression guard:
    # do not wrap a Generic.List variable in @($list).
    $genericNames = @()

    foreach ($line in ($content -split "`r?`n")) {
        if ($line -match '^\s*\$(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*New-Object\s+System\.Collections\.Generic\.List') {
            $genericNames += $Matches["name"]
        }
    }

    foreach ($name in $genericNames) {
        $pattern = '@\(\$' + [regex]::Escape($name) + '\)'
        if ([regex]::IsMatch($content, $pattern)) {
            [void]$errors.Add(
                $file.FullName + ": forbidden Generic.List unary-array wrapper for $" + $name
            )
        }
    }

    # ASCII guard.
    foreach ($ch in $content.ToCharArray()) {
        if ([int][char]$ch -gt 127) {
            [void]$errors.Add($file.FullName + ": non-ASCII character detected")
            break
        }
    }
}

if ($errors.Count -gt 0) {
    foreach ($e in $errors) {
        Write-Error $e
    }
    throw "R2 package safety guard failed."
}

Write-Host ("Safety guard passed for " + $psFiles.Count + " PowerShell files.")
