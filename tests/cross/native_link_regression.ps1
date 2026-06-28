# Native-link regression guardrail for Windows.
#
# Windows counterpart of native_link_regression.sh. It builds a tiny program
# natively (Windows -> Windows) with -show-system-calls and enforces the same
# two tiers of checks:
#
#   Tier A (always enforced):
#     * the native build must NOT hit the cross-compile "not yet supported" path;
#     * a native linker SYSTEM CALL ("[SYSTEM CALL] *-link") must be emitted
#       (msvc-link / msvc-lld-link / msvc-rad-link);
#     * structural tokens that src/linker.cpp emits as string literals for the
#       MSVC link command must all be present.
#
#   Tier B: the full normalized native link command line is diffed against a
#   checked-in baseline; if none exists it is auto-recorded and the run passes.
#
# Regenerate the Tier B baseline after an intentional, reviewed change:
#       pwsh tests/cross/native_link_regression.ps1 -Update
# and commit the updated baseline file.

param(
	[switch]$Update
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot  = (Resolve-Path (Join-Path $ScriptDir "..\..")).Path

$Odin = $env:ODIN
if ([string]::IsNullOrEmpty($Odin)) {
	$Odin = Join-Path $RepoRoot "odin.exe"
	if (-not (Test-Path $Odin)) { $Odin = Join-Path $RepoRoot "odin" }
}

$Src      = Join-Path $ScriptDir "hello.odin"
$Baseline = Join-Path $ScriptDir "baselines\windows_native_link.txt"

# Structural tokens emitted as string literals by src/linker.cpp for the MSVC
# (default) Windows link path. A regression in the additive cross work would
# most likely drop one of these from the native command line.
$RequiredTokens = @(
	"-OUT:",
	"/nologo",
	"/subsystem:"
)

$Work = Join-Path ([System.IO.Path]::GetTempPath()) ("odin_cross_" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $Work | Out-Null
try {
	$Out    = Join-Path $Work "hello_regression.exe"
	$RawLog = Join-Path $Work "raw.log"

	Write-Host "[native-link-regression] building $Src natively with $Odin"
	& $Odin build $Src -file -show-system-calls -keep-temp-files -out:"$Out" > $RawLog 2>&1
	$BuildRc = $LASTEXITCODE

	$Raw = Get-Content -Raw $RawLog
	if ($BuildRc -ne 0) {
		Write-Host "[native-link-regression] FAIL: native build returned non-zero exit ($BuildRc)"
		Write-Host "----- build output -----"; Write-Host $Raw; Write-Host "------------------------"
		exit 1
	}

	# Tier A.1: native builds must never hit the cross "not yet supported" path.
	if ($Raw -match "(?i)not yet supported") {
		Write-Host "[native-link-regression] FAIL: native build hit the cross-compile 'not yet supported' path."
		Write-Host "    The cross changes leaked into the native link path -- they must be additive."
		Write-Host $Raw
		exit 1
	}

	# Extract the last [SYSTEM CALL] block whose tag ends in "-link".
	$Lines = Get-Content $RawLog
	$LinkerTag = ""
	$LinkerCmd = ""
	for ($i = 0; $i -lt $Lines.Count; $i++) {
		if ($Lines[$i] -match '^\[SYSTEM CALL\] (.*-link)\s*$') {
			$LinkerTag = $Matches[1]
			if ($i + 1 -lt $Lines.Count) { $LinkerCmd = $Lines[$i + 1] }
		}
	}

	# Tier A.2: a native link step with a native linker tag must have run.
	if ([string]::IsNullOrWhiteSpace($LinkerTag) -or [string]::IsNullOrWhiteSpace($LinkerCmd)) {
		Write-Host "[native-link-regression] FAIL: no native linker SYSTEM CALL was found."
		Write-Host "    Expected a '[SYSTEM CALL] *-link' line from src/linker.cpp."
		Write-Host "----- build output -----"; Write-Host $Raw; Write-Host "------------------------"
		exit 1
	}

	# Tier A.3: required structural tokens must all be present.
	$Missing = $false
	foreach ($tok in $RequiredTokens) {
		if ($LinkerCmd -notlike "*$tok*") {
			Write-Host "[native-link-regression] FAIL: native link command line is missing required token: '$tok'"
			$Missing = $true
		}
	}
	if ($Missing) {
		Write-Host "----- native link command line -----"
		Write-Host "[SYSTEM CALL] $LinkerTag"
		Write-Host $LinkerCmd
		Write-Host "------------------------------------"
		exit 1
	}

	function Normalize-Cmd([string]$tag, [string]$cmd) {
		$text = "TAG: $tag`nCMD: $cmd"
		$text = $text.Replace($Work, "<WORK>")
		$text = $text.Replace($Out, "<OUT>")
		$text = $text.Replace($RepoRoot, "<ROOT>")
		$text = [Regex]::Replace($text, '"[^"]*\.o"', '"<OBJ>"')
		$text = [Regex]::Replace($text, '[A-Za-z]:\\[^ "]*\\', '<PATH>\')
		$text = [Regex]::Replace($text, '/opt:lldltojobs=\d+', '/opt:lldltojobs=<N>')
		$text = [Regex]::Replace($text, '\s+', ' ')
		return $text.Trim()
	}

	$Normalized = Normalize-Cmd $LinkerTag $LinkerCmd

	if ($Update) {
		$BaselineDir = Split-Path -Parent $Baseline
		if (-not (Test-Path $BaselineDir)) { New-Item -ItemType Directory -Path $BaselineDir | Out-Null }
		Set-Content -Path $Baseline -Value $Normalized -NoNewline
		Write-Host "[native-link-regression] baseline updated: $Baseline"
		Write-Host "----- new baseline -----"; Write-Host $Normalized; Write-Host "------------------------"
		exit 0
	}

	if (-not (Test-Path $Baseline)) {
		# Auto-bootstrap so a brand-new host does not fail CI spuriously.
		$BaselineDir = Split-Path -Parent $Baseline
		if (-not (Test-Path $BaselineDir)) { New-Item -ItemType Directory -Path $BaselineDir | Out-Null }
		Set-Content -Path $Baseline -Value $Normalized -NoNewline
		Write-Host "[native-link-regression] NOTICE: no Windows baseline; recorded one at:"
		Write-Host "    $Baseline"
		Write-Host "    Commit it so future runs diff against it."
	} else {
		$BaselineText = (Get-Content -Raw $Baseline).Trim()
		if ($BaselineText -ne $Normalized) {
			Write-Host "[native-link-regression] FAIL: native link command line changed vs baseline."
			Write-Host "    If this change is intentional, regenerate the baseline with:"
			Write-Host "        pwsh $($MyInvocation.MyCommand.Path) -Update"
			Write-Host "    and commit $Baseline."
			Write-Host "----- baseline -----"; Write-Host $BaselineText
			Write-Host "----- observed -----"; Write-Host $Normalized
			Write-Host "--------------------"
			exit 1
		}
	}

	Write-Host "[native-link-regression] smoke-running native binary"
	& $Out
	if ($LASTEXITCODE -ne 0) {
		Write-Host "[native-link-regression] FAIL: natively linked binary did not run cleanly."
		exit 1
	}

	Write-Host "[native-link-regression] PASS: native link guardrail OK ($LinkerTag)."
}
finally {
	Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
}
