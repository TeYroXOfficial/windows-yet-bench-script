#Requires -Version 5.1
<#
.SYNOPSIS
    Yet-Another-Bench-Script - Windows (PowerShell) port.

.DESCRIPTION
    Windows port of yabs.sh by Mason Rowe (https://github.com/masonr/yet-another-bench-script).

    Gauges the performance of a Windows machine:
      * disk    - fio.exe if available, otherwise a built-in unbuffered (direct I/O) random R/W test
      * network - iperf3.exe against public iperf3 servers
      * system  - Geekbench 4/5/6 (portable Windows build, downloaded on demand)

    Runs in Windows PowerShell 5.1, PowerShell 7+, from cmd.exe (via wybs.cmd) and Windows Terminal.
    Does not require administrator privileges.

.EXAMPLE
    .\wybs.ps1
.EXAMPLE
    .\wybs.ps1 -SkipGeekbench -ReduceNet
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\wybs.ps1 -PrintJson
#>

[CmdletBinding()]
param(
    # -f / -d : skip the disk benchmark
    [Alias('f', 'd')][switch]$SkipDisk,
    # -i : skip the iperf3 network test
    [Alias('i')][switch]$SkipIperf,
    # -g : skip the Geekbench test
    [Alias('g')][switch]$SkipGeekbench,
    # -n : skip the network information lookup
    [Alias('n')][switch]$SkipNet,
    # -r : reduce the number of iperf3 locations to three
    [Alias('r')][switch]$ReduceNet,
    # Geekbench version selection (GB6 is the default)
    [switch]$GB4,
    [switch]$GB5,
    [switch]$GB6,
    [switch]$GB9,
    # -j / -w / -s : JSON output options
    [Alias('j')][switch]$PrintJson,
    [Alias('w')][string]$JsonFile,
    [Alias('s')][string]$JsonSend,
    # -p : custom iperf servers "host:ports:name:location:modes,..."
    [Alias('p')][string]$IperfServers,
    # explicit paths to external tools
    [string]$FioPath,
    [string]$IperfPath,
    [string]$GeekbenchPath,
    # ignore a locally installed fio and always use the built-in disk test
    [switch]$BuiltinDisk,
    # where downloaded tools are cached (default: <script dir>\bin\win)
    [string]$BinDir,
    # never download anything; use only what is already present
    [switch]$NoDownload,
    # built-in disk test tuning
    [ValidateRange(1, 4096)][int]$DiskThreads = 32,
    [ValidateRange(5, 600)][int]$DiskRuntime = 30,
    [string]$DiskSize,
    # plain ASCII output for legacy consoles
    [switch]$Ascii,
    # do not wait for a keypress before the window closes
    [switch]$NoPause,
    # where to save a copy of the full output (default: .\wybs-<timestamp>.txt)
    [string]$LogFile,
    # do not save the output to a file and do not touch the clipboard
    [switch]$NoLog,
    [Alias('h')][switch]$Help
)

$YABS_NAME = 'Windows-Yet-Bench-Script'
$YABS_VERSION = 'v2026-07-03-win'
$YABS_URL = 'https://github.com/TeYroXOfficial/windows-yet-bench-script'

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# locale / console setup
# ---------------------------------------------------------------------------
# The Linux script exports LC_ALL=C so numbers always parse with a period as the
# decimal separator. The equivalent here is pinning the thread culture to the
# invariant culture (a pl-PL host would otherwise format "1,23" and break parsing).
[System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture
[System.Threading.Thread]::CurrentThread.CurrentUICulture = [System.Globalization.CultureInfo]::InvariantCulture

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# PowerShell 5.1 defaults to TLS 1.0, which most of the endpoints below reject.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor
        [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
} catch { }

if ($Ascii) {
    $script:OK_MARK = '[+]'
    $script:NO_MARK = '[-]'
} else {
    $script:OK_MARK = [string][char]0x2714
    $script:NO_MARK = [string][char]0x274C
}

# When the script is piped into iex / run as a scriptblock there is no file path,
# so fall back to the working directory (that is where bin\ and logs then live).
$script:ScriptDir = $null
if ($MyInvocation.MyCommand.Path) {
    $script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $script:ScriptDir) { $script:ScriptDir = (Get-Location).Path }

# ---------------------------------------------------------------------------
# small output helpers
# ---------------------------------------------------------------------------
# every printed line is mirrored here so the whole run can be saved / copied afterwards
$script:LogLines = New-Object System.Collections.Generic.List[string]

function Out-Line {
    param([string]$Text = '')
    Clear-Status
    Write-Host $Text
    $script:LogLines.Add($Text)
}

$script:StatusLen = 0

# Prints a transient status line (the equivalent of `echo -en "...\r\033[0K"`).
function Write-Status {
    param([string]$Text)
    Clear-Status
    Write-Host -NoNewline $Text
    $script:StatusLen = $Text.Length
}

function Clear-Status {
    if ($script:StatusLen -gt 0) {
        Write-Host -NoNewline ("`r" + (' ' * $script:StatusLen) + "`r")
        $script:StatusLen = 0
    }
}

# Writes the full run to a text file and puts it on the clipboard, so the results
# survive the console window being closed (and can be pasted somewhere).
$script:LogSaved = $false
function Save-Output {
    if ($NoLog -or $script:LogSaved) { return }
    $script:LogSaved = $true

    $stamp = $TIME_START
    if (-not $stamp) { $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss') }
    $path = $LogFile
    if (-not $path) { $path = Join-Path (Get-Location).Path "wybs-$stamp.txt" }

    $text = ($script:LogLines -join "`r`n")

    $copied = $false
    try {
        Set-Clipboard -Value $text -ErrorAction Stop
        $copied = $true
    } catch {
        try { $text | clip.exe; $copied = $true } catch { }
    }

    try {
        [System.IO.File]::WriteAllText($path, $text + "`r`n", (New-Object System.Text.UTF8Encoding($true)))
        Out-Line
        Out-Line "Results saved to : $path"
    } catch {
        Out-Line
        Out-Line "Could not write the results file: $($_.Exception.Message)"
    }
    if ($copied) { Out-Line 'Results copied to the clipboard - just paste them anywhere.' }
}

# Keeps the console window open once the run is over. Only Enter/Esc/Q close it, so
# selecting text with the mouse and copying it with Ctrl+C does not kill the window.
# Skipped when stdin is not a console (piped/redirected/CI) so it can never hang.
function Wait-ForKey {
    if ($NoPause) { return }
    try { if ([Console]::IsInputRedirected) { return } } catch { return }
    Out-Line
    Out-Line 'Done. Select text with the mouse to copy it; press Enter, Esc or Q to close this window.'
    try {
        # drop any keystroke already buffered (e.g. the Enter that launched the run)
        $Host.UI.RawUI.FlushInputBuffer()
        while ($true) {
            $k = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            # ignore anything held with Ctrl or Alt (Ctrl+C is "copy" here, not "quit")
            if (([int]$k.ControlKeyState -band 0x000F) -ne 0) { continue }
            if (@(13, 27, 81) -contains [int]$k.VirtualKeyCode) { break }
        }
    } catch {
        try { $null = Read-Host } catch { Start-Sleep -Seconds 60 }
    }
}

# Catches any terminating error so the window still stays open (and the temp
# directory still gets removed) instead of flashing shut.
trap {
    # An error can fire before the helpers below are defined, so nothing here may
    # assume they exist - otherwise the trap masks the real failure.
    if (Get-Command Clear-Status -ErrorAction SilentlyContinue) { Clear-Status }
    Write-Host ''
    Write-Host ('WYBS aborted: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ('  at line ' + $_.InvocationInfo.ScriptLineNumber + ': ' + $_.InvocationInfo.Line.Trim())
    $tmp = Get-Variable -Name YABS_PATH -Scope Script -ErrorAction SilentlyContinue
    if ($tmp -and $tmp.Value -and (Test-Path -LiteralPath $tmp.Value)) {
        Remove-Item -LiteralPath $tmp.Value -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Get-Command Save-Output -ErrorAction SilentlyContinue) { Save-Output }
    if (Get-Command Wait-ForKey -ErrorAction SilentlyContinue) { Wait-ForKey }
    exit 1
}

function Out-Row {
    param([string[]]$Cells, [int[]]$Widths, [string[]]$Align)
    $parts = @()
    for ($i = 0; $i -lt $Cells.Count; $i++) {
        $w = $Widths[$i]
        $c = $Cells[$i]
        if ($Align -and $Align[$i] -eq 'r') {
            $parts += $c.PadLeft($w)
        } else {
            $parts += $c.PadRight($w)
        }
    }
    Out-Line (($parts -join ' | ').TrimEnd())
}

# ---------------------------------------------------------------------------
# formatting helpers (ports of format_size / format_speed / format_iops)
# ---------------------------------------------------------------------------

# Formats a raw size given in kibibytes into KiB/MiB/GiB/TiB.
function Format-Size {
    param($Raw)
    if ($null -eq $Raw -or $Raw -eq '') { return '' }
    [double]$v = 0
    if (-not [double]::TryParse([string]$Raw, [ref]$v)) { return '' }

    $denom = 1.0; $unit = 'KiB'
    if ($v -ge 1073741824) { $denom = 1073741824.0; $unit = 'TiB' }
    elseif ($v -ge 1048576) { $denom = 1048576.0; $unit = 'GiB' }
    elseif ($v -ge 1024) { $denom = 1024.0; $unit = 'MiB' }

    return ('{0:F1} {1}' -f ($v / $denom), $unit)
}

# Formats a raw disk speed given in KiB/s into KB/s, MB/s or GB/s (decimal units,
# matching the upstream script's conversion).
function Format-Speed {
    param($Raw)
    if ($null -eq $Raw -or $Raw -eq '') { return '' }
    [double]$v = 0
    if (-not [double]::TryParse([string]$Raw, [ref]$v)) { return '' }

    if ($v -ge 976563) { return ('{0:F2} GB/s' -f ($v * 1024 / 1000000000)) }
    if ($v -ge 977) { return ('{0:F2} MB/s' -f ($v * 1024 / 1000000)) }
    return ('{0:F2} KB/s' -f ($v * 1024 / 1000))
}

# Formats raw IOPS (e.g. 8, 123, 1.7k, 275.9k).
function Format-Iops {
    param($Raw)
    if ($null -eq $Raw -or $Raw -eq '') { return '' }
    [double]$v = 0
    if (-not [double]::TryParse([string]$Raw, [ref]$v)) { return '' }
    if ($v -ge 1000) { return ('{0:F1}k' -f ($v / 1000)) }
    return ('{0:F0}' -f $v)
}

function ConvertTo-JsonString {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    # note: in a -replace replacement string only '$' is special, backslashes are literal
    $t = $Text -replace '\\', '\\'
    $t = $t -replace '"', '\"'
    $t = $t -replace "`r", ' '
    $t = $t -replace "`n", ' '
    $t = $t -replace "`t", ' '
    return $t
}

# ---------------------------------------------------------------------------
# process helper: run a native binary with a hard timeout, return stdout
# ---------------------------------------------------------------------------
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSec = 60,
        [string]$WorkingDirectory,
        # iperf3 reports "unable to connect" on stderr; merging it in lets callers
        # detect a dead server instead of burning three attempts on it
        [switch]$IncludeStderr
    )

    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    $text = ''
    try {
        $spArgs = @{
            FilePath               = $FilePath
            NoNewWindow            = $true
            PassThru               = $true
            RedirectStandardOutput = $outFile
            RedirectStandardError  = $errFile
        }
        if ($Arguments -and $Arguments.Count -gt 0) { $spArgs['ArgumentList'] = $Arguments }
        if ($WorkingDirectory) { $spArgs['WorkingDirectory'] = $WorkingDirectory }

        $proc = Start-Process @spArgs
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill() } catch { }
            try { $proc.WaitForExit(5000) | Out-Null } catch { }
        }
        Start-Sleep -Milliseconds 100
        if (Test-Path -LiteralPath $outFile) {
            $text = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
        }
        if ($IncludeStderr -and (Test-Path -LiteralPath $errFile)) {
            $errText = Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue
            if ($errText) { $text = "$text`n$errText" }
        }
    } catch {
        $text = ''
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
    if ($null -eq $text) { $text = '' }
    return $text
}

function Get-ToolPath {
    param([string]$Explicit, [string]$Command, [string[]]$Candidates)

    if ($Explicit) {
        if (Test-Path -LiteralPath $Explicit) { return (Resolve-Path -LiteralPath $Explicit).Path }
        return $null
    }
    $cmd = Get-Command $Command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    foreach ($c in $Candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    return $null
}

function Invoke-Download {
    param([string]$Uri, [string]$OutFile, [int]$TimeoutSec = 120)
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'yabs-windows')
        $wc.DownloadFile($Uri, $OutFile)
        $wc.Dispose()
        return (Test-Path -LiteralPath $OutFile)
    } catch {
        return $false
    }
}

