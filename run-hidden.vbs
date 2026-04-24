' =================================================================
' Generic hidden-process launcher.
' Usage: wscript run-hidden.vbs "<command line to run>"
' Runs the given command line with no visible window.
' =================================================================
If WScript.Arguments.Count = 0 Then WScript.Quit
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run WScript.Arguments(0), 0, False
