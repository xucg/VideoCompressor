<#
encode-segments.ps1
Auto-split a long video into time-based segments, encode each with the same
H.265/H.264 settings, RESUME safely after shutdown/crash (re-run skips finished
parts via ffprobe check), then concatenate into one final file.

Source can be EITHER a single file OR a folder (folder = batch mode, every
video processed into its own sub-folder). Configuration can come from:
  1. command-line arguments (highest priority)
  2. setting.ini next to this script (or -Ini <path>)  -- see setting.ini
  3. built-in defaults

Usage:
  # everything from setting.ini (recommended once configured)
  powershell -ExecutionPolicy Bypass -File encode-segments.ps1

  # single file, override a few things
  powershell -ExecutionPolicy Bypass -File encode-segments.ps1 -Video "D:\big.mp4" -SegLen 300

  # batch: process every video under a folder
  powershell -ExecutionPolicy Bypass -File encode-segments.ps1 -Dir "D:\BaiduNetdiskDownload\test"
  # batch only "big" videos (>= 500 MB), recurse into subfolders
  powershell -ExecutionPolicy Bypass -File encode-segments.ps1 -Dir "D:\Videos" -MinSizeMB 500 -Recurse

  # point at a specific config file
  powershell -ExecutionPolicy Bypass -File encode-segments.ps1 -Ini "D:\my-settings.ini"

Options (all optional; fall back to setting.ini / built-in defaults):
  -Video      single source video OR a folder (folder => batch). Mutually
              exclusive with -Dir. In setting.ini this is [Source] Video.
  -Dir        folder of videos to process (mutually exclusive with -Video).
  -Ini        path to a setting.ini file (default: setting.ini beside script).
  -Recurse    (batch) also scan subfolders.
  -MinSizeMB  (batch) only process videos larger than this many MB (0 = all).
  -SegLen     seconds per segment (default 600 = 10 min; 300 for finer resume).
  -OutDir     SINGLE: output folder (default "encoded_parts").
              BATCH : root folder; each video -> <OutDir>/<video-name>/
  -Crf        quality value (default 28; x265's CRF scale is ~5-6 higher than
              x264, so 28 ~= x264 24). Configurable in setting [Encode] Crf.
  -Preset     speed tier: ultrafast/veryfast/fast/medium/slow/slower (default fast).
              Configurable in setting [Encode] Preset.
  -Ffmpeg     path/name of ffmpeg (default "ffmpeg" = must be in PATH).
  -ConcatOnly skip encoding, only run concat on existing parts.
  -BurnSub    find a same-name .ass/.srt next to the video, copy it into OutDir
              and BURN it into the picture (subtitles filter). Because the
              subtitle becomes part of the image, splitting + concat keeps it
              perfectly aligned per segment - no more dropped subtitle problem.
  -ProbeOnly  ONLY probe: print duration, resolution, fps, segment count and an
              estimated total encode time on a Ryzen 5600U. No encoding, no concat.
  -FirstN     TEST MODE: encode only the first N segments of EACH video, then
              stop WITHOUT concatenating. Verify the pipeline on a short clip
              before committing to a long encode.
  -CleanUp    (default ON) After the final.mp4 is verified (covers >=98% of the
              source duration), automatically DELETE the intermediate
              part_*.mp4 segments and concat.txt to free disk space. A
              ENCODE_DONE.flag is written so re-runs skip the video instead of
              re-encoding. Set -CleanUp:$false (or CleanUp=false in setting.ini)
              to keep the parts (e.g. for a manual re-merge).
  -ShowFfmpeg (default OFF) By default ffmpeg's verbose diagnostic output is
              redirected to a per-segment log file and only a single compact
              status line (file + time range + live progress %) is shown at the
              bottom of the window. Pass -ShowFfmpeg to print ffmpeg's raw output
              instead (useful for debugging).

Notes:
  - Video + first audio track are encoded.
  - Each segment is re-encoded from the source with -ss before -i (fast seek to
    keyframe), so every part starts on a keyframe and -c copy concat is safe.
  - Requires ffprobe (ships with the same ffmpeg build) for the resume check.
  - Speed estimate in -ProbeOnly is a rough model (~+/-30%).
#>
param(
  [string]$Video,
  [string]$Dir,
  [string]$Ini = "",
  [switch]$Recurse,
  [int]$MinSizeMB = 0,
  [int]$SegLen = 600,
  [string]$OutDir = "",
  [int]$Crf = 28,
  [string]$Preset = "fast",
  [string]$Ffmpeg = "ffmpeg",
  [switch]$ConcatOnly,
  [switch]$BurnSub,
  [switch]$ProbeOnly,
  [int]$FirstN = 0,
  [switch]$CleanUp,
  [switch]$ShowFfmpeg,
  [string]$VideoExt = '',
  [string]$NameSuffix = '',
  [string]$FfmpegCmd = ''
)

