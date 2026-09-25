import importlib.util
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('installer_command', ROOT/'tools/installer_command.py')
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class BootstrapTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.root = Path(cls.directory.name)
        def git(*args):
            return subprocess.run(['git', *args], cwd=cls.root, check=True,
                                  capture_output=True).stdout.decode().strip()
        git('init', '-q')
        git('config', 'user.name', 'Installer Test')
        git('config', 'user.email', 'installer-test@example.invalid')
        out = cls.root / 'installer/versions/v0.1.4'
        out.mkdir(parents=True)
        payload = b'-- fixture\n' * 120
        (out / 'rtx-dns.lua').write_bytes(payload)
        git('add', '.')
        git('commit', '-qm', 'test payload')
        payload_ref = git('rev-parse', 'HEAD')
        cls.body = ('-- Installer release: v0.1.4\n' + '-- installer fixture\n' * 60 +
                    'local release = {version="v0.1.4",sha256="' + hashlib.sha256(payload).hexdigest() +
                    '",bytes=' + str(len(payload)) + ',url="https://raw.githubusercontent.com/Yamar50/rtx-dns-tcp-lua/' +
                    payload_ref + '/installer/versions/v0.1.4/rtx-dns.lua"}\nreturn true\n')
        (out / 'rtx-dns-install.lua').write_text(cls.body)
        git('add', '.')
        git('commit', '-qm', 'test installer')
        cls.ref = git('rev-parse', 'HEAD')

    @classmethod
    def tearDownClass(cls):
        cls.directory.cleanup()

    def run_case(self, scenario, succeeds):
        lua = shutil.which('lua')
        if not lua:
            self.skipTest('Lua interpreter unavailable')
        command = generator.command('v0.1.4', self.ref, 'no', self.root)
        source = command[len("lua -e '"):-1]
        harness = r'''
loadstring = loadstring or load
local case = CASE
local body = BODY
local reads,writes,starts,requests = 0,0,0,0
local saved = "previous installer"
local boot = 'Command line: lua -e "local DNSINSTALL_BOOT=..."'
rt = {
 command = function(cmd)
  if cmd == "show status lua running" then
   reads=reads+1
   if case=="direct" then return true, "Script file: /lua/rtx-dns-install.lua" end
   if case=="duplicate" or (case=="late" and reads==2) then return true,boot.."\n"..boot end
   return true,boot
  end
  assert(cmd=="make directory /lua");return false,"already exists"
 end,
 httprequest = function(req)
  requests=requests+1
  assert(req.url:match("^https://raw%.githubusercontent%.com/"))
  if case=="http" then return {rtn1=true,code=404,body=body} end
  if case=="short" then return {rtn1=true,code=200,body="short"} end
  if case=="syntax" then return {rtn1=true,code=200,body=body:sub(1,-2).."!"} end
  if case=="wrong-version" then return {rtn1=true,code=200,body=body:gsub("v0%.1%.4","v0.9.9")} end
  return {rtn1=true,code=200,body=body}
 end
}
io = {open=function(path,mode)
 assert(path=="/lua/rtx-dns-install.lua")
 return {write=function(_,data)writes=writes+1;saved=data;return true end,
 read=function()return saved end,close=function()return true end}
end}
dofile=function(path)
 assert(path=="/lua/rtx-dns-install.lua" and arg[1]=="no" and saved==body)
 starts=starts+1
end
local f=assert(loadstring(SOURCE))
local ok=pcall(f)
assert(ok==SUCCEEDS)
if ok then assert(writes==1 and starts==1 and reads==2 and requests==1)
else assert(writes==0 and starts==0 and saved=="previous installer") end
'''
        def literal(s):
            return '[====[' + s + ']====]'
        harness = harness.replace('CASE', literal(scenario)).replace('SOURCE', literal(source)).replace('BODY', literal(self.body)).replace('SUCCEEDS', 'true' if succeeds else 'false')
        result = subprocess.run([lua, '-'], input=harness, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_bootstrap_guards_and_success(self):
        for scenario in ['direct', 'duplicate', 'late', 'http', 'short', 'syntax', 'wrong-version', 'success']:
            with self.subTest(scenario=scenario):
                self.run_case(scenario, scenario == 'success')

    def test_only_explicit_mode_and_immutable_ref(self):
        for ref, mode in [('main', 'yes'), ('a'*40, 'maybe'), ('a'*39, 'yes')]:
            with self.assertRaises(ValueError):
                generator.command('v0.1.4', ref, mode)


if __name__ == '__main__':
    unittest.main()
