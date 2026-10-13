<#
video_monitor.ps1  --  folder watcher for encode-segments.ps1
=============================================================
Keeps running, watches a folder, and encodes every video that appears in it.
After EACH video finishes it re-scans the folder immediately, so a video
dropped in while another one is encoding is picked up as soon as the current
one completes.

Encoding itself is NOT re-implemented here: this script calls
encode-segments.ps1 once per video (single-file mode), so all settings,
resume logic, cleanup and ENCODE_DONE.flag behaviour stay exactly the same
as your normal run.

Config: setting.ini beside this script (or -Ini <path>). Optional section:
    [Monitor]
    Dir             = D:\BaiduNetdiskDownload\test   ; folder to watch (default: [Source] Video or script dir)
    PollSeconds     = 15                             ; idle rescan interval (seconds)
    SettleSeconds   = 4                              ; wait for copy to finish (seconds)
    IdleExitMinutes = 5                              ; auto-exit after N min of no new video (0 = never)
If [Monitor] Dir is absent, [Source] Video is used (when it is a folder).

Usage:
    powershell -ExecutionPolicy Bypass -File video_monitor.ps1
    powershell -ExecutionPolicy Bypass -File video_monitor.ps1 -Ini "D:\my.ini"
    powershell -ExecutionPolicy Bypass -File video_monitor.ps1 -PollSeconds 5 -Once
    (or just double click compress_video.bat)

-Once  = encode everything found right now, then exit (no endless watch).
Stop the watcher any time with Ctrl+C.
Idle-exit: in watch mode, if no new video is seen for IdleExitMinutes (setting.ini),
           the monitor stops by itself so you don't have to kill it manually.
#>
param(
  [string]$Ini = "",
  [int]$PollSeconds = 0,
  [int]$SettleSeconds = 0,
  [switch]$Once
)

# 强制 UTF-8 输出编码：避免中文文件名在控制台 / 管道（被 C# 外壳或重定向捕获）下出现乱码。
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- paths
$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$mainScript = Join-Path $scriptDir 'encode-segments.ps1'
if (-not (Test-Path -LiteralPath $mainScript)) {
  Write-Host "ERROR: encode-segments.ps1 not found beside this script: $mainScript"
  exit 1
}
$iniPath = if ($Ini -and $Ini.Trim() -ne '') { $Ini } else { Join-Path $scriptDir 'setting.ini' }
# 家目录 = setting.ini 所在目录（用户真正操作的文件夹）。脚本被 exe 释放到临时目录运行时，
# 监控目录 / 视频源仍指向用户文件夹，而不是临时目录。
$homeDir = Split-Path $iniPath

# ---------------------------------------------------------------- ini reader (self-contained)
function Read-Ini($Path) {
  $ini = @{}
  $section = ''
  foreach ($line in (Get-Content -Encoding UTF8 -LiteralPath $Path)) {
    $line = $line.Trim()
    if (-not $line -or $line.StartsWith(';') -or $line.StartsWith('#')) { continue }
    if ($line -match '^\[(.+)\]$') { $section = $matches[1].Trim(); continue }
    if ($line -match '^(.+?)\s*=\s*(.*)$') {
      $k = $matches[1].Trim(); $v = $matches[2].Trim()
      if ($section) { $ini["$section.$k"] = $v }
    }
  }
  return $ini
}
function Get-IniVal($section, $key, $fallback) {
  $full = "$section.$key"
  if ($script:config -and $script:config.ContainsKey($full)) {
    $v = $script:config[$full]
    if ($null -ne $v -and $v.Trim() -ne '') { return $v.Trim() }
  }
  return $fallback
}
function To-Bool($v) {
  return ($v -eq 'true' -or $v -eq '1' -or $v -eq 'yes' -or $v -eq 'on')
}

$script:config = @{}
if (Test-Path -LiteralPath $iniPath) {
  $script:config = Read-Ini $iniPath
  Write-Host "Loaded config: $iniPath"
} else {
  Write-Host "WARNING: config not found ($iniPath) - monitor uses defaults, encode-segments.ps1 uses its own defaults."
}

# ---------------------------------------------------------------- what to watch
$watchDir = Get-IniVal 'Monitor' 'Dir' ''
if ($watchDir -eq '') {
  $src = Get-IniVal 'Source' 'Video' ''
  if ($src -ne '' -and (Test-Path -LiteralPath $src -PathType Container)) { $watchDir = $src }
}
if ($watchDir -eq '') { $watchDir = $homeDir }
if (-not (Test-Path -LiteralPath $watchDir)) {
  Write-Host "ERROR: watch folder not found: $watchDir"
  exit 1
}

$defPoll   = [int](Get-IniVal 'Monitor' 'PollSeconds'   '15')
$defSettle = [int](Get-IniVal 'Monitor' 'SettleSeconds' '4')
if ($PollSeconds   -le 0) { $PollSeconds   = $defPoll }
if ($SettleSeconds -le 0) { $SettleSeconds = $defSettle }
if ($SettleSeconds -lt 1) { $SettleSeconds = 1 }
if ($PollSeconds   -lt 1) { $PollSeconds   = 1 }

