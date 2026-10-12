# Shared audio selection for every transcription engine. No model/API calls here.
function Get-MediaAudioTracks {
    param([string]$MediaPath, [string]$FfmpegExecutable)

    $ffprobe = Join-Path (Split-Path -Parent $FfmpegExecutable) 'ffprobe.exe'
    if (-not (Test-Path -LiteralPath $ffprobe -PathType Leaf)) {
        $command = Get-Command 'ffprobe.exe' -ErrorAction SilentlyContinue
        if ($command) { $ffprobe = $command.Source }
        else {
            $bundled = Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -Filter 'ffprobe.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $bundled) { throw 'FFprobe is required to identify audio tracks.' }
            $ffprobe = $bundled.FullName
        }
    }
    $lines = & $ffprobe -v quiet -select_streams a -show_entries 'stream=index,channels:stream_tags=language,title' -of json $MediaPath
    if ($LASTEXITCODE -ne 0) { throw "Could not read audio tracks: $MediaPath" }
    $metadata = ($lines -join "`n") | ConvertFrom-Json
    $ordinal = 0
    foreach ($stream in $metadata.streams) {
        $ordinal++
        $language = 'unknown'
        $title = ''
        if ($stream.PSObject.Properties['tags']) {
            if ($stream.tags.PSObject.Properties['language']) { $language = [string]$stream.tags.language }
            if ($stream.tags.PSObject.Properties['title']) { $title = [string]$stream.tags.title }
        }
        $languageName = Get-AudioLanguageName $language
        [pscustomobject]@{
            Number = $ordinal
            StreamIndex = [int]$stream.index
            Language = $language
            Title = $title
            Label = "Track $ordinal - $languageName$(if ($title) { " - $title" })"
        }
    }
}

function Get-AudioLanguageName {
    param([string]$Language)
    $code = ($Language.ToLowerInvariant() -split '[-_]')[0]
    $names = @{
        en = 'Αγγλικά'; eng = 'Αγγλικά'; english = 'Αγγλικά'
        pl = 'Πολωνικά'; pol = 'Πολωνικά'
        el = 'Ελληνικά'; ell = 'Ελληνικά'; gre = 'Ελληνικά'
        fr = 'Γαλλικά'; fra = 'Γαλλικά'; fre = 'Γαλλικά'
        de = 'Γερμανικά'; deu = 'Γερμανικά'; ger = 'Γερμανικά'
        es = 'Ισπανικά'; spa = 'Ισπανικά'; it = 'Ιταλικά'; ita = 'Ιταλικά'
        unknown = 'Άγνωστη γλώσσα'; und = 'Άγνωστη γλώσσα'
    }
    if ($names.ContainsKey($code)) { return $names[$code] }
    $culture = [Globalization.CultureInfo]::GetCultures('NeutralCultures') | Where-Object {
        $_.TwoLetterISOLanguageName -eq $code -or $_.ThreeLetterISOLanguageName -eq $code
    } | Select-Object -First 1
    if ($culture) { return $culture.EnglishName }
    if ($Language) { return $Language }
    return 'Άγνωστη γλώσσα'
}

function Set-AudioTrackChoices {
    param($Combo, [object[]]$Tracks, [int]$PreferredTrack = 0, [string]$FallbackReason = '')
    $Combo.BeginUpdate()
    try {
        $Combo.Items.Clear()
        $Combo.DisplayMember = 'Label'
        if ($Tracks.Count -gt 0) {
            $auto = Select-MediaAudioTrack -Tracks $Tracks -AudioTrack 0
            [void]$Combo.Items.Add([pscustomobject]@{ Number = 0; Label = "Auto -> Track $($auto.Number) - $(Get-AudioLanguageName $auto.Language)" })
            foreach ($track in $Tracks) { [void]$Combo.Items.Add($track) }
        }
        else {
            [void]$Combo.Items.Add([pscustomobject]@{ Number = 0; Label = "Auto - prefer English ($FallbackReason)" })
            foreach ($number in 1..32) {
                [void]$Combo.Items.Add([pscustomobject]@{ Number = $number; Label = "Track $number - $FallbackReason" })
            }
        }
        $Combo.SelectedIndex = 0
        for ($index = 0; $index -lt $Combo.Items.Count; $index++) {
            if ($Combo.Items[$index].Number -eq $PreferredTrack) { $Combo.SelectedIndex = $index; break }
        }
    }
    finally { $Combo.EndUpdate() }
}

function Select-MediaAudioTrack {
    param([object[]]$Tracks, [ValidateRange(0, 32)][int]$AudioTrack)
    if ($Tracks.Count -eq 0) { throw 'This file has no audio tracks.' }
    if ($AudioTrack -gt $Tracks.Count) {
        throw "Audio Track $AudioTrack was requested, but the media has only $($Tracks.Count) audio track(s)."
    }
    if ($AudioTrack -gt 0) { return $Tracks[$AudioTrack - 1] }
    $english = $Tracks | Where-Object { ($_.Language -split '[-_]')[0] -in @('en', 'eng', 'english') } | Select-Object -First 1
    if ($english) { return $english }
    return $Tracks[0]
}

function New-TranscriptionAudio {
    param([string]$MediaPath, [string]$FfmpegExecutable, [int]$AudioTrack)
    $tracks = @(Get-MediaAudioTracks -MediaPath $MediaPath -FfmpegExecutable $FfmpegExecutable)
    $selected = Select-MediaAudioTrack -Tracks $tracks -AudioTrack $AudioTrack
    Write-RunLog "Audio selected: $($selected.Label) (stream $($selected.StreamIndex), $($tracks.Count) available)"
    $directory = Join-Path ([System.IO.Path]::GetTempPath()) ('faster-whisper-audio-' + [guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($directory)
    # Preserve the original basename so all engines keep their normal SRT filenames.
    $wav = Join-Path $directory ([System.IO.Path]::GetFileNameWithoutExtension($MediaPath) + '.wav')
    try {
        $arguments = @('-hide_banner', '-loglevel', 'error', '-nostdin', '-y',
            '-copyts', '-start_at_zero', '-i', $MediaPath, '-map', "0:$($selected.StreamIndex)",
            '-vn', '-sn', '-dn', '-af', 'aresample=async=1:first_pts=0',
            '-ac', '1', '-ar', '16000', '-c:a', 'pcm_s16le', '-rf64', 'auto', $wav)
        Write-RunLog 'Preparing the selected audio track for transcription...'
        $exitCode = Invoke-LoggedProcess -FilePath $FfmpegExecutable -Arguments $arguments
        if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $wav -PathType Leaf) -or (Get-Item -LiteralPath $wav).Length -le 80) {
            throw "Could not prepare Audio Track $($selected.Number) (FFmpeg exit code $exitCode)."
        }
        return [pscustomobject]@{ Path = $wav; Directory = $directory; Track = $selected }
    }
    catch {
        Remove-TranscriptionAudio -Audio ([pscustomobject]@{ Path = $wav; Directory = $directory })
        throw
    }
}

function Remove-TranscriptionAudio {
    param($Audio)
    if ($null -eq $Audio) { return }
    # Only remove the exact generated file and its now-empty directory, never recurse.
    if (Test-Path -LiteralPath $Audio.Path) { Remove-Item -LiteralPath $Audio.Path -Force -ErrorAction SilentlyContinue }
    try { [System.IO.Directory]::Delete($Audio.Directory, $false) } catch { }
}
