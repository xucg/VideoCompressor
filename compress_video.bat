@echo off
chcp 65001
cd /d "%~dp0"

echo ============================================================
echo  Video Batch Compressor - Watcher (script mode / compress_video.bat)
echo  Double-click to start; Ctrl+C to stop; auto-exit on idle timeout
echo  Config: setting.ini in this folder
echo ============================================================

powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0video_monitor.ps1"

echo.
echo Watcher finished. Press any key to close...
pause