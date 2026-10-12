from __future__ import annotations

import base64
import html
import json
import mimetypes
import os
import re
import signal
import secrets
import socket
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse


ROOT = Path(__file__).resolve().parent
SCRIPT = ROOT / "Transcribe-And-Translate.ps1"
JOBS_DIR = ROOT / "web_jobs"
UPLOADS_DIR = JOBS_DIR / "uploads"
DEFAULT_PORT = int(os.environ.get("FASTER_WHISPER_WEB_PORT", "8765"))
OFFICIAL_MOSS_MODEL = "OpenMOSS-Team/MOSS-Transcribe-Diarize"


def load_web_auth() -> tuple[str, str]:
    username = os.environ.get("FASTER_WHISPER_WEB_USERNAME", "tablet")
    password = os.environ.get("FASTER_WHISPER_WEB_PASSWORD", "")
    auth_file = ROOT / ".web-auth"
    if not password and auth_file.is_file():
        try:
            lines = auth_file.read_text(encoding="utf-8").splitlines()
            if len(lines) >= 2:
                username = lines[0].strip() or username
                password = lines[1].strip()
        except OSError:
            pass
    return username, password


WEB_AUTH_USERNAME, WEB_AUTH_PASSWORD = load_web_auth()

MEDIA_EXTENSIONS = {".mp3", ".wav", ".m4a", ".mp4", ".mkv", ".mov", ".avi", ".flac", ".webm"}

jobs: dict[str, dict] = {}
job_processes: dict[str, subprocess.Popen[str]] = {}
jobs_lock = threading.Lock()


def load_dotenv() -> dict[str, str]:
    env = os.environ.copy()
    env_path = ROOT / ".env"
    if not env_path.exists():
        return env

    for raw_line in env_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in env:
            env[key] = value
    return env


def local_ip() -> str:
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.connect(("8.8.8.8", 80))
            return sock.getsockname()[0]
    except OSError:
        return "127.0.0.1"


def safe_filename(name: str) -> str:
    base = Path(name).name.strip()
    base = re.sub(r"[^A-Za-z0-9._ -]+", "_", base)
    return base or f"upload-{int(time.time())}.bin"


def bool_value(value: str | None, default: bool) -> bool:
    if value is None or value == "":
        return default
    return value.lower() in {"1", "true", "yes", "on"}


def ps_bool(value: bool) -> str:
    return "$true" if value else "$false"


def ps_bool_arg(name: str, value: bool) -> str:
    return f"-{name}:{ps_bool(value)}"


def ps_quote(value: str | Path) -> str:
    return "'" + str(value).replace("'", "''") + "'"


def append_log(job_id: str, line: str) -> None:
    with jobs_lock:
        job = jobs.get(job_id)
        if not job:
            return
        job["log"].append(line.rstrip("\r\n"))
        job["log"] = job["log"][-1200:]


def output_files(job: dict) -> list[dict]:
    output_dir = Path(job["output_dir"])
    if not output_dir.exists():
        return []

    files = []
    for path in sorted(output_dir.rglob("*"), key=lambda item: item.stat().st_mtime, reverse=True):
        if not path.is_file():
            continue
        rel = path.relative_to(output_dir).as_posix()
        files.append(
            {
                "name": rel,
                "path": str(path),
                "size": path.stat().st_size,
                "mtime": int(path.stat().st_mtime),
                "download": f"/api/download?path={quote(str(path))}",
            }
        )
    return files


def recover_finished_jobs() -> None:
    """Restore downloadable output folders after a Web UI server restart."""
    if not JOBS_DIR.exists():
        return

    recovered: dict[str, dict] = {}
    for job_dir in JOBS_DIR.iterdir():
        if (
            not job_dir.is_dir()
            or job_dir.name == "uploads"
            or (job_dir / ".web-hidden").exists()
        ):
            continue
        output_dir = job_dir / "output"
        output_paths = [path for path in output_dir.rglob("*") if path.is_file()] if output_dir.exists() else []
        if not output_paths:
            continue
        try:
            started_at = int(time.mktime(time.strptime(job_dir.name[:15], "%Y%m%d-%H%M%S")))
        except (ValueError, OverflowError):
            started_at = int(job_dir.stat().st_mtime)
        finished_at = int(max(path.stat().st_mtime for path in output_paths))
        recovered[job_dir.name] = {
            "id": job_dir.name,
            "status": "completed",
            "started_at": started_at,
            "finished_at": finished_at,
            "return_code": 0,
            "output_dir": str(output_dir),
            "source": "Ανακτήθηκε μετά από επανεκκίνηση του Web UI",
            "log": ["Το job ανακτήθηκε από τα αποθηκευμένα αρχεία εξόδου."],
        }

    with jobs_lock:
        for job_id, job in recovered.items():
            jobs.setdefault(job_id, job)


def terminate_process_tree(process: subprocess.Popen[str]) -> None:
    """Stop the job runner and every transcription/translation child process."""
    if process.poll() is not None:
        return

    if os.name == "nt":
        completed = subprocess.run(
            ["taskkill.exe", "/PID", str(process.pid), "/T", "/F"],
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            timeout=20,
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
            check=False,
        )
        if completed.returncode != 0 and process.poll() is None:
            detail = (completed.stderr or completed.stdout).strip()
            raise RuntimeError(detail or f"taskkill failed with exit code {completed.returncode}")
        return

    os.killpg(os.getpgid(process.pid), signal.SIGTERM)


def cancel_job(job_id: str) -> dict:
    with jobs_lock:
        job = jobs.get(job_id)
        if job is None:
            raise KeyError(job_id)
        if job["status"] == "cancelling":
            return dict(job)
        if job["status"] != "running":
            raise ValueError("Το job έχει ήδη ολοκληρωθεί.")

        process = job_processes.get(job_id)
        if process is None:
            raise RuntimeError("Δεν βρέθηκε η ενεργή διεργασία του job.")

        job["status"] = "cancelling"
        job["log"].append("Cancellation requested from the Web UI...")
        snapshot = dict(job)

    try:
        terminate_process_tree(process)
    except Exception:
        with jobs_lock:
            current = jobs.get(job_id)
            if current is not None and current["status"] == "cancelling":
                current["status"] = "running"
                current["log"].append("Cancellation failed; the job is still running.")
        raise

    return snapshot


