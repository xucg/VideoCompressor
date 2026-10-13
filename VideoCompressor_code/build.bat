@echo off
setlocal
echo ============================================
echo  VideoCompressor - build with VS2022 MSBuild
echo ============================================
echo.

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" set "VSWHERE=%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"

if not exist "%VSWHERE%" (
  echo ERROR: vswhere.exe not found. Please open VideoCompressor.sln in Visual Studio 2022 and Build.
  goto :wait
)

for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -requires Microsoft.Component.MSBuild -find MSBuild\Current\Bin\MSBuild.exe`) do set "MSBUILD=%%i"

if not defined MSBUILD (
  echo ERROR: MSBuild not found. Please open VideoCompressor.sln in Visual Studio 2022 and Build.
  goto :wait
)

echo Using MSBuild: %MSBUILD%
echo.
"%MSBUILD%" VideoCompressor.csproj /p:Configuration=Release /m
if errorlevel 1 (
  echo.
  echo BUILD FAILED
  goto :wait
)

echo.
echo BUILD OK
echo Output: bin\Release\VideoCompressor.exe
echo.
echo To run: copy the SINGLE file bin\Release\VideoCompressor.exe into your
echo         video folder, then double-click it.
echo         The .ps1 engines are embedded and extracted to a temp folder at
echo         runtime (your video folder never shows .ps1). If no setting.ini is
echo         found beside the exe, one is created from the built-in template.
echo         Put ffmpeg.exe + ffprobe.exe beside it (or set Ffmpeg in setting.ini).
:wait
pause
