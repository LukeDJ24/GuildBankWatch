<#
.SYNOPSIS
	Converts GuildBankWatch SavedVariables into a CSV file.
.DESCRIPTION
	Reads GuildBankWatch.lua from every WoW retail account's SavedVariables
	folder and writes all recorded guild bank transactions to one CSV.

	NOTE: WoW only writes SavedVariables to disk on logout or /reload, so the
	export reflects the state at your last logout/reload, not live data.
.PARAMETER WowPath
	Path to the World of Warcraft install folder (the one containing _retail_).
.PARAMETER OutFile
	Path of the CSV file to write.
.EXAMPLE
	.\Export-GuildBankWatch.ps1
.EXAMPLE
	.\Export-GuildBankWatch.ps1 -WowPath 'D:\Games\World of Warcraft' -OutFile C:\temp\gbank.csv
#>
[CmdletBinding()]
param(
	[string]$WowPath = 'C:\Program Files (x86)\World of Warcraft',
	[string]$OutFile = (Join-Path (Get-Location) 'GuildBankWatch-export.csv')
)

$ErrorActionPreference = 'Stop'

$pattern = Join-Path $WowPath '_retail_\WTF\Account\*\SavedVariables\GuildBankWatch.lua'
$files = @(Get-ChildItem -Path $pattern -File -ErrorAction SilentlyContinue)
if ($files.Count -eq 0) {
	Write-Error "No GuildBankWatch.lua found matching '$pattern'. Check -WowPath, and log out of WoW at least once with the addon enabled."
}

function Convert-LuaEscapes([string]$s) {
	$sb = [System.Text.StringBuilder]::new()
	for ($i = 0; $i -lt $s.Length; $i++) {
		$c = $s[$i]
		if ($c -eq '\' -and $i + 1 -lt $s.Length) {
			$i++
			switch ($s[$i]) {
				'n' { [void]$sb.Append("`n") }
				't' { [void]$sb.Append("`t") }
				default { [void]$sb.Append($s[$i]) } # \" \\ \' etc.
			}
		} else {
			[void]$sb.Append($c)
		}
	}
	$sb.ToString()
}

$actionLabels = @{ 1 = 'Item Withdraw'; 2 = 'Item Deposit'; 3 = 'Gold Withdraw'; 4 = 'Gold Deposit'; 5 = 'Repair'; 9 = 'Unattributed' }
$rows = [System.Collections.Generic.List[object]]::new()

foreach ($file in $files) {
	$account = $file.Directory.Parent.Name

	# Line-oriented parse of the known SavedVariables shape. A stack of table
	# names tracks where we are; records are the only quoted-string array
	# entries in the file, and guild names are the only ["name"] fields.
	$stack = [System.Collections.Generic.Stack[string]]::new()
	$guildNames = @{}
	$guildRecords = @{}

	foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
		$trim = $line.Trim()
		if ($trim -match '^\},?$') {
			if ($stack.Count -gt 0) { [void]$stack.Pop() }
			continue
		}
		if ($trim -match '^\[?"?(?<key>[^"\[\]]+?)"?\]?\s*=\s*\{$') {
			$stack.Push($Matches.key)
			continue
		}
		$path = $stack.ToArray() # index 0 = innermost table
		if ($path.Length -ge 2 -and $path[1] -eq 'guilds' -and
			$trim -match '^\["name"\]\s*=\s*"(?<val>.*)",$') {
			$guildNames[$path[0]] = Convert-LuaEscapes $Matches.val
			continue
		}
		if ($path.Length -ge 3 -and $path[0] -eq 'records' -and $path[2] -eq 'guilds' -and
			$trim -match '^"(?<rec>.*)",\s*--\s*\[\d+\]$') {
			$guildKey = $path[1]
			if (-not $guildRecords.ContainsKey($guildKey)) {
				$guildRecords[$guildKey] = [System.Collections.Generic.List[string]]::new()
			}
			$guildRecords[$guildKey].Add($Matches.rec)
		}
	}

	foreach ($guildKey in $guildRecords.Keys) {
		$guild = if ($guildNames.ContainsKey($guildKey)) { $guildNames[$guildKey] } else { $guildKey }
		foreach ($rec in $guildRecords[$guildKey]) {
			# Record format (written by Core.lua):
			# epoch|code|player|itemID|itemName|count|copper|tab
			$fields = (Convert-LuaEscapes $rec) -split '\|'
			if ($fields.Count -lt 8) { continue }
			$epoch = 0L
			if (-not [long]::TryParse($fields[0], [ref]$epoch)) { continue }
			$code = 0
			[void][int]::TryParse($fields[1], [ref]$code)
			$rows.Add([pscustomobject]@{
				DateTimeUTC  = [DateTimeOffset]::FromUnixTimeSeconds($epoch).UtcDateTime.ToString('yyyy-MM-dd HH:mm')
				Guild        = $guild
				Character    = $fields[2]
				Action       = if ($actionLabels.ContainsKey($code)) { $actionLabels[$code] } else { "$code" }
				ItemID       = $fields[3]
				ItemName     = $fields[4]
				Count        = $fields[5]
				GoldCopper   = $fields[6]
				Tab          = $fields[7]
				Unattributed = if ($code -eq 9) { 1 } else { 0 }
				Account      = $account
			})
		}
	}
}

if ($rows.Count -eq 0) {
	Write-Warning 'No transactions found. Visit the guild bank in game with the addon enabled, then log out and re-run.'
}

$rows | Sort-Object Guild, DateTimeUTC | Export-Csv -Path $OutFile -NoTypeInformation -Encoding UTF8
Write-Host "Wrote $($rows.Count) transaction(s) to $OutFile"
