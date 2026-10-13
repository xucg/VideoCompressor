============================================================
 VideoCompressor —— 视频批量压缩监控（EXE 外壳）
============================================================

本程序是把原 PowerShell 工具（encode-segments.ps1 /
video_monitor.ps1）打包成的 Windows 桌面程序（.exe）。
功能、画质参数、跳过/续压逻辑 100% 沿用原脚本（前提是 exe 由最新
Resources\ 目录下的 *.ps1 重新编译；磁盘上的旧 exe 内嵌的是旧脚本，不含后续修复，
改完脚本务必重编，详见下文「四、依赖与限制」），只是把
“双击 compress_video.bat”换成了“双击 VideoCompressor.exe”，
并带一个简单的日志窗口 + 启动/停止按钮。

------------------------------------------------------------
编码默认值（与脚本版完全一致，均在 setting.ini 可调）
------------------------------------------------------------
- 编码器：libx265（H.265/HEVC），10bit（yuv420p10le），输出打 hvc1 标签并带 +faststart。
- 质量：CRF 32（best 版默认；x265 的 CRF 刻度比 x264 高约 5~6）。
        版本A 均衡档 = CRF 32（最小最快、人眼看不太出）；
        版本B 清晰档 = CRF 30（更清楚，体积约比版本A 大一倍）。
- 速度档：Preset = fast（本目录固定：比 medium 快、比 veryfast 体积小，是又
        快又小的平衡点；不要升 slow —— 慢一倍只小几个百分点）。
- x265 动漫向调参已写入 X265Params：bframes=8 / qcomp=0.5 / psy-rd=1.0:psy-rdoq=0.5 /
  aq-mode=2:aq-strength=0.8 / no-sao=1 / threaded-me=1。threaded-me=1 需 x265 4.2+，
  旧版 x265 请删掉该项。
- 降分辨率：Downscale = true（默认开，按宽 960 等比缩放到 -2 高度，不变形，
  1080p 源 → 960x540）；版本B 把宽度改成 1280（720p）；想保留原分辨率设 false。
  ✅ 引擎已内置"窄源不放大"保护：源宽度 ≤ 960（720p / 竖屏 / 小课件）时
     自动跳过缩放、保留原始分辨率，并打印 no upscaling 提示，无需手动干预。
注意：以上默认值已随本工程 Resources\setting.ini 一并更新。若你手上的 exe 是用
旧版 Resources 编译的，请重新运行 build.bat 编译，否则仍会跑旧的编码参数。

------------------------------------------------------------
一、如何生成 exe（只需做一次）
------------------------------------------------------------
方式 1（推荐，最省事）：
  双击本目录下的 build.bat
  → 自动用 VS2022 的 MSBuild 编译
  → 产物在 bin\Release\VideoCompressor.exe

方式 2（用 VS2022 界面）：
  双击 VideoCompressor.sln 用 Visual Studio 2022 打开
  → 菜单“生成”→“生成解决方案”(或 Ctrl+Shift+B)
  → 产物同上

------------------------------------------------------------
二、如何使用（日常）
------------------------------------------------------------
1) 把 bin\Release\VideoCompressor.exe 复制到你放视频的文件夹
   （首次运行会在 exe 同目录自动生成 setting.ini——已有则保留你的修改；
    两个 .ps1 引擎只释放到系统临时目录、退出即删，不会出现在视频文件夹，无需理会）。
2) 把 ffmpeg.exe、ffprobe.exe 也放进这个文件夹
   （或已在系统 PATH，或在 setting.ini 里写 Ffmpeg 完整路径）。
3) 双击 VideoCompressor.exe
   → 弹出一个窗口，自动开始监控并压制视频。
   → 窗口有三个按钮：
       启动监控 / 停止：手动开、关监控。
       打开 setting.ini：一键用记事本打开配置文件，改完保存即可，
       下次运行生效，无需重新编译 exe。
   → 想停也可直接关窗口。
   → 空闲超过 setting.ini 里 [Monitor] IdleExitMinutes
     （默认 5）分钟没新视频，会自动退出。

------------------------------------------------------------
三、单文件 / 不暴露 .ps1 的说明
------------------------------------------------------------
本程序是“单文件 exe”：你只需把 VideoCompressor.exe 一个文件
放到视频文件夹即可，旁边无需任何 .ps1。
- encode-segments.ps1、video_monitor.ps1 已作为内嵌资源编译进 exe；
  运行时释放到系统临时目录（如 C:\Users\<你>\AppData\Local\Temp\
  VideoCompressor_xxxx），并由程序在退出时自动删除，所以你的视频
  文件夹里永远只会出现 setting.ini + 压制产物，绝不出现 .ps1。
- setting.ini 的处理：exe 同目录【已有则保留你的修改】，【没有则
  从内置模板自动创建一份】。改画质、改监控时长，只需改同目录的
  setting.ini，无需重新生成 exe。
- “ffmpeg / 视频源 留空 = 脚本目录”这句话里的“脚本目录”，在本程序
  中实际指【setting.ini 所在目录】（即你放 exe 的文件夹）。所以把
  ffmpeg.exe 和 exe 放一起、Video 留空，就能自动批量压该文件夹。

------------------------------------------------------------
四、依赖与限制
------------------------------------------------------------
- 需要 Windows PowerShell（Win10/11 自带，无需额外安装）。
- 需要 .NET Framework 4.8 运行时（Win10 1809+ 系统自带）。
- 仍需 ffmpeg / ffprobe（不打包，需自备）。
- 中文文件名已在脚本里强制 UTF-8 输出，控制台与窗口都不会乱码。
- 重要：exe 内嵌的 encode-segments.ps1 / video_monitor.ps1 取自本工程
  Resources\ 目录。若你修改了这两个脚本（或父目录同名 .ps1），必须重新
  运行 build.bat 编译，新 exe 才会包含改动；直接拿旧的 VideoCompressor.exe
  运行，用的仍是它内嵌的旧脚本（例如 1-based 分段命名、旧目录迁移防护等修复
  不会生效）。

------------------------------------------------------------
五、工程结构
------------------------------------------------------------
VideoCompressor.sln        解决方案（VS2022 打开）
VideoCompressor.csproj     C# 工程（.NET Framework 4.8 WinForms）
Program.cs                 外壳源码（释放资源 + 调用监控 + 日志窗口）
build.bat                 一键编译脚本（需 VS2022）
Resources\
  encode-segments.ps1      内嵌：主引擎（源在 Resources\ 或父目录；改后需 build.bat 重编才会生效）
  video_monitor.ps1        内嵌：常驻监控
  setting.ini              内嵌：默认配置模板
