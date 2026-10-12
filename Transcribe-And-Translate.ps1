param(
    [Parameter(Position = 0)]
    [string]$InputPath = "",
    [string]$YouTubeUrl = "",
    [ValidateSet("Maximum", "2160p", "1440p", "1080p", "720p", "480p", "360p")]
    [string]$YouTubeQuality = "Maximum",
    [ValidateSet("", "edge", "chrome", "firefox", "brave", "vivaldi", "opera")]
    [string]$YouTubeCookiesFromBrowser = "",
    [string]$YouTubeCookiesFile = "",

    [string]$FasterWhisperPath = "faster-whisper-xxl.exe",
    [string]$YtDlpPath = "yt-dlp.exe",
    [string]$OutputDir = "",

    [ValidateSet("FasterWhisper", "MOSS", "ElevenLabs", "VNAIGemini")]
    [string]$TranscriptionEngine = "ElevenLabs",
    [ValidateSet("gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash")]
    [string]$VnaiGeminiModel = "gemini-3.8-flash",
    [string]$WhisperModel = "",
    [string]$MossModel = "OpenMOSS-Team/MOSS-Transcribe-Diarize",
    [string]$MossPythonPath = "",
    [ValidateSet("auto", "cpu", "cuda")]
    [string]$MossDevice = "auto",
    [ValidateRange(0, 65536)]
    [int]$MossMaxNewTokens = 0,
    [string]$ElevenLabsModel = "scribe_v2",
    [ValidateRange(0, 32)]
    [int]$ElevenLabsNumSpeakers = 0,
    [bool]$ShowSpeakerLabels = $false,
    [string]$Device = "cpu",
    [string]$ComputeType = "int8",
    [string]$SourceLanguage = "English",
    [ValidateRange(0, 32)]
    [int]$AudioTrack = 0,
    [string]$OutputFormat = "srt",
    [bool]$StandardSubtitles = $false,
    [double]$SentenceMaxGapSeconds = 0.8,
    [int]$MaxLineWidth = 58,
    [int]$MaxLineCount = 2,
    [int]$MaxCommaCent = 70,
    [double]$MinCueDurationSeconds = 0.8,
    [double]$MaxCueDurationSeconds = 8.0,
    [ValidateRange(10.0, 60.0)]
    [double]$MaxReadingCharsPerSecond = 20.0,
    [int]$VadSpeechPadMs = 150,
    [int]$VadMinSilenceDurationMs = 500,
    [bool]$PrintProgress = $true,

    [string]$TargetLanguage = "Greek",
    [ValidateSet("OpenAI", "VNAI Pro", "VNAI Pro Claude", "VNAI Pro Gemini", "AI Prime Tech", "Gemini", "ElevenLabs Dubbing", "Local NLLB")]
    [string]$TranslationProvider = "OpenAI",
    [bool]$PromptTranslationProvider = $true,
    [Alias("ClaudeModel", "TranslationModel")]
    [string]$OpenAIModel = "gpt-5.4-mini",
    [bool]$PromptTranslationModel = $true,
    [bool]$PromptTranslationApiKey = $false,
    [string]$TranslationBaseUrl = "",
    [int]$MaxChunkChars = 4000,
    [ValidateRange(1, 8)]
    [int]$MaxParallelTranslations = 3,
    [ValidateSet("Prompt", "None", "TwoLineText", "TwoLineTextAndTiming", "SentenceFlow")]
    [string]$SrtPostProcessingMode = "None",
    [bool]$EnableTranslationQaPass = $false,
    [bool]$EnableAutoGenderInference = $false,
    [bool]$EnableVoiceGenderDetection = $false,
    [string]$SubtitleContextHints = "",

    [switch]$EnableEmailNotification,
    [string]$EmailTo = "",
    [string]$EmailFrom = "",
    [string]$SmtpServer = "",
    [int]$SmtpPort = 587,
    [string]$SmtpUsername = "",
    [string]$SmtpPassword = "",
    [bool]$SmtpUseSsl = $true,

    [switch]$SkipTranscription,
    [switch]$SkipTranslation,
    [switch]$DownloadYouTubeOnly,
    [switch]$Headless
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
. (Join-Path $script:ScriptRoot 'tools\audio_tracks.ps1')
$script:ConfigPath = Join-Path $script:ScriptRoot ".faster-whisper-config.json"
$script:ConsoleCloseHandlerEnabled = $false
$script:ConsoleCloseHandler = $null
$script:ConsoleCloseButtonDisabled = $false
$script:RunLogForm = $null
$script:RunLogTextBox = $null
$script:RunLogNotifyIcon = $null

function Enable-GuiWindowActivation {
    if ("GuiWindowActivation.NativeMethods" -as [type]) {
        return
    }

    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace GuiWindowActivation {
    public static class NativeMethods {
        [DllImport("user32.dll")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);
    }
}
"@
}

function Test-ControlAlive {
    param($Control)

    if ($null -eq $Control) {
        return $false
    }

    try {
        $isDisposedProperty = $Control.PSObject.Properties["IsDisposed"]
        if ($isDisposedProperty -and [bool]$isDisposedProperty.Value) {
            return $false
        }
    }
    catch {
        return $false
    }

    return $true
}

function Close-RunLogNotifyIcon {
    if (Test-ControlAlive -Control $script:RunLogNotifyIcon) {
        try {
            $script:RunLogNotifyIcon.Visible = $false
            $script:RunLogNotifyIcon.Dispose()
        }
        catch {
        }
    }
    $script:RunLogNotifyIcon = $null
}

function Show-GuiWindow {
    param([System.Windows.Forms.Form]$Form)

    if (-not (Test-ControlAlive -Control $Form)) {
        return
    }

    Enable-GuiWindowActivation
    [void][GuiWindowActivation.NativeMethods]::ShowWindow($Form.Handle, 5)
    $Form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $Form.ShowInTaskbar = $true
    $Form.Activate()
    $Form.BringToFront()
    [void][GuiWindowActivation.NativeMethods]::SetForegroundWindow($Form.Handle)
    [System.Windows.Forms.Application]::DoEvents()
}

function Restore-RunLogWindow {
    if (-not (Test-ControlAlive -Control $script:RunLogForm)) {
        return
    }

    Show-GuiWindow -Form $script:RunLogForm
}

function Initialize-RunLogWindow {
    if ($Headless) {
        return
    }

    if (Test-ControlAlive -Control $script:RunLogForm) {
        Restore-RunLogWindow
        return
    }

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Run log"
    $form.StartPosition = "CenterScreen"
    $form.Size = New-Object System.Drawing.Size(920, 620)
    $form.MinimumSize = New-Object System.Drawing.Size(720, 420)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $form.MaximizeBox = $true
    $form.MinimizeBox = $true
    $form.ShowInTaskbar = $true

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Multiline = $true
    $textBox.ReadOnly = $true
    $textBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $textBox.WordWrap = $false
    $textBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $textBox.Font = New-Object System.Drawing.Font("Consolas", 10)
    $form.Controls.Add($textBox)

    $showMenuItem = New-Object System.Windows.Forms.MenuItem
    $showMenuItem.Text = "Show Run log"
    $showMenuItem.Add_Click({
        Restore-RunLogWindow
    })

    $closeMenuItem = New-Object System.Windows.Forms.MenuItem
    $closeMenuItem.Text = "Close Run log"
    $closeMenuItem.Add_Click({
        if (Test-ControlAlive -Control $script:RunLogForm) {
            $script:RunLogForm.Close()
        }
    })

    $trayMenu = New-Object System.Windows.Forms.ContextMenu
    [void]$trayMenu.MenuItems.Add($showMenuItem)
    [void]$trayMenu.MenuItems.Add($closeMenuItem)

    Close-RunLogNotifyIcon
    $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $notifyIcon.Text = "Transcribe and translate - Run log"
    $notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
    $notifyIcon.ContextMenu = $trayMenu
    $notifyIcon.Visible = $true
    $notifyIcon.Add_DoubleClick({
        Restore-RunLogWindow
    })

    $form.Add_Resize({
        if (Test-ControlAlive -Control $script:RunLogForm) {
            $script:RunLogForm.ShowInTaskbar = $true
        }
    })

    $form.Add_FormClosed({
        Close-RunLogNotifyIcon
    })

    $script:RunLogForm = $form
    $script:RunLogTextBox = $textBox
    $script:RunLogNotifyIcon = $notifyIcon
    $form.Show()
    Show-GuiWindow -Form $form
}

function Write-RunLog {
    param([AllowNull()][object]$Message = "")

    $text = if ($null -eq $Message) { "" } else { [string]$Message }
    Microsoft.PowerShell.Utility\Write-Host $text

    if ((Test-ControlAlive -Control $script:RunLogForm) -and (Test-ControlAlive -Control $script:RunLogTextBox)) {
        $append = [System.Action[string]]{
            param([string]$line)
            if (Test-ControlAlive -Control $script:RunLogTextBox) {
                $script:RunLogTextBox.AppendText($line + [Environment]::NewLine)
                $script:RunLogTextBox.SelectionStart = $script:RunLogTextBox.TextLength
                $script:RunLogTextBox.ScrollToCaret()
            }
        }

        if ($script:RunLogTextBox.InvokeRequired) {
            [void]$script:RunLogTextBox.BeginInvoke($append, $text)
        }
        else {
            $append.Invoke($text)
            [System.Windows.Forms.Application]::DoEvents()
        }
    }
}

function Write-RunWarning {
    param([AllowNull()][object]$Message = "")

    $text = if ($null -eq $Message) { "" } else { [string]$Message }
    Microsoft.PowerShell.Utility\Write-Warning $text

    if ((Test-ControlAlive -Control $script:RunLogForm) -and (Test-ControlAlive -Control $script:RunLogTextBox)) {
        Write-RunLog ("WARNING: " + $text)
    }
}

function Complete-RunLogWindow {
    if (Test-ControlAlive -Control $script:RunLogForm) {
        $script:RunLogForm.Tag = $true
        $script:RunLogForm.Text = "Run log - finished"
        [System.Windows.Forms.Application]::DoEvents()
    }
}


function Wait-RunLogWindow {
    if ($Headless) {
        return
    }

    Complete-RunLogWindow

    if (-not (Test-ControlAlive -Control $script:RunLogForm)) {
        return
    }

    Write-RunLog ""
    Write-RunLog "Run finished. You can close this log window when you are done."
    while (Test-ControlAlive -Control $script:RunLogForm) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 100
    }
}

function Join-ProcessArguments {
    param([string[]]$Arguments)

    $quoted = foreach ($argument in $Arguments) {
        $value = if ($null -eq $argument) { "" } else { [string]$argument }
        if ($value -notmatch '[\s"]' -and $value.Length -gt 0) {
            $value
        }
        else {
            '"' + ($value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
        }
    }

    return ($quoted -join " ")
}

function Read-AppendedLogFile {
    param(
        [string]$Path,
        [ref]$Offset,
        [string]$Prefix = ""
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $stream = $null
    $reader = $null
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($Offset.Value -gt $stream.Length) {
            $Offset.Value = 0
        }
        [void]$stream.Seek([int64]$Offset.Value, [System.IO.SeekOrigin]::Begin)
        $reader = New-Object System.IO.StreamReader($stream)
        $text = $reader.ReadToEnd()
        $Offset.Value = $stream.Position
    }
    finally {
        if ($reader) {
            $reader.Dispose()
        }
        elseif ($stream) {
            $stream.Dispose()
        }
    }

    if ([string]::IsNullOrEmpty($text)) {
        return
    }

    $text = $text -replace "`r`n", "`n" -replace "`r", "`n"
    foreach ($line in ($text -split "`n")) {
        if ($line.Length -gt 0) {
            Write-RunLog ($Prefix + $line)
        }
    }
}

function Invoke-LoggedProcess {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [System.Collections.Generic.List[string]]$OutputLines = $null,
        [switch]$Utf8Output
    )

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = $FilePath
    $startInfo.Arguments = Join-ProcessArguments -Arguments $Arguments
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.CreateNoWindow = $true
    if ($Utf8Output) {
        $utf8Encoding = New-Object System.Text.UTF8Encoding($false)
        $startInfo.StandardOutputEncoding = $utf8Encoding
        $startInfo.StandardErrorEncoding = $utf8Encoding
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $startInfo

    try {
        [void]$process.Start()
        $stdoutDone = $false
        $stderrDone = $false
        $stdoutTask = $process.StandardOutput.ReadLineAsync()
        $stderrTask = $process.StandardError.ReadLineAsync()

        while (-not $process.HasExited -or -not $stdoutDone -or -not $stderrDone) {
            if (-not $stdoutDone -and $stdoutTask.IsCompleted) {
                $line = $stdoutTask.Result
                if ($null -eq $line) {
                    $stdoutDone = $true
                }
                else {
                    Write-RunLog $line
                    if ($OutputLines) {
                        $OutputLines.Add($line)
                    }
                    $stdoutTask = $process.StandardOutput.ReadLineAsync()
                }
            }

            if (-not $stderrDone -and $stderrTask.IsCompleted) {
                $line = $stderrTask.Result
                if ($null -eq $line) {
                    $stderrDone = $true
                }
                else {
                    Write-RunLog ("ERROR: " + $line)
                    $stderrTask = $process.StandardError.ReadLineAsync()
                }
            }

            if (Test-ControlAlive -Control $script:RunLogForm) {
                [System.Windows.Forms.Application]::DoEvents()
            }
            Start-Sleep -Milliseconds 100
            $process.Refresh()
        }

        $process.WaitForExit()
        if (Test-ControlAlive -Control $script:RunLogForm) {
            [System.Windows.Forms.Application]::DoEvents()
        }
        return [int]$process.ExitCode
    }
    finally {
        $process.Dispose()
    }
}

function Enable-ConsoleCloseConfirmation {
    if ($script:ConsoleCloseHandlerEnabled) {
        return
    }

    Add-Type -AssemblyName System.Windows.Forms

    if (-not ("ConsoleCloseConfirmation.NativeMethods" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace ConsoleCloseConfirmation {
    public delegate bool ConsoleCtrlHandler(uint ctrlType);

    public static class NativeMethods {
        [DllImport("kernel32.dll")]
        public static extern bool SetConsoleCtrlHandler(ConsoleCtrlHandler handler, bool add);
    }
}
"@
    }

    $script:ConsoleCloseHandler = [ConsoleCloseConfirmation.ConsoleCtrlHandler]{
        param([uint32]$ctrlType)

        if ($ctrlType -eq 2) {
            $message = [string]::Concat(
                [char]0x0395, [char]0x03AF, [char]0x03C3, [char]0x03C4, [char]0x03B5, " ",
                [char]0x03C3, [char]0x03AF, [char]0x03B3, [char]0x03BF, [char]0x03C5, [char]0x03C1, [char]0x03BF, [char]0x03C2, "?"
            )
            $title = [string]::Concat(
                [char]0x039A, [char]0x03BB, [char]0x03B5, [char]0x03AF, [char]0x03C3, [char]0x03B9, [char]0x03BC, [char]0x03BF,
                " PowerShell"
            )
            $choice = [System.Windows.Forms.MessageBox]::Show(
                $message,
                $title,
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Question,
                [System.Windows.Forms.MessageBoxDefaultButton]::Button2
            )

            return ($choice -ne [System.Windows.Forms.DialogResult]::Yes)
        }

        return $false
    }

    [void][ConsoleCloseConfirmation.NativeMethods]::SetConsoleCtrlHandler($script:ConsoleCloseHandler, $true)
    $script:ConsoleCloseHandlerEnabled = $true
}

Enable-ConsoleCloseConfirmation

function Disable-ConsoleCloseButton {
    if ($script:ConsoleCloseButtonDisabled) {
        return
    }

    if (-not ("ConsoleWindow.NativeMethods" -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace ConsoleWindow {
    public static class NativeMethods {
        public const int MF_BYCOMMAND = 0x00000000;
        public const int MF_GRAYED = 0x00000001;
        public const int SC_CLOSE = 0xF060;

        [DllImport("kernel32.dll")]
        public static extern IntPtr GetConsoleWindow();

        [DllImport("user32.dll")]
        public static extern IntPtr GetSystemMenu(IntPtr hWnd, bool bRevert);

        [DllImport("user32.dll")]
        public static extern bool EnableMenuItem(IntPtr hMenu, int uIDEnableItem, int uEnable);

        [DllImport("user32.dll")]
        public static extern bool DeleteMenu(IntPtr hMenu, int uPosition, int uFlags);

        [DllImport("user32.dll")]
        public static extern bool DrawMenuBar(IntPtr hWnd);
    }
}
"@
    }

    $windowHandle = [ConsoleWindow.NativeMethods]::GetConsoleWindow()
    if ($windowHandle -eq [IntPtr]::Zero) {
        return
    }

    $menuHandle = [ConsoleWindow.NativeMethods]::GetSystemMenu($windowHandle, $false)
    if ($menuHandle -eq [IntPtr]::Zero) {
        return
    }

    [void][ConsoleWindow.NativeMethods]::EnableMenuItem(
        $menuHandle,
        [ConsoleWindow.NativeMethods]::SC_CLOSE,
        ([ConsoleWindow.NativeMethods]::MF_BYCOMMAND -bor [ConsoleWindow.NativeMethods]::MF_GRAYED)
    )
    [void][ConsoleWindow.NativeMethods]::DeleteMenu(
        $menuHandle,
        [ConsoleWindow.NativeMethods]::SC_CLOSE,
        [ConsoleWindow.NativeMethods]::MF_BYCOMMAND
    )
    [void][ConsoleWindow.NativeMethods]::DrawMenuBar($windowHandle)
    $script:ConsoleCloseButtonDisabled = $true
}

Disable-ConsoleCloseButton

function Import-DotEnv {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    Get-Content -LiteralPath $Path | ForEach-Object {
        $line = [string]$_
        if ([string]::IsNullOrWhiteSpace($line)) {
            return
        }

        $trimmed = $line.Trim()
        if ($trimmed.StartsWith("#")) {
            return
        }

        if ($trimmed.StartsWith("export ")) {
            $trimmed = $trimmed.Substring(7).TrimStart()
        }

        $separatorIndex = $trimmed.IndexOf("=")
        if ($separatorIndex -le 0) {
            return
        }

        $name = $trimmed.Substring(0, $separatorIndex).Trim()
        $value = $trimmed.Substring($separatorIndex + 1).Trim()
        if ($name -notmatch "^[A-Za-z_][A-Za-z0-9_]*$") {
            return
        }

        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or
            ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        else {
            $commentIndex = $value.IndexOf(" #")
            if ($commentIndex -ge 0) {
                $value = $value.Substring(0, $commentIndex).TrimEnd()
            }
        }

        [System.Environment]::SetEnvironmentVariable($name, $value, "Process")
    }
}

Import-DotEnv -Path (Join-Path $script:ScriptRoot ".env")

function Select-MediaFile {
    Add-Type -AssemblyName System.Windows.Forms

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Select video or audio file"
    $dialog.Filter = "Media files|*.mp4;*.mkv;*.mov;*.avi;*.mp3;*.wav;*.m4a;*.flac|Video files|*.mp4;*.mkv;*.mov;*.avi|Audio files|*.mp3;*.wav;*.m4a;*.flac|All files|*.*"
    $dialog.Multiselect = $false
    $dialog.CheckFileExists = $true
    $dialog.CheckPathExists = $true
    $dialog.RestoreDirectory = $true

    $result = $dialog.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        throw "No media file was selected."
    }

    return $dialog.FileName
}

function Select-InputSource {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Select input source"
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ClientSize = New-Object System.Drawing.Size(420, 142)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Choose where the video or audio should come from:"
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(16, 18)
    $form.Controls.Add($label)

    $fileButton = New-Object System.Windows.Forms.Button
    $fileButton.Text = "Local file"
    $fileButton.Location = New-Object System.Drawing.Point(58, 70)
    $fileButton.Size = New-Object System.Drawing.Size(130, 32)
    $fileButton.Add_Click({
        $form.Tag = "file"
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $form.Controls.Add($fileButton)

    $youtubeButton = New-Object System.Windows.Forms.Button
    $youtubeButton.Text = "YouTube link"
    $youtubeButton.Location = New-Object System.Drawing.Point(228, 70)
    $youtubeButton.Size = New-Object System.Drawing.Size(130, 32)
    $youtubeButton.Add_Click({
        $form.Tag = "youtube"
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })
    $form.Controls.Add($youtubeButton)

    $form.AcceptButton = $fileButton

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK -or [string]::IsNullOrWhiteSpace([string]$form.Tag)) {
        throw "No input source was selected."
    }

    return [string]$form.Tag
}

function Read-YouTubeUrl {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "YouTube URL"
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ClientSize = New-Object System.Drawing.Size(560, 150)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Paste the YouTube video URL:"
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(16, 18)
    $form.Controls.Add($label)

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Location = New-Object System.Drawing.Point(18, 48)
    $textBox.Size = New-Object System.Drawing.Size(522, 24)
    $form.Controls.Add($textBox)

    $pasteButton = New-Object System.Windows.Forms.Button
    $pasteButton.Text = "Paste"
    $pasteButton.Location = New-Object System.Drawing.Point(297, 104)
    $pasteButton.Add_Click({
        if ([System.Windows.Forms.Clipboard]::ContainsText()) {
            $textBox.Text = [System.Windows.Forms.Clipboard]::GetText().Trim()
            $textBox.Select($textBox.Text.Length, 0)
            $textBox.Focus()
        }
    })
    $form.Controls.Add($pasteButton)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "OK"
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $okButton.Location = New-Object System.Drawing.Point(378, 104)
    $form.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelButton.Location = New-Object System.Drawing.Point(459, 104)
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        throw "No YouTube URL was entered."
    }

    $url = $textBox.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($url)) {
        throw "No YouTube URL was entered."
    }

    return $url
}

function Select-YouTubeQuality {
    param([string]$DefaultQuality = "Maximum")

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $qualities = @("Maximum", "2160p", "1440p", "1080p", "720p", "480p", "360p")

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "YouTube quality"
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.ClientSize = New-Object System.Drawing.Size(420, 150)
    $form.Add_Shown({
        Show-GuiWindow -Form $form
        $combo.Focus()
    })

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Choose the maximum download quality:"
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(16, 18)
    $form.Controls.Add($label)

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $combo.Location = New-Object System.Drawing.Point(18, 48)
    $combo.Size = New-Object System.Drawing.Size(382, 24)
    [void]$combo.Items.AddRange([object[]]$qualities)
    $combo.Text = if ($qualities -contains $DefaultQuality) { $DefaultQuality } else { "Maximum" }
    $form.Controls.Add($combo)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = "Specific choices download the best available quality up to that height."
    $hint.AutoSize = $true
    $hint.Location = New-Object System.Drawing.Point(16, 78)
    $form.Controls.Add($hint)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "OK"
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $okButton.Location = New-Object System.Drawing.Point(244, 110)
    $form.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelButton.Location = New-Object System.Drawing.Point(325, 110)
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        throw "No YouTube quality was selected."
    }

    return [string]$combo.Text
}

function Select-SrtPostProcessingMode {
    param([string]$DefaultMode = "TwoLineTextAndTiming")

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $options = @(
        [pscustomobject]@{
            Label = "None - keep translated SRT exactly as returned"
            Value = "None"
        },
        [pscustomobject]@{
            Label = "Two-line text only - max 2 subtitle lines"
            Value = "TwoLineText"
        },
        [pscustomobject]@{
            Label = "Two-line text + timing cleanup - current behavior"
            Value = "TwoLineTextAndTiming"
        },
        [pscustomobject]@{
            Label = "Sentence flow - experimental orphan-word repair"
            Value = "SentenceFlow"
        }
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "SRT post-processing"
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ClientSize = New-Object System.Drawing.Size(520, 170)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Choose SRT post-processing for this run:"
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(16, 18)
    $form.Controls.Add($label)

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $combo.Location = New-Object System.Drawing.Point(18, 48)
    $combo.Size = New-Object System.Drawing.Size(482, 24)
    [void]$combo.Items.AddRange([object[]]($options.Label))
    $defaultOption = $options | Where-Object { $_.Value -eq $DefaultMode } | Select-Object -First 1
    $combo.Text = if ($defaultOption) { $defaultOption.Label } else { $options[-1].Label }
    $form.Controls.Add($combo)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = "Two-line text + timing cleanup is recommended. Sentence flow is experimental."
    $hint.AutoSize = $true
    $hint.Location = New-Object System.Drawing.Point(16, 82)
    $form.Controls.Add($hint)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "OK"
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $okButton.Location = New-Object System.Drawing.Point(338, 126)
    $form.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelButton.Location = New-Object System.Drawing.Point(419, 126)
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        throw "No SRT post-processing mode was selected."
    }

    $selected = $options | Where-Object { $_.Label -eq $combo.Text } | Select-Object -First 1
    if (-not $selected) {
        throw "No SRT post-processing mode was selected."
    }

    return $selected.Value
}

function Select-FasterWhisperExecutable {
    Add-Type -AssemblyName System.Windows.Forms

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Select faster-whisper-xxl.exe"
    $dialog.Filter = "Faster Whisper XXL|faster-whisper-xxl*.exe|Executable files|*.exe|All files|*.*"
    $dialog.Multiselect = $false
    $dialog.CheckFileExists = $true
    $dialog.CheckPathExists = $true
    $dialog.RestoreDirectory = $true

    $result = $dialog.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        throw "No faster-whisper-xxl.exe was selected."
    }

    return $dialog.FileName
}

function Select-YtDlpExecutable {
    Add-Type -AssemblyName System.Windows.Forms

    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Select yt-dlp.exe"
    $dialog.Filter = "yt-dlp|yt-dlp*.exe|Executable files|*.exe|All files|*.*"
    $dialog.Multiselect = $false
    $dialog.CheckFileExists = $true
    $dialog.CheckPathExists = $true
    $dialog.RestoreDirectory = $true

    $result = $dialog.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        throw "No yt-dlp.exe was selected."
    }

    return $dialog.FileName
}

function Select-WhisperModel {
    param([string]$DefaultModel = "large-v3")

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $models = @(
        "tiny",
        "tiny.en",
        "base",
        "base.en",
        "small",
        "small.en",
        "medium",
        "medium.en",
        "large-v1",
        "large-v2",
        "large-v3",
        "large-v3-turbo",
        "turbo"
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Select transcription model"
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.ClientSize = New-Object System.Drawing.Size(420, 150)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Choose the Faster Whisper model for transcription:"
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(16, 18)
    $form.Controls.Add($label)

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
    $combo.Location = New-Object System.Drawing.Point(18, 48)
    $combo.Size = New-Object System.Drawing.Size(382, 24)
    [void]$combo.Items.AddRange([object[]]$models)
    $combo.Text = $DefaultModel
    $form.Controls.Add($combo)
    $form.Add_Shown({
        Show-GuiWindow -Form $form
        $combo.Focus()
    })

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = "You can type a custom model name too."
    $hint.AutoSize = $true
    $hint.Location = New-Object System.Drawing.Point(16, 78)
    $form.Controls.Add($hint)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "OK"
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $okButton.Location = New-Object System.Drawing.Point(244, 110)
    $form.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelButton.Location = New-Object System.Drawing.Point(325, 110)
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        throw "No transcription model was selected."
    }

    $selectedModel = $combo.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($selectedModel)) {
        throw "No transcription model was selected."
    }

    return $selectedModel
}

function Select-TranslationProvider {
    param([string]$DefaultProvider = "AI Prime Tech")

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $providers = @(
        "AI Prime Tech",
        "VNAI Pro",
        "VNAI Pro Claude",
        "VNAI Pro Gemini",
        "Gemini",
        "OpenAI",
        "ElevenLabs Dubbing",
        "Local NLLB"
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Select translation API"
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ClientSize = New-Object System.Drawing.Size(420, 150)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Choose the API provider for translation:"
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(16, 18)
    $form.Controls.Add($label)

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $combo.Location = New-Object System.Drawing.Point(18, 48)
    $combo.Size = New-Object System.Drawing.Size(382, 24)
    [void]$combo.Items.AddRange([object[]]$providers)
    $combo.Text = $DefaultProvider
    $form.Controls.Add($combo)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = "Model and API key will be requested next."
    $hint.AutoSize = $true
    $hint.Location = New-Object System.Drawing.Point(16, 78)
    $form.Controls.Add($hint)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "OK"
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $okButton.Location = New-Object System.Drawing.Point(244, 110)
    $form.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelButton.Location = New-Object System.Drawing.Point(325, 110)
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        throw "No translation API provider was selected."
    }

    $selectedProvider = $combo.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($selectedProvider)) {
        throw "No translation API provider was selected."
    }

    return $selectedProvider
}

function Get-DefaultTranslationModel {
    param([string]$Provider)

    if ($Provider -eq "Local NLLB") { return "nllb-600m-int8" }

    if ($Provider -eq "ElevenLabs Dubbing") {
        return "automatic"
    }

    if ($Provider -eq "OpenAI") {
        return "gpt-5.4-mini"
    }

    if ($Provider -eq "VNAI Pro") {
        return "gpt-5.6-sol"
    }

    if ($Provider -eq "VNAI Pro Claude") {
        return "claude-sonnet-4-6"
    }

    if ($Provider -eq "VNAI Pro Gemini") {
        return "gemini-3.8-flash"
    }

    if ($Provider -eq "Gemini") {
        return "gemini-3.1-flash-lite"
    }

    return "claude-sonnet-4-6"
}

function Get-DefaultTranslationBaseUrl {
    param([string]$Provider)

    if ($Provider -eq "Local NLLB") { return "local" }

    if ($Provider -eq "ElevenLabs Dubbing") {
        return "https://api.elevenlabs.io/v1"
    }

    if ($Provider -eq "OpenAI") {
        return "https://api.openai.com/v1"
    }

    if ($Provider -in @("VNAI Pro", "VNAI Pro Claude", "VNAI Pro Gemini")) {
        return "https://apikey.vnaipro.app/v1"
    }

    if ($Provider -eq "Gemini") {
        return "https://generativelanguage.googleapis.com/v1beta"
    }

    return "https://aiprimetech.io/v1"
}

function Get-TranslationModelsForProvider {
    param([string]$Provider)

    if ($Provider -eq "Local NLLB") { return @("nllb-600m-int8") }

    if ($Provider -eq "ElevenLabs Dubbing") {
        return @("automatic")
    }

    if ($Provider -eq "OpenAI") {
        return @(
            "gpt-5.4-mini",
            "gpt-5.4",
            "gpt-5.4-nano",
            "gpt-4o",
            "gpt-4o-mini"
        )
    }

    if ($Provider -eq "VNAI Pro") {
        return @(
            "gpt-5.6-sol",
            "gpt-5.6-terra"
        )
    }

    if ($Provider -eq "VNAI Pro Claude") {
        return @(
            "claude-sonnet-4-6",
            "claude-sonnet-5",
            "claude-fable-5-1",
            "claude-fable-5",
            "claude-opus-4-6",
            "claude-opus-4-7",
            "claude-opus-4-8",
            "claude-opus-5",
            "claude-opus-5-5"
        )
    }

    if ($Provider -eq "VNAI Pro Gemini") {
        return @(
            "gemini-3.8-flash",
            "gemini-3.7-flash",
            "gemini-3.6-flash"
        )
    }

    if ($Provider -eq "Gemini") {
        return @(
            "gemini-3.1-flash-lite",
            "gemini-2.5-flash",
            "gemini-2.5-pro",
            "gemini-2.5-flash-lite"
        )
    }

    return @(
        "claude-sonnet-4-6",
        "claude-opus-4-7",
        "claude-opus-4-6",
        "claude-haiku-4-5"
    )
}

function Get-TranslationModelFallbacks {
    param(
        [string]$Provider,
        [string]$SelectedModel
    )

    $models = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($SelectedModel)) {
        $models.Add($SelectedModel)
    }

    if ($Provider -eq "Gemini") {
        foreach ($model in @("gemini-3.1-flash-lite", "gemini-2.5-flash", "gemini-2.5-pro", "gemini-2.5-flash-lite")) {
            if (-not $models.Contains($model)) {
                $models.Add($model)
            }
        }
    }

    return @($models)
}

function Select-OpenAIModel {
    param(
        [string]$DefaultModel = "claude-sonnet-4-6",
        [string]$Provider = "AI Prime Tech"
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $models = Get-TranslationModelsForProvider -Provider $Provider

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Select translation model"
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.ClientSize = New-Object System.Drawing.Size(420, 150)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Choose the $Provider model for translation:"
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(16, 18)
    $form.Controls.Add($label)

    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
    $combo.Location = New-Object System.Drawing.Point(18, 48)
    $combo.Size = New-Object System.Drawing.Size(382, 24)
    [void]$combo.Items.AddRange([object[]]$models)
    $combo.Text = $DefaultModel
    $form.Controls.Add($combo)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = "You can type a custom model name too."
    $hint.AutoSize = $true
    $hint.Location = New-Object System.Drawing.Point(16, 78)
    $form.Controls.Add($hint)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "OK"
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $okButton.Location = New-Object System.Drawing.Point(244, 110)
    $form.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelButton.Location = New-Object System.Drawing.Point(325, 110)
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK) {
        throw "No translation model was selected."
    }

    $selectedModel = $combo.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($selectedModel)) {
        throw "No translation model was selected."
    }

    return $selectedModel
}

