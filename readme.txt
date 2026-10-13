============================================================
 批量切片压缩文件夹内所有视频 · 使用说明（readme）
 Video_Compressor_x265_best —— 当前最优配方版 
============================================================

这是一个把视频用 H.265 (libx265) 分段压制、再合并成一个体积更小
的 mp4 的小工具。特点：
  - 自动把长视频切成小段压制（断点可续、断电最多丢一段）
  - 已压完的视频重跑会自动跳过，不重复劳动
  - 压完自动清理中间分段，省磁盘
  - 自带一个"常驻监控"：把视频丢进文件夹就自动开始压


------------------------------------------------------------
〇、本目录的定位：为什么叫 best
------------------------------------------------------------
设计目标（按你的口径）：
   压缩率越大越好 + 速度越快越好，画质只要"人眼看不太出"就行，
   不为看不见的清晰度浪费码率。

与同级另外两套的区别（三套互不影响，可并存）：

  目录                     分辨率      CRF    体积 / 速度 / 画质
  ----------------------------------------------------------------
  Video_Compressor _x265__crf28  原始分辨率   28   体积大、慢、清晰（旧·已停维护）
  Video_Compressor_x265_deep     768 宽(432p) 28   体积小、快，但明显发糊（旧）
  Video_Compressor_x265_best     960 宽(540p) 32   体积小、快，且不再发糊（本目录·当前默认）

  说明：deep 版把画面压到 768x432 —— 那正是"压出来模糊"的元凶，
        不是 x265 参数的问题。best 版抬到 960x540 并把 CRF 松到 32，
        体积仍远小于原分辨率、速度依然快好几倍，但肉眼不再发糊。

★ 本目录内置【两个版本】，默认走版本A：

  版本A · 均衡档（默认，推荐）
      960 宽(540p) + CRF 32 + preset fast
      → 最小、最快，画质落在"看不太出"区间。日常首选。

  版本B · 清晰档（备选）
      1280 宽(720p) + CRF 30 + preset fast
      → 更清楚一档，体积约比版本A 大一倍。压重要材料时用。

  切换方法（二选一）：
    ① 改 setting.ini 分项值：版本A = Crf 32 / DownscaleW 960；
                              版本B = Crf 30 / DownscaleW 1280
    ② 粘贴预设命令：把 setting.ini 里 [Encode] 的"版本A/版本B"预设行
       复制到 FFmpegCmd = 后面（优先级最高，会忽略上面的分项设置）


------------------------------------------------------------
一、文件清单（全部放同一个文件夹即可）
------------------------------------------------------------
  encode-segments.ps1   主引擎：分段 → 压制 → 合并 → 清理
  video_monitor.ps1     常驻监控：监视频目录，出现新视频就调用主引擎
  compress_video.bat    双击它即可启动监控
  auto_split_video.bat  独立小工具：仅按固定时长【纯切片、不重编码】(-c copy)，与上面压制流程互不串接
  setting.ini           配置文件（所有常用参数都在这里）
  readme.txt           本说明
  （另有 VideoCompressor.exe —— 单文件版，无需 .ps1，见文末说明）


------------------------------------------------------------
二、第一次使用：3 步上手（推荐方式）
------------------------------------------------------------
1) 准备 ffmpeg
   把 ffmpeg.exe 和 ffprobe.exe 放进上面那个文件夹（和 .ps1 同目录）。
   —— 这是最简单的方式：setting.ini 里 Ffmpeg 留空，脚本会自动用
      同目录下的 ffmpeg.exe / ffprobe.exe。
   （另一种方式：如果你已把 ffmpeg 加进系统 PATH，也可以不设，
      在 ini 里写 Ffmpeg = ffmpeg。）

2) 放入视频
   把要压的视频文件直接放进这个文件夹。

3) 双击 compress_video.bat
   监控启动后会在窗口里显示"Watching: <本文件夹>",
   然后自动逐个压制你放进去的视频。
   想停止：在窗口里按 Ctrl+C。

完成后的成品：
   每个视频会在同目录生成 "<视频名>" 子文件夹，
   里面是 final.mp4（默认改名成 "原名_x265_best.mp4"，
   后缀由 NameSuffix 控制，特意带 best 标记，不会和另外两套的产物混在一起）。


