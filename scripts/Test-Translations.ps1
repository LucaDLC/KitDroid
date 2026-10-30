# Controlla scripts\strings.json: ogni lingua deve avere le stesse voci dell'inglese e gli stessi segnaposto {0}/{1}.
# Da lanciare dopo aver modificato una traduzione.
#
# Checks scripts\strings.json: every language must have the same keys as English and the same {0}/{1} placeholders.
# Run it after editing a translation.
$ErrorActionPreference = 'Stop'
$file = Join-Path $PSScriptRoot 'strings.json'
$json = [IO.File]::ReadAllText($file) | ConvertFrom-Json
$langs = @($json.PSObject.Properties.Name)
$en = $json.en
$keys = @($en.PSObject.Properties.Name)
function Placeholders([string]$s) { @([regex]::Matches($s, '\{\d+\}') | ForEach-Object Value | Sort-Object -Unique) -join ',' }

$problems = 0
foreach ($l in $langs) {
    $d = $json.$l
    $have = @($d.PSObject.Properties.Name)
    foreach ($k in $keys) {
        if ($have -notcontains $k) { Write-Host "[$l] missing key: $k" -ForegroundColor Red; $problems++; continue }
        if ((Placeholders $d.$k) -ne (Placeholders $en.$k)) {
            Write-Host "[$l] $k : placeholders '$(Placeholders $d.$k)' differ from English '$(Placeholders $en.$k)'" -ForegroundColor Red; $problems++
        }
        if ([string]::IsNullOrWhiteSpace($d.$k)) { Write-Host "[$l] $k is empty" -ForegroundColor Red; $problems++ }
    }
    foreach ($k in $have) { if ($keys -notcontains $k) { Write-Host "[$l] unknown key: $k" -ForegroundColor Yellow; $problems++ } }
}
"{0} languages, {1} keys each: {2}" -f $langs.Count, $keys.Count, $(if ($problems -eq 0) { 'all consistent' } else { "$problems problem(s)" })
if ($problems) { exit 1 }
