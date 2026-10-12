"""Offline checks for chunk offsets, proxy responses, errors, and job wiring."""
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch, MagicMock
import urllib.error
import wave

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from tools import vnai_gemini_transcribe as adapter
import web_server


def response(segments, finish='STOP', fenced=False):
    text = json.dumps({'segments': segments})
    if fenced:
        text = '```json\n' + text + '\n```'
    return {'candidates': [{'finishReason': finish, 'content': {'parts': [
        {'thought': True, 'text': 'not output'}, {'text': text},
    ]}}]}


class TranscriptionTests(unittest.TestCase):
    def test_proxy_fences_and_unicode(self):
        data = response([{'start': .2, 'end': 1.4, 'text': 'Γεια σου.'}], fenced=True)
        self.assertEqual(adapter.parse_segments(data, 2, 60),
                         [{'start': 60.2, 'end': 61.4, 'text': 'Γεια σου.'}])

    def test_bad_timings_fail_instead_of_saving_corrupt_subtitles(self):
        for start, end in [(-1, 2), (3, 2), (0, 99), (0, float('nan')), ('0', 1), (False, 1)]:
            with self.subTest(start=start, end=end), self.assertRaises(ValueError):
                adapter.parse_segments(response([{'start': start, 'end': end, 'text': 'Hello'}]), 5, 0)
        with self.assertRaises(ValueError):
            adapter.parse_segments(response([{'start': 1, 'end': 3, 'text': 'A'},
                                              {'start': 0, 'end': 1, 'text': 'B'}]), 5, 0)

    def test_truncated_and_blocked_output_rejected(self):
        for value in ({}, response([], 'MAX_TOKENS'), response([], 'SAFETY')):
            with self.assertRaises(ValueError):
                adapter.parse_segments(value, 5, 0)
        self.assertEqual(adapter.parse_segments(response([]), 5, 0), [])

    def test_chunk_offsets_and_atomic_failure(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'input.wav'
            with wave.open(str(path), 'wb') as audio:
                audio.setparams((1, 2, 16000, 0, 'NONE', 'not compressed'))
                audio.writeframes(b'\0\0' * 16000 * 3)
            chunks = list(adapter.audio_chunks(path, 2))
            self.assertEqual([(a, b) for a, b, _ in chunks], [(0, 2), (2, 1)])
            for _, duration, data in chunks:
                with wave.open(io.BytesIO(data)) as audio:
                    self.assertEqual(audio.getnframes() / audio.getframerate(), duration)
            answer = response([{'start': 0, 'end': .8, 'text': 'Hello.'}])
            with patch.object(adapter, 'generate', return_value=answer):
                target = adapter.transcribe(path, Path(folder), adapter.MODELS[0], 'dummy', chunk_seconds=2)
            original = target.read_bytes()
            self.assertIn('00:00:02,000 --> 00:00:02,800', target.read_text(encoding='utf-8-sig'))
            with patch.object(adapter, 'generate', side_effect=[answer, RuntimeError('failure')]):
                with self.assertRaises(RuntimeError):
                    adapter.transcribe(path, Path(folder), adapter.MODELS[0], 'dummy', chunk_seconds=2)
            self.assertEqual(target.read_bytes(), original)
            self.assertFalse(list(Path(folder).glob('*.partial')))
            with patch.object(adapter, 'generate', return_value=response([])):
                with self.assertRaisesRegex(ValueError, 'No speech'):
                    adapter.transcribe(path, Path(folder), adapter.MODELS[0], 'dummy')
            self.assertEqual(target.read_bytes(), original)

    def test_http_retry_and_secret_redaction(self):
        error = lambda code: urllib.error.HTTPError('https://example.invalid', code, 'failure', {}, io.BytesIO(b'secret-key'))
        with patch.object(adapter.urllib.request, 'urlopen', side_effect=error(401)) as call:
            with self.assertRaisesRegex(RuntimeError, 'HTTP 401') as result:
                adapter.generate(adapter.MODELS[0], 'secret-key', {})
            self.assertNotIn('secret-key', str(result.exception))
            self.assertEqual(call.call_count, 1)
        with patch.object(adapter.urllib.request, 'urlopen', side_effect=[error(429), error(503), error(503)]) as call, patch.object(adapter.time, 'sleep'):
            with self.assertRaisesRegex(RuntimeError, 'HTTP 503'):
                adapter.generate(adapter.MODELS[0], 'secret-key', {})
            self.assertEqual(call.call_count, 3)

    def test_web_runner_model_and_key_isolation(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(web_server, 'JOBS_DIR', Path(folder)), \
                patch.object(web_server.subprocess, 'Popen') as popen, \
                patch.object(web_server.threading, 'Thread') as thread, \
                patch.object(web_server, 'load_dotenv', return_value={}):
            popen.return_value.pid = 123
            try:
                for model in adapter.MODELS:
                    job = web_server.start_job({'input_path': 'sample.wav', 'transcription_engine': 'VNAIGemini',
                                               'vnai_gemini_model': model, 'skip_translation': 'on',
                                               'vnai_transcription_api_key': 'test-secret'}, None)
                    runner = (Path(folder) / job['id'] / 'run.ps1').read_text()
                    self.assertIn('-VnaiGeminiModel', runner)
                    self.assertIn(model, runner)
                    self.assertNotIn('test-secret', runner)
                    self.assertEqual(popen.call_args.kwargs['env']['VNAIPRO_TRANSCRIPTION_API_KEY'], 'test-secret')
                with self.assertRaises(ValueError):
                    web_server.start_job({'input_path': 'sample.wav', 'transcription_engine': 'VNAIGemini',
                                          'vnai_gemini_model': 'gemini-3.5-transcribe'}, None)
            finally:
                web_server.jobs.clear()


if __name__ == '__main__':
    unittest.main()