------------------------------------------------------------
三、两种用法
------------------------------------------------------------
【方式 A：常驻监控（日常最省事）】
  双击 compress_video.bat 即可。
  它一直运行、监视频文件夹；你随时往里丢视频，它都会自动压。
  每压完一个就立刻重新扫描，所以边压边加也没问题。
  停止：Ctrl+C。
  自动退出：连续 IdleExitMinutes（默认 5）分钟没发现新视频，监控会自行退出，
            不必手动关窗口（设为 0 则永不自动退出，一直挂着）。

  想"只压当前已有的、压完就退、不常驻"？
    打开 PowerShell，进入脚本目录，运行：
      powershell -ExecutionPolicy Bypass -File video_monitor.ps1 -Once

【方式 B：直接跑主脚本（单次 / 批量）】
  打开 PowerShell，进入脚本目录，运行：
    powershell -ExecutionPolicy Bypass -File encode-segments.ps1
  不写任何参数时，Video 留空 = 自动批量处理"脚本所在目录"下所有视频。
  也可指定来源：
    单个文件： ...\encode-segments.ps1 -Video "D:\a\foo.mp4"
    指定目录： ...\encode-segments.ps1 -Video "D:\videos"

  小技巧：先压一段看看效果再决定要不要换版本 ——
    把 setting.ini 的 FirstN 改成 1，跑一次只压第一段。


------------------------------------------------------------
四、配置 setting.ini（基本不用改）
------------------------------------------------------------
优先级：命令行参数  >  setting.ini  >  脚本内置默认值。
等号前后空格会被忽略；以 ; 或 # 开头是注释。

[Source]
  Video     视频来源。留空 = setting.ini 所在目录（即你放 exe/脚本的文件夹，
            批量处理其下所有视频）；也可填单文件路径或目录路径。
  Recurse   目录模式下是否连子文件夹一起扫：true / false
  MinSizeMB 只压大于此大小(MB)的文件，0 = 全部
  VideoExt  扩展名过滤，留空 = 默认常见格式(mp4/mkv/mov/avi/flv/webm/m4v/ts/wmv)。
            想识别自定义扩展名（例如你把 mp4 改名成 .mp4del 来标记待压文件），
            直接写进来即可：  VideoExt = .mp4,.mp4del

[FFmpeg]
  Ffmpeg    ffmpeg 路径。留空 = 用 setting.ini 所在目录（即你放 exe/脚本的文件夹）
            下的 ffmpeg.exe（最省事）；也可写 ffmpeg（走系统 PATH）或完整路径。
            无论哪种，ffprobe.exe 都自动取与它同目录的同名程序。

[Output]
  OutDir    输出根目录。留空 = 在各视频旁建"<视频名>"子目录；
            填了 = 统一输出到 该目录\<视频名>\。
  SegLen    每段时长(秒)。越小断点损失越小、段数越多。推荐 300~600。
  NameSuffix 成品后缀。留空 = final.mp4；
            本目录默认 _x265_best → 成品改名 "原名_x265_best.mp4"。

