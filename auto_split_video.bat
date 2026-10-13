@echo off
REM =============================================================
REM  按源扩展名自动切片批处理
REM  功能：把[指定]视频按固定时长切成分段文件
REM        - 不重新编码 (流拷贝, 秒切)
REM        - 输出保留[原扩展名] (MP4->MP4, MKV->MKV ...)
REM        - 每段连续编号 _part_001 / _part_002 ...
REM        - 结果放进 splits\ 子目录, 避免二次处理
REM
REM  * 怎么用 (两步都要会) *
REM  1) 切片时长 SEG_MIN (单位: 分钟, 留空则运行时输入, 默认10)
REM       直接改下方 set "SEG_MIN=10"  即可;
REM       也可用命令行第一个参数覆盖:  split_video.bat 5   (每 5 分钟一段)
REM  2) 要切的文件 FILE (必填! 不填会提醒并退出, 不会自动切整个目录)
REM       直接改下方 set "FILE=广告.mp4"  (填文件名, 可带相对或绝对路径)
REM       也可用命令行第二个参数:  split_video.bat 10 广告.mp4
REM
REM  运行后显示一行任务摘要; ffmpeg 输出收进 splits\ffmpeg.log; 处理完停在"按任意键"
REM  如需恢复"自动批量处理整个目录", 删掉 [FILE 检查] 块并把处理段改回
REM    for %%F in (*.mp4 *.mkv ...) do ( ... )  即可。
REM =============================================================

REM ---- [可调参数] ----
set "SEG_MIN="
set "FILE=a_b.ts"

REM 命令行参数: split_video.bat [时长分钟] [文件名]
if not "%~1"=="" set "SEG_MIN=%~1"
if not "%~2"=="" set "FILE=%~2"

REM ---- [FILE 检查]: 未指定则提醒并退出 ----
if "%FILE%"=="" (
    echo.
    echo [错误] 未指定要切片的视频文件!
    echo   方式一: 编辑本文件, 把  set "FILE="  改成  set "FILE=你的视频.mp4"
    echo   方式二: 命令行直接给文件名  格式：split_video.bat 时长 视频
    echo                                               例如：split_video.bat 10 你的视频.mp4
    echo   说明: 本脚本不会自动处理整个目录, 以免误切。必须明确指定 FILE。
    echo.
    pause
    exit /b 1
)


REM ---- [SEG_MIN 交互]: 留空则运行时由使用者输入(分钟) ----
if "%SEG_MIN%"=="" (
    set /p "SEG_MIN=请输入切片时长(分钟, 直接回车默认10): "
)
if "%SEG_MIN%"=="" set "SEG_MIN=10"
REM 分钟 -> 秒 (ffmpeg 用秒)
set /a SEG_SEC=SEG_MIN*60 2>nul || (
    echo 时长必须是数字, 请检查 SEG_MIN 设置。
    pause
    exit /b 1
)

REM ---- ffmpeg 位置 ----
set "FFMPEG=ffmpeg"
REM 若 ffmpeg 不在 PATH, 取消下一行注释并填绝对路径:
REM set "FFMPEG=D:/Program Files (x86)\FFmpeg\ffmpeg.exe"
where ffmpeg >nul 2>&1 || (
    echo 找不到 ffmpeg, 请把它加入 PATH, 或在上方 FFMPEG 变量填绝对路径。
    pause
    exit /b 1
)

REM 切到批处理所在目录
pushd "%~dp0"

REM 准备输出目录
if not exist "splits" md "splits"

echo 任务: "%FILE%"  每 %SEG_MIN% 分钟一段  ^>  splits\

REM 检查文件是否存在
if not exist "%FILE%" (
    echo [错误] 找不到文件: "%FILE%"
    echo   请确认文件名或路径是否正确, 可相对本bat目录或用绝对路径。
    echo.
    pause
    exit /b 1
)

REM ---- 执行切片 (单文件) ----
echo 正在切片，请稍候...
for %%F in ("%FILE%") do (
    "%FFMPEG%" -y -i "%%F" -map 0 -c copy -f segment -segment_time %SEG_SEC% -segment_start_number 1 -reset_timestamps 1 "splits\%%~nF_part_%%03d%%~xF" 2> "splits\ffmpeg.log"
    if errorlevel 1 (
        echo ffmpeg 执行失败, 详情见 splits\ffmpeg.log
        pause
        exit /b 1
    )
)
    echo.

echo 完成。结果见 splits\ 目录 (ffmpeg 日志: splits\ffmpeg.log)
popd
pause
