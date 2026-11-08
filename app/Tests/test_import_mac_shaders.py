"""Shader resource import checks, without game assets or a GPU."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


class ShaderImportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'Scripts').mkdir()
        (self.root / 'Resources').mkdir()
        self.script = self.root / 'Scripts/import_mac_shaders.py'
        shutil.copyfile(Path(__file__).resolve().parents[1] / 'Scripts/import_mac_shaders.py', self.script)
        self.source = self.root / 'source'
        self.source.mkdir()
        (self.source / 'shaders-maccatalyst.metallib').write_bytes(b'MTLBtest-fixture')
        (self.source / 'shader-reflection.jsonl').write_text(json.dumps({'h': 'shader1', 'st': 'vs'}) + '\n')
        self.index = self.root / 'index.json'
        self.index.write_text(json.dumps({'shader1': {'ok': True, 'stage': 'vs'}}))

    def run_import(self, index):
        return subprocess.run([sys.executable, str(self.script), '--source', str(self.source),
                               '--index', str(index)], capture_output=True, text=True)

    def test_initial_import_and_cached_index_rebuild(self):
        first = self.run_import(self.index)
        self.assertEqual(first.returncode, 0, first.stderr)
        cached = self.root / 'Resources/shader-index.json'
        self.assertEqual(cached.read_bytes(), self.index.read_bytes())
        second = self.run_import(cached)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual((self.root / 'GeneratedResources/shaders-maccatalyst.metallib').read_bytes(),
                         (self.source / 'shaders-maccatalyst.metallib').read_bytes())

    def test_incompatible_stage_does_not_copy_resources(self):
        self.index.write_text(json.dumps({'shader1': {'ok': True, 'stage': 'ps'}}))
        result = self.run_import(self.index)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('1 missing or different stages', result.stderr)
        self.assertFalse((self.root / 'GeneratedResources').exists())

    def test_invalid_library_header_does_not_copy_resources(self):
        (self.source / 'shaders-maccatalyst.metallib').write_bytes(b'bad-library')
        result = self.run_import(self.index)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('invalid Mac Metal library', result.stderr)
        self.assertFalse((self.root / 'GeneratedResources').exists())


if __name__ == '__main__':
    unittest.main()