function Show-RunOptionsDialog {
    param(
        [string]$DefaultYouTubeQuality = "Maximum",
        [string]$DefaultYouTubeCookiesFromBrowser = "",
        [string]$DefaultYouTubeCookiesFile = "",
        [string]$DefaultTranscriptionEngine = "ElevenLabs",
        [string]$DefaultVnaiGeminiModel = "gemini-3.8-flash",
        [int]$DefaultAudioTrack = 0,
        [string]$DefaultWhisperModel = "medium.en",
        [string]$DefaultMossModel = "OpenMOSS-Team/MOSS-Transcribe-Diarize",
        [bool]$DefaultShowSpeakerLabels = $false,
        [string]$DefaultProvider = "OpenAI",
        [string]$DefaultTranslationModel = "gpt-5.4-mini",
        [string]$DefaultTargetLanguage = "Greek",
        [string]$DefaultPostProcessingMode = "None",
        [bool]$DefaultTranslationQaPass = $false,
        [bool]$DefaultAutoGenderInference = $false,
        [bool]$DefaultVoiceGenderDetection = $false,
        [string]$DefaultSubtitleContextHints = ""
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $whisperModels = @(
        "tiny",
        "tiny.en",
        "base",
        "base.en",
        "small",
        "small.en",
        "medium",
        "medium.en",
        "large-v1",
        "large-v2",
        "large-v3",
        "large-v3-turbo",
        "turbo"
    )
    $transcriptionEngines = @(
        [pscustomobject]@{ Label = "Faster Whisper XXL"; Value = "FasterWhisper" },
        [pscustomobject]@{ Label = "MOSS + speaker diarization"; Value = "MOSS" },
        [pscustomobject]@{ Label = "ElevenLabs Scribe v2 (cloud)"; Value = "ElevenLabs" },
        [pscustomobject]@{ Label = "VNAI Pro Gemini (cloud)"; Value = "VNAIGemini" }
    )
    $providers = @("AI Prime Tech", "VNAI Pro", "VNAI Pro Claude", "VNAI Pro Gemini", "Gemini", "OpenAI", "ElevenLabs Dubbing", "Local NLLB")
    $qualities = @("Maximum", "2160p", "1440p", "1080p", "720p", "480p", "360p")
    $cookieBrowsers = @(
        [pscustomobject]@{ Label = "No cookies"; Value = "" },
        [pscustomobject]@{ Label = "Edge cookies"; Value = "edge" },
        [pscustomobject]@{ Label = "Chrome cookies"; Value = "chrome" },
        [pscustomobject]@{ Label = "Firefox cookies"; Value = "firefox" },
        [pscustomobject]@{ Label = "Brave cookies"; Value = "brave" },
        [pscustomobject]@{ Label = "Vivaldi cookies"; Value = "vivaldi" },
        [pscustomobject]@{ Label = "Opera cookies"; Value = "opera" }
    )
    $postProcessingOptions = @(
        [pscustomobject]@{ Label = "None - keep translated SRT exactly as returned"; Value = "None" },
        [pscustomobject]@{ Label = "Two-line text only - max 2 subtitle lines"; Value = "TwoLineText" },
        [pscustomobject]@{ Label = "Two-line text + timing cleanup - recommended"; Value = "TwoLineTextAndTiming" },
        [pscustomobject]@{ Label = "Sentence flow - experimental orphan-word repair"; Value = "SentenceFlow" }
    )

    if ([string]::IsNullOrWhiteSpace($DefaultTranslationModel)) {
        $DefaultTranslationModel = Get-DefaultTranslationModel -Provider $DefaultProvider
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "Transcribe and translate"
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.ClientSize = New-Object System.Drawing.Size(720, 680)

    $inputGroup = New-Object System.Windows.Forms.GroupBox
    $inputGroup.Text = "Input"
    $inputGroup.Location = New-Object System.Drawing.Point(14, 12)
    $inputGroup.Size = New-Object System.Drawing.Size(690, 150)
    $form.Controls.Add($inputGroup)

    $fileRadio = New-Object System.Windows.Forms.RadioButton
    $fileRadio.Text = "File"
    $fileRadio.Location = New-Object System.Drawing.Point(18, 26)
    $fileRadio.Size = New-Object System.Drawing.Size(70, 22)
    $fileRadio.Checked = $true
    $inputGroup.Controls.Add($fileRadio)

    $folderRadio = New-Object System.Windows.Forms.RadioButton
    $folderRadio.Text = "Folder"
    $folderRadio.Location = New-Object System.Drawing.Point(96, 26)
    $folderRadio.Size = New-Object System.Drawing.Size(80, 22)
    $inputGroup.Controls.Add($folderRadio)

    $youtubeRadio = New-Object System.Windows.Forms.RadioButton
    $youtubeRadio.Text = "YouTube"
    $youtubeRadio.Location = New-Object System.Drawing.Point(188, 26)
    $youtubeRadio.Size = New-Object System.Drawing.Size(90, 22)
    $inputGroup.Controls.Add($youtubeRadio)

    $cookiesLabel = New-Object System.Windows.Forms.Label
    $cookiesLabel.Text = "Cookies"
    $cookiesLabel.Location = New-Object System.Drawing.Point(306, 29)
    $cookiesLabel.Size = New-Object System.Drawing.Size(54, 18)
    $inputGroup.Controls.Add($cookiesLabel)

    $cookiesCombo = New-Object System.Windows.Forms.ComboBox
    $cookiesCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cookiesCombo.Location = New-Object System.Drawing.Point(366, 25)
    $cookiesCombo.Size = New-Object System.Drawing.Size(138, 24)
    [void]$cookiesCombo.Items.AddRange([object[]]($cookieBrowsers.Label))
    $defaultCookieOption = $cookieBrowsers | Where-Object { $_.Value -eq $DefaultYouTubeCookiesFromBrowser } | Select-Object -First 1
    $cookiesCombo.Text = if ($defaultCookieOption) { $defaultCookieOption.Label } else { "No cookies" }
    $cookiesCombo.Enabled = $false
    $inputGroup.Controls.Add($cookiesCombo)

    $pathBox = New-Object System.Windows.Forms.TextBox
    $pathBox.Location = New-Object System.Drawing.Point(18, 58)
    $pathBox.Size = New-Object System.Drawing.Size(560, 24)
    $inputGroup.Controls.Add($pathBox)

    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.Text = "Browse"
    $browseButton.Location = New-Object System.Drawing.Point(590, 56)
    $browseButton.Size = New-Object System.Drawing.Size(82, 28)
    $inputGroup.Controls.Add($browseButton)

    $urlBox = New-Object System.Windows.Forms.TextBox
    $urlBox.Location = New-Object System.Drawing.Point(18, 101)
    $urlBox.Size = New-Object System.Drawing.Size(332, 24)
    $urlBox.Enabled = $false
    $inputGroup.Controls.Add($urlBox)

    $pasteButton = New-Object System.Windows.Forms.Button
    $pasteButton.Text = "Paste"
    $pasteButton.Location = New-Object System.Drawing.Point(360, 99)
    $pasteButton.Size = New-Object System.Drawing.Size(70, 28)
    $pasteButton.Enabled = $false
    $inputGroup.Controls.Add($pasteButton)

    $cookiesFileBox = New-Object System.Windows.Forms.TextBox
    $cookiesFileBox.Location = New-Object System.Drawing.Point(440, 101)
    $cookiesFileBox.Size = New-Object System.Drawing.Size(132, 24)
    $cookiesFileBox.Text = $DefaultYouTubeCookiesFile
    $cookiesFileBox.Enabled = $false
    $inputGroup.Controls.Add($cookiesFileBox)

    $cookiesFileButton = New-Object System.Windows.Forms.Button
    $cookiesFileButton.Text = "Cookie file"
    $cookiesFileButton.Location = New-Object System.Drawing.Point(582, 99)
    $cookiesFileButton.Size = New-Object System.Drawing.Size(90, 28)
    $cookiesFileButton.Enabled = $false
    $inputGroup.Controls.Add($cookiesFileButton)

    $qualityCombo = New-Object System.Windows.Forms.ComboBox
    $qualityCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $qualityCombo.Location = New-Object System.Drawing.Point(582, 101)
    $qualityCombo.Size = New-Object System.Drawing.Size(90, 24)
    [void]$qualityCombo.Items.AddRange([object[]]$qualities)
    $qualityCombo.Text = if ($qualities -contains $DefaultYouTubeQuality) { $DefaultYouTubeQuality } else { "Maximum" }
    $qualityCombo.Enabled = $false
    $inputGroup.Controls.Add($qualityCombo)

    $transcriptionGroup = New-Object System.Windows.Forms.GroupBox
    $transcriptionGroup.Text = "Transcription"
    $transcriptionGroup.Location = New-Object System.Drawing.Point(14, 174)
    $transcriptionGroup.Size = New-Object System.Drawing.Size(334, 152)
    $form.Controls.Add($transcriptionGroup)

    $skipTranscription = New-Object System.Windows.Forms.CheckBox
    $skipTranscription.Text = "Skip transcription"
    $skipTranscription.Location = New-Object System.Drawing.Point(18, 24)
    $skipTranscription.Size = New-Object System.Drawing.Size(145, 22)
    $transcriptionGroup.Controls.Add($skipTranscription)

    $speakerLabelsCheck = New-Object System.Windows.Forms.CheckBox
    $speakerLabelsCheck.Text = "Show S01 in final"
    $speakerLabelsCheck.Location = New-Object System.Drawing.Point(168, 24)
    $speakerLabelsCheck.Size = New-Object System.Drawing.Size(145, 22)
    $speakerLabelsCheck.Checked = $DefaultShowSpeakerLabels
    $transcriptionGroup.Controls.Add($speakerLabelsCheck)

    $vnaiTranscriptionKeyButton = New-Object System.Windows.Forms.Button
    $vnaiTranscriptionKeyButton.Text = "VNAI Gemini API key"
    $vnaiTranscriptionKeyButton.Location = New-Object System.Drawing.Point(168, 22)
    $vnaiTranscriptionKeyButton.Size = New-Object System.Drawing.Size(145, 26)
    $vnaiTranscriptionKeyButton.Visible = $false
    $transcriptionGroup.Controls.Add($vnaiTranscriptionKeyButton)
    $vnaiTranscriptionKeyButton.Add_Click({
        try { $null = Read-AndSaveTranslationApiKey -Provider "VNAI Pro Gemini" }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, "VNAI Gemini API key")
        }
    })

    $engineLabel = New-Object System.Windows.Forms.Label
    $engineLabel.Text = "Engine"
    $engineLabel.Location = New-Object System.Drawing.Point(18, 56)
    $engineLabel.Size = New-Object System.Drawing.Size(112, 18)
    $transcriptionGroup.Controls.Add($engineLabel)

    $engineCombo = New-Object System.Windows.Forms.ComboBox
    $engineCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $engineCombo.Location = New-Object System.Drawing.Point(140, 52)
    $engineCombo.Size = New-Object System.Drawing.Size(170, 24)
    [void]$engineCombo.Items.AddRange([object[]]($transcriptionEngines.Label))
    $defaultEngineOption = $transcriptionEngines | Where-Object { $_.Value -eq $DefaultTranscriptionEngine } | Select-Object -First 1
    $engineCombo.Text = if ($defaultEngineOption) { $defaultEngineOption.Label } else { "Faster Whisper XXL" }
    $transcriptionGroup.Controls.Add($engineCombo)

    $whisperLabel = New-Object System.Windows.Forms.Label
    $whisperLabel.Text = "Model"
    $whisperLabel.Location = New-Object System.Drawing.Point(18, 88)
    $whisperLabel.Size = New-Object System.Drawing.Size(120, 18)
    $transcriptionGroup.Controls.Add($whisperLabel)

    $whisperCombo = New-Object System.Windows.Forms.ComboBox
    $whisperCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
    $whisperCombo.Location = New-Object System.Drawing.Point(140, 84)
    $whisperCombo.Size = New-Object System.Drawing.Size(170, 24)
    [void]$whisperCombo.Items.AddRange([object[]]$whisperModels)
    $whisperCombo.Text = if ($DefaultTranscriptionEngine -eq "MOSS") {
        $DefaultMossModel
    }
    elseif ($DefaultTranscriptionEngine -eq "ElevenLabs") {
        "scribe_v2"
    }
    elseif ($DefaultTranscriptionEngine -eq "VNAIGemini") {
        $whisperCombo.Items.Clear()
        [void]$whisperCombo.Items.AddRange([object[]](Get-TranslationModelsForProvider -Provider "VNAI Pro Gemini"))
        $DefaultVnaiGeminiModel
    }
    else {
        $DefaultWhisperModel
    }
    $transcriptionGroup.Controls.Add($whisperCombo)

    $audioTrackLabel = New-Object System.Windows.Forms.Label
    $audioTrackLabel.Text = "Audio track"
    $audioTrackLabel.Location = New-Object System.Drawing.Point(18, 120)
    $audioTrackLabel.Size = New-Object System.Drawing.Size(112, 18)
    $transcriptionGroup.Controls.Add($audioTrackLabel)

    $audioTrackCombo = New-Object System.Windows.Forms.ComboBox
    $audioTrackCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $audioTrackLabel.Size = New-Object System.Drawing.Size(78, 18)
    $audioTrackCombo.Location = New-Object System.Drawing.Point(96, 116)
    $audioTrackCombo.Size = New-Object System.Drawing.Size(222, 24)
    $audioTrackCombo.DropDownWidth = 660
    Set-AudioTrackChoices -Combo $audioTrackCombo -Tracks @() -PreferredTrack $DefaultAudioTrack -FallbackReason 'select a file'
    $audioTrackTooltip = New-Object System.Windows.Forms.ToolTip
    $audioTrackCombo.Add_SelectedIndexChanged({ $audioTrackTooltip.SetToolTip($audioTrackCombo, $audioTrackCombo.Text) })
    $transcriptionGroup.Controls.Add($audioTrackCombo)

    $translationGroup = New-Object System.Windows.Forms.GroupBox
    $translationGroup.Text = "Translation"
    $translationGroup.Location = New-Object System.Drawing.Point(370, 174)
    $translationGroup.Size = New-Object System.Drawing.Size(334, 252)
    $form.Controls.Add($translationGroup)

    $skipTranslation = New-Object System.Windows.Forms.CheckBox
    $skipTranslation.Text = "Skip translation"
    $skipTranslation.Location = New-Object System.Drawing.Point(18, 28)
    $skipTranslation.AutoSize = $true
    $translationGroup.Controls.Add($skipTranslation)

    $qaCheck = New-Object System.Windows.Forms.CheckBox
    $qaCheck.Text = "Translation QA pass"
    $qaCheck.Location = New-Object System.Drawing.Point(168, 28)
    $qaCheck.AutoSize = $true
    $qaCheck.Checked = $DefaultTranslationQaPass
    $translationGroup.Controls.Add($qaCheck)

    $autoGenderCheck = New-Object System.Windows.Forms.CheckBox
    $autoGenderCheck.Text = "Auto gender"
    $autoGenderCheck.Location = New-Object System.Drawing.Point(168, 52)
    $autoGenderCheck.AutoSize = $true
    $autoGenderCheck.Checked = $DefaultAutoGenderInference
    $translationGroup.Controls.Add($autoGenderCheck)

    $providerLabel = New-Object System.Windows.Forms.Label
    $providerLabel.Text = "Provider"
    $providerLabel.Location = New-Object System.Drawing.Point(18, 74)
    $providerLabel.Size = New-Object System.Drawing.Size(90, 18)
    $translationGroup.Controls.Add($providerLabel)

    $providerCombo = New-Object System.Windows.Forms.ComboBox
    $providerCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $providerCombo.Location = New-Object System.Drawing.Point(120, 70)
    $providerCombo.Size = New-Object System.Drawing.Size(190, 24)
    [void]$providerCombo.Items.AddRange([object[]]$providers)
    $providerCombo.Text = if ($providers -contains $DefaultProvider) { $DefaultProvider } else { "Gemini" }
    $translationGroup.Controls.Add($providerCombo)

    $modelLabel = New-Object System.Windows.Forms.Label
    $modelLabel.Text = "Model"
    $modelLabel.Location = New-Object System.Drawing.Point(18, 106)
    $modelLabel.Size = New-Object System.Drawing.Size(90, 18)
    $translationGroup.Controls.Add($modelLabel)

    $modelCombo = New-Object System.Windows.Forms.ComboBox
    $modelCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDown
    $modelCombo.Location = New-Object System.Drawing.Point(120, 102)
    $modelCombo.Size = New-Object System.Drawing.Size(190, 24)
    [void]$modelCombo.Items.AddRange([object[]](Get-TranslationModelsForProvider -Provider $providerCombo.Text))
    $modelCombo.Text = $DefaultTranslationModel
    $translationGroup.Controls.Add($modelCombo)

    $languageLabel = New-Object System.Windows.Forms.Label
    $languageLabel.Text = "Target language"
    $languageLabel.Location = New-Object System.Drawing.Point(18, 138)
    $languageLabel.Size = New-Object System.Drawing.Size(100, 18)
    $translationGroup.Controls.Add($languageLabel)

    $languageBox = New-Object System.Windows.Forms.TextBox
    $languageBox.Location = New-Object System.Drawing.Point(120, 134)
    $languageBox.Size = New-Object System.Drawing.Size(190, 24)
    $languageBox.Text = $DefaultTargetLanguage
    $translationGroup.Controls.Add($languageBox)

    $postLabel = New-Object System.Windows.Forms.Label
    $postLabel.Text = "SRT cleanup"
    $postLabel.Location = New-Object System.Drawing.Point(18, 170)
    $postLabel.Size = New-Object System.Drawing.Size(100, 18)
    $translationGroup.Controls.Add($postLabel)

    $postCombo = New-Object System.Windows.Forms.ComboBox
    $postCombo.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $postCombo.Location = New-Object System.Drawing.Point(120, 166)
    $postCombo.Size = New-Object System.Drawing.Size(190, 24)
    [void]$postCombo.Items.AddRange([object[]]($postProcessingOptions.Label))
    $defaultPostOption = $postProcessingOptions | Where-Object { $_.Value -eq $DefaultPostProcessingMode } | Select-Object -First 1
    $postCombo.Text = if ($defaultPostOption) { $defaultPostOption.Label } else { ($postProcessingOptions | Where-Object { $_.Value -eq "TwoLineTextAndTiming" } | Select-Object -First 1).Label }
    $translationGroup.Controls.Add($postCombo)

    $translationChangeKeyButton = New-Object System.Windows.Forms.Button
    $translationChangeKeyButton.Text = "Change translation API key"
    $translationChangeKeyButton.Location = New-Object System.Drawing.Point(120, 204)
    $translationChangeKeyButton.Size = New-Object System.Drawing.Size(190, 28)
    $translationGroup.Controls.Add($translationChangeKeyButton)

    $elevenLabsUsageGroup = New-Object System.Windows.Forms.GroupBox
    $elevenLabsUsageGroup.Text = "ElevenLabs credits / estimate"
    $elevenLabsUsageGroup.Location = New-Object System.Drawing.Point(14, 438)
    $elevenLabsUsageGroup.Size = New-Object System.Drawing.Size(334, 142)
    $elevenLabsUsageGroup.Visible = $false
    $form.Controls.Add($elevenLabsUsageGroup)

    $elevenLabsCreditsButton = New-Object System.Windows.Forms.Button
    $elevenLabsCreditsButton.Text = "Refresh credits"
    $elevenLabsCreditsButton.Location = New-Object System.Drawing.Point(18, 24)
    $elevenLabsCreditsButton.Size = New-Object System.Drawing.Size(120, 28)
    $elevenLabsUsageGroup.Controls.Add($elevenLabsCreditsButton)

    $elevenLabsChangeKeyButton = New-Object System.Windows.Forms.Button
    $elevenLabsChangeKeyButton.Text = "Change API key"
    $elevenLabsChangeKeyButton.Location = New-Object System.Drawing.Point(148, 24)
    $elevenLabsChangeKeyButton.Size = New-Object System.Drawing.Size(144, 28)
    $elevenLabsUsageGroup.Controls.Add($elevenLabsChangeKeyButton)

    $elevenLabsCreditsLabel = New-Object System.Windows.Forms.Label
    $elevenLabsCreditsLabel.Text = "Click Refresh credits to load the balance."
    $elevenLabsCreditsLabel.Location = New-Object System.Drawing.Point(18, 58)
    $elevenLabsCreditsLabel.Size = New-Object System.Drawing.Size(292, 18)
    $elevenLabsCreditsLabel.AutoEllipsis = $true
    $elevenLabsUsageGroup.Controls.Add($elevenLabsCreditsLabel)

    $elevenLabsEstimateLabel = New-Object System.Windows.Forms.Label
    $elevenLabsEstimateLabel.Text = "Select one media file to calculate the estimate."
    $elevenLabsEstimateLabel.Location = New-Object System.Drawing.Point(18, 82)
    $elevenLabsEstimateLabel.Size = New-Object System.Drawing.Size(292, 48)
    $elevenLabsUsageGroup.Controls.Add($elevenLabsEstimateLabel)

    $contextGroup = New-Object System.Windows.Forms.GroupBox
    $contextGroup.Text = "Context / gender hints"
    $contextGroup.Location = New-Object System.Drawing.Point(370, 440)
    $contextGroup.Size = New-Object System.Drawing.Size(334, 118)
    $form.Controls.Add($contextGroup)

    $voiceGenderCheck = New-Object System.Windows.Forms.CheckBox
    $voiceGenderCheck.Text = "Voice gender detection"
    $voiceGenderCheck.Location = New-Object System.Drawing.Point(18, 22)
    $voiceGenderCheck.Size = New-Object System.Drawing.Size(210, 22)
    $voiceGenderCheck.Checked = $DefaultVoiceGenderDetection
    $contextGroup.Controls.Add($voiceGenderCheck)

    $contextBox = New-Object System.Windows.Forms.TextBox
    $contextBox.Multiline = $true
    $contextBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $contextBox.Location = New-Object System.Drawing.Point(18, 50)
    $contextBox.Size = New-Object System.Drawing.Size(292, 50)
    $contextBox.Text = $DefaultSubtitleContextHints
    $contextGroup.Controls.Add($contextBox)

    $outputGroup = New-Object System.Windows.Forms.GroupBox
    $outputGroup.Text = "Output"
    $outputGroup.Location = New-Object System.Drawing.Point(14, 338)
    $outputGroup.Size = New-Object System.Drawing.Size(334, 88)
    $form.Controls.Add($outputGroup)

    $sameFolderCheck = New-Object System.Windows.Forms.CheckBox
    $sameFolderCheck.Text = "Save next to each media file"
    $sameFolderCheck.Location = New-Object System.Drawing.Point(18, 26)
    $sameFolderCheck.Size = New-Object System.Drawing.Size(230, 22)
    $sameFolderCheck.Checked = $true
    $outputGroup.Controls.Add($sameFolderCheck)

    $outputBox = New-Object System.Windows.Forms.TextBox
    $outputBox.Location = New-Object System.Drawing.Point(18, 54)
    $outputBox.Size = New-Object System.Drawing.Size(222, 24)
    $outputBox.Enabled = $false
    $outputGroup.Controls.Add($outputBox)

    $outputBrowseButton = New-Object System.Windows.Forms.Button
    $outputBrowseButton.Text = "Browse"
    $outputBrowseButton.Location = New-Object System.Drawing.Point(248, 52)
    $outputBrowseButton.Size = New-Object System.Drawing.Size(70, 28)
    $outputBrowseButton.Enabled = $false
    $outputGroup.Controls.Add($outputBrowseButton)

    $hintBox = New-Object System.Windows.Forms.Label
    $hintBox.Text = "For gender-sensitive subtitles, keep QA pass on and add speaker/gender hints when known."
    $hintBox.Location = New-Object System.Drawing.Point(18, 586)
    $hintBox.Size = New-Object System.Drawing.Size(670, 34)
    $form.Controls.Add($hintBox)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "Start"
    $okButton.Location = New-Object System.Drawing.Point(518, 628)
    $okButton.Size = New-Object System.Drawing.Size(84, 30)
    $form.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $cancelButton.Location = New-Object System.Drawing.Point(614, 628)
    $cancelButton.Size = New-Object System.Drawing.Size(84, 30)
    $form.Controls.Add($cancelButton)

    $audioTrackState = @{ Source = ''; Error = ''; IsFile = $false }
    $updateAudioTracks = {
        $path = $pathBox.Text.Trim().Trim('"')
        $isLocalFile = $fileRadio.Checked -and -not $youtubeRadio.Checked
        $sourceKey = "$isLocalFile|$path"
        if ($audioTrackState.Source -eq $sourceKey) { return }
        $preferred = if ($audioTrackCombo.SelectedItem) { $audioTrackCombo.SelectedItem.Number } else { 0 }
        $audioTrackState.Error = ''
        $audioTrackState.IsFile = $isLocalFile
        try {
            if ($isLocalFile -and -not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                $tracks = @(Get-MediaAudioTracks -MediaPath $path -FfmpegExecutable (Join-Path $script:ScriptRoot 'tools\ffmpeg.exe'))
                if ($tracks.Count -eq 0) { throw 'This file has no audio tracks.' }
                Set-AudioTrackChoices -Combo $audioTrackCombo -Tracks $tracks -PreferredTrack $preferred
                $audioTrackState.Source = $sourceKey
            }
            else {
                $reason = if ($youtubeRadio.Checked) { 'after download' } elseif ($folderRadio.Checked) { 'per file in folder' } else { 'select a file' }
                Set-AudioTrackChoices -Combo $audioTrackCombo -Tracks @() -PreferredTrack $preferred -FallbackReason $reason
                $audioTrackState.Source = $sourceKey
            }
        }
        catch {
            $audioTrackState.Error = $_.Exception.Message
            Set-AudioTrackChoices -Combo $audioTrackCombo -Tracks @() -FallbackReason 'could not read tracks'
            $audioTrackTooltip.SetToolTip($audioTrackCombo, $audioTrackState.Error)
        }
    }
    $audioTrackTimer = New-Object System.Windows.Forms.Timer
    $audioTrackTimer.Interval = 450
    $audioTrackTimer.Add_Tick({ $audioTrackTimer.Stop(); & $updateAudioTracks })
    $pathBox.Add_TextChanged({
        $audioTrackState.Source = ''
        $audioTrackTimer.Stop()
        $audioTrackTimer.Start()
    })
    $pathBox.Add_Leave({ $audioTrackTimer.Stop(); & $updateAudioTracks })
    $audioTrackCombo.Add_DropDown({ $audioTrackTimer.Stop(); & $updateAudioTracks })
    $form.Add_FormClosed({ $audioTrackTimer.Stop(); $audioTrackTimer.Dispose(); $audioTrackTooltip.Dispose() })

    $updateInputState = {
        $isYoutube = $youtubeRadio.Checked
        $pathBox.Enabled = -not $isYoutube
        $browseButton.Enabled = -not $isYoutube
        $urlBox.Enabled = $isYoutube
        $pasteButton.Enabled = $isYoutube
        $qualityCombo.Enabled = $isYoutube
        $cookiesCombo.Enabled = $isYoutube
        $cookiesFileBox.Enabled = $isYoutube
        $cookiesFileButton.Enabled = $isYoutube
        & $updateAudioTracks
    }

    $updateElevenLabsEstimate = {
        $selectedEngine = $transcriptionEngines | Where-Object { $_.Label -eq $engineCombo.Text } | Select-Object -First 1
        $usesElevenLabs = ($providerCombo.Text -eq "ElevenLabs Dubbing") -or ($selectedEngine -and $selectedEngine.Value -eq "ElevenLabs")
        if (-not $usesElevenLabs) {
            return
        }

        if ($youtubeRadio.Checked) {
            $elevenLabsEstimateLabel.Text = "YouTube: the estimate will be available after the download, when the duration is known."
            return
        }

        $mediaPath = $pathBox.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($mediaPath)) {
            $elevenLabsEstimateLabel.Text = "Select one media file to calculate the estimate."
            return
        }
        if (-not (Test-Path -LiteralPath $mediaPath -PathType Leaf)) {
            $elevenLabsEstimateLabel.Text = "For a folder, the cost is calculated separately for each media file."
            return
        }

        try {
            $mediaDurationSeconds = Get-MediaDurationSeconds -MediaPath $mediaPath
            if ($null -eq $mediaDurationSeconds -or $mediaDurationSeconds -le 0) {
                $elevenLabsEstimateLabel.Text = "Could not read the media duration, so no estimate is available."
                return
            }

            $useScribe = -not $skipTranscription.Checked -and $selectedEngine -and $selectedEngine.Value -eq "ElevenLabs"
            $useDubbing = -not $skipTranslation.Checked -and $providerCombo.Text -eq "ElevenLabs Dubbing"
            $elevenLabsEstimateLabel.Text = Get-ElevenLabsCostEstimateSummary `
                -MediaDurationSeconds $mediaDurationSeconds `
                -UseScribe $useScribe `
                -UseDubbing $useDubbing
        }
        catch {
            $elevenLabsEstimateLabel.Text = "Could not calculate the ElevenLabs estimate."
        }
    }

    $updateElevenLabsCreditsState = {
        $selectedEngine = $transcriptionEngines | Where-Object { $_.Label -eq $engineCombo.Text } | Select-Object -First 1
        $usesElevenLabs = ($providerCombo.Text -eq "ElevenLabs Dubbing") -or ($selectedEngine -and $selectedEngine.Value -eq "ElevenLabs")
        $elevenLabsUsageGroup.Visible = $usesElevenLabs
        if ($usesElevenLabs) {
            & $updateElevenLabsEstimate
        }
    }

    $updateTranslationState = {
        $enabled = -not $skipTranslation.Checked
        $isElevenLabsDubbing = $providerCombo.Text -in @("ElevenLabs Dubbing", "Local NLLB")
        $qaCheck.Enabled = $enabled -and -not $isElevenLabsDubbing
        $autoGenderCheck.Enabled = $enabled -and -not $isElevenLabsDubbing
        $providerCombo.Enabled = $enabled
        $translationChangeKeyButton.Enabled = $enabled -and $providerCombo.Text -ne "Local NLLB"
        $modelCombo.Enabled = $enabled -and -not $isElevenLabsDubbing
        $languageBox.Enabled = $enabled
        $postCombo.Enabled = $enabled -and $providerCombo.Text -ne "Local NLLB"
        if ($providerCombo.Text -eq "Local NLLB") {
            $postCombo.Text = ($postProcessingOptions | Where-Object { $_.Value -eq "None" } | Select-Object -First 1).Label
            $qaCheck.Checked = $false
            $autoGenderCheck.Checked = $false
            $voiceGenderCheck.Checked = $false
        }
        $voiceGenderCheck.Enabled = $enabled -and -not $isElevenLabsDubbing
        $contextBox.Enabled = $enabled -and $providerCombo.Text -ne "Local NLLB"
        $modelLabel.Text = if ($providerCombo.Text -eq "ElevenLabs Dubbing") { "Mode" } else { "Model" }
        $hintBox.Text = if ($providerCombo.Text -eq "Local NLLB") {
            "Offline CPU translation with sentence grouping and number protection. Optional .nllb-glossary.json beside input. SRT timings are preserved."
        } elseif ($isElevenLabsDubbing) {
            "Set Dubbing permission to Write (includes Read); creates a billable ElevenLabs job and returns the translated SRT."
        }
        else {
            "For gender-sensitive subtitles, keep QA pass on and add speaker/gender hints when known."
        }
        & $updateElevenLabsCreditsState
    }

    $updateTranscriptionState = {
        $enabled = -not $skipTranscription.Checked
        $audioTrackCombo.Enabled = $enabled
        $engineCombo.Enabled = $enabled
        $whisperCombo.Enabled = $enabled
        $selectedEngine = $transcriptionEngines | Where-Object { $_.Label -eq $engineCombo.Text } | Select-Object -First 1
        $speakerLabelsCheck.Enabled = $enabled -and $selectedEngine -and $selectedEngine.Value -in @("MOSS", "ElevenLabs")
        $isVnaiGemini = $selectedEngine -and $selectedEngine.Value -eq "VNAIGemini"
        $vnaiTranscriptionKeyButton.Visible = $isVnaiGemini
        $vnaiTranscriptionKeyButton.Enabled = $enabled
        $speakerLabelsCheck.Visible = -not $isVnaiGemini
        $whisperCombo.DropDownStyle = if ($isVnaiGemini) { [System.Windows.Forms.ComboBoxStyle]::DropDownList } else { [System.Windows.Forms.ComboBoxStyle]::DropDown }
        & $updateElevenLabsCreditsState
    }

    $fileRadio.Add_CheckedChanged({ & $updateInputState; & $updateElevenLabsEstimate })
    $folderRadio.Add_CheckedChanged({ & $updateInputState; & $updateElevenLabsEstimate })
    $youtubeRadio.Add_CheckedChanged({ & $updateInputState; & $updateElevenLabsEstimate })
    $skipTranslation.Add_CheckedChanged($updateTranslationState)

    $skipTranscription.Add_CheckedChanged($updateTranscriptionState)

    $engineCombo.Add_SelectedIndexChanged({
        $selectedEngine = $transcriptionEngines | Where-Object { $_.Label -eq $engineCombo.Text } | Select-Object -First 1
        $whisperCombo.Items.Clear()
        if ($selectedEngine -and $selectedEngine.Value -eq "MOSS") {
            [void]$whisperCombo.Items.Add($DefaultMossModel)
            $whisperCombo.Text = $DefaultMossModel
        }
        elseif ($selectedEngine -and $selectedEngine.Value -eq "ElevenLabs") {
            [void]$whisperCombo.Items.Add("scribe_v2")
            $whisperCombo.Text = "scribe_v2"
        }
        elseif ($selectedEngine -and $selectedEngine.Value -eq "VNAIGemini") {
            [void]$whisperCombo.Items.AddRange([object[]](Get-TranslationModelsForProvider -Provider "VNAI Pro Gemini"))
            $whisperCombo.Text = $DefaultVnaiGeminiModel
        }
        else {
            [void]$whisperCombo.Items.AddRange([object[]]$whisperModels)
            $whisperCombo.Text = $DefaultWhisperModel
        }
        & $updateTranscriptionState
    })

    $sameFolderCheck.Add_CheckedChanged({
        $outputBox.Enabled = -not $sameFolderCheck.Checked
        $outputBrowseButton.Enabled = -not $sameFolderCheck.Checked
    })

    $pathBox.Add_Leave($updateElevenLabsEstimate)

    $elevenLabsCreditsButton.Add_Click({
        $elevenLabsCreditsButton.Enabled = $false
        $elevenLabsCreditsLabel.Text = "Checking ElevenLabs credits..."
        try {
            $elevenLabsCreditsLabel.Text = Get-ElevenLabsCreditSummary
        }
        catch {
            $elevenLabsCreditsLabel.Text = "Could not load ElevenLabs credits."
            [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, "ElevenLabs credits", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
        finally {
            $elevenLabsCreditsButton.Enabled = $true
        }
    })

    $elevenLabsChangeKeyButton.Add_Click({
        try {
            $newApiKey = Read-AndSaveElevenLabsApiKey
            if (-not [string]::IsNullOrWhiteSpace($newApiKey)) {
                $elevenLabsCreditsLabel.Text = "API key saved. Refreshing credits..."
                $elevenLabsCreditsButton.PerformClick()
            }
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, "ElevenLabs API key", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    })

    $translationChangeKeyButton.Add_Click({
        try {
            $selectedProvider = $providerCombo.Text
            $newApiKey = Read-AndSaveTranslationApiKey -Provider $selectedProvider
            if (-not [string]::IsNullOrWhiteSpace($newApiKey)) {
                $modelStatus = ""
                if ($selectedProvider -in @("VNAI Pro", "VNAI Pro Claude", "VNAI Pro Gemini")) {
                    $availableModels = @(Get-VnaiProAvailableModels -ApiKey $newApiKey -Provider $selectedProvider)
                    $currentModel = $modelCombo.Text.Trim()
                    $defaultModel = Get-DefaultTranslationModel -Provider $selectedProvider
                    $modelCombo.Items.Clear()
                    [void]$modelCombo.Items.AddRange([object[]]$availableModels)
                    if ($availableModels -contains $currentModel) {
                        $modelCombo.Text = $currentModel
                    }
                    elseif ($availableModels -contains $defaultModel) {
                        $modelCombo.Text = $defaultModel
                    }
                    else {
                        $modelCombo.Text = [string]$availableModels[0]
                    }
                    $modelStatus = " Found $($availableModels.Count) models for this key; the model list was refreshed."
                }
                if ($selectedProvider -eq "ElevenLabs Dubbing") {
                    $elevenLabsCreditsLabel.Text = "API key saved. Click Refresh credits to load the balance."
                }
                [void][System.Windows.Forms.MessageBox]::Show($form, "$selectedProvider API key saved. It will be used for translation, including after restarting the app.$modelStatus", "Translation API key", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            }
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, "Translation API key", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    })

    $providerCombo.Add_SelectedIndexChanged({
        $selectedProvider = $providerCombo.Text
        $models = Get-TranslationModelsForProvider -Provider $selectedProvider
        $modelCombo.Items.Clear()
        [void]$modelCombo.Items.AddRange([object[]]$models)
        $modelCombo.Text = Get-DefaultTranslationModel -Provider $selectedProvider
        & $updateTranslationState
    })

    $browseButton.Add_Click({
        if ($folderRadio.Checked) {
            $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $folderDialog.Description = "Select folder with media files"
            $folderDialog.ShowNewFolderButton = $false
            if ($folderDialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
                $pathBox.Text = $folderDialog.SelectedPath
                & $updateElevenLabsEstimate
            }
        }
        else {
            $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
            $fileDialog.Title = "Select video or audio file"
            $fileDialog.Filter = "Media files|*.mp4;*.mkv;*.mov;*.avi;*.mp3;*.wav;*.m4a;*.flac|Video files|*.mp4;*.mkv;*.mov;*.avi|Audio files|*.mp3;*.wav;*.m4a;*.flac|All files|*.*"
            $fileDialog.Multiselect = $false
            $fileDialog.CheckFileExists = $true
            $fileDialog.CheckPathExists = $true
            $fileDialog.RestoreDirectory = $true
            if ($fileDialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
                $pathBox.Text = $fileDialog.FileName
                & $updateElevenLabsEstimate
            }
        }
    })

    $pasteButton.Add_Click({
        if ([System.Windows.Forms.Clipboard]::ContainsText()) {
            $urlBox.Text = [System.Windows.Forms.Clipboard]::GetText().Trim()
            $urlBox.Select($urlBox.Text.Length, 0)
            $urlBox.Focus()
        }
    })

    $cookiesFileButton.Add_Click({
        $fileDialog = New-Object System.Windows.Forms.OpenFileDialog
        $fileDialog.Title = "Select YouTube cookies.txt"
        $fileDialog.Filter = "Cookies text file|*.txt|All files|*.*"
        $fileDialog.Multiselect = $false
        $fileDialog.CheckFileExists = $true
        $fileDialog.CheckPathExists = $true
        $fileDialog.RestoreDirectory = $true
        if ($fileDialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $cookiesFileBox.Text = $fileDialog.FileName
        }
    })

    $outputBrowseButton.Add_Click({
        $folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $folderDialog.Description = "Select output folder"
        $folderDialog.ShowNewFolderButton = $true
        if ($folderDialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $outputBox.Text = $folderDialog.SelectedPath
        }
    })

    $okButton.Add_Click({
        $audioTrackTimer.Stop()
        & $updateAudioTracks
        if (-not $skipTranscription.Checked -and $audioTrackState.Error) {
            [void][System.Windows.Forms.MessageBox]::Show($form, $audioTrackState.Error, 'Audio tracks', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }
        if ($youtubeRadio.Checked) {
            if ([string]::IsNullOrWhiteSpace($urlBox.Text)) {
                [void][System.Windows.Forms.MessageBox]::Show($form, "Paste a YouTube URL first.", "Missing input", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                return
            }
        }
        else {
            if ([string]::IsNullOrWhiteSpace($pathBox.Text) -or -not (Test-Path -LiteralPath $pathBox.Text.Trim())) {
                [void][System.Windows.Forms.MessageBox]::Show($form, "Select an existing file or folder first.", "Missing input", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                return
            }
        }

        if (-not $skipTranscription.Checked -and [string]::IsNullOrWhiteSpace($whisperCombo.Text)) {
            [void][System.Windows.Forms.MessageBox]::Show($form, "Choose a transcription model.", "Missing model", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }

        if (-not $skipTranslation.Checked) {
            if ([string]::IsNullOrWhiteSpace($modelCombo.Text) -or [string]::IsNullOrWhiteSpace($languageBox.Text)) {
                [void][System.Windows.Forms.MessageBox]::Show($form, "Choose a translation model and target language.", "Missing translation settings", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
                return
            }
            if ($providerCombo.Text -eq "ElevenLabs Dubbing") {
                $dubbingConfirmation = [System.Windows.Forms.MessageBox]::Show(
                    $form,
                    "This uploads the original media and creates a billable ElevenLabs Dubbing job. Continue?",
                    "Confirm ElevenLabs Dubbing",
                    [System.Windows.Forms.MessageBoxButtons]::YesNo,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                )
                if ($dubbingConfirmation -ne [System.Windows.Forms.DialogResult]::Yes) {
                    return
                }
            }
        }

        if (-not $sameFolderCheck.Checked -and [string]::IsNullOrWhiteSpace($outputBox.Text)) {
            [void][System.Windows.Forms.MessageBox]::Show($form, "Select an output folder or use the media folder option.", "Missing output folder", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }

        $selectedPost = $postProcessingOptions | Where-Object { $_.Label -eq $postCombo.Text } | Select-Object -First 1
        $selectedCookieBrowser = $cookieBrowsers | Where-Object { $_.Label -eq $cookiesCombo.Text } | Select-Object -First 1
        if (-not $selectedPost) {
            [void][System.Windows.Forms.MessageBox]::Show($form, "Choose an SRT cleanup mode.", "Missing SRT cleanup", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }

        $form.Tag = [pscustomobject]@{
            InputPath = if ($youtubeRadio.Checked) { "" } else { $pathBox.Text.Trim() }
            YouTubeUrl = if ($youtubeRadio.Checked) { $urlBox.Text.Trim() } else { "" }
            YouTubeQuality = $qualityCombo.Text
            YouTubeCookiesFromBrowser = if ($youtubeRadio.Checked -and $selectedCookieBrowser) { $selectedCookieBrowser.Value } else { "" }
            YouTubeCookiesFile = if ($youtubeRadio.Checked) { $cookiesFileBox.Text.Trim() } else { "" }
            OutputDir = if ($sameFolderCheck.Checked) { "" } else { $outputBox.Text.Trim() }
            TranscriptionEngine = ($transcriptionEngines | Where-Object { $_.Label -eq $engineCombo.Text } | Select-Object -First 1).Value
            AudioTrack = [int]$audioTrackCombo.SelectedItem.Number
            WhisperModel = if ($engineCombo.Text -eq "Faster Whisper XXL") { $whisperCombo.Text.Trim() } else { $DefaultWhisperModel }
            MossModel = if ($engineCombo.Text -eq "MOSS + speaker diarization") { $whisperCombo.Text.Trim() } else { $DefaultMossModel }
            ElevenLabsModel = if ($engineCombo.Text -eq "ElevenLabs Scribe v2 (cloud)") { $whisperCombo.Text.Trim() } else { "scribe_v2" }
            VnaiGeminiModel = if ($engineCombo.Text -eq "VNAI Pro Gemini (cloud)") { $whisperCombo.Text.Trim() } else { $DefaultVnaiGeminiModel }
            ShowSpeakerLabels = [bool]($speakerLabelsCheck.Checked -and $engineCombo.Text -ne "VNAI Pro Gemini (cloud)")
            SkipTranscription = [bool]$skipTranscription.Checked
            SkipTranslation = [bool]$skipTranslation.Checked
            TranslationProvider = $providerCombo.Text.Trim()
            OpenAIModel = $modelCombo.Text.Trim()
            TargetLanguage = $languageBox.Text.Trim()
            SrtPostProcessingMode = $selectedPost.Value
            EnableTranslationQaPass = [bool]($qaCheck.Checked -and $providerCombo.Text -ne "ElevenLabs Dubbing")
            EnableAutoGenderInference = [bool]($autoGenderCheck.Checked -and $providerCombo.Text -ne "ElevenLabs Dubbing")
            EnableVoiceGenderDetection = [bool]($voiceGenderCheck.Checked -and $providerCombo.Text -ne "ElevenLabs Dubbing")
            SubtitleContextHints = $contextBox.Text.Trim()
        }
        $form.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $form.Close()
    })

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton
    & $updateInputState
    & $updateTranslationState
    & $updateTranscriptionState
    $form.Add_Shown({
        Show-GuiWindow -Form $form
    })

    $result = $form.ShowDialog()
    if ($result -ne [System.Windows.Forms.DialogResult]::OK -or -not $form.Tag) {
        throw "Run options were not selected."
    }

    return $form.Tag
}

function Get-LocalConfig {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        return [pscustomobject]@{}
    }

    try {
        $configText = Get-Content -LiteralPath $script:ConfigPath -Raw
        if ([string]::IsNullOrWhiteSpace($configText)) {
            return [pscustomobject]@{}
        }

        return ($configText | ConvertFrom-Json)
    }
    catch {
        Write-RunWarning "Could not read saved config. A new config file may be created."
        return [pscustomobject]@{}
    }
}

function Set-LocalConfigProperty {
    param(
        $Config,
        [string]$Name,
        $Value
    )

    if (Test-LocalConfigProperty -Config $Config -Name $Name) {
        $Config.$Name = $Value
    }
    else {
        $Config | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
}

function Test-LocalConfigProperty {
    param(
        $Config,
        [string]$Name
    )

    if ($null -eq $Config) {
        return $false
    }

    return $null -ne ($Config.PSObject.Properties | Where-Object { $_.Name -eq $Name } | Select-Object -First 1)
}

function Save-LocalConfig {
    param($Config)

    $Config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8
}

function Get-ProviderConfigKeyName {
    param([string]$Provider)

    if ($Provider -in @("ElevenLabs", "ElevenLabs Dubbing")) {
        return "ElevenLabs"
    }

    if ($Provider -eq "OpenAI") {
        return "OpenAI"
    }

    if ($Provider -eq "VNAI Pro") {
        return "VNAIPro"
    }

    if ($Provider -eq "VNAI Pro Claude") {
        return "VNAIProClaude"
    }

    if ($Provider -eq "VNAI Pro Gemini") {
        return "VNAIProGemini"
    }

    if ($Provider -eq "Gemini") {
        return "Gemini"
    }

    return "AIPrimeTech"
}

function Read-MaskedApiKeyDialog {
    param(
        [string]$Title,
        [string]$Label
    )

    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.StartPosition = "CenterScreen"
    $form.FormBorderStyle = "FixedDialog"
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.TopMost = $true
    $form.ClientSize = New-Object System.Drawing.Size(520, 142)

    $labelControl = New-Object System.Windows.Forms.Label
    $labelControl.Text = $Label
    $labelControl.Location = New-Object System.Drawing.Point(16, 16)
    $labelControl.Size = New-Object System.Drawing.Size(488, 34)
    $form.Controls.Add($labelControl)

    $keyBox = New-Object System.Windows.Forms.TextBox
    $keyBox.Location = New-Object System.Drawing.Point(16, 54)
    $keyBox.Size = New-Object System.Drawing.Size(488, 24)
    $keyBox.UseSystemPasswordChar = $true
    $form.Controls.Add($keyBox)

    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = "OK"
    $okButton.Location = New-Object System.Drawing.Point(328, 96)
    $okButton.Size = New-Object System.Drawing.Size(80, 28)
    $okButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $form.Controls.Add($okButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.Location = New-Object System.Drawing.Point(424, 96)
    $cancelButton.Size = New-Object System.Drawing.Size(80, 28)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $form.Controls.Add($cancelButton)

    $form.AcceptButton = $okButton
    $form.CancelButton = $cancelButton
    $form.Add_Shown({
        Show-GuiWindow -Form $form
        $keyBox.Focus()
    })

    if ($form.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) {
        return $null
    }
    return $keyBox.Text.Trim()
}

function Test-ElevenLabsApiKeyFormat {
    param([string]$ApiKey)

    if ([string]::IsNullOrWhiteSpace($ApiKey) -or $ApiKey.Length -lt 20) {
        return $false
    }
    # ElevenLabs key IDs are often long hexadecimal values. They are identifiers
    # shown in the dashboard, not secrets accepted by the API. Real API keys use
    # the sk_ prefix; reject IDs locally before making a request.
    if ($ApiKey -notmatch '^sk_[^\s]+$') {
        return $false
    }
    if ($ApiKey -match "\s") {
        return $false
    }
    foreach ($character in $ApiKey.ToCharArray()) {
        $code = [int]$character
        if ($code -lt 33 -or $code -gt 126) {
            return $false
        }
    }
    return $true
}

function Get-ElevenLabsApiKey {
    $savedApiKey = Get-SavedTranslationApiKey -Provider "ElevenLabs"
    $preferSavedApiKey = $false
    try {
        $config = Get-LocalConfig
        $preferSavedApiKey = (Test-LocalConfigProperty -Config $config -Name "PreferSavedElevenLabsApiKey") -and [bool]$config.PreferSavedElevenLabsApiKey
    }
    catch {
    }

    if ($preferSavedApiKey -and (Test-ElevenLabsApiKeyFormat -ApiKey $savedApiKey)) {
        return $savedApiKey
    }

    if (Test-ElevenLabsApiKeyFormat -ApiKey $env:ELEVENLABS_API_KEY) {
        return $env:ELEVENLABS_API_KEY
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ELEVENLABS_API_KEY)) {
        Write-RunWarning "ELEVENLABS_API_KEY is not a valid ElevenLabs secret. Use the full API key beginning with sk_; the dashboard key ID cannot authenticate."
    }

    if (Test-ElevenLabsApiKeyFormat -ApiKey $savedApiKey) {
        return $savedApiKey
    }
    if (-not [string]::IsNullOrWhiteSpace($savedApiKey)) {
        Write-RunWarning "The saved ElevenLabs value is not a valid secret (key IDs do not work). Replace it with the full API key beginning with sk_."
    }

    if ($Headless) {
        throw "Set ELEVENLABS_API_KEY in the environment or in the Web app .env file."
    }

    $apiKey = Read-MaskedApiKeyDialog `
        -Title "ElevenLabs API key" `
        -Label "Paste only the full ElevenLabs API key beginning with sk_ (not the dashboard key ID, name, quotes, or spaces)."
    if (-not (Test-ElevenLabsApiKeyFormat -ApiKey $apiKey)) {
        throw "This is not a valid ElevenLabs API key. Paste the full secret beginning with sk_; the dashboard key ID is not accepted by the API."
    }

    Save-ElevenLabsDesktopApiKey -ApiKey $apiKey
    return $apiKey
}

function Save-ElevenLabsDesktopApiKey {
    param([string]$ApiKey)

    Save-TranslationApiKey -Provider "ElevenLabs" -ApiKey $ApiKey
    $config = Get-LocalConfig
    Set-LocalConfigProperty -Config $config -Name "PreferSavedElevenLabsApiKey" -Value $true
    Save-LocalConfig -Config $config
    $env:ELEVENLABS_API_KEY = $ApiKey
}

function Read-AndSaveElevenLabsApiKey {
    $apiKey = Read-MaskedApiKeyDialog `
        -Title "Change ElevenLabs API key" `
        -Label "Paste the full secret beginning with sk_ (not the dashboard key ID). Credit balance requires an unrestricted key; transcription needs Speech to Text access."

    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        return $null
    }
    if (-not (Test-ElevenLabsApiKeyFormat -ApiKey $apiKey)) {
        throw "This is an ElevenLabs key ID, or otherwise not a valid secret. Copy the full API key beginning with sk_ from the API Keys page."
    }

    Save-ElevenLabsDesktopApiKey -ApiKey $apiKey
    return $apiKey
}

function Assert-ElevenLabsDubbingApiAccess {
    param([string]$ApiKey)

    try {
        [void](Invoke-RestMethod `
            -Uri "https://api.elevenlabs.io/v1/dubbing?page_size=1" `
            -Headers @{ "xi-api-key" = $ApiKey; "Accept" = "application/json" } `
            -Method Get `
            -TimeoutSec 30)
    }
    catch {
        $apiMessage = ""
        if (-not [string]::IsNullOrWhiteSpace($_.ErrorDetails.Message)) {
            try {
                $errorPayload = $_.ErrorDetails.Message | ConvertFrom-Json
                if ($errorPayload.detail.message) {
                    $apiMessage = [string]$errorPayload.detail.message
                }
            }
            catch {
                $apiMessage = [string]$_.ErrorDetails.Message
            }
        }

        if ($apiMessage -match "dubbing_read|missing the permission|missing_permissions") {
            throw "The saved ElevenLabs API key does not have Dubbing access. Open the ElevenLabs API Keys page, set Dubbing to Write (this includes Read), save, and then run again."
        }
        if ([string]::IsNullOrWhiteSpace($apiMessage)) {
            $apiMessage = $_.Exception.Message
        }
        throw "Could not verify ElevenLabs Dubbing access: $apiMessage"
    }

    Write-RunLog "ElevenLabs Dubbing access check: read permission verified"
}

function Get-ElevenLabsCreditSummary {
    $apiKey = Get-ElevenLabsApiKey

    try {
        $subscription = Invoke-RestMethod `
            -Uri "https://api.elevenlabs.io/v1/user/subscription" `
            -Headers @{ "xi-api-key" = $apiKey; "Accept" = "application/json" } `
            -Method Get `
            -TimeoutSec 30 `
            -ErrorAction Stop
    }
    catch {
        $creditError = $_
        $apiErrorDetails = [string]$creditError.ErrorDetails.Message
        $statusCode = 0
        try {
            $statusCode = [int]$creditError.Exception.Response.StatusCode
        }
        catch {
        }

        if ($apiErrorDetails -match "user_read") {
            throw "This API key can transcribe, but ElevenLabs will not let it read the credit balance because it is missing the internal user_read permission. The current API-key editor does not list that permission. Edit the key, turn Restrict Key OFF, click Save Changes, and then try Refresh credits again."
        }
        if ($statusCode -eq 401) {
            throw "ElevenLabs rejected this API key (HTTP 401). The key may be invalid, expired, or disabled. Create a new key, then click Change API key here and paste it."
        }
        if ($statusCode -eq 403) {
            throw "ElevenLabs authenticated the key but denied access (HTTP 403). Check its endpoint permissions and any IP restrictions."
        }

        throw "Could not read the ElevenLabs credit balance: $(Get-RestErrorMessage -ErrorRecord $creditError)"
    }

    $usedCredits = [int64]$subscription.character_count
    $creditLimit = [int64]$subscription.character_limit
    $remainingCredits = [Math]::Max([int64]0, $creditLimit - $usedCredits)
    $tier = if ([string]::IsNullOrWhiteSpace([string]$subscription.tier)) { "unknown plan" } else { [string]$subscription.tier }

    return "ElevenLabs ($tier): $remainingCredits credits remaining ($usedCredits / $creditLimit used)"
}

