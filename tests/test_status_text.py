import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('build_status_text', ROOT / 'tools/build_status_text.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)


class StatusTextTests(unittest.TestCase):
    def test_committed_table_is_reproducible_ascii(self):
        raw = builder.render()
        self.assertEqual(raw, (ROOT / 'src/status_text.lua').read_bytes())
        raw.decode('ascii')

    def test_observed_cp932_and_utf8_are_both_present(self):
        raw = builder.render().decode('ascii')
        for encoding in ('cp932', 'utf-8'):
            for phrase in ('PPPoEセッションは継っていません', 'サーバ検索中', 'PPTPセッションは接続されています'):
                self.assertIn(builder.quoted(phrase.encode(encoding)), raw)

    def test_lua_string_escaping_is_unambiguous(self):
        self.assertEqual(builder.quoted(b'\x01' + b'23"\\'), '"\\00123\\034\\092"')
