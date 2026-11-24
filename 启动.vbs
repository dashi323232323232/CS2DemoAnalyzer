' 启动.vbs — 静默启动 CS2 Demo 分析器
'
' 用 wscript 启动，本身不创建控制台。
'
' 注意 sh.Run 的第二个参数不要用 0（SW_HIDE）：
' 那是「进程创建时」的显示状态，会被 WinForms 的首个顶层窗口继承，
' 结果主界面根本不显示。用 1（SW_SHOWNORMAL），
' 控制台仍由 powershell 自己的 -WindowStyle Hidden 隐藏。
Option Explicit

Dim sh, fso, here, ps, cmd
Set sh  = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

here = fso.GetParentFolderName(WScript.ScriptFullName)
ps   = sh.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"

cmd = """" & ps & """" & _
      " -STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden" & _
      " -File """ & here & "\DemoAnalyzer.ps1"""

' 1 = 正常显示（主窗口才能出现）, False = 不等待
sh.Run cmd, 1, False
