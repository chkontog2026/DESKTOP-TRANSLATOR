"""Real FFmpeg integration checks; model/API boundaries are stubbed, never billed."""
import json
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import wave

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


class AudioTrackTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="audio-track-tests-")
        cls.folder = Path(cls.temp.name)
        cls.media = cls.folder / "two tracks.mkv"
        cls.ffmpeg = shutil.which("ffmpeg")
        if not cls.ffmpeg:
            raise unittest.SkipTest("FFmpeg is required")
        subprocess.run([
            cls.ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", "color=s=32x32:r=5:d=2",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
            "-f", "lavfi", "-i", "sine=frequency=880:duration=2",
            "-map", "0:v", "-map", "1:a", "-map", "2:a", "-c:v", "ffv1", "-c:a", "pcm_s16le",
            "-metadata:s:a:0", "language=fra", "-metadata:s:a:0", "title=French",
            "-metadata:s:a:1", "language=eng", "-metadata:s:a:1", "title=English",
            str(cls.media),
        ], check=True, capture_output=True)
        cls.base = f"""
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. {quote(ROOT / 'tools/audio_tracks.ps1')}
function Write-RunLog {{ param($Message) }}
function Write-RunWarning {{ param($Message) }}
function Invoke-LoggedProcess {{
    param($FilePath, $Arguments)
    & $FilePath @Arguments | Out-Null
    return $LASTEXITCODE
}}
$media = Get-Item -LiteralPath {quote(cls.media)}
$transcriptionFfmpegExe = {quote(cls.ffmpeg)}
"""

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def ps(self, code):
        script = self.folder / "check.ps1"
        script.write_text(self.base + code, encoding="utf-8-sig")
        result = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip()

    def frequency(self, path):
        with wave.open(str(path)) as source:
            self.assertEqual(source.getnchannels(), 1)
            self.assertEqual(source.getframerate(), 16000)
            samples = struct.unpack("<" + "h" * source.getnframes(), source.readframes(source.getnframes()))
        crossings = sum(a <= 0 < b for a, b in zip(samples, samples[1:]))
        return crossings / (len(samples) / 16000)

    def test_selection_uses_audio_ordinal_not_global_stream_index(self):
        result = json.loads(self.ps("""
$tracks = @(Get-MediaAudioTracks $media.FullName $transcriptionFfmpegExe)
@($tracks) | ConvertTo-Json -Compress
"""))
        self.assertEqual([x["StreamIndex"] for x in result], [1, 2])
        self.assertEqual([x["Number"] for x in result], [1, 2])
        self.assertEqual(result[1]["Title"], "English")

    def test_auto_manual_and_cleanup(self):
        for track, expected in [(0, 880), (1, 440), (2, 880)]:
            with self.subTest(track=track):
                output = self.folder / f"track-{track}.wav"
                self.ps(f"""
$audio = New-TranscriptionAudio $media.FullName $transcriptionFfmpegExe {track}
Copy-Item -LiteralPath $audio.Path -Destination {quote(output)}
Remove-TranscriptionAudio $audio
if (Test-Path -LiteralPath $audio.Directory) {{ throw 'Temporary audio was not removed' }}
""")
                self.assertAlmostEqual(self.frequency(output), expected, delta=2)

    def test_no_english_falls_back_to_first(self):
        self.assertEqual(self.ps("""
$tracks = @(Get-MediaAudioTracks $media.FullName $transcriptionFfmpegExe)
$tracks[1].Language = 'unknown'
(Select-MediaAudioTrack $tracks 0).Number
"""), "1")

    def test_invalid_track_and_no_audio_fail(self):
        self.ps("""
try { New-TranscriptionAudio $media.FullName $transcriptionFfmpegExe 3; throw 'NOT REJECTED' }
catch { if ($_.Exception.Message -notlike '*only 2 audio*') { throw } }
try { Select-MediaAudioTrack @() 0; throw 'NOT REJECTED' }
catch { if ($_.Exception.Message -notlike '*no audio tracks*') { throw } }
""")

    def test_delayed_audio_keeps_video_timeline(self):
        delayed = self.folder / 'delayed.mkv'
        output = self.folder / 'delayed.wav'
        subprocess.run([
            self.ffmpeg, '-v', 'error', '-y', '-f', 'lavfi', '-i', 'color=s=32x32:r=5:d=3',
            '-itsoffset', '1', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=1',
            '-map', '0:v', '-map', '1:a', '-c:v', 'ffv1', '-c:a', 'pcm_s16le', str(delayed),
        ], check=True, capture_output=True)
        self.ps(f"""
$audio = New-TranscriptionAudio {quote(delayed)} $transcriptionFfmpegExe 1
Copy-Item -LiteralPath $audio.Path -Destination {quote(output)}
Remove-TranscriptionAudio $audio
""")
        with wave.open(str(output)) as source:
            values = struct.unpack('<' + 'h' * source.getnframes(), source.readframes(source.getnframes()))
        self.assertLess(max(abs(x) for x in values[:15000]), 5)
        self.assertGreater(max(abs(x) for x in values[17000:]), 1000)

    def test_web_form_passes_track_to_every_engine(self):
        import web_server

        with patch.object(web_server, 'JOBS_DIR', self.folder / 'jobs'), \
             patch.object(web_server, 'jobs', {}), \
             patch.object(web_server, 'job_processes', {}), \
             patch.object(web_server, 'load_dotenv', return_value={}), \
             patch.object(web_server.subprocess, 'Popen'), \
             patch.object(web_server.threading, 'Thread'):
            for engine in ['FasterWhisper', 'MOSS', 'ElevenLabs', 'VNAIGemini']:
                result = web_server.start_job({
                    'input_path': str(self.media), 'transcription_engine': engine,
                    'audio_track': '2', 'skip_translation': 'on',
                }, None)
                runner = (self.folder / 'jobs' / result['id'] / 'run.ps1').read_text(encoding='utf-8')
                self.assertRegex(runner, r'-AudioTrack\s+`\s+2')
                self.assertIn(engine, runner)

    def test_desktop_choices_follow_selected_file(self):
        source = (ROOT / 'Transcribe-And-Translate.ps1').read_text(encoding='utf-8-sig')
        start = source.index('    $updateAudioTracks = {')
        block = source[start:source.index('    $audioTrackTimer =', start)]
        # Exercise the actual form update handler using a real WinForms ComboBox.
        self.ps(f"""
Add-Type -AssemblyName System.Windows.Forms
$audioTrackCombo = New-Object System.Windows.Forms.ComboBox
$audioTrackTooltip = New-Object System.Windows.Forms.ToolTip
$script:ScriptRoot = {quote(ROOT)}
$pathBox = [pscustomobject]@{{ Text = '' }}
$fileRadio = [pscustomobject]@{{ Checked = $true }}
$folderRadio = [pscustomobject]@{{ Checked = $false }}
$youtubeRadio = [pscustomobject]@{{ Checked = $false }}
$audioTrackState = @{{ Source = ''; Error = ''; IsFile = $false }}
{block}
try {{
    & $updateAudioTracks
    if ($audioTrackState.Error) {{ throw 'Empty input was treated as a probe failure' }}
    $pathBox.Text = $media.FullName
    & $updateAudioTracks
    if ($audioTrackCombo.Items.Count -ne 3) {{ throw 'Expected Auto plus exactly two real tracks' }}
    if ($audioTrackCombo.Items[0].Label -notlike 'Auto -> Track 2*') {{ throw 'Auto choice not explained' }}
    if ($audioTrackCombo.Items[1].Label -notlike '*French*') {{ throw 'First title missing' }}
    if ($audioTrackCombo.Items[2].Label -notlike '*English*') {{ throw 'Second title missing' }}
    $audioTrackCombo.SelectedIndex = 2
    & $updateAudioTracks
    if ($audioTrackCombo.SelectedItem.Number -ne 2) {{ throw 'Selection was lost' }}
    $tracks = @(Get-MediaAudioTracks $media.FullName $transcriptionFfmpegExe)
    Set-AudioTrackChoices -Combo $audioTrackCombo -Tracks @($tracks[0]) -PreferredTrack 2
    if ($audioTrackCombo.Items.Count -ne 2 -or $audioTrackCombo.SelectedItem.Number -ne 0) {{ throw 'Stale track retained for a different file' }}
    $fileRadio.Checked = $false
    $folderRadio.Checked = $true
    & $updateAudioTracks
    if ($audioTrackCombo.Items.Count -ne 33 -or $audioTrackCombo.Items[1].Label -notlike '*per file*') {{ throw 'Folder fallback is ambiguous' }}
}} finally {{ $audioTrackCombo.Dispose(); $audioTrackTooltip.Dispose() }}
""")

    def test_real_engine_dispatch_and_cleanup_on_success_and_failure(self):
        source = (ROOT / "Transcribe-And-Translate.ps1").read_text(encoding="utf-8-sig")
        start = source.index("    if (-not $SkipTranscription) {", source.index("foreach ($media in $mediaFiles)"))
        block = source[start:source.index("    $stem =", start)]
        for engine in ["FasterWhisper", "MOSS", "ElevenLabs", "VNAIGemini"]:
            for fail in [False, True]:
                with self.subTest(engine=engine, fail=fail):
                    output = self.folder / f"{engine}-{fail}.wav"
                    self.ps(f"""
$SkipTranscription = $false
$TranscriptionEngine = {quote(engine)}
$AudioTrack = 2
$mediaOutputRoot = {quote(self.folder)}
$mossPythonExe = $elevenLabsPythonExe = 'stub'
$vnaiGeminiPythonExe = 'stub'
$VnaiGeminiModel = 'gemini-3.8-flash'
$vnaiGeminiApiKey = 'not-a-real-key'
$MossModel = $ElevenLabsModel = $WhisperModel = 'stub'
$MossDevice = 'cpu'
$MossMaxNewTokens = $ElevenLabsNumSpeakers = 0
$SourceLanguage = 'English'
$elevenLabsFfmpegExe = $transcriptionFfmpegExe
$elevenLabsApiKey = 'not-a-real-key'
$whisperExe = 'fake-whisper'
$OutputFormat = 'srt'
$script:receivedPath = ''
function Record-Audio {{
    param($Path)
    $script:receivedPath = $Path
    Copy-Item -LiteralPath $Path -Destination {quote(output)}
    if (${str(fail).lower()}) {{ return 7 }}
    return 0
}}
function Invoke-MossTranscription {{
    param($PythonExecutable,$MediaPath,$OutputRoot,$Model,$MossDeviceName,$MaxNewTokens)
    Record-Audio $MediaPath
}}
function Invoke-VnaiGeminiTranscription {{
    param($PythonExecutable,$MediaPath,$OutputRoot,$Model,$Language,$ApiKey)
    if ($Model -ne 'gemini-3.8-flash') {{ throw 'VNAI model not passed through' }}
    Record-Audio $MediaPath
}}
function Invoke-ElevenLabsTranscription {{
    param($PythonExecutable,$MediaPath,$OutputRoot,$Model,$NumSpeakers,$LanguageCode,$AudioTrack,$FfmpegExecutable,$ApiKey)
    if ($AudioTrack -ne 1) {{ throw 'Prepared audio must use its only track' }}
    Record-Audio $MediaPath
}}
function ConvertTo-ElevenLabsLanguageCode {{ param($Language) 'en' }}
function Get-MediaDurationSeconds {{ param($MediaPath,$FasterWhisperExecutable) 2 }}
function Invoke-LoggedProcess {{
    param($FilePath,$Arguments)
    if ($FilePath -eq 'fake-whisper') {{ return Record-Audio $Arguments[0] }}
    & $FilePath @Arguments | Out-Null
    return $LASTEXITCODE
}}
$caught = $false
try {{
{block}
}} catch {{
    $caught = $true
    if ($_.Exception.Message -notlike '*exit code 7*') {{ throw }}
}}
if ($caught -ne ${str(fail).lower()}) {{ throw 'Unexpected engine error handling' }}
if (-not $script:receivedPath) {{ throw 'Engine never received audio' }}
if ([IO.Path]::GetFileName($script:receivedPath) -ne 'two tracks.wav') {{ throw 'Output basename changed' }}
if (Test-Path -LiteralPath (Split-Path -Parent $script:receivedPath)) {{ throw 'Audio leaked after engine call' }}
""")
                    self.assertAlmostEqual(self.frequency(output), 880, delta=2)


if __name__ == "__main__":
    unittest.main()