# 强制 UTF-8 输出编码：避免中文文件名在控制台 / 管道（被 C# 外壳或重定向捕获）下出现乱码。
# 该设置会作用于本进程以及它再启动的 encode 子进程（子进程启动时读取同一设置）。
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
try { $OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# =====================================================================
# setting.ini support
# =====================================================================
function Read-Ini($Path) {
  # Use a FLAT hashtable: keys are "Section.Key" (no nested tables, which
  # are fragile under PowerShell's indexer semantics).
  $ini = @{}
  $section = ''
  foreach ($line in (Get-Content -Encoding UTF8 $Path)) {
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
  if ($config -and $config.ContainsKey($full)) {
    $v = $config[$full]
    if ($null -ne $v -and $v.Trim() -ne '') { return $v.Trim() }
  }
  return $fallback
}

function To-Bool($v) {
  return ($v -eq 'true' -or $v -eq '1' -or $v -eq 'yes' -or $v -eq 'on')
}

<#
  Split-CommandLine: tokenize a command-line string into arguments while
  honoring DOUBLE quotes, so a path that contains spaces stays one token.
  Single quotes are treated as literal characters (not quoting) to keep
  behaviour predictable. Used by the custom-ffmpeg-command path, where the
  user supplies a raw ffmpeg argument string (with {input}/{output}).
#>
function Split-CommandLine([string]$cmd) {
  $tokens = @()
  $cur = ''
  $inQ = $false
  for ($i = 0; $i -lt $cmd.Length; $i++) {
    $c = $cmd[$i]
    if ($c -eq [char]'"') { $inQ = -not $inQ; continue }
    if ($c -eq [char]' ' -and -not $inQ) {
      if ($cur -ne '') { $tokens += $cur; $cur = '' }
    } else {
      $cur += $c
    }
  }
  if ($cur -ne '') { $tokens += $cur }
  return $tokens
}

<#
  Localize-FfmpegCmd: turn a user-supplied ffmpeg command (copied from anywhere)
  into a PER-SEGMENT argument list. The program then auto-slices (-ss/-t),
  substitutes the real source / segment paths, and returns the args. Two input
  styles are supported:

  (A) Placeholder style (explicit, most robust):
        -i {input} ... {output}
      The program substitutes {input}/{output} with the real source / segment
      paths and injects -ss/-t for the slice seek.

  (B) "Paste a complete command" style (zero editing required):
        ffmpeg -i input.mp4 -c:v libx265 -crf 28 -c:a aac output.mp4
      The program AUTO-LOCALIZES:
        - drops any leading "ffmpeg" / "ffmpeg.exe" program token (we invoke it)
        - replaces the FIRST "-i <path>" with the real source video
        - replaces the LAST non-option argument with the per-segment output
          (values of options like -movflags +faststart are NOT mistaken for output)
        - removes any pre-existing top-level -ss / -t / -to (the program injects
          its own slice seek, so a leftover -ss/-t would conflict)
        - injects  -ss <start> -t <len>  right after the "-i <source>"
      Everything else in the command is preserved verbatim. This is what lets a
      command copied verbatim from the web work with no manual editing.
#>
function Localize-FfmpegCmd {
  param(
    [string]$Raw,
    [string]$Source,    # full path to the source video
    [string]$Segment,   # full path to the segment output
    [double]$Start,
    [double]$Len
  )
  $Raw = $Raw.Trim()

  # ---- style (A): explicit {input}/{output} placeholders ----
  if ($Raw -match '\{input\}' -or $Raw -match '\{output\}') {
    $qIn  = '"{0}"' -f ($Source -replace '\\', '/')
    $qOut = '"{0}"' -f ($Segment -replace '\\', '/')
    $s = $Raw -replace '(")?\{input\}(")?', $qIn
    $s = $s -replace '(")?\{output\}(")?', $qOut
    if ($s -match '-i\s') {
      $s = $s -replace '(-i\s+"?[^"]*"?\s*)', ('$1-ss {0} -t {1} ' -f $Start, $Len)
    } else {
      $s = ('-ss {0} -t {1} ' -f $Start, $Len) + $s
    }
    return (Split-CommandLine $s)
  }

  # ---- style (B): auto-localize a complete pasted command ----
  $tokens = Split-CommandLine $Raw
  # drop a leading ffmpeg program token (we invoke ffmpeg ourselves)
  if ($tokens.Count -gt 0 -and $tokens[0] -match '(?i)^ffmpeg(\.exe)?$') {
    $tokens = $tokens[1..($tokens.Count - 1)]
  }
  # options that take NO argument (so the next token is a separate option)
  $noArg = @('-y','-n','-hide_banner','-nostdin','-vn','-an','-sn','-dn','-shortest',
             '-copyts','-benchmark','-stats','-nostats','-accurate_seek',
             '-noaccurate_seek','-ignore_unknown')

  # pass 1: locate the first -i (replace its value with source), strip -ss/-t/-to
  $newTokens = @()
  $i = 0
  $inputReplaced = $false
  while ($i -lt $tokens.Count) {
    $tok = $tokens[$i]
    # remove standalone top-level -ss / -t / -to and their following value
    if ($tok -eq '-ss' -or $tok -eq '-t' -or $tok -eq '-to') { $i += 2; continue }
    if ($tok -eq '-i') {
      $newTokens += $tok          # keep -i
      $i++
      if ($i -lt $tokens.Count) { $newTokens += $Source; $inputReplaced = $true; $i++ }
      continue
    }
    $newTokens += $tok
    if ($tok.StartsWith('-') -and -not ($noArg -contains $tok)) {
      $i++                                   # skip this option's value token
      if ($i -lt $tokens.Count) { $newTokens += $tokens[$i] }
    }
    $i++
  }
  # defensive: if no -i present, prepend one with the source
  if (-not $inputReplaced) { $newTokens = @('-i', $Source) + $newTokens }

  # pass 2: inject -ss/-t right after the first -i and its source value
  $outTokens = @()
  $i = 0
  $injected = $false
  while ($i -lt $newTokens.Count) {
    $outTokens += $newTokens[$i]
    if (-not $injected -and $newTokens[$i] -eq '-i') {
      $i++
      if ($i -lt $newTokens.Count) { $outTokens += $newTokens[$i]; $i++ }
      $outTokens += '-ss'; $outTokens += ([string]$Start)
      $outTokens += '-t';  $outTokens += ([string]$Len)
      $injected = $true
      continue
    }
    $i++
  }

  # pass 3: replace the LAST argument that is NOT an option and NOT an option's
  # value with the per-segment output (so -movflags +faststart etc. are skipped).
  $lastIdx = -1
  for ($k = 0; $k -lt $outTokens.Count; $k++) {
    $tok = $outTokens[$k]
    if (-not $tok.StartsWith('-')) {
      $isValue = ($k -gt 0 -and $outTokens[$k-1].StartsWith('-') -and -not ($noArg -contains $outTokens[$k-1]))
      if (-not $isValue) { $lastIdx = $k }
    }
  }
  if ($lastIdx -ge 0) { $outTokens[$lastIdx] = $Segment }
  else { $outTokens += $Segment }
  return $outTokens
}

$scriptDir = Split-Path $MyInvocation.MyCommand.Path
$iniPath   = if ($Ini) { $Ini } else { Join-Path $scriptDir 'setting.ini' }
# 家目录 = setting.ini 所在目录（用户真正操作的文件夹）。
# 当脚本被 exe 释放到临时目录运行时，此处仍指向用户文件夹，
# 所以“留空=脚本目录”的 ffmpeg / 视频源默认都落到用户文件夹，不会跑到临时目录。
$homeDir   = Split-Path $iniPath
$config = if (Test-Path $iniPath) { Read-Ini $iniPath } else { @{} }
if (Test-Path $iniPath) { Write-Host "Loaded config: $iniPath" }

# Merge precedence: command line (explicit) > setting.ini > built-in default
# INI 留空 => 脚本所在目录（批量处理其下所有视频）
# INI 留空 => 自动批量处理“setting.ini 所在目录”（即用户文件夹）下的所有视频
$Video      = if ($PSBoundParameters.ContainsKey('Video')) { $Video } else { $iniVid = Get-IniVal 'Source' 'Video' ''; if ([string]::IsNullOrWhiteSpace($iniVid)) { $homeDir } else { $iniVid } }
$Dir        = if ($PSBoundParameters.ContainsKey('Dir'))        { $Dir }       else { $null }
$Recurse    = if ($PSBoundParameters.ContainsKey('Recurse'))    { $Recurse }   else { To-Bool (Get-IniVal 'Source' 'Recurse' 'false') }
$MinSizeMB  = if ($PSBoundParameters.ContainsKey('MinSizeMB'))  { $MinSizeMB } else { [int](Get-IniVal 'Source' 'MinSizeMB' '0') }
$SegLen     = if ($PSBoundParameters.ContainsKey('SegLen'))     { $SegLen }    else { [int](Get-IniVal 'Output' 'SegLen' '600') }
$OutDir     = if ($PSBoundParameters.ContainsKey('OutDir'))     { $OutDir }    else { Get-IniVal 'Output' 'OutDir' '' }
$Crf        = if ($PSBoundParameters.ContainsKey('Crf'))        { $Crf }       else { [int](Get-IniVal 'Encode' 'Crf' '24') }
$Preset     = if ($PSBoundParameters.ContainsKey('Preset'))     { $Preset }    else { Get-IniVal 'Encode' 'Preset' 'medium' }
# INI 留空 => setting.ini 所在目录下的 ffmpeg.exe / ffprobe.exe（显式 ffmpeg 走 PATH；写完整路径用该路径）
$Ffmpeg = if ($PSBoundParameters.ContainsKey('Ffmpeg')) { $Ffmpeg } else { $iniFf = Get-IniVal 'FFmpeg' 'Ffmpeg' ''; if ([string]::IsNullOrWhiteSpace($iniFf)) { Join-Path $homeDir 'ffmpeg.exe' } else { $iniFf } }
$FirstN     = if ($PSBoundParameters.ContainsKey('FirstN'))     { $FirstN }    else { [int](Get-IniVal 'Run' 'FirstN' '0') }
$ProbeOnly  = if ($PSBoundParameters.ContainsKey('ProbeOnly'))  { $ProbeOnly } else { To-Bool (Get-IniVal 'Run' 'ProbeOnly' 'false') }
$ConcatOnly = if ($PSBoundParameters.ContainsKey('ConcatOnly')) { $ConcatOnly }else { To-Bool (Get-IniVal 'Run' 'ConcatOnly' 'false') }
$BurnSub    = if ($PSBoundParameters.ContainsKey('BurnSub'))    { $BurnSub }   else { To-Bool (Get-IniVal 'Encode' 'BurnSub' 'true') }
$SubMode    = (Get-IniVal 'Subtitle' 'Mode' 'copy').ToLower()
$CleanUp    = if ($PSBoundParameters.ContainsKey('CleanUp'))    { $CleanUp }   else { To-Bool (Get-IniVal 'Run' 'CleanUp' 'true') }
$ShowFfmpeg = if ($PSBoundParameters.ContainsKey('ShowFfmpeg')){ $ShowFfmpeg }else { To-Bool (Get-IniVal 'Run' 'ShowFfmpeg' 'false') }
$Codec        = Get-IniVal 'Encode' 'Codec' 'libx265'
$PixelFormat  = Get-IniVal 'Encode' 'PixelFormat' 'yuv420p10le'
$TagHvc1      = To-Bool (Get-IniVal 'Encode' 'TagHvc1' 'true')
$AudioCodec   = Get-IniVal 'Encode' 'AudioCodec' 'aac'
$AudioBitrate = Get-IniVal 'Encode' 'AudioBitrate' '96k'
$VideoExt     = if ($PSBoundParameters.ContainsKey('VideoExt'))     { $VideoExt }    else { Get-IniVal 'Source' 'VideoExt' '' }
$NameSuffix  = if ($PSBoundParameters.ContainsKey('NameSuffix'))   { $NameSuffix } else { Get-IniVal 'Output' 'NameSuffix' '' }

# ---- x265 anime-oriented tuning + downscale toggle (all configurable in setting.ini) ----
# X265Params: appended via -x265-params; ignored automatically when Codec is libx264.
#   bframes=8           more B-frames -> smaller
#   qcomp=0.5           flatter quantization (slightly more consistent quality)
#   psy-rd=1.0:psy-rdoq=0.5   lower than x265 defaults -> sharper lines (anime)
#   aq-mode=2:aq-strength=0.8  adaptive quantization (efficiency at low/mid bitrate)
#   no-sao=1            disable SAO -> keeps more detail / sharper edges
#   threaded-me=1       multi-threaded motion estimation (x265 4.2+, multi-core speedup)
$X265Params  = Get-IniVal 'Encode' 'X265Params' 'bframes=8:qcomp=0.5:psy-rd=1.0:psy-rdoq=0.5:aq-mode=2:aq-strength=0.8:no-sao=1:threaded-me=1'
# Downscale: when ON, shrink each frame to DownscaleW x DownscaleH (lanczos) before encode.
# DownscaleH = -2 means "auto height, even number" (preserves aspect ratio, no distortion).
$Downscale   = To-Bool (Get-IniVal 'Encode' 'Downscale' 'true')
$DownscaleW  = Get-IniVal 'Encode' 'DownscaleW' '768'
$DownscaleH  = Get-IniVal 'Encode' 'DownscaleH' '-2'

# ---- custom ffmpeg command (HIGHEST priority for the per-segment re-encode) ----
# If non-empty, the program auto-splits the source into time-based segments and
# re-encodes EACH segment using THIS command. ALL other [Encode] settings
# (Crf / Preset / Codec / X265Params / Downscale / faststart / PixelFormat) are
# then IGNORED -- the user's command is fully authoritative for the encode step.
# The program does the slicing (-ss/-t injected from [Output] SegLen), the source/
# segment path substitution, and the final concat. The user does NOT edit the
# pasted command. Two accepted styles:
#   (A) explicit placeholders:  -i {input} ... {output}
#   (B) a complete pasted command copied from anywhere, e.g.
#         ffmpeg -i input.mp4 -c:v libx265 -crf 28 -c:a aac output.mp4
#       -> the program auto-localizes: drops the leading ffmpeg, replaces the
#          first -i's file with the real source, replaces the last output file
#          with the per-segment output, strips any -ss/-t/-to, and injects its
#          own -ss/-t for the slice.
# The program always prepends -hide_banner -y. DO NOT put -ss/-t/-y in your
# command (they are managed automatically); DO NOT quote {input}/{output}.
# If empty (default), the normal per-setting encode path runs.
$CustomCmd = if ($PSBoundParameters.ContainsKey('FfmpegCmd')) { $FfmpegCmd } else { Get-IniVal 'Encode' 'FFmpegCmd' '' }

# ---- ffmpeg / ffprobe availability ----
$ffprobe = $Ffmpeg -replace 'ffmpeg(\.exe)?$', 'ffprobe$1'
if ($Ffmpeg -match '[\\/]') {
  if (-not (Test-Path $Ffmpeg)) {
    Write-Host "ERROR: ffmpeg not found at: $Ffmpeg. Check the path or pass -Ffmpeg 'C:\path\to\ffmpeg.exe'"
    exit 1
  }
} else {
  if (-not (Get-Command $Ffmpeg -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: ffmpeg '$Ffmpeg' not found in PATH. Add to PATH or pass -Ffmpeg 'C:\path\to\ffmpeg.exe'"
    exit 1
  }
}

function fmtTime($sec) {
  $sec = [double]$sec
  $h = [math]::Floor($sec / 3600)
  $m = [math]::Floor(($sec % 3600) / 60)
  $s = [math]::Floor($sec % 60)
  return ("{0}h {1}m {2}s" -f $h, $m, $s)
}

function fmtClock($sec) {
  $sec = [math]::Floor([double]$sec)
  $h = [int]([math]::Floor($sec / 3600))
  $m = [int]([math]::Floor(($sec % 3600) / 60))
  $s = [int]([math]::Floor($sec % 60))
  return ("{0:D2}:{1:D2}:{2:D2}" -f $h, $m, $s)
}

<#
  Run-Ffmpeg: launch ffmpeg. By default it redirects ffmpeg's verbose stderr to a
  log file and prints a TWO-LINE compact status per segment (file + time range +
  0% at start, 100% at end). We deliberately do NOT refresh a live progress line
  every tick: under an exe/redirected host "CarriageReturn" does not overwrite, so
  the per-tick line would scroll into hundreds of duplicate rows ("刷屏"); also
  ffmpeg -progress combined with -ss reports an absolute out_time, making a live
  "cur" value wrong. Two lines per segment is enough to know what is processing.
  Pass -Show to dump raw ffmpeg output instead.
#>
function Run-Ffmpeg {
  param(
    [string[]]$ArgumentList,
    [string]$LogFile,
    [string]$ProgFile,
    [double]$TotalSec = 0,
    [string]$StatusLine = '',
    [switch]$Show
  )
  if ($Show) {
    & $Ffmpeg @ArgumentList
    return $LASTEXITCODE
  }
  if ($ProgFile) {
    try { Remove-Item $ProgFile -Force -ErrorAction SilentlyContinue } catch { }
  }
  # Run ffmpeg in a background job so its verbose stderr is redirected to a log
  # file (console stays clean). The main thread polls the -progress file and
  # refreshes ONE status line at the bottom of the window.
  # NOTE: Start-Process is intentionally NOT used here. PS 5.1's Start-Process
  # throws "An item with the same key has already been added" (PATH/Path) when
  # the environment carries a case-duplicated variable (common with v2rayN).
  # Start-Job launches via a plain CreateProcess and is immune to that bug.
  $job = Start-Job -ScriptBlock {
    param($ff, $argsArr, $log)
    & $ff @argsArr 2> $log
    $LASTEXITCODE
  } -ArgumentList $Ffmpeg, $ArgumentList, $LogFile
  $printed = $false
  if ($ProgFile -and $TotalSec -gt 0) {
    # 方案1：每段只打印首行(0%)与尾行(100%)，不在轮询中刷进度。
    # 原因：在 exe / 重定向宿主下 "`r" 不会原地覆盖，每 tick 的刷新会变成
    # 成百上千行重复文本（刷屏）；且 ffmpeg -progress 配合 -ss 时 out_time
    # 报的是绝对时间，cur 会异常失真。只打首尾两行最干净。
    Write-Host ($StatusLine -f 0, '00:00:00')
    $printed = $true
    while ($job.State -eq 'Running') {
      Start-Sleep -Milliseconds 500
    }
    Write-Host ($StatusLine -f 100, (fmtClock $TotalSec))
  }
  Wait-Job $job | Out-Null
  $out = Receive-Job $job
  Remove-Job $job -Force -ErrorAction SilentlyContinue
  $rc = if ($out -match '^\d+$') { [int]$out } else { 1 }
  if (-not $printed) { Write-Host $StatusLine }
  return $rc
}

<#
  Clear-IntermediateTemp: drop the transient artifacts left by an encode run
  once the final is verified good. Only ever called when -CleanUp is on.
  Removes: part_*.mp4 (segments), concat.txt (merge list), prog_*.tmp
  (per-segment + merge progress files) and ffmpeg_*.log (per-segment ffmpeg
  logs + ffmpeg_merge.log). ENCODE_DONE.flag and the final .mp4 are intentionally
  left alone. Failed-run logs are NOT removed here because this only runs after a
  successful verify, so anything still present is genuinely stale.
#>
function Clear-IntermediateTemp {
  param([string]$Dir)
  $patterns = @('part_*.mp4', 'concat.txt', 'prog_*.tmp', 'ffmpeg_*.log')
  foreach ($pat in $patterns) {
    $p = Join-Path $Dir $pat
    if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
  }
}

<#
  Verify-Final: confirm the merged final.mp4 is real and covers (almost) the
  entire source. We REQUIRE >= 98% of the source duration so a truncated merge
  is never mistaken for a finished job (which would let us delete the parts).
#>
function Verify-Final {
  param(
    [string]$final,
    [double]$srcDur,
    [string]$ffprobe,
    [string]$baseName,
    [string]$NameSuffix
  )
  
  # Check if the file exists and has content
  if (-not (Test-Path $final) -or (Get-Item $final).Length -eq 0) { return $false }
  
  # Get the directory and base name from the final path
  $finalDir = Split-Path $final
  $finalName = Split-Path $final -Leaf
  
  # Check if there's a NameSuffix configured and if the suffixed file exists
  if ($NameSuffix -match '\S') {
    $suffixedFinal = Join-Path $finalDir ("$baseName$NameSuffix.mp4")
    if (Test-Path $suffixedFinal) {
      $final = $suffixedFinal
      $finalName = Split-Path $final -Leaf
    }
  }
  
  # Now verify the actual final file (either original or suffixed)
  $fd = & $ffprobe -v error -show_entries format=duration -of csv=p=0 "$final" 2>$null
  $fd = [double]($fd -replace ',', '.')
  if ($fd -le 0) { return $false }
  if ($fd -ge ($srcDur * 0.98)) { return $true }
  return $false
}

<#
  Encode-OneVideo: process a single video file.
  Returns $true on success (or ProbeOnly/FirstN non-merge completion),
  $false if a segment fatally failed OR the final concat failed.
#>
function Encode-OneVideo {
  param(
    [string]$Video,
    [string]$outDir,
    [int]$SegLen,
    [int]$Crf,
    [string]$Preset,
    [string]$Ffmpeg,
    [string]$ffprobe,
    [bool]$ConcatOnly,
    [bool]$BurnSub,
    [bool]$ProbeOnly,
    [int]$FirstN,
    [string]$Codec,
    [string]$PixelFormat,
    [bool]$TagHvc1,
    [string]$AudioCodec,
    [string]$AudioBitrate,
    [bool]$CleanUp,
    [string]$NameSuffix = '',
    [bool]$Downscale,
    [string]$DownscaleW,
    [string]$DownscaleH,
    [string]$X265Params,
    [string]$CustomCmd = ''
  )

  # ---- Probe: container duration + first video stream ----
  $dur = & $ffprobe -v error -show_entries format=duration -of csv=p=0 "$Video" 2>$null
  $dur = [double]($dur -replace ',', '.')
  # Use JSON so field ORDER never matters (ffprobe builds differ in csv layout)
  $j = & $ffprobe -v error -select_streams v:0 `
        -show_entries stream=width,height,avg_frame_rate,codec_name -of json "$Video" 2>$null `
       | ConvertFrom-Json
  $vw = [int]($j.streams[0].width)
  $vh = [int]($j.streams[0].height)
  $vfr = $j.streams[0].avg_frame_rate
  $vcodec = $j.streams[0].codec_name
  $fps = 30.0
  if ($vfr -and $vfr -match '/') {
    $a, $b = $vfr -split '/'
    if ([double]$b -ne 0) { $fps = [math]::Round([double]$a / [double]$b, 3) }
  } elseif ($vfr -match '\d') { $fps = [double]$vfr }
  $n = [math]::Ceiling($dur / $SegLen)
  $baseName = [System.IO.Path]::GetFileNameWithoutExtension($Video)

  # ---- ProbeOnly mode ----
  if ($ProbeOnly) {
    $baseFps  = 6.0
    $baseLoad = 1920 * 1080 * 30.0
    $curLoad  = [double]$vw * [double]$vh * $fps
    $estFps   = [math]::Max(0.5, $baseFps * $baseLoad / $curLoad)
    if ($BurnSub) { $estFps *= 0.85 }
    $totalSec = $dur * $fps / $estFps
    $perSeg   = $SegLen * $fps / $estFps
    Write-Host ""
    Write-Host "==== PROBE ONLY (no encoding performed) ===="
    Write-Host "Source            : $Video"
    Write-Host ("Container duration: {0:N1} s  ({1})" -f $dur, (fmtTime $dur))
    Write-Host ("Video stream      : {0} x {1}, {2} fps, codec {3}" -f $vw, $vh, $fps, $vcodec)
    Write-Host ("Segment length    : {0} s  ->  {1} segments" -f $SegLen, $n)
    Write-Host ("Est. speed (5600U): ~{0:N1} fps  ({1}, {2}{3})" -f $estFps, $Preset, $Codec, $(if($BurnSub){", burn-sub"}else{""}))
    Write-Host ("Per segment (~{0}s): ~{1}" -f $SegLen, (fmtTime $perSeg))
    Write-Host ("TOTAL encode time : ~{0}   (~ {1:N1} h)" -f (fmtTime $totalSec), ($totalSec/3600))
    Write-Host "Disk note: keep >= 2x source free (all parts + final coexist)."
    Write-Host "Speed is a rough model (+/-30%). Use -Preset fast to cut time ~40%."
    Write-Host "=============================================="
    return $true
  }

  # Always use fixed ENCODE_DONE.flag location for cache check
  $doneFlag = Join-Path $outDir "ENCODE_DONE.flag"
  # ---- Fast-skip if a previous run already completed this video ----
  # (valid final + flag present). Prevents re-encoding deleted parts or
  # re-merging when a good final.mp4 already exists. -ConcatOnly bypasses this
  # so the user can force a re-merge; -ProbeOnly/-FirstN never skip.
  $final = Join-Path $outDir "final.mp4"
  # Check if there's a NameSuffix configured and if the suffixed file exists
  if ($NameSuffix -match '\S') {
    $suffixedFinal = Join-Path $outDir ("$baseName$NameSuffix.mp4")
    if (Test-Path $suffixedFinal) {
      $final = $suffixedFinal
    }
  }
  if (-not $ProbeOnly -and -not $FirstN -and -not $ConcatOnly -and (Test-Path $doneFlag) -and (Verify-Final -final $final -srcDur $dur -ffprobe $ffprobe -baseName $baseName -NameSuffix $NameSuffix)) {
    if ($CleanUp) { Clear-IntermediateTemp -Dir $outDir }
    Write-Host "SKIP: $Video already fully encoded (final valid + ENCODE_DONE.flag present)."
    Write-Host "  To re-press: delete $doneFlag (and $final if you changed encode settings), then re-run."
    return $true
  }

  New-Item -ItemType Directory -Force -Path $outDir | Out-Null
  $anyEncoded = $false   # tracks whether any segment got re-encoded this run
  Write-Host "File: $baseName  |  Duration: $dur s  |  Segments: $n @ ${SegLen}s each"

  # ---- Smart downscale guard: never UPSCALE a source that is already narrow ----
  # The scale filter uses an absolute target width, so if the source width is
  # already <= target, scaling could only ENLARGE the picture (bigger file AND
  # softer image). Detect that once per video and skip the scale entirely.
  $doScale = $Downscale
  if ($doScale) {
    $targetW = 0
    if ([int]::TryParse([string]$DownscaleW, [ref]$targetW)) {
      if ($targetW -gt 0 -and $vw -gt 0 -and $vw -le $targetW) {
        $doScale = $false
        Write-Host ("  NOTE: source is {0}x{1}, width <= target {2} -> keep original resolution (no upscaling)." -f $vw, $vh, $targetW)
      }
    }
  }

  # ---- BurnSub: find same-name subtitle, copy into OutDir, build -vf ----
  $vf = $null
  if ($BurnSub) {
    $srcDir = Split-Path $Video
    $base   = [System.IO.Path]::GetFileNameWithoutExtension($Video)
    $cands = @(
      (Join-Path $srcDir "$base.ass"),
      (Join-Path $srcDir "$base.srt"),
      (Get-ChildItem $srcDir -Filter "*.ass" | Select-Object -First 1 | ForEach-Object { $_.FullName }),
      (Get-ChildItem $srcDir -Filter "*.srt" | Select-Object -First 1 | ForEach-Object { $_.FullName })
    ) | Where-Object { $_ -and (Test-Path $_) }

    if ($cands) {
      $subSrc = $cands[0]
      $subExt = [System.IO.Path]::GetExtension($subSrc)
      $subDst = Join-Path $outDir ("burn_sub" + $subExt)
      Copy-Item $subSrc $subDst -Force
      $subEsc = ($subDst -replace '\\', '/')
      $vf = "subtitles='" + $subEsc + "'"
      Write-Host "BurnSub: found '$subSrc' -> burning into picture (subtitle becomes part of video)"
    } else {
      Write-Host "BurnSub: no .ass/.srt found next to the video; encoding without subtitles."
    }
  }

  # ---- migration guard: 0-based -> 1-based rename (2026-10-07) ----
  # An OLD 0-based leftover (part_000.mp4) with no new part_001.mp4 means the
  # output dir was produced by a previous build. Reusing it would let resume
  # silently skip/mis-map segments and emit a corrupt final. Force clean re-run.
  $legacyPart = Join-Path $outDir 'part_000.mp4'
  $newFirst   = Join-Path $outDir 'part_001.mp4'
  if ((Test-Path $legacyPart) -and -not (Test-Path $newFirst)) {
    Write-Host ''
    Write-Host 'ERROR: detected legacy 0-based naming (part_000.mp4 present, no part_001.mp4).'
    Write-Host '  This build uses 1-based naming (part_001.mp4 and up).'
    Write-Host "  Please delete the output folder '$outDir' and re-run, or resume will mis-map segments."
    Write-Host ''
    return $false
  }

  if (-not $ConcatOnly) {
    for ($i = 1; $i -le $n; $i++) {
      if ($FirstN -gt 0 -and $i -gt $FirstN) {
        Write-Host "FirstN limit reached ($FirstN). Stopping before final merge."
        break
      }
      $segIndex = $i - 1
      $start = $segIndex * $SegLen
      $part  = Join-Path $outDir ("part_{0:D3}.mp4" -f $i)
      $len   = [math]::Min($SegLen, [double]($dur - $start))

      # resume guard: skip if part exists, is a valid video, AND its length
      # matches this segment's expected length (so a leftover short test clip
      # from a different -SegLen won't be mistaken for a finished segment).
      if (Test-Path $part) {
        $vd = & $ffprobe -v error -select_streams v:0 -show_entries stream=duration -of csv=p=0 "$part" 2>$null
        $expectedLen = [math]::Min($SegLen, [double]($dur - $start))
        if (($LASTEXITCODE -eq 0) -and ($vd -match '\d')) {
          $vdNum = [double]($vd -replace ', ', '.')
          if (($vdNum -gt 0) -and ([math]::Abs($vdNum - $expectedLen) -le 2.0)) {
            Write-Host ("[$i/$n] SKIP (already done): {0}  {1} - {2}" -f $baseName, (fmtClock $start), (fmtClock ($start + $len)))
            continue
          }
        }
        Write-Host ("[$i/$n] STALE/CORRUPT part, re-encoding: {0}  {1} - {2}" -f $baseName, (fmtClock $start), (fmtClock ($start + $len)))
        # Remove the stale/corrupt part before re-encoding. The file can be
        # momentarily locked (antivirus scan, or a leftover ffmpeg process from
        # an interrupted run), so retry a few times; if it still won't go, just
        # warn and let ffmpeg (which uses -y) overwrite it on its own.
        $removed = $false
        for ($t = 1; $t -le 5; $t++) {
          try { Remove-Item $part -Force -ErrorAction Stop; $removed = $true; break }
          catch { Start-Sleep -Milliseconds 500 }
        }
        if (-not $removed) {
          Write-Host ("  WARNING: could not delete stale {0} (locked?); ffmpeg will overwrite it." -f $part)
        }
        $anyEncoded = $true
      }

      $anyEncoded = $true

      # ---- Build the ffmpeg argument list for this segment ----
      # HIGHEST PRIORITY: if a custom ffmpeg command is configured
      # ([Encode] FFmpegCmd / -FfmpegCmd), use it verbatim for the per-segment
      # re-encode; all other encode settings are ignored. The program still does
      # the auto-split (it injects -ss/-t) and the final concat. Placeholders:
      #   {input}  = source video (auto-quoted)
      #   {output} = this segment's output file (auto-quoted)
      $progSeg = Join-Path $outDir ("prog_{0:D3}.tmp" -f $i)
      $logSeg  = Join-Path $outDir ("ffmpeg_{0:D3}.log" -f $i)

      if ($CustomCmd -and $CustomCmd.Trim() -ne '') {
        # Localize a user-supplied ffmpeg command: it may use {input}/{output}
        # placeholders OR be a complete pasted command (ffmpeg -i in out). Either
        # way we auto-slice (-ss/-t), substitute the real source/segment paths,
        # and return the argument list. -hide_banner -y and -progress are added
        # by the caller. The user never has to edit the pasted command.
        $encArgs = @('-hide_banner', '-y') + (Localize-FfmpegCmd -Raw $CustomCmd `
                      -Source $Video -Segment $part -Start $start -Len $len)
        $encArgs += @('-progress', $progSeg)
      } else {
        # Build the argument list (paths need no manual quotes; both & and
        # Start-Process handle spaces / Unicode correctly)
        $encArgs = @('-hide_banner', '-y', '-i', $Video, '-ss', $start, '-t', $len,
                     '-map', '0:v:0?', '-map', '0:a:0?',
                     '-c:v:0', $Codec, '-preset:v:0', $Preset)
        # x265-specific tuning: anime-oriented sharp lines + threaded motion est.
        # (Ignored automatically when Codec is libx264.)
        if ($Codec -match 'x265|hevc' -and $X265Params) {
          $encArgs += @('-x265-params', $X265Params)
        }
        $encArgs += @('-crf:v:0', $Crf)
        if ($TagHvc1 -and $Codec -match 'x265|hevc') {
          $encArgs += @('-tag:v:0', 'hvc1')
        }
        $encArgs += @('-c:a:0', $AudioCodec, '-b:a:0', $AudioBitrate)
        # Build the video filter chain: burn-sub (if any) + optional downscale + pixel format.
        $vfParts = @()
        if ($vf) { $vfParts += $vf }
        if ($doScale) {
          $vfParts += ("scale={0}:{1}:flags=lanczos" -f $DownscaleW, $DownscaleH)
        }
        if ($vfParts.Count -gt 0) {
          $chain = $vfParts -join ','
          if ($PixelFormat) { $chain += ",format=$PixelFormat" }
          $encArgs += @('-vf', $chain)
        } elseif ($PixelFormat) {
          $encArgs += @('-pix_fmt:v:0', $PixelFormat)
        }
        # Relocate the moov atom to the front for fast web/streaming start.
        $encArgs += @('-movflags', '+faststart')
        $encArgs += @('-progress', $progSeg, $part)
      }

      $statusLine = ("[{0}/{1}] {2}  {3} - {4}  prog {{0,3}}%  cur {{1}}" -f $i, $n, $baseName, (fmtClock $start), (fmtClock ($start + $len)))
      $rc = Run-Ffmpeg -ArgumentList $encArgs -LogFile $logSeg -ProgFile $progSeg -TotalSec $len -StatusLine $statusLine -Show:$ShowFfmpeg
      if (Test-Path $progSeg) { Remove-Item $progSeg -Force -ErrorAction SilentlyContinue }
      if ($rc -eq 0) {
        # delete the log for a successful segment — only failures are worth keeping
        Remove-Item $logSeg -Force -ErrorAction SilentlyContinue
      }
      if ($rc -ne 0) {
        Write-Host "FAILED segment $i of $Video (see $logSeg). Fix the issue and re-run the SAME command to resume."
        return $false
      }
    }
  }

  # ---- FirstN test mode: do not merge an incomplete file ----
  if ($FirstN -gt 0) {
    Write-Host ""
    Write-Host "==== FirstN test mode ===="
    Write-Host "Encoded first $FirstN segment(s) of $Video into $outDir."
    Write-Host "No final merge performed (incomplete file). Verify e.g.:"
    Write-Host "  $outDir\part_001.mp4"
    Write-Host "When ready for the full encode, re-run the SAME command WITHOUT -FirstN."
    Write-Host "==========================="
    return $true
  }

  # ---- build concat list using RELATIVE names (no Chinese dir name enters
  #      the file, so encoding never breaks on Unicode paths) + UTF-8 no BOM ----
  $list = Join-Path $outDir "concat.txt"
  $relLines = 1..$n | ForEach-Object { "file 'part_{0:D3}.mp4'" -f $_ }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllLines($list, $relLines, $utf8NoBom)

  # Skip the merge entirely if the final already exists AND nothing was
  # re-encoded this run (i.e. every segment was resumed/skipped). This avoids
  # re-concatenating a file that is already complete. -ConcatOnly always merges.
  $final = Join-Path $outDir "final.mp4"
  # Check if there's a NameSuffix configured and if the suffixed file exists
  if ($NameSuffix -match '\S') {
    $suffixedFinal = Join-Path $outDir ("$baseName$NameSuffix.mp4")
    if (Test-Path $suffixedFinal) {
      $final = $suffixedFinal
    }
  }
  if ((Test-Path $final) -and -not $anyEncoded -and -not $ConcatOnly) {
    if (Verify-Final -final $final -srcDur $dur -ffprobe $ffprobe -baseName $baseName -NameSuffix $NameSuffix) {
      # Always use the fixed ENCODE_DONE.flag location for cache check
      $doneFlag = Join-Path $outDir "ENCODE_DONE.flag"
      New-Item -ItemType File -Force -Path $doneFlag | Out-Null
      if ($CleanUp) {
        Clear-IntermediateTemp -Dir $outDir
        $left = @(Get-ChildItem (Join-Path $outDir 'part_*.mp4') -Force -ErrorAction SilentlyContinue).Count
        if ($left -gt 0) { Write-Host "  NOTE: $left part(s) could not be removed (locked?); final is still complete." }
        Write-Host "SKIP merge: $final already complete. Cleaned intermediate parts."
        # rename final if suffix configured
        if ($NameSuffix -match '\S') {
          $newFinal = Join-Path $outDir ("$baseName$NameSuffix.mp4")
          if (Test-Path $newFinal) { Remove-Item $newFinal -Force -ErrorAction SilentlyContinue }
          Rename-Item -Path $final -NewName ("$baseName$NameSuffix.mp4")
          $final = $newFinal
          Write-Host "  renamed final to: $baseName$NameSuffix.mp4"
        }
      } else {
        Write-Host "SKIP merge: $final already complete (intermediate parts kept)."
      }
    } else {
      Write-Host "SKIP merge: $final exists but its duration looks wrong (source $dur s)."
      Write-Host "  Delete $final and re-run to re-merge; parts are kept."
    }
    return $true
  }
  Write-Host "Concatenating $n parts of $baseName -> $final"
  $progMerge = Join-Path $outDir "prog_merge.tmp"
  $logMerge  = Join-Path $outDir "ffmpeg_merge.log"
  if ($BurnSub) {
    # 字幕已烧录进画面，不再封装字幕轨，避免重复显示
    Write-Host "Subtitle: BurnSub enabled -> burned into video; skipping muxing subtitle stream."
    $mergeArgs = @('-hide_banner', '-y', '-f', 'concat', '-safe', '0', '-i', $list, '-c', 'copy', '-progress', $progMerge, $final)
  } elseif ($SubMode -eq 'off') {
    $mergeArgs = @('-hide_banner', '-y', '-f', 'concat', '-safe', '0', '-i', $list, '-c', 'copy', '-progress', $progMerge, $final)
  } else {
    $sCode = if ($SubMode -eq 'mov_text') { 'mov_text' } else { 'copy' }
    Write-Host ("Subtitle: muxing source subtitle stream (mode={0}) into output." -f $sCode)
    $mergeArgs = @('-hide_banner', '-y',
                   '-f', 'concat', '-safe', '0', '-i', $list,
                   '-i', $Video,
                   '-map', '0:v', '-map', '0:a', '-map', '1:s?',
                   '-c:v', 'copy', '-c:a', 'copy', '-c:s', $sCode,
                   '-progress', $progMerge, $final)
  }
  $statusLine = ("merge {0}  ->  final.mp4  prog {{0,3}}%" -f $baseName)
  $rc = Run-Ffmpeg -ArgumentList $mergeArgs -LogFile $logMerge -ProgFile $progMerge -TotalSec $dur -StatusLine $statusLine -Show:$ShowFfmpeg
  if (Test-Path $progMerge) { Remove-Item $progMerge -Force -ErrorAction SilentlyContinue }
  if ($rc -ne 0 -or -not (Test-Path $final) -or (Get-Item $final).Length -eq 0) {
    Write-Host "FAILED to concatenate into $final. Parts are kept; re-run the SAME command to retry merge only (log: $logMerge)."
    return $false
  }
  # merge succeeded — drop the log, only keep it on failure
  Remove-Item $logMerge -Force -ErrorAction SilentlyContinue
  # ---- verify the merged file actually covers the whole source ----
  $final = Join-Path $outDir "final.mp4"
  # Check if there's a NameSuffix configured and if the suffixed file exists
  if ($NameSuffix -match '\S') {
    $suffixedFinal = Join-Path $outDir ("$baseName$NameSuffix.mp4")
    if (Test-Path $suffixedFinal) {
      $final = $suffixedFinal
    }
  }
  if (-not (Verify-Final -final $final -srcDur $dur -ffprobe $ffprobe -baseName $baseName -NameSuffix $NameSuffix)) {
    Write-Host "WARNING: $final was created but its duration looks wrong (source $dur s)."
    Write-Host "  Parts are kept; delete $final and re-run to retry the merge."
    return $false
  }
  # ---- mark complete, then optionally clean up intermediate parts ----
  # Always use the fixed ENCODE_DONE.flag location for cache check
  $doneFlag = Join-Path $outDir "ENCODE_DONE.flag"
  New-Item -ItemType File -Force -Path $doneFlag | Out-Null
  if ($CleanUp) {
    Clear-IntermediateTemp -Dir $outDir
    $left = @(Get-ChildItem (Join-Path $outDir 'part_*.mp4') -Force -ErrorAction SilentlyContinue).Count
    if ($left -gt 0) { Write-Host "  NOTE: $left part(s) could not be removed (locked?); final is still complete." }
    Write-Host "DONE. Final: $final  (cleaned intermediate parts)"
  }
  # ---- rename final.mp4 with configured suffix ----
  if ($NameSuffix -match '\S') {
    $newFinal = Join-Path $outDir ("$baseName$NameSuffix.mp4")
    if (Test-Path $newFinal) { Remove-Item $newFinal -Force -ErrorAction SilentlyContinue }
    Rename-Item -Path $final -NewName ("$baseName$NameSuffix.mp4")
    $final = $newFinal
    Write-Host "  renamed final to: $baseName$NameSuffix.mp4"
  }
  return $true
}

# =====================================================================
# Dispatch
# =====================================================================
# Normalize source: -Dir, or -Video being a folder => batch; -Video file => single
$batchDir     = $null
$singleVideo = $null
if ($Dir) {
  $batchDir = $Dir
} elseif ($Video) {
  if (Test-Path $Video -PathType Container) { $batchDir = $Video }
  elseif (Test-Path $Video -PathType Leaf)  { $singleVideo = $Video }
  else { Write-Host "ERROR: source not found: $Video"; exit 1 }
} else {
  Write-Host "ERROR: provide -Video <file-or-folder> (or -Dir <folder>), or set Video= in setting.ini"
  exit 1
}

if ($singleVideo) {
  $od = if ($OutDir) { $OutDir } else { "encoded_parts" }
  $ok = Encode-OneVideo -Video $singleVideo -outDir $od -SegLen $SegLen -Crf $Crf `
        -Preset $Preset -Ffmpeg $Ffmpeg -ffprobe $ffprobe `
        -ConcatOnly $ConcatOnly -BurnSub $BurnSub -ProbeOnly $ProbeOnly -FirstN $FirstN `
        -Codec $Codec -PixelFormat $PixelFormat -TagHvc1 $TagHvc1         -AudioCodec $AudioCodec -AudioBitrate $AudioBitrate `
        -CleanUp $CleanUp -NameSuffix $NameSuffix `
        -Downscale $Downscale -DownscaleW $DownscaleW -DownscaleH $DownscaleH -X265Params $X265Params -CustomCmd $CustomCmd
  if (-not $ok) { exit 1 }
  exit 0
}

# ---- BATCH mode ----
# Build extension set from config: "VideoExt = .mp4,.mkv,.avi" or empty = default
$extSet = if ($VideoExt -match '\S') {
  $parts = $VideoExt -split ','
  $trimmed = $parts | ForEach-Object { $_.Trim().ToLower() }
  $filtered = $trimmed | Where-Object { $_ }
  @($filtered)
} else {
  @('.mp4', '.mkv', '.mov', '.avi', '.flv', '.webm', '.m4v', '.ts', '.wmv')
}
Write-Host "Scanning $batchDir $(if($Recurse){'(recursive)'}) for videos..."
$vids = Get-ChildItem -Path $batchDir -File -Recurse:([bool]$Recurse) -ErrorAction SilentlyContinue |
        Where-Object { $extSet -contains $_.Extension.ToLower() -and $_.Length -ge ([long]$MinSizeMB * 1MB) }

if ($vids.Count -eq 0) {
  Write-Host "No matching video files found in $batchDir $(if($MinSizeMB -gt 0){"(>= $MinSizeMB MB)"})."
  exit 0
}

$total = $vids.Count
Write-Host "Found $total video(s) to process."
$okList   = @()
$failList = @()

for ($idx = 0; $idx -lt $total; $idx++) {
  $v = $vids[$idx]
  $base = if ($OutDir) { $OutDir } else { $v.DirectoryName }
  $od   = Join-Path $base $v.BaseName
  Write-Host ""
  Write-Host "########## [$(( $idx + 1 ))/$total] $($v.Name) ##########"
  try {
    $r = Encode-OneVideo -Video $v.FullName -outDir $od -SegLen $SegLen -Crf $Crf `
          -Preset $Preset -Ffmpeg $Ffmpeg -ffprobe $ffprobe `
          -ConcatOnly $ConcatOnly -BurnSub $BurnSub -ProbeOnly $ProbeOnly -FirstN $FirstN `
          -Codec $Codec -PixelFormat $PixelFormat -TagHvc1 $TagHvc1 -AudioCodec $AudioCodec -AudioBitrate $AudioBitrate `
          -CleanUp $CleanUp -NameSuffix $NameSuffix `
          -Downscale $Downscale -DownscaleW $DownscaleW -DownscaleH $DownscaleH -X265Params $X265Params -CustomCmd $CustomCmd
  } catch {
    $r = $false
    Write-Host "EXCEPTION while processing $($v.Name): $_"
  }
  if ($r) { $okList += $v.Name } else { $failList += $v.Name }
}

Write-Host ""
Write-Host "================ BATCH SUMMARY ================"
Write-Host "Total: $total | Succeeded: $($okList.Count) | Failed: $($failList.Count)"
if ($okList.Count) {
  Write-Host "OK:"; $okList | ForEach-Object { "  + $_" }
}
if ($failList.Count) {
  Write-Host "FAILED (re-run the same command to resume each):"
  $failList | ForEach-Object { "  - $_" }
}
Write-Host "==============================================="
exit 0
