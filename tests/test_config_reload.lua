package.path = 'src/?.lua;' .. package.path
local Reload, Main, Relay = require('config_reload'), require('main'), require('relay')
local original_floor, original_ceil = math.floor, math.ceil
math.floor, math.ceil = nil, nil -- Match the router's integer-Lua API surface.
local count = 0
local function check(value, label)
  count = count + 1
  assert(value, 'check ' .. count .. ': ' .. label)
end
local base = 'dns host 192.0.2.1\ndns server 198.51.100.1\nip lan1 address 192.0.2.254/24\n'
local changed = base:gsub('dns host 192.0.2.1', 'dns host 192.0.2.2')
local signature = assert(Reload.signature(base))
check(Reload.signature('# comment\r\n' .. base:gsub(' ', '\t') .. 'syslog notice on\n') == signature,
  'whitespace/comments/unrelated setting do not change the snapshot')
check(not Reload.signature(base .. 'administrator password never-retain-me\n'):find('never-retain-me', 1, true),
  'snapshot does not retain unrelated credentials')
for _, input in ipairs({'', '   ', '# comment\n', 'console prompt example\n', base .. '\0'}) do
  check(not Reload.signature(input), 'empty/incomplete/invalid snapshots fail closed')
end
for _, line in ipairs({'dns host none', 'dns service off', 'dns service aaaa filter on',
  'dns static a host.example 192.0.2.3', 'ip host host.example 192.0.2.3',
  'dns server pp 2', 'dns server select 1 dhcp onu1 any .', 'ip pp remote address dhcp',
  'ip lan2 address dhcp', 'ip lan1 secondary address 192.0.3.1/24',
  'ipv6 lan2 dhcp service client', 'no dns server', 'no dns host', 'no ip host example'}) do
  check(Reload.signature(base .. line .. '\n') ~= signature, 'captures relevant input: ' .. line)
end