$IdleExitMinutes = [int](Get-IniVal 'Monitor' 'IdleExitMinutes' '5')
if ($IdleExitMinutes -lt 0) { $IdleExitMinutes = 0 }

$recurse   = To-Bool (Get-IniVal 'Source' 'Recurse' 'false')
$minSizeMB = [int](Get-IniVal 'Source' 'MinSizeMB' '0')
$minBytes  = [long]$minSizeMB * 1MB
$OutDir    = Get-IniVal 'Output' 'OutDir' ''

$extRaw = Get-IniVal 'Source' 'VideoExt' ''
if ($extRaw -match '\S') {
  $extSet = @($extRaw -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
} else {
  $extSet = @('.mp4', '.mkv', '.mov', '.avi', '.flv', '.webm', '.m4v', '.ts', '.wmv')
}

# ---------------------------------------------------------------- state
# full path -> @{ Len; Tick; Status }   Status: ok | failed
$script:state = @{}
# 已被判为"输出目录"而跳过的目录，仅用于去重打印一次提示
$script:skippedDirs = @{}

function Normalize-Dir([string]$dir) {
  if (-not $dir) { return '' }
  try { return ((Resolve-Path -LiteralPath $dir).Path).TrimEnd('\') }
  catch { return $dir.TrimEnd('\') }
}

function Test-OutputDir([string]$dir) {
  # never treat encode-segments' own working folders as source material
  if (-not $dir) { return $false }
  if (Test-Path -LiteralPath (Join-Path $dir 'ENCODE_DONE.flag')) { return $true }
  if (Test-Path -LiteralPath (Join-Path $dir 'concat.txt'))        { return $true }

  # 只在【子目录】应用 part_*.mp4 判据，监控根目录本身除外。
  #
  # 原因（自指误判 BUG）：监控根目录是用户投放待压素材的地方。若根目录残留一个
  # part_*.mp4（例如上次切片/编码遗留），该判据会被这个文件自身满足 —— 目录被
  # 判成"输出目录"，于是根目录里【所有】视频都被静默跳过，表现为"程序不识别
  # part_000.mp4"、甚至整个文件夹都没反应。真正的输出目录（如 aaa\、<视频名>\）
  # 都是子目录，跳过它们依然是正确的。
  $isWatchRoot = (Normalize-Dir $dir) -ieq (Normalize-Dir $watchDir)
  if (-not $isWatchRoot) {
    if (@(Get-ChildItem -LiteralPath $dir -Filter 'part_*.mp4' -File -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
  }
  return $false
}

function Get-CandidateVideos {
  $files = @(Get-ChildItem -LiteralPath $watchDir -File -Recurse:([bool]$recurse) -ErrorAction SilentlyContinue)
  $out = @()
  foreach ($f in $files) {
    if (-not ($extSet -contains $f.Extension.ToLower())) { continue }
    if ($f.Length -lt $minBytes) { continue }
    if (Test-OutputDir $f.DirectoryName) {
      # 不再静默跳过：首次遇到该目录时明确告知原因，避免"文件明明在却没反应"。
      if (-not $script:skippedDirs.ContainsKey($f.DirectoryName)) {
        $script:skippedDirs[$f.DirectoryName] = $true
        Write-Host "[skip] $($f.DirectoryName)  <-- 识别为编码输出目录，不当作待压素材。"
        Write-Host "       若这是你放视频的目录，请删掉里面的 ENCODE_DONE.flag / concat.txt，或把视频放进别的文件夹。"
      }
      continue
    }
    $out += $f
  }
  return @($out)
}

function Get-PendingVideos {
  $out = @()
  foreach ($f in (Get-CandidateVideos)) {
    $st = $script:state[$f.FullName]
    if ($st -and $st.Len -eq $f.Length -and $st.Tick -eq $f.LastWriteTimeUtc.Ticks) { continue }
    $out += $f
  }
  return @($out)
}

function Wait-FileStable {
  param([System.IO.FileInfo]$File)
  $prev = -1
  for ($i = 0; $i -lt 15; $i++) {
    $cur = Get-Item -LiteralPath $File.FullName -ErrorAction SilentlyContinue
    if (-not $cur) { return $false }
    if ($cur.Length -gt 0 -and $cur.Length -eq $prev) { return $true }
    $prev = $cur.Length
    Start-Sleep -Seconds $SettleSeconds
  }
  return $false
}

# ---------------------------------------------------------------- watcher (wake-up only)
# A synchronized hashtable is the only reliable way to hand a signal from the
# FileSystemWatcher event thread back to the main loop.
$signal  = [hashtable]::Synchronized(@{ Wake = $false })
$watcher = $null
$evtC    = $null
$evtR    = $null
try {
  $watcher = New-Object System.IO.FileSystemWatcher
  $watcher.Path = $watchDir
  $watcher.Filter = '*.*'
  $watcher.IncludeSubdirectories = [bool]$recurse
  $evtC = Register-ObjectEvent -InputObject $watcher -EventName 'Created' -MessageData $signal -Action { $Event.MessageData.Wake = $true }
  $evtR = Register-ObjectEvent -InputObject $watcher -EventName 'Renamed' -MessageData $signal -Action { $Event.MessageData.Wake = $true }
  $watcher.EnableRaisingEvents = $true
} catch {
  Write-Host "NOTE: FileSystemWatcher unavailable ($_). Polling only."
  $watcher = $null
}

function Wait-OrWake {
  param([int]$Seconds)
  $signal.Wake = $false
  for ($i = 0; $i -lt $Seconds; $i++) {
    Start-Sleep -Seconds 1
    if ($signal.Wake) { return }
  }
}

# ---------------------------------------------------------------- main loop
Write-Host ""
Write-Host "================ VIDEO MONITOR ================"
Write-Host "Watching   : $watchDir $(if($recurse){'(recursive)'})"
Write-Host "Extensions : $($extSet -join ', ')"
if ($minSizeMB -gt 0) { Write-Host "Min size   : $minSizeMB MB" }
Write-Host "Idle scan  : every $PollSeconds s (instant when a file appears); auto-exit after $IdleExitMinutes min idle (0 = never)"
Write-Host "Engine     : $mainScript"
Write-Host "Press Ctrl+C to stop."
Write-Host "==============================================="

$processed = 0
$failed    = 0
$lastActivity = [DateTime]::Now   # last time a video was detected or finished -> idle timer anchor

try {
  while ($true) {

    $pending = Get-PendingVideos

    if ($pending.Count -eq 0) {
      if ($Once) { break }
      if ($IdleExitMinutes -gt 0) {
        $idleMin = ([DateTime]::Now - $lastActivity).TotalMinutes
        if ($idleMin -ge $IdleExitMinutes) {
          Write-Host "[$(Get-Date -Format 'HH:mm:ss')] no new video for $([math]::Round($idleMin,1)) min (auto-exit limit $IdleExitMinutes min) - stopping."
          break
        }
        Write-Host ("[$(Get-Date -Format 'HH:mm:ss')] idle - nothing new ({0} min since last activity; auto-exit at {1} min). next scan in {2}s" -f [math]::Round($idleMin,1), $IdleExitMinutes, $PollSeconds)
      } else {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] idle - nothing new. next scan in ${PollSeconds}s"
      }
      Wait-OrWake -Seconds $PollSeconds
      continue
    }

    # handle ONE video, then loop back -> folder gets re-scanned after each one
    $lastActivity = [DateTime]::Now   # a video is here -> keep idle timer fresh
    $f    = $pending[0]
    $base = $f.BaseName
    $od   = if ($OutDir) { Join-Path $OutDir $base } else { Join-Path $f.DirectoryName $base }

    Write-Host ""
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] NEW: $($f.Name)  ($([math]::Round($f.Length / 1MB, 1)) MB) -> $od"

    if (-not (Wait-FileStable -File $f)) {
      Write-Host "  skip for now: file still growing (copy in progress?)"
      Start-Sleep -Seconds $SettleSeconds
      continue
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & powershell -NoProfile -ExecutionPolicy Bypass -File $mainScript -Video $f.FullName -OutDir $od -Ini $iniPath
    $rc = $LASTEXITCODE
    $sw.Stop()

    $cur  = Get-Item -LiteralPath $f.FullName -ErrorAction SilentlyContinue
    $len  = if ($cur) { $cur.Length }                else { $f.Length }
    $tick = if ($cur) { $cur.LastWriteTimeUtc.Ticks } else { $f.LastWriteTimeUtc.Ticks }
    $script:state[$f.FullName] = @{ Len = $len; Tick = $tick; Status = $(if ($rc -eq 0) { 'ok' } else { 'failed' }) }
    $lastActivity = [DateTime]::Now   # work just finished -> keep idle timer fresh

    if ($rc -eq 0) {
      $processed++
      Write-Host "[$(Get-Date -Format 'HH:mm:ss')] FINISHED: $($f.Name)  in $([math]::Round($sw.Elapsed.TotalMinutes, 1)) min"
    } else {
      $failed++
      Write-Host "[$(Get-Date -Format 'HH:mm:ss')] FAILED  : $($f.Name)  (exit $rc). Not retried until the file changes."
    }
  }
} finally {
  if ($evtC) { Unregister-Event -SourceIdentifier $evtC.Name -ErrorAction SilentlyContinue; Remove-Job $evtC -Force -ErrorAction SilentlyContinue }
  if ($evtR) { Unregister-Event -SourceIdentifier $evtR.Name -ErrorAction SilentlyContinue; Remove-Job $evtR -Force -ErrorAction SilentlyContinue }
  if ($watcher) { $watcher.EnableRaisingEvents = $false; $watcher.Dispose() }
  Write-Host ""
  Write-Host "Monitor stopped. encoded=$processed failed=$failed"
}

exit 0
