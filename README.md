# Windows-Yet-Bench-Script

A native PowerShell port of Mason Rowe's [yabs.sh](https://github.com/masonr/yet-another-bench-script).
Benchmarks disk, network and CPU performance on Windows — no WSL, no Cygwin, no administrator rights.

| File | Role |
|---|---|
| `wybs.ps1` | the script itself |
| `wybs.cmd` | launcher for cmd.exe / double-click (bypasses the execution policy) |
| `bin\win\<arch>\` | cache for automatically downloaded tools |

## How to Run

Paste this into PowerShell — nothing to clone, download or install first:

```powershell
irm https://raw.githubusercontent.com/TeYroXOfficial/windows-yet-bench-script/main/wybs.ps1 | iex
```

With flags — `iex` cannot take arguments, so the script is run as a scriptblock:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/TeYroXOfficial/windows-yet-bench-script/main/wybs.ps1))) -ReduceNet
```

From cmd.exe:

```bat
powershell -NoProfile -Command "irm https://raw.githubusercontent.com/TeYroXOfficial/windows-yet-bench-script/main/wybs.ps1 | iex"
```

This works under the default `Restricted` execution policy, because the policy applies to script
files on disk, not to code held in memory. On an older system where TLS 1.2 is not negotiated by
default, prepend `[Net.ServicePointManager]::SecurityProtocol = 'Tls12';` to the command.

Started this way the script has no file of its own, so it caches the tools it downloads in the
**current directory** (`.\bin\win\<arch>`) — Geekbench alone is about 250 MB. Add `-SkipGeekbench`,
or point `-BinDir` at a permanent location, if that is not what you want.

## Running a local copy

Simplest, with no changes to your system:

```bat
wybs.cmd
```

From PowerShell, if you would rather not touch the execution policy:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\wybs.ps1
```

Full list of options:

```powershell
.\wybs.cmd -Help
```

### Running `.ps1` directly

The default execution policy on Windows 11 is `Restricted`, so `.\wybs.ps1` will be blocked.
One-time fix, user scope, **no administrator rights required**:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

If you downloaded `wybs.ps1` from the internet, clear the zone marker as well: `Unblock-File .\wybs.ps1`.

### Making `wybs` a command available anywhere

```powershell
[Environment]::SetEnvironmentVariable('Path',
    [Environment]::GetEnvironmentVariable('Path','User') + ';C:\path\to\WYBS', 'User')