def start_job(form: dict[str, str], uploaded_file: Path | None) -> dict:
    job_id = time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8]
    job_dir = JOBS_DIR / job_id
    output_dir = job_dir / "output"
    output_dir.mkdir(parents=True, exist_ok=True)

    youtube_url = form.get("youtube_url", "").strip()
    input_path = form.get("input_path", "").strip()
    download_only = bool_value(form.get("download_only"), False)
    if uploaded_file:
        input_path = str(uploaded_file)
    if not youtube_url and not input_path:
        raise ValueError("Δώσε YouTube URL, τοπικό path ή ανέβασε αρχείο.")
    if download_only and not youtube_url:
        raise ValueError("Η επιλογή «Μόνο λήψη βίντεο» απαιτεί YouTube URL.")

    transcription_engine = form.get("transcription_engine", "ElevenLabs").strip() or "ElevenLabs"
    if transcription_engine not in {"FasterWhisper", "MOSS", "ElevenLabs", "VNAIGemini"}:
        raise ValueError("Μη έγκυρη transcription engine.")

    vnai_gemini_model = form.get("vnai_gemini_model", "gemini-3.8-flash").strip() or "gemini-3.8-flash"
    if vnai_gemini_model not in {"gemini-3.8-flash", "gemini-3.7-flash", "gemini-3.6-flash"}:
        raise ValueError("Μη έγκυρο VNAI Gemini transcription model.")

    translation_provider = form.get("translation_provider", "OpenAI").strip() or "OpenAI"
    if translation_provider not in {"Gemini", "OpenAI", "VNAI Pro", "VNAI Pro Claude", "VNAI Pro Gemini", "AI Prime Tech", "ElevenLabs Dubbing", "Local NLLB"}:
        raise ValueError("Μη έγκυρος translation provider.")

    if translation_provider == "Local NLLB" and not bool_value(form.get("skip_translation"), False) and not download_only:
        from tools.translate_nllb import language
        language(form.get("source_language", "English").strip() or "auto")
        language(form.get("target_language", "Greek").strip() or "Greek")
        if not (ROOT / "tools/models/nllb-600m-int8/ready.txt").is_file():
            raise ValueError("Εκτελέστε πρώτα το Setup-NLLB.bat για την εγκατάσταση του τοπικού μοντέλου.")

    moss_model = form.get("moss_model", OFFICIAL_MOSS_MODEL).strip() or OFFICIAL_MOSS_MODEL
    if transcription_engine == "MOSS" and moss_model != OFFICIAL_MOSS_MODEL:
        raise ValueError("Το Web UI επιτρέπει μόνο το επίσημο MOSS model.")

    moss_device = form.get("moss_device", "auto").strip() or "auto"
    if moss_device not in {"auto", "cpu", "cuda"}:
        raise ValueError("Μη έγκυρο MOSS device.")

    try:
        moss_max_new_tokens = int(form.get("moss_max_new_tokens", "0").strip() or "0")
    except ValueError as exc:
        raise ValueError("Το MOSS max output tokens πρέπει να είναι ακέραιος.") from exc
    if not 0 <= moss_max_new_tokens <= 65_536:
        raise ValueError("Το MOSS max output tokens πρέπει να είναι από 0 έως 65536.")

    try:
        elevenlabs_num_speakers = int(form.get("elevenlabs_num_speakers", "0").strip() or "0")
    except ValueError as exc:
        raise ValueError("Ο αριθμός ομιλητών ElevenLabs πρέπει να είναι ακέραιος.") from exc
    if not 0 <= elevenlabs_num_speakers <= 32:
        raise ValueError("Ο αριθμός ομιλητών ElevenLabs πρέπει να είναι από 0 έως 32.")

    try:
        audio_track = int(form.get("audio_track", "0").strip() or "0")
    except ValueError as exc:
        raise ValueError("Το audio track πρέπει να είναι ακέραιος.") from exc
    if not 0 <= audio_track <= 32:
        raise ValueError("Το audio track πρέπει να είναι από 0 (Auto) έως 32.")

    script_args = [
        ps_quote(SCRIPT),
        "-Headless",
        "-OutputDir",
        ps_quote(output_dir),
        "-TranscriptionEngine",
        ps_quote(transcription_engine),
        "-VnaiGeminiModel",
        ps_quote(vnai_gemini_model),
        "-WhisperModel",
        ps_quote(form.get("whisper_model", "medium.en").strip() or "medium.en"),
        "-MossModel",
        ps_quote(moss_model),
        "-MossDevice",
        ps_quote(moss_device),
        "-MossMaxNewTokens",
        str(moss_max_new_tokens),
        "-ElevenLabsModel",
        ps_quote("scribe_v2"),
        "-ElevenLabsNumSpeakers",
        str(elevenlabs_num_speakers),
        "-SourceLanguage",
        ps_quote(form.get("source_language", "English").strip() or "auto"),
        "-AudioTrack",
        str(audio_track),
        ps_bool_arg(
            "ShowSpeakerLabels",
            bool_value(form.get("show_speaker_labels"), False),
        ),
        "-YouTubeQuality",
        ps_quote(form.get("youtube_quality", "Maximum").strip() or "Maximum"),
        "-YouTubeCookiesFromBrowser",
        ps_quote(form.get("youtube_cookies", "").strip()),
        "-YouTubeCookiesFile",
        ps_quote(form.get("youtube_cookies_file", "").strip()),
        "-TranslationProvider",
        ps_quote(translation_provider),
        "-PromptTranslationProvider:$false",
        "-PromptTranslationModel:$false",
        "-TargetLanguage",
        ps_quote(form.get("target_language", "Greek").strip() or "Greek"),
        "-MaxParallelTranslations",
        "3",
        "-SrtPostProcessingMode",
        ps_quote(form.get("post_processing", "None").strip() or "None"),
        ps_bool_arg("EnableTranslationQaPass", bool_value(form.get("translation_qa"), False)),
        ps_bool_arg("EnableAutoGenderInference", bool_value(form.get("auto_gender"), False)),
        ps_bool_arg("EnableVoiceGenderDetection", bool_value(form.get("voice_gender"), False)),
    ]

    model = form.get("translation_model", "").strip()
    if model:
        script_args += ["-OpenAIModel", ps_quote(model)]

    hints = form.get("subtitle_hints", "").strip()
    if hints:
        script_args += ["-SubtitleContextHints", ps_quote(hints)]

    if youtube_url:
        script_args += ["-YouTubeUrl", ps_quote(youtube_url)]
    else:
        script_args += ["-InputPath", ps_quote(input_path)]

    if download_only:
        script_args.append("-DownloadYouTubeOnly")
    if bool_value(form.get("skip_transcription"), False):
        script_args.append("-SkipTranscription")
    if bool_value(form.get("skip_translation"), False):
        script_args.append("-SkipTranslation")

    runner = job_dir / "run.ps1"
    runner.write_text(
        "$ErrorActionPreference = 'Stop'\n"
        "& " + " `\n  ".join(script_args) + "\n",
        encoding="utf-8",
    )
    command = [
        "powershell.exe",
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(runner),
    ]

    job = {
        "id": job_id,
        "status": "running",
        "started_at": int(time.time()),
        "finished_at": None,
        "return_code": None,
        "output_dir": str(output_dir),
        "source": youtube_url or input_path,
        "log": ["Starting job..."],
    }

    with jobs_lock:
        jobs[job_id] = job

    env = load_dotenv()
    elevenlabs_api_key = form.get("elevenlabs_api_key", "").strip()
    if elevenlabs_api_key:
        env["ELEVENLABS_API_KEY"] = elevenlabs_api_key
    vnai_transcription_key = form.get("vnai_transcription_api_key", "").strip()
    if vnai_transcription_key and transcription_engine == "VNAIGemini":
        env["VNAIPRO_TRANSCRIPTION_API_KEY"] = vnai_transcription_key
    process = subprocess.Popen(
        command,
        cwd=str(ROOT),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=env,
        creationflags=(
            getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
            if os.name == "nt"
            else 0
        ),
        start_new_session=os.name != "nt",
    )
    with jobs_lock:
        job["pid"] = process.pid
        job_processes[job_id] = process

    def pump() -> None:
        try:
            assert process.stdout is not None
            for line in process.stdout:
                append_log(job_id, line)
            return_code = process.wait()
            with jobs_lock:
                current = jobs[job_id]
                current["return_code"] = return_code
                current["finished_at"] = int(time.time())
                if current["status"] == "cancelling":
                    current["status"] = "cancelled"
                    current["log"].append("Job cancelled.")
                else:
                    current["status"] = "completed" if return_code == 0 else "failed"
                current["files"] = output_files(current)
        except Exception as exc:
            with jobs_lock:
                current = jobs[job_id]
                current["status"] = (
                    "cancelled" if current["status"] == "cancelling" else "failed"
                )
                current["finished_at"] = int(time.time())
                current["log"].append(f"Server error: {exc}")
        finally:
            with jobs_lock:
                job_processes.pop(job_id, None)

    threading.Thread(target=pump, daemon=True).start()
    return job


