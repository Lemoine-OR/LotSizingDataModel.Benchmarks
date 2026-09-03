param([string]$PackageRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
if([string]::IsNullOrWhiteSpace($PackageRoot)){throw "PackageRoot is required"}
$issues=New-Object System.Collections.ArrayList;$files=@(Get-ChildItem -LiteralPath $PackageRoot -Filter "*.ps1" -File -Recurse)
foreach($f in $files){$c=[IO.File]::ReadAllText($f.FullName);foreach($ch in $c.ToCharArray()){if([int][char]$ch -gt 127){[void]$issues.Add($f.FullName+": non-ASCII");break}};if($c -match "(?i)start_ini\.bat"){[void]$issues.Add($f.FullName+": generator invocation forbidden")};$names=@();foreach($l in($c -split "`r?`n")){if($l -match '^\s*\$(?<n>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*New-Object\s+System\.Collections\.Generic\.List'){$names+=$Matches['n']}};foreach($n in $names){if([regex]::IsMatch($c,'@\(\$'+[regex]::Escape($n)+'\)')){[void]$issues.Add($f.FullName+": unsafe Generic.List wrapper $"+$n)}}}
if($issues.Count-gt0){foreach($i in $issues){Write-Error $i};throw "Safety guard failed"};Write-Host ("Safety guard passed for "+$files.Count+" PowerShell files.");Write-Host "No generator invocation detected. ASCII and Generic.List guards passed."
