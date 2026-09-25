import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('build_uninstaller', ROOT / 'tools/build_uninstaller.py')
tool = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tool)


class UninstallerToolsTests(unittest.TestCase):
    def test_bundle_is_current_and_propagates_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'src').mkdir()
            shutil.copyfile(ROOT / 'src/uninstaller.lua', root / 'src/uninstaller.lua')
            self.assertEqual(tool.build(root), (ROOT / tool.RELATIVE).read_bytes())
            result = subprocess.run(['lua', '-'], input='rt={}\n' + tool.build(root).decode(),
                                    text=True, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('rt.sleep is required', result.stderr)

    def test_pinned_bootstrap_rejects_failed_download_before_execution(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / tool.RELATIVE
            path.parent.mkdir(parents=True)
            body = tool.HEADER + '-- test fixture\n' * 100 + 'assert(... == "uninstall"); print("EXECUTED")\n'
            path.write_text(body)
            def git(*args):
                return subprocess.run(['git', *args], cwd=root, check=True, capture_output=True).stdout.decode().strip()
            git('init', '-q'); git('add', '.')
            git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'fixture')
            command = tool.command(git('rev-parse', 'HEAD'), root)
            self.assertLess(len(command), 4095)
            self.assertIn('local DNSINSTALL_BOOT="uninstall"', command)
            for response, good in [('{rtn1=true,code=200,body=body}', True),
                                   ('{rtn1=false,code=200,body=body}', False),
                                   ('{rtn1=true,code=404,body=body}', False),
                                   ('{rtn1=true,code=200,body="short"}', False),
                                   ('{rtn1=true,code=200,body={}}', False)]:
                script = ('loadstring=loadstring or load\nlocal body=[====[' + body + ']====]\n'
                          + 'rt={httprequest=function(r) assert(r.method=="GET" and r.timeout==30); return '
                          + response + ' end}\n' + command[len("lua -e '"):-1])
                p = subprocess.run(['lua', '-'], input=script, text=True, capture_output=True)
                self.assertEqual(p.returncode == 0, good, p.stderr)
                self.assertEqual('EXECUTED' in p.stdout, good)
            for bad in ['main', 'a' * 39, 'A' * 40]:
                with self.assertRaises(ValueError):
                    tool.command(bad, root)


if __name__ == '__main__':
    unittest.main()