def parse_multipart(content_type: str, body: bytes) -> tuple[dict[str, str], Path | None]:
    match = re.search(r"boundary=(.+)", content_type)
    if not match:
        raise ValueError("Missing multipart boundary.")
    boundary = ("--" + match.group(1).strip('"')).encode()
    form: dict[str, str] = {}
    uploaded_file: Path | None = None

    for part in body.split(boundary):
        part = part.strip(b"\r\n")
        if not part or part == b"--":
            continue
        header_blob, _, data = part.partition(b"\r\n\r\n")
        headers = header_blob.decode("utf-8", errors="replace")
        disposition = re.search(r'name="([^"]+)"(?:;\s*filename="([^"]*)")?', headers)
        if not disposition:
            continue
        name = disposition.group(1)
        filename = disposition.group(2)
        if data.endswith(b"\r\n"):
            data = data[:-2]
        if filename:
            if data:
                upload_dir = UPLOADS_DIR / (time.strftime("%Y%m%d-%H%M%S-") + uuid.uuid4().hex[:8])
                upload_dir.mkdir(parents=True, exist_ok=True)
                uploaded_file = upload_dir / safe_filename(filename)
                uploaded_file.write_bytes(data)
        else:
            form[name] = data.decode("utf-8", errors="replace")
    return form, uploaded_file