[Encode]
  Codec        libx265(更省体积) 或 libx264(兼容性最好)。默认 libx265。
  Crf          质量值，越小越好、越大越省体积。H.265 的 CRF 刻度比 H.264 高约 5~6：
               x265 CRF 28 ≈ x264 CRF 24（常用观感）。
               ★ 本目录默认 32（版本A）；版本B 用 30。推荐区间 30~34，
                 再高（34+）渐变处开始出现可见色带，谨慎。
  Preset       速度档：ultrafast/veryfast/fast/medium/slow/slower。
               ★ 本目录固定 fast —— 比 medium 快、比 veryfast 体积小，
                 是"又快又小"的平衡点。
                 （不要升 slow：慢一倍只小约 5~10%，不划算；
                   也不要降 veryfast：更快，但同画质文件反而更大，与"压缩率优先"冲突）
  PixelFormat  yuv420p10le(10bit,推荐) 或 yuv420p(8bit,老设备友好)。
               10bit 在高 CRF 下更抗色带、压缩率略优，故即便要小也保留。
  X265Params   x265 专属调参（仅 libx265 生效），本目录沿用动漫向参数：
               bframes=8 / qcomp=0.5 / psy-rd=1.0:psy-rdoq=0.5 / aq-mode=2:aq-strength=0.8 /
               no-sao=1 / threaded-me=1。threaded-me=1 需 x265 4.2+，旧版请删该段。
  Downscale    是否降分辨率：true(默认,省时省体积)/false(保留原分辨率,高画质归档)。
  DownscaleW / DownscaleH  降分辨率目标宽/高（仅 Downscale=true 生效）。
               ★ 本目录默认 960 / -2（宽960、高按原比例自动取偶数，不变形）
                 → 版本A；版本B 改成 1280 / -2。
               ✅ 已内置"窄源不放大"自动保护：若源本身宽度 ≤ 960（720p、竖屏、
                  小分辨率课件），引擎会【自动跳过缩放】、保留原始分辨率，
                  避免画面被放大导致文件变大又发虚；窗口会打印一行
                  "NOTE: source is ... (no upscaling)" 提示，无需手动干预。
                  （只有确实想强制缩到某个宽度时，才把 DownscaleW 调小。）
  AudioCodec / AudioBitrate  音频，语音/课件 96k 够用
  TagHvc1      H.265 打 hvc1 标签让苹果设备能播：true/false
  BurnSub      烧录同目录同名 .ass/.srt 字幕进画面：true(默认,所有设备可见)/false

  FFmpegCmd  【最高优先】自定义 ffmpeg 压缩命令。留空 = 走上面 Crf/Preset/Codec 等
            分项设置（默认）；填写后 = 程序自动切片，并用本命令逐段重编码、最后合并，
            上面所有编码设置全部被忽略。支持两种写法，粘进去就能用、无需改命令：
            ★ 写法 B（推荐，最省事）：直接从别处复制"完整命令"原样粘入，连
              {input}/{output} 都不用写。例：
                FFmpegCmd = ffmpeg -i D:\临时\原片.mp4 -c:v libx265 -crf 32 -c:a aac D:\临时\成品.mp4
              程序自动：① 丢开头 ffmpeg ② 把第一个 -i 后的文件换成真实源
                        ③ 把最后输出文件换成"本段分段输出" ④ 清掉命令里自带的 -ss/-t/-to
                        ⑤ 在 -i 后注入 -ss/-t（按 SegLen 切片）。原路径/文件名随便写，全忽略。
            ★ 写法 A（显式占位符，更稳）：用 {input}=源视频、{output}=本段输出。
            两种写法程序都会自动加 -hide_banner -y 并在 -i 后注入 -ss/-t（切片），
            【不要再自己写 -ss/-t/-y】。合并仍由程序自动 -c copy 完成。
            本目录的两档预设（版本A / 版本B）就写在 setting.ini 的 FFmpegCmd 注释里，
            复制对应那一行粘到 FFmpegCmd = 后面即可切换版本。

[Subtitle]
  Mode       字幕封装模式（把源视频"内嵌字幕轨"封装进输出 mp4，不烧进画面）：
              copy     = 直接复制字幕轨（无损最快；图形字幕 PGS/SUP 不能进 MP4，仅 MKV/TS 支持）
              mov_text = 转成 mov_text 文本字幕（兼容性最好，能进 MP4；需源字幕为文本字幕轨）
              off      = 不封装字幕轨
              默认 copy。注意：若 [Encode] BurnSub=true，字幕已焊进画面，此处封装会自动跳过，避免重复。

[Run]
  FirstN      只压前 N 段做测试，0 = 全部（可先压一段验证效果）
  ProbeOnly    true = 只预估分段数/耗时，不压制
  ConcatOnly   true = 只把已压好的分段合并（不重新编码）
  CleanUp     压完是否自动删中间分段：true(默认,省空间)/false(保留便于手动重合并)
  ShowFfmpeg  true = 在窗口显示 ffmpeg 原始输出（排查问题时用）


------------------------------------------------------------
五、产物与"跳过/续压"机制
------------------------------------------------------------
- 每个视频处理后在 "<视频名>" 子目录生成 final.mp4（默认带 _x265_best 后缀），
  并写入 ENCODE_DONE.flag 标记"已完成"。
- 中间分段 part_*.mp4、concat.txt、prog_*.tmp、ffmpeg_*.log
  默认在压完校验通过后自动清理（CleanUp=true）。
- 中断后重跑：已完成的视频会被自动跳过；只重新压制失败/缺失的分段。
  想强制重压某个视频：删掉它的 ENCODE_DONE.flag（必要时也删 final.mp4），再跑。
- 输出统一带 -movflags +faststart，网页/流媒体可秒开。


