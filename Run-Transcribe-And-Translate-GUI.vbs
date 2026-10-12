Option Explicit

Dim shell
Dim fso
Dim scriptDir
Dim psScript
Dim command

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
psScript = fso.BuildPath(scriptDir, "Transcribe-And-Translate.ps1")

shell.CurrentDirectory = scriptDir
command = "powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File " & Chr(34) & psScript & Chr(34)

shell.Run command, 0, False
