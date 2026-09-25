import importlib.util
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('installer_command', ROOT/'tools/installer_command.py')
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class BootstrapTests(unittest.TestCase):
    def run_case(self, scenario, succeeds):
        lua = shutil.which('lua')
        if not lua:
            self.skipTest('Lua interpreter unavailable')
        body = '-- installer fixture\nreturn true\n'
        command = generator.command('a'*40, 'no', len(body))
        source = command[len("lua -e '"):-1]
        harness = r'''
loadstring = loadstring or load
local case = CASE
local body = "-- installer fixture\nreturn true\n"
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
  if case=="syntax" then return {rtn1=true,code=200,body=string.rep("!",#body)} end
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
        harness = harness.replace('CASE', literal(scenario)).replace('SOURCE', literal(source)).replace('SUCCEEDS', 'true' if succeeds else 'false')
        result = subprocess.run([lua, '-'], input=harness, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_bootstrap_guards_and_success(self):
        for scenario in ['direct', 'duplicate', 'late', 'http', 'short', 'syntax', 'success']:
            with self.subTest(scenario=scenario):
                self.run_case(scenario, scenario == 'success')

    def test_only_explicit_mode_and_immutable_ref(self):
        for ref, mode in [('main', 'yes'), ('a'*40, 'maybe'), ('a'*39, 'yes')]:
            with self.assertRaises(ValueError):
                generator.command(ref, mode)


if __name__ == '__main__':
    unittest.main()