function Get-ElevenLabsCostEstimateSummary {
    param(
        [double]$MediaDurationSeconds,
        [bool]$UseScribe,
        [bool]$UseDubbing
    )

    if ($MediaDurationSeconds -le 0) {
        return "Could not determine the media duration."
    }

    # ElevenLabs API pricing as of August 2026: Scribe v2 is $0.22/hour and
    # automatic dubbing with watermark is $0.33/minute. One credit is $0.0001.
    $hours = $MediaDurationSeconds / 3600.0
    $minutes = $MediaDurationSeconds / 60.0
    $duration = [TimeSpan]::FromSeconds($MediaDurationSeconds)
    $durationText = "{0:00}:{1:00}:{2:00}" -f [Math]::Floor($duration.TotalHours), $duration.Minutes, $duration.Seconds
    $parts = New-Object System.Collections.Generic.List[string]

    if ($UseScribe) {
        $scribeCredits = [Math]::Round($hours * 2200.0)
        $scribeCost = $hours * 0.22
        $parts.Add(('Scribe: ~{0} credits (${1})' -f $scribeCredits, $scribeCost.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)))
    }

    if ($UseDubbing) {
        $dubbingCredits = [Math]::Round($minutes * 3300.0)
        $dubbingCost = $minutes * 0.33
        $parts.Add(('Dubbing: ~{0} credits (${1})' -f $dubbingCredits, $dubbingCost.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)))
    }

    if ($parts.Count -eq 0) {
        return "Duration $durationText. No ElevenLabs service is selected."
    }

    return "Duration $durationText`r`nEstimated: $($parts -join ' + ')"
}

function Get-SavedFasterWhisperPath {
    try {
        $config = Get-LocalConfig
        if ((Test-LocalConfigProperty -Config $config -Name "FasterWhisperPath") -and
            -not [string]::IsNullOrWhiteSpace($config.FasterWhisperPath) -and
            (Test-Path -LiteralPath $config.FasterWhisperPath)) {
            return (Resolve-Path -LiteralPath $config.FasterWhisperPath).Path
        }
    }
    catch {
        Write-RunWarning "Could not read saved Faster Whisper config. You can select the executable again."
    }

    return $null
}

function Save-FasterWhisperPath {
    param([string]$ExecutablePath)

    $resolvedPath = (Resolve-Path -LiteralPath $ExecutablePath).Path
    $config = Get-LocalConfig
    Set-LocalConfigProperty -Config $config -Name "FasterWhisperPath" -Value $resolvedPath
    Save-LocalConfig -Config $config
}

function Get-SavedYtDlpPath {
    try {
        $config = Get-LocalConfig
        if ((Test-LocalConfigProperty -Config $config -Name "YtDlpPath") -and
            -not [string]::IsNullOrWhiteSpace($config.YtDlpPath) -and
            (Test-Path -LiteralPath $config.YtDlpPath)) {
            return (Resolve-Path -LiteralPath $config.YtDlpPath).Path
        }
    }
    catch {
        Write-RunWarning "Could not read saved yt-dlp config. You can select the executable again."
    }

    return $null
}

function Save-YtDlpPath {
    param([string]$ExecutablePath)

    $resolvedPath = (Resolve-Path -LiteralPath $ExecutablePath).Path
    $config = Get-LocalConfig
    Set-LocalConfigProperty -Config $config -Name "YtDlpPath" -Value $resolvedPath
    Save-LocalConfig -Config $config
}

function Get-SavedTranslationApiKey {
    param([string]$Provider)

    $config = Get-LocalConfig
    if (-not (Test-LocalConfigProperty -Config $config -Name "ApiKeys") -or $null -eq $config.ApiKeys) {
        return $null
    }

    $keyName = Get-ProviderConfigKeyName -Provider $Provider
    if ((Test-LocalConfigProperty -Config $config.ApiKeys -Name $keyName) -and
        -not [string]::IsNullOrWhiteSpace($config.ApiKeys.$keyName)) {
        return [string]$config.ApiKeys.$keyName
    }

    return $null
}

function Save-TranslationApiKey {
    param(
        [string]$Provider,
        [string]$ApiKey,
        [switch]$PreferSaved
    )

    if ([string]::IsNullOrWhiteSpace($ApiKey)) {
        return
    }

    $config = Get-LocalConfig
    if (-not (Test-LocalConfigProperty -Config $config -Name "ApiKeys") -or $null -eq $config.ApiKeys) {
        Set-LocalConfigProperty -Config $config -Name "ApiKeys" -Value ([pscustomobject]@{})
    }

    $keyName = Get-ProviderConfigKeyName -Provider $Provider
    Set-LocalConfigProperty -Config $config.ApiKeys -Name $keyName -Value $ApiKey
    if ($PreferSaved) {
        if (-not (Test-LocalConfigProperty -Config $config -Name "PreferredTranslationKeys") -or $null -eq $config.PreferredTranslationKeys) {
            Set-LocalConfigProperty -Config $config -Name "PreferredTranslationKeys" -Value ([pscustomobject]@{})
        }
        Set-LocalConfigProperty -Config $config.PreferredTranslationKeys -Name $keyName -Value $true
    }
    Save-LocalConfig -Config $config
}

function Read-AndSaveTranslationApiKey {
    param(
        [ValidateSet("OpenAI", "VNAI Pro", "VNAI Pro Claude", "VNAI Pro Gemini", "Gemini", "AI Prime Tech", "ElevenLabs Dubbing", "Local NLLB")]
        [string]$Provider
    )

    if ($Provider -eq "Local NLLB") { return $null }
    if ($Provider -eq "ElevenLabs Dubbing") { return Read-AndSaveElevenLabsApiKey }

    $apiKey = Read-MaskedApiKeyDialog `
        -Title "Change $Provider translation API key" `
        -Label "Paste the new $Provider API key. It will be saved locally for this provider. Cancel keeps the existing key."
    if ([string]::IsNullOrWhiteSpace($apiKey)) { return $null }
    if ($apiKey -match '[^\x21-\x7E]' -or $apiKey.Contains('"') -or $apiKey.Contains("'")) {
        throw "Copy only the API key value, without quotes, spaces, or explanatory text."
    }

    Save-TranslationApiKey -Provider $Provider -ApiKey $apiKey -PreferSaved
    return $apiKey
}

function Get-TranslationApiKey {
    param(
        [string]$Provider,
        [bool]$ForcePrompt = $false
    )

    if ($Provider -eq "ElevenLabs Dubbing") {
        return Get-ElevenLabsApiKey
    }

    if (-not $ForcePrompt) {
        $config = Get-LocalConfig
        $keyName = Get-ProviderConfigKeyName -Provider $Provider
        if ((Test-LocalConfigProperty -Config $config -Name "PreferredTranslationKeys") -and
            (Test-LocalConfigProperty -Config $config.PreferredTranslationKeys -Name $keyName) -and
            [bool]$config.PreferredTranslationKeys.$keyName) {
            $savedApiKey = Get-SavedTranslationApiKey -Provider $Provider
            if (-not [string]::IsNullOrWhiteSpace($savedApiKey)) { return $savedApiKey }
        }
    }

    if ($Provider -eq "OpenAI") {
        if (-not $ForcePrompt -and -not [string]::IsNullOrWhiteSpace($env:OPENAI_API_KEY)) {
            return $env:OPENAI_API_KEY
        }

        $promptLabel = "OpenAI API key"
        $missingMessage = "Set OPENAI_API_KEY."
    }
    elseif ($Provider -eq "VNAI Pro") {
        if (-not $ForcePrompt -and -not [string]::IsNullOrWhiteSpace($env:VNAIPRO_API_KEY)) {
            return $env:VNAIPRO_API_KEY
        }

        $promptLabel = "VNAI Pro API key"
        $missingMessage = "Set VNAIPRO_API_KEY."
    }
    elseif ($Provider -eq "VNAI Pro Claude") {
        if (-not $ForcePrompt -and -not [string]::IsNullOrWhiteSpace($env:VNAIPRO_CLAUDE_API_KEY)) {
            return $env:VNAIPRO_CLAUDE_API_KEY
        }

        $promptLabel = "VNAI Pro Claude API key"
        $missingMessage = "Set VNAIPRO_CLAUDE_API_KEY."
    }
    elseif ($Provider -eq "VNAI Pro Gemini") {
        if (-not $ForcePrompt -and -not [string]::IsNullOrWhiteSpace($env:VNAIPRO_GEMINI_API_KEY)) {
            return $env:VNAIPRO_GEMINI_API_KEY
        }

        $promptLabel = "VNAI Pro Gemini API key"
        $missingMessage = "Set VNAIPRO_GEMINI_API_KEY."
    }
    elseif ($Provider -eq "Gemini") {
        if (-not $ForcePrompt -and -not [string]::IsNullOrWhiteSpace($env:GEMINI_API_KEY)) {
            return $env:GEMINI_API_KEY
        }

        if (-not $ForcePrompt -and -not [string]::IsNullOrWhiteSpace($env:GOOGLE_API_KEY)) {
            return $env:GOOGLE_API_KEY
        }

        $promptLabel = "Gemini API key"
        $missingMessage = "Set GEMINI_API_KEY or GOOGLE_API_KEY."
    }
    else {
        if (-not $ForcePrompt -and -not [string]::IsNullOrWhiteSpace($env:AIPRIMETECH_API_KEY)) {
            return $env:AIPRIMETECH_API_KEY
        }

        if (-not $ForcePrompt -and -not [string]::IsNullOrWhiteSpace($env:ANTHROPIC_AUTH_TOKEN)) {
            return $env:ANTHROPIC_AUTH_TOKEN
        }

        if (-not $ForcePrompt -and -not [string]::IsNullOrWhiteSpace($env:ANTHROPIC_API_KEY)) {
            return $env:ANTHROPIC_API_KEY
        }

        $promptLabel = "AI Prime Tech API key"
        $missingMessage = "Set AIPRIMETECH_API_KEY, ANTHROPIC_AUTH_TOKEN, or ANTHROPIC_API_KEY."
    }

    if (-not $ForcePrompt) {
        $savedApiKey = Get-SavedTranslationApiKey -Provider $Provider
        if (-not [string]::IsNullOrWhiteSpace($savedApiKey)) {
            return $savedApiKey
        }
    }

<#
    Legacy AI Prime Tech environment-variable lookup kept here for reference.
    if (-not $ForcePrompt -and -not [string]::IsNullOrWhiteSpace($env:AIPRIMETECH_API_KEY)) {
        return $env:AIPRIMETECH_API_KEY
    }

    if (-not $ForcePrompt -and -not [string]::IsNullOrWhiteSpace($env:ANTHROPIC_AUTH_TOKEN)) {
        return $env:ANTHROPIC_AUTH_TOKEN
    }

    if (-not $ForcePrompt -and -not [string]::IsNullOrWhiteSpace($env:ANTHROPIC_API_KEY)) {
        return $env:ANTHROPIC_API_KEY
    }
#>

    if ($Headless) {
        Write-RunWarning "$missingMessage No interactive API-key prompt is available in headless mode."
        return $null
    }

    $apiKey = Read-MaskedApiKeyDialog `
        -Title "$Provider translation API key" `
        -Label "Paste the $Provider API key. It will be stored locally for this provider; the value remains hidden."

    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        Write-RunWarning "$missingMessage Exporting Faster Whisper output without translation."
        return $null
    }

    if ($apiKey -match '[^\x21-\x7E]' -or $apiKey.Contains('"') -or $apiKey.Contains("'")) {
        throw "Copy only the API key value, without quotes, spaces, or explanatory text."
    }

    Save-TranslationApiKey -Provider $Provider -ApiKey $apiKey -PreferSaved
    return $apiKey
}

function Get-VnaiProAvailableModels {
    param(
        [string]$ApiKey,
        [string]$Provider = "VNAI Pro"
    )

    try {
        $response = Invoke-RestMethod `
            -Uri "https://apikey.vnaipro.app/v1/models" `
            -Headers @{ "Authorization" = "Bearer $ApiKey"; "Accept" = "application/json" } `
            -Method Get `
            -TimeoutSec 30 `
            -ErrorAction Stop
    }
    catch {
        $statusCode = 0
        try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
        if ($statusCode -eq 401) {
            throw "$Provider rejected this API key. Use Change translation API key and enter the active key from the VNAI Pro API Keys page."
        }
        throw "Could not check $Provider model access: $(Get-RestErrorMessage -ErrorRecord $_)"
    }

    $availableModels = @(
        if ($null -ne $response.data) {
            $response.data | ForEach-Object { [string]$_.id } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        }
    )
    if ($availableModels.Count -eq 0) {
        throw "The $Provider API key is valid, but it currently has no models assigned. Ask the provider to enable model access for this key, then try again."
    }

    return @($availableModels)
}

function Assert-VnaiProModelAccess {
    param(
        [string]$ApiKey,
        [string]$Model,
        [string]$Provider = "VNAI Pro"
    )

    $availableModels = @(Get-VnaiProAvailableModels -ApiKey $ApiKey -Provider $Provider)
    if ($availableModels -notcontains $Model) {
        if ($Provider -eq "VNAI Pro Claude") {
            throw "Claude through VNAI Pro is supported, but this Claude API key/group cannot use model '$Model'. Ask the VNAI Pro seller/provider to assign an active Claude channel to this key. Available models for this key: $($availableModels -join ', ')."
        }
        if ($Provider -eq "VNAI Pro Gemini") {
            $preferredModels = @(Get-TranslationModelsForProvider -Provider $Provider)
            $fallbackModel = @($preferredModels | Where-Object { $availableModels -contains $_ } | Select-Object -First 1)
            if ($fallbackModel.Count -eq 0) {
                $fallbackModel = @($availableModels | Where-Object { $_ -like "gemini-*" } | Select-Object -First 1)
            }
            if ($fallbackModel.Count -gt 0) {
                Write-RunWarning "VNAI Pro Gemini model '$Model' is not assigned to this key. Switching to '$($fallbackModel[0])'."
                return [string]$fallbackModel[0]
            }
            throw "Gemini through VNAI Pro is supported, but this Gemini API key/group cannot use model '$Model'. Choose one of the models assigned to this key: $($availableModels -join ', ')."
        }
        throw "The $Provider API key cannot use model '$Model'. Available models for this key: $($availableModels -join ', ')."
    }

    Write-RunLog "$Provider model access verified: $Model"
    return $Model
}

function Format-Duration {
    param([TimeSpan]$Duration)

    return "{0:00}:{1:00}:{2:00}.{3:000}" -f `
        [Math]::Floor($Duration.TotalHours),
        $Duration.Minutes,
        $Duration.Seconds,
        $Duration.Milliseconds
}

function Get-SafeFileNamePart {
    param(
        [string]$Text,
        [string]$Fallback = "unknown"
    )

    $safeText = ($Text -replace "[^\p{L}\p{Nd}._-]+", "_").Trim("_")
    if ([string]::IsNullOrWhiteSpace($safeText)) {
        return $Fallback
    }

    return $safeText
}

function Convert-DurationTextToSeconds {
    param([string]$DurationText)

    $text = $DurationText.Trim()
    if ($text -match "^(?:(?<h>\d+):)?(?<m>\d{1,2}):(?<s>\d{2})(?:[.,](?<ms>\d+))?$") {
        $hours = if ($Matches.h) { [int]$Matches.h } else { 0 }
        $milliseconds = if ($Matches.ms) { [double]("0.$($Matches.ms)") } else { 0.0 }
        return ($hours * 3600) + ([int]$Matches.m * 60) + [int]$Matches.s + $milliseconds
    }

    return $null
}

function Get-MediaDurationSeconds {
    param(
        [string]$MediaPath,
        [string]$FasterWhisperExecutable = ""
    )

    $ffprobe = Get-Command "ffprobe.exe" -ErrorAction SilentlyContinue
    if (-not $ffprobe -and -not [string]::IsNullOrWhiteSpace($FasterWhisperExecutable)) {
        $whisperFolder = Split-Path -Parent $FasterWhisperExecutable
        $ffprobeCandidates = @(
            (Join-Path $whisperFolder "ffprobe.exe"),
            (Join-Path $whisperFolder "ffmpeg\bin\ffprobe.exe")
        )
        foreach ($candidate in $ffprobeCandidates) {
            if (Test-Path -LiteralPath $candidate) {
                $ffprobe = [pscustomobject]@{ Source = $candidate }
                break
            }
        }
    }

    if ($ffprobe) {
        try {
            $durationText = & $ffprobe.Source -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 $MediaPath 2>$null
            $durationText = ([string]$durationText).Trim()
            $duration = 0.0
            if ([double]::TryParse($durationText, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$duration) -and $duration -gt 0) {
                return $duration
            }
        }
        catch {
        }
    }

    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.Namespace((Split-Path -Parent $MediaPath))
        if ($folder) {
            $item = $folder.ParseName((Split-Path -Leaf $MediaPath))
            if ($item) {
                for ($i = 0; $i -le 350; $i++) {
                    $value = $folder.GetDetailsOf($item, $i)
                    if ($value -match "\d+:\d{2}") {
                        $duration = Convert-DurationTextToSeconds -DurationText $value
                        if ($duration -and $duration -gt 0) {
                            return $duration
                        }
                    }
                }
            }
        }
    }
    catch {
    }

    return $null
}

function Write-TimingSummary {
    param(
        [TimeSpan]$TranscriptionDuration,
        [bool]$TranscriptionSkipped,
        [TimeSpan]$TranslationDuration,
        [bool]$TranslationSkipped,
        [TimeSpan]$TotalDuration
    )

    $transcriptionText = if ($TranscriptionSkipped) { "skipped" } else { Format-Duration -Duration $TranscriptionDuration }
    $translationText = if ($TranslationSkipped) { "skipped" } else { Format-Duration -Duration $TranslationDuration }

    Write-RunLog ""
    Write-RunLog "Timing summary:"
    Write-RunLog "  Transcription: $transcriptionText"
    Write-RunLog "  Translation:   $translationText"
    Write-RunLog "  Total:         $(Format-Duration -Duration $TotalDuration)"
}

function Send-CompletionEmail {
    param(
        [string]$Status,
        [string]$MediaPath,
        [string]$OutputFolder,
        [TimeSpan]$TotalDuration
    )

    $emailEnabledFromEnv = $env:ENABLE_EMAIL_NOTIFICATION -match "^(1|true|yes|on)$"
    if (-not $EnableEmailNotification -and -not $emailEnabledFromEnv) {
        return
    }

    $to = if (-not [string]::IsNullOrWhiteSpace($EmailTo)) { $EmailTo } else { $env:SMTP_TO }
    $from = if (-not [string]::IsNullOrWhiteSpace($EmailFrom)) { $EmailFrom } else { $env:SMTP_FROM }
    $server = if (-not [string]::IsNullOrWhiteSpace($SmtpServer)) { $SmtpServer } else { $env:SMTP_SERVER }
    $username = if (-not [string]::IsNullOrWhiteSpace($SmtpUsername)) { $SmtpUsername } else { $env:SMTP_USERNAME }
    $password = if (-not [string]::IsNullOrWhiteSpace($SmtpPassword)) { $SmtpPassword } else { $env:SMTP_PASSWORD }
    $port = if (-not [string]::IsNullOrWhiteSpace($env:SMTP_PORT) -and $SmtpPort -eq 587) { [int]$env:SMTP_PORT } else { $SmtpPort }
    $useSsl = if (-not [string]::IsNullOrWhiteSpace($env:SMTP_USE_SSL)) {
        $env:SMTP_USE_SSL -match "^(1|true|yes|on)$"
    }
    else {
        $SmtpUseSsl
    }

    if ([string]::IsNullOrWhiteSpace($from) -and -not [string]::IsNullOrWhiteSpace($username)) {
        $from = $username
    }

    if ([string]::IsNullOrWhiteSpace($to) -or [string]::IsNullOrWhiteSpace($from) -or [string]::IsNullOrWhiteSpace($server)) {
        Write-RunWarning "Email notification is enabled, but EmailTo/EmailFrom/SmtpServer is missing. Skipping email."
        return
    }

    $subject = "Faster Whisper job $Status"
    $body = @"
The Faster Whisper job has finished.

Status: $Status
Media: $MediaPath
Output folder: $OutputFolder
Total time: $(Format-Duration -Duration $TotalDuration)
Finished at: $((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))
"@

    $message = [System.Net.Mail.MailMessage]::new($from, $to, $subject, $body)
    $client = [System.Net.Mail.SmtpClient]::new($server, $port)
    $client.EnableSsl = $useSsl
    if (-not [string]::IsNullOrWhiteSpace($username)) {
        $client.Credentials = [System.Net.NetworkCredential]::new($username, $password)
    }

    try {
        $client.Send($message)
        Write-RunLog "Email notification sent to $to"
    }
    catch {
        Write-RunWarning "Could not send email notification: $($_.Exception.Message)"
    }
    finally {
        $message.Dispose()
        $client.Dispose()
    }
}

