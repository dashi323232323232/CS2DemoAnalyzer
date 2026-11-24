@echo off
rem 这个 .bat 只是为了兼容习惯找 bat 的人。
rem 双击 .bat 本身会闪一下控制台（Windows 对 bat 的固有行为，无法避免）；
rem 想完全不闪，请用同目录的 启动.vbs，或桌面快捷方式。
chcp 65001 >nul
cd /d "%~dp0"
start "" wscript.exe "%~dp0启动.vbs"