INDEX_HTML = r"""<!doctype html>
<html lang="el">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Transcribe & Translate</title>
  <style>
    :root { color-scheme: light dark; font-family: Arial, sans-serif; }
    body { margin: 0; background: #f5f7f8; color: #172026; }
    main { max-width: 980px; margin: 0 auto; padding: 18px; }
    h1 { font-size: 24px; margin: 8px 0 16px; }
    section { background: #fff; border: 1px solid #d8e0e5; border-radius: 8px; padding: 16px; margin-bottom: 14px; }
    label { display: block; font-weight: 700; margin: 12px 0 6px; }
    input, select, textarea, button { font: inherit; box-sizing: border-box; }
    input, select, textarea { width: 100%; padding: 10px; border: 1px solid #b9c6cf; border-radius: 6px; background: #fff; color: #172026; }
    textarea { min-height: 72px; resize: vertical; }
    .input-with-action { position: relative; }
    .input-with-action input { padding-right: 82px; }
    .input-action-button {
      position: absolute;
      top: 50%;
      right: 5px;
      transform: translateY(-50%);
      padding: 6px 10px;
      background: #e5f2ef;
      color: #126f62;
      border: 1px solid #92b9b2;
      font-size: 14px;
      line-height: 1.2;
    }
    dialog {
      width: min(420px, calc(100% - 32px));
      padding: 18px;
      border: 1px solid #b9c6cf;
      border-radius: 10px;
      background: #fff;
      color: #172026;
    }
    dialog::backdrop { background: rgb(0 0 0 / 45%); }
    dialog h2 { margin: 0 0 8px; font-size: 20px; }
    dialog p { margin: 0 0 12px; }
    .dialog-actions { display: flex; justify-content: flex-end; gap: 8px; margin-top: 14px; }
    .dialog-cancel { background: transparent; color: #126f62; border: 1px solid #92b9b2; }
    .grid { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 12px; }
    .checks { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 8px; margin-top: 10px; }
    .checks label { display: flex; align-items: center; gap: 8px; margin: 0; font-weight: 400; }
    input[type="checkbox"] { width: auto; }
    .download-option { display: flex; align-items: center; gap: 8px; font-weight: 400; }
    button { border: 0; border-radius: 6px; background: #126f62; color: white; padding: 11px 14px; font-weight: 700; cursor: pointer; touch-action: manipulation; }
    button:disabled { opacity: .55; cursor: default; }
    .muted { color: #62727d; font-size: 14px; }
    .field-panel[hidden] { display: none; }
    .jobs-heading { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 8px; }
    .jobs-heading h2 { margin: 0; }
    .secondary-button { background: transparent; color: #126f62; border: 1px solid #92b9b2; padding: 7px 10px; font-size: 14px; }
    .form-actions { display: flex; align-items: center; gap: 8px; margin: 14px 0; }
    .form-actions button { min-height: 44px; }
    .cancel-button { background: #a73535; color: #fff; border: 1px solid #8d2929; }
    .cancel-job-button { margin-left: auto; padding: 7px 11px; min-height: 38px; }
    .jobs { display: grid; gap: 8px; }
    .job { border-top: 1px solid #d8e0e5; padding-top: 10px; min-width: 0; }
    .job-header { display: flex; align-items: center; flex-wrap: wrap; gap: 6px; }
    .job-id { overflow-wrap: anywhere; }
    .status { border-radius: 999px; padding: 2px 7px; font-size: 12px; font-weight: 700; }
    .status-running { background: #dceffb; color: #125476; }
    .status-cancelling { background: #fff0cc; color: #795600; }
    .status-cancelled { background: #eceff1; color: #4f5b62; }
    .status-completed { background: #dff2e9; color: #176045; }
    .status-failed { background: #f9e0e0; color: #8b2929; }
    .job-source { margin: 4px 0; overflow-wrap: anywhere; }
    .job-files { line-height: 1.45; }
    .log-details { margin-top: 6px; }
    .log-details summary { width: fit-content; color: #0c6b85; cursor: pointer; font-size: 14px; user-select: none; }
    pre { margin: 6px 0 0; white-space: pre-wrap; overflow-wrap: anywhere; background: #11181d; color: #d5f6ee; padding: 12px; border-radius: 6px; max-height: 260px; overflow: auto; font-size: 12px; line-height: 1.35; }
    a { color: #0c6b85; }
    @media (max-width: 720px) { .grid, .checks { grid-template-columns: 1fr; } main { padding: 12px; } }
    @media (prefers-color-scheme: dark) {
      body { background: #11181d; color: #edf3f5; }
      section { background: #182228; border-color: #34434c; }
      input, select, textarea { background: #11181d; color: #edf3f5; border-color: #50616b; }
      .muted { color: #a8b7bf; }
      a { color: #85d8ef; }
      .secondary-button { color: #85d8ef; border-color: #50616b; }
      .cancel-button { background: #8e3030; color: #fff; border-color: #bd5b5b; }
      .input-action-button { background: #203b39; color: #9ce0d5; border-color: #506e69; }
      dialog { background: #182228; color: #edf3f5; border-color: #50616b; }
      .dialog-cancel { color: #85d8ef; border-color: #50616b; }
      .status-running { background: #183b50; color: #a8defb; }
      .status-cancelling { background: #4a3b17; color: #ffe09a; }
      .status-cancelled { background: #30383d; color: #c4cdd2; }
      .status-completed { background: #183e31; color: #a9e5ca; }
      .status-failed { background: #4b2525; color: #ffc1c1; }
    }
  </style>
</head>
<body>
<main>
  <h1>Transcribe & Translate</h1>
  <section>
    <form id="jobForm">
      <label>Upload</label>
      <select id="uploadMode" name="upload_mode">
        <option value="youtube">YouTube URL</option>
        <option value="file" selected>Upload file</option>
        <option value="path">Local PC path</option>
      </select>
      <div id="youtubePanel" class="field-panel" hidden>
        <label>YouTube URL</label>
        <div class="input-with-action">
          <input id="youtubeUrl" name="youtube_url" type="url" placeholder="https://www.youtube.com/watch?v=...">
          <button id="pasteYoutubeUrl" class="input-action-button" type="button" aria-label="Paste YouTube URL">Paste</button>
        </div>
        <label class="download-option"><input id="downloadOnly" type="checkbox" name="download_only"> Μόνο λήψη βίντεο (χωρίς μεταγραφή/μετάφραση)</label>
      </div>
      <div id="filePanel" class="field-panel">
        <label>Upload file</label>
        <input name="media_file" type="file" accept="audio/*,video/*,.mkv,.avi,.flac,.webm">
      </div>
      <div id="pathPanel" class="field-panel" hidden>
        <label>Local PC path</label>
        <input name="input_path" placeholder="C:\Videos\episode.mp4">
      </div>
      <div class="grid">
        <div><label>Transcription engine</label><select id="transcriptionEngine" name="transcription_engine"><option value="FasterWhisper">Faster Whisper XXL</option><option value="MOSS">MOSS + speaker diarization</option><option value="ElevenLabs" selected>ElevenLabs Scribe v2 (cloud)</option><option value="VNAIGemini">VNAI Pro Gemini (cloud)</option></select></div>
        <div id="vnaiGeminiModelPanel" hidden><label>VNAI Gemini transcription model</label><select name="vnai_gemini_model"><option>gemini-3.8-flash</option><option>gemini-3.7-flash</option><option>gemini-3.6-flash</option></select><small class="muted">Ο ήχος αποστέλλεται στο VNAI Pro σε τμήματα 60 δευτερολέπτων. Ελέγξτε τους χρονισμούς των υποτίτλων.</small></div>
        <div id="vnaiGeminiKeyPanel" hidden><label>VNAI Gemini API key</label><input name="vnai_transcription_api_key" type="password" autocomplete="off" placeholder="Προαιρετικό — χρησιμοποιείται το αποθηκευμένο VNAI Gemini key"></div>
        <div id="whisperModelPanel" hidden><label>Whisper model</label><select name="whisper_model"><option>medium.en</option><option>small.en</option><option>medium</option><option>large-v3</option><option>large-v3-turbo</option></select></div>
        <div id="mossModelPanel" hidden><label>MOSS model</label><select name="moss_model"><option>OpenMOSS-Team/MOSS-Transcribe-Diarize</option></select></div>
        <div id="mossDevicePanel" hidden><label>MOSS device</label><select name="moss_device"><option value="auto">Auto (CPU on this PC)</option><option value="cpu">CPU</option><option value="cuda">NVIDIA CUDA</option></select></div>
        <div id="mossTokensPanel" hidden><label>MOSS max output tokens</label><input name="moss_max_new_tokens" type="number" min="0" step="1" value="0" title="0 = automatic based on media duration"></div>
        <div id="elevenLabsModelPanel"><label>ElevenLabs model</label><input value="scribe_v2" readonly></div>
        <div id="elevenLabsKeyPanel"><label>ElevenLabs API key</label><input name="elevenlabs_api_key" type="password" autocomplete="off" placeholder="ή βάλε ELEVENLABS_API_KEY στο .env"></div>
        <div id="elevenLabsSpeakersPanel"><label>Expected speakers</label><input name="elevenlabs_num_speakers" type="number" min="0" max="32" step="1" value="0" title="0 = automatic detection"></div>
        <div id="sourceLanguagePanel"><label>Source language</label><input name="source_language" value="English" title="English, Greek ή auto"></div>
        <div id="audioTrackPanel"><label for="audioTrack">Audio track</label><select id="audioTrack" name="audio_track"><option value="0" selected>Auto - prefer English</option></select><small class="muted">Ισχύει για όλες τις μηχανές. Track 1 = πρώτο κανάλι ήχου, Track 2 = δεύτερο κ.λπ. Το Auto προτιμά αγγλικό track, αλλιώς το πρώτο.</small></div>
        <div><label>YouTube quality</label><select name="youtube_quality"><option>Maximum</option><option>1080p</option><option>720p</option><option>480p</option><option>360p</option></select></div>
        <div><label>YouTube cookies</label><select name="youtube_cookies"><option value="">No cookies</option><option value="edge">Edge cookies</option><option value="chrome">Chrome cookies</option><option value="firefox">Firefox cookies</option><option value="brave">Brave cookies</option><option value="vivaldi">Vivaldi cookies</option><option value="opera">Opera cookies</option></select></div>
        <div><label>YouTube cookies file path</label><input name="youtube_cookies_file" placeholder="C:\Users\...\youtube-cookies.txt"></div>
        <div><label>Provider</label><select id="translationProvider" name="translation_provider"><option>Gemini</option><option selected>OpenAI</option><option>VNAI Pro</option><option>VNAI Pro Claude</option><option>VNAI Pro Gemini</option><option>AI Prime Tech</option><option>ElevenLabs Dubbing</option><option value="Local NLLB">Local — NLLB 600M</option></select></div>
        <p id="localTranslationHint" hidden>Τοπική μετάφραση σε CPU με ομαδοποίηση προτάσεων και προστασία αριθμών. Διατηρεί τους χρονισμούς SRT. Προαιρετικό γλωσσάρι δίπλα στο αρχείο: .nllb-glossary.json. Η μεταγραφή με ElevenLabs εξακολουθεί να χρησιμοποιεί cloud.</p><div id="translationModelPanel"><label>Translation model / mode</label><input id="translationModel" name="translation_model" value="gpt-5.4-mini" list="translationModelSuggestions" placeholder="κενό = default"><datalist id="translationModelSuggestions"></datalist></div>
        <div><label>Target language</label><input name="target_language" value="Greek"></div>
        <div><label>SRT processing</label><select name="post_processing"><option value="None" selected>None - keep translated SRT exactly as returned</option><option value="TwoLineText">Two-line text only - max 2 subtitle lines</option><option value="TwoLineTextAndTiming">Two-line text + timing cleanup - recommended</option><option value="SentenceFlow">Sentence flow - experimental orphan-word repair</option></select></div>
      </div>
      <label>Context / ονόματα / φύλο ομιλητών</label>
      <textarea name="subtitle_hints" placeholder="π.χ. Sports interview, player names..."></textarea>
      <div class="checks">
        <label><input type="checkbox" name="auto_gender"> Auto gender inference</label>
        <label><input type="checkbox" name="translation_qa"> Translation QA pass</label>
        <label><input type="checkbox" name="voice_gender"> Voice gender detection</label>
        <label id="speakerLabelsOption" hidden><input type="checkbox" name="show_speaker_labels"> Show S01/S02 in final SRT</label>
        <label><input type="checkbox" name="skip_transcription"> Skip transcription</label>
        <label><input type="checkbox" name="skip_translation"> Skip translation</label>
      </div>
      <div class="form-actions">
        <button id="startBtn" type="submit">Start job</button>
        <button id="cancelStartBtn" class="cancel-button" type="button" hidden>Ακύρωση αποστολής</button>
      </div>
      <div id="message" class="muted"></div>
    </form>
  </section>
  <dialog id="manualPasteDialog">
    <h2>Επικόλληση YouTube URL</h2>
    <p class="muted">Κράτησε πατημένο μέσα στο πεδίο και επίλεξε «Επικόλληση» από το Android.</p>
    <input id="manualPasteUrl" type="url" inputmode="url" autocomplete="off" placeholder="Επικόλλησε το URL εδώ">
    <div class="dialog-actions">
      <button id="cancelManualPaste" class="dialog-cancel" type="button">Άκυρο</button>
      <button id="applyManualPaste" type="button">Χρήση URL</button>
    </div>
  </dialog>
  <section>
    <div class="jobs-heading">
      <h2>Jobs</h2>
      <button id="clearJobsBtn" class="secondary-button" type="button" hidden>Καθαρισμός παλιών</button>
    </div>
    <div id="jobs" class="jobs"></div>
  </section>
</main>
<script>
const form = document.getElementById('jobForm');
const message = document.getElementById('message');
const jobsEl = document.getElementById('jobs');
const clearJobsBtn = document.getElementById('clearJobsBtn');
const startBtn = document.getElementById('startBtn');
const cancelStartBtn = document.getElementById('cancelStartBtn');
const uploadMode = document.getElementById('uploadMode');
const downloadOnly = document.getElementById('downloadOnly');
const youtubeUrl = document.getElementById('youtubeUrl');
const pasteYoutubeUrl = document.getElementById('pasteYoutubeUrl');
const manualPasteDialog = document.getElementById('manualPasteDialog');
const manualPasteUrl = document.getElementById('manualPasteUrl');
const cancelManualPaste = document.getElementById('cancelManualPaste');
const applyManualPaste = document.getElementById('applyManualPaste');
const transcriptionEngine = document.getElementById('transcriptionEngine');
const translationProvider = document.getElementById('translationProvider');
const translationModel = document.getElementById('translationModel');
const translationModelSuggestions = document.getElementById('translationModelSuggestions');
const translationModelPanel = document.getElementById('translationModelPanel');
const whisperModelPanel = document.getElementById('whisperModelPanel');
const vnaiGeminiModelPanel = document.getElementById('vnaiGeminiModelPanel');
const vnaiGeminiKeyPanel = document.getElementById('vnaiGeminiKeyPanel');
const mossPanels = [
  document.getElementById('mossModelPanel'),
  document.getElementById('mossDevicePanel'),
  document.getElementById('mossTokensPanel')
];
const elevenLabsModelPanel = document.getElementById('elevenLabsModelPanel');
const elevenLabsKeyPanel = document.getElementById('elevenLabsKeyPanel');
const elevenLabsSpeakersPanel = document.getElementById('elevenLabsSpeakersPanel');
const sourceLanguagePanel = document.getElementById('sourceLanguagePanel');
const audioTrackPanel = document.getElementById('audioTrackPanel');
for (let track = 1; track <= 32; track++) {
  form.audio_track.add(new Option(`Track ${track}`, String(track)));
}
const speakerLabelsOption = document.getElementById('speakerLabelsOption');
const uploadPanels = {
  youtube: document.getElementById('youtubePanel'),
  file: document.getElementById('filePanel'),
  path: document.getElementById('pathPanel')
};
let activeStartController = null;
const translationModelsByProvider = {
  'OpenAI': ['gpt-5.4-mini', 'gpt-5.4', 'gpt-5.4-nano', 'gpt-4o', 'gpt-4o-mini'],
  'VNAI Pro': ['gpt-5.6-sol', 'gpt-5.6-terra'],
  'VNAI Pro Claude': [
    'claude-sonnet-4-6', 'claude-sonnet-5',
    'claude-fable-5-1', 'claude-fable-5',
    'claude-opus-4-6', 'claude-opus-4-7', 'claude-opus-4-8',
    'claude-opus-5', 'claude-opus-5-5'
  ],
  'VNAI Pro Gemini': ['gemini-3.8-flash', 'gemini-3.7-flash', 'gemini-3.6-flash'],
  'Gemini': ['gemini-3.1-flash-lite', 'gemini-2.5-flash', 'gemini-2.5-pro', 'gemini-2.5-flash-lite']
};
function defaultTranslationModel(provider) {
  if (provider === 'Local NLLB') return 'nllb-600m-int8';
  if (provider === 'ElevenLabs Dubbing') return 'automatic';
  return (translationModelsByProvider[provider] || [''])[0];
}
function updateTranslationModelSuggestions() {
  const models = translationModelsByProvider[translationProvider.value] || [];
  translationModelSuggestions.replaceChildren(...models.map(model => new Option(model, model)));
}
function updateUploadMode() {
  for (const [mode, panel] of Object.entries(uploadPanels)) {
    panel.hidden = uploadMode.value !== mode;
  }
  if (uploadMode.value !== 'youtube') downloadOnly.checked = false;
}
uploadMode.addEventListener('change', updateUploadMode);
const setYoutubeUrl = (value) => {
  const trimmedValue = value.trim();
  if (!trimmedValue) return false;
  youtubeUrl.value = trimmedValue;
  youtubeUrl.dispatchEvent(new Event('input', { bubbles: true }));
  message.textContent = '';
  return true;
};
const openManualPasteDialog = () => {
  manualPasteUrl.value = youtubeUrl.value;
  manualPasteDialog.showModal();
  requestAnimationFrame(() => {
    manualPasteUrl.focus();
    manualPasteUrl.select();
  });
};
cancelManualPaste.addEventListener('click', () => manualPasteDialog.close());
applyManualPaste.addEventListener('click', () => {
  if (!setYoutubeUrl(manualPasteUrl.value)) {
    manualPasteUrl.focus();
    return;
  }
  manualPasteDialog.close();
  youtubeUrl.focus();
});
manualPasteUrl.addEventListener('keydown', (event) => {
  if (event.key === 'Enter') applyManualPaste.click();
});
pasteYoutubeUrl.addEventListener('click', async () => {
  youtubeUrl.focus();
  try {
    if (!window.isSecureContext || !navigator.clipboard || !navigator.clipboard.readText) {
      throw new Error('Clipboard API unavailable');
    }
    const clipboardText = await navigator.clipboard.readText();
    if (!setYoutubeUrl(clipboardText)) {
      message.textContent = 'Το clipboard είναι κενό.';
    }
    return;
  } catch (error) {
    // Some Android browsers still expose the older paste command on HTTP pages.
    const previousValue = youtubeUrl.value;
    youtubeUrl.select();
    try {
      if (document.execCommand('paste') && youtubeUrl.value !== previousValue) {
        youtubeUrl.dispatchEvent(new Event('input', { bubbles: true }));
        message.textContent = '';
        return;
      }
    } catch (pasteError) {
      // Continue to the visible manual fallback below.
    }

    openManualPasteDialog();
  }
});
function updateTranscriptionEngine() {
  const isMoss = transcriptionEngine.value === 'MOSS';
  const isElevenLabs = transcriptionEngine.value === 'ElevenLabs';
  const isVnaiGemini = transcriptionEngine.value === 'VNAIGemini';
  const isElevenLabsDubbing = translationProvider.value === 'ElevenLabs Dubbing';
  whisperModelPanel.hidden = isMoss || isElevenLabs || isVnaiGemini;
  vnaiGeminiModelPanel.hidden = !isVnaiGemini;
  vnaiGeminiKeyPanel.hidden = !isVnaiGemini;
  for (const panel of mossPanels) panel.hidden = !isMoss;
  elevenLabsModelPanel.hidden = !isElevenLabs;
  elevenLabsKeyPanel.hidden = !(isElevenLabs || isElevenLabsDubbing);
  elevenLabsSpeakersPanel.hidden = !(isElevenLabs || isElevenLabsDubbing);
  sourceLanguagePanel.hidden = !(isElevenLabs || isVnaiGemini || isElevenLabsDubbing || translationProvider.value === 'Local NLLB');
  audioTrackPanel.hidden = false;
  speakerLabelsOption.hidden = !(isMoss || isElevenLabs);
  if (!(isMoss || isElevenLabs)) form.show_speaker_labels.checked = false;
}
function updateTranslationProvider() {
  const isDubbing = translationProvider.value === 'ElevenLabs Dubbing';
  const isLocal = translationProvider.value === 'Local NLLB';
  translationModel.disabled = isDubbing || isLocal;
  if (isLocal) translationModel.value = 'nllb-600m-int8';
  else if (isDubbing) translationModel.value = 'automatic';
  else if (['automatic', 'nllb-600m-int8'].includes(translationModel.value)) {
    translationModel.value = defaultTranslationModel(translationProvider.value);
  }
  for (const name of ['translation_qa', 'auto_gender', 'voice_gender']) {
    form.elements[name].disabled = isDubbing || isLocal;
    if (isDubbing || isLocal) form.elements[name].checked = false;
  }
  form.elements.subtitle_hints.disabled = isLocal;
  form.elements.post_processing.disabled = isLocal;
  if (isLocal) form.elements.post_processing.value = 'None';
  document.getElementById('localTranslationHint').hidden = !isLocal;
  updateTranslationModelSuggestions();
  updateTranscriptionEngine();
}

transcriptionEngine.addEventListener('change', updateTranscriptionEngine);
translationProvider.addEventListener('change', () => {
  translationModel.value = defaultTranslationModel(translationProvider.value);
  updateTranslationProvider();
});
cancelStartBtn.addEventListener('click', () => {
  if (!activeStartController) return;
  cancelStartBtn.disabled = true;
  message.textContent = 'Ακύρωση αποστολής...';
  activeStartController.abort();
});
form.addEventListener('submit', async (event) => {
  event.preventDefault();
  if (
    translationProvider.value === 'ElevenLabs Dubbing' &&
    !window.confirm('Θα ανέβει το αρχικό media και θα δημιουργηθεί χρεώσιμο ElevenLabs Dubbing job. Συνέχεια;')
  ) return;
  if (uploadMode.value !== 'youtube') form.youtube_url.value = '';
  if (uploadMode.value !== 'file') form.media_file.value = '';
  if (uploadMode.value !== 'path') form.input_path.value = '';
  const isFileUpload = uploadMode.value === 'file';
  const formData = new FormData(form);
  const requestBody = isFileUpload
    ? formData
    : new URLSearchParams([...formData.entries()].filter(([name]) => name !== 'media_file'));
  const controller = new AbortController();
  activeStartController = controller;
  const timeoutId = isFileUpload ? null : setTimeout(() => controller.abort(), 45000);
  startBtn.disabled = true;
  cancelStartBtn.disabled = false;
  cancelStartBtn.hidden = false;
  message.textContent = isFileUpload ? 'Ανέβασμα αρχείου...' : 'Εκκίνηση...';
  try {
    const response = await fetch('/api/jobs', {
      method: 'POST',
      body: requestBody,
      signal: controller.signal
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || 'Request failed');
    message.textContent = 'Job started: ' + data.id;
    form.reset();
    form.auto_gender.checked = true;
    updateUploadMode();
    updateTranscriptionEngine();
    updateTranslationProvider();
    await loadJobs();
  } catch (error) {
    message.textContent = error.name === 'AbortError'
      ? 'Η αποστολή ακυρώθηκε. Αν το job είχε ήδη ξεκινήσει, μπορείς να το ακυρώσεις από τη λίστα Jobs.'
      : error.message;
  } finally {
    if (timeoutId !== null) clearTimeout(timeoutId);
    activeStartController = null;
    startBtn.disabled = false;
    cancelStartBtn.hidden = true;
    cancelStartBtn.disabled = false;
    await loadJobs();
  }
});
async function loadJobs() {
  const response = await fetch('/api/jobs');
  const data = await response.json();
  const openLogs = new Set([...jobsEl.querySelectorAll('details[data-job-id][open]')].map(details => details.dataset.jobId));
  const logPositions = new Map([...jobsEl.querySelectorAll('pre[data-job-id]')].map(pre => {
    const nearBottom = pre.scrollHeight - pre.scrollTop - pre.clientHeight < 24;
    return [pre.dataset.jobId, { scrollTop: pre.scrollTop, nearBottom }];
  }));
  clearJobsBtn.hidden = !data.jobs.some(job => !['running', 'cancelling'].includes(job.status));
  jobsEl.innerHTML = data.jobs.map(job => {
    const isRunning = job.status === 'running';
    const isCancelling = job.status === 'cancelling';
    const statusLabels = {
      running: 'σε εξέλιξη',
      cancelling: 'ακυρώνεται',
      cancelled: 'ακυρώθηκε',
      completed: 'ολοκληρώθηκε',
      failed: 'απέτυχε'
    };
    const statusLabel = statusLabels[job.status] || job.status;
    const log = escapeHtml((job.log || []).slice(-240).join('\n'));
    const logView = (isRunning || isCancelling)
      ? `<pre data-job-id="${escapeHtml(job.id)}">${log}</pre>`
      : `<details class="log-details" data-job-id="${escapeHtml(job.id)}"${openLogs.has(job.id) ? ' open' : ''}>
          <summary>Προβολή log</summary>
          <pre data-job-id="${escapeHtml(job.id)}">${log}</pre>
        </details>`;
    return `
    <div class="job">
      <div class="job-header">
        <strong class="job-id">${escapeHtml(job.id)}</strong>
        <span class="status status-${escapeHtml(job.status)}">${statusLabel}${job.return_code !== null ? ' · exit ' + job.return_code : ''}</span>
        ${(isRunning || isCancelling) ? `<button class="cancel-button cancel-job-button" type="button" data-cancel-job="${escapeHtml(job.id)}"${isCancelling ? ' disabled' : ''}>${isCancelling ? 'Ακυρώνεται…' : 'Ακύρωση'}</button>` : ''}
      </div>
      <div class="muted job-source">${escapeHtml(job.source || '')}</div>
      <div class="job-files">${(job.files || []).map(file => `<a href="${file.download}">${escapeHtml(file.name)}</a>`).join('<br>')}</div>
      ${logView}
    </div>
  `}).join('') || '<div class="muted">Δεν υπάρχουν jobs ακόμα.</div>';
  for (const pre of jobsEl.querySelectorAll('pre[data-job-id]')) {
    const previous = logPositions.get(pre.dataset.jobId);
    if (!previous || previous.nearBottom) {
      pre.scrollTop = pre.scrollHeight;
    } else {
      pre.scrollTop = previous.scrollTop;
    }
  }
}
jobsEl.addEventListener('click', async (event) => {
  const button = event.target.closest('button[data-cancel-job]');
  if (!button || button.disabled) return;
  const jobId = button.dataset.cancelJob;
  if (!window.confirm('Να ακυρωθεί αυτό το job; Η τοπική επεξεργασία θα σταματήσει. API κλήση που έχει ήδη σταλεί μπορεί να έχει ήδη χρεωθεί.')) return;

  button.disabled = true;
  button.textContent = 'Ακυρώνεται…';
  try {
    const response = await fetch(`/api/jobs/${encodeURIComponent(jobId)}/cancel`, { method: 'POST' });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || 'Η ακύρωση απέτυχε.');
    message.textContent = `Ζητήθηκε ακύρωση του job ${jobId}.`;
  } catch (error) {
    message.textContent = error.message;
  } finally {
    await loadJobs();
  }
});
clearJobsBtn.addEventListener('click', async () => {
  clearJobsBtn.disabled = true;
  try {
    const response = await fetch('/api/jobs/completed', { method: 'DELETE' });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error || 'Request failed');
    message.textContent = `Καθαρίστηκαν ${data.removed} παλιά job${data.removed === 1 ? '' : 's'}. Τα αρχεία τους παραμένουν αποθηκευμένα.`;
    await loadJobs();
  } catch (error) {
    message.textContent = error.message;
  } finally {
    clearJobsBtn.disabled = false;
  }
});
function escapeHtml(value) {
  return String(value).replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
}
loadJobs();
updateUploadMode();
updateTranscriptionEngine();
updateTranslationProvider();
setInterval(loadJobs, 3000);
</script>
</body>
</html>
"""


