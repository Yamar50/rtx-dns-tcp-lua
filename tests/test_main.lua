package.path = 'src/?.lua;' .. package.path
local main = require('main')
local count = 0
local function check(value, label)
  count = count + 1
  assert(value, 'check ' .. count .. ': ' .. (label or ''))
end

local secret = 'secret-never-retained'
local routes = 'dns server select 10 192.0.2.1 any .\n'
local unrelated = 'administrator password ' .. secret .. '\n'
local function contains_secret(value, seen)
  if type(value) == 'string' then return value:find(secret, 1, true) ~= nil end
  if type(value) ~= 'table' then return false end
  seen = seen or {}
  if seen[value] then return false end
  seen[value] = true
  for key, item in pairs(value) do
    if contains_secret(key, seen) or contains_secret(item, seen) then return true end
  end
  return false
end

local function reader(text)
  local calls = {command = 0, socket = 0}
  local runtime = {command = function(command)
    calls.command = calls.command + 1
    check(command == 'show config', 'one running config command')
    return true, text
  end, socket = {tcp = function() calls.socket = calls.socket + 1 end}}
  return runtime, calls
end

local function accepted_service(text, label, config)
  local runtime, calls = reader(unrelated .. text .. '\n' .. routes)
  local policy, err = main.read_policy(config or {}, runtime)
  check(policy and not err and #policy.routes == 1, label)
  check(policy.routes[1].upstreams[1].host == '192.0.2.1', label .. ' route')
  check(calls.command == 1 and calls.socket == 0, label .. ' reads once without sockets')
  check(not contains_secret(policy), label .. ' keeps only parsed descriptors')
end

accepted_service('', 'omitted service defaults to recursive')
accepted_service('dns service recursive', 'explicit recursive')
accepted_service('dns service recursive', 'legacy running option', {dns_config = 'running'})
accepted_service(' \tdns\tservice  recursive \t\r\n', 'whitespace and CRLF')
accepted_service('# dns service off\r\n\n  dns service recursive\r\n', 'comments do not disable DNS')
accepted_service('# dns service off\r\n', 'commented service still defaults to recursive')
accepted_service('dns service fallback on', 'fallback on accepted')
accepted_service('dns service fallback off', 'fallback off accepted')
accepted_service('dns service aaaa filter on', 'separate aaaa command is not a service mode')
accepted_service('dns service aaaa filter off\ndns service recursive', 'aaaa command with explicit mode')

-- Test-only static and internally injected policies do not inspect the router.
local runtime, calls = reader(unrelated .. 'dns service off\n' .. routes)
local policy, err = main.read_policy({dns_config = 'static'}, runtime)
check(policy == nil and err == nil and calls.command == 0, 'static explicitly skips config read')
policy, err = main.read_policy({dns_config = 'static'}, {})
check(policy == nil and err == nil, 'static needs no command API')
local injected = {routes = {}}
policy, err = main.read_policy({dns_policy = injected}, runtime)
check(policy == injected and err == nil and calls.command == 0, 'injected policy skips config read')
policy, err = main.read_policy({dns_policy = injected}, {})
check(policy == injected and err == nil, 'injected policy needs no command API')
for _, mode in ipairs({'typo', '', true, 1}) do
  policy, err = main.read_policy({dns_config = mode}, runtime)
  check(policy == nil and type(err) == 'string' and calls.command == 0,
    'invalid dns_config is rejected before read')
end

local function rejected_start(runtime, label, expected_error, profile)
  local sockets = 0
  runtime.socket = {tcp = function() sockets = sockets + 1 end}
  profile = profile or {}
  profile.console_log, profile.syslog = false, false
  local ok, result = pcall(main.start, profile, runtime)
  check(not ok and type(result) == 'string', label .. ' rejects startup')
  check(sockets == 0, label .. ' creates no sockets')
  check(not contains_secret(result), label .. ' startup error keeps secrets private')
  if expected_error then check(result:find(expected_error, 1, true) ~= nil, label .. ' startup reason') end
end

local function rejected_config(text, label, expected_error)
  local runtime, calls = reader(unrelated .. text)
  local policy, err = main.read_policy({}, runtime)
  check(policy == nil and type(err) == 'string', label .. ' read failure')
  check(not contains_secret(err), label .. ' read error keeps secrets private')
  if expected_error then check(err == expected_error, label .. ' exact reason') end
  check(calls.command == 1 and calls.socket == 0, label .. ' read creates no sockets')
  rejected_start(runtime, label, expected_error)
  check(calls.command == 2, label .. ' one config snapshot per start')
end

rejected_config('dns service off\n' .. routes, 'explicit service off', 'dns service is off')
rejected_config(' \tdns  service\toff \r\n', 'off with no routes', 'dns service is off')
rejected_config('dns service off # disabled\r\n' .. routes, 'unsupported inline off comment')
for _, case in ipairs({
  {'dns service recursive\ndns service recursive', 'duplicate recursive'},
  {'dns service recursive\ndns service off', 'conflicting service modes'},
  {'dns service off\ndns service recursive', 'conflicting reverse order'},
  {'dns service off\ndns service off', 'duplicate off'},
  {'dns service', 'missing service mode'},
  {'dns service forwarding', 'unsupported service mode'},
  {'dns service recursive extra', 'extra recursive argument'},
  {'dns service recursive # enabled', 'unsupported inline recursive comment'},
  {'dns service off extra', 'extra off argument'},
  {'no dns service', 'negated service'},
  {'no dns service recursive', 'negated explicit mode'},
  {'no dns service off', 'negated off mode'},
}) do
  rejected_config(case[1] .. '\n' .. routes, case[2])
end
rejected_config('dns service recursive\ndns server select ' .. secret .. ' 192.0.2.1 any .', 'malformed rule id with secret')
-- Dynamic source failure is query-local; startup and independent fixed routes survive.
local dynamic_calls = {}
local dynamic_runtime = {command = function(command)
  dynamic_calls[#dynamic_calls + 1] = command
  if command == 'show config' then return true, unrelated .. [[
dns service fallback on
dns service aaaa filter on
dns server select 10 pp 1 any example.test
dns server 192.0.2.1
]] end
  return false, secret
end}
local dynamic_policy, dynamic_error, _, refresh = main.read_policy({}, dynamic_runtime)
check(dynamic_policy and not dynamic_error and type(refresh) == 'function', 'dynamic startup survives unavailable runtime')
check(dynamic_policy.aaaa_filter == true, 'AAAA flag retained independently of fallback activation')
check(dynamic_policy.routes[1].unavailable and #dynamic_policy.routes[1].upstreams == 0, 'unknown PP blocked')
check(dynamic_policy.fallback.upstreams[1].host == '192.0.2.1', 'independent ordinary route remains available')
check(not contains_secret(dynamic_policy), 'failed status details not retained')
local before = #dynamic_calls
refresh()
check(#dynamic_calls > before, 'explicit refresh rereads dynamic status')
for i = before + 1, #dynamic_calls do check(dynamic_calls[i] ~= 'show config', 'refresh never rereads config') end

for _, failure in ipairs({'missing', 'failure', 'throw', 'no_text', 'non_text'}) do
  local runtime = {}
  if failure ~= 'missing' then
    runtime.command = function()
      if failure == 'throw' then error(secret) end
      if failure == 'failure' then return false, secret end
      if failure == 'no_text' then return true end
      return true, {password = secret}
    end
  end
  local policy, err = main.read_policy({}, runtime)
  check(policy == nil and type(err) == 'string', failure .. ' config API is rejected')
  check(not contains_secret(err), failure .. ' read error keeps secrets private')
  rejected_start(runtime, failure .. ' config API')
end

-- Exercise the real entrypoint logger without opening a socket. Long-running
-- counters and stopped summaries can exceed Yamaha's SYSLOG message limit.
local Relay = require('relay')
local original_new, original_print = Relay.new, print
local messages = {
  '', 'DNSRELAY short', string.rep('x', 230), string.rep('x', 231),
  string.rep('x', 232), string.rep('x', 444), string.rep('x', 5000),
  string.rep(string.char(130, 160), 240),
  'DNSRELAY stats queries=1000000 responses=1000000 pending=32 clients=32 dials=1234 failures=123 accept_failures=123 connections=4 cache_hits=1000000 cache_entries=256 cache_bytes=1048576 cache_ttl_fields=4096 lua_kib=1234 uptime=1000000'
}
local console, sent = {}, {}
local summary = {long_counter = string.rep('9', 500)}
Relay.new = function(_config, _socket, log)
  return {
    run = function()
      for _, message in ipairs(messages) do log(message) end
      return summary
    end,
    close = function() end
  }
end
print = function(message) console[#console + 1] = message end
local logging_ok, logging_error = pcall(main.start, {dns_config = 'static'}, {
  socket = {}, syslog = function(level, message)
    check(level == 'info', 'SYSLOG level remains info')
    check(#message <= 231, 'every SYSLOG record fits the Yamaha limit')
    sent[#sent + 1] = message
    return true
  end
})
Relay.new, print = original_new, original_print
check(logging_ok, 'logging start succeeds: ' .. tostring(logging_error))
messages[#messages + 1] = 'DNSRELAY stopped long_counter=' .. summary.long_counter .. ' reason=duration'
check(#console == #messages, 'console emits one full record per message')
local at, continuation = 1, 'DNSRELAY continued '
for index, message in ipairs(messages) do
  check(console[index] == message, 'console keeps original message ' .. index)
  local rebuilt = sent[at]
  at = at + 1
  while #rebuilt < #message do
    local record = sent[at]
    check(record and record:sub(1, #continuation) == continuation,
      'continuation identifies DNSRELAY ' .. index)
    rebuilt = rebuilt .. record:sub(#continuation + 1)
    at = at + 1
  end
  check(rebuilt == message, 'SYSLOG chunks preserve every byte ' .. index)
end
check(at == #sent + 1, 'no missing or extra SYSLOG records')

-- The ready-to-run profile obtains policy, access and local names from one
-- snapshot. No household values are present in the distributed profile.
local automatic_text = unrelated .. routes .. [[
dns service recursive
dns host lan1
ip lan1 address 192.0.2.1/24
ip host router.home.arpa 192.0.2.1
]]
local auto_runtime, auto_calls = reader(automatic_text)
local auto_policy, auto_error, settings = main.read_policy({auto_config = true}, auto_runtime)
check(auto_policy and not auto_error and settings, 'automatic startup settings parsed')
check(auto_calls.command == 1, 'automatic access and DNS policy share one snapshot')
check(settings.listen_host == '0.0.0.0' and settings.listen_port == 53, 'ready TCP/53 listener')
check(settings.local_dns_host == '192.0.2.1', 'local DNS uses an address permitted by dns host')
check(#settings.local_names == 2, 'registered forward and reverse names imported')
check(not contains_secret(settings), 'automatic settings do not retain unrelated config')
local original_new_auto, captured = Relay.new, nil
Relay.new = function(config)
  captured = config
  return {run = function(_, duration) check(duration == nil, 'release runs without a time limit'); return {} end,
    close = function() end}
end
local supplied = {auto_config = true, console_log = false, syslog = false}
local ok_auto, error_auto = pcall(main.start, supplied, auto_runtime)
Relay.new = original_new_auto
check(ok_auto, 'ready-to-run startup succeeds: ' .. tostring(error_auto))
check(captured and captured.dns_policy and captured.listen_port == 53, 'relay receives parsed policy and listener')
check(captured and #captured.local_names == 2 and #captured.allowed_clients > 0, 'relay receives local names and ACL')
check(supplied.dns_policy == nil and supplied.allowed_clients == nil, 'startup leaves the supplied profile unchanged')
for _, profile in ipairs({{auto_config = 'yes'}, {auto_config = true, dns_config = 'static'},
  {auto_config = true, dns_policy = {routes = {}}}}) do
  local runtime, calls = reader(automatic_text)
  local policy, err = main.read_policy(profile, runtime)
  check(not policy and err and calls.command == 0, 'conflicting auto profile rejected before I/O')
end
rejected_start(reader(unrelated .. routes .. 'dns host none\n'),
  'native DNS access disabled in auto mode', nil, {auto_config = true})

print('main policy and logging checks passed: ' .. count)
