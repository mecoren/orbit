@echo off
setlocal

setlocal ENABLEDELAYEDEXPANSION

REM ---------------------------------------------------------------------------
REM Fix: ensure a complete Perl + NASM toolchain is used for the Rust/cargokit
REM build. flutter invokes this script via cmd.exe (NOT bash), so .bash_profile
REM / BASH_ENV do NOT apply here. Prepending Strawberry to PATH guarantees that
REM openssl-src can compile OpenSSL from source (libsqlite3-sys vendored-openssl
REM feature) instead of hitting the incomplete Perl shipped with Git for Windows.
REM The nuget.exe in Strawberry\c\bin is also exposed for plugins that need it.
REM ---------------------------------------------------------------------------
if exist "C:\Strawberry\c\bin" set "PATH=C:\Strawberry\c\bin;%PATH%"
if exist "C:\Strawberry\perl\bin" set "PATH=C:\Strawberry\perl\bin;%PATH%"

SET BASEDIR=%~dp0

if not exist "%CARGOKIT_TOOL_TEMP_DIR%" (
    mkdir "%CARGOKIT_TOOL_TEMP_DIR%"
)
cd /D "%CARGOKIT_TOOL_TEMP_DIR%"

SET BUILD_TOOL_PKG_DIR=%BASEDIR%build_tool
SET DART=%FLUTTER_ROOT%\bin\cache\dart-sdk\bin\dart

set BUILD_TOOL_PKG_DIR_POSIX=%BUILD_TOOL_PKG_DIR:\=/%

(
    echo name: build_tool_runner
    echo version: 1.0.0
    echo publish_to: none
    echo.
    echo environment:
    echo   sdk: '^>=3.0.0 ^<4.0.0'
    echo.
    echo dependencies:
    echo   build_tool:
    echo     path: %BUILD_TOOL_PKG_DIR_POSIX%
) >pubspec.yaml

if not exist bin (
    mkdir bin
)

(
    echo import 'package:build_tool/build_tool.dart' as build_tool;
    echo void main^(List^<String^> args^) ^{
    echo    build_tool.runMain^(args^);
    echo ^}
) >bin\build_tool_runner.dart

SET PRECOMPILED=bin\build_tool_runner.dill

REM To detect changes in package we compare output of DIR /s (recursive)
set PREV_PACKAGE_INFO=.dart_tool\package_info.prev
set CUR_PACKAGE_INFO=.dart_tool\package_info.cur

DIR "%BUILD_TOOL_PKG_DIR%" /s > "%CUR_PACKAGE_INFO%_orig"

REM Last line in dir output is free space on harddrive. That is bound to
REM change between invocation so we need to remove it
(
    Set "Line="
    For /F "UseBackQ Delims=" %%A In ("%CUR_PACKAGE_INFO%_orig") Do (
        SetLocal EnableDelayedExpansion
        If Defined Line Echo !Line!
        EndLocal
        Set "Line=%%A")
) >"%CUR_PACKAGE_INFO%"
DEL "%CUR_PACKAGE_INFO%_orig"

REM Compare current directory listing with previous
FC /B "%CUR_PACKAGE_INFO%" "%PREV_PACKAGE_INFO%" > nul 2>&1

If %ERRORLEVEL% neq 0 (
    REM Changed - copy current to previous and remove precompiled kernel
    if exist "%PREV_PACKAGE_INFO%" (
        DEL "%PREV_PACKAGE_INFO%"
    )
    MOVE /Y "%CUR_PACKAGE_INFO%" "%PREV_PACKAGE_INFO%"
    if exist "%PRECOMPILED%" (
        DEL "%PRECOMPILED%"
    )
)

REM There is no CUR_PACKAGE_INFO it was renamed in previous step to %PREV_PACKAGE_INFO%
REM which means  we need to do pub get and precompile
if not exist "%PRECOMPILED%" (
    echo Running pub get in "%cd%"
    "%DART%" pub get --no-precompile
    "%DART%" compile kernel bin/build_tool_runner.dart
)

"%DART%" "%PRECOMPILED%" %*
set CKB_DART_EXIT=%ERRORLEVEL%

REM 253 means invalid snapshot version.
If %CKB_DART_EXIT% equ 253 (
    "%DART%" pub get --no-precompile
    "%DART%" compile kernel bin/build_tool_runner.dart
    "%DART%" "%PRECOMPILED%" %*
    set CKB_DART_EXIT=%ERRORLEVEL%
)

REM ---------------------------------------------------------------------------
REM The cargo target dir is redirected to a short path (C:/ckb) on Windows
REM because openssl-src's bundled source tree under the default deep
REM cargokit_build path exceeds Windows MAX_PATH (260 chars). That breaks
REM Strawberry Perl's stat(), so OpenSSL's Configure reports "missing source
REM files" and the whole Rust build fails (MSB8066). Building into C:/ckb keeps
REM every path under 260. The built cdylib (.dll / .dll.lib / .pdb) is therefore
REM produced under C:/ckb, so copy it back to CARGOKIT_OUTPUT_DIR (the original
REM location MSBuild / Flutter expect) to keep the rest of the pipeline unchanged.
REM ---------------------------------------------------------------------------
set "CKB_TRIPLE=%CARGOKIT_TARGET_TEMP_DIR%\x86_64-pc-windows-msvc"
set "CKB_ART_SRC="
if exist "%CKB_TRIPLE%\debug" set "CKB_ART_SRC=%CKB_TRIPLE%\debug"
if exist "%CKB_TRIPLE%\release" set "CKB_ART_SRC=%CKB_TRIPLE%\release"
if defined CKB_ART_SRC (
    if not exist "%CARGOKIT_OUTPUT_DIR%" mkdir "%CARGOKIT_OUTPUT_DIR%"
    copy /Y "%CKB_ART_SRC%\wait_frbbindings.dll" "%CARGOKIT_OUTPUT_DIR%\" >nul 2>&1
    copy /Y "%CKB_ART_SRC%\wait_frbbindings.dll.lib" "%CARGOKIT_OUTPUT_DIR%\" >nul 2>&1
    if exist "%CKB_ART_SRC%\wait_frbbindings.pdb" copy /Y "%CKB_ART_SRC%\wait_frbbindings.pdb" "%CARGOKIT_OUTPUT_DIR%\" >nul 2>&1
)

exit /b %CKB_DART_EXIT%