class Handler(BaseHTTPRequestHandler):
    server_version = "FasterWhisperWeb/1.0"

    def require_authorization(self) -> bool:
        if not WEB_AUTH_PASSWORD:
            return True

        header = self.headers.get("Authorization", "")
        try:
            scheme, encoded = header.split(" ", 1)
            decoded = base64.b64decode(encoded, validate=True)
        except ValueError:
            scheme = ""
            decoded = b""

        expected = f"{WEB_AUTH_USERNAME}:{WEB_AUTH_PASSWORD}".encode("utf-8")
        if scheme.lower() == "basic" and secrets.compare_digest(decoded, expected):
            return True

        body = "Απαιτείται κωδικός πρόσβασης.".encode("utf-8")
        self.send_response(401)
        self.send_header("WWW-Authenticate", 'Basic realm="Private subtitle app", charset="UTF-8"')
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        return False

    def send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if not self.require_authorization():
            return
        parsed = urlparse(self.path)
        if parsed.path == "/":
            body = INDEX_HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        if parsed.path == "/api/jobs":
            with jobs_lock:
                payload = []
                for job in sorted(jobs.values(), key=lambda item: item["started_at"], reverse=True):
                    copy = dict(job)
                    copy["files"] = output_files(copy)
                    payload.append(copy)
            self.send_json(200, {"jobs": payload})
            return

        if parsed.path == "/api/download":
            query = parse_qs(parsed.query)
            target = Path(query.get("path", [""])[0]).resolve()
            jobs_root = JOBS_DIR.resolve()
            if not target.is_relative_to(jobs_root) or not target.is_file():
                self.send_error(404)
                return
            mime = mimetypes.guess_type(target.name)[0] or "application/octet-stream"
            size = target.stat().st_size
            ascii_name = target.name.encode("ascii", errors="ignore").decode("ascii") or "download"
            ascii_name = ascii_name.replace('"', "")
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header(
                "Content-Disposition",
                f'attachment; filename="{ascii_name}"; filename*=UTF-8\'\'{quote(target.name)}',
            )
            self.send_header("Content-Length", str(size))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            with target.open("rb") as source:
                while chunk := source.read(1024 * 1024):
                    self.wfile.write(chunk)
            return

        self.send_error(404)

    def do_POST(self) -> None:
        if not self.require_authorization():
            return
        parsed = urlparse(self.path)
        cancel_match = re.fullmatch(r"/api/jobs/([^/]+)/cancel", parsed.path)
        if cancel_match:
            job_id = cancel_match.group(1)
            try:
                job = cancel_job(job_id)
                self.send_json(202, {"id": job_id, "status": job["status"]})
            except KeyError:
                self.send_json(404, {"error": "Το job δεν βρέθηκε."})
            except ValueError as exc:
                self.send_json(409, {"error": str(exc)})
            except Exception as exc:
                self.send_json(500, {"error": f"Η ακύρωση απέτυχε: {exc}"})
            return

        if parsed.path != "/api/jobs":
            self.send_error(404)
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
            body = self.rfile.read(length)
            if len(body) != length:
                raise ValueError("Η αποστολή του αρχείου ακυρώθηκε ή διακόπηκε.")
            content_type = self.headers.get("Content-Type", "")
            if content_type.startswith("multipart/form-data"):
                form, uploaded_file = parse_multipart(content_type, body)
            else:
                form = {k: v[-1] for k, v in parse_qs(body.decode("utf-8", errors="replace")).items()}
                uploaded_file = None
            job = start_job(form, uploaded_file)
            self.send_json(201, job)
        except Exception as exc:
            self.send_json(400, {"error": str(exc)})

    def do_DELETE(self) -> None:
        if not self.require_authorization():
            return
        parsed = urlparse(self.path)
        if parsed.path != "/api/jobs/completed":
            self.send_error(404)
            return

        with jobs_lock:
            finished_ids = [
                job_id
                for job_id, job in jobs.items()
                if job["status"] not in {"running", "cancelling"}
            ]
            for job_id in finished_ids:
                job_dir = JOBS_DIR / job_id
                if job_dir.is_dir():
                    (job_dir / ".web-hidden").write_text("hidden\n", encoding="utf-8")
                del jobs[job_id]
        self.send_json(200, {"removed": len(finished_ids)})

    def log_message(self, format: str, *args) -> None:
        print("[%s] %s" % (self.log_date_time_string(), format % args))


def main() -> None:
    JOBS_DIR.mkdir(exist_ok=True)
    UPLOADS_DIR.mkdir(parents=True, exist_ok=True)
    recover_finished_jobs()
    server = ThreadingHTTPServer(("0.0.0.0", DEFAULT_PORT), Handler)
    ip = local_ip()
    print(f"Local:   http://127.0.0.1:{DEFAULT_PORT}")
    print(f"Tablet:  http://{ip}:{DEFAULT_PORT}")
    print("Press Ctrl+C to stop.")
    server.serve_forever()


if __name__ == "__main__":
    main()