------------------------------------------------------------
六、常见问题
------------------------------------------------------------
Q：双击 bat 后报错 "ffmpeg not found …" / "not found in PATH"
A：没把 ffmpeg.exe/ffprobe.exe 放进脚本目录，也没在 PATH 里。
   把这两个 exe 放到 .ps1 同目录，Ffmpeg 留空即可。

Q：setting.ini 里的中文路径读出来是乱码
A：setting.ini 必须用 UTF-8 编码保存（记事本"保存类型"选 UTF-8）。

Q：窗口里中文文件名显示成 ????? 或乱码
A：脚本已强制以 UTF-8 输出。若你是用 compress_video.bat（控制台）直接跑、
   仍看到乱码，请在 bat 开头加一行「chcp 65001」。用 VideoCompressor.exe 则
   窗口已正确处理中文，无需额外设置。

Q：监控窗口一闪而过 / 启动就退出
A：窗口里会打印原因（通常是 ffmpeg 找不到、或目录不存在）。
   看完按任意键关闭；按提示修正后重跑 compress_video.bat。

Q：我只想压一次就关，不要一直挂着
A：用方式 A 里的 -Once：
    powershell -ExecutionPolicy Bypass -File video_monitor.ps1 -Once

Q：想监控别的文件夹（而不是脚本目录）
A：在 setting.ini 加一段：
    [Monitor]
    Dir = D:\你的视频文件夹
    PollSeconds = 15      ; 空闲时每多少秒重扫一次
    SettleSeconds = 4     ; 等新文件拷贝稳定后再压
    IdleExitMinutes = 5   ; 连续多少分钟没新视频就自动退出（0 = 永不退出）
  不写 [Monitor] 时,监控会沿用 [Source] Video（若是目录）或脚本目录，
  且 PollSeconds / SettleSeconds / IdleExitMinutes 用内置默认值（15 / 4 / 5）。

Q：压出来还是嫌糊 / 嫌大，怎么调？
A：嫌糊 → 换版本B（DownscaleW 改 1280、Crf 改 30），或 Downscale = false 保原始分辨率；
   嫌大 → Crf 往上加 2（34 为上限，再高可见色带），或把 DownscaleW 降到 854(480p)。
   注意：优先动"分辨率 + CRF"这两个杠杆，别去动 preset —— 它对体积的影响
   远小于前两者，却对耗时影响巨大。

Q：源视频本身就不大（720p / 竖屏 / 小课件），会被放大吗？
A：不会。引擎已内置自动保护：源宽度 ≤ 目标宽度时自动跳过缩放，保留原始分辨率，
   并在窗口打印一行 "NOTE: source is ... (no upscaling)"。
   想彻底关掉缩放功能，仍可设 Downscale = false。

Q：这三套目录会不会互相干扰？
A：不会。三套各自独立目录、各自 setting.ini；成品文件名后缀也不同
   （本目录是 _x265_best），压出来的文件不会重名覆盖。


============================================================
一句话总结：
  放好 ffmpeg → 视频丢进文件夹 → 双击 compress_video.bat → 完事。
  默认 = 版本A（540p + CRF32 + fast）：最小最快、肉眼够看。

补充：单文件版 VideoCompressor.exe
  如果你想要"只有一个 exe、旁边不出现 .ps1"的版本：用 VideoCompressor
  工程（含在 VideoCompressor_code\ 目录）双击 build.bat 编译，得到
  VideoCompressor.exe。把它单独放进视频文件夹即可——两个 .ps1 引擎已内嵌，
  运行时释放到系统临时目录并在退出时自动删除，你的文件夹里永远只有
  setting.ini 和压制产物。setting.ini 有则保留、无则自动创建。详细见
  VideoCompressor_code\readme_videocompressor.txt。
  窗口里有三个按钮：启动监控 / 停止 / 打开 setting.ini（一键用记事本打开配置，
  改完保存即可，下次运行生效，无需重新编译）。

  ⚠️ 关于本目录 exe 的一个注意点：
     当前 VideoCompressor.exe 是从 x265_deep 那套复制过来的，它【内嵌】的默认
     配置模板仍是旧值（768 宽 / CRF 28）。只要 exe 旁边有 setting.ini（本目录
     就有，且已是 best 参数），运行时就会优先用旁边这份，不受影响。
     但若你把 exe 单独复制到别的空文件夹用，它会按旧模板生成 setting.ini。
     想让 exe 内置模板也变成 best 参数：进 VideoCompressor_code\ 双击 build.bat
     重新编译一次即可（需装 VS2022）。
============================================================