# The Geekbench Browser sits behind a Cloudflare challenge that rejects .NET's HTTP
# stack outright (403), while curl.exe - shipped with Windows 10 1803+ - gets a 200
# with an ordinary browser User-Agent. So curl is tried first and Invoke-WebRequest
# is only the fallback.
$script:BrowserUA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36'
$script:CurlExe = $null
$curlCmd = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($curlCmd) { $script:CurlExe = $curlCmd.Source }

function Invoke-HttpGet {
    param([string]$Uri, [int]$TimeoutSec = 10)

    if ($script:CurlExe) {
        try {
            $lines = & $script:CurlExe -s -L --compressed -A $script:BrowserUA --max-time $TimeoutSec $Uri
            if ($LASTEXITCODE -eq 0 -and $lines) { return ($lines -join "`n") }
        } catch { }
    }
    try {
        return (Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec $TimeoutSec -UserAgent $script:BrowserUA).Content
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# banner
# ---------------------------------------------------------------------------

# Draws the framed header. The frame is sized from the longest line, so renaming
# the project or bumping the version can never knock the box out of alignment.
function Write-Banner {
    param([string[]]$Lines)

    $longest = ($Lines | Measure-Object -Property Length -Maximum).Maximum
    # border is '#' + ' ##' * groups + ' #', i.e. 3*groups+3 wide, 3*groups+1 inside
    $groups = [int][Math]::Ceiling(($longest + 1) / 3.0)
    $inner = 3 * $groups + 1
    $border = '#' + (' ##' * $groups) + ' #'

    Out-Line $border
    foreach ($line in $Lines) {
        $pad = $inner - $line.Length
        $left = [int]($pad / 2)
        Out-Line ('#' + (' ' * $left) + $line + (' ' * ($pad - $left)) + '#')
    }
    Out-Line $border
}

Write-Banner @($YABS_NAME, $YABS_VERSION, $YABS_URL)
Out-Line
Out-Line (Get-Date).ToString('ddd MMM dd HH:mm:ss yyyy')

$TIME_START = (Get-Date).ToString('yyyyMMdd-HHmmss')
$YABS_START_TIME = [long]([System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds())

# ---------------------------------------------------------------------------
# architecture
# ---------------------------------------------------------------------------
$archRaw = $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITEW6432) { $archRaw = $env:PROCESSOR_ARCHITEW6432 }
switch -Regex ($archRaw) {
    'AMD64' { $ARCH = 'x64'; break }
    'ARM64' { $ARCH = 'aarch64'; break }
    'ARM'   { $ARCH = 'arm'; break }
    'x86'   { $ARCH = 'x86'; break }
    default { $ARCH = 'x64' }
}
if ($ARCH -eq 'aarch64' -or $ARCH -eq 'arm') {
    Out-Line
    Out-Line 'ARM compatibility is considered *experimental*'
}

# Geekbench version flags (GB6 by default, same behaviour as the shell script)
$runGB4 = $false; $runGB5 = $false; $runGB6 = $true
if ($GB4) { $runGB4 = $true; $runGB6 = $false }
if ($GB5) { $runGB5 = $true; $runGB6 = $false }
if ($GB9) { $runGB4 = $true; $runGB5 = $true; $runGB6 = $false }
if ($GB6) { $runGB6 = $true }
if ($SkipGeekbench) { $runGB4 = $false; $runGB5 = $false; $runGB6 = $false }

if (-not $DiskSize) {
    if ($ARCH -eq 'aarch64' -or $ARCH -eq 'arm') { $DiskSize = '512M' } else { $DiskSize = '2G' }
}

function ConvertFrom-SizeString {
    param([string]$Text)
    if ($Text -match '^\s*(\d+(?:\.\d+)?)\s*([KMGT])?[Bb]?\s*$') {
        $n = [double]$Matches[1]
        switch ($Matches[2]) {
            'K' { return [long]($n * 1KB) }
            'M' { return [long]($n * 1MB) }
            'G' { return [long]($n * 1GB) }
            'T' { return [long]($n * 1TB) }
            default { return [long]$n }
        }
    }
    return 2GB
}
$DiskSizeBytes = ConvertFrom-SizeString $DiskSize

# ---------------------------------------------------------------------------
# on-demand tool provisioning, cached under .\bin\win\<arch>
# ---------------------------------------------------------------------------
if (-not $BinDir) { $BinDir = Join-Path $script:ScriptDir 'bin\win' }
# Windows on ARM runs x64 binaries under emulation, so aarch64 reuses the x64 assets.
$script:BinArch = $ARCH
if ($ARCH -eq 'aarch64' -or $ARCH -eq 'arm') { $script:BinArch = 'x64' }
$script:BinArchDir = Join-Path $BinDir $script:BinArch

# Pinned official releases together with the SHA-256 of the exact asset. A hash
# mismatch aborts the install - better no fio than an unexpected binary.
$script:ToolCatalog = @{
    'fio' = @{
        'x64' = @{
            Url    = 'https://github.com/axboe/fio/releases/download/fio-3.42/fio-3.42-x64.msi'
            Sha256 = 'D6BC1C0EB7A4B3BD2810E6C0CE605917A4671CC126C9DAE5BE7EB4891464A5C6'
            Kind   = 'msi'
            Exe    = 'fio.exe'
        }
        'x86' = @{
            Url    = 'https://github.com/axboe/fio/releases/download/fio-3.42/fio-3.42-x86.msi'
            Sha256 = '921BA0AD3450F41307A2E8188BD03E9D257B107B9F2F4F30B859914F5515A115'
            Kind   = 'msi'
            Exe    = 'fio.exe'
        }
    }
    'iperf3' = @{
        'x64' = @{
            Url    = 'https://github.com/ar51an/iperf3-win-builds/releases/download/3.21/iperf-3.21-win64.zip'
            Sha256 = '9B73B7E0E0326347B5F4AC4F6A1FC34FE60A5966E5FD172C7BFCD0E1CC93E709'
            Kind   = 'zip'
            Exe    = 'iperf3.exe'
        }
    }
}

function Get-CachedTool {
    param([string]$Name)
    $def = $script:ToolCatalog[$Name]
    if (-not $def -or -not $def[$script:BinArch]) { return $null }
    $p = Join-Path $script:BinArchDir $def[$script:BinArch].Exe
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

# Downloads a pinned release into the bin cache and returns the path to the binary.
function Install-BinTool {
    param([string]$Name)

    $cached = Get-CachedTool $Name
    if ($cached) { return $cached }

    $def = $null
    if ($script:ToolCatalog[$Name]) { $def = $script:ToolCatalog[$Name][$script:BinArch] }
    if (-not $def) {
        Out-Line ("No Windows build of {0} is available for {1}." -f $Name, $ARCH)
        return $null
    }
    if ($NoDownload) {
        Out-Line ("{0} is missing and -NoDownload was given." -f $Name)
        return $null
    }

    $target = Join-Path $script:BinArchDir $def.Exe
    New-Item -ItemType Directory -Path $script:BinArchDir -Force | Out-Null
    $tmpDir = Join-Path $env:TEMP ('yabs-' + [System.Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

    try {
        $pkg = Join-Path $tmpDir ([System.IO.Path]::GetFileName($def.Url))
        Write-Status ("Downloading {0} from {1} ..." -f $Name, $def.Url)
        $downloaded = Invoke-Download -Uri $def.Url -OutFile $pkg
        Clear-Status
        if (-not $downloaded) {
            Out-Line ("Download of {0} failed: {1}" -f $Name, $def.Url)
            return $null
        }

        $hash = (Get-FileHash -LiteralPath $pkg -Algorithm SHA256).Hash
        if ($def.Sha256 -and $hash -ne $def.Sha256) {
            Out-Line ("SHA-256 mismatch for {0} - refusing to use the download." -f $Name)
            Out-Line ("  expected: {0}" -f $def.Sha256)
            Out-Line ("  got     : {0}" -f $hash)
            return $null
        }

        if ($def.Kind -eq 'zip') {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            $zip = [System.IO.Compression.ZipFile]::OpenRead($pkg)
            try {
                foreach ($entry in $zip.Entries) {
                    if (-not $entry.Name) { continue }   # directory entry
                    $dest = Join-Path $script:BinArchDir $entry.Name
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
                }
            } finally { $zip.Dispose() }
        } else {
            # administrative install: unpacks the MSI without installing and without admin rights
            $extract = Join-Path $tmpDir 'msi'
            New-Item -ItemType Directory -Path $extract -Force | Out-Null
            $proc = Start-Process msiexec.exe -Wait -PassThru -WindowStyle Hidden -ArgumentList @(
                '/a', ('"' + $pkg + '"'), '/qn', ('TARGETDIR="' + $extract + '"')
            )
            if ($proc.ExitCode -ne 0) {
                Out-Line ("msiexec failed (exit {0}) while unpacking {1}." -f $proc.ExitCode, $Name)
                return $null
            }
            $found = Get-ChildItem -Path $extract -Filter $def.Exe -Recurse -File -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $found) {
                Out-Line ("{0} was not found inside the downloaded package." -f $def.Exe)
                return $null
            }
            Copy-Item -LiteralPath $found.FullName -Destination $target -Force
        }

        if (Test-Path -LiteralPath $target) {
            Out-Line ("Installed {0} -> {1}" -f $Name, $target)
            return $target
        }
        Out-Line ("Could not place {0} in {1}." -f $def.Exe, $script:BinArchDir)
        return $null
    } finally {
        Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# local tool detection
# ---------------------------------------------------------------------------
$FIO_CMD = Get-ToolPath -Explicit $FioPath -Command 'fio' -Candidates @(
    (Join-Path $script:BinArchDir 'fio.exe'),
    (Join-Path $script:ScriptDir 'fio.exe'),
    (Join-Path $env:ProgramFiles 'fio\fio.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'fio\fio.exe')
)
$IPERF_CMD = Get-ToolPath -Explicit $IperfPath -Command 'iperf3' -Candidates @(
    (Join-Path $script:BinArchDir 'iperf3.exe'),
    (Join-Path $script:ScriptDir 'iperf3.exe'),
    (Join-Path $env:ProgramFiles 'iPerf3\iperf3.exe'),
    (Join-Path $env:ProgramFiles 'iperf3\iperf3.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'iPerf3\iperf3.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\iPerf3\iperf3.exe')
)
if ($BuiltinDisk) { $FIO_CMD = $null }

# ---------------------------------------------------------------------------
# connectivity check
# ---------------------------------------------------------------------------
function Test-IpConnectivity {
    param([int]$Version)
    $uri = if ($Version -eq 6) { 'https://ipv6.icanhazip.com' } else { 'https://ipv4.icanhazip.com' }
    try {
        $r = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 6
        if ($r.Content -and $r.Content.Trim().Length -gt 0) { return $true }
    } catch { }
    return $false
}

$IPV4_CHECK = Test-IpConnectivity 4
$IPV6_CHECK = Test-IpConnectivity 6
if (-not $IPV4_CHECK -and -not $IPV6_CHECK) {
    Out-Line
    Out-Line 'Warning: Both IPv4 AND IPv6 connectivity were not detected. Check for DNS issues...'
}

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------
if ($Help) {
    Out-Line
    Out-Line 'Usage: .\wybs.ps1 [-flags]'
    Out-Line '       wybs.cmd [-flags]                      (from cmd.exe)'
    Out-Line '       powershell -NoProfile -ExecutionPolicy Bypass -File .\wybs.ps1 [-flags]'
    Out-Line
    Out-Line 'Flags:'
    Out-Line '       -SkipDisk (-f/-d) : skips the disk benchmark test'
    Out-Line '       -SkipIperf (-i)   : skips the iperf3 network test'
    Out-Line '       -SkipGeekbench (-g): skips the geekbench performance test'
    Out-Line '       -SkipNet (-n)     : skips the network information lookup and print out'
    Out-Line '       -ReduceNet (-r)   : reduce number of iperf3 network locations (to only three)'
    Out-Line '       -GB4 / -GB5 / -GB9 / -GB6 : geekbench version selection (default: GB6)'
    Out-Line '       -PrintJson (-j)   : print jsonified WYBS results at conclusion of test'
    Out-Line '       -JsonFile <file> (-w) : write jsonified WYBS results to disk'
    Out-Line '       -JsonSend <url> (-s)  : send jsonified WYBS results to URL'
    Out-Line '       -IperfServers <s> (-p): custom iperf servers'
    Out-Line '                               format: host:port_range:name:location:network_modes'
    Out-Line '                               example: -IperfServers "example.com:5201-5210:MyServer:New York (10G):IPv4|IPv6"'
    Out-Line '       -FioPath / -IperfPath / -GeekbenchPath <path> : explicit paths to the tools'
    Out-Line '       -BuiltinDisk      : always use the built-in disk test, even if fio.exe exists'
    Out-Line '       -DiskThreads <n>  : worker threads for the built-in disk test (default 32)'
    Out-Line '       -DiskRuntime <s>  : seconds per block size (default 30)'
    Out-Line '       -DiskSize <size>  : test file size, e.g. 2G (default 2G / 512M on ARM)'
    Out-Line '       -BinDir <dir>     : where downloaded tools are cached (default: <script dir>\bin\win)'
    Out-Line '       -NoDownload       : never download anything, use only what is already present'
    Out-Line '       -Ascii            : ASCII-only output for legacy consoles'
    Out-Line '       -NoPause          : close the window immediately instead of waiting for a keypress'
    Out-Line '       -LogFile <file>   : where to save the full output (default: .\wybs-<timestamp>.txt)'
    Out-Line '       -NoLog            : do not save a results file and do not touch the clipboard'
    Out-Line '       -Help (-h)        : prints this lovely message and exits'
    Out-Line
    Out-Line "Detected Arch: $ARCH"
    Out-Line
    Out-Line 'Local Binary Check:'
    if ($FIO_CMD) {
        Out-Line "       fio detected: $FIO_CMD"
    } elseif ($NoDownload) {
        Out-Line '       fio not detected, will use the built-in direct I/O disk test'
    } else {
        Out-Line "       fio not detected, will be downloaded to $script:BinArchDir"
    }
    if ($IPERF_CMD) {
        Out-Line "       iperf3 detected: $IPERF_CMD"
    } elseif ($NoDownload -or -not $script:ToolCatalog['iperf3'][$script:BinArch]) {
        Out-Line '       iperf3 not detected, network speed test will be skipped'
    } else {
        Out-Line "       iperf3 not detected, will be downloaded to $script:BinArchDir"
    }
    Out-Line "       tool cache: $script:BinArchDir"
    Out-Line
    Out-Line 'Detected Connectivity:'
    if ($IPV4_CHECK) { Out-Line '       IPv4 connected' } else { Out-Line '       IPv4 not connected' }
    if ($IPV6_CHECK) { Out-Line '       IPv6 connected' } else { Out-Line '       IPv6 not connected' }
    Out-Line
    Out-Line 'Exiting...'
    Wait-ForKey
    return
}

# ---------------------------------------------------------------------------
# basic system information
# ---------------------------------------------------------------------------
Out-Line
Out-Line 'Basic System Information:'
Out-Line '---------------------------------'

$osInfo = Get-CimInstance Win32_OperatingSystem
$csInfo = Get-CimInstance Win32_ComputerSystem
$cpuInfo = @(Get-CimInstance Win32_Processor)

$uptimeSpan = (Get-Date) - $osInfo.LastBootUpTime
$UPTIME_S = [long]$uptimeSpan.TotalSeconds
$UPTIME = '{0} days, {1} hours, {2} minutes' -f $uptimeSpan.Days, $uptimeSpan.Hours, $uptimeSpan.Minutes
Out-Line "Uptime     : $UPTIME"

$CPU_PROC = ($cpuInfo[0].Name).Trim() -replace '\s+', ' '
Out-Line "Processor  : $CPU_PROC"

$CPU_CORES = ($cpuInfo | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
if (-not $CPU_CORES) { $CPU_CORES = [Environment]::ProcessorCount }
$CPU_PHYS = ($cpuInfo | Measure-Object -Property NumberOfCores -Sum).Sum
$CPU_FREQ = '{0} MHz' -f $cpuInfo[0].MaxClockSpeed
if ($CPU_PHYS -and $CPU_PHYS -ne $CPU_CORES) {
    Out-Line "CPU cores  : $CPU_CORES @ $CPU_FREQ ($CPU_PHYS physical)"
} else {
    Out-Line "CPU cores  : $CPU_CORES @ $CPU_FREQ"
}

# AES-NI detection.
#   * ARM64 : IsProcessorFeaturePresent(PF_ARM_V8_CRYPTO_INSTRUCTIONS_AVAILABLE)
#   * x86/x64 : System.Runtime.Intrinsics (.NET Core only, i.e. PowerShell 7+);
#               on Windows PowerShell 5.1 we shell out to pwsh if it is installed,
#               otherwise the status is genuinely unknown (Windows exposes no
#               documented AES-NI flag to user mode).
function Test-AesNi {
    if ($ARCH -eq 'aarch64' -or $ARCH -eq 'arm') {
        try {
            Add-Type -Namespace Yabs -Name Cpu -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern bool IsProcessorFeaturePresent(uint feature);
'@ -ErrorAction Stop
            return [Yabs.Cpu]::IsProcessorFeaturePresent(30)
        } catch { return $null }
    }

    $t = [type]::GetType('System.Runtime.Intrinsics.X86.Aes, System.Runtime.Intrinsics')
    if (-not $t) { $t = [type]::GetType('System.Runtime.Intrinsics.X86.Aes') }
    if ($t) {
        try { return [bool]$t.GetProperty('IsSupported').GetValue($null, $null) } catch { }
    }

    $pwsh = Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($pwsh) {
        try {
            $res = & $pwsh.Source -NoProfile -Command '[System.Runtime.Intrinsics.X86.Aes]::IsSupported'
            if ($res -match 'True') { return $true }
            if ($res -match 'False') { return $false }
        } catch { }
    }
    return $null
}

$aesSupported = Test-AesNi
if ($null -eq $aesSupported) {
    $CPU_AES_TEXT = '? Unknown (install PowerShell 7 for detection)'
    $CPU_AES_BOOL = 'null'
} elseif ($aesSupported) {
    $CPU_AES_TEXT = "$OK_MARK Enabled"
    $CPU_AES_BOOL = 'true'
} else {
    $CPU_AES_TEXT = "$NO_MARK Disabled"
    $CPU_AES_BOOL = 'false'
}
Out-Line "AES-NI     : $CPU_AES_TEXT"

# VT-x / AMD-V. Note: once Hyper-V (or VBS/Device Guard/WSL2) owns the CPU,
# VMMonitorModeExtensions reports False for the guest-visible processor, so a
# present hypervisor also counts as virtualization being enabled.
$virtEnabled = $false
foreach ($c in $cpuInfo) {
    if ($c.VirtualizationFirmwareEnabled -eq $true -or $c.VMMonitorModeExtensions -eq $true) { $virtEnabled = $true }
}
if ($csInfo.HypervisorPresent -eq $true) { $virtEnabled = $true }
if ($virtEnabled) { $CPU_VIRT_TEXT = "$OK_MARK Enabled" } else { $CPU_VIRT_TEXT = "$NO_MARK Disabled" }
Out-Line "VM-x/AMD-V : $CPU_VIRT_TEXT"

$TOTAL_RAM_RAW = [long]$osInfo.TotalVisibleMemorySize          # KiB
Out-Line ('RAM        : {0}' -f (Format-Size $TOTAL_RAM_RAW))

$TOTAL_SWAP_RAW = [long]$osInfo.SizeStoredInPagingFiles        # KiB
Out-Line ('Swap       : {0}' -f (Format-Size $TOTAL_SWAP_RAW))

$TOTAL_DISK_RAW = 0
foreach ($ld in (Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3')) {
    if ($ld.Size) { $TOTAL_DISK_RAW += [long]($ld.Size / 1024) }
}
Out-Line ('Disk       : {0}' -f (Format-Size $TOTAL_DISK_RAW))

$DISTRO = $osInfo.Caption.Trim()
if ($osInfo.OSArchitecture) { $DISTRO = '{0} ({1})' -f $DISTRO, $osInfo.OSArchitecture }
Out-Line "Distro     : $DISTRO"

$KERNEL = '{0} Build {1}' -f $osInfo.Version, $osInfo.BuildNumber
Out-Line "Kernel     : $KERNEL"

# hypervisor / bare metal detection based on SMBIOS strings
function Get-VirtType {
    $man = "$($csInfo.Manufacturer)"
    $mod = "$($csInfo.Model)"
    $both = "$man $mod"
    switch -Regex ($both) {
        'VMware'                        { return 'VMWARE' }
        'VirtualBox|innotek'            { return 'ORACLE' }
        'QEMU|KVM|Bochs'                { return 'KVM' }
        'Xen'                           { return 'XEN' }
        'Parallels'                     { return 'PARALLELS' }
        'Amazon EC2'                    { return 'AMAZON' }
        'Google (Compute Engine|Cloud)' { return 'GCE' }
        'Alibaba|Aliyun'                { return 'ALIBABA' }
        'OpenStack'                     { return 'OPENSTACK' }
        'Virtual Machine'               { return 'MICROSOFT' }
    }
    $bios = $null
    try { $bios = Get-CimInstance Win32_BIOS } catch { }
    if ($bios -and "$($bios.Manufacturer) $($bios.SMBIOSBIOSVersion)" -match 'VMware|VirtualBox|QEMU|Xen|Hyper-V|Parallels') {
        return 'VM'
    }
    return 'NONE'
}
$VIRT = Get-VirtType
Out-Line "VM Type    : $VIRT"

if ($IPV4_CHECK) { $ONLINE = "$OK_MARK Online / " } else { $ONLINE = "$NO_MARK Offline / " }
if ($IPV6_CHECK) { $ONLINE += "$OK_MARK Online" } else { $ONLINE += "$NO_MARK Offline" }
Out-Line "IPv4/IPv6  : $ONLINE"

# ---------------------------------------------------------------------------
# JSON scaffold
# ---------------------------------------------------------------------------
$WANT_JSON = ($PrintJson -or $JsonFile -or $JsonSend)
$JSON_RESULT = ''
if ($WANT_JSON) {
    $ipv4Json = if ($IPV4_CHECK) { 'true' } else { 'false' }
    $ipv6Json = if ($IPV6_CHECK) { 'true' } else { 'false' }
    $virtJson = if ($virtEnabled) { 'true' } else { 'false' }
    $JSON_RESULT = '{"version":"' + $YABS_VERSION + '","time":"' + $TIME_START + '","os":{"arch":"' + $ARCH +
        '","distro":"' + (ConvertTo-JsonString $DISTRO) + '","kernel":"' + (ConvertTo-JsonString $KERNEL) + '",'
    $JSON_RESULT += '"uptime":' + $UPTIME_S + ',"vm":"' + $VIRT + '"},"net":{"ipv4":' + $ipv4Json + ',"ipv6":' + $ipv6Json +
        '},"cpu":{"model":"' + (ConvertTo-JsonString $CPU_PROC) + '","cores":' + $CPU_CORES + ','
    $JSON_RESULT += '"freq":"' + $CPU_FREQ + '","aes":' + $CPU_AES_BOOL + ',"virt":' + $virtJson +
        '},"mem":{"ram":' + $TOTAL_RAM_RAW + ',"ram_units":"KiB","swap":' + $TOTAL_SWAP_RAW +
        ',"swap_units":"KiB","disk":' + $TOTAL_DISK_RAW + ',"disk_units":"KB"}'
}

# ---------------------------------------------------------------------------
# network information lookup (ip-api.com)
# ---------------------------------------------------------------------------
function Get-IpInfo {
    $resp = Invoke-HttpGet 'http://ip6.me/api/' 8
    if (-not $resp) { return }
    $parts = $resp.Split(',')
    if ($parts.Count -lt 2) { return }
    $netType = $parts[0].Trim()
    $netIp = $parts[1].Trim()

    $json = Invoke-HttpGet ("http://ip-api.com/json/{0}" -f $netIp) 8
    if (-not $json) { return }
    try { $info = $json | ConvertFrom-Json } catch { return }

    Out-Line
    Out-Line "$netType Network Information:"
    Out-Line '---------------------------------'
    if ($info.isp) { Out-Line "ISP        : $($info.isp)" } else { Out-Line 'ISP        : Unknown' }
    if ($info.as) { Out-Line "ASN        : $($info.as)" } else { Out-Line 'ASN        : Unknown' }
    if ($info.org) { Out-Line "Host       : $($info.org)" }
    if ($info.city -and $info.regionName) { Out-Line "Location   : $($info.city), $($info.regionName) ($($info.region))" }
    if ($info.country) { Out-Line "Country    : $($info.country)" }

    if ($WANT_JSON) {
        $script:JSON_RESULT += ',"ip_info":{"protocol":"' + $netType + '","isp":"' + (ConvertTo-JsonString $info.isp) +
            '","asn":"' + (ConvertTo-JsonString $info.as) + '","org":"' + (ConvertTo-JsonString $info.org) +
            '","city":"' + (ConvertTo-JsonString $info.city) + '","region":"' + (ConvertTo-JsonString $info.regionName) +
            '","region_code":"' + (ConvertTo-JsonString $info.region) + '","country":"' + (ConvertTo-JsonString $info.country) + '"}'
    }
}

if (-not $SkipNet) { Get-IpInfo }

# ---------------------------------------------------------------------------
# working directory
# ---------------------------------------------------------------------------
$DATE = (Get-Date).ToString('yyyy-MM-ddTHH_mm_sszzz') -replace ':', '_'
$YABS_PATH = Join-Path (Get-Location).Path $DATE

try {
    $probe = Join-Path (Get-Location).Path ("$DATE.test")
    New-Item -ItemType File -Path $probe -Force -ErrorAction Stop | Out-Null
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
} catch {
    Out-Line
    Out-Line 'You do not have write permission in this directory. Switch to an owned directory and re-run the script.'
    Out-Line 'Exiting...'
    Wait-ForKey
    return
}
New-Item -ItemType Directory -Path $YABS_PATH -Force | Out-Null

# ---------------------------------------------------------------------------
# built-in direct I/O disk benchmark (fio replacement)
# ---------------------------------------------------------------------------
$DiskHelperSource = @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public static class YabsDisk
{
    const uint GENERIC_READ = 0x80000000;
    const uint GENERIC_WRITE = 0x40000000;
    const uint FILE_SHARE_READ = 0x00000001;
    const uint FILE_SHARE_WRITE = 0x00000002;
    const uint CREATE_ALWAYS = 2;
    const uint OPEN_EXISTING = 3;
    const uint FILE_FLAG_NO_BUFFERING = 0x20000000;
    const uint FILE_FLAG_WRITE_THROUGH = 0x80000000;
    const int ALIGN = 4096;

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr sec,
        uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool ReadFile(SafeFileHandle handle, IntPtr buffer, uint toRead, out uint read, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool WriteFile(SafeFileHandle handle, IntPtr buffer, uint toWrite, out uint written, IntPtr overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool SetFilePointerEx(SafeFileHandle handle, long distance, IntPtr newPointer, uint method);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool FlushFileBuffers(SafeFileHandle handle);

    public class Result
    {
        public long ReadOps;
        public long WriteOps;
        public long ReadBytes;
        public long WriteBytes;
        public double Seconds;
        public string Error;
    }

    static IntPtr AllocAligned(int size, out IntPtr raw)
    {
        raw = Marshal.AllocHGlobal(size + ALIGN);
        long addr = raw.ToInt64();
        long aligned = (addr + (ALIGN - 1)) & ~((long)(ALIGN - 1));
        return new IntPtr(aligned);
    }

    // Lays out the test file with real (non-sparse) data using unbuffered writes.
    public static string CreateTestFile(string path, long size, bool noBuffering)
    {
        const int chunk = 8 * 1024 * 1024;
        uint flags = FILE_FLAG_WRITE_THROUGH;
        if (noBuffering) flags |= FILE_FLAG_NO_BUFFERING;

        SafeFileHandle h = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, IntPtr.Zero,
            CREATE_ALWAYS, flags, IntPtr.Zero);
        if (h.IsInvalid) return "CreateFile failed (" + Marshal.GetLastWin32Error() + ")";

        IntPtr raw = IntPtr.Zero;
        try
        {
            IntPtr buf = AllocAligned(chunk, out raw);
            byte[] seed = new byte[chunk];
            new Random(20191001).NextBytes(seed);
            Marshal.Copy(seed, 0, buf, chunk);

            long written = 0;
            while (written < size)
            {
                long remaining = size - written;
                int n = (int)Math.Min((long)chunk, remaining);
                if (noBuffering && (n % ALIGN) != 0) n = (n / ALIGN) * ALIGN;
                if (n <= 0) break;
                uint done;
                if (!WriteFile(h, buf, (uint)n, out done, IntPtr.Zero))
                    return "WriteFile failed (" + Marshal.GetLastWin32Error() + ")";
                written += done;
                if (done == 0) break;
            }
            FlushFileBuffers(h);
        }
        finally
        {
            if (raw != IntPtr.Zero) Marshal.FreeHGlobal(raw);
            h.Close();
        }
        return null;
    }

    // Random mixed read/write test. Each worker thread owns its own handle and its
    // own sector-aligned buffer; the thread count emulates fio's queue depth.
    public static Result RunMixed(string path, int blockSize, long fileSize, int seconds,
        int threads, int readPercent, bool noBuffering)
    {
        Result res = new Result();
        long blocks = fileSize / blockSize;
        if (blocks < 1) blocks = 1;
        if (blocks > int.MaxValue) blocks = int.MaxValue;
        int blockCount = (int)blocks;

        long[] readOps = new long[threads];
        long[] writeOps = new long[threads];
        string[] errors = new string[threads];
        Thread[] workers = new Thread[threads];

        System.Diagnostics.Stopwatch sw = System.Diagnostics.Stopwatch.StartNew();
        long limitMs = (long)seconds * 1000L;

        for (int i = 0; i < threads; i++)
        {
            int idx = i;
            workers[i] = new Thread(new ThreadStart(delegate()
            {
                SafeFileHandle h = null;
                IntPtr raw = IntPtr.Zero;
                long lr = 0, lw = 0;
                try
                {
                    uint flags = FILE_FLAG_WRITE_THROUGH;
                    if (noBuffering) flags |= FILE_FLAG_NO_BUFFERING;
                    h = CreateFileW(path, GENERIC_READ | GENERIC_WRITE,
                        FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, flags, IntPtr.Zero);
                    if (h.IsInvalid)
                    {
                        errors[idx] = "CreateFile failed (" + Marshal.GetLastWin32Error() + ")";
                        return;
                    }
                    IntPtr buf = AllocAligned(blockSize, out raw);
                    Random rnd = new Random(unchecked(Environment.TickCount * 397 + idx));

                    while (sw.ElapsedMilliseconds < limitMs)
                    {
                        for (int k = 0; k < 16; k++)
                        {
                            long off = (long)rnd.Next(0, blockCount) * blockSize;
                            if (!SetFilePointerEx(h, off, IntPtr.Zero, 0))
                            {
                                errors[idx] = "Seek failed (" + Marshal.GetLastWin32Error() + ")";
                                return;
                            }
                            uint done;
                            if (rnd.Next(0, 100) < readPercent)
                            {
                                if (!ReadFile(h, buf, (uint)blockSize, out done, IntPtr.Zero))
                                {
                                    errors[idx] = "ReadFile failed (" + Marshal.GetLastWin32Error() + ")";
                                    return;
                                }
                                lr++;
                            }
                            else
                            {
                                if (!WriteFile(h, buf, (uint)blockSize, out done, IntPtr.Zero))
                                {
                                    errors[idx] = "WriteFile failed (" + Marshal.GetLastWin32Error() + ")";
                                    return;
                                }
                                lw++;
                            }
                        }
                    }
                }
                catch (Exception ex)
                {
                    errors[idx] = ex.Message;
                }
                finally
                {
                    readOps[idx] = lr;
                    writeOps[idx] = lw;
                    if (raw != IntPtr.Zero) Marshal.FreeHGlobal(raw);
                    if (h != null) h.Close();
                }
            }));
            workers[i].IsBackground = true;
        }

        for (int i = 0; i < threads; i++) workers[i].Start();
        for (int i = 0; i < threads; i++) workers[i].Join();
        sw.Stop();

        for (int i = 0; i < threads; i++)
        {
            res.ReadOps += readOps[i];
            res.WriteOps += writeOps[i];
            if (errors[i] != null && res.Error == null) res.Error = errors[i];
        }
        res.ReadBytes = res.ReadOps * blockSize;
        res.WriteBytes = res.WriteOps * blockSize;
        res.Seconds = sw.Elapsed.TotalSeconds;
        if (res.Seconds <= 0) res.Seconds = 1;
        return res;
    }
}
'@

function Initialize-DiskHelper {
    if (-not ([System.Management.Automation.PSTypeName]'YabsDisk').Type) {
        Add-Type -TypeDefinition $DiskHelperSource -Language CSharp
    }
}

# ---------------------------------------------------------------------------
# disk benchmark
# ---------------------------------------------------------------------------
$DISK_RESULTS = @()      # formatted: total, read, write, iops_total, iops_r, iops_w (per block size)
$DISK_RESULTS_RAW = @()  # raw KiB/s + IOPS
$DISK_BS_DONE = @()      # block sizes that actually produced a result
$BLOCK_SIZES = @('4k', '64k', '512k', '1m')
$CURRENT_PARTITION = ''
if ((Get-Location).Drive) { $CURRENT_PARTITION = (Get-Location).Drive.Name + ':' }
if (-not $CURRENT_PARTITION -or $CURRENT_PARTITION.Length -ne 2) {
    $CURRENT_PARTITION = [System.IO.Path]::GetPathRoot((Get-Location).Path).TrimEnd('\')
}

function ConvertFrom-BlockSize {
    param([string]$Bs)
    switch -Regex ($Bs) {
        '^(\d+)k$' { return [int]$Matches[1] * 1024 }
        '^(\d+)m$' { return [int]$Matches[1] * 1024 * 1024 }
        default { return [int]$Bs }
    }
}

function Invoke-FioTest {
    param([string]$DiskPath)

    # fio on Windows treats ':' as a file separator, so run it inside the test
    # directory and hand it a bare relative filename.
    Write-Status 'Generating fio test file...'
    Invoke-Native -FilePath $FIO_CMD -TimeoutSec 600 -WorkingDirectory $DiskPath -Arguments @(
        '--name=setup', '--ioengine=windowsaio', '--rw=read', '--bs=64k', '--iodepth=64',
        '--numjobs=2', "--size=$DiskSize", '--runtime=1', '--gtod_reduce=1',
        '--filename=test.fio', '--direct=1', '--minimal'
    ) | Out-Null
    Clear-Status

    $ok = $false
    foreach ($bs in $BLOCK_SIZES) {
        Write-Status "Running fio random mixed R+W disk test with $bs block size..."
        $out = Invoke-Native -FilePath $FIO_CMD -TimeoutSec ($DiskRuntime + 15) -WorkingDirectory $DiskPath -Arguments @(
            "--name=rand_rw_$bs", '--ioengine=windowsaio', '--rw=randrw', '--rwmixread=50',
            "--bs=$bs", '--iodepth=64', '--numjobs=2', "--size=$DiskSize", "--runtime=$DiskRuntime",
            '--gtod_reduce=1', '--direct=1', '--filename=test.fio', '--group_reporting', '--minimal'
        )
        Clear-Status

        $line = ($out -split "`n" | Where-Object { $_ -match "rand_rw_$bs" } | Select-Object -First 1)
        if (-not $line) { continue }
        $f = $line.Split(';')
        if ($f.Count -lt 50) { continue }

        # terse v3: $7/$8 = read bw (KiB/s) + read IOPS, $48/$49 = write bw + write IOPS (1-based)
        $rBw = [double]$f[6]; $rIops = [double]$f[7]
        $wBw = [double]$f[47]; $wIops = [double]$f[48]

        $script:DISK_RESULTS_RAW += @(($rBw + $wBw), $rBw, $wBw, ($rIops + $wIops), $rIops, $wIops)
        $script:DISK_RESULTS += @(
            (Format-Speed ($rBw + $wBw)), (Format-Speed $rBw), (Format-Speed $wBw),
            (Format-Iops ($rIops + $wIops)), (Format-Iops $rIops), (Format-Iops $wIops)
        )
        $script:DISK_BS_DONE += $bs
        $ok = $true
    }
    return $ok
}

function Invoke-BuiltinDiskTest {
    param([string]$DiskPath)

    Initialize-DiskHelper
    $testFile = Join-Path $DiskPath 'test.dat'
    $noBuffering = $true

    Write-Status ('Generating test file ({0})...' -f $DiskSize)
    $err = [YabsDisk]::CreateTestFile($testFile, $DiskSizeBytes, $noBuffering)
    if ($err) {
        # some volumes (network shares, exotic filesystems) reject FILE_FLAG_NO_BUFFERING
        $noBuffering = $false
        $err = [YabsDisk]::CreateTestFile($testFile, $DiskSizeBytes, $noBuffering)
    }
    Clear-Status
    if ($err) {
        Out-Line "Failed to create the disk test file: $err"
        return $false
    }
    if (-not $noBuffering) {
        Out-Line 'Note: direct I/O unavailable on this volume, results include OS cache effects.'
    }

    $ok = $false
    foreach ($bs in $BLOCK_SIZES) {
        $bsBytes = ConvertFrom-BlockSize $bs
        Write-Status "Running built-in random mixed R+W disk test with $bs block size..."
        $r = [YabsDisk]::RunMixed($testFile, $bsBytes, $DiskSizeBytes, $DiskRuntime, $DiskThreads, 50, $noBuffering)
        Clear-Status
        if ($r.Error -and ($r.ReadOps + $r.WriteOps) -eq 0) {
            Out-Line "Disk test failed at $bs block size: $($r.Error)"
            continue
        }

        $rBw = $r.ReadBytes / $r.Seconds / 1024      # KiB/s
        $wBw = $r.WriteBytes / $r.Seconds / 1024
        $rIops = $r.ReadOps / $r.Seconds
        $wIops = $r.WriteOps / $r.Seconds

        $script:DISK_RESULTS_RAW += @(($rBw + $wBw), $rBw, $wBw, ($rIops + $wIops), $rIops, $wIops)
        $script:DISK_RESULTS += @(
            (Format-Speed ($rBw + $wBw)), (Format-Speed $rBw), (Format-Speed $wBw),
            (Format-Iops ($rIops + $wIops)), (Format-Iops $rIops), (Format-Iops $wIops)
        )
        $script:DISK_BS_DONE += $bs
        $ok = $true
    }

    Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
    return $ok
}

function Show-DiskResults {
    param([string]$Engine)

    if ($WANT_JSON) {
        $script:JSON_RESULT += ',"partition":"' + $CURRENT_PARTITION + '","fio":['
    }

    Out-Line "$Engine Disk Speed Tests (Mixed R/W 50/50) (Partition $CURRENT_PARTITION):"
    Out-Line '---------------------------------'

    $num = [int]($DISK_RESULTS.Count / 6)
    $c = 0
    while ($c -lt $num) {
        $hasSecond = ($c + 1) -lt $num
        if ($c -gt 0) { Out-Line }

        $bs1 = $DISK_BS_DONE[$c]
        $bs2 = if ($hasSecond) { $DISK_BS_DONE[$c + 1] } else { '' }

        Out-Row @('Block Size', $bs1, '(IOPS)', $bs2, '(IOPS)') @(10, 11, 8, 11, 8) @('l', 'l', 'r', 'l', 'r')
        Out-Row @('  ------', '---', '---- ', '----', '---- ') @(10, 11, 8, 11, 8) @('l', 'l', 'r', 'l', 'r')

        foreach ($row in @(@('Read', 1, 4), @('Write', 2, 5), @('Total', 0, 3))) {
            $label = $row[0]; $spdIdx = [int]$row[1]; $iopIdx = [int]$row[2]
            $v1 = $DISK_RESULTS[$c * 6 + $spdIdx]
            $i1 = '(' + $DISK_RESULTS[$c * 6 + $iopIdx] + ')'
            if ($hasSecond) {
                $v2 = $DISK_RESULTS[($c + 1) * 6 + $spdIdx]
                $i2 = '(' + $DISK_RESULTS[($c + 1) * 6 + $iopIdx] + ')'
            } else { $v2 = ''; $i2 = '' }
            Out-Row @($label, $v1, $i1, $v2, $i2) @(10, 11, 8, 11, 8) @('l', 'l', 'r', 'l', 'r')
        }

        if ($WANT_JSON) {
            # note: the comma operator binds tighter than '+', so the parentheses matter
            foreach ($k in @($c, ($c + 1))) {
                if ($k -ge $num) { continue }
                $b = $k * 6
                $script:JSON_RESULT += '{"bs":"' + $DISK_BS_DONE[$k] + '","speed_r":' + ('{0:F2}' -f $DISK_RESULTS_RAW[$b + 1]) +
                    ',"iops_r":' + ('{0:F0}' -f $DISK_RESULTS_RAW[$b + 4]) +
                    ',"speed_w":' + ('{0:F2}' -f $DISK_RESULTS_RAW[$b + 2]) +
                    ',"iops_w":' + ('{0:F0}' -f $DISK_RESULTS_RAW[$b + 5]) +
                    ',"speed_rw":' + ('{0:F2}' -f $DISK_RESULTS_RAW[$b]) +
                    ',"iops_rw":' + ('{0:F0}' -f $DISK_RESULTS_RAW[$b + 3]) + ',"speed_units":"KBps"},'
            }
        }
        $c += 2
    }

    if ($WANT_JSON) {
        $script:JSON_RESULT = $script:JSON_RESULT.TrimEnd(',') + ']'
    }
}

if (-not $SkipDisk) {
    $freeBytes = 0
    try {
        $drive = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $CURRENT_PARTITION)
        $freeBytes = [long]$drive.FreeSpace
    } catch { $freeBytes = 0 }

    if ($freeBytes -gt 0 -and $freeBytes -lt ($DiskSizeBytes + 128MB)) {
        Out-Line
        Out-Line ('Less than {0} of space available on {1}. Skipping disk test...' -f $DiskSize, $CURRENT_PARTITION)
    } else {
        Out-Line
        Write-Status 'Preparing system for disk tests...'
        $DISK_PATH = Join-Path $YABS_PATH 'disk'
        New-Item -ItemType Directory -Path $DISK_PATH -Force | Out-Null
        Clear-Status

        if (-not $FIO_CMD -and -not $BuiltinDisk) { $FIO_CMD = Install-BinTool 'fio' }

        if ($FIO_CMD) {
            $engine = 'fio'
            $success = Invoke-FioTest -DiskPath $DISK_PATH
            if (-not $success) {
                Out-Line 'fio disk speed tests failed. Falling back to the built-in direct I/O test...'
                $DISK_RESULTS = @(); $DISK_RESULTS_RAW = @(); $DISK_BS_DONE = @()
                $engine = 'Built-in'
                $success = Invoke-BuiltinDiskTest -DiskPath $DISK_PATH
            }
        } else {
            Out-Line 'fio.exe unavailable - using the built-in direct I/O disk test.'
            Out-Line
            $engine = 'Built-in'
            $success = Invoke-BuiltinDiskTest -DiskPath $DISK_PATH
        }

        if ($success -and $DISK_RESULTS.Count -gt 0) {
            Show-DiskResults -Engine $engine
        } else {
            Out-Line 'Disk speed tests failed. Run manually to determine cause.'
        }
        Remove-Item -LiteralPath $DISK_PATH -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# iperf3 network test
# ---------------------------------------------------------------------------
# format: host, port range, provider, location, supported network modes
$IPERF_LOCS = @(
    @('lon.speedtest.clouvider.net', '5200-5209', 'Clouvider', 'London, UK (10G)', 'IPv4|IPv6'),
    @('iperf-ams-nl.eranium.net', '5201-5210', 'Eranium', 'Amsterdam, NL (100G)', 'IPv4|IPv6'),
    @('speedtest.uztelecom.uz', '5200-5209', 'Uztelecom', 'Tashkent, UZ (10G)', 'IPv4|IPv6'),
    @('speedtest.sin1.sg.leaseweb.net', '5201-5210', 'Leaseweb', 'Singapore, SG (10G)', 'IPv4|IPv6'),
    @('la.speedtest.clouvider.net', '5200-5209', 'Clouvider', 'Los Angeles, CA, US (10G)', 'IPv4|IPv6'),
    @('speedtest.nyc1.us.leaseweb.net', '5201-5210', 'Leaseweb', 'NYC, NY, US (10G)', 'IPv4|IPv6'),
    @('speedtest.sao1.edgoo.net', '9204-9240', 'Edgoo', 'Sao Paulo, BR (1G)', 'IPv4|IPv6')
)

if ($ReduceNet) {
    $IPERF_LOCS = @(
        @('lon.speedtest.clouvider.net', '5200-5209', 'Clouvider', 'London, UK (10G)', 'IPv4|IPv6'),
        @('speedtest.sin1.sg.leaseweb.net', '5201-5210', 'Leaseweb', 'Singapore, SG (10G)', 'IPv4|IPv6'),
        @('speedtest.nyc1.us.leaseweb.net', '5201-5210', 'Leaseweb', 'NYC, NY, US (10G)', 'IPv4|IPv6')
    )
}

if ($IperfServers) {
    $custom = @()
    foreach ($server in ($IperfServers -split ',')) {
        $parts = $server.Split(':')
        if ($parts.Count -eq 5) {
            $custom += , @($parts[0], $parts[1], $parts[2], $parts[3], $parts[4])
        } else {
            Out-Line "Invalid server format: $server (expected format: host:port_range:name:location:network_modes)"
        }
    }
    if ($custom.Count -gt 0) { $IPERF_LOCS = $custom }
}

function Get-RandomPort {
    param([string]$Range)
    if ($Range -match '^(\d+)-(\d+)$') {
        return Get-Random -Minimum ([int]$Matches[1]) -Maximum ([int]$Matches[2] + 1)
    }
    return [int]$Range
}

function Get-Latency {
    param([string]$Target, [string]$Mode)
    try {
        $family = if ($Mode -eq 'IPv6') { 'InterNetworkV6' } else { 'InterNetwork' }
        $addr = [System.Net.Dns]::GetHostAddresses($Target) |
            Where-Object { $_.AddressFamily -eq $family } | Select-Object -First 1
        if (-not $addr) { return '--' }
        $pinger = New-Object System.Net.NetworkInformation.Ping
        $reply = $pinger.Send($addr, 4000)
        if ($reply.Status -eq 'Success') { return ('{0:F1} ms' -f $reply.RoundtripTime) }
    } catch { }
    return '--'
}

# Parses the "[SUM] ... receiver" line of an iperf3 run into value + unit.
function Get-IperfSpeed {
    param([string]$Output)
    if (-not $Output) { return $null }
    $line = ($Output -split "`n" | Where-Object { $_ -match 'SUM' -and $_ -match 'receiver' } | Select-Object -First 1)
    if (-not $line) { return $null }
    $fields = ($line.Trim() -split '\s+')
    if ($fields.Count -lt 7) { return $null }
    return [PSCustomObject]@{ Value = $fields[5]; Unit = $fields[6] }
}

function Invoke-IperfTest {
    param([string]$Target, [string]$Ports, [string]$ProviderName, [string]$Flag, [string]$Mode)

    $sendResult = $null
    $recvResult = $null

    foreach ($direction in @('send', 'recv')) {
        $attempt = 1
        while ($attempt -le 3) {
            Write-Status "Performing $Mode iperf3 $direction test to $ProviderName (Attempt #$attempt of 3)..."
            $port = Get-RandomPort $Ports
            $iperfArgs = @($Flag, '-c', $Target, '-p', "$port", '-P', '8')
            if ($direction -eq 'recv') { $iperfArgs += '-R' }
            $out = Invoke-Native -FilePath $IPERF_CMD -Arguments $iperfArgs -TimeoutSec 20 -IncludeStderr
            Clear-Status

            if ($out -match 'receiver' -and $out -notmatch 'error') {
                $parsed = Get-IperfSpeed $out
                if ($parsed -and $parsed.Value -and $parsed.Value -ne '0.00') {
                    if ($direction -eq 'send') { $sendResult = $parsed } else { $recvResult = $parsed }
                    break
                }
                $attempt++
            } else {
                if ($out -match 'unable to connect') { break }
                $attempt++
                Start-Sleep -Seconds 2
            }
        }
        if ($direction -eq 'send') { Start-Sleep -Seconds 1 }
    }

    return [PSCustomObject]@{
        Send    = $sendResult
        Recv    = $recvResult
        Latency = (Get-Latency -Target $Target -Mode $Mode)
    }
}

function Start-IperfSuite {
    param([string]$Mode)

    $flag = if ($Mode -eq 'IPv6') { '-6' } else { '-4' }

    Out-Line
    Out-Line "iperf3 Network Speed Tests ($Mode):"
    Out-Line '---------------------------------'
    Out-Row @('Provider', 'Location (Link)', 'Send Speed', 'Recv Speed', 'Ping') @(15, 25, 15, 15, 15)
    Out-Row @('-----', '-----', '----', '----', '----') @(15, 25, 15, 15, 15)

    foreach ($loc in $IPERF_LOCS) {
        if ($loc[4] -notmatch [regex]::Escape($Mode)) { continue }

        $r = Invoke-IperfTest -Target $loc[0] -Ports $loc[1] -ProviderName $loc[2] -Flag $flag -Mode $Mode

        if ($r.Send) { $sendText = '{0} {1}' -f $r.Send.Value, $r.Send.Unit } else { $sendText = 'busy' }
        if ($r.Recv) { $recvText = '{0} {1}' -f $r.Recv.Value, $r.Recv.Unit } else { $recvText = 'busy' }

        Out-Row @($loc[2], $loc[3], $sendText, $recvText, $r.Latency) @(15, 25, 15, 15, 15)

        if ($WANT_JSON) {
            $script:JSON_RESULT += '{"mode":"' + $Mode + '","provider":"' + (ConvertTo-JsonString $loc[2]) +
                '","loc":"' + (ConvertTo-JsonString $loc[3]) + '","send":"' + $sendText + '","recv":"' + $recvText +
                '","latency":"' + $r.Latency + '"},'
        }
    }
}

if (-not $SkipIperf) {
    if (-not $IPERF_CMD) {
        Out-Line
        $IPERF_CMD = Install-BinTool 'iperf3'
    }
    if (-not $IPERF_CMD) {
        Out-Line 'iperf3.exe unavailable. Skipping the network speed test.'
        Out-Line 'Pass an explicit path with -IperfPath C:\path\to\iperf3.exe if you have one.'
    } else {
        if ($WANT_JSON) { $JSON_RESULT += ',"iperf":[' }
        if ($IPV4_CHECK) { Start-IperfSuite -Mode 'IPv4' }
        if ($IPV6_CHECK) { Start-IperfSuite -Mode 'IPv6' }
        if ($WANT_JSON) { $JSON_RESULT = $JSON_RESULT.TrimEnd(',') + ']' }
    }
}

# ---------------------------------------------------------------------------
# Geekbench
# ---------------------------------------------------------------------------
function Get-GeekbenchUrls {
    param([int]$Version)

    $arm = ($ARCH -eq 'aarch64' -or $ARCH -eq 'arm')
    switch ($Version) {
        4 { $base = 'Geekbench-4.4.4' }
        5 { $base = 'Geekbench-5.5.1' }
        6 { $base = 'Geekbench-6.7.1' }
    }
    $urls = @()
    if ($arm -and $Version -ge 5) {
        $urls += "https://cdn.geekbench.com/$base-WindowsARMPreview.zip"
        $urls += "https://cdn.geekbench.com/$base-WindowsARM64.zip"
    }
    $urls += "https://cdn.geekbench.com/$base-Windows.zip"
    return $urls
}

function Start-Geekbench {
    param([int]$Version)

    if ($Version -eq 4 -and ($ARCH -eq 'aarch64' -or $ARCH -eq 'arm')) {
        Out-Line
        Out-Line 'ARM architecture not supported by Geekbench 4, use Geekbench 5 or 6.'
        return
    }
    if ($Version -ge 5 -and $ARCH -eq 'x86') {
        Out-Line
        Out-Line "Geekbench $Version cannot run on 32-bit architectures. Re-run with -GB4 to use Geekbench 4."
        return
    }

    $exeName = "geekbench$Version.exe"
    $gbExe = $null

    if ($GeekbenchPath) {
        if (Test-Path -LiteralPath $GeekbenchPath) { $gbExe = (Resolve-Path -LiteralPath $GeekbenchPath).Path }
    }
    # the extracted Geekbench tree is cached in bin so the ~250 MB download happens once
    $gbDir = Join-Path $script:BinArchDir "geekbench$Version"

    if (-not $gbExe) {
        $localCandidates = @(
            (Join-Path $gbDir $exeName),
            (Join-Path $env:ProgramFiles ("Geekbench $Version\$exeName")),
            (Join-Path ${env:ProgramFiles(x86)} ("Geekbench $Version\$exeName")),
            (Join-Path $script:ScriptDir $exeName)
        )
        foreach ($c in $localCandidates) {
            if ($c -and (Test-Path -LiteralPath $c)) { $gbExe = $c; break }
        }
        if (-not $gbExe -and (Test-Path -LiteralPath $gbDir)) {
            $cachedExe = Get-ChildItem -Path $gbDir -Filter $exeName -Recurse -File -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($cachedExe) { $gbExe = $cachedExe.FullName }
        }
    }

    New-Item -ItemType Directory -Path $gbDir -Force | Out-Null

    if (-not $gbExe) {
        if ($NoDownload) {
            Out-Line
            Out-Line "Geekbench $Version is not present and -NoDownload was given. Skipping."
            return
        }
        if (-not $IPV4_CHECK) {
            Out-Line
            Out-Line 'Geekbench releases can only be downloaded over IPv4. Download the files manually and use -GeekbenchPath.'
            return
        }
        $zip = Join-Path $gbDir 'gb.zip'
        $downloaded = $false
        foreach ($url in (Get-GeekbenchUrls -Version $Version)) {
            Write-Status "Downloading Geekbench $Version (a few hundred MB, cached in $gbDir)..."
            if (Invoke-Download -Uri $url -OutFile $zip) { $downloaded = $true; break }
        }
        Clear-Status
        if (-not $downloaded) {
            Out-Line "Geekbench $Version download failed. Skipping."
            return
        }
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $gbDir)
        } catch {
            try { Expand-Archive -LiteralPath $zip -DestinationPath $gbDir -Force } catch {
                Out-Line "Failed to extract the Geekbench $Version archive. Skipping."
                return
            }
        }
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue

        $found = Get-ChildItem -Path $gbDir -Filter $exeName -Recurse -File -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if (-not $found) {
            $found = Get-ChildItem -Path $gbDir -Filter 'geekbench*.exe' -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch 'setup|uninstall' } | Select-Object -First 1
        }
        if (-not $found) {
            Out-Line "Geekbench $Version binary not found in the archive. Skipping."
            return
        }
        $gbExe = $found.FullName
    }

    Write-Status "Running GB$Version benchmark test... *cue elevator music*"

    # unlock if a license file is present next to the script / in the cwd
    foreach ($lic in @((Join-Path (Get-Location).Path 'geekbench.license'), (Join-Path $script:ScriptDir 'geekbench.license'))) {
        if (Test-Path -LiteralPath $lic) {
            $key = (Get-Content -LiteralPath $lic -Raw).Trim()
            Invoke-Native -FilePath $gbExe -Arguments @('--unlock', $key) -TimeoutSec 60 | Out-Null
            break
        }
    }

    $gbOut = Invoke-Native -FilePath $gbExe -Arguments @('--upload') -TimeoutSec 3600
    Clear-Status

    $urlLines = @($gbOut -split "`n" | Where-Object { $_ -match 'https://browser' })
    if ($urlLines.Count -eq 0) {
        if ($Version -ge 5 -and $TOTAL_RAM_RAW -le 1048576) {
            Out-Line "Geekbench $Version test failed and low memory was detected. Use -GB4 instead."
        } else {
            Out-Line "Geekbench $Version test failed. Run manually to determine cause."
        }
        return
    }

    $GEEKBENCH_URL = ($urlLines[0] -split '\s+' | Where-Object { $_ -match '^https://browser' } | Select-Object -First 1)
    $GEEKBENCH_URL_CLAIM = ($urlLines[-1] -split '\s+' | Where-Object { $_ -match '^https://browser' } | Select-Object -First 1)

    # The scores only exist on the Geekbench Browser page (exporting them locally is a Pro
    # feature), and that page is behind Cloudflare. Datacenter IPs get challenged far more
    # aggressively than residential ones, so a single attempt is not enough on a VPS: retry a
    # few times, and if it still fails say so instead of printing two blank cells.
    $single = ''
    $multi = ''
    $tag = if ($Version -eq 4) { 'span' } else { 'div' }
    $fetchNote = ''

    foreach ($waitFor in @(10, 15, 30)) {
        Start-Sleep -Seconds $waitFor
        $html = Invoke-HttpGet $GEEKBENCH_URL 30
        if (-not $html) { $fetchNote = 'result page could not be fetched'; continue }
        if ($html -match 'Just a moment|cf_chl|Attention Required') {
            $fetchNote = 'result page blocked by Cloudflare from this host'
            continue
        }
        $matchesFound = [regex]::Matches($html, "<$tag class=['`"]score['`"]>\s*(\d+)\s*</$tag>")
        if ($matchesFound.Count -ge 1) {
            $single = $matchesFound[0].Groups[1].Value
            if ($matchesFound.Count -ge 2) { $multi = $matchesFound[$matchesFound.Count - 1].Groups[1].Value }
            $fetchNote = ''
            break
        }
        $fetchNote = 'scores not present on the result page yet'
    }

    $singleText = $single
    $multiText = $multi
    if (-not $single) { $singleText = 'see full test' }
    if (-not $multi) { $multiText = 'see full test' }

    Out-Line "Geekbench $Version Benchmark Test:"
    Out-Line '---------------------------------'
    Out-Row @('Test', 'Value') @(15, 30)
    Out-Row @('', '') @(15, 30)
    Out-Row @('Single Core', $singleText) @(15, 30)
    Out-Row @('Multi Core', $multiText) @(15, 30)
    Out-Row @('Full Test', $GEEKBENCH_URL) @(15, 60)
    if ($fetchNote) {
        Out-Line "Note: $fetchNote - open the link above to see the scores."
    }

    if ($WANT_JSON) {
        $s = if ($single) { $single } else { 'null' }
        $m = if ($multi) { $multi } else { 'null' }
        $script:JSON_RESULT += '{"version":' + $Version + ',"single":' + $s + ',"multi":' + $m +
            ',"url":"' + $GEEKBENCH_URL + '"},'
    }

    if ($GEEKBENCH_URL_CLAIM) {
        Add-Content -Path (Join-Path (Get-Location).Path 'geekbench_claim.url') -Value $GEEKBENCH_URL_CLAIM -ErrorAction SilentlyContinue
    }
}

if (-not $SkipGeekbench) {
    if ($WANT_JSON) { $JSON_RESULT += ',"geekbench":[' }
    if ($runGB4) { Start-Geekbench -Version 4 }
    if ($runGB5) { Start-Geekbench -Version 5 }
    if ($runGB6) { Start-Geekbench -Version 6 }
    if ($WANT_JSON) { $JSON_RESULT = $JSON_RESULT.TrimEnd(',') + ']' }
}

# ---------------------------------------------------------------------------
# clean up + summary
# ---------------------------------------------------------------------------
Out-Line
Remove-Item -LiteralPath $YABS_PATH -Recurse -Force -ErrorAction SilentlyContinue

$YABS_END_TIME = [long]([System.DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
$timeTaken = $YABS_END_TIME - $YABS_START_TIME
if ($timeTaken -gt 60) {
    Out-Line ('WYBS completed in {0} min {1} sec' -f [int]($timeTaken / 60), ($timeTaken % 60))
} else {
    Out-Line ('WYBS completed in {0} sec' -f $timeTaken)
}

if ($WANT_JSON) {
    $JSON_RESULT += ',"runtime":{"start":' + $YABS_START_TIME + ',"end":' + $YABS_END_TIME + ',"elapsed":' + $timeTaken + '}'
    $JSON_RESULT += '}'

    if ($JsonFile) {
        [System.IO.File]::WriteAllText($JsonFile, $JSON_RESULT, (New-Object System.Text.UTF8Encoding($false)))
    }

    if ($JsonSend) {
        foreach ($site in ($JsonSend -split ',')) {
            try {
                Invoke-RestMethod -Uri $site.Trim() -Method Post -ContentType 'application/json' -Body $JSON_RESULT -TimeoutSec 30 | Out-Null
            } catch {
                Out-Line "Failed to send JSON results to $site"
            }
        }
    }

    if ($PrintJson) {
        Out-Line
        Write-Output $JSON_RESULT
        $script:LogLines.Add($JSON_RESULT)
    }
}

Save-Output
Wait-ForKey
