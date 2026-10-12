r"""Run with .venv-nllb\Scripts\python.exe -m unittest discover -s tools -p test_nllb.py."""
import argparse
import json
from pathlib import Path
import socket
import tempfile
import unittest
from unittest.mock import patch

from translate_nllb import read_srt, translate
from nllb_segments import slots_for_cues, groups_for_slots, sentence_parts, distribute, protect, restore


class SegmentationTests(unittest.TestCase):
    def test_visual_wrap_and_continuation_join_but_next_speaker_does_not(self):
        cues = [('1', '00:00:01,000 --> 00:00:02,000', 'Wait while\nthe coffee is'),
                ('2', '00:00:02,100 --> 00:00:03,000', 'brewing. Thanks.'),
                ('3', '00:00:03,100 --> 00:00:04,000', '- You are welcome.')]
        groups = groups_for_slots(slots_for_cues(cues), cues)
        self.assertEqual([len(g) for g in groups], [2, 1])
        self.assertEqual(sentence_parts(' '.join(s.text for s in groups[0])),
                         ['Wait while the coffee is brewing.', 'Thanks.'])
        self.assertTrue(distribute('Περίμενε μέχρι να ετοιμαστεί ο καφές. Ευχαριστώ.', groups[0]))
        self.assertEqual(' '.join(s.output for s in groups[0]), 'Περίμενε μέχρι να ετοιμαστεί ο καφές. Ευχαριστώ.')

    def test_large_gap_and_format_change_prevent_joining(self):
        cues = [('1', '00:00:01,000 --> 00:00:02,000', 'Come'),
                ('2', '00:00:05,000 --> 00:00:06,000', 'back'),
                ('3', '00:00:06,100 --> 00:00:07,000', '<i>now.</i>')]
        self.assertEqual([len(g) for g in groups_for_slots(slots_for_cues(cues), cues)], [1, 1, 1])

    def test_protection_fails_on_missing_duplicated_or_reordered_items(self):
        protected, values = protect('Summer is 12, Summer.', {'Summer': 'Σάμερ'})
        self.assertEqual(restore(protected, values), 'Σάμερ is 12, Σάμερ.')
        with self.assertRaises(ValueError):
            restore(protected.replace(values[0][0], ''), values)
        with self.assertRaises(ValueError):
            restore(protected + ' ' + values[0][0], values)
        with self.assertRaises(ValueError):
            restore(' '.join(token for token, _ in reversed(values)), values)

    def test_abbreviations_and_no_empty_redistribution(self):
        self.assertEqual(sentence_parts('Mr. Smith is here. He is 12.5 years old.'),
                         ['Mr. Smith is here.', 'He is 12.5 years old.'])
        cues = [('1', '00:00:01,000 --> 00:00:02,000', 'Come'), ('2', '00:00:02,000 --> 00:00:03,000', 'here')]
        self.assertFalse(distribute('Έλα', slots_for_cues(cues)))

    def test_nested_markup_and_spaces_survive_reconstruction(self):
        source = '<i>Hello <b>Summer</b></i>'
        slots = slots_for_cues([('1', '00:00:01,000 --> 00:00:02,000', source)])
        for slot in slots:
            slot.output = slot.text.strip()
        self.assertEqual(''.join(s.prefix + s.output + s.suffix for s in slots), source)


class OfflineTranslationTests(unittest.TestCase):
    def test_names_numbers_and_short_questions_with_real_model(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, output = root / 'sample.srt', root / 'greek.srt'
            source.write_text('1\n00:00:01,000 --> 00:00:02,000\n12.\n\n2\n00:00:03,000 --> 00:00:04,000\nWhat?\n\n3\n00:00:05,000 --> 00:00:06,000\nSummer?\n', encoding='utf-8')
            source.with_suffix('.nllb-glossary.json').write_text(json.dumps({
                'source_language': 'eng_Latn', 'target_language': 'ell_Grek', 'terms': {'Summer': 'Σάμερ'}}), encoding='utf-8')
            args = argparse.Namespace(input=source, output=output, source_language='English', target_language='Greek', show_speaker_labels=False)
            with patch.object(socket.socket, 'connect', side_effect=AssertionError('Offline inference attempted network access')):
                translate(args)
            cues, _ = read_srt(output)
            self.assertEqual([c[2] for c in cues], ['12.', 'Τι;', 'Σάμερ;'])

    def test_offline_translation_preserves_structure_and_source(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, output = root / "source.srt", root / "greek.srt"
            raw = ("7\r\n00:00:01,000 --> 00:00:03,000\r\n<i>We need to leave now.</i>\r\n\r\n"
                   "9\r\n00:00:04,000 --> 00:00:06,000\r\n- I will call you tomorrow.\r\n- Thank you.\r\n").encode("utf-8-sig")
            source.write_bytes(raw)
            args = argparse.Namespace(input=source, output=output, source_language="English",
                                      target_language="Greek", show_speaker_labels=False)
            with patch.object(socket.socket, "connect", side_effect=AssertionError("Network access during offline inference")):
                translate(args)
            before, _ = read_srt(source)
            after, newline = read_srt(output)
            self.assertEqual(source.read_bytes(), raw)
            self.assertEqual([(n, t) for n, t, _ in before], [(n, t) for n, t, _ in after])
            self.assertEqual(newline, "\r\n")
            self.assertTrue(after[0][2].startswith("<i>"))
            self.assertTrue(after[0][2].endswith("</i>"))
            self.assertTrue(all(line.startswith("- ") for line in after[1][2].splitlines()))
            self.assertTrue(all(any("\u0370" <= c <= "\u03ff" for c in text) for _, _, text in after))

    def test_invalid_input_does_not_overwrite_existing_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, output = root / "bad.srt", root / "existing.srt"
            source.write_text("bad subtitle", encoding="utf-8")
            output.write_bytes(b"existing translation")
            args = argparse.Namespace(input=source, output=output, source_language="English",
                                      target_language="Greek", show_speaker_labels=False)
            with self.assertRaises(ValueError):
                translate(args)
            self.assertEqual(output.read_bytes(), b"existing translation")

if __name__ == "__main__":
    unittest.main()