function Complete-MediaProcessing {
    param(
        [string]$Status,
        [string]$MediaPath,
        [string]$OutputFolder,
        [TimeSpan]$TranscriptionDuration,
        [bool]$TranscriptionSkipped,
        [TimeSpan]$TranslationDuration,
        [bool]$TranslationSkipped,
        [TimeSpan]$TotalDuration
    )

    Write-TimingSummary `
        -TranscriptionDuration $TranscriptionDuration `
        -TranscriptionSkipped $TranscriptionSkipped `
        -TranslationDuration $TranslationDuration `
        -TranslationSkipped $TranslationSkipped `
        -TotalDuration $TotalDuration

    Send-CompletionEmail `
        -Status $Status `
        -MediaPath $MediaPath `
        -OutputFolder $OutputFolder `
        -TotalDuration $TotalDuration
}

function Export-FasterWhisperFallback {
    param(
        $SourceSrt,
        $Transcript,
        [string]$OutputRoot,
        [string]$Stem,
        [string]$SafeLanguage
    )

    if ($SourceSrt) {
        $fallbackSrtPath = Join-Path $OutputRoot "$Stem.$SafeLanguage.srt"
        Copy-Item -LiteralPath $SourceSrt.FullName -Destination $fallbackSrtPath -Force
        Write-RunWarning "No translated text was produced. Exported Faster Whisper SRT instead: $fallbackSrtPath"
        return [pscustomobject]@{
            Path = $fallbackSrtPath
            Format = "srt"
        }
    }

    if ($Transcript) {
        $fallbackTextPath = Join-Path $OutputRoot "$Stem.$SafeLanguage.txt"
        Copy-Item -LiteralPath $Transcript.FullName -Destination $fallbackTextPath -Force
        Write-RunWarning "No translated text was produced. Exported Faster Whisper transcript instead: $fallbackTextPath"
        return [pscustomobject]@{
            Path = $fallbackTextPath
            Format = "txt"
        }
    }

    throw "No Faster Whisper output is available for fallback export."
}

function Copy-GeneratedOutputToTargetFolder {
    param(
        $File,
        [string]$TargetFolder
    )

    if (-not $File) {
        return $null
    }

    $targetPath = Join-Path $TargetFolder $File.Name
    if ($File.FullName -ne $targetPath) {
        Copy-Item -LiteralPath $File.FullName -Destination $targetPath -Force
        return Get-Item -LiteralPath $targetPath
    }

    return $File
}

function Resolve-Executable {
    param([string]$PathOrCommand)

    if (Test-Path -LiteralPath $PathOrCommand) {
        return (Resolve-Path -LiteralPath $PathOrCommand).Path
    }

    $savedPath = Get-SavedFasterWhisperPath
    if ($savedPath) {
        return $savedPath
    }

    $searchRoots = @($script:ScriptRoot, (Get-Location).Path) | Select-Object -Unique
    foreach ($root in $searchRoots) {
        $localMatch = Get-ChildItem -LiteralPath $root -Recurse -Filter "faster-whisper-xxl*.exe" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($localMatch) {
            Save-FasterWhisperPath -ExecutablePath $localMatch.FullName
            return $localMatch.FullName
        }
    }

    $command = Get-Command $PathOrCommand -ErrorAction SilentlyContinue
    if ($command) {
        Save-FasterWhisperPath -ExecutablePath $command.Source
        return $command.Source
    }

    Write-RunLog "Could not find faster-whisper-xxl.exe automatically. Please select it in the next window."
    $selectedPath = Select-FasterWhisperExecutable
    Save-FasterWhisperPath -ExecutablePath $selectedPath
    return (Resolve-Path -LiteralPath $selectedPath).Path
}

function Resolve-YtDlpExecutable {
    param([string]$PathOrCommand)

    if (Test-Path -LiteralPath $PathOrCommand) {
        Save-YtDlpPath -ExecutablePath $PathOrCommand
        return (Resolve-Path -LiteralPath $PathOrCommand).Path
    }

    $savedPath = Get-SavedYtDlpPath
    if ($savedPath) {
        return $savedPath
    }

    $searchRoots = @($script:ScriptRoot, (Get-Location).Path) | Select-Object -Unique
    foreach ($root in $searchRoots) {
        $localMatch = Get-ChildItem -LiteralPath $root -Recurse -Filter "yt-dlp*.exe" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($localMatch) {
            Save-YtDlpPath -ExecutablePath $localMatch.FullName
            return $localMatch.FullName
        }
    }

    $command = Get-Command $PathOrCommand -ErrorAction SilentlyContinue
    if ($command) {
        Save-YtDlpPath -ExecutablePath $command.Source
        return $command.Source
    }

    $localToolsFolder = Join-Path $script:ScriptRoot "tools"
    $downloadedYtDlp = Join-Path $localToolsFolder "yt-dlp.exe"
    try {
        Write-RunLog "yt-dlp.exe was not found. Downloading it into the app tools folder..."
        [void](New-Item -ItemType Directory -Force -Path $localToolsFolder)
        Invoke-WebRequest `
            -Uri "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe" `
            -OutFile $downloadedYtDlp `
            -UseBasicParsing
        if (Test-Path -LiteralPath $downloadedYtDlp) {
            Save-YtDlpPath -ExecutablePath $downloadedYtDlp
            return (Resolve-Path -LiteralPath $downloadedYtDlp).Path
        }
    }
    catch {
        Write-RunWarning "Could not download yt-dlp automatically: $($_.Exception.Message)"
    }

    Write-RunLog "Could not find yt-dlp.exe automatically. Please select it in the next window."
    $selectedPath = Select-YtDlpExecutable
    Save-YtDlpPath -ExecutablePath $selectedPath
    return (Resolve-Path -LiteralPath $selectedPath).Path
}

function Resolve-FfmpegFolder {
    $ffmpegCommand = Get-Command "ffmpeg.exe" -ErrorAction SilentlyContinue
    if ($ffmpegCommand) {
        return (Split-Path -Parent $ffmpegCommand.Source)
    }

    $localToolsFolder = Join-Path $script:ScriptRoot "tools"
    $localFfmpeg = Join-Path $localToolsFolder "ffmpeg.exe"
    if (Test-Path -LiteralPath $localFfmpeg) {
        return $localToolsFolder
    }

    $localFfmpegBin = Join-Path $localToolsFolder "ffmpeg\bin\ffmpeg.exe"
    if (Test-Path -LiteralPath $localFfmpegBin) {
        return (Split-Path -Parent $localFfmpegBin)
    }

    $existingMatch = Get-ChildItem -LiteralPath $localToolsFolder -Recurse -Filter "ffmpeg.exe" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($existingMatch) {
        return $existingMatch.DirectoryName
    }

    $archivePath = Join-Path $localToolsFolder "ffmpeg-release-essentials.zip"
    $extractFolder = Join-Path $localToolsFolder "ffmpeg-download"
    try {
        Write-RunLog "ffmpeg.exe was not found. Downloading it into the app tools folder..."
        [void](New-Item -ItemType Directory -Force -Path $localToolsFolder)
        Invoke-WebRequest `
            -Uri "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip" `
            -OutFile $archivePath `
            -UseBasicParsing

        if (Test-Path -LiteralPath $extractFolder) {
            Remove-Item -LiteralPath $extractFolder -Recurse -Force
        }
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractFolder -Force

        $downloadedFfmpeg = Get-ChildItem -LiteralPath $extractFolder -Recurse -Filter "ffmpeg.exe" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($downloadedFfmpeg) {
            return $downloadedFfmpeg.DirectoryName
        }
    }
    catch {
        Write-RunWarning "Could not download ffmpeg automatically: $($_.Exception.Message)"
    }

    return $null
}

function Resolve-PythonExecutable {
    $pythonCommand = Get-Command "python.exe" -ErrorAction SilentlyContinue
    if ($pythonCommand) {
        return $pythonCommand.Source
    }

    $pyCommand = Get-Command "py.exe" -ErrorAction SilentlyContinue
    if ($pyCommand) {
        return $pyCommand.Source
    }

    return $null
}

function Resolve-MossPythonExecutable {
    param([string]$RequestedPath = "")

    $candidates = @(
        $RequestedPath,
        (Join-Path $script:ScriptRoot ".venv-moss\Scripts\python.exe")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "The MOSS runtime was not found. Run Setup-MOSS.bat, then try again."
}

function Invoke-MossTranscription {
    param(
        [string]$PythonExecutable,
        [string]$MediaPath,
        [string]$OutputRoot,
        [string]$Model,
        [string]$MossDeviceName,
        [int]$MaxNewTokens
    )

    $adapterPath = Join-Path $script:ScriptRoot "tools\moss_transcribe.py"
    if (-not (Test-Path -LiteralPath $adapterPath -PathType Leaf)) {
        throw "The MOSS adapter was not found: $adapterPath"
    }

    $arguments = @(
        $adapterPath,
        $MediaPath,
        "--output-dir", $OutputRoot,
        "--model", $Model,
        "--device", $MossDeviceName,
        "--max-new-tokens", $MaxNewTokens
    )

    $mutex = [System.Threading.Mutex]::new($false, "Local\FasterWhisperAppMossTranscription")
    $lockTaken = $false
    try {
        Write-RunLog "Waiting for the local MOSS transcription slot..."
        try {
            $lockTaken = $mutex.WaitOne()
        }
        catch [System.Threading.AbandonedMutexException] {
            $lockTaken = $true
        }

        Write-RunLog "MOSS args: $($arguments -join ' ')"
        return Invoke-LoggedProcess -FilePath $PythonExecutable -Arguments $arguments -Utf8Output
    }
    finally {
        if ($lockTaken) {
            [void]$mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

function Invoke-VnaiGeminiTranscription {
    param(
        [string]$PythonExecutable,
        [string]$MediaPath,
        [string]$OutputRoot,
        [string]$Model,
        [string]$Language,
        [string]$ApiKey
    )
    $arguments = @(
        (Join-Path $script:ScriptRoot "tools\vnai_gemini_transcribe.py"),
        $MediaPath, "--output-dir", $OutputRoot, "--model", $Model,
        "--language", $(if ([string]::IsNullOrWhiteSpace($Language)) { "auto" } else { $Language })
    )
    $previousApiKey = $env:VNAIPRO_GEMINI_API_KEY
    try {
        $env:VNAIPRO_GEMINI_API_KEY = $ApiKey
        return Invoke-LoggedProcess -FilePath $PythonExecutable -Arguments $arguments -Utf8Output
    }
    finally {
        if ($null -eq $previousApiKey) {
            Remove-Item Env:\VNAIPRO_GEMINI_API_KEY -ErrorAction SilentlyContinue
        }
        else { $env:VNAIPRO_GEMINI_API_KEY = $previousApiKey }
    }
}

function ConvertTo-ElevenLabsLanguageCode {
    param([string]$Language)

    if ([string]::IsNullOrWhiteSpace($Language) -or $Language.Trim().ToLowerInvariant() -eq "auto") {
        return ""
    }

    $languageCodes = @{
        "english" = "eng"
        "en" = "eng"
        "eng" = "eng"
        "greek" = "ell"
        "el" = "ell"
        "ell" = "ell"
        "spanish" = "spa"
        "french" = "fra"
        "german" = "deu"
        "italian" = "ita"
        "portuguese" = "por"
    }
    $normalized = $Language.Trim().ToLowerInvariant()
    if ($languageCodes.ContainsKey($normalized)) {
        return $languageCodes[$normalized]
    }
    return $Language.Trim()
}

function Invoke-ElevenLabsTranscription {
    param(
        [string]$PythonExecutable,
        [string]$MediaPath,
        [string]$OutputRoot,
        [string]$Model,
        [int]$NumSpeakers,
        [string]$LanguageCode,
        [int]$AudioTrack,
        [string]$FfmpegExecutable,
        [string]$ApiKey
    )

    $adapterPath = Join-Path $script:ScriptRoot "tools\elevenlabs_transcribe.py"
    if (-not (Test-Path -LiteralPath $adapterPath -PathType Leaf)) {
        throw "The ElevenLabs adapter was not found: $adapterPath"
    }

    $arguments = @(
        $adapterPath,
        $MediaPath,
        "--output-dir", $OutputRoot,
        "--model", $Model,
        "--num-speakers", $NumSpeakers,
        "--audio-track", $AudioTrack,
        "--ffmpeg", $FfmpegExecutable
    )
    if (-not [string]::IsNullOrWhiteSpace($LanguageCode)) {
        $arguments += @("--language-code", $LanguageCode)
    }

    $previousApiKey = $env:ELEVENLABS_API_KEY
    try {
        $env:ELEVENLABS_API_KEY = $ApiKey
        return Invoke-LoggedProcess -FilePath $PythonExecutable -Arguments $arguments -Utf8Output
    }
    finally {
        if ($null -eq $previousApiKey) {
            Remove-Item Env:\ELEVENLABS_API_KEY -ErrorAction SilentlyContinue
        }
        else {
            $env:ELEVENLABS_API_KEY = $previousApiKey
        }
    }
}

function ConvertTo-ElevenLabsDubbingLanguageCode {
    param(
        [string]$Language,
        [bool]$AllowAuto = $false
    )

    if ([string]::IsNullOrWhiteSpace($Language)) {
        return $(if ($AllowAuto) { "auto" } else { "" })
    }

    $normalized = $Language.Trim().ToLowerInvariant()
    if ($AllowAuto -and $normalized -eq "auto") {
        return "auto"
    }

    $languageCodes = @{
        "english" = "en"
        "en" = "en"
        "eng" = "en"
        "greek" = "el"
        "el" = "el"
        "ell" = "el"
        "spanish" = "es"
        "es" = "es"
        "spa" = "es"
        "french" = "fr"
        "fr" = "fr"
        "fra" = "fr"
        "german" = "de"
        "de" = "de"
        "deu" = "de"
        "italian" = "it"
        "it" = "it"
        "ita" = "it"
        "portuguese" = "pt"
        "pt" = "pt"
        "por" = "pt"
    }
    if ($languageCodes.ContainsKey($normalized)) {
        return $languageCodes[$normalized]
    }
    return $Language.Trim()
}

function Invoke-ElevenLabsDubbing {
    param(
        [string]$PythonExecutable,
        [string]$MediaPath,
        [string]$OutputSrtPath,
        [string]$SourceSrtPath,
        [string]$SourceLanguageCode,
        [string]$TargetLanguageCode,
        [int]$NumSpeakers,
        [string]$ApiKey
    )

    $adapterPath = Join-Path $script:ScriptRoot "tools\elevenlabs_dubbing.py"
    if (-not (Test-Path -LiteralPath $adapterPath -PathType Leaf)) {
        throw "The ElevenLabs Dubbing adapter was not found: $adapterPath"
    }

    $arguments = @(
        $adapterPath,
        $MediaPath,
        "--output-srt", $OutputSrtPath,
        "--source-srt", $SourceSrtPath,
        "--source-language", $SourceLanguageCode,
        "--target-language", $TargetLanguageCode,
        "--num-speakers", $NumSpeakers
    )

    $previousApiKey = $env:ELEVENLABS_API_KEY
    try {
        $env:ELEVENLABS_API_KEY = $ApiKey
        return Invoke-LoggedProcess -FilePath $PythonExecutable -Arguments $arguments -Utf8Output
    }
    finally {
        if ($null -eq $previousApiKey) {
            Remove-Item Env:\ELEVENLABS_API_KEY -ErrorAction SilentlyContinue
        }
        else {
            $env:ELEVENLABS_API_KEY = $previousApiKey
        }
    }
}

function Remove-MossSpeakerLabelsFromSrt {
    param([string]$Srt)

    if ([string]::IsNullOrWhiteSpace($Srt)) {
        return $Srt
    }

    # Subtitle reflow can move a diarization label away from the beginning of
    # its cue. Remove label tokens anywhere in subtitle text, while requiring
    # the trailing colon so ordinary values such as "S01E02" stay untouched.
    return $Srt -replace "(?i)(?<![\p{L}\p{Nd}_])(?:\[?S\d{1,3}\]?|speaker[ \t]*\d+)[ \t]*:[ \t]*", ""
}

function Hide-SpeakerLabelsInSrtFile {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            $originalSrt = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
            $cleanSrt = Remove-MossSpeakerLabelsFromSrt -Srt $originalSrt
            if ($cleanSrt -ceq $originalSrt) {
                return $false
            }

            Set-Content -LiteralPath $Path -Value $cleanSrt -Encoding UTF8 -ErrorAction Stop
            return $true
        }
        catch {
            if ($attempt -eq 5) {
                Write-RunWarning "Could not hide speaker labels in the source SRT after 5 attempts: $($_.Exception.Message)"
                return $false
            }
            Start-Sleep -Milliseconds (200 * $attempt)
        }
    }

    return $false
}

function Get-VoiceGenderHintsFromAudio {
    param(
        [string]$MediaPath,
        [string]$SourceSrtPath
    )

    $classifierPath = Join-Path $script:ScriptRoot "tools\voice_gender_heuristic.py"
    if (-not (Test-Path -LiteralPath $classifierPath)) {
        Write-RunWarning "Voice gender detection script was not found: $classifierPath"
        return ""
    }

    $pythonExe = Resolve-PythonExecutable
    if (-not $pythonExe) {
        Write-RunWarning "Python was not found. Skipping voice gender detection."
        return ""
    }

    $ffmpegFolder = Resolve-FfmpegFolder
    if (-not $ffmpegFolder) {
        Write-RunWarning "ffmpeg was not found. Skipping voice gender detection."
        return ""
    }

    $ffmpegExe = Join-Path $ffmpegFolder "ffmpeg.exe"
    if (-not (Test-Path -LiteralPath $ffmpegExe)) {
        Write-RunWarning "ffmpeg.exe was not found in $ffmpegFolder. Skipping voice gender detection."
        return ""
    }

    $tempFolder = Join-Path $script:ScriptRoot "temp"
    [void](New-Item -ItemType Directory -Force -Path $tempFolder)
    $tempWav = Join-Path $tempFolder ("voice-gender-{0}.wav" -f ([guid]::NewGuid().ToString("N")))

    try {
        Write-RunLog "Preparing audio for voice gender detection..."
        $ffmpegArgs = @(
            "-y",
            "-hide_banner",
            "-loglevel", "error",
            "-i", $MediaPath,
            "-vn",
            "-ac", "1",
            "-ar", "16000",
            "-sample_fmt", "s16",
            $tempWav
        )
        $ffmpegExitCode = Invoke-LoggedProcess -FilePath $ffmpegExe -Arguments $ffmpegArgs
        if ($ffmpegExitCode -ne 0 -or -not (Test-Path -LiteralPath $tempWav)) {
            Write-RunWarning "Could not prepare WAV for voice gender detection."
            return ""
        }

        Write-RunLog "Estimating voice gender from audio pitch..."
        $output = New-Object System.Collections.Generic.List[string]
        $pythonExitCode = Invoke-LoggedProcess -FilePath $pythonExe -Arguments @($classifierPath, "--wav", $tempWav, "--srt", $SourceSrtPath) -OutputLines $output
        if ($pythonExitCode -ne 0) {
            Write-RunWarning "Voice gender detection failed: $($output -join ' ')"
            return ""
        }

        $hintText = ($output -join "`r`n").Trim()
        if ([string]::IsNullOrWhiteSpace($hintText) -or $hintText -match "No reliable cue-level") {
            Write-RunWarning "Voice gender detection did not find reliable cue-level hints."
            return ""
        }

        Write-RunLog "Voice gender detection produced cue-level hints."
        return $hintText
    }
    catch {
        Write-RunWarning "Voice gender detection failed: $($_.Exception.Message)"
        return ""
    }
    finally {
        if (Test-Path -LiteralPath $tempWav) {
            Remove-Item -LiteralPath $tempWav -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-YouTubeFormatSelector {
    param(
        [string]$Quality,
        [bool]$CanMerge
    )

    $qualityHeights = @{
        "2160p" = 2160
        "1440p" = 1440
        "1080p" = 1080
        "720p" = 720
        "480p" = 480
        "360p" = 360
    }

    if ($Quality -eq "Maximum") {
        if ($CanMerge) {
            # Prefer the broadly supported MP4 combination. YouTube often ranks
            # AV1/Opus above H.264/AAC, but those codecs can stutter or fail on
            # older phones, tablets, TVs, and hardware-decoder-only players.
            return "bestvideo[vcodec^=avc1]+bestaudio[acodec^=mp4a]/bestvideo[vcodec^=avc1]+bestaudio/best[ext=mp4][vcodec^=avc1]/bestvideo*+bestaudio/best"
        }

        return "best[ext=mp4][vcodec^=avc1][acodec^=mp4a]/best[ext=mp4]/best"
    }

    $height = $qualityHeights[$Quality]
    if ($CanMerge) {
        return "bestvideo[vcodec^=avc1][height<=$height]+bestaudio[acodec^=mp4a]/bestvideo[vcodec^=avc1][height<=$height]+bestaudio/best[ext=mp4][vcodec^=avc1][height<=$height]/bestvideo*[height<=$height]+bestaudio/best[height<=$height]"
    }

    return "best[height<=$height][ext=mp4][vcodec^=avc1][acodec^=mp4a]/best[height<=$height][ext=mp4]/best[height<=$height]/best"
}

function Save-YouTubeVideo {
    param(
        [string]$Url,
        [string]$YtDlpExecutable,
        [string]$DownloadFolder,
        [string]$Quality = "Maximum",
        [string]$CookiesFromBrowser = "",
        [string]$CookiesFile = ""
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        throw "No YouTube URL was provided."
    }

    [void](New-Item -ItemType Directory -Force -Path $DownloadFolder)
    $beforeDownload = Get-Date
    $outputTemplate = Join-Path $DownloadFolder "%(title).200B.%(ext)s"
    $pathOutputFile = Join-Path ([System.IO.Path]::GetTempPath()) ("faster-whisper-yt-dlp-{0}.tmp" -f [guid]::NewGuid().ToString("N"))
    $ffmpegFolder = Resolve-FfmpegFolder
    $nodeCommand = Get-Command "node.exe" -ErrorAction SilentlyContinue
    $formatSelector = Get-YouTubeFormatSelector -Quality $Quality -CanMerge ([bool]$ffmpegFolder)
    $ytDlpArgs = @(
        "--no-playlist",
        "--newline",
        "--windows-filenames",
        "--restrict-filenames",
        "-f", $formatSelector,
        "-o", $outputTemplate,
        "--print-to-file", "after_move:filepath", $pathOutputFile,
        $Url
    )
    if ($ffmpegFolder) {
        $ytDlpArgs = @("--ffmpeg-location", $ffmpegFolder, "--merge-output-format", "mp4") + $ytDlpArgs
    }
    if ($nodeCommand) {
        $ytDlpArgs = @("--js-runtimes", "node:$($nodeCommand.Source)") + $ytDlpArgs
    }
    if (-not [string]::IsNullOrWhiteSpace($CookiesFile)) {
        if (-not (Test-Path -LiteralPath $CookiesFile)) {
            throw "YouTube cookies file does not exist: $CookiesFile"
        }
        $ytDlpArgs = @("--cookies", (Resolve-Path -LiteralPath $CookiesFile).Path) + $ytDlpArgs
    }
    elseif (-not [string]::IsNullOrWhiteSpace($CookiesFromBrowser)) {
        $ytDlpArgs = @("--cookies-from-browser", $CookiesFromBrowser) + $ytDlpArgs
    }

    Write-RunLog "Downloading YouTube video..."
    Write-RunLog "yt-dlp: $YtDlpExecutable"
    if (-not [string]::IsNullOrWhiteSpace($CookiesFile)) {
        Write-RunLog "YouTube cookies file: $CookiesFile"
    }
    elseif (-not [string]::IsNullOrWhiteSpace($CookiesFromBrowser)) {
        Write-RunLog "YouTube cookies: $CookiesFromBrowser"
    }
    if ($ffmpegFolder) {
        Write-RunLog "ffmpeg: $ffmpegFolder"
        Write-RunLog "Quality: $Quality"
    }
    else {
        Write-RunLog "ffmpeg was not found, so yt-dlp will download a single-file format without merging."
    }
    $ytDlpExitCode = Invoke-LoggedProcess -FilePath $YtDlpExecutable -Arguments $ytDlpArgs
    if ($ytDlpExitCode -ne 0) {
        Remove-Item -LiteralPath $pathOutputFile -Force -ErrorAction SilentlyContinue
        throw "yt-dlp failed with exit code $ytDlpExitCode."
    }

    $mediaExtensions = @(".mp4", ".mkv", ".webm", ".mov", ".m4a", ".mp3", ".opus", ".wav", ".flac")
    $printedPath = @()
    if (Test-Path -LiteralPath $pathOutputFile) {
        $printedPath = @(Get-Content -LiteralPath $pathOutputFile |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
            ForEach-Object { [string]$_ } |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -Last 1)
        Remove-Item -LiteralPath $pathOutputFile -Force -ErrorAction SilentlyContinue
    }
    if ($printedPath.Count -gt 0) {
        $downloadedFile = Get-Item -LiteralPath $printedPath[-1]
    }
    else {
        $downloadedFile = $null
    }

    if (-not $downloadedFile) {
        $downloadedFile = Get-ChildItem -LiteralPath $DownloadFolder -File |
            Where-Object { $mediaExtensions -contains $_.Extension.ToLowerInvariant() -and $_.LastWriteTime -ge $beforeDownload.AddSeconds(-2) } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }

    if (-not $downloadedFile) {
        $downloadedFile = Get-ChildItem -LiteralPath $DownloadFolder -File |
            Where-Object { $mediaExtensions -contains $_.Extension.ToLowerInvariant() } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }

    if (-not $downloadedFile) {
        throw "yt-dlp finished, but no downloaded media file was found in $DownloadFolder."
    }

    Write-RunLog "Downloaded input: $($downloadedFile.FullName)"
    return $downloadedFile.FullName
}

function Split-TextForModel {
    param(
        [string]$Text,
        [int]$MaxChars
    )

    $chunks = New-Object System.Collections.Generic.List[string]
    $builder = New-Object System.Text.StringBuilder
    $lines = $Text -split "(\r?\n)"

    foreach ($line in $lines) {
        if (($builder.Length + $line.Length) -gt $MaxChars -and $builder.Length -gt 0) {
            $chunks.Add($builder.ToString())
            [void]$builder.Clear()
        }

        if ($line.Length -gt $MaxChars) {
            for ($i = 0; $i -lt $line.Length; $i += $MaxChars) {
                $length = [Math]::Min($MaxChars, $line.Length - $i)
                $chunks.Add($line.Substring($i, $length))
            }
        }
        else {
            [void]$builder.Append($line)
        }
    }

    if ($builder.Length -gt 0) {
        $chunks.Add($builder.ToString())
    }

    return $chunks
}

function Split-SrtForModel {
    param(
        [string]$Srt,
        [int]$MaxChars
    )

    $chunks = New-Object System.Collections.Generic.List[string]
    $builder = New-Object System.Text.StringBuilder
    $normalizedSrt = $Srt -replace "`r`n", "`n"
    $normalizedSrt = $normalizedSrt -replace "`r", "`n"
    $blocks = [regex]::Split($normalizedSrt.Trim(), "`n{2,}")

    foreach ($block in $blocks) {
        if ([string]::IsNullOrWhiteSpace($block)) {
            continue
        }

        $separator = if ($builder.Length -gt 0) { "`n`n" } else { "" }
        if (($builder.Length + $separator.Length + $block.Length) -gt $MaxChars -and $builder.Length -gt 0) {
            $chunks.Add($builder.ToString())
            [void]$builder.Clear()
            $separator = ""
        }

        if ($block.Length -gt $MaxChars) {
            $chunks.Add($block)
        }
        else {
            [void]$builder.Append($separator)
            [void]$builder.Append($block)
        }
    }

    if ($builder.Length -gt 0) {
        $chunks.Add($builder.ToString())
    }

    return $chunks
}

function Get-SrtCueBlocks {
    param([string]$Srt)

    $normalizedSrt = $Srt -replace "`r`n", "`n"
    $normalizedSrt = $normalizedSrt -replace "`r", "`n"
    return @([regex]::Split($normalizedSrt.Trim(), "`n{2,}") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-SrtCueParts {
    param([string]$Block)

    $lines = @($Block -split "`n")
    $timestampIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "\d{2}:\d{2}:\d{2},\d{3}\s+-->\s+\d{2}:\d{2}:\d{2},\d{3}") {
            $timestampIndex = $i
            break
        }
    }

    if ($timestampIndex -lt 0) {
        throw "Invalid SRT block without a timestamp line: $Block"
    }

    $number = if ($timestampIndex -gt 0) { $lines[$timestampIndex - 1].Trim() } else { "" }
    $timestamp = $lines[$timestampIndex].Trim()
    $textLines = @()
    if ($timestampIndex + 1 -lt $lines.Count) {
        $textLines = @($lines[($timestampIndex + 1)..($lines.Count - 1)])
    }

    return [pscustomobject]@{
        Number = $number
        Timestamp = $timestamp
        Text = ($textLines -join "`n").Trim()
    }
}

function Repair-TranslatedSrtStructure {
    param(
        [string]$SourceSrt,
        [string]$TranslatedSrt
    )

    $sourceBlocks = @(Get-SrtCueBlocks -Srt $SourceSrt)
    $translatedBlocks = @(Get-SrtCueBlocks -Srt $TranslatedSrt)
    if ($sourceBlocks.Count -ne $translatedBlocks.Count) {
        throw "Translated SRT cue count mismatch. Source has $($sourceBlocks.Count), translation has $($translatedBlocks.Count)."
    }

    $repairedBlocks = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $sourceBlocks.Count; $i++) {
        $sourceCue = Get-SrtCueParts -Block $sourceBlocks[$i]
        $translatedCue = Get-SrtCueParts -Block $translatedBlocks[$i]

        $text = $translatedCue.Text
        if ([string]::IsNullOrWhiteSpace($text)) {
            $text = $sourceCue.Text
        }

        $cueNumber = if ([string]::IsNullOrWhiteSpace($sourceCue.Number)) { [string]($i + 1) } else { $sourceCue.Number }
        $repairedBlocks.Add(($cueNumber, $sourceCue.Timestamp, $text) -join "`r`n")
    }

    return ($repairedBlocks -join "`r`n`r`n")
}

function Convert-SrtPairForQaPass {
    param(
        [string]$SourceSrt,
        [string]$TranslatedSrt
    )

    $sourceBlocks = @(Get-SrtCueBlocks -Srt $SourceSrt)
    $translatedBlocks = @(Get-SrtCueBlocks -Srt $TranslatedSrt)
    if ($sourceBlocks.Count -ne $translatedBlocks.Count) {
        throw "QA pass cue count mismatch. Source has $($sourceBlocks.Count), translation has $($translatedBlocks.Count)."
    }

    $pairedBlocks = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $sourceBlocks.Count; $i++) {
        $sourceCue = Get-SrtCueParts -Block $sourceBlocks[$i]
        $translatedCue = Get-SrtCueParts -Block $translatedBlocks[$i]
        $cueNumber = if ([string]::IsNullOrWhiteSpace($sourceCue.Number)) { [string]($i + 1) } else { $sourceCue.Number }
        $pairedBlocks.Add((@(
            $cueNumber,
            $sourceCue.Timestamp,
            "SOURCE:",
            $sourceCue.Text,
            "DRAFT:",
            $translatedCue.Text
        ) -join "`r`n"))
    }

    return ($pairedBlocks -join "`r`n`r`n")
}

function Convert-SrtBlocksToText {
    param([object[]]$Blocks)

    return ($Blocks -join "`r`n`r`n")
}

function Convert-SrtTimestampToSeconds {
    param([string]$Timestamp)

    if ($Timestamp -notmatch "^(?<h>\d{2}):(?<m>\d{2}):(?<s>\d{2}),(?<ms>\d{3})$") {
        throw "Invalid SRT timestamp: $Timestamp"
    }

    return ([int]$Matches.h * 3600) + ([int]$Matches.m * 60) + [int]$Matches.s + ([int]$Matches.ms / 1000.0)
}

function Convert-SecondsToSrtTimestamp {
    param([double]$Seconds)

    if ($Seconds -lt 0) {
        $Seconds = 0
    }

    $totalMilliseconds = [int][Math]::Round($Seconds * 1000)
    $hours = [Math]::Floor($totalMilliseconds / 3600000)
    $totalMilliseconds = $totalMilliseconds % 3600000
    $minutes = [Math]::Floor($totalMilliseconds / 60000)
    $totalMilliseconds = $totalMilliseconds % 60000
    $wholeSeconds = [Math]::Floor($totalMilliseconds / 1000)
    $milliseconds = $totalMilliseconds % 1000

    return "{0:00}:{1:00}:{2:00},{3:000}" -f $hours, $minutes, $wholeSeconds, $milliseconds
}

function Split-SubtitleTextForTiming {
    param(
        [string]$Text,
        [int]$TargetChars = 90
    )

    $singleLineText = ($Text -replace "\s+", " ").Trim()
    if ([string]::IsNullOrWhiteSpace($singleLineText)) {
        return @("")
    }

    $sentences = New-Object System.Collections.Generic.List[string]
    foreach ($match in [regex]::Matches($singleLineText, ".+?(?:[.!?;:]+(?:['"")\]]+)?(?=\s+|$)|$)")) {
        $sentence = $match.Value.Trim()
        if (-not [string]::IsNullOrWhiteSpace($sentence)) {
            $sentences.Add($sentence)
        }
    }

    if ($sentences.Count -gt 1) {
        $sentenceParts = New-Object System.Collections.Generic.List[string]
        foreach ($sentence in $sentences) {
            if ($sentence.Length -le $TargetChars) {
                $sentenceParts.Add($sentence)
                continue
            }

            $builder = New-Object System.Text.StringBuilder
            foreach ($word in ($sentence -split "\s+")) {
                $separator = if ($builder.Length -gt 0) { " " } else { "" }
                if (($builder.Length + $separator.Length + $word.Length) -gt $TargetChars -and $builder.Length -gt 0) {
                    $sentenceParts.Add($builder.ToString())
                    [void]$builder.Clear()
                    $separator = ""
                }

                [void]$builder.Append($separator)
                [void]$builder.Append($word)
            }

            if ($builder.Length -gt 0) {
                $sentenceParts.Add($builder.ToString())
            }
        }

        return @($sentenceParts)
    }

    $parts = New-Object System.Collections.Generic.List[string]
    $builder = New-Object System.Text.StringBuilder
    foreach ($word in ($singleLineText -split "\s+")) {
        $separator = if ($builder.Length -gt 0) { " " } else { "" }
        if (($builder.Length + $separator.Length + $word.Length) -gt $TargetChars -and $builder.Length -gt 0) {
            $parts.Add($builder.ToString())
            [void]$builder.Clear()
            $separator = ""
        }

        [void]$builder.Append($separator)
        [void]$builder.Append($word)
    }

    if ($builder.Length -gt 0) {
        $parts.Add($builder.ToString())
    }

    return @($parts)
}

function Split-SubtitleTextByWords {
    param(
        [string]$Text,
        [int]$TargetChars
    )

    $singleLineText = ($Text -replace "\s+", " ").Trim()
    if ([string]::IsNullOrWhiteSpace($singleLineText)) {
        return @("")
    }

    $parts = New-Object System.Collections.Generic.List[string]
    $builder = New-Object System.Text.StringBuilder
    foreach ($word in ($singleLineText -split "\s+")) {
        $separator = if ($builder.Length -gt 0) { " " } else { "" }
        if (($builder.Length + $separator.Length + $word.Length) -gt $TargetChars -and $builder.Length -gt 0) {
            $parts.Add($builder.ToString())
            [void]$builder.Clear()
            $separator = ""
        }

        [void]$builder.Append($separator)
        [void]$builder.Append($word)
    }

    if ($builder.Length -gt 0) {
        $parts.Add($builder.ToString())
    }

    return @($parts)
}