local function supervised(snapshots, duration, options)
  options = options or {}
  local env = {time = 0, reads = 0, waits = 0, starts = {}, logs = {}, events = {}, snapshots = {}}
  local runtime = {socket = {gettime = function() return env.time end}}
  if not options.no_wait then
    runtime.sleep = function(seconds) env.waits = env.waits + 1; env.time = env.time + seconds end
  end
  runtime.command = function(command)
    check(command == 'show config', 'fixed upstream does not issue extra runtime commands')
    env.reads = env.reads + 1
    local value = snapshots[(env.time - env.time % 30) / 30 + 1]
    if value == nil then value = snapshots[#snapshots] end
    if value == false then return false, 'private-read-error' end
    return true, value
  end
  local profile = {auto_config = true, config_reload_interval = 30, duration = duration,
    config_reload_observe = function(event)
      env.events[#env.events + 1] = event
      if options.observer_throws then error('observer error') end
    end}
  local result = Reload.run(profile, runtime, function(text, control, remaining)
    check(not text:find('never-retain-me', 1, true), 'running generation keeps projection only')
    local policy, err, automatic = Main.read_policy(profile, runtime, text)
    if err then error(err) end
    check(policy and automatic, 'generation uses both parsed routing and ACL')
    env.starts[#env.starts + 1] = {time = env.time, acl = automatic.allowed_clients[1]}
    control.ready()
    local deadline = env.time + remaining
    while env.time < deadline do
      env.time = env.time + 1
      if control.check() then return {responses = 1}, 'config_reload' end
    end
    return {responses = 1}
  end, function(message) env.logs[#env.logs + 1] = message end)
  env.result = result
  return env
end

local env = supervised({base, base .. 'administrator password never-retain-me\n', changed,
  'dns host none\ndns server 198.51.100.1', 'dns host 192.0.2.1\ndns server select broken',
  false, base, 'dns service off\n' .. base, changed, changed}, 271)
check(#env.starts == 4, 'only changed valid snapshots start four generations')
check(env.starts[1].time == 0 and env.starts[2].time == 60 and env.starts[3].time == 180
  and env.starts[4].time == 240, 'off/invalid/unreadable snapshots suspend and recover on next poll')
check(env.starts[2].acl == '192.0.2.2', 'ACL edit reaches new generation')
check(env.reads == 10, 'each poll reads configuration exactly once, including recovery startup')
check(env.result.config_generations == 4 and env.result.config_failures == 4,
  'supervisor counters preserve whole-run failures and generations')
for _, message in ipairs(env.logs) do
  check(not message:find('never-retain-me', 1, true) and not message:find('private-read-error', 1, true),
    'supervisor log does not expose config or command error payload')
end
local unchanged = supervised({base, base, base}, 91, {observer_throws = true})
check(#unchanged.starts == 1 and unchanged.reads == 4, 'identical snapshots preserve generation despite observer failures')
local denied = supervised({'dns host none\ndns server 198.51.100.1'}, 301)
check(#denied.starts == 0 and denied.reads == 11 and denied.waits == 11,
  'repeated initialization failures are limited to one per 30 seconds')
local ok = pcall(supervised, {false}, 61, {no_wait = true})
check(not ok, 'broken wait APIs stop safely instead of spinning')
local unreadable = supervised({false, false, base}, 61)
check(#unreadable.starts == 1 and unreadable.starts[1].time == 60,
  'startup read failure leaves supervisor alive and can recover')

-- Exercise real relay lifecycle at the readiness boundary. These sockets are
-- already accepted/connected before the poll; no old ready input may execute.
local wire = require('dns_wire')
local function readiness_case(change)
  local time, handles, clears, callback_count, cache = 0, {}, 0, 0, {}
  function cache:clear() clears = clears + 1 end
  function cache:stats() return {} end
  local function socket()
    local value = {}
    function value:settimeout() return true end
    function value:bind() return true end
    function value:listen() return true end
    function value:close() self.closed = true end
    function value:receive() self.received = true; return nil, 'timeout', '' end
    function value:receivefrom() return nil, 'timeout' end
    handles[#handles + 1] = value
    return value
  end
  local client, upstream, local_udp = socket(), socket(), socket()
  local api = {tcp = socket, gettime = function() return time end,
    select = function() time = time + 30; return {client, upstream, local_udp}, {} end}
  local relay = Relay.new({allowed_clients = {'192.0.2.1'}, upstreams = {{host = '198.51.100.1', port = 53}},
    control_check = function()
      callback_count = callback_count + 1
      if time >= 30 then
        if change == 'error' then error('control error') end
        return change
      end
      return false
    end}, api, function() end, wire, cache)
  relay.clients[client] = {socket = client, input = '', output = {}, jobs = 0, last_activity = 0,
    read_deadline = 999, peer = '192.0.2.1'}
  relay.client_count = 1
  relay.endpoints[1].socket = upstream
  relay.endpoints[1].state = 'ready'
  relay.endpoints[1].last_activity = 0
  relay.jobs[1] = {serial = 1, udp = local_udp, deadline = 999, state = 'local', response_deadline = 999}
  -- Timers would normally close idle sockets after 30 seconds, independently
  -- of reload. Keep this fixture idle longer so unchanged snapshots test it.
  relay.cfg.idle_timeout = 999
  local successful, reason = relay:step()
  check(callback_count == 2, 'control checked before work and again after select')
  if change then
    check(not successful and reason == 'config_reload', 'change/control failure asks supervisor to rebuild')
    for _, handle in ipairs(handles) do check(handle.closed, 'every listener/client/upstream/UDP socket is closed') end
    check(not client.received and not upstream.received, 'stale readiness does not process input after ACL change')
    check(relay.client_count == 0 and relay.pending == 0 and clears == 1, 'old jobs and cache are cleared')
  else
    check(successful and not client.closed and not upstream.closed and clears == 0,
      'unchanged snapshot keeps client, upstream and cache')
  end
  relay:close()
end
readiness_case(true)
readiness_case('error')
readiness_case(false)

-- Full main + real relay: dynamic PP refresh still occurs on an unchanged
-- configuration, while an EDNS configuration edit creates a new generation.
do
  local time, config_reads, pp_reads, relays, events = 0, 0, 0, {}, {}
  local api = {gettime = function() return time end,
    tcp = function()
      return {settimeout = function() return true end, setoption = function() return true end, bind = function() return true end,
        listen = function() return true end, close = function(self) self.closed = true end}
    end,
    select = function() time = time + 1; return {}, {} end}
  local runtime = {socket = api, command = function(command)
    if command == 'show config' then
      config_reads = config_reads + 1
      local edns = time >= 60 and 'on' or 'off'
      return true, 'dns host 192.0.2.1\ndns server pp 1 edns=' .. edns .. '\n'
    end
    check(command == 'show status pp 1', 'dynamic source remains scoped to configured PP')
    pp_reads = pp_reads + 1
    local ip = time >= 30 and '198.51.100.2' or '198.51.100.1'
    return true, 'PP[1]:\nPPPoE session is connected.\nIPCP Local: IP-Address Primary-DNS('
      .. ip .. '), Remote: IP-Address\nPP IP Address Local: 192.0.2.10, Remote: 192.0.2.1\n'
  end}
  local original = Relay.new
  Relay.new = function(...)
    local relay = original(...)
    relays[#relays + 1] = relay
    return relay
  end
  local ok, result = pcall(Main.start, {auto_config = true, config_reload_interval = 30,
    duration = 91, console_log = false, syslog = false,
    config_reload_observe = function(value) events[#events + 1] = value end}, runtime)
  Relay.new = original
  check(ok, 'full supervisor and relay complete: ' .. tostring(result))
  check(config_reads == 4 and pp_reads == 4, 'one config read per poll plus independent PP runtime refresh')
  check(#relays == 2 and result.config_generations == 2, 'EDNS edit alone triggers exactly one reinitialization')
  check(relays[1].counters.policy_updates == 1, 'unchanged config still refreshes effective dynamic DNS')
  check(relays[1].cfg.dns_policy.fallback.upstreams[1].host == '198.51.100.2', 'dynamic PP address update applied')
  check(relays[2].cfg.dns_policy.fallback.upstreams[1].edns == true, 'new generation applies EDNS edit')
  local seen_stats = false
  for _, event in ipairs(events) do
    if event.event == 'relay' then
      seen_stats = true
      check(type(event.lua_kib) == 'number' and type(event.clients) == 'number'
        and type(event.cache) == 'table', 'poll observer supplies memory and relay/cache metrics')
    end
  end
  check(seen_stats, 'periodic diagnostics emitted without per-query observer calls')
end

-- Full main retries failed construction and failed runtime without leaving a
-- bound listener or spinning. The fourth attempt resumes normal operation.
do
  local time, handles, config_reads, attempts = 0, {}, 0, 0
  local api = {gettime = function() return time end,
    select = function() time = time + 1; return {}, {} end}
  api.tcp = function()
    local handle = {settimeout = function() return true end, setoption = function() return true end, listen = function() return true end,
      close = function(self) self.closed = true end}
    handles[#handles + 1] = handle
    function handle:bind()
      if #handles <= 2 then return nil, 'temporary bind failure' end
      return true
    end
    return handle
  end
  local runtime = {socket = api, sleep = function(seconds) time = time + seconds end,
    command = function()
      config_reads = config_reads + 1
      return true, base
    end}
  local original = Relay.new
  Relay.new = function(...)
    attempts = attempts + 1
    local relay = original(...)
    if attempts == 3 then relay.run = function() error('temporary runtime failure') end end
    return relay
  end
  local ok, result = pcall(Main.start, {auto_config = true, config_reload_interval = 30,
    duration = 121, console_log = false, syslog = false}, runtime)
  Relay.new = original
  check(ok, 'constructor/runtime failures recover inside same main invocation')
  check(#handles == 4 and attempts == 4 and config_reads == 5, 'one retry per interval, then healthy poll')
  for _, handle in ipairs(handles) do check(handle.closed, 'failed and completed generations release their listener') end
  check(result.config_failures == 3 and result.config_generations == 2, 'run-wide diagnostics retain failure/recovery count')
end

-- Native RTX1210 rejected an immediate rebind after the old listener closed.
-- Reload profiles enable reuseaddr, always before bind; unavailable or
-- failed option APIs release the socket for the supervisor's bounded retry.
for _, mode in ipairs({'enabled', 'disabled', 'fails', 'throws', 'missing'}) do
  local events, handle = {}, {}
  function handle:settimeout() events[#events + 1] = 'timeout'; return true end
  if mode ~= 'missing' then
    function handle:setoption(option, enabled)
      check(option == 'reuseaddr' and enabled == true, 'only reuseaddr is enabled')
      events[#events + 1] = 'reuseaddr'
      if mode == 'throws' then error('option failure') end
      if mode == 'fails' then return nil, 'option unavailable' end
      return 1 -- Native API success is numeric.
    end
  end
  function handle:bind() events[#events + 1] = 'bind'; return true end
  function handle:listen() events[#events + 1] = 'listen'; return true end
  function handle:close() self.closed = true end
  local config = {allowed_clients = {'192.0.2.1'}, upstreams = {{host = '198.51.100.1', port = 53}}}
  if mode ~= 'disabled' then config.config_reload_interval = 30 end
  local ok, result = pcall(Relay.new, config,
    {tcp = function() return handle end, gettime = function() return 0 end, select = function() return {}, {} end},
    function() end, wire, nil)
  if mode == 'enabled' then
    check(ok and table.concat(events, ',') == 'timeout,reuseaddr,bind,listen', 'reuseaddr precedes bind')
    result:close()
  elseif mode == 'disabled' then
    check(ok and table.concat(events, ',') == 'timeout,bind,listen', 'normal profile never requests reuseaddr')
    result:close()
  else
    check(not ok and tostring(result):find('listener reuseaddr:', 1, true), 'option failure has explicit diagnostic')
    check(handle.closed and not table.concat(events, ','):find('bind', 1, true), 'option failure closes listener before bind')
  end
end

math.floor, math.ceil = original_floor, original_ceil
print('config reload checks passed: ' .. count)
