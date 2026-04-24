' =================================================================
' ClientFlow Proxy Farm - invisible launcher
' Launched by the ProxyFarm scheduled task at boot / logon.
' Runs start-all.ps1 with no visible cmd window.
' =================================================================
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\proxy-farm\start-all.ps1""", 0, False