function Optimize-TranslatedSrtTiming {
    param(
        [string]$Srt,
        [double]$MinCueDurationSeconds,
        [double]$MaxCueDurationSeconds,
        [int]$MaxLineWidth,
        [int]$MaxLineCount
    )

    $sourceBlocks = @(Get-SrtCueBlocks -Srt $Srt)
    $cueObjects = New-Object System.Collections.Generic.List[object]

    foreach ($block in $sourceBlocks) {
        $cue = Get-SrtCueParts -Block $block
        if ($cue.Timestamp -notmatch "^(?<start>\d{2}:\d{2}:\d{2},\d{3})\s+-->\s+(?<end>\d{2}:\d{2}:\d{2},\d{3})") {
            continue
        }

        $startSeconds = Convert-SrtTimestampToSeconds -Timestamp $Matches.start
        $endSeconds = Convert-SrtTimestampToSeconds -Timestamp $Matches.end
        if ($endSeconds -le $startSeconds) {
            $endSeconds = $startSeconds + $MinCueDurationSeconds
        }

        $duration = $endSeconds - $startSeconds
        $textParts = @($cue.Text)
        $targetChars = [Math]::Max(40, $MaxLineWidth * $MaxLineCount)
        $singleLineCueText = ($cue.Text -replace "\s+", " ").Trim()
        if ($duration -gt $MaxCueDurationSeconds -or $singleLineCueText.Length -gt ($MaxLineWidth * $MaxLineCount)) {
            $textParts = @(Split-SubtitleTextByWords -Text $cue.Text -TargetChars $targetChars)
        }

        if ($textParts.Count -le 1) {
            $cueObjects.Add([pscustomobject]@{
                Start = $startSeconds
                End = [Math]::Min($endSeconds, $startSeconds + $MaxCueDurationSeconds)
                Text = $cue.Text
            })
            continue
        }

        $totalChars = 0
        foreach ($part in $textParts) {
            $totalChars += [Math]::Max(1, $part.Length)
        }

        $segmentStart = $startSeconds
        for ($i = 0; $i -lt $textParts.Count; $i++) {
            if ($i -eq $textParts.Count - 1) {
                $segmentEnd = $endSeconds
            }
            else {
                $share = [Math]::Max(1, $textParts[$i].Length) / [Math]::Max(1, $totalChars)
                $segmentEnd = $segmentStart + ($duration * $share)
            }

            if (($segmentEnd - $segmentStart) -gt $MaxCueDurationSeconds) {
                $segmentEnd = $segmentStart + $MaxCueDurationSeconds
            }

            $cueObjects.Add([pscustomobject]@{
                Start = $segmentStart
                End = $segmentEnd
                Text = $textParts[$i]
            })
            $segmentStart = $segmentEnd
        }
    }

    for ($i = 0; $i -lt $cueObjects.Count; $i++) {
        if (($cueObjects[$i].End - $cueObjects[$i].Start) -lt $MinCueDurationSeconds) {
            $desiredEnd = $cueObjects[$i].Start + $MinCueDurationSeconds
            if ($i -lt ($cueObjects.Count - 1)) {
                $desiredEnd = [Math]::Min($desiredEnd, $cueObjects[$i + 1].Start - 0.04)
            }

            if ($desiredEnd -gt $cueObjects[$i].Start) {
                $cueObjects[$i].End = $desiredEnd
            }
        }

        if (($cueObjects[$i].End - $cueObjects[$i].Start) -gt $MaxCueDurationSeconds) {
            $cueObjects[$i].End = $cueObjects[$i].Start + $MaxCueDurationSeconds
        }

        if ($i -lt ($cueObjects.Count - 1) -and $cueObjects[$i].End -gt ($cueObjects[$i + 1].Start - 0.04)) {
            $cueObjects[$i].End = [Math]::Max($cueObjects[$i].Start + 0.1, $cueObjects[$i + 1].Start - 0.04)
        }
    }

    $optimizedBlocks = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $cueObjects.Count; $i++) {
        $timestamp = "{0} --> {1}" -f `
            (Convert-SecondsToSrtTimestamp -Seconds $cueObjects[$i].Start),
            (Convert-SecondsToSrtTimestamp -Seconds $cueObjects[$i].End)
        $text = Format-SubtitleCueText -Text $cueObjects[$i].Text -MaxLineWidth $MaxLineWidth -MaxLineCount $MaxLineCount
        $optimizedBlocks.Add((([string]($i + 1)), $timestamp, $text) -join "`r`n")
    }

    return ($optimizedBlocks -join "`r`n`r`n")
}

function Format-SrtCueTextOnly {
    param(
        [string]$Srt,
        [int]$MaxLineWidth,
        [int]$MaxLineCount
    )

    $sourceBlocks = @(Get-SrtCueBlocks -Srt $Srt)
    $formattedBlocks = New-Object System.Collections.Generic.List[string]

    for ($i = 0; $i -lt $sourceBlocks.Count; $i++) {
        $cue = Get-SrtCueParts -Block $sourceBlocks[$i]
        $cueNumber = if ([string]::IsNullOrWhiteSpace($cue.Number)) { [string]($i + 1) } else { $cue.Number }
        $text = Format-SubtitleCueText -Text $cue.Text -MaxLineWidth $MaxLineWidth -MaxLineCount $MaxLineCount
        $formattedBlocks.Add(($cueNumber, $cue.Timestamp, $text) -join "`r`n")
    }

    return ($formattedBlocks -join "`r`n`r`n")
}

function Split-LongSrtCuesLocally {
    param(
        [string]$Srt,
        [double]$MaxCueDurationSeconds,
        [int]$MaxLineWidth,
        [int]$MaxLineCount
    )

    $sourceBlocks = @(Get-SrtCueBlocks -Srt $Srt)
    $outputBlocks = New-Object System.Collections.Generic.List[string]
    $cueNumber = 1

    foreach ($block in $sourceBlocks) {
        $cue = Get-SrtCueParts -Block $block
        if ($cue.Timestamp -notmatch "^(?<start>\d{2}:\d{2}:\d{2},\d{3})\s+-->\s+(?<end>\d{2}:\d{2}:\d{2},\d{3})") {
            throw "Invalid SRT timestamp line: $($cue.Timestamp)"
        }

        $startSeconds = Convert-SrtTimestampToSeconds -Timestamp $Matches.start
        $endSeconds = Convert-SrtTimestampToSeconds -Timestamp $Matches.end
        if ($endSeconds -le $startSeconds) {
            $endSeconds = $startSeconds + 0.1
        }

        $duration = $endSeconds - $startSeconds
        $textParts = @($cue.Text)
        $targetChars = [Math]::Max(36, $MaxLineWidth)
        $singleLineCueText = ($cue.Text -replace "\s+", " ").Trim()
        if ($duration -gt $MaxCueDurationSeconds -or $singleLineCueText.Length -gt ($MaxLineWidth * $MaxLineCount)) {
            $textParts = @(Split-SubtitleTextByWords -Text $cue.Text -TargetChars $targetChars)
        }

        if ($textParts.Count -le 1) {
            $formattedText = Format-SubtitleCueText -Text $cue.Text -MaxLineWidth $MaxLineWidth -MaxLineCount $MaxLineCount
            $outputBlocks.Add((([string]$cueNumber), $cue.Timestamp, $formattedText) -join "`r`n")
            $cueNumber++
            continue
        }

        $totalChars = 0
        foreach ($part in $textParts) {
            $totalChars += [Math]::Max(1, $part.Length)
        }

        $segmentStart = $startSeconds
        for ($i = 0; $i -lt $textParts.Count; $i++) {
            if ($i -eq $textParts.Count - 1) {
                $segmentEnd = $endSeconds
            }
            else {
                $share = [Math]::Max(1, $textParts[$i].Length) / [Math]::Max(1, $totalChars)
                $segmentEnd = $segmentStart + ($duration * $share)
                if ($segmentEnd -le $segmentStart) {
                    $segmentEnd = $segmentStart + 0.1
                }
            }

            $timestamp = "{0} --> {1}" -f `
                (Convert-SecondsToSrtTimestamp -Seconds $segmentStart),
                (Convert-SecondsToSrtTimestamp -Seconds $segmentEnd)
            $formattedText = Format-SubtitleCueText -Text $textParts[$i] -MaxLineWidth $MaxLineWidth -MaxLineCount $MaxLineCount
            $outputBlocks.Add((([string]$cueNumber), $timestamp, $formattedText) -join "`r`n")
            $cueNumber++
            $segmentStart = $segmentEnd
        }
    }

    return ($outputBlocks -join "`r`n`r`n")
}