```

After restarting the terminal, `wybs -ReduceNet` works in cmd.exe.
**Caveat:** in PowerShell the bare name `wybs` resolves to `wybs.ps1` rather than `wybs.cmd`, so there
you still need `RemoteSigned`. Alternative: keep `wybs.cmd` in a directory on PATH and `wybs.ps1` outside it.

### Running from memory

The execution policy applies to files, not to in-memory code, so this works even under `Restricted`:

```powershell
Get-Content .\wybs.ps1 -Raw | iex
```

With arguments (`iex` does not accept them, so a scriptblock is needed):

```powershell
& ([scriptblock]::Create((Get-Content .\wybs.ps1 -Raw))) -ReduceNet -SkipGeekbench
```


Run from memory, the script does not know its own path, so it puts the `bin\win\<arch>` cache in the
current directory. To reuse already-downloaded tools, run it from the project directory or pass
`-BinDir C:\path\to\WYBS\bin\win`.

## Requirements

- Windows 10 1803+ / Windows 11 / Windows Server 2019+
- Windows PowerShell 5.1 (ships with the OS) or PowerShell 7+
- `curl.exe` — part of Windows since 1803, used to read Geekbench results
- ~2 GB free space for the disk test, ~530 MB for the tool cache
- **no administrator rights**

## Options

### Skipping tests

| Flag | Alias | Effect |
|---|---|---|
| `-SkipDisk` | `-f`, `-d` | skips the disk test |
| `-SkipIperf` | `-i` | skips the network test |
| `-SkipGeekbench` | `-g` | skips the CPU test |
| `-SkipNet` | `-n` | skips the ISP/location lookup |

### Network test

| Flag | Alias | Effect |
|---|---|---|
| `-ReduceNet` | `-r` | 3 locations instead of 7 (less bandwidth) |
| `-IperfServers <s>` | `-p` | custom servers: `host:ports:name:location:modes`, comma-separated |

```powershell
.\wybs.ps1 -IperfServers "example.com:5201-5210:MyServer:New York (10G):IPv4|IPv6"
```

### Geekbench

| Flag | Effect |
|---|---|
| `-GB6` | Geekbench 6 (default) |
| `-GB5` | Geekbench 5 instead of 6 |
| `-GB4` | Geekbench 4 instead of 6 |
| `-GB9` | Geekbench 4 **and** 5 instead of 6 |

### Disk test

| Flag | Default | Effect |
|---|---|---|
| `-DiskSize <size>` | `2G` (`512M` on ARM) | size of the test file |
| `-DiskRuntime <s>` | `30` | seconds per block size |
| `-BuiltinDisk` | — | force the built-in test even when fio is available |
| `-DiskThreads <n>` | `32` | worker threads for the built-in test (emulates `iodepth`) |

### Tools and downloads

| Flag | Effect |
|---|---|
| `-BinDir <dir>` | where downloaded tools are cached (default `<script dir>\bin\win`) |
| `-NoDownload` | never download anything, use only what is already present |
| `-FioPath`, `-IperfPath`, `-GeekbenchPath` | explicit paths to the binaries |

### Output

| Flag | Alias | Effect |
|---|---|---|
| `-PrintJson` | `-j` | print JSON at the end |
| `-JsonFile <file>` | `-w` | write JSON to a file |
| `-JsonSend <url>` | `-s` | POST the JSON (several comma-separated URLs allowed) |
| `-LogFile <file>` | — | where to save the full output (default `.\wybs-<timestamp>.txt`) |
| `-NoLog` | — | no results file, do not touch the clipboard |
| `-NoPause` | — | close the window immediately instead of waiting for a keypress |
| `-Ascii` | — | `[+]`/`[-]` instead of `✔`/`❌` for legacy consoles |
| `-Help` | `-h` | print help and exit |

## What it measures with

| Area | Tool | Source | Parameters |
|---|---|---|---|
| Disk | fio 3.42 | [`axboe/fio`](https://github.com/axboe/fio/releases) | `--ioengine=windowsaio --direct=1 --rw=randrw --rwmixread=50 --iodepth=64 --numjobs=2`, blocks 4k/64k/512k/1m |
| Disk (fallback) | built-in C# test | compiled on the fly | `CreateFileW` with `FILE_FLAG_NO_BUFFERING\|WRITE_THROUGH`, 4 KiB-aligned buffers |
| Network | iperf3 3.21 | [`ar51an/iperf3-win-builds`](https://github.com/ar51an/iperf3-win-builds/releases) | 8 parallel streams, send and receive |
| Latency | `System.Net.NetworkInformation.Ping` | .NET | address family forced to IPv4/IPv6 |
| CPU | Geekbench 6.7.1 | `cdn.geekbench.com` | `--upload` |
| System info | CIM/WMI | — | `Win32_OperatingSystem`, `Win32_Processor`, `Win32_ComputerSystem`, `Win32_LogicalDisk`, `Win32_BIOS` |
| Network info | `ip6.me/api`, `ip-api.com` | — | ISP, ASN, location |

fio, iperf3 and Geekbench download themselves on first use into `bin\win\<arch>\` and stay there.
Every download has a **pinned SHA-256**; a mismatch aborts the install and prints both hashes.
Windows on ARM gets the x64 binaries (they run under emulation).

## What ends up on disk

| Path | What it is |
|---|---|
| `bin\win\<arch>\fio.exe` | ~6 MB |
| `bin\win\<arch>\iperf3.exe` + `cygwin1.dll` | ~3 MB |
| `bin\win\<arch>\geekbench6\` | ~516 MB — delete it if you need the space |
| `.\wybs-<timestamp>.txt` | full output of the run (also copied to the clipboard) |
| `.\geekbench_claim.url` | link for claiming the result on your Geekbench account |

The test working directory (`.\<timestamp>\`) is removed after a normal run and after a fatal error.
If you interrupt the run with Ctrl+C such a directory may be left behind — it is safe to delete manually.

## Results and copying them

When the run finishes the script writes the whole output to `wybs-<timestamp>.txt`, copies it to the
clipboard, and keeps the window open. Only **Enter, Esc or Q** close it — keys held with Ctrl are
ignored, so `Ctrl+C` copies your selection instead of killing the window. When stdin is redirected
(pipe, scheduled task, CI) the pause is skipped entirely, so the script can never hang unattended.

## JSON

The schema matches `yabs.sh`, so existing tooling will accept it:

```json
{
  "version": "...", "time": "...",
  "os":  { "arch": "x64", "distro": "...", "kernel": "...", "uptime": 0, "vm": "NONE" },
  "net": { "ipv4": true, "ipv6": false },
  "cpu": { "model": "...", "cores": 32, "freq": "...", "aes": null, "virt": true },
  "mem": { "ram": 0, "ram_units": "KiB", "swap": 0, "swap_units": "KiB", "disk": 0, "disk_units": "KB" },
  "ip_info": { "...": "..." },
  "partition": "C:",
  "fio": [ { "bs": "4k", "speed_r": 0.0, "iops_r": 0, "...": "..." } ],
  "iperf": [ { "mode": "IPv4", "provider": "...", "...": "..." } ],
  "geekbench": [ { "version": 6, "single": 0, "multi": 0, "url": "..." } ],
  "runtime": { "start": 0, "end": 0, "elapsed": 0 }
}
```

The only deviation: `cpu.aes` can be `null` (see below), whereas `yabs.sh` always emits `true`/`false`.

## Differences from `yabs.sh`

**Instead of downloading binaries from the yabs repository** (which only holds ELF files) the script
pulls the official Windows releases and verifies them by SHA-256.

**Instead of `dd` as the disk-test fallback** there is a built-in direct-I/O test written in C#. It runs
when fio is unavailable. Its numbers are **not directly comparable to fio** — synchronous threads do
not reproduce `iodepth=64` exactly.

**Geekbench results are read with `curl.exe`, not .NET.** `browser.geekbench.com` sits behind a
Cloudflare challenge that rejects .NET's HTTP stack with a 403. `curl.exe` with an ordinary
User-Agent gets through. Reading the scores locally is not an option: `--export-json`, `--save` and
`--no-upload` are **Geekbench Pro** features.

**`LC_ALL=C` replaced by pinning the thread culture to `InvariantCulture`** — without it a Polish (or
any comma-decimal) locale formats `1,23` and breaks both parsing and the JSON output.

**VM detection via SMBIOS strings** instead of `systemd-detect-virt`.

**The ZFS check is gone** — there is no Windows equivalent.

## Known limitations

**AES-NI shows `? Unknown` under Windows PowerShell 5.1.** Windows exposes no AES-NI flag to user
mode (`IsProcessorFeaturePresent` only has such a bit for ARM64), and
`System.Runtime.Intrinsics.X86.Aes` only exists in .NET Core. The script tries the intrinsics and, if
`pwsh` is installed, queries it in a subprocess — so **under PowerShell 7 the field is filled in
correctly**.

**iperf3 is only available for x64.** On 32-bit Windows the network test is skipped.

**The network test can consume several GB of traffic** — 8 streams in both directions across 7
locations. On a metered connection use `-ReduceNet` or `-SkipIperf`.

**The free Geekbench always publishes the result** to the Geekbench Browser; that cannot be disabled
without a Pro licence.

## Troubleshooting

**"running scripts is disabled on this system"** — see [Running `.ps1` directly](#running-ps1-directly).

**The window disappears before I can read the result** — it should not, but the output is in
`wybs-<timestamp>.txt` and on the clipboard anyway.

**Garbage instead of `✔` / `❌`** — legacy console without UTF-8; use `-Ascii`.

**Disk test is skipped** — not enough free space. Lower `-DiskSize`, e.g. `-DiskSize 512M`.

**No internet / air-gapped environment** — `-NoDownload` together with `-FioPath` / `-IperfPath`
pointing at your own binaries.

## Verification status

| Path | Status |
|---|---|
| System info, JSON, results file, clipboard, pause | tested live |
| Disk test via fio (download + full run) | tested live |
| Built-in disk test | tested live |
| iperf3 download and invocation | tested; transfers only over loopback |
| Geekbench score parsing | tested against a real result page |
| Full end-to-end Geekbench run |  (7 min under load + publishes the result) |
| Real iperf3 test against public servers |  (bandwidth cost) |

## Licence and credits

The original [Yet-Another-Bench-Script](https://github.com/masonr/yet-another-bench-script) is by Mason
Rowe; its licence is in the `LICENSE` file. This port keeps the original's output format and JSON schema.

The third-party tools carry their own licences: [fio](https://github.com/axboe/fio) (GPL-2.0),
[iperf3](https://github.com/esnet/iperf) (BSD-3-Clause) and [Geekbench](https://www.geekbench.com/)
(proprietary, Primate Labs).

## Partners

**[VPSReseller.net](https://vpsreseller.net)** — a white-label billing and provisioning platform for VPS
resellers, built around its Vanguard panel. It combines hourly billing, a client wallet, multi-gateway
payments and API integrations with several upstream VPS providers, so the whole order-to-invoice flow
lives in one place.

**[FastKVM.eu](https://fastkvm.eu)** — a KVM virtual server provider running NVMe-backed Ceph storage,
with locations in Amsterdam, New York, Singapore, Sydney and Ho Chi Minh City. Plans include DDoS
protection, daily backups and hot-resizing of CPU and RAM without downtime.