function Repair-SrtDanglingCueEndings {
    param(
        [string]$Srt,
        [int]$MaxMovedWords = 5,
        [int]$MaxLineWidth,
        [int]$MaxLineCount
    )

    $danglingEndingPattern = "(?i)(?:\u03BD\u03B1|\u03B8\u03B1|\u03B4\u03B5\u03BD|\u03BC\u03B7|\u03BC\u03B7\u03BD|\u03C4\u03BF|\u03C4\u03B7|\u03C4\u03B7\u03BD|\u03C4\u03BF\u03BD|\u03C4\u03BF\u03C5\u03C2|\u03C4\u03B9\u03C2|\u03C4\u03B7\u03C2|\u03C4\u03BF\u03C5|\u03C4\u03C9\u03BD|\u03C3\u03C4\u03BF|\u03C3\u03C4\u03B7|\u03C3\u03C4\u03B7\u03BD|\u03C3\u03C4\u03BF\u03BD|\u03C3\u03B5|\u03BC\u03B5|\u03B3\u03B9\u03B1|\u03B1\u03C0\u03CC|\u03BA\u03B1\u03B9|\u03C0\u03BF\u03C5|\u03CC\u03C4\u03B9|\u03C0\u03C9\u03C2|\u03B5\u03AF\u03BD\u03B1\u03B9|\u03AE\u03C4\u03B1\u03BD|\u03AD\u03C7\u03BF\u03C5\u03BC\u03B5|\u03AD\u03C7\u03C9|\u03AD\u03BD\u03B1|\u03BC\u03B9\u03B1|\u03BF|\u03B7)\s*[^\p{L}\p{Nd}]*$"

    $sourceBlocks = @(Get-SrtCueBlocks -Srt $Srt)
    $cueObjects = New-Object System.Collections.Generic.List[object]

    foreach ($block in $sourceBlocks) {
        $cue = Get-SrtCueParts -Block $block
        if ($cue.Timestamp -notmatch "^(?<start>\d{2}:\d{2}:\d{2},\d{3})\s+-->\s+(?<end>\d{2}:\d{2}:\d{2},\d{3})") {
            throw "Invalid SRT timestamp line: $($cue.Timestamp)"
        }

        $cueObjects.Add([pscustomobject]@{
            StartSeconds = Convert-SrtTimestampToSeconds -Timestamp $Matches.start
            EndSeconds = Convert-SrtTimestampToSeconds -Timestamp $Matches.end
            Text = (($cue.Text -replace "\s+", " ").Trim())
            Remove = $false
        })
    }

    for ($i = 0; $i -lt ($cueObjects.Count - 1); $i++) {
        $currentCue = $cueObjects[$i]
        $nextCue = $cueObjects[$i + 1]
        if ($currentCue.Remove -or $nextCue.Remove) {
            continue
        }

        $currentText = ($currentCue.Text -replace "\s+", " ").Trim()
        $nextText = ($nextCue.Text -replace "\s+", " ").Trim()
        if ([string]::IsNullOrWhiteSpace($currentText) -or [string]::IsNullOrWhiteSpace($nextText)) {
            continue
        }

        $gapSeconds = $nextCue.StartSeconds - $currentCue.EndSeconds
        if ($gapSeconds -lt -0.001 -or $gapSeconds -gt 0.12) {
            continue
        }

        if ($currentText -notmatch $danglingEndingPattern) {
            continue
        }

        $moveText = ""
        $restText = ""
        if ($nextText -match "^(?<move>.+?[.!?;:\u2026]+[`"')\]]*)(?:\s+(?<rest>.+))?$") {
            $moveText = $Matches.move.Trim()
            $restText = if ($Matches.ContainsKey("rest") -and $Matches.rest) { $Matches.rest.Trim() } else { "" }
        }
        else {
            $words = @($nextText -split "\s+" | Where-Object { $_ })
            if ($words.Count -eq 0) {
                continue
            }

            $moveCount = [Math]::Min($MaxMovedWords, $words.Count)
            $moveText = (@($words | Select-Object -First $moveCount) -join " ").Trim()
            $restText = (@($words | Select-Object -Skip $moveCount) -join " ").Trim()
        }

        $movedWordCount = @($moveText -split "\s+" | Where-Object { $_ }).Count
        if ([string]::IsNullOrWhiteSpace($moveText) -or $movedWordCount -gt $MaxMovedWords) {
            continue
        }

        $nextDuration = [Math]::Max(0.1, $nextCue.EndSeconds - $nextCue.StartSeconds)
        $nextChars = [Math]::Max(1, $nextText.Length)
        $moveShare = [Math]::Min(0.85, [Math]::Max(0.15, $moveText.Length / $nextChars))
        $moveDuration = [Math]::Min(2.0, [Math]::Max(0.35, $nextDuration * $moveShare))
        $splitPoint = [Math]::Min($nextCue.EndSeconds, $nextCue.StartSeconds + $moveDuration)

        $currentCue.Text = (($currentText, $moveText) -join " ").Trim()
        $currentCue.EndSeconds = [Math]::Max($currentCue.EndSeconds, $splitPoint)

        if ([string]::IsNullOrWhiteSpace($restText)) {
            $nextCue.Remove = $true
        }
        else {
            $nextCue.Text = $restText
            $nextCue.StartSeconds = [Math]::Min($nextCue.EndSeconds - 0.1, $splitPoint + 0.04)
        }
    }

    $repairedBlocks = New-Object System.Collections.Generic.List[string]
    $cueNumber = 1
    foreach ($cueObject in $cueObjects) {
        if ($cueObject.Remove -or [string]::IsNullOrWhiteSpace($cueObject.Text)) {
            continue
        }

        $timestamp = "{0} --> {1}" -f `
            (Convert-SecondsToSrtTimestamp -Seconds $cueObject.StartSeconds),
            (Convert-SecondsToSrtTimestamp -Seconds $cueObject.EndSeconds)
        $formattedText = Format-SubtitleCueText -Text $cueObject.Text -MaxLineWidth $MaxLineWidth -MaxLineCount $MaxLineCount
        $repairedBlocks.Add((([string]$cueNumber), $timestamp, $formattedText) -join "`r`n")
        $cueNumber++
    }

    return ($repairedBlocks -join "`r`n`r`n")
}

function Split-SubtitleTextIntoSentences {
    param([string]$Text)

    $singleLineText = ($Text -replace "\s+", " ").Trim()
    if ([string]::IsNullOrWhiteSpace($singleLineText)) {
        return @()
    }

    $matches = [regex]::Matches($singleLineText, ".+?(?:[.!?]+(?:['"")\]]+)?(?=\s+|$)|$)")
    $sentences = New-Object System.Collections.Generic.List[string]
    foreach ($match in $matches) {
        $sentence = $match.Value.Trim()
        if (-not [string]::IsNullOrWhiteSpace($sentence)) {
            $sentences.Add($sentence)
        }
    }

    if ($sentences.Count -eq 0) {
        $sentences.Add($singleLineText)
    }

    return $sentences
}

function Format-SubtitleCueText {
    param(
        [string]$Text,
        [int]$MaxLineWidth,
        [int]$MaxLineCount
    )

    $singleLineText = ($Text -replace "\s+", " ").Trim()
    if ([string]::IsNullOrWhiteSpace($singleLineText) -or $MaxLineCount -le 1) {
        return $singleLineText
    }

    if ($MaxLineCount -ge 2) {
        $sentences = @(Split-SubtitleTextIntoSentences -Text $singleLineText)
        if ($sentences.Count -eq 2 -and
            $sentences[0].Length -le $MaxLineWidth -and
            $sentences[1].Length -le $MaxLineWidth) {
            return ($sentences[0], $sentences[1]) -join "`r`n"
        }
    }

    if ($singleLineText.Length -le $MaxLineWidth) {
        return $singleLineText
    }

    $preferredBreaks = New-Object System.Collections.Generic.List[int]
    foreach ($match in [regex]::Matches($singleLineText, "[,;:]\s+")) {
        $breakAt = $match.Index + 1
        if ($breakAt -ge 24 -and $breakAt -le $MaxLineWidth -and
            ($singleLineText.Length - $breakAt) -ge 8 -and
            ($singleLineText.Length - $breakAt) -le $MaxLineWidth) {
            $preferredBreaks.Add($breakAt)
        }
    }

    foreach ($match in [regex]::Matches($singleLineText, "\s+(?:how|what|why|when|where|who|with|as|and|but|while|after|before|because)\s+", "IgnoreCase")) {
        $breakAt = $match.Index
        if ($breakAt -ge 24 -and $breakAt -le $MaxLineWidth -and
            ($singleLineText.Length - $breakAt) -ge 8 -and
            ($singleLineText.Length - $breakAt) -le $MaxLineWidth) {
            $preferredBreaks.Add($breakAt)
        }
    }

    $target = [Math]::Min($MaxLineWidth, [Math]::Ceiling($singleLineText.Length / 2))
    $breakIndex = $null
    if ($preferredBreaks.Count -gt 0) {
        $breakIndex = $preferredBreaks |
            Sort-Object @{ Expression = { [Math]::Abs($_ - $target) } }, @{ Expression = { $_ } } |
            Select-Object -First 1
    }

    if ($null -eq $breakIndex) {
        $spaceMatches = @([regex]::Matches($singleLineText, "\s+"))
        $candidateSpaces = @(
            $spaceMatches |
                Where-Object { $_.Index -le $MaxLineWidth -and $_.Index -ge 24 -and ($singleLineText.Length - $_.Index) -le $MaxLineWidth } |
                Sort-Object Index -Descending |
                Select-Object -First 1
        )

        if ($candidateSpaces.Count -gt 0 -and $candidateSpaces[0]) {
            $breakIndex = $candidateSpaces[0].Index
        }
    }

    if ($null -eq $breakIndex -and $MaxLineCount -ge 2 -and $singleLineText.Length -le ($MaxLineWidth * 2)) {
        $balancedSpaces = @(
            [regex]::Matches($singleLineText, "\s+") |
                Where-Object {
                    $_.Index -gt 0 -and
                    $_.Index -le $MaxLineWidth -and
                    ($singleLineText.Length - ($_.Index + $_.Length)) -le $MaxLineWidth
                } |
                Sort-Object @{ Expression = { [Math]::Abs($_.Index - [Math]::Ceiling($singleLineText.Length / 2)) } } |
                Select-Object -First 1
        )

        if ($balancedSpaces.Count -gt 0 -and $balancedSpaces[0]) {
            $breakIndex = $balancedSpaces[0].Index
        }
    }

    if ($null -eq $breakIndex -or $breakIndex -le 0 -or $breakIndex -ge $singleLineText.Length) {
        return $singleLineText
    }

    $firstLine = $singleLineText.Substring(0, $breakIndex).Trim()
    $secondLine = $singleLineText.Substring($breakIndex).Trim()
    if ([string]::IsNullOrWhiteSpace($firstLine) -or [string]::IsNullOrWhiteSpace($secondLine)) {
        return $singleLineText
    }

    return ($firstLine, $secondLine) -join "`r`n"
}

function Test-SubtitleSentenceEnd {
    param([string]$Text)

    $trimmedText = ($Text -replace "\s+", " ").Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedText)) {
        return $true
    }

    return $trimmedText -match "[.!?;:\u2026]+[`"')\]]*$"
}

function Repair-SrtOrphanCuePrefixes {
    param(
        [string]$Srt,
        [int]$MaxPrefixWords = 2,
        [int]$MaxPrefixChars = 18,
        [double]$MaxPrefixGapSeconds = 0.12,
        [int]$MaxLineWidth,
        [int]$MaxLineCount
    )

    $sourceBlocks = @(Get-SrtCueBlocks -Srt $Srt)
    $cueObjects = New-Object System.Collections.Generic.List[object]

    foreach ($block in $sourceBlocks) {
        $cue = Get-SrtCueParts -Block $block
        if ($cue.Timestamp -notmatch "^(?<start>\d{2}:\d{2}:\d{2},\d{3})\s+-->\s+(?<end>\d{2}:\d{2}:\d{2},\d{3})") {
            throw "Invalid SRT timestamp line: $($cue.Timestamp)"
        }

        $cueObjects.Add([pscustomobject]@{
            StartSeconds = Convert-SrtTimestampToSeconds -Timestamp $Matches.start
            EndSeconds = Convert-SrtTimestampToSeconds -Timestamp $Matches.end
            Text = (($cue.Text -replace "\s+", " ").Trim())
            Remove = $false
        })
    }

    for ($i = 1; $i -lt $cueObjects.Count; $i++) {
        $previousCue = $cueObjects[$i - 1]
        $currentCue = $cueObjects[$i]
        if ($previousCue.Remove -or $currentCue.Remove) {
            continue
        }

        if (Test-SubtitleSentenceEnd -Text $previousCue.Text) {
            continue
        }

        $gapSeconds = $currentCue.StartSeconds - $previousCue.EndSeconds
        if ($gapSeconds -lt -0.001 -or $gapSeconds -gt $MaxPrefixGapSeconds) {
            continue
        }

        $currentText = ($currentCue.Text -replace "\s+", " ").Trim()
        if ([string]::IsNullOrWhiteSpace($currentText)) {
            continue
        }

        if ($currentText -notmatch "^(?<prefix>.{1,$MaxPrefixChars}?[.!?;:\u2026]+[`"')\]]*)(?:\s+(?<rest>.+))?$") {
            continue
        }

        $prefix = $Matches.prefix.Trim()
        $rest = if ($Matches.ContainsKey("rest") -and $Matches.rest) { $Matches.rest.Trim() } else { "" }
        $prefixWordCount = @($prefix -split "\s+" | Where-Object { $_ }).Count
        if ($prefixWordCount -gt $MaxPrefixWords -or $prefix -notmatch "^[\p{L}\p{Nd}'\u2019`"-]+[.!?;:\u2026]+[`"')\]]*$") {
            continue
        }

        $currentDuration = [Math]::Max(0.1, $currentCue.EndSeconds - $currentCue.StartSeconds)
        $currentChars = [Math]::Max(1, $currentText.Length)
        $prefixShare = [Math]::Min(0.85, [Math]::Max(0.15, $prefix.Length / $currentChars))
        $prefixDuration = [Math]::Min(1.5, [Math]::Max(0.35, $currentDuration * $prefixShare))
        $splitPoint = [Math]::Min($currentCue.EndSeconds, $currentCue.StartSeconds + $prefixDuration)

        $previousCue.Text = (($previousCue.Text, $prefix) -join " ").Trim()
        $previousCue.EndSeconds = [Math]::Max($previousCue.EndSeconds, $splitPoint)

        if ([string]::IsNullOrWhiteSpace($rest)) {
            $currentCue.Remove = $true
        }
        else {
            $currentCue.Text = $rest
            $currentCue.StartSeconds = [Math]::Min($currentCue.EndSeconds - 0.1, $splitPoint + 0.04)
        }
    }

    $repairedBlocks = New-Object System.Collections.Generic.List[string]
    $cueNumber = 1
    foreach ($cueObject in $cueObjects) {
        if ($cueObject.Remove -or [string]::IsNullOrWhiteSpace($cueObject.Text)) {
            continue
        }

        if ($cueObject.EndSeconds -le $cueObject.StartSeconds) {
            $cueObject.EndSeconds = $cueObject.StartSeconds + 0.1
        }

        $timestamp = "{0} --> {1}" -f `
            (Convert-SecondsToSrtTimestamp -Seconds $cueObject.StartSeconds),
            (Convert-SecondsToSrtTimestamp -Seconds $cueObject.EndSeconds)
        $formattedText = Format-SubtitleCueText -Text $cueObject.Text -MaxLineWidth $MaxLineWidth -MaxLineCount $MaxLineCount
        $repairedBlocks.Add((([string]$cueNumber), $timestamp, $formattedText) -join "`r`n")
        $cueNumber++
    }

    return ($repairedBlocks -join "`r`n`r`n")
}

function Repair-SrtTrailingCueStartFragments {
    param(
        [string]$Srt,
        [int]$MaxFragmentWords = 2,
        [int]$MaxFragmentChars = 22,
        [double]$MaxFragmentDurationSeconds = 1.2,
        [int]$MaxLineWidth,
        [int]$MaxLineCount
    )

    $sourceBlocks = @(Get-SrtCueBlocks -Srt $Srt)
    $cueObjects = New-Object System.Collections.Generic.List[object]

    foreach ($block in $sourceBlocks) {
        $cue = Get-SrtCueParts -Block $block
        if ($cue.Timestamp -notmatch "^(?<start>\d{2}:\d{2}:\d{2},\d{3})\s+-->\s+(?<end>\d{2}:\d{2}:\d{2},\d{3})") {
            throw "Invalid SRT timestamp line: $($cue.Timestamp)"
        }

        $cueObjects.Add([pscustomobject]@{
            StartSeconds = Convert-SrtTimestampToSeconds -Timestamp $Matches.start
            EndSeconds = Convert-SrtTimestampToSeconds -Timestamp $Matches.end
            Text = (($cue.Text -replace "\s+", " ").Trim())
            Remove = $false
        })
    }

    for ($i = 0; $i -lt ($cueObjects.Count - 1); $i++) {
        $currentCue = $cueObjects[$i]
        $nextCue = $cueObjects[$i + 1]
        if ($currentCue.Remove -or $nextCue.Remove) {
            continue
        }

        $currentText = ($currentCue.Text -replace "\s+", " ").Trim()
        $nextText = ($nextCue.Text -replace "\s+", " ").Trim()
        if ([string]::IsNullOrWhiteSpace($currentText) -or [string]::IsNullOrWhiteSpace($nextText)) {
            continue
        }

        if ($currentText -notmatch "^(?<complete>.+?[.!?;:\u2026]+[`"')\]]?)\s+(?<fragment>[\p{L}\p{Nd}'\u2019`"-]+(?:\s+[\p{L}\p{Nd}'\u2019`"-]+){0,$($MaxFragmentWords - 1)})$") {
            continue
        }

        $completeText = $Matches.complete.Trim()
        $fragment = $Matches.fragment.Trim()
        if ([string]::IsNullOrWhiteSpace($completeText) -or [string]::IsNullOrWhiteSpace($fragment)) {
            continue
        }

        if ($fragment.Length -gt $MaxFragmentChars) {
            continue
        }

        $fragmentWordCount = @($fragment -split "\s+" | Where-Object { $_ }).Count
        if ($fragmentWordCount -gt $MaxFragmentWords) {
            continue
        }

        $currentDuration = [Math]::Max(0.10, $currentCue.EndSeconds - $currentCue.StartSeconds)
        if ($currentDuration -lt 0.70) {
            continue
        }

        $fragmentShare = [Math]::Min(0.45, [Math]::Max(0.12, $fragment.Length / [Math]::Max(1, $currentText.Length)))
        $fragmentDuration = [Math]::Min($MaxFragmentDurationSeconds, [Math]::Max(0.25, $currentDuration * $fragmentShare))
        $splitPoint = $currentCue.EndSeconds - $fragmentDuration
        if ($splitPoint -le ($currentCue.StartSeconds + 0.25)) {
            continue
        }

        $currentCue.Text = $completeText
        $currentCue.EndSeconds = $splitPoint
        $nextCue.Text = (($fragment, $nextText) -join " ").Trim()
        $nextCue.StartSeconds = [Math]::Min($nextCue.StartSeconds, $splitPoint + 0.04)
    }

    $repairedBlocks = New-Object System.Collections.Generic.List[string]
    $cueNumber = 1
    foreach ($cueObject in $cueObjects) {
        if ($cueObject.Remove -or [string]::IsNullOrWhiteSpace($cueObject.Text)) {
            continue
        }

        if ($cueObject.EndSeconds -le $cueObject.StartSeconds) {
            $cueObject.EndSeconds = $cueObject.StartSeconds + 0.10
        }

        $timestamp = "{0} --> {1}" -f `
            (Convert-SecondsToSrtTimestamp -Seconds $cueObject.StartSeconds),
            (Convert-SecondsToSrtTimestamp -Seconds $cueObject.EndSeconds)
        $formattedText = Format-SubtitleCueText -Text $cueObject.Text -MaxLineWidth $MaxLineWidth -MaxLineCount $MaxLineCount
        $repairedBlocks.Add((([string]$cueNumber), $timestamp, $formattedText) -join "`r`n")
        $cueNumber++
    }

    return ($repairedBlocks -join "`r`n`r`n")
}

function Test-TranslationLooksLikeTargetLanguage {
    param(
        [string]$Text,
        [string]$TargetLanguage
    )

    if ($TargetLanguage -notmatch "^(?i:Greek)$") {
        return $true
    }

    $plainText = $Text `
        -replace "\d{2}:\d{2}:\d{2},\d{3}\s+-->\s+\d{2}:\d{2}:\d{2},\d{3}", " " `
        -replace "(?m)^\s*\d+\s*$", " "
    $greekLetterCount = [regex]::Matches($plainText, "[\u0370-\u03FF\u1F00-\u1FFF]").Count
    $latinLetterCount = [regex]::Matches($plainText, "[A-Za-z]").Count
    $letterCount = $greekLetterCount + $latinLetterCount

    if ($letterCount -lt 20) {
        return $greekLetterCount -gt 0
    }

    return $greekLetterCount -ge 20 -and $greekLetterCount -ge ([Math]::Ceiling($latinLetterCount * 0.25))
}

function Split-SubtitleSentencesIntoCueGroups {
    param(
        [string[]]$Sentences,
        [int]$MaxSentencesPerCue = 2
    )

    $groups = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Sentences.Count; $i += $MaxSentencesPerCue) {
        $groupSentences = @($Sentences | Select-Object -Skip $i -First $MaxSentencesPerCue)
        $groupText = ($groupSentences -join " ").Trim()
        if (-not [string]::IsNullOrWhiteSpace($groupText)) {
            $groups.Add($groupText)
        }
    }

    return @($groups)
}

function Normalize-SrtCueFlow {
    param(
        [string]$Srt,
        [double]$MaxCueDurationSeconds,
        [double]$SentenceMaxGapSeconds,
        [int]$MaxLineWidth,
        [int]$MaxLineCount
    )

    $sourceBlocks = @(Get-SrtCueBlocks -Srt $Srt)
    $normalizedBlocks = New-Object System.Collections.Generic.List[string]
    $cueNumber = 1
    $pendingCue = $null

    foreach ($block in $sourceBlocks) {
        $cue = Get-SrtCueParts -Block $block
        if ($cue.Timestamp -notmatch "^(?<start>\d{2}:\d{2}:\d{2},\d{3})\s+-->\s+(?<end>\d{2}:\d{2}:\d{2},\d{3})") {
            throw "Invalid SRT timestamp line: $($cue.Timestamp)"
        }

        $cueObject = [pscustomobject]@{
            StartSeconds = Convert-SrtTimestampToSeconds -Timestamp $Matches.start
            EndSeconds = Convert-SrtTimestampToSeconds -Timestamp $Matches.end
            Text = $cue.Text
        }

        if ($null -eq $pendingCue) {
            $pendingCue = $cueObject
            continue
        }

        $gapSeconds = $cueObject.StartSeconds - $pendingCue.EndSeconds
        $shouldJoin = $gapSeconds -ge 0 -and
            $gapSeconds -le $SentenceMaxGapSeconds -and
            -not (Test-SubtitleSentenceEnd -Text $pendingCue.Text)

        if ($shouldJoin) {
            $pendingCue.Text = (($pendingCue.Text, $cueObject.Text) -join " ").Trim()
            $pendingCue.EndSeconds = $cueObject.EndSeconds
            continue
        }

        $startSeconds = $pendingCue.StartSeconds
        $endSeconds = $pendingCue.EndSeconds
        $duration = [Math]::Max(0.1, $endSeconds - $startSeconds)
        $sentences = @(Split-SubtitleTextIntoSentences -Text $pendingCue.Text)

        if ($sentences.Count -le 1 -or ($duration -le $MaxCueDurationSeconds -and $sentences.Count -le 2)) {
            $timestamp = "{0} --> {1}" -f (Convert-SecondsToSrtTimestamp -Seconds $startSeconds), (Convert-SecondsToSrtTimestamp -Seconds $endSeconds)
            $formattedText = Format-SubtitleCueText -Text $pendingCue.Text -MaxLineWidth $MaxLineWidth -MaxLineCount $MaxLineCount
            $normalizedBlocks.Add((([string]$cueNumber), $timestamp, $formattedText) -join "`r`n")
            $cueNumber++
            $pendingCue = $cueObject
            continue
        }

        $cueGroups = @(Split-SubtitleSentencesIntoCueGroups -Sentences $sentences -MaxSentencesPerCue 2)
        $totalChars = 0
        foreach ($cueGroup in $cueGroups) {
            $totalChars += [Math]::Max(1, $cueGroup.Length)
        }

        $segmentStart = $startSeconds
        for ($i = 0; $i -lt $cueGroups.Count; $i++) {
            if ($i -eq $cueGroups.Count - 1) {
                $segmentEnd = $endSeconds
            }
            else {
                $share = [Math]::Max(1, $cueGroups[$i].Length) / [Math]::Max(1, $totalChars)
                $segmentEnd = $segmentStart + ($duration * $share)
                if ($segmentEnd -le $segmentStart) {
                    $segmentEnd = $segmentStart + 0.1
                }
            }

            $timestamp = "{0} --> {1}" -f (Convert-SecondsToSrtTimestamp -Seconds $segmentStart), (Convert-SecondsToSrtTimestamp -Seconds $segmentEnd)
            $formattedText = Format-SubtitleCueText -Text $cueGroups[$i] -MaxLineWidth $MaxLineWidth -MaxLineCount $MaxLineCount
            $normalizedBlocks.Add((([string]$cueNumber), $timestamp, $formattedText) -join "`r`n")
            $cueNumber++
            $segmentStart = $segmentEnd
        }

        $pendingCue = $cueObject
    }

    if ($null -ne $pendingCue) {
        $startSeconds = $pendingCue.StartSeconds
        $endSeconds = $pendingCue.EndSeconds
        $duration = [Math]::Max(0.1, $endSeconds - $startSeconds)
        $sentences = @(Split-SubtitleTextIntoSentences -Text $pendingCue.Text)

        if ($sentences.Count -le 1 -or ($duration -le $MaxCueDurationSeconds -and $sentences.Count -le 2)) {
            $timestamp = "{0} --> {1}" -f (Convert-SecondsToSrtTimestamp -Seconds $startSeconds), (Convert-SecondsToSrtTimestamp -Seconds $endSeconds)
            $formattedText = Format-SubtitleCueText -Text $pendingCue.Text -MaxLineWidth $MaxLineWidth -MaxLineCount $MaxLineCount
            $normalizedBlocks.Add((([string]$cueNumber), $timestamp, $formattedText) -join "`r`n")
        }
        else {
            $cueGroups = @(Split-SubtitleSentencesIntoCueGroups -Sentences $sentences -MaxSentencesPerCue 2)
            $totalChars = 0
            foreach ($cueGroup in $cueGroups) {
                $totalChars += [Math]::Max(1, $cueGroup.Length)
            }

            $segmentStart = $startSeconds
            for ($i = 0; $i -lt $cueGroups.Count; $i++) {
                if ($i -eq $cueGroups.Count - 1) {
                    $segmentEnd = $endSeconds
                }
                else {
                    $share = [Math]::Max(1, $cueGroups[$i].Length) / [Math]::Max(1, $totalChars)
                    $segmentEnd = $segmentStart + ($duration * $share)
                    if ($segmentEnd -le $segmentStart) {
                        $segmentEnd = $segmentStart + 0.1
                    }
                }

                $timestamp = "{0} --> {1}" -f (Convert-SecondsToSrtTimestamp -Seconds $segmentStart), (Convert-SecondsToSrtTimestamp -Seconds $segmentEnd)
                $formattedText = Format-SubtitleCueText -Text $cueGroups[$i] -MaxLineWidth $MaxLineWidth -MaxLineCount $MaxLineCount
                $normalizedBlocks.Add((([string]$cueNumber), $timestamp, $formattedText) -join "`r`n")
                $cueNumber++
                $segmentStart = $segmentEnd
            }
        }
    }

    return ($normalizedBlocks -join "`r`n`r`n")
}

function Repair-Utf8ApiText {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text) -or $Text -notmatch "[\u00C2\u00C3\u00CE\u00CF]") {
        return $Text
    }

    try {
        $latin1 = [System.Text.Encoding]::GetEncoding(28591)
        $decoded = [System.Text.Encoding]::UTF8.GetString($latin1.GetBytes($Text))
        if ($decoded -match [char]0xFFFD) {
            return $Text
        }

        $originalGreekCount = [regex]::Matches($Text, "[\u0370-\u03FF\u1F00-\u1FFF]").Count
        $decodedGreekCount = [regex]::Matches($decoded, "[\u0370-\u03FF\u1F00-\u1FFF]").Count
        $originalMarkerCount = [regex]::Matches($Text, "[\u00C2\u00C3\u00CE\u00CF]").Count
        $decodedMarkerCount = [regex]::Matches($decoded, "[\u00C2\u00C3\u00CE\u00CF]").Count
        if ($decodedGreekCount -gt $originalGreekCount -or $decodedMarkerCount -lt $originalMarkerCount) {
            return $decoded
        }
    }
    catch {
    }

    return $Text
}

function Get-OpenAIText {
    param($Response)

    if ($Response.PSObject.Properties.Name -contains "candidates" -and $Response.candidates) {
        $candidate = $Response.candidates | Select-Object -First 1
        if ($candidate.PSObject.Properties.Name -contains "content" -and
            $candidate.content.PSObject.Properties.Name -contains "parts") {
            $parts = New-Object System.Collections.Generic.List[string]
            foreach ($part in $candidate.content.parts) {
                if ($part.PSObject.Properties.Name -contains "text" -and $part.text) {
                    $parts.Add([string]$part.text)
                }
            }

            if ($parts.Count -gt 0) {
                return (Repair-Utf8ApiText -Text ($parts -join ""))
            }
        }
    }

    if ($Response.PSObject.Properties.Name -contains "choices" -and $Response.choices) {
        $choice = $Response.choices | Select-Object -First 1
        if ($choice.PSObject.Properties.Name -contains "message" -and
            $choice.message.PSObject.Properties.Name -contains "content" -and
            $choice.message.content) {
            return (Repair-Utf8ApiText -Text ([string]$choice.message.content))
        }
    }

    if ($Response.PSObject.Properties.Name -contains "output_text" -and $Response.output_text) {
        return (Repair-Utf8ApiText -Text ([string]$Response.output_text))
    }

    $parts = New-Object System.Collections.Generic.List[string]
    if ($Response.PSObject.Properties.Name -contains "output") {
        foreach ($item in $Response.output) {
            if ($item.PSObject.Properties.Name -contains "content") {
                foreach ($content in $item.content) {
                    if ($content.PSObject.Properties.Name -contains "text" -and $content.text) {
                        $parts.Add([string]$content.text)
                    }
                }
            }
        }
    }

    if ($parts.Count -eq 0) {
        throw "The translation API response did not contain text output."
    }

    return (Repair-Utf8ApiText -Text ($parts -join ""))
}

function Protect-SensitiveApiErrorText {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    # Providers sometimes echo a rejected secret (or a masked fragment) in a
    # JSON error. Keep that out of the run log and the on-screen warning.
    return ($Text -replace '(?i)sk[-_][A-Za-z0-9*._-]{6,}', '[REDACTED_API_KEY]')
}

function Get-RestErrorMessage {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    $message = $ErrorRecord.Exception.Message
    $errorDetailsText = if ($null -ne $ErrorRecord.ErrorDetails) { [string]$ErrorRecord.ErrorDetails.Message } else { "" }
    if (-not [string]::IsNullOrWhiteSpace($errorDetailsText)) {
        try {
            $errorPayload = $errorDetailsText | ConvertFrom-Json
            $detail = $errorPayload.error
            if (-not $detail) {
                $detail = $errorPayload.detail
            }
            if ($detail) {
                $detailMessage = [string]$detail.message
                $detailCode = [string]$detail.code
                if ($detailCode -match '(?i)^invalid_api_key$' -or $detailMessage -match '(?i)invalid api key|incorrect api key') {
                    return "$message API key rejected (invalid_api_key). Use Change translation API key and enter a current key for this provider."
                }
                if (-not [string]::IsNullOrWhiteSpace($detailMessage)) {
                    if (-not [string]::IsNullOrWhiteSpace($detailCode)) {
                        return (Protect-SensitiveApiErrorText "$message API error [$detailCode]: $detailMessage")
                    }
                    return (Protect-SensitiveApiErrorText "$message API error: $detailMessage")
                }
            }
        }
        catch {
        }

        return (Protect-SensitiveApiErrorText "$message $errorDetailsText")
    }

    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response) {
        return $message
    }

    try {
        $stream = $response.GetResponseStream()
        if ($null -eq $stream) {
            return $message
        }

        $reader = New-Object System.IO.StreamReader($stream)
        try {
            $body = $reader.ReadToEnd()
        }
        finally {
            $reader.Dispose()
        }

        if (-not [string]::IsNullOrWhiteSpace($body)) {
            return (Protect-SensitiveApiErrorText "$message $body")
        }
    }
    catch {
    }

    return (Protect-SensitiveApiErrorText $message)
}

function Wait-RestApiRetry {
    param(
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [int]$Attempt
    )

    $errorMessage = Get-RestErrorMessage -ErrorRecord $ErrorRecord
    if ($errorMessage -match "(?i)insufficient_quota|credit[_ -]?balance|balance[_ -]?too[_ -]?low|billing[_ -]?hard[_ -]?limit|billing_not_active") {
        throw $errorMessage
    }

    $statusCode = 0
    try {
        $statusCode = [int]$ErrorRecord.Exception.Response.StatusCode
    }
    catch {
    }

    $delaySeconds = if ($statusCode -eq 429) {
        [Math]::Min(30, 5 * [Math]::Pow(2, $Attempt - 1))
    }
    elseif ($statusCode -in @(502, 503, 504) -or $errorMessage -match '(?i)system_cpu_overloaded|server overloaded|service unavailable') {
        [Math]::Min(60, 15 * [Math]::Pow(2, $Attempt - 1))
    }
    else {
        [Math]::Min(20, 2 * $Attempt)
    }

    Write-RunWarning "API request failed (HTTP $statusCode). Retrying in $delaySeconds seconds (attempt $($Attempt + 1)/3)..."
    Start-Sleep -Seconds $delaySeconds
}

function ConvertTo-TranslationJsonBody {
    param($Payload)

    $json = $Payload | ConvertTo-Json -Depth 12 -Compress
    $json = $json -replace "[\u0000-\u0008\u000B\u000C\u000E-\u001F]", ""
    return $json
}

function Get-SubtitleDomainGuidance {
    param(
        [string]$TargetLanguage,
        [bool]$EnableAutoGenderInference = $false,
        [string]$SubtitleContextHints = ""
    )

    $autoGenderGuidance = ""
    if ($EnableAutoGenderInference) {
        $autoGenderGuidance = @"

Automatic gender inference:
- Infer speaker gender conservatively from source evidence: speaker labels, names, titles, pronouns, visual/context references in the transcript, and surrounding cues.
- Apply inferred gender consistently only while the same speaker/context remains clear.
- Do not infer gender from stereotypes, topic, occupation, or voice-like wording alone.
- When the evidence is ambiguous, prefer Greek wording that avoids explicit gender instead of guessing.
- During QA, specifically check whether first-person Greek forms match the inferred speaker gender.
"@
    }

    $customGuidance = ""
    if (-not [string]::IsNullOrWhiteSpace($SubtitleContextHints)) {
        $customGuidance = @"

User-provided context/gender hints:
$SubtitleContextHints
"@
    }

    return @"
Domain/style guidance:
- Use the source context and the user-provided hints to choose Greek gender correctly.
- For Greek, check gender agreement in pronouns, adjectives, participles, professions, and self-references.
- Gender-sensitive English source patterns include: I am ready/sure/happy/upset/tired/proud/excited, I felt ready/sure, I was ready/sure/happy/tired/proud.
- If the speaker's gender is unknown, avoid inventing gender where natural Greek can stay neutral.
- If the source clearly identifies a female speaker, use feminine forms for first-person lines by that speaker.
- If the source clearly identifies a male speaker, use masculine forms for first-person lines by that speaker.
- Do not carry a speaker gender across a reporter question or a new speaker unless the source makes that speaker clear.
- In interview clips, reporter questions and player answers may alternate. Apply player gender hints to player answers, not automatically to reporter questions.
- In this basketball context, "Yukon" is almost certainly "UConn"; render it as UConn.
- Keep league/team/event names natural: Liberty, Wings, WNBA, All-Star break, UConn.
- "back-to-back" means consecutive games; prefer Greek wording unless the English term is clearly better.
- "shootaround" means pregame light practice/shootaround; do not translate it as waking up.
- Prefer natural subtitle Greek over literal word-for-word translation.
$autoGenderGuidance
$customGuidance
"@
}

function Get-AutoSubtitleContextHints {
    param(
        [string]$MediaName,
        [string]$ExistingHints = ""
    )

    $hints = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($ExistingHints)) {
        $hints.Add($ExistingHints.Trim())
    }

    $lowerName = if ($MediaName) { $MediaName.ToLowerInvariant() } else { "" }
    if ($lowerName -match "azzi[\s._-]+fudd") {
        $hints.Add("Speaker/person Azzi Fudd is female. Use feminine Greek forms only when Azzi speaks about herself.")
        $hints.Add("This may be an interview clip: keep reporter questions gender-neutral unless the reporter gender is explicit.")
    }

    if ($lowerName -match "li[\s._-]+yueru") {
        $hints.Add("Speaker/person Li Yueru is female. Use feminine Greek forms only when Li speaks about herself.")
    }

    if ($lowerName -match "paige[\s._-]+bueckers") {
        $hints.Add("Speaker/person Paige Bueckers is female. Use feminine Greek forms only when Paige speaks about herself.")
    }

    if ($lowerName -match "wnba|liberty|wings|uconn") {
        $hints.Add("WNBA/player context: named players in the clip are often female, but do not apply feminine forms to reporters or unknown speakers without source evidence.")
    }

    return (($hints | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "`r`n")
}

function Test-FeminineFirstPersonContext {
    param([string]$SubtitleContextHints)

    if ([string]::IsNullOrWhiteSpace($SubtitleContextHints)) {
        return $false
    }

    $lowerHints = $SubtitleContextHints.ToLowerInvariant()
    return (
        $lowerHints -match "\bfemale\b" -or
        $lowerHints -match "\bfeminine\b" -or
        $lowerHints -match "\bwoman\b" -or
        $lowerHints -match "\bwomen\b" -or
        $lowerHints -match "\bshe\b" -or
        $lowerHints -match "\bher\b" -or
        $lowerHints -match "azzi[\s._-]+fudd" -or
        $lowerHints -match "li[\s._-]+yueru" -or
        $lowerHints -match "paige[\s._-]+bueckers"
    )
}

function Apply-SubtitleTextFixups {
    param(
        [string]$Srt,
        [string]$TargetLanguage,
        [string]$SubtitleContextHints = ""
    )

    if ($TargetLanguage -notmatch "^(?i:Greek)$") {
        return $Srt
    }

    $fixed = $Srt
    $fixed = $fixed -replace "\bYukon\b", "UConn"
    $fixed = $fixed -replace "\bUconn\b", "UConn"
    $movieBoxOffice = [regex]::Unescape("\u03BA\u03B9\u03BD\u03B7\u03BC\u03B1\u03C4\u03BF\u03B3\u03C1\u03B1\u03C6\u03B9\u03BA\u03AC \u03C4\u03B1\u03BC\u03B5\u03AF\u03B1")
    $fixed = $fixed -replace "\bbox office\b", $movieBoxOffice
    $fixed = $fixed -replace "\bBox office\b", $movieBoxOffice
    $fixed = $fixed -replace "\bprime day\b", "Prime Day"
    $fixed = $fixed -replace "\bPrime day\b", "Prime Day"
    $fixed = $fixed -replace [regex]::Escape([regex]::Unescape("\u0398\u03B7\u03BB\u03C9\u03BC\u03AD\u03BD\u03BF")), ([regex]::Unescape("\u039A\u03B1\u03B8\u03B7\u03BB\u03C9\u03BC\u03AD\u03BD\u03BF"))
    $fixed = $fixed -replace [regex]::Escape([regex]::Unescape("\u03B8\u03B7\u03BB\u03C9\u03BC\u03AD\u03BD\u03BF")), ([regex]::Unescape("\u03BA\u03B1\u03B8\u03B7\u03BB\u03C9\u03BC\u03AD\u03BD\u03BF"))
    $fixed = $fixed -replace [regex]::Escape([regex]::Unescape("\u03B5\u03BD \u03BC\u03AF\u03B1 \u03BD\u03C5\u03BA\u03C4\u03AF")), ([regex]::Unescape("\u03BC\u03AD\u03C3\u03B1 \u03C3\u03C4\u03B7 \u03BD\u03CD\u03C7\u03C4\u03B1"))
    $fixed = $fixed -replace [regex]::Escape([regex]::Unescape("\u0395\u03BD \u03BC\u03AF\u03B1 \u03BD\u03C5\u03BA\u03C4\u03AF")), ([regex]::Unescape("\u039C\u03AD\u03C3\u03B1 \u03C3\u03C4\u03B7 \u03BD\u03CD\u03C7\u03C4\u03B1"))
    $noBackToBack = [regex]::Unescape("\u03BA\u03B1\u03BD\u03AD\u03BD\u03B1 back-to-back")
    $noConsecutiveGames = [regex]::Unescape("\u03BA\u03B1\u03BD\u03AD\u03BD\u03B1 \u03C3\u03C5\u03BD\u03B5\u03C7\u03CC\u03BC\u03B5\u03BD\u03BF \u03C0\u03B1\u03B9\u03C7\u03BD\u03AF\u03B4\u03B9")
    $backToBackGames = [regex]::Unescape("back-to-back \u03C0\u03B1\u03B9\u03C7\u03BD\u03AF\u03B4\u03B9\u03B1")
    $consecutiveGames = [regex]::Unescape("\u03C3\u03C5\u03BD\u03B5\u03C7\u03CC\u03BC\u03B5\u03BD\u03B1 \u03C0\u03B1\u03B9\u03C7\u03BD\u03AF\u03B4\u03B9\u03B1")
    $firstBackToBack = [regex]::Unescape("\u03C4\u03BF \u03C0\u03C1\u03CE\u03C4\u03BF back-to-back")
    $firstConsecutiveGames = [regex]::Unescape("\u03C4\u03B1 \u03C0\u03C1\u03CE\u03C4\u03B1 \u03C3\u03C5\u03BD\u03B5\u03C7\u03CC\u03BC\u03B5\u03BD\u03B1 \u03C0\u03B1\u03B9\u03C7\u03BD\u03AF\u03B4\u03B9\u03B1")
    $fixed = $fixed -replace [regex]::Escape($noBackToBack), $noConsecutiveGames
    $fixed = $fixed -replace [regex]::Escape($backToBackGames), $consecutiveGames
    $fixed = $fixed -replace [regex]::Escape($firstBackToBack), $firstConsecutiveGames

    if (Test-FeminineFirstPersonContext -SubtitleContextHints $SubtitleContextHints) {
        $genderPairs = @(
            @("\u03B5\u03AF\u03BC\u03B1\u03B9 \u03BB\u03AF\u03B3\u03BF \u03B1\u03BD\u03B1\u03C3\u03C4\u03B1\u03C4\u03C9\u03BC\u03AD\u03BD\u03BF\u03C2", "\u03B5\u03AF\u03BC\u03B1\u03B9 \u03BB\u03AF\u03B3\u03BF \u03B1\u03BD\u03B1\u03C3\u03C4\u03B1\u03C4\u03C9\u03BC\u03AD\u03BD\u03B7"),
            @("\u03C0\u03C1\u03BF\u03C6\u03B1\u03BD\u03CE\u03C2 \u03BB\u03AF\u03B3\u03BF \u03B1\u03BD\u03B1\u03C3\u03C4\u03B1\u03C4\u03C9\u03BC\u03AD\u03BD\u03BF\u03C2", "\u03C0\u03C1\u03BF\u03C6\u03B1\u03BD\u03CE\u03C2 \u03BB\u03AF\u03B3\u03BF \u03B1\u03BD\u03B1\u03C3\u03C4\u03B1\u03C4\u03C9\u03BC\u03AD\u03BD\u03B7"),
            @("\u03B5\u03AF\u03BC\u03B1\u03B9 \u03C3\u03AF\u03B3\u03BF\u03C5\u03C1\u03BF\u03C2", "\u03B5\u03AF\u03BC\u03B1\u03B9 \u03C3\u03AF\u03B3\u03BF\u03C5\u03C1\u03B7"),
            @("\u03B5\u03AF\u03BC\u03B1\u03B9 \u03AD\u03C4\u03BF\u03B9\u03BC\u03BF\u03C2", "\u03B5\u03AF\u03BC\u03B1\u03B9 \u03AD\u03C4\u03BF\u03B9\u03BC\u03B7"),
            @("\u03B5\u03AF\u03BC\u03B1\u03B9 \u03C7\u03B1\u03C1\u03BF\u03CD\u03BC\u03B5\u03BD\u03BF\u03C2", "\u03B5\u03AF\u03BC\u03B1\u03B9 \u03C7\u03B1\u03C1\u03BF\u03CD\u03BC\u03B5\u03BD\u03B7"),
            @("\u03B5\u03AF\u03BC\u03B1\u03B9 \u03BA\u03BF\u03C5\u03C1\u03B1\u03C3\u03BC\u03AD\u03BD\u03BF\u03C2", "\u03B5\u03AF\u03BC\u03B1\u03B9 \u03BA\u03BF\u03C5\u03C1\u03B1\u03C3\u03BC\u03AD\u03BD\u03B7"),
            @("\u03B5\u03AF\u03BC\u03B1\u03B9 \u03C0\u03B5\u03C1\u03AE\u03C6\u03B1\u03BD\u03BF\u03C2", "\u03B5\u03AF\u03BC\u03B1\u03B9 \u03C0\u03B5\u03C1\u03AE\u03C6\u03B1\u03BD\u03B7"),
            @("\u03B5\u03AF\u03BC\u03B1\u03B9 \u03B5\u03BD\u03B8\u03BF\u03C5\u03C3\u03B9\u03B1\u03C3\u03BC\u03AD\u03BD\u03BF\u03C2", "\u03B5\u03AF\u03BC\u03B1\u03B9 \u03B5\u03BD\u03B8\u03BF\u03C5\u03C3\u03B9\u03B1\u03C3\u03BC\u03AD\u03BD\u03B7"),
            @("\u03BD\u03B9\u03CE\u03B8\u03C9 \u03C3\u03AF\u03B3\u03BF\u03C5\u03C1\u03BF\u03C2", "\u03BD\u03B9\u03CE\u03B8\u03C9 \u03C3\u03AF\u03B3\u03BF\u03C5\u03C1\u03B7"),
            @("\u03BD\u03B9\u03CE\u03B8\u03C9 \u03AD\u03C4\u03BF\u03B9\u03BC\u03BF\u03C2", "\u03BD\u03B9\u03CE\u03B8\u03C9 \u03AD\u03C4\u03BF\u03B9\u03BC\u03B7"),
            @("\u03AE\u03BC\u03BF\u03C5\u03BD \u03C3\u03AF\u03B3\u03BF\u03C5\u03C1\u03BF\u03C2", "\u03AE\u03BC\u03BF\u03C5\u03BD \u03C3\u03AF\u03B3\u03BF\u03C5\u03C1\u03B7"),
            @("\u03AE\u03BC\u03BF\u03C5\u03BD \u03AD\u03C4\u03BF\u03B9\u03BC\u03BF\u03C2", "\u03AE\u03BC\u03BF\u03C5\u03BD \u03AD\u03C4\u03BF\u03B9\u03BC\u03B7"),
            @("\u03AE\u03BC\u03BF\u03C5\u03BD \u03C7\u03B1\u03C1\u03BF\u03CD\u03BC\u03B5\u03BD\u03BF\u03C2", "\u03AE\u03BC\u03BF\u03C5\u03BD \u03C7\u03B1\u03C1\u03BF\u03CD\u03BC\u03B5\u03BD\u03B7"),
            @("\u03AE\u03BC\u03BF\u03C5\u03BD \u03BA\u03BF\u03C5\u03C1\u03B1\u03C3\u03BC\u03AD\u03BD\u03BF\u03C2", "\u03AE\u03BC\u03BF\u03C5\u03BD \u03BA\u03BF\u03C5\u03C1\u03B1\u03C3\u03BC\u03AD\u03BD\u03B7")
        )

        foreach ($pair in $genderPairs) {
            $malePhrase = [regex]::Unescape($pair[0])
            $femalePhrase = [regex]::Unescape($pair[1])
            $fixed = $fixed -replace [regex]::Escape($malePhrase), $femalePhrase
        }
    }
    return $fixed
}

function Merge-ShortSrtCuesForReadability {
    param(
        [string]$Srt,
        [double]$MinCueDurationSeconds,
        [double]$MaxMergeGapSeconds = 0.20,
        [double]$MaxReadingCharsPerSecond = 20.0,
        [int]$MaxLineWidth,
        [int]$MaxLineCount
    )

    $sourceBlocks = @(Get-SrtCueBlocks -Srt $Srt)
    $cueObjects = New-Object System.Collections.Generic.List[object]

    foreach ($block in $sourceBlocks) {
        $cue = Get-SrtCueParts -Block $block
        if ($cue.Timestamp -notmatch "^(?<start>\d{2}:\d{2}:\d{2},\d{3})\s+-->\s+(?<end>\d{2}:\d{2}:\d{2},\d{3})") {
            continue
        }

        $startSeconds = Convert-SrtTimestampToSeconds -Timestamp $Matches.start
        $endSeconds = Convert-SrtTimestampToSeconds -Timestamp $Matches.end
        if ($endSeconds -le $startSeconds) {
            $endSeconds = $startSeconds + 0.10
        }

        $cueObjects.Add([pscustomobject]@{
            StartSeconds = $startSeconds
            EndSeconds = $endSeconds
            Text = (($cue.Text -replace "\s+", " ").Trim())
        })
    }

    if ($cueObjects.Count -le 1) {
        return (Format-SrtCueTextOnly -Srt $Srt -MaxLineWidth $MaxLineWidth -MaxLineCount $MaxLineCount)
    }

    $merged = New-Object System.Collections.Generic.List[object]
    $maxMergedChars = [Math]::Max(48, $MaxLineWidth * $MaxLineCount)

    foreach ($cue in $cueObjects) {
        if ([string]::IsNullOrWhiteSpace($cue.Text)) {
            continue
        }

        $duration = [Math]::Max(0.01, $cue.EndSeconds - $cue.StartSeconds)
        $readingRate = (($cue.Text -replace "\s+", "").Length) / $duration
        $shouldTryMerge = $duration -lt $MinCueDurationSeconds -or $readingRate -gt $MaxReadingCharsPerSecond

        if ($shouldTryMerge -and $merged.Count -gt 0) {
            $previous = $merged[$merged.Count - 1]
            $gapSeconds = $cue.StartSeconds - $previous.EndSeconds
            $combinedText = (($previous.Text, $cue.Text) -join " ").Trim()
            $combinedDuration = [Math]::Max(0.01, $cue.EndSeconds - $previous.StartSeconds)
            $combinedReadingRate = (($combinedText -replace "\s+", "").Length) / $combinedDuration

            if ($gapSeconds -ge -0.35 -and
                $gapSeconds -le $MaxMergeGapSeconds -and
                $combinedText.Length -le $maxMergedChars -and
                $combinedReadingRate -le ($MaxReadingCharsPerSecond * 1.15)) {
                $previous.Text = $combinedText
                $previous.EndSeconds = [Math]::Max($previous.EndSeconds, $cue.EndSeconds)
                continue
            }
        }

        $merged.Add([pscustomobject]@{
            StartSeconds = $cue.StartSeconds
            EndSeconds = $cue.EndSeconds
            Text = $cue.Text
        })
    }

    $blocks = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $merged.Count; $i++) {
        $current = $merged[$i]
        if ($i -lt ($merged.Count - 1) -and $current.EndSeconds -gt ($merged[$i + 1].StartSeconds - 0.04)) {
            $current.EndSeconds = [Math]::Max($current.StartSeconds + 0.10, $merged[$i + 1].StartSeconds - 0.04)
        }

        $timestamp = "{0} --> {1}" -f `
            (Convert-SecondsToSrtTimestamp -Seconds $current.StartSeconds),
            (Convert-SecondsToSrtTimestamp -Seconds $current.EndSeconds)
        $text = Format-SubtitleCueText -Text $current.Text -MaxLineWidth $MaxLineWidth -MaxLineCount $MaxLineCount
        $blocks.Add((([string]($i + 1)), $timestamp, $text) -join "`r`n")
    }

    return ($blocks -join "`r`n`r`n")
}

function Split-SubtitleTextIntoBalancedParts {
    param(
        [string]$Text,
        [int]$DesiredPartCount,
        [int]$MaxPartChars = 0,
        [int]$MaxLineWidth = 0,
        [int]$MaxLineCount = 2
    )

    $singleLineText = ($Text -replace "\s+", " ").Trim()
    if ([string]::IsNullOrWhiteSpace($singleLineText) -or $DesiredPartCount -le 1) {
        return @($singleLineText)
    }

    $words = @($singleLineText -split "\s+" | Where-Object { $_ })
    if ($words.Count -le 1) {
        return @($singleLineText)
    }

    $DesiredPartCount = [Math]::Min($DesiredPartCount, $words.Count)
    $targetLength = [Math]::Max(1, [Math]::Ceiling($singleLineText.Length / $DesiredPartCount))
    if ($MaxPartChars -gt 0) {
        $targetLength = [Math]::Min($targetLength, $MaxPartChars)
    }

    $costs = New-Object object[] ($DesiredPartCount + 1)
    $previousCuts = New-Object object[] ($DesiredPartCount + 1)
    for ($partCount = 0; $partCount -le $DesiredPartCount; $partCount++) {
        $costs[$partCount] = @{}
        $previousCuts[$partCount] = @{}
    }
    $costs[0][0] = 0.0

    for ($partCount = 1; $partCount -le $DesiredPartCount; $partCount++) {
        $minimumEnd = $partCount
        $maximumEnd = $words.Count - ($DesiredPartCount - $partCount)

        for ($endExclusive = $minimumEnd; $endExclusive -le $maximumEnd; $endExclusive++) {
            $minimumStart = $partCount - 1
            $maximumStart = $endExclusive - 1

            for ($startIndex = $maximumStart; $startIndex -ge $minimumStart; $startIndex--) {
                $candidateText = (@($words[$startIndex..($endExclusive - 1)]) -join " ").Trim()
                $candidateLength = $candidateText.Length
                if ($MaxPartChars -gt 0 -and $candidateLength -gt $MaxPartChars) {
                    break
                }
                if (-not $costs[$partCount - 1].ContainsKey($startIndex)) {
                    continue
                }

                if ($MaxLineWidth -gt 0) {
                    $fitsLineLimits = $candidateLength -le $MaxLineWidth
                    if (-not $fitsLineLimits -and $MaxLineCount -eq 2) {
                        $spaceIndex = $candidateText.IndexOf(' ')
                        while ($spaceIndex -gt 0) {
                            $secondLineLength = $candidateLength - $spaceIndex - 1
                            if ($spaceIndex -le $MaxLineWidth -and $secondLineLength -le $MaxLineWidth) {
                                $fitsLineLimits = $true
                                break
                            }
                            $spaceIndex = $candidateText.IndexOf(' ', $spaceIndex + 1)
                        }
                    }
                    elseif (-not $fitsLineLimits -and $MaxLineCount -gt 2) {
                        $previewLines = @((Format-SubtitleCueText `
                            -Text $candidateText `
                            -MaxLineWidth $MaxLineWidth `
                            -MaxLineCount $MaxLineCount) -split "`r?`n")
                        $fitsLineLimits = @($previewLines | Where-Object { $_.Length -gt $MaxLineWidth }).Count -eq 0
                    }

                    if (-not $fitsLineLimits) {
                        continue
                    }
                }

                $endsSentence = $candidateText -match '[.!?;\u2026]+[\u0022\u0027»”)\]]*$'
                $endsClause = $candidateText -match '[,:]+[\u0022\u0027»”)\]]*$'
                $leavesOrphanEnding = $false
                if (-not $endsSentence -and $endExclusive -lt $words.Count) {
                    $lookAheadEnd = [Math]::Min($words.Count - 1, $endExclusive + 4)
                    for ($lookAheadIndex = $endExclusive; $lookAheadIndex -le $lookAheadEnd; $lookAheadIndex++) {
                        if ($words[$lookAheadIndex] -match '[.!?;\u2026]+[\u0022\u0027»”)\]]*$') {
                            $leavesOrphanEnding = $true
                            break
                        }
                    }
                }

                $segmentCost = [Math]::Abs($candidateLength - $targetLength)
                if ($endsSentence -and $endExclusive -lt $words.Count) {
                    $segmentCost -= 90
                }
                elseif ($endsClause) {
                    $segmentCost -= 16
                }
                if ($leavesOrphanEnding) {
                    $segmentCost += 500
                }
                if ($candidateLength -lt [Math]::Min(18, $targetLength * 0.35)) {
                    $segmentCost += 200
                }

                $totalCost = [double]$costs[$partCount - 1][$startIndex] + $segmentCost
                if (-not $costs[$partCount].ContainsKey($endExclusive) -or
                    $totalCost -lt [double]$costs[$partCount][$endExclusive]) {
                    $costs[$partCount][$endExclusive] = $totalCost
                    $previousCuts[$partCount][$endExclusive] = $startIndex
                }
            }
        }
    }

    if (-not $costs[$DesiredPartCount].ContainsKey($words.Count)) {
        return @(Split-SubtitleTextByWords `
            -Text $singleLineText `
            -TargetChars $(if ($MaxPartChars -gt 0) { $MaxPartChars } else { $targetLength }))
    }

    $parts = New-Object System.Collections.Generic.List[string]
    $endIndex = $words.Count
    for ($partCount = $DesiredPartCount; $partCount -ge 1; $partCount--) {
        $startIndex = [int]$previousCuts[$partCount][$endIndex]
        $parts.Insert(0, (@($words[$startIndex..($endIndex - 1)]) -join " ").Trim())
        $endIndex = $startIndex
    }

    return @($parts)
}

function Rebalance-SrtTimingForReadability {
    param(
        [string]$Srt,
        [double]$MinCueDurationSeconds,
        [double]$MaxCueDurationSeconds,
        [double]$MaxReadingCharsPerSecond = 20.0,
        [double]$MaxJoinGapSeconds = 0.35,
        [double]$MinCueGapSeconds = 0.04,
        [double]$MaxGroupSpanSeconds = 14.0,
        [int]$MaxLineWidth,
        [int]$MaxLineCount
    )

    $sourceBlocks = @(Get-SrtCueBlocks -Srt $Srt)
    $cueObjects = New-Object System.Collections.Generic.List[object]

    foreach ($block in $sourceBlocks) {
        $cue = Get-SrtCueParts -Block $block
        if ($cue.Timestamp -notmatch "^(?<start>\d{2}:\d{2}:\d{2},\d{3})\s+-->\s+(?<end>\d{2}:\d{2}:\d{2},\d{3})") {
            continue
        }

        $text = (($cue.Text -replace "\s+", " ").Trim())
        if ([string]::IsNullOrWhiteSpace($text)) {
            continue
        }

        $startSeconds = Convert-SrtTimestampToSeconds -Timestamp $Matches.start
        $endSeconds = Convert-SrtTimestampToSeconds -Timestamp $Matches.end
        if ($endSeconds -le $startSeconds) {
            $endSeconds = $startSeconds + 0.10
        }

        $speakerLabel = ""
        if ($text -match "^\s*(?<speaker>\[(?:SPEAKER[_ ]?\d+|Speaker[^\]]*)\])") {
            $speakerLabel = $Matches.speaker
        }

        $cueObjects.Add([pscustomobject]@{
            StartSeconds = $startSeconds
            EndSeconds = $endSeconds
            Text = $text
            SpeakerLabel = $speakerLabel
        })
    }

    if ($cueObjects.Count -eq 0) {
        return $Srt
    }

    $groups = New-Object System.Collections.Generic.List[object]
    $cueIndex = 0

    while ($cueIndex -lt $cueObjects.Count) {
        $cue = $cueObjects[$cueIndex]
        $currentGroup = [pscustomobject]@{
            StartSeconds = $cue.StartSeconds
            EndSeconds = $cue.EndSeconds
            Texts = [System.Collections.Generic.List[string]]::new()
            SpeakerLabel = $cue.SpeakerLabel
        }
        $currentGroup.Texts.Add($cue.Text)
        $cueIndex++

        while ($cueIndex -lt $cueObjects.Count) {
            $nextCue = $cueObjects[$cueIndex]
            $groupText = (@($currentGroup.Texts) -join " ").Trim()
            $groupDuration = [Math]::Max(0.01, $currentGroup.EndSeconds - $currentGroup.StartSeconds)
            $groupReadingRate = (($groupText -replace "\s+", "").Length) / $groupDuration
            $nextDuration = [Math]::Max(0.01, $nextCue.EndSeconds - $nextCue.StartSeconds)
            $nextReadingRate = (($nextCue.Text -replace "\s+", "").Length) / $nextDuration
            $gapSeconds = $nextCue.StartSeconds - $currentGroup.EndSeconds
            $projectedSpan = [Math]::Max($currentGroup.EndSeconds, $nextCue.EndSeconds) - $currentGroup.StartSeconds
            $speakerChanged = -not [string]::IsNullOrWhiteSpace($currentGroup.SpeakerLabel) -and
                -not [string]::IsNullOrWhiteSpace($nextCue.SpeakerLabel) -and
                $currentGroup.SpeakerLabel -ne $nextCue.SpeakerLabel
            $hasTimingPressure = $groupDuration -lt $MinCueDurationSeconds -or
                $nextDuration -lt $MinCueDurationSeconds -or
                $groupReadingRate -gt $MaxReadingCharsPerSecond -or
                $nextReadingRate -gt $MaxReadingCharsPerSecond -or
                $gapSeconds -lt $MinCueGapSeconds
            $isSentenceContinuation = -not (Test-SubtitleSentenceEnd -Text $groupText)
            $allowedJoinGapSeconds = if ($isSentenceContinuation) {
                [Math]::Max($MaxJoinGapSeconds, 0.80)
            }
            else {
                $MaxJoinGapSeconds
            }
            $shouldJoin = -not $speakerChanged -and
                $gapSeconds -le $allowedJoinGapSeconds -and
                $gapSeconds -ge -0.50 -and
                ($isSentenceContinuation -or $projectedSpan -le $MaxGroupSpanSeconds) -and
                ($isSentenceContinuation -or $hasTimingPressure)

            if (-not $shouldJoin) {
                break
            }

            $currentGroup.Texts.Add($nextCue.Text)
            $currentGroup.EndSeconds = [Math]::Max($currentGroup.EndSeconds, $nextCue.EndSeconds)
            if ([string]::IsNullOrWhiteSpace($currentGroup.SpeakerLabel)) {
                $currentGroup.SpeakerLabel = $nextCue.SpeakerLabel
            }
            $cueIndex++
        }

        $groups.Add($currentGroup)
    }

    $outputBlocks = New-Object System.Collections.Generic.List[string]
    $cueNumber = 1
    $maxDisplayChars = [Math]::Max(32, $MaxLineWidth * $MaxLineCount)

    for ($groupIndex = 0; $groupIndex -lt $groups.Count; $groupIndex++) {
        $group = $groups[$groupIndex]
        $groupText = ((@($group.Texts) -join " ") -replace "\s+", " ").Trim()
        $groupStart = $group.StartSeconds
        $groupEnd = $group.EndSeconds

        if ($groupIndex -lt ($groups.Count - 1)) {
            $latestAllowedEnd = $groups[$groupIndex + 1].StartSeconds - $MinCueGapSeconds
            $neededDuration = [Math]::Max(
                $MinCueDurationSeconds,
                (($groupText -replace "\s+", "").Length) / $MaxReadingCharsPerSecond
            )
            $neededEnd = $groupStart + $neededDuration
            $groupEnd = [Math]::Min($latestAllowedEnd, [Math]::Max($groupEnd, $neededEnd))
        }

        if ($groupEnd -le $groupStart) {
            $groupEnd = $groupStart + 0.10
        }

        $groupDuration = $groupEnd - $groupStart
        $partCountByLength = [Math]::Max(1, [Math]::Ceiling($groupText.Length / $maxDisplayChars))
        $partCountByDuration = [Math]::Max(1, [Math]::Ceiling(($groupDuration + $MinCueGapSeconds) / ($MaxCueDurationSeconds + $MinCueGapSeconds)))
        $desiredPartCount = [Math]::Max($partCountByLength, $partCountByDuration)
        $maxPartsByMinimumDuration = [Math]::Max(1, [Math]::Floor(($groupDuration + $MinCueGapSeconds) / ($MinCueDurationSeconds + $MinCueGapSeconds)))
        $maxPartsByMinimumDuration = [Math]::Min($maxPartsByMinimumDuration, @($groupText -split "\s+" | Where-Object { $_ }).Count)
        $desiredPartCount = [Math]::Min($desiredPartCount, $maxPartsByMinimumDuration)
        while ($true) {
            $textParts = @(Split-SubtitleTextIntoBalancedParts `
                -Text $groupText `
                -DesiredPartCount $desiredPartCount `
                -MaxPartChars $maxDisplayChars `
                -MaxLineWidth $MaxLineWidth `
                -MaxLineCount $MaxLineCount)
            $availableDuration = [Math]::Max(0.10, $groupDuration - ($MinCueGapSeconds * [Math]::Max(0, $textParts.Count - 1)))
            $totalWeight = 0
            $largestPartLength = 0
            $hasLineOverflow = $false
            $hasOrphanSentenceEnding = $false
            $weights = New-Object System.Collections.Generic.List[int]
            foreach ($textPart in $textParts) {
                $weight = [Math]::Max(1, ($textPart -replace "\s+", "").Length)
                $weights.Add($weight)
                $totalWeight += $weight
                $largestPartLength = [Math]::Max($largestPartLength, $textPart.Length)
                $previewLines = @(Format-SubtitleCueText -Text $textPart -MaxLineWidth $MaxLineWidth -MaxLineCount $MaxLineCount) -split "`r?`n"
                if (@($previewLines | Where-Object { $_.Length -gt $MaxLineWidth }).Count -gt 0) {
                    $hasLineOverflow = $true
                }
            }

            for ($textPartIndex = 1; $textPartIndex -lt $textParts.Count; $textPartIndex++) {
                if ($textParts[$textPartIndex - 1] -notmatch '[.!?;:\u2026][\u0022\u0027»”)\]]*$' -and
                    $textParts[$textPartIndex] -match '^(?:\S+\s+){0,4}\S+?[.!?;:\u2026][\u0022\u0027»”)\]]*(?:\s+|$)') {
                    $hasOrphanSentenceEnding = $true
                    break
                }
            }

            $largestProjectedDuration = 0.0
            foreach ($weight in $weights) {
                $largestProjectedDuration = [Math]::Max(
                    $largestProjectedDuration,
                    $availableDuration * ($weight / [Math]::Max(1.0, $totalWeight))
                )
            }

            if (($largestProjectedDuration -le $MaxCueDurationSeconds -and
                    $largestPartLength -le $maxDisplayChars -and
                    -not $hasLineOverflow -and
                    -not $hasOrphanSentenceEnding) -or
                $desiredPartCount -ge $maxPartsByMinimumDuration) {
                break
            }

            $desiredPartCount++
        }

        $segmentStart = $groupStart
        $segmentDurations = New-Object System.Collections.Generic.List[double]
        $minimumDurationTotal = $MinCueDurationSeconds * $textParts.Count
        if ($availableDuration -ge $minimumDurationTotal) {
            $remainingDuration = $availableDuration - $minimumDurationTotal
            foreach ($weight in $weights) {
                $segmentDurations.Add(
                    $MinCueDurationSeconds + ($remainingDuration * ($weight / [Math]::Max(1.0, $totalWeight)))
                )
            }
        }
        else {
            foreach ($weight in $weights) {
                $segmentDurations.Add(
                    $availableDuration * ($weight / [Math]::Max(1.0, $totalWeight))
                )
            }
        }

        for ($partIndex = 0; $partIndex -lt $textParts.Count; $partIndex++) {
            if ($partIndex -eq ($textParts.Count - 1)) {
                $segmentEnd = $groupEnd
            }
            else {
                $segmentDuration = $segmentDurations[$partIndex]
                $segmentDuration = [Math]::Max(0.10, [Math]::Min($MaxCueDurationSeconds, $segmentDuration))
                $segmentEnd = $segmentStart + $segmentDuration
                $latestSegmentEnd = $groupEnd - (($textParts.Count - $partIndex - 1) * (0.10 + $MinCueGapSeconds))
                $segmentEnd = [Math]::Min($segmentEnd, $latestSegmentEnd)
            }

            if ($segmentEnd -le $segmentStart) {
                $segmentEnd = $segmentStart + 0.10
            }

            $timestamp = "{0} --> {1}" -f `
                (Convert-SecondsToSrtTimestamp -Seconds $segmentStart),
                (Convert-SecondsToSrtTimestamp -Seconds $segmentEnd)
            $formattedText = Format-SubtitleCueText -Text $textParts[$partIndex] -MaxLineWidth $MaxLineWidth -MaxLineCount $MaxLineCount
            $outputBlocks.Add((([string]$cueNumber), $timestamp, $formattedText) -join "`r`n")
            $cueNumber++
            $segmentStart = $segmentEnd + $MinCueGapSeconds
        }
    }

    return ($outputBlocks -join "`r`n`r`n")
}

function Invoke-FinalSrtQualityPass {
    param(
        [string]$Srt,
        [string]$TargetLanguage,
        [string]$SubtitleContextHints,
        [double]$MinCueDurationSeconds,
        [double]$MaxCueDurationSeconds,
        [double]$MaxReadingCharsPerSecond,
        [int]$MaxLineWidth,
        [int]$MaxLineCount
    )

    $qualitySrt = Apply-SubtitleTextFixups -Srt $Srt -TargetLanguage $TargetLanguage -SubtitleContextHints $SubtitleContextHints
    $qualitySrt = Repair-SrtDanglingCueEndings `
        -Srt $qualitySrt `
        -MaxLineWidth $MaxLineWidth `
        -MaxLineCount $MaxLineCount
    $qualitySrt = Repair-SrtOrphanCuePrefixes `
        -Srt $qualitySrt `
        -MaxLineWidth $MaxLineWidth `
        -MaxLineCount $MaxLineCount
    $qualitySrt = Repair-SrtTrailingCueStartFragments `
        -Srt $qualitySrt `
        -MaxLineWidth $MaxLineWidth `
        -MaxLineCount $MaxLineCount
    $qualitySrt = Merge-ShortSrtCuesForReadability `
        -Srt $qualitySrt `
        -MinCueDurationSeconds $MinCueDurationSeconds `
        -MaxReadingCharsPerSecond $MaxReadingCharsPerSecond `
        -MaxLineWidth $MaxLineWidth `
        -MaxLineCount $MaxLineCount
    $qualitySrt = Rebalance-SrtTimingForReadability `
        -Srt $qualitySrt `
        -MinCueDurationSeconds $MinCueDurationSeconds `
        -MaxCueDurationSeconds $MaxCueDurationSeconds `
        -MaxReadingCharsPerSecond $MaxReadingCharsPerSecond `
        -MaxLineWidth $MaxLineWidth `
        -MaxLineCount $MaxLineCount
    return (Format-SrtCueTextOnly -Srt $qualitySrt -MaxLineWidth $MaxLineWidth -MaxLineCount $MaxLineCount)
}

function Invoke-OpenAITranslation {
    param(
        [string]$Text,
        [string]$TargetLanguage,
        [string]$Model,
        [string]$ApiKey,
        [string]$BaseUrl,
        [string]$Provider,
        [bool]$EnableAutoGenderInference,
        [string]$SubtitleContextHints,
        [int]$ChunkNumber,
        [int]$ChunkCount
    )

    $domainGuidance = Get-SubtitleDomainGuidance -TargetLanguage $TargetLanguage -EnableAutoGenderInference $EnableAutoGenderInference -SubtitleContextHints $SubtitleContextHints
    $instructions = @"
You are a professional audiovisual translator.
Translate the user's transcript into $TargetLanguage.
Preserve paragraph breaks, speaker labels, names, numbers, and technical terms.
Return only the translated text, without notes or markdown fences.

$domainGuidance
"@

    $inputText = @"
Transcript chunk $ChunkNumber of ${ChunkCount}:

$Text
"@

    if ($Provider -eq "Gemini") {
        $body = ConvertTo-TranslationJsonBody -Payload @{
            systemInstruction = @{
                parts = @(
                    @{
                        text = $instructions
                    }
                )
            }
            contents = @(
                @{
                    role = "user"
                    parts = @(
                        @{
                            text = $inputText
                        }
                    )
                }
            )
        }

        $headers = @{}
    }
    else {
        $body = ConvertTo-TranslationJsonBody -Payload @{
            model = $Model
            messages = @(
                @{
                    role = "system"
                    content = $instructions
                },
                @{
                    role = "user"
                    content = $inputText
                }
            )
        }

        $headers = @{
            "Authorization" = "Bearer $ApiKey"
        }
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $uri = if ($Provider -eq "Gemini") {
                "$($BaseUrl.TrimEnd('/'))/models/${Model}:generateContent?key=$([uri]::EscapeDataString($ApiKey))"
            }
            else {
                "$($BaseUrl.TrimEnd('/'))/chat/completions"
            }
            $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType "application/json; charset=utf-8" -Body $body
            return Get-OpenAIText -Response $response
        }
        catch {
            if ($attempt -eq 3) {
                throw (Get-RestErrorMessage -ErrorRecord $_)
            }
            Wait-RestApiRetry -ErrorRecord $_ -Attempt $attempt
        }
    }
}

function Invoke-OpenAISrtTranslation {
    param(
        [string]$Srt,
        [string]$TargetLanguage,
        [string]$Model,
        [string]$ApiKey,
        [string]$BaseUrl,
        [string]$Provider,
        [bool]$EnableAutoGenderInference,
        [string]$SubtitleContextHints,
        [int]$ChunkNumber,
        [int]$ChunkCount
    )

    $domainGuidance = Get-SubtitleDomainGuidance -TargetLanguage $TargetLanguage -EnableAutoGenderInference $EnableAutoGenderInference -SubtitleContextHints $SubtitleContextHints
    $instructions = @"
You are a professional subtitle translator.
Translate only the spoken subtitle text into $TargetLanguage.
Preserve valid SubRip .srt structure exactly: cue numbers, timestamp lines, cue order, and blank lines between cues.
Do not translate, edit, remove, or add timestamps.
Keep the same number of subtitle cues.
Use concise, natural subtitle language that fits the original cue duration. Avoid expanding fillers or repetitions, and aim for no more than 20 visible characters per second whenever the source timing permits it.
Return only the translated .srt content, without notes or markdown fences.

$domainGuidance
"@

    $inputText = @"
SRT chunk $ChunkNumber of ${ChunkCount}:

$Srt
"@

    if ($Provider -eq "Gemini") {
        $body = ConvertTo-TranslationJsonBody -Payload @{
            systemInstruction = @{
                parts = @(
                    @{
                        text = $instructions
                    }
                )
            }
            contents = @(
                @{
                    role = "user"
                    parts = @(
                        @{
                            text = $inputText
                        }
                    )
                }
            )
        }

        $headers = @{}
    }
    else {
        $body = ConvertTo-TranslationJsonBody -Payload @{
            model = $Model
            messages = @(
                @{
                    role = "system"
                    content = $instructions
                },
                @{
                    role = "user"
                    content = $inputText
                }
            )
        }

        $headers = @{
            "Authorization" = "Bearer $ApiKey"
        }
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $uri = if ($Provider -eq "Gemini") {
                "$($BaseUrl.TrimEnd('/'))/models/${Model}:generateContent?key=$([uri]::EscapeDataString($ApiKey))"
            }
            else {
                "$($BaseUrl.TrimEnd('/'))/chat/completions"
            }
            $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType "application/json; charset=utf-8" -Body $body
            return Get-OpenAIText -Response $response
        }
        catch {
            if ($attempt -eq 3) {
                throw (Get-RestErrorMessage -ErrorRecord $_)
            }
            Wait-RestApiRetry -ErrorRecord $_ -Attempt $attempt
        }
    }
}

function Invoke-OpenAISrtTranslationQaPass {
    param(
        [string]$SourceSrt,
        [string]$TranslatedSrt,
        [string]$TargetLanguage,
        [string]$Model,
        [string]$ApiKey,
        [string]$BaseUrl,
        [string]$Provider,
        [bool]$EnableAutoGenderInference,
        [string]$SubtitleContextHints,
        [int]$ChunkNumber,
        [int]$ChunkCount
    )

    $pairedSrt = Convert-SrtPairForQaPass -SourceSrt $SourceSrt -TranslatedSrt $TranslatedSrt
    $domainGuidance = Get-SubtitleDomainGuidance -TargetLanguage $TargetLanguage -EnableAutoGenderInference $EnableAutoGenderInference -SubtitleContextHints $SubtitleContextHints
    $instructions = @"
You are a senior subtitle QA editor.
Review the DRAFT $TargetLanguage subtitles against the SOURCE English subtitles cue by cue.
Fix only real translation problems: missing meaning, wrong names, wrong speaker intent, mistranslated idioms, mistranslated sports terms, wrong gender where clear, and untranslated English that should be translated.
Keep concise, natural $TargetLanguage suitable for subtitles.
Preserve valid SubRip .srt structure exactly: cue numbers, timestamp lines, cue order, and blank lines between cues.
Return only the corrected $TargetLanguage .srt content.
Do not include SOURCE/DRAFT labels, notes, markdown fences, or explanations.

$domainGuidance
"@

    $inputText = @"
QA chunk $ChunkNumber of ${ChunkCount}.
Each cue has SOURCE English text and DRAFT $TargetLanguage text.
Return corrected $TargetLanguage SRT only:

$pairedSrt
"@

    if ($Provider -eq "Gemini") {
        $body = ConvertTo-TranslationJsonBody -Payload @{
            systemInstruction = @{
                parts = @(
                    @{
                        text = $instructions
                    }
                )
            }
            contents = @(
                @{
                    role = "user"
                    parts = @(
                        @{
                            text = $inputText
                        }
                    )
                }
            )
        }

        $headers = @{}
    }
    else {
        $body = ConvertTo-TranslationJsonBody -Payload @{
            model = $Model
            messages = @(
                @{
                    role = "system"
                    content = $instructions
                },
                @{
                    role = "user"
                    content = $inputText
                }
            )
        }

        $headers = @{
            "Authorization" = "Bearer $ApiKey"
        }
    }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $uri = if ($Provider -eq "Gemini") {
                "$($BaseUrl.TrimEnd('/'))/models/${Model}:generateContent?key=$([uri]::EscapeDataString($ApiKey))"
            }
            else {
                "$($BaseUrl.TrimEnd('/'))/chat/completions"
            }
            $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType "application/json; charset=utf-8" -Body $body
            $qaSrt = Get-OpenAIText -Response $response
            return Repair-TranslatedSrtStructure -SourceSrt $SourceSrt -TranslatedSrt $qaSrt
        }
        catch {
            if ($attempt -eq 3) {
                throw (Get-RestErrorMessage -ErrorRecord $_)
            }
            Wait-RestApiRetry -ErrorRecord $_ -Attempt $attempt
        }
    }
}

function Invoke-OpenAISrtTranslationWithRepair {
    param(
        [string]$Srt,
        [string]$TargetLanguage,
        [string]$Model,
        [string]$ApiKey,
        [string]$BaseUrl,
        [string]$Provider,
        [bool]$EnableAutoGenderInference,
        [string]$SubtitleContextHints,
        [int]$ChunkNumber,
        [int]$ChunkCount,
        [int]$Depth = 0
    )

    $sourceBlocks = @(Get-SrtCueBlocks -Srt $Srt)
    $translatedSrt = Invoke-OpenAISrtTranslation `
        -Srt $Srt `
        -TargetLanguage $TargetLanguage `
        -Model $Model `
        -ApiKey $ApiKey `
        -BaseUrl $BaseUrl `
        -Provider $Provider `
        -EnableAutoGenderInference $EnableAutoGenderInference `
        -SubtitleContextHints $SubtitleContextHints `
        -ChunkNumber $ChunkNumber `
        -ChunkCount $ChunkCount

    try {
        return Repair-TranslatedSrtStructure -SourceSrt $Srt -TranslatedSrt $translatedSrt
    }
    catch {
        if ($sourceBlocks.Count -le 1 -or $Depth -ge 6) {
            throw
        }

        $leftCount = [Math]::Ceiling($sourceBlocks.Count / 2)
        $leftBlocks = @($sourceBlocks | Select-Object -First $leftCount)
        $rightBlocks = @($sourceBlocks | Select-Object -Skip $leftCount)

        Write-RunWarning "Translation cue count mismatch in chunk $ChunkNumber. Retrying as smaller subtitle chunks: $($leftBlocks.Count) + $($rightBlocks.Count)."

        $leftSrt = Convert-SrtBlocksToText -Blocks $leftBlocks
        $rightSrt = Convert-SrtBlocksToText -Blocks $rightBlocks

        $leftTranslated = Invoke-OpenAISrtTranslationWithRepair `
            -Srt $leftSrt `
            -TargetLanguage $TargetLanguage `
            -Model $Model `
            -ApiKey $ApiKey `
            -BaseUrl $BaseUrl `
            -Provider $Provider `
            -EnableAutoGenderInference $EnableAutoGenderInference `
            -SubtitleContextHints $SubtitleContextHints `
            -ChunkNumber $ChunkNumber `
            -ChunkCount $ChunkCount `
            -Depth ($Depth + 1)

        $rightTranslated = Invoke-OpenAISrtTranslationWithRepair `
            -Srt $rightSrt `
            -TargetLanguage $TargetLanguage `
            -Model $Model `
            -ApiKey $ApiKey `
            -BaseUrl $BaseUrl `
            -Provider $Provider `
            -EnableAutoGenderInference $EnableAutoGenderInference `
            -SubtitleContextHints $SubtitleContextHints `
            -ChunkNumber $ChunkNumber `
            -ChunkCount $ChunkCount `
            -Depth ($Depth + 1)

        return (($leftTranslated.Trim(), $rightTranslated.Trim()) -join "`r`n`r`n")
    }
}

function Get-TranslationWorkerFunctionSource {
    $functionNames = @(
        "Repair-Utf8ApiText",
        "Get-OpenAIText",
        "Protect-SensitiveApiErrorText",
        "Get-RestErrorMessage",
        "Wait-RestApiRetry",
        "ConvertTo-TranslationJsonBody",
        "Get-SubtitleDomainGuidance",
        "Get-SrtCueBlocks",
        "Get-SrtCueParts",
        "Repair-TranslatedSrtStructure",
        "Convert-SrtPairForQaPass",
        "Convert-SrtBlocksToText",
        "Invoke-OpenAITranslation",
        "Invoke-OpenAISrtTranslation",
        "Invoke-OpenAISrtTranslationQaPass",
        "Invoke-OpenAISrtTranslationWithRepair"
    )

    $definitions = New-Object System.Collections.Generic.List[string]
    foreach ($functionName in $functionNames) {
        $command = Get-Command -Name $functionName -CommandType Function -ErrorAction Stop
        $definitions.Add("function $functionName {`r`n$($command.Definition)`r`n}")
    }

    return ($definitions -join "`r`n`r`n")
}

function Invoke-ParallelTranslationWorkItems {
    param(
        [object[]]$WorkItems,
        [ValidateRange(1, 8)]
        [int]$MaxConcurrency = 3
    )

    if ($null -eq $WorkItems -or $WorkItems.Count -eq 0) {
        return @()
    }

    $workerFunctionSource = Get-TranslationWorkerFunctionSource
    $workerScript = {
        param(
            [string]$FunctionSource,
            [object]$WorkItem
        )

        Set-StrictMode -Version Latest
        $ErrorActionPreference = "Stop"
        Invoke-Expression $FunctionSource

        function Write-RunLog {
            param([AllowNull()][object]$Message = "")
        }

        function Write-RunWarning {
            param([AllowNull()][object]$Message = "")
            Write-Warning ([string]$Message)
        }

        try {
            $text = switch ([string]$WorkItem.Mode) {
                "Srt" {
                    Invoke-OpenAISrtTranslationWithRepair `
                        -Srt ([string]$WorkItem.SourceText) `
                        -TargetLanguage ([string]$WorkItem.TargetLanguage) `
                        -Model ([string]$WorkItem.Model) `
                        -ApiKey ([string]$WorkItem.ApiKey) `
                        -BaseUrl ([string]$WorkItem.BaseUrl) `
                        -Provider ([string]$WorkItem.Provider) `
                        -EnableAutoGenderInference ([bool]$WorkItem.EnableAutoGenderInference) `
                        -SubtitleContextHints ([string]$WorkItem.SubtitleContextHints) `
                        -ChunkNumber ([int]$WorkItem.ChunkNumber) `
                        -ChunkCount ([int]$WorkItem.ChunkCount)
                    break
                }
                "Qa" {
                    Invoke-OpenAISrtTranslationQaPass `
                        -SourceSrt ([string]$WorkItem.SourceText) `
                        -TranslatedSrt ([string]$WorkItem.TranslatedText) `
                        -TargetLanguage ([string]$WorkItem.TargetLanguage) `
                        -Model ([string]$WorkItem.Model) `
                        -ApiKey ([string]$WorkItem.ApiKey) `
                        -BaseUrl ([string]$WorkItem.BaseUrl) `
                        -Provider ([string]$WorkItem.Provider) `
                        -EnableAutoGenderInference ([bool]$WorkItem.EnableAutoGenderInference) `
                        -SubtitleContextHints ([string]$WorkItem.SubtitleContextHints) `
                        -ChunkNumber ([int]$WorkItem.ChunkNumber) `
                        -ChunkCount ([int]$WorkItem.ChunkCount)
                    break
                }
                "Text" {
                    Invoke-OpenAITranslation `
                        -Text ([string]$WorkItem.SourceText) `
                        -TargetLanguage ([string]$WorkItem.TargetLanguage) `
                        -Model ([string]$WorkItem.Model) `
                        -ApiKey ([string]$WorkItem.ApiKey) `
                        -BaseUrl ([string]$WorkItem.BaseUrl) `
                        -Provider ([string]$WorkItem.Provider) `
                        -EnableAutoGenderInference ([bool]$WorkItem.EnableAutoGenderInference) `
                        -SubtitleContextHints ([string]$WorkItem.SubtitleContextHints) `
                        -ChunkNumber ([int]$WorkItem.ChunkNumber) `
                        -ChunkCount ([int]$WorkItem.ChunkCount)
                    break
                }
                default {
                    throw "Unknown parallel translation mode: $($WorkItem.Mode)"
                }
            }

            [pscustomobject]@{
                Index = [int]$WorkItem.Index
                Text = [string]$text
                Error = ""
            }
        }
        catch {
            [pscustomobject]@{
                Index = [int]$WorkItem.Index
                Text = ""
                Error = $_.Exception.Message
            }
        }
    }

    $runspacePool = [runspacefactory]::CreateRunspacePool(1, [Math]::Min($MaxConcurrency, $WorkItems.Count))
    $jobs = New-Object System.Collections.Generic.List[object]
    $results = New-Object System.Collections.Generic.List[object]
    try {
        $runspacePool.Open()
        foreach ($workItem in $WorkItems) {
            $powershell = [powershell]::Create()
            $powershell.RunspacePool = $runspacePool
            [void]$powershell.AddScript($workerScript.ToString()).AddArgument($workerFunctionSource).AddArgument($workItem)
            $jobs.Add([pscustomobject]@{
                PowerShell = $powershell
                AsyncResult = $powershell.BeginInvoke()
                WorkItem = $workItem
            })
        }

        while ($jobs.Count -gt 0) {
            $completedJobs = @($jobs | Where-Object { $_.AsyncResult.IsCompleted })
            if ($completedJobs.Count -eq 0) {
                Start-Sleep -Milliseconds 100
                continue
            }

            foreach ($job in $completedJobs) {
                try {
                    $output = @($job.PowerShell.EndInvoke($job.AsyncResult))
                    foreach ($warningRecord in $job.PowerShell.Streams.Warning) {
                        Write-RunWarning $warningRecord.Message
                    }
                    if ($output.Count -eq 0) {
                        throw "Parallel translation worker returned no result."
                    }
                    $result = $output[-1]
                    $results.Add($result)
                    if ([string]::IsNullOrWhiteSpace([string]$result.Error)) {
                        Write-RunLog "Completed API chunk $([int]$result.Index + 1)."
                    }
                    else {
                        Write-RunWarning "API chunk $([int]$result.Index + 1) failed: $($result.Error)"
                    }
                }
                catch {
                    $results.Add([pscustomobject]@{
                        Index = [int]$job.WorkItem.Index
                        Text = ""
                        Error = $_.Exception.Message
                    })
                }
                finally {
                    $job.PowerShell.Dispose()
                    [void]$jobs.Remove($job)
                }
            }
        }
    }
    finally {
        foreach ($job in $jobs) {
            try {
                $job.PowerShell.Stop()
            }
            catch {
            }
            $job.PowerShell.Dispose()
        }
        $runspacePool.Close()
        $runspacePool.Dispose()
    }

    # Once the parallel wave drains, retry only transient failures sequentially.
    # Successful results remain in memory and are never requested again here.
    if ($MaxConcurrency -gt 1) {
        $retryableResults = @($results | Where-Object {
            $_.Error -match '(?i)system_cpu_overloaded|\b(429|502|503|504)\b|server overloaded|service unavailable'
        } | Sort-Object Index)
        foreach ($failed in $retryableResults) {
            $retryItem = @($WorkItems | Where-Object { [int]$_.Index -eq [int]$failed.Index })
            Write-RunWarning "Retrying failed API chunk $([int]$failed.Index + 1) alone in 30 seconds; successful chunks are retained."
            Start-Sleep -Seconds 30
            try {
                $recovered = @(Invoke-ParallelTranslationWorkItems -WorkItems $retryItem -MaxConcurrency 1)
                $failed.Text = [string]$recovered[0].Text
                $failed.Error = ""
            }
            catch { $failed.Error = $_.Exception.Message }
        }
    }

    $failedResult = $results | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Error) } | Sort-Object Index | Select-Object -First 1
    if ($failedResult) {
        throw "Parallel translation chunk $([int]$failedResult.Index + 1) failed: $($failedResult.Error)"
    }

    return @($results | Sort-Object Index)
}

trap {
    if ($_.Exception.Message -eq "Run options were not selected.") {
        break
    }
    if (-not (Test-ControlAlive -Control $script:RunLogForm)) {
        Initialize-RunLogWindow
    }
    Write-RunWarning "Run failed: $($_.Exception.Message)"
    Wait-RunLogWindow
    break
}

if ([string]::IsNullOrWhiteSpace($InputPath) -and [string]::IsNullOrWhiteSpace($YouTubeUrl)) {
    $runOptions = Show-RunOptionsDialog `
        -DefaultYouTubeQuality $YouTubeQuality `
        -DefaultYouTubeCookiesFromBrowser $YouTubeCookiesFromBrowser `
        -DefaultYouTubeCookiesFile $YouTubeCookiesFile `
        -DefaultTranscriptionEngine $TranscriptionEngine `
        -DefaultVnaiGeminiModel $VnaiGeminiModel `
        -DefaultAudioTrack $AudioTrack `
        -DefaultWhisperModel "medium.en" `
        -DefaultMossModel $MossModel `
        -DefaultShowSpeakerLabels $ShowSpeakerLabels `
        -DefaultProvider $TranslationProvider `
        -DefaultTranslationModel $OpenAIModel `
        -DefaultTargetLanguage $TargetLanguage `
        -DefaultPostProcessingMode "None" `
        -DefaultTranslationQaPass $EnableTranslationQaPass `
        -DefaultAutoGenderInference $EnableAutoGenderInference `
        -DefaultVoiceGenderDetection $EnableVoiceGenderDetection `
        -DefaultSubtitleContextHints $SubtitleContextHints

    $InputPath = $runOptions.InputPath
    $YouTubeUrl = $runOptions.YouTubeUrl
    $YouTubeQuality = $runOptions.YouTubeQuality
    $YouTubeCookiesFromBrowser = $runOptions.YouTubeCookiesFromBrowser
    $YouTubeCookiesFile = $runOptions.YouTubeCookiesFile
    $OutputDir = $runOptions.OutputDir
    $TranscriptionEngine = $runOptions.TranscriptionEngine
    $AudioTrack = $runOptions.AudioTrack
    $WhisperModel = $runOptions.WhisperModel
    $MossModel = $runOptions.MossModel
    $ElevenLabsModel = $runOptions.ElevenLabsModel
    $VnaiGeminiModel = $runOptions.VnaiGeminiModel
    $ShowSpeakerLabels = $runOptions.ShowSpeakerLabels
    $TranslationProvider = $runOptions.TranslationProvider
    $OpenAIModel = $runOptions.OpenAIModel
    $TargetLanguage = $runOptions.TargetLanguage
    $SrtPostProcessingMode = $runOptions.SrtPostProcessingMode
    $EnableTranslationQaPass = $runOptions.EnableTranslationQaPass
    $EnableAutoGenderInference = $runOptions.EnableAutoGenderInference
    $EnableVoiceGenderDetection = $runOptions.EnableVoiceGenderDetection
    $SubtitleContextHints = $runOptions.SubtitleContextHints
    $PromptTranslationProvider = $false
    $PromptTranslationModel = $false

    if ([bool]$runOptions.SkipTranscription) {
        $SkipTranscription = $true
    }
    if ([bool]$runOptions.SkipTranslation) {
        $SkipTranslation = $true
    }

    Initialize-RunLogWindow

    if (-not [string]::IsNullOrWhiteSpace($InputPath)) {
        Write-RunLog "Selected input: $InputPath"
    }
    if (-not [string]::IsNullOrWhiteSpace($YouTubeUrl)) {
        Write-RunLog "Selected YouTube URL: $YouTubeUrl"
    }
}

Initialize-RunLogWindow

if (-not [string]::IsNullOrWhiteSpace($YouTubeUrl)) {
    $downloadRoot = if ([string]::IsNullOrWhiteSpace($OutputDir)) {
        Join-Path $script:ScriptRoot "YouTube Downloads"
    }
    else {
        (New-Item -ItemType Directory -Force -Path $OutputDir).FullName
    }

    $ytDlpExe = Resolve-YtDlpExecutable -PathOrCommand $YtDlpPath
    $InputPath = Save-YouTubeVideo -Url $YouTubeUrl -YtDlpExecutable $ytDlpExe -DownloadFolder $downloadRoot -Quality $YouTubeQuality -CookiesFromBrowser $YouTubeCookiesFromBrowser -CookiesFile $YouTubeCookiesFile
}

if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "Input path does not exist: $InputPath"
}

if ($DownloadYouTubeOnly) {
    if ([string]::IsNullOrWhiteSpace($YouTubeUrl)) {
        throw "DownloadYouTubeOnly requires a YouTube URL."
    }
    Write-RunLog "YouTube download completed: $InputPath"
    return
}

$resolvedInput = Resolve-Path -LiteralPath $InputPath
$useMediaFolderOutput = [string]::IsNullOrWhiteSpace($OutputDir)
$outputRoot = if ($useMediaFolderOutput) {
    $null
}
else {
    (New-Item -ItemType Directory -Force -Path $OutputDir).FullName
}
$inputItems = Get-Item -LiteralPath $resolvedInput.Path
$inputPatterns = if ($SkipTranscription) {
    @("*.srt", "*.txt", "*.mp3", "*.wav", "*.m4a", "*.mp4", "*.mkv", "*.mov", "*.avi", "*.flac")
}
else {
    @("*.mp3", "*.wav", "*.m4a", "*.mp4", "*.mkv", "*.mov", "*.avi", "*.flac")
}
$mediaFiles = @(
    if ($inputItems.PSIsContainer) {
        Get-ChildItem -LiteralPath $inputItems.FullName -File -Include $inputPatterns -Recurse
    }
    else {
        $inputItems
    }
)

if ($mediaFiles.Count -eq 0) {
    throw "No media files found in $($inputItems.FullName)."
}

$whisperExe = $null
$mossPythonExe = $null
$elevenLabsPythonExe = $null
$elevenLabsApiKey = $null
$elevenLabsFfmpegExe = $null
$vnaiGeminiPythonExe = $null
$vnaiGeminiApiKey = $null
$apiKey = $null
if (-not $SkipTranscription) {
    $ffmpegFolder = Resolve-FfmpegFolder
    if (-not $ffmpegFolder) { throw 'FFmpeg is required to prepare the selected audio track.' }
    $transcriptionFfmpegExe = Join-Path $ffmpegFolder 'ffmpeg.exe'
    Write-RunLog "Audio track: $(if ($AudioTrack -gt 0) { "Track $AudioTrack" } else { 'automatic, preferring English' })"
    if ($TranscriptionEngine -eq "MOSS") {
        if ([string]::IsNullOrWhiteSpace($MossModel)) {
            $MossModel = "OpenMOSS-Team/MOSS-Transcribe-Diarize"
        }
        $mossPythonExe = Resolve-MossPythonExecutable -RequestedPath $MossPythonPath
        Write-RunLog "Transcription engine: MOSS"
        Write-RunLog "MOSS runtime: $mossPythonExe"
        Write-RunLog "Transcription model: $MossModel"
        Write-RunLog "MOSS device: $MossDevice"
        if ($MossMaxNewTokens -gt 0) {
            Write-RunLog "MOSS max new tokens: $MossMaxNewTokens"
        }
        else {
            Write-RunLog "MOSS max new tokens: automatic"
        }
    }
    elseif ($TranscriptionEngine -eq "ElevenLabs") {
        if ([string]::IsNullOrWhiteSpace($ElevenLabsModel)) {
            $ElevenLabsModel = "scribe_v2"
        }
        $elevenLabsPythonExe = Resolve-PythonExecutable
        if (-not $elevenLabsPythonExe) {
            throw "Python was not found. It is required by the ElevenLabs adapter."
        }
        $elevenLabsFfmpegExe = $transcriptionFfmpegExe
        $elevenLabsApiKey = Get-ElevenLabsApiKey
        Write-RunLog "Transcription engine: ElevenLabs Scribe v2 (cloud)"
        Write-RunLog "Transcription model: $ElevenLabsModel"
        Write-RunLog "Speaker diarization: enabled"
        Write-RunLog "Expected speakers: $(if ($ElevenLabsNumSpeakers -gt 0) { $ElevenLabsNumSpeakers } else { 'automatic' })"
        Write-RunLog "Source language: $SourceLanguage"
        Write-RunLog "Privacy notice: prepared audio will be uploaded to ElevenLabs."
    }
    elseif ($TranscriptionEngine -eq "VNAIGemini") {
        $vnaiGeminiPythonExe = Resolve-PythonExecutable
        if (-not $vnaiGeminiPythonExe) { throw "Python is required for VNAI Gemini transcription." }
        $vnaiGeminiApiKey = if (-not [string]::IsNullOrWhiteSpace($env:VNAIPRO_TRANSCRIPTION_API_KEY)) {
            $env:VNAIPRO_TRANSCRIPTION_API_KEY
        } else { Get-TranslationApiKey -Provider "VNAI Pro Gemini" }
        if ([string]::IsNullOrWhiteSpace($vnaiGeminiApiKey)) { throw "Set or save a VNAI Pro Gemini API key for transcription." }
        $availableModels = @(Get-VnaiProAvailableModels -ApiKey $vnaiGeminiApiKey -Provider "VNAI Pro Gemini")
        if ($VnaiGeminiModel -notin $availableModels) { throw "The VNAI Gemini key cannot access selected model '$VnaiGeminiModel'. Select an available model." }
        Write-RunLog "Transcription engine: VNAI Pro Gemini (cloud)"
        Write-RunLog "Transcription model: $VnaiGeminiModel"
        Write-RunLog "Prepared audio will be uploaded to VNAI Pro in 60-second chunks. Review generated subtitle timings."
    }
    else {
        if ([string]::IsNullOrWhiteSpace($WhisperModel)) {
            Write-RunLog "Opening transcription model picker..."
            $WhisperModel = Select-WhisperModel -DefaultModel "medium.en"
        }

        $whisperExe = Resolve-Executable -PathOrCommand $FasterWhisperPath
        Write-RunLog "Transcription engine: Faster Whisper XXL"
        Write-RunLog "Faster Whisper XXL: $whisperExe"
        Write-RunLog "Transcription model: $WhisperModel"
    }
}
if (-not $SkipTranslation) {
    if ($SrtPostProcessingMode -eq "Prompt") {
        $SrtPostProcessingMode = Select-SrtPostProcessingMode -DefaultMode "TwoLineTextAndTiming"
    }

    if ($PromptTranslationProvider) {
        $TranslationProvider = Select-TranslationProvider -DefaultProvider $TranslationProvider
    }

    if ($TranslationProvider -eq "Local NLLB") {
        if ($SourceLanguage -eq "auto") { throw "Local NLLB requires an explicit source language, such as English." }
        $OpenAIModel = "nllb-600m-int8"
        $TranslationBaseUrl = "local"
        $PromptTranslationModel = $false
        $EnableTranslationQaPass = $false
        $EnableAutoGenderInference = $false
        $EnableVoiceGenderDetection = $false
        $SrtPostProcessingMode = "None"
        $localPython = Join-Path $script:ScriptRoot ".venv-nllb\Scripts\python.exe"
        if (-not (Test-Path -LiteralPath $localPython) -or -not (Test-Path -LiteralPath (Join-Path $script:ScriptRoot "tools\models\nllb-600m-int8\ready.txt"))) {
            throw "Run Setup-NLLB.bat once to install Local NLLB."
        }
    }

    if ([string]::IsNullOrWhiteSpace($TranslationBaseUrl)) {
        $TranslationBaseUrl = Get-DefaultTranslationBaseUrl -Provider $TranslationProvider
    }

    if ([string]::IsNullOrWhiteSpace($OpenAIModel)) {
        $OpenAIModel = Get-DefaultTranslationModel -Provider $TranslationProvider
    }

    if ($PromptTranslationModel) {
        $OpenAIModel = Select-OpenAIModel -DefaultModel $OpenAIModel -Provider $TranslationProvider
    }
    elseif ([string]::IsNullOrWhiteSpace($OpenAIModel)) {
        $OpenAIModel = Get-DefaultTranslationModel -Provider $TranslationProvider
    }

    if ($TranslationProvider -eq "ElevenLabs Dubbing") {
        $elevenLabsDubbingPythonExe = Resolve-PythonExecutable
        if (-not $elevenLabsDubbingPythonExe) {
            throw "Python was not found. It is required by the ElevenLabs Dubbing adapter."
        }
        if ($EnableTranslationQaPass) {
            Write-RunWarning "Translation QA pass is not supported by ElevenLabs Dubbing and will be skipped."
            $EnableTranslationQaPass = $false
        }
        if ($EnableAutoGenderInference) {
            Write-RunWarning "Auto gender inference is not used by ElevenLabs Dubbing and will be skipped."
            $EnableAutoGenderInference = $false
        }
        if ($EnableVoiceGenderDetection) {
            Write-RunWarning "Voice gender detection is not used by ElevenLabs Dubbing and will be skipped."
            $EnableVoiceGenderDetection = $false
        }
        $OpenAIModel = "automatic"
    }

    Write-RunLog "Translation provider: $TranslationProvider"
    Write-RunLog "Translation endpoint: $TranslationBaseUrl"
    Write-RunLog "$(if ($TranslationProvider -eq 'ElevenLabs Dubbing') { 'Dubbing mode' } else { 'Translation model' }): $OpenAIModel"
    Write-RunLog "Target language: $TargetLanguage"
    Write-RunLog "SRT post-processing: $SrtPostProcessingMode"
    Write-RunLog "Subtitle readability: min $MinCueDurationSeconds s, max $MaxCueDurationSeconds s, max $MaxReadingCharsPerSecond chars/s"
    Write-RunLog "Translation QA pass: $EnableTranslationQaPass"
    if ($TranslationProvider -in @("OpenAI", "VNAI Pro", "VNAI Pro Claude", "VNAI Pro Gemini")) {
        Write-RunLog "Parallel $TranslationProvider translation requests: $MaxParallelTranslations"
    }
    Write-RunLog "Auto gender inference: $EnableAutoGenderInference"
    Write-RunLog "Voice gender detection: $EnableVoiceGenderDetection"
    if (-not [string]::IsNullOrWhiteSpace($SubtitleContextHints)) {
        Write-RunLog "Subtitle context/gender hints: enabled"
    }
    if ($TranslationProvider -eq "ElevenLabs Dubbing") {
        Write-RunLog "Privacy notice: the original media will be uploaded to ElevenLabs Dubbing."
    }
    $apiKey = if ($TranslationProvider -eq "Local NLLB") { $null } else { Get-TranslationApiKey -Provider $TranslationProvider -ForcePrompt $PromptTranslationApiKey }
    if ($TranslationProvider -in @("VNAI Pro", "VNAI Pro Claude", "VNAI Pro Gemini") -and -not [string]::IsNullOrWhiteSpace($apiKey)) {
        $resolvedVnaiModel = Assert-VnaiProModelAccess -ApiKey $apiKey -Model $OpenAIModel -Provider $TranslationProvider
        if (-not [string]::IsNullOrWhiteSpace($resolvedVnaiModel) -and $resolvedVnaiModel -ne $OpenAIModel) {
            $OpenAIModel = $resolvedVnaiModel
            Write-RunLog "Translation model changed to available VNAI model: $OpenAIModel"
        }
    }
    if ($TranslationProvider -eq "ElevenLabs Dubbing" -and -not [string]::IsNullOrWhiteSpace($apiKey)) {
        Assert-ElevenLabsDubbingApiAccess -ApiKey $apiKey
    }
}
if ($useMediaFolderOutput) {
    Write-RunLog "Output folder: same folder as each media file"
}
else {
    Write-RunLog "Output folder: $outputRoot"
}

foreach ($media in $mediaFiles) {
    Write-RunLog ""
    Write-RunLog "Processing: $($media.FullName)"
    $startedAt = Get-Date
    $totalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $transcriptionElapsed = [TimeSpan]::Zero
    $translationElapsed = [TimeSpan]::Zero
    $mediaOutputRoot = if ($useMediaFolderOutput) {
        $media.DirectoryName
    }
    else {
        $outputRoot
    }
    [void](New-Item -ItemType Directory -Force -Path $mediaOutputRoot)

    $safeLanguage = ($TargetLanguage -replace "[^\p{L}\p{Nd}-]+", "_").Trim("_")
    if (-not $safeLanguage) {
        $safeLanguage = "translated"
    }
    $safeSourceLanguage = ($SourceLanguage -replace "[^\p{L}\p{Nd}-]+", "_").Trim("_")
    if (-not $safeSourceLanguage -or $safeSourceLanguage.ToLowerInvariant() -eq "auto") {
        $safeSourceLanguage = "source"
    }

    if (-not $SkipTranscription) {
        $transcriptionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $transcriptionAudio = $null
        try {
            $transcriptionAudio = New-TranscriptionAudio -MediaPath $media.FullName -FfmpegExecutable $transcriptionFfmpegExe -AudioTrack $AudioTrack
            if ($TranscriptionEngine -eq "MOSS") {
                Write-RunLog "Transcribing and separating speakers with MOSS..."
                $mossExitCode = Invoke-MossTranscription `
                    -PythonExecutable $mossPythonExe `
                    -MediaPath $transcriptionAudio.Path `
                    -OutputRoot $mediaOutputRoot `
                    -Model $MossModel `
                    -MossDeviceName $MossDevice `
                    -MaxNewTokens $MossMaxNewTokens
                if ($mossExitCode -ne 0) {
                    throw "MOSS transcription failed with exit code $mossExitCode."
                }
            }
            elseif ($TranscriptionEngine -eq "ElevenLabs") {
                Write-RunLog "Preparing and uploading audio to ElevenLabs..."
                $elevenLabsExitCode = Invoke-ElevenLabsTranscription `
                    -PythonExecutable $elevenLabsPythonExe `
                    -MediaPath $transcriptionAudio.Path `
                    -OutputRoot $mediaOutputRoot `
                    -Model $ElevenLabsModel `
                    -NumSpeakers $ElevenLabsNumSpeakers `
                    -LanguageCode (ConvertTo-ElevenLabsLanguageCode -Language $SourceLanguage) `
                    -AudioTrack 1 `
                    -FfmpegExecutable $elevenLabsFfmpegExe `
                    -ApiKey $elevenLabsApiKey
                if ($elevenLabsExitCode -ne 0) {
                    throw "ElevenLabs transcription failed with exit code $elevenLabsExitCode."
                }
            }
            elseif ($TranscriptionEngine -eq "VNAIGemini") {
                $vnaiExitCode = Invoke-VnaiGeminiTranscription `
                    -PythonExecutable $vnaiGeminiPythonExe `
                    -MediaPath $transcriptionAudio.Path `
                    -OutputRoot $mediaOutputRoot `
                    -Model $VnaiGeminiModel `
                    -Language $SourceLanguage `
                    -ApiKey $vnaiGeminiApiKey
                if ($vnaiExitCode -ne 0) { throw "VNAI Gemini transcription failed with exit code $vnaiExitCode." }
            }
            else {
                $whisperArgs = @(
                    $transcriptionAudio.Path,
                    "--model", $WhisperModel,
                    "--output_dir", $mediaOutputRoot,
                    "--output_format", $OutputFormat
                )

    <#
            Faster Whisper formatting and extra parameters disabled by request.
            Only model and output location/format are passed from the dropdown above.

            $whisperArgs += @(
                "--device", $Device,
                "--compute_type", $ComputeType,
            )

            if ($StandardSubtitles) {
                $whisperArgs += @(
                    "--standard",
                    "--sentence",
                    "--max_gap", ([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, "{0}", $SentenceMaxGapSeconds)),
                    "--max_line_width", $MaxLineWidth,
                    "--max_line_count", $MaxLineCount,
                    "--max_comma_cent", $MaxCommaCent
                )
            }

            if ($VadSpeechPadMs -ge 0) {
                $whisperArgs += @("--vad_speech_pad_ms", $VadSpeechPadMs)
            }

            if ($VadMinSilenceDurationMs -gt 0) {
                $whisperArgs += @("--vad_min_silence_duration_ms", $VadMinSilenceDurationMs)
            }

            if ($PrintProgress) {
                $whisperArgs += @("--print_progress")
            }

            if ($SourceLanguage -and $SourceLanguage.ToLowerInvariant() -ne "auto") {
                $whisperArgs += @("--language", $SourceLanguage)
            }
    #>

                Write-RunLog "Transcribing with Faster Whisper model $WhisperModel..."
                Write-RunLog "Whisper args: $($whisperArgs -join ' ')"
                $whisperExitCode = Invoke-LoggedProcess -FilePath $whisperExe -Arguments $whisperArgs
                if ($whisperExitCode -ne 0) {
                    throw "Faster Whisper XXL failed with exit code $whisperExitCode."
                }
            }
        }
        finally {
            Remove-TranscriptionAudio -Audio $transcriptionAudio
        }

        $transcriptionStopwatch.Stop()
        $transcriptionElapsed = $transcriptionStopwatch.Elapsed

        $audioDurationSeconds = Get-MediaDurationSeconds -MediaPath $media.FullName -FasterWhisperExecutable $whisperExe
        if ($audioDurationSeconds -and $transcriptionElapsed.TotalSeconds -gt 0) {
            $audioSecondsPerSecond = $audioDurationSeconds / $transcriptionElapsed.TotalSeconds
            Write-RunLog ("Transcription speed: {0:N2} audio sec/sec" -f $audioSecondsPerSecond)
        }
        else {
            Write-RunWarning "Could not calculate transcription speed because media duration was not available."
        }

        Start-Sleep -Milliseconds 500
    }

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($media.Name)
    $exportStem = ($stem -replace '\s*\[[A-Za-z0-9_-]{11}\]', '').Trim()
    if ([string]::IsNullOrWhiteSpace($exportStem)) {
        $exportStem = $stem
    }
    $selectedTranscriptionModel = if ($TranscriptionEngine -eq "MOSS") {
        $MossModel
    }
    elseif ($TranscriptionEngine -eq "ElevenLabs") {
        $ElevenLabsModel
    }
    elseif ($TranscriptionEngine -eq "VNAIGemini") {
        $VnaiGeminiModel
    }
    else {
        $WhisperModel
    }
    $safeTranscriptionModel = Get-SafeFileNamePart -Text $selectedTranscriptionModel -Fallback "transcription"
    $safeTranslationModel = Get-SafeFileNamePart -Text $OpenAIModel -Fallback "translation"
    $mediaSubtitleContextHints = Get-AutoSubtitleContextHints -MediaName $media.Name -ExistingHints $SubtitleContextHints
    if (-not [string]::IsNullOrWhiteSpace($mediaSubtitleContextHints)) {
        Write-RunLog "Media context/gender hints: enabled"
    }
    $postProcessingSuffix = switch ($SrtPostProcessingMode) {
        "None" { "raw" }
        "TwoLineText" { "2line" }
        "TwoLineTextAndTiming" { "2line_timing" }
        "SentenceFlow" { "sentence_flow" }
        default { "post" }
    }
    $voiceGenderSuffix = if ($EnableVoiceGenderDetection) { "_voicegender" } else { "" }
    $translationOutputStem = "{0}_{1}_{2}_{3}_desktop_{4}{5}" -f $exportStem, $safeTranscriptionModel, $safeTranslationModel, $safeLanguage, $postProcessingSuffix, $voiceGenderSuffix
    if ($TranslationProvider -eq "Local NLLB") { $translationOutputStem += "_sentence_v2" }
    $whisperOutputRoots = @($mediaOutputRoot)
    if ($SkipTranscription -and $media.DirectoryName) {
        $whisperOutputRoots += $media.DirectoryName
    }
    if ($whisperExe) {
        $whisperOutputRoots += (Split-Path -Parent $whisperExe)
    }
    $whisperOutputRoots = @($whisperOutputRoots | Where-Object { $_ } | Select-Object -Unique)

    $sourceSrt = if ($SkipTranscription -and $media.Extension -ieq ".srt") {
        $media
    }
    else {
        $null
    }
    if (-not $sourceSrt) {
        foreach ($root in $whisperOutputRoots) {
            $exactSrtPath = Join-Path $root "$stem.srt"
            if (Test-Path -LiteralPath $exactSrtPath) {
                $sourceSrt = Get-Item -LiteralPath $exactSrtPath
                if ($SkipTranscription -or $sourceSrt.LastWriteTime -ge $startedAt.AddSeconds(-5)) {
                    break
                }

                $sourceSrt = $null
            }

            $sourceSrt = Get-ChildItem -LiteralPath $root -Filter "$stem*.srt" -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.BaseName -ne "$stem.$safeLanguage" -and
                    ($SkipTranscription -or $_.LastWriteTime -ge $startedAt.AddSeconds(-5))
                } |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
            if ($sourceSrt) {
                break
            }
        }
    }

    $transcript = $null
    foreach ($root in $whisperOutputRoots) {
        $exactTranscriptPath = Join-Path $root "$stem.txt"
        if (Test-Path -LiteralPath $exactTranscriptPath) {
            $transcript = Get-Item -LiteralPath $exactTranscriptPath
            break
        }

        $transcript = Get-ChildItem -LiteralPath $root -Filter "$stem*.txt" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.BaseName -ne "$stem.$safeLanguage" } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($transcript) {
            break
        }
    }

    if (-not $transcript) {
        $transcript = Get-ChildItem -LiteralPath $mediaOutputRoot -Filter "*.txt" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -ge $startedAt.AddSeconds(-5) -and $_.BaseName -ne "$stem.$safeLanguage" } |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
    }

    $sourceSrt = Copy-GeneratedOutputToTargetFolder -File $sourceSrt -TargetFolder $mediaOutputRoot
    $transcript = Copy-GeneratedOutputToTargetFolder -File $transcript -TargetFolder $mediaOutputRoot

    if ($sourceSrt) {
        Write-RunLog "Source SRT: $($sourceSrt.FullName)"
    }
    if ($transcript) {
        Write-RunLog "Transcript: $($transcript.FullName)"
    }
    if (-not $sourceSrt -and -not $transcript) {
        throw "Could not find the generated .srt or .txt transcript for $($media.Name)."
    }

    # Keep diarization labels in memory for translation context, but hide them
    # from the source SRT as soon as it becomes visible in the web player.
    $sourceSrtTextForTranslation = $null
    if ($sourceSrt -and -not $ShowSpeakerLabels -and $TranslationProvider -ne "ElevenLabs Dubbing") {
        $sourceSrtTextForTranslation = Get-Content -LiteralPath $sourceSrt.FullName -Raw
        if (Hide-SpeakerLabelsInSrtFile -Path $sourceSrt.FullName) {
            Write-RunLog "Speaker labels were kept in memory for translation context and hidden from the source SRT."
        }
    }
    if ($SkipTranslation) {
        if ($sourceSrt -and -not $ShowSpeakerLabels) {
            if (Hide-SpeakerLabelsInSrtFile -Path $sourceSrt.FullName) {
                Write-RunLog "Speaker labels were hidden from the transcription SRT."
            }
        }
        $totalStopwatch.Stop()
        Complete-MediaProcessing `
            -Status "completed" `
            -MediaPath $media.FullName `
            -OutputFolder $mediaOutputRoot `
            -TranscriptionDuration $transcriptionElapsed `
            -TranscriptionSkipped ([bool]$SkipTranscription) `
            -TranslationDuration $translationElapsed `
            -TranslationSkipped $true `
            -TotalDuration $totalStopwatch.Elapsed
        continue
    }

    if ($TranslationProvider -ne "Local NLLB" -and [string]::IsNullOrWhiteSpace($apiKey)) {
        if ($sourceSrt -and -not $ShowSpeakerLabels) {
            if (Hide-SpeakerLabelsInSrtFile -Path $sourceSrt.FullName) {
                Write-RunLog "Speaker labels were hidden from the transcription SRT."
            }
        }
        $totalStopwatch.Stop()
        throw "No $TranslationProvider API key was provided. Translation was not run; only the source transcription was created."
    }

    $translationStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
    if ($TranslationProvider -eq "ElevenLabs Dubbing") {
        if ($media.Extension -in @(".srt", ".txt")) {
            throw "ElevenLabs Dubbing requires an audio or video input, not $($media.Extension)."
        }
        if (-not $sourceSrt) {
            throw "ElevenLabs Dubbing subtitle alignment requires a source SRT from Scribe."
        }

        $translatedSrtPath = Join-Path $mediaOutputRoot "$translationOutputStem.srt"
        $translatedDraftSrtPath = Join-Path $mediaOutputRoot "$translationOutputStem.draft.srt"
        $sourceDubbingLanguage = ConvertTo-ElevenLabsDubbingLanguageCode -Language $SourceLanguage -AllowAuto $true
        $targetDubbingLanguage = ConvertTo-ElevenLabsDubbingLanguageCode -Language $TargetLanguage
        if ([string]::IsNullOrWhiteSpace($targetDubbingLanguage)) {
            throw "Could not determine the ElevenLabs Dubbing target language code for '$TargetLanguage'."
        }

        Write-RunLog "Starting ElevenLabs Dubbing translation ($sourceDubbingLanguage -> $targetDubbingLanguage)..."
        $dubbingExitCode = Invoke-ElevenLabsDubbing `
            -PythonExecutable $elevenLabsDubbingPythonExe `
            -MediaPath $media.FullName `
            -OutputSrtPath $translatedDraftSrtPath `
            -SourceSrtPath $sourceSrt.FullName `
            -SourceLanguageCode $sourceDubbingLanguage `
            -TargetLanguageCode $targetDubbingLanguage `
            -NumSpeakers $ElevenLabsNumSpeakers `
            -ApiKey $apiKey
        if ($dubbingExitCode -ne 0) {
            throw "ElevenLabs Dubbing failed with exit code $dubbingExitCode."
        }
        if (-not (Test-Path -LiteralPath $translatedDraftSrtPath -PathType Leaf)) {
            throw "ElevenLabs Dubbing completed without creating the translated SRT."
        }

        $finalTranslatedSrt = Get-Content -LiteralPath $translatedDraftSrtPath -Raw
        if ([string]::IsNullOrWhiteSpace($finalTranslatedSrt)) {
            throw "ElevenLabs Dubbing returned an empty translated SRT."
        }

        if ($SrtPostProcessingMode -eq "TwoLineText") {
            $finalTranslatedSrt = Format-SrtCueTextOnly `
                -Srt $finalTranslatedSrt `
                -MaxLineWidth $MaxLineWidth `
                -MaxLineCount $MaxLineCount
        }
        elseif ($SrtPostProcessingMode -eq "TwoLineTextAndTiming") {
            $finalTranslatedSrt = Split-LongSrtCuesLocally `
                -Srt $finalTranslatedSrt `
                -MaxCueDurationSeconds $MaxCueDurationSeconds `
                -MaxLineWidth $MaxLineWidth `
                -MaxLineCount $MaxLineCount
        }
        elseif ($SrtPostProcessingMode -eq "SentenceFlow") {
            $finalTranslatedSrt = Repair-SrtOrphanCuePrefixes `
                -Srt $finalTranslatedSrt `
                -MaxLineWidth $MaxLineWidth `
                -MaxLineCount $MaxLineCount

            $finalTranslatedSrt = Normalize-SrtCueFlow `
                -Srt $finalTranslatedSrt `
                -MaxCueDurationSeconds $MaxCueDurationSeconds `
                -SentenceMaxGapSeconds $SentenceMaxGapSeconds `
                -MaxLineWidth $MaxLineWidth `
                -MaxLineCount $MaxLineCount

            $finalTranslatedSrt = Optimize-TranslatedSrtTiming `
                -Srt $finalTranslatedSrt `
                -MinCueDurationSeconds $MinCueDurationSeconds `
                -MaxCueDurationSeconds $MaxCueDurationSeconds `
                -MaxLineWidth $MaxLineWidth `
                -MaxLineCount $MaxLineCount
        }

        if ($SrtPostProcessingMode -ne "None") {
            Write-RunLog "Applying final subtitle quality pass..."
            $finalTranslatedSrt = Invoke-FinalSrtQualityPass `
                -Srt $finalTranslatedSrt `
                -TargetLanguage $TargetLanguage `
                -SubtitleContextHints $mediaSubtitleContextHints `
                -MinCueDurationSeconds $MinCueDurationSeconds `
                -MaxCueDurationSeconds $MaxCueDurationSeconds `
                -MaxReadingCharsPerSecond $MaxReadingCharsPerSecond `
                -MaxLineWidth $MaxLineWidth `
                -MaxLineCount $MaxLineCount
        }
        else {
            Write-RunLog "Final subtitle quality pass skipped: SRT post-processing is None."
        }
        if (-not $ShowSpeakerLabels) {
            $finalTranslatedSrt = Remove-MossSpeakerLabelsFromSrt -Srt $finalTranslatedSrt
            Write-RunLog "Speaker labels were kept for translation context and hidden from the final SRT."
        }
        if (-not (Test-TranslationLooksLikeTargetLanguage -Text $finalTranslatedSrt -TargetLanguage $TargetLanguage)) {
            throw "ElevenLabs Dubbing output does not look like $TargetLanguage text. The translated file was not written."
        }

        Set-Content -LiteralPath $translatedSrtPath -Value $finalTranslatedSrt -Encoding UTF8
        Remove-Item -LiteralPath $translatedDraftSrtPath -Force
        $translationStopwatch.Stop()
        $translationElapsed = $translationStopwatch.Elapsed
        $totalStopwatch.Stop()
        Write-RunLog "Translated SRT: $translatedSrtPath"
        Complete-MediaProcessing `
            -Status "completed" `
            -MediaPath $media.FullName `
            -OutputFolder $mediaOutputRoot `
            -TranscriptionDuration $transcriptionElapsed `
            -TranscriptionSkipped ([bool]$SkipTranscription) `
            -TranslationDuration $translationElapsed `
            -TranslationSkipped $false `
            -TotalDuration $totalStopwatch.Elapsed
        continue
    }

    if ($TranslationProvider -eq "Local NLLB") {
        if (-not $sourceSrt) { throw "Local NLLB requires SRT input. Select SRT transcription output or an existing .srt file." }
        $translatedSrtPath = Join-Path $mediaOutputRoot "$translationOutputStem.srt"
        $localArguments = @(
            (Join-Path $script:ScriptRoot "tools\translate_nllb.py"),
            $sourceSrt.FullName, $translatedSrtPath,
            "--source-language", $SourceLanguage, "--target-language", $TargetLanguage
        )
        $glossaryPath = [System.IO.Path]::ChangeExtension($media.FullName, ".nllb-glossary.json")
        if (Test-Path -LiteralPath $glossaryPath) { $localArguments += @("--glossary", $glossaryPath) }
        if ($ShowSpeakerLabels) { $localArguments += "--show-speaker-labels" }
        Write-RunLog "Starting offline NLLB translation on CPU (INT8, 4 threads)..."
        $localExitCode = Invoke-LoggedProcess -FilePath $localPython -Arguments $localArguments -Utf8Output
        if ($localExitCode -ne 0 -or -not (Test-Path -LiteralPath $translatedSrtPath)) {
            throw "Local NLLB translation failed (exit $localExitCode)."
        }
        $translationStopwatch.Stop()
        $translationElapsed = $translationStopwatch.Elapsed
        $totalStopwatch.Stop()
        Write-RunLog "Translated SRT: $translatedSrtPath"
        Complete-MediaProcessing -Status "completed" -MediaPath $media.FullName -OutputFolder $mediaOutputRoot -TranscriptionDuration $transcriptionElapsed -TranscriptionSkipped ([bool]$SkipTranscription) -TranslationDuration $translationElapsed -TranslationSkipped $false -TotalDuration $totalStopwatch.Elapsed
        continue
    }

    $translationModels = @(Get-TranslationModelFallbacks -Provider $TranslationProvider -SelectedModel $OpenAIModel)
    if ($sourceSrt) {
        $sourceSrtText = if ($null -ne $sourceSrtTextForTranslation) {
            $sourceSrtTextForTranslation
        }
        else {
            Get-Content -LiteralPath $sourceSrt.FullName -Raw
        }
        if ([string]::IsNullOrWhiteSpace($sourceSrtText)) {
            throw "Source SRT is empty: $($sourceSrt.FullName)"
        }

        $effectiveSubtitleContextHints = $mediaSubtitleContextHints
        if ($EnableVoiceGenderDetection) {
            $voiceGenderHints = Get-VoiceGenderHintsFromAudio -MediaPath $media.FullName -SourceSrtPath $sourceSrt.FullName
            if (-not [string]::IsNullOrWhiteSpace($voiceGenderHints)) {
                $effectiveSubtitleContextHints = (($effectiveSubtitleContextHints, $voiceGenderHints) |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "`r`n`r`n"
            }
        }

        $srtChunks = @(Split-SrtForModel -Srt $sourceSrtText -MaxChars $MaxChunkChars)
        $translatedSrtChunks = New-Object System.Collections.Generic.List[string]

        if ($TranslationProvider -in @("OpenAI", "VNAI Pro", "VNAI Pro Claude", "VNAI Pro Gemini") -and $srtChunks.Count -gt 1 -and $MaxParallelTranslations -gt 1) {
            $translationWorkItems = @(
                for ($i = 0; $i -lt $srtChunks.Count; $i++) {
                    [pscustomobject]@{
                        Index = $i
                        Mode = "Srt"
                        SourceText = $srtChunks[$i]
                        TranslatedText = ""
                        TargetLanguage = $TargetLanguage
                        Model = $translationModels[0]
                        ApiKey = $apiKey
                        BaseUrl = $TranslationBaseUrl
                        Provider = $TranslationProvider
                        EnableAutoGenderInference = $EnableAutoGenderInference
                        SubtitleContextHints = $effectiveSubtitleContextHints
                        ChunkNumber = $i + 1
                        ChunkCount = $srtChunks.Count
                    }
                }
            )
            Write-RunLog "Translating $($srtChunks.Count) SRT chunks with up to $MaxParallelTranslations parallel $TranslationProvider requests..."
            $parallelTranslations = @(Invoke-ParallelTranslationWorkItems -WorkItems $translationWorkItems -MaxConcurrency $MaxParallelTranslations)
            foreach ($result in $parallelTranslations) {
                $translatedSrtChunks.Add(([string]$result.Text).Trim())
            }
        }
        else {
            for ($i = 0; $i -lt $srtChunks.Count; $i++) {
                $translatedSrt = $null
                $lastTranslationError = $null
                foreach ($translationModel in $translationModels) {
                    Write-RunLog "Translating SRT chunk $($i + 1)/$($srtChunks.Count) with $translationModel..."
                    try {
                        $translatedSrt = Invoke-OpenAISrtTranslationWithRepair `
                            -Srt $srtChunks[$i] `
                            -TargetLanguage $TargetLanguage `
                            -Model $translationModel `
                            -ApiKey $apiKey `
                            -BaseUrl $TranslationBaseUrl `
                            -Provider $TranslationProvider `
                            -EnableAutoGenderInference $EnableAutoGenderInference `
                            -SubtitleContextHints $effectiveSubtitleContextHints `
                            -ChunkNumber ($i + 1) `
                            -ChunkCount $srtChunks.Count
                        break
                    }
                    catch {
                        $lastTranslationError = $_
                        if ($translationModel -ne $translationModels[-1]) {
                            Write-RunWarning "Translation with $translationModel failed. Trying $($translationModels[[Array]::IndexOf($translationModels, $translationModel) + 1])..."
                        }
                    }
                }

                if ([string]::IsNullOrWhiteSpace($translatedSrt)) {
                    throw $lastTranslationError
                }

                $translatedSrtChunks.Add($translatedSrt.Trim())
            }
        }

        $translatedSrtPath = Join-Path $mediaOutputRoot "$translationOutputStem.srt"
        $translatedDraftSrtPath = Join-Path $mediaOutputRoot "$translationOutputStem.draft.srt"
        $finalTranslatedSrt = $translatedSrtChunks -join "`r`n`r`n"
        Set-Content -LiteralPath $translatedDraftSrtPath -Value $finalTranslatedSrt -Encoding UTF8
        Write-RunLog "Translation draft checkpoint: $translatedDraftSrtPath"
        if ($EnableTranslationQaPass) {
            $qaTranslatedChunks = New-Object System.Collections.Generic.List[string]
            if ($TranslationProvider -in @("OpenAI", "VNAI Pro", "VNAI Pro Claude", "VNAI Pro Gemini") -and $srtChunks.Count -gt 1 -and $MaxParallelTranslations -gt 1) {
                $qaWorkItems = @(
                    for ($i = 0; $i -lt $srtChunks.Count; $i++) {
                        [pscustomobject]@{
                            Index = $i
                            Mode = "Qa"
                            SourceText = $srtChunks[$i]
                            TranslatedText = $translatedSrtChunks[$i]
                            TargetLanguage = $TargetLanguage
                            Model = $translationModels[0]
                            ApiKey = $apiKey
                            BaseUrl = $TranslationBaseUrl
                            Provider = $TranslationProvider
                            EnableAutoGenderInference = $EnableAutoGenderInference
                            SubtitleContextHints = $effectiveSubtitleContextHints
                            ChunkNumber = $i + 1
                            ChunkCount = $srtChunks.Count
                        }
                    }
                )
                Write-RunLog "QA reviewing $($srtChunks.Count) SRT chunks with up to $MaxParallelTranslations parallel $TranslationProvider requests..."
                $parallelQaResults = @(Invoke-ParallelTranslationWorkItems -WorkItems $qaWorkItems -MaxConcurrency $MaxParallelTranslations)
                foreach ($result in $parallelQaResults) {
                    $qaTranslatedChunks.Add(([string]$result.Text).Trim())
                }
            }
            else {
                for ($i = 0; $i -lt $srtChunks.Count; $i++) {
                    $qaTranslatedSrt = $null
                    $lastQaError = $null
                    foreach ($translationModel in $translationModels) {
                        Write-RunLog "QA reviewing SRT chunk $($i + 1)/$($srtChunks.Count) with $translationModel..."
                        try {
                            $qaTranslatedSrt = Invoke-OpenAISrtTranslationQaPass `
                                -SourceSrt $srtChunks[$i] `
                                -TranslatedSrt $translatedSrtChunks[$i] `
                                -TargetLanguage $TargetLanguage `
                                -Model $translationModel `
                                -ApiKey $apiKey `
                                -BaseUrl $TranslationBaseUrl `
                                -Provider $TranslationProvider `
                                -EnableAutoGenderInference $EnableAutoGenderInference `
                                -SubtitleContextHints $effectiveSubtitleContextHints `
                                -ChunkNumber ($i + 1) `
                                -ChunkCount $srtChunks.Count
                            break
                        }
                        catch {
                            $lastQaError = $_
                            if ($translationModel -ne $translationModels[-1]) {
                                Write-RunWarning "QA pass with $translationModel failed. Trying $($translationModels[[Array]::IndexOf($translationModels, $translationModel) + 1])..."
                            }
                        }
                    }

                    if ([string]::IsNullOrWhiteSpace($qaTranslatedSrt)) {
                        throw $lastQaError
                    }

                    $qaTranslatedChunks.Add($qaTranslatedSrt.Trim())
                }
            }

            $finalTranslatedSrt = $qaTranslatedChunks -join "`r`n`r`n"
        }
        if ($SrtPostProcessingMode -eq "TwoLineText") {
            $finalTranslatedSrt = Format-SrtCueTextOnly `
                -Srt $finalTranslatedSrt `
                -MaxLineWidth $MaxLineWidth `
                -MaxLineCount $MaxLineCount
        }
        elseif ($SrtPostProcessingMode -eq "TwoLineTextAndTiming") {
            $finalTranslatedSrt = Split-LongSrtCuesLocally `
                -Srt $finalTranslatedSrt `
                -MaxCueDurationSeconds $MaxCueDurationSeconds `
                -MaxLineWidth $MaxLineWidth `
                -MaxLineCount $MaxLineCount
        }
        elseif ($SrtPostProcessingMode -eq "SentenceFlow") {
            $finalTranslatedSrt = Repair-SrtOrphanCuePrefixes `
                -Srt $finalTranslatedSrt `
                -MaxLineWidth $MaxLineWidth `
                -MaxLineCount $MaxLineCount

            $finalTranslatedSrt = Normalize-SrtCueFlow `
                -Srt $finalTranslatedSrt `
                -MaxCueDurationSeconds $MaxCueDurationSeconds `
                -SentenceMaxGapSeconds $SentenceMaxGapSeconds `
                -MaxLineWidth $MaxLineWidth `
                -MaxLineCount $MaxLineCount
        }
        if ($SrtPostProcessingMode -eq "SentenceFlow") {
            $finalTranslatedSrt = Optimize-TranslatedSrtTiming `
                -Srt $finalTranslatedSrt `
                -MinCueDurationSeconds $MinCueDurationSeconds `
                -MaxCueDurationSeconds $MaxCueDurationSeconds `
                -MaxLineWidth $MaxLineWidth `
                -MaxLineCount $MaxLineCount
        }
        if ($SrtPostProcessingMode -ne "None") {
            Write-RunLog "Applying final subtitle quality pass..."
            $finalTranslatedSrt = Invoke-FinalSrtQualityPass `
                -Srt $finalTranslatedSrt `
                -TargetLanguage $TargetLanguage `
                -SubtitleContextHints $effectiveSubtitleContextHints `
                -MinCueDurationSeconds $MinCueDurationSeconds `
                -MaxCueDurationSeconds $MaxCueDurationSeconds `
                -MaxReadingCharsPerSecond $MaxReadingCharsPerSecond `
                -MaxLineWidth $MaxLineWidth `
                -MaxLineCount $MaxLineCount
        }
        else {
            Write-RunLog "Final subtitle quality pass skipped: SRT post-processing is None."
        }
        if (-not $ShowSpeakerLabels) {
            $finalTranslatedSrt = Remove-MossSpeakerLabelsFromSrt -Srt $finalTranslatedSrt
            Write-RunLog "Speaker labels were kept for translation context and hidden from the final SRT."
        }
        if (-not (Test-TranslationLooksLikeTargetLanguage -Text $finalTranslatedSrt -TargetLanguage $TargetLanguage)) {
            throw "Translation output does not look like $TargetLanguage text. The translated file was not written."
        }
        Set-Content -LiteralPath $translatedSrtPath -Value $finalTranslatedSrt -Encoding UTF8
        if (Test-Path -LiteralPath $translatedDraftSrtPath) {
            Remove-Item -LiteralPath $translatedDraftSrtPath -Force
        }
        $translationStopwatch.Stop()
        $translationElapsed = $translationStopwatch.Elapsed
        $totalStopwatch.Stop()
        Write-RunLog "Translated SRT: $translatedSrtPath"
        Complete-MediaProcessing `
            -Status "completed" `
            -MediaPath $media.FullName `
            -OutputFolder $mediaOutputRoot `
            -TranscriptionDuration $transcriptionElapsed `
            -TranscriptionSkipped ([bool]$SkipTranscription) `
            -TranslationDuration $translationElapsed `
            -TranslationSkipped $false `
            -TotalDuration $totalStopwatch.Elapsed
        continue
    }

    Write-RunWarning "No .srt file was found for $($media.Name). Falling back to .txt translation."
    $sourceText = Get-Content -LiteralPath $transcript.FullName -Raw
    if ([string]::IsNullOrWhiteSpace($sourceText)) {
        throw "Transcript is empty: $($transcript.FullName)"
    }

    $chunks = @(Split-TextForModel -Text $sourceText -MaxChars $MaxChunkChars)
    $translatedChunks = New-Object System.Collections.Generic.List[string]

    if ($TranslationProvider -in @("OpenAI", "VNAI Pro", "VNAI Pro Claude", "VNAI Pro Gemini") -and $chunks.Count -gt 1 -and $MaxParallelTranslations -gt 1) {
        $textWorkItems = @(
            for ($i = 0; $i -lt $chunks.Count; $i++) {
                [pscustomobject]@{
                    Index = $i
                    Mode = "Text"
                    SourceText = $chunks[$i]
                    TranslatedText = ""
                    TargetLanguage = $TargetLanguage
                    Model = $translationModels[0]
                    ApiKey = $apiKey
                    BaseUrl = $TranslationBaseUrl
                    Provider = $TranslationProvider
                    EnableAutoGenderInference = $EnableAutoGenderInference
                    SubtitleContextHints = $mediaSubtitleContextHints
                    ChunkNumber = $i + 1
                    ChunkCount = $chunks.Count
                }
            }
        )
        Write-RunLog "Translating $($chunks.Count) text chunks with up to $MaxParallelTranslations parallel $TranslationProvider requests..."
        $parallelTextResults = @(Invoke-ParallelTranslationWorkItems -WorkItems $textWorkItems -MaxConcurrency $MaxParallelTranslations)
        foreach ($result in $parallelTextResults) {
            $translatedChunks.Add(([string]$result.Text).Trim())
        }
    }
    else {
        for ($i = 0; $i -lt $chunks.Count; $i++) {
            $translated = $null
            $lastTranslationError = $null
            foreach ($translationModel in $translationModels) {
                Write-RunLog "Translating chunk $($i + 1)/$($chunks.Count) with $translationModel..."
                try {
                    $translated = Invoke-OpenAITranslation `
                        -Text $chunks[$i] `
                        -TargetLanguage $TargetLanguage `
                        -Model $translationModel `
                        -ApiKey $apiKey `
                        -BaseUrl $TranslationBaseUrl `
                        -Provider $TranslationProvider `
                        -EnableAutoGenderInference $EnableAutoGenderInference `
                        -SubtitleContextHints $mediaSubtitleContextHints `
                        -ChunkNumber ($i + 1) `
                        -ChunkCount $chunks.Count
                    break
                }
                catch {
                    $lastTranslationError = $_
                    if ($translationModel -ne $translationModels[-1]) {
                        Write-RunWarning "Translation with $translationModel failed. Trying $($translationModels[[Array]::IndexOf($translationModels, $translationModel) + 1])..."
                    }
                }
            }

            if ([string]::IsNullOrWhiteSpace($translated)) {
                throw $lastTranslationError
            }

            $translatedChunks.Add($translated.Trim())
        }
    }

    $translationPath = Join-Path $mediaOutputRoot "$translationOutputStem.txt"
    $finalTranslatedText = $translatedChunks -join "`r`n`r`n"
    $finalTranslatedText = Apply-SubtitleTextFixups -Srt $finalTranslatedText -TargetLanguage $TargetLanguage -SubtitleContextHints $mediaSubtitleContextHints
    if (-not (Test-TranslationLooksLikeTargetLanguage -Text $finalTranslatedText -TargetLanguage $TargetLanguage)) {
        throw "Translation output does not look like $TargetLanguage text. The translated file was not written."
    }
    Set-Content -LiteralPath $translationPath -Value $finalTranslatedText -Encoding UTF8
    $translationStopwatch.Stop()
    $translationElapsed = $translationStopwatch.Elapsed
    $totalStopwatch.Stop()
    Write-RunLog "Translation: $translationPath"
    Complete-MediaProcessing `
        -Status "completed" `
        -MediaPath $media.FullName `
        -OutputFolder $mediaOutputRoot `
        -TranscriptionDuration $transcriptionElapsed `
        -TranscriptionSkipped ([bool]$SkipTranscription) `
        -TranslationDuration $translationElapsed `
        -TranslationSkipped $false `
        -TotalDuration $totalStopwatch.Elapsed
    }
    catch {
        $translationFailureMessage = $_.Exception.Message
        if ($translationFailureMessage -match "(?i)credit[_ -]?balance|balance[_ -]?too[_ -]?low|insufficient_quota") {
            $translationFailureMessage = "The OpenAI API credit balance is too low. Add API balance in the OpenAI Platform billing page, wait a few minutes for it to update, and then retry."
        }
        if ($translationStopwatch.IsRunning) {
            $translationStopwatch.Stop()
        }
        $translationElapsed = $translationStopwatch.Elapsed
        Write-RunWarning "Translation failed or returned no usable text: $translationFailureMessage"
        if ($sourceSrt) {
            Write-RunWarning "The completed source transcription was kept: $($sourceSrt.FullName)"
            Write-RunWarning "To retry only the translation without another ElevenLabs charge, select this SRT and enable Skip transcription."
        }
        $totalStopwatch.Stop()
        throw "Translation failed: $translationFailureMessage The translated output file was not created."
    }
    finally {
        if ($sourceSrt -and -not $ShowSpeakerLabels) {
            try {
                if (Hide-SpeakerLabelsInSrtFile -Path $sourceSrt.FullName) {
                    Write-RunLog "Speaker labels were hidden from the transcription SRT."
                }
            }
            catch {
                Write-RunWarning "Could not update speaker-label visibility in the source SRT: $($_.Exception.Message)"
            }
        }
    }
}


Wait-RunLogWindow
