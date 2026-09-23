package.path = "./src/?.lua;" .. package.path
local Relay = require("relay")

local function eq(actual, expected, message)
  assert(actual == expected, (message or "not equal") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end
local function u16(n) return string.char((n - n % 256) / 256, n % 256) end
local function id(raw) return string.byte(raw, 1) * 256 + string.byte(raw, 2) end
local function frame(raw) return u16(#raw) .. raw end
local function query(n, name) return u16(n) .. "Q" .. (name or "example.test.") end
local function answer(raw) return string.sub(raw, 1, 2) .. "R" .. string.sub(raw, 4) end
local function canonical_name(name)
  local parts = {}
  for label in string.gmatch(string.lower(name), "[^.]+") do
    if #label > 63 then return "" end -- Maximum-frame tests use an intentionally synthetic wire module.
    parts[#parts + 1] = string.char(#label) .. label
  end
  return table.concat(parts) .. "\0"
end
local wire = {
  frame = frame,
  upstream_query = function(q, _server) return q.raw end,
  downstream_response = function(raw, _q, _server) return raw end,
  with_id = function(raw, value) return u16(value) .. string.sub(raw, 3) end,
  parse_query = function(raw)
    if string.sub(raw, 3, 3) ~= "Q" then return nil, "invalid" end
    return { raw = raw, id = id(raw), name = string.sub(raw, 4), retryable = true,
      canonical_name = canonical_name(string.sub(raw, 4)) }
  end,
  validate_response = function(raw, q, expected)
    return id(raw) == expected and string.sub(raw, 3, 3) == "R" and string.sub(raw, 4) == q.name
  end,
  error_response = function(q, rcode)
    return u16(type(q) == "table" and q.id or id(q)) .. "E" .. tostring(rcode) .. string.rep("!", 8)
  end
}

local function mock(options)
  options = options or {}
  local env = { time = 0, sockets = {}, tcp_created = 0, upstream_queries = 0,
    tcp_dials = {}, upstream_requests = {}, pending_accept = {}, accept_failures = {}, udp_count = 0, last_writers = {}, logs = {} }
  local methods = {}
  function methods:settimeout(_) return 1 end
  function methods:bind(host, port) self.host, self.port = host, port; return 1 end
  function methods:listen(_) self.kind = "listener"; return 1 end
  function methods:getpeername()
    if self.kind == "client" then return self.peer or "198.18.32.30", 41000 end
    if self.connected then return self.host, self.port end
    return nil, "getpeername failed"
  end
  function methods:accept()
    if env.accept_error then
      env.accept_failures[#env.accept_failures + 1] = env.time
      return nil, env.accept_error
    end
    if #env.pending_accept == 0 then return nil, "timeout" end
    return table.remove(env.pending_accept, 1)
  end
  function methods:connect(host, port)
    self.host, self.port, self.kind = host, port, "upstream"
    env.tcp_dials[#env.tcp_dials + 1] = env.time
    self.mode = options.connect_mode and options.connect_mode(self, #env.tcp_dials) or "pending"
    if self.mode == "resource" then return nil, "Can't assign requested address" end
    if self.mode == "immediate" then self.connected = true; return 1 end
    return nil, "timeout"
  end
  function methods:close() self.closed = true; self.close_count = (self.close_count or 0) + 1; return 1 end
  function methods:receive(n)
    self.receive_count = (self.receive_count or 0) + 1
    local amount = math.min(n, #self.input, options.read_chunk or n)
    local part = string.sub(self.input, 1, amount)
    self.input = string.sub(self.input, amount + 1)
    if amount == n then return part end
    return nil, self.eof and #self.input == 0 and "closed" or "timeout", part
  end
  function methods:send(raw, first)
    first = first or 1
    local last = math.min(#raw, first + (options.send_chunk or #raw) - 1)
    local part = string.sub(raw, first, last)
    self.output = self.output .. part
    if self.kind == "upstream" then
      self.server_input = self.server_input .. part
      while #self.server_input >= 2 do
        local length = id(self.server_input)
        if #self.server_input < length + 2 then break end
        local request = string.sub(self.server_input, 3, length + 2)
        self.server_input = string.sub(self.server_input, length + 3)
        env.upstream_queries = env.upstream_queries + 1
        env.upstream_requests[#env.upstream_requests + 1] = { host = self.host, port = self.port, raw = request }
        if options.respond then options.respond(self, request, env)
        else self.input = self.input .. frame(answer(request)) end
      end
    end
    if last < #raw then return nil, "timeout", last end
    return last
  end
  function methods:sendto(raw, host, port)
    self.udp_response, self.remote_host, self.remote_port = answer(raw), host, port
    env.udp_count = env.udp_count + 1
    return #raw
  end
  function methods:receivefrom(_)
    local response = self.udp_response
    self.udp_response = nil
    if response then return response, self.remote_host, self.remote_port end
    return nil, "timeout"
  end
  local function socket(kind)
    local s = setmetatable({ kind = kind, input = "", output = "", server_input = "" }, { __index = methods })
    env.sockets[#env.sockets + 1] = s
    return s
  end
  env.api = {
    gettime = function() return env.time end,
    tcp = function()
      env.tcp_created = env.tcp_created + 1
      if env.tcp_created > 1 and options.tcp_allocation_error then return nil, "socket allocation failed" end
      return socket("new")
    end,
    udp = function() return socket("udp") end,
    select = function(readers, writers, timeout)
      env.last_readers = readers
      env.last_writers = writers
      if options.select_error then return nil, "select failed" end
      local r, w = {}, {}
      for _, s in ipairs(readers) do
        assert(not s.closed, "closed socket monitored for read")
        if (s.kind == "listener" and #env.pending_accept > 0)
          or #s.input > 0 or s.eof or s.udp_response then r[#r + 1] = s end
      end
      for _, s in ipairs(writers) do
        assert(not s.closed, "closed socket monitored for write")
        if s.mode ~= "unreachable" and not s.write_blocked then
          if s.kind == "upstream" and s.mode ~= "refused" then s.connected = true end
          w[#w + 1] = s
        end
      end
      env.time = env.time + (env.select_advance or ((#r == 0 and #w == 0) and timeout or 0.001))
      return r, w
    end
  }
  function env.client(raw, peer)
    local c = socket("client")
    c.peer, c.input = peer, raw and frame(raw) or ""
    env.pending_accept[#env.pending_accept + 1] = c
    return c
  end
  return env
end

local function relay(env, override, cache, wire_module)
  local config = { listen_host = "198.18.32.42", allowed_clients = { "198.18.32.0/20" },
    upstreams = { { host = "198.18.32.30", port = 15353 }, { host = "198.18.32.31", port = 15353 } },
    local_zones = { "is.example.test", "18.198.in-addr.arpa" } }
  for key, value in pairs(override or {}) do config[key] = value end
  return Relay.new(config, env.api, function(line) env.logs[#env.logs + 1] = line end, wire_module or wire, cache)
end

local function route_policy(routes, choose)
  return { routes = routes, select = function(_, q, address) return choose(q, address) end }
end

local function policy_cache()
  local cache = { entries = {}, lookups = {}, inserts = {} }
  function cache:get(q, policy)
    self.lookups[#self.lookups + 1] = policy
    local raw = self.entries[policy .. ":" .. q.name]
    if raw then return wire.with_id(raw, q.id) end
  end
  function cache:put(q, policy, raw)
    eq(id(raw), q.id, "cache receives original client ID")
    self.inserts[#self.inserts + 1] = policy
    self.entries[policy .. ":" .. q.name] = raw
  end
  function cache:clear() self.entries = {}; self.clears = (self.clears or 0) + 1 end
  return cache
end

local function steps(r, count)
  for _ = 1, count do assert(r:step()) end
end

local function until_true(r, predicate, limit)
  for _ = 1, limit or 1000 do
    if predicate() then return end
    assert(r:step())
  end
  error("condition did not become true")
end

local tests = {}

function tests.routing_configuration_cannot_trigger_hostname_resolution()
  local invalid = {
    {upstreams = {{host = "resolver.example"}}},
    {upstreams = {{host = "198.18.32.999"}}},
    {upstreams = {{host = "198.18.32.30", port = 65536}}},
    {local_dns_host = "localhost"}, {listen_host = "localhost"},
    {listen_port = 0}, {local_dns_port = "53"}
  }
  for _, config in ipairs(invalid) do
    local env = mock()
    local ok = pcall(function() relay(env, config) end)
    eq(ok, false, "invalid routing configuration rejected")
    eq(env.tcp_created, 0, "reject before creating any socket")
  end
end
function tests.persistent_connection_over_4000()
  local env = mock()
  local r = relay(env, { query_rate_per_ip = 1000, query_burst_per_ip = 1000 })
  local c = env.client()
  steps(r, 1)
  for n = 1, 4100 do
    local q = query(n)
    c.input = c.input .. frame(q)
    until_true(r, function() return #c.output > 0 end, 20)
    eq(c.output, frame(answer(q)), "reply content and original ID")
    c.output = ""
  end
  eq(#env.tcp_dials, 1, "persistent upstream connection count")
  eq(env.upstream_queries, 4100)
  eq(r.pending, 0)
  eq(r:stats_snapshot().responses, 4100)
  r:close()
end

function tests.reordered_partial_frames_and_writes()
  local env = mock({ read_chunk = 3, send_chunk = 4, respond = function(s, request)
    s.held = s.held or {}; s.held[#s.held + 1] = request
    if #s.held == 4 then
      for n = 4, 1, -1 do s.input = s.input .. frame(answer(s.held[n])) end
      s.held = {}
    end
  end })
  local r = relay(env)
  local clients = {}
  for n = 1, 4 do clients[n] = env.client(query(100 + n, "query" .. n .. ".test.")) end
  until_true(r, function()
    for _, c in ipairs(clients) do if #c.output < 2 or #c.output < id(c.output) + 2 then return false end end
    return true
  end)
  for n, c in ipairs(clients) do eq(c.output, frame(answer(query(100 + n, "query" .. n .. ".test.")))) end
  eq(#env.tcp_dials, 1)
  eq(env.upstream_queries, 4)
  r:close()
end

function tests.primary_full_does_not_open_secondary()
  local env = mock({ respond = function() end })
  local r = relay(env, { max_clients_per_ip = 32 })
  for n = 1, 8 do env.client(query(n)) end
  until_true(r, function() return env.upstream_queries == 4 end)
  eq(#env.tcp_dials, 1)
  eq(r.endpoints[1].count, 4)
  eq(#r.queue, 4)
  r:close()
end

function tests.resource_freeze_cache_and_local_continue()
  local env = mock({ connect_mode = function() return "resource" end })
  local cached = query(55, "cached.test.")
  local cache = { get = function(_, q) if q.name == "cached.test." then return answer(q.raw) end end,
    put = function() end }
  local r = relay(env, { query_rate_per_ip = 1000, query_burst_per_ip = 1000 }, cache)
  local c = env.client(query(1))
  until_true(r, function() return #c.output > 0 end)
  eq(#env.tcp_dials, 1)
  eq(r.resource_until, 30 + r.events.resource.at)
  for n = 1, 100 do
    local rejected = env.client(query(n))
    until_true(r, function() return #rejected.output > 0 end)
    rejected.eof = true
  end
  eq(#env.tcp_dials, 1, "no per-query resource retry")
  local hit = env.client(cached)
  local local_client = env.client(query(56, "router01.is.example.test."))
  until_true(r, function() return #hit.output > 0 and #local_client.output > 0 end)
  eq(hit.output, frame(answer(cached)))
  eq(local_client.output, frame(answer(query(56, "router01.is.example.test."))))
  eq(env.udp_count, 1)
  eq(#env.tcp_dials, 1)
  env.time = r.resource_until + 0.1
  local probe = env.client(query(57))
  until_true(r, function() return #probe.output > 0 end)
  eq(#env.tcp_dials, 2, "one recovery probe after 30 sec")
  r:close()
end

function tests.endpoint_backoff_and_probe()
  local env = mock({ connect_mode = function(_, n) return n <= 2 and "refused" or "pending" end })
  local r = relay(env)
  local c = env.client(query(1))
  until_true(r, function() return #c.output > 0 end)
  eq(#env.tcp_dials, 2)
  eq(r.endpoints[1].failures, 1)
  eq(r.endpoints[2].failures, 1)
  local blocked = env.client(query(2))
  until_true(r, function() return #blocked.output > 0 end)
  eq(#env.tcp_dials, 2)
  env.time = 2
  local recovered = env.client(query(3))
  until_true(r, function() return #recovered.output > 0 end)
  eq(recovered.output, frame(answer(query(3))))
  eq(r.endpoints[1].failures, 0)
  eq(r.endpoints[1].probe, false)
  r:close()
end

function tests.idle_socket_not_writable_and_normal_fin()
  local env = mock()
  local r = relay(env)
  local c = env.client(query(1))
  until_true(r, function() return #c.output > 0 end)
  steps(r, 1)
  eq(#env.last_writers, 0, "idle sockets must not be writable interests")
  local upstream = r.endpoints[1].socket
  upstream.eof = true
  steps(r, 1)
  eq(r.endpoints[1].state, "closed")
  eq(r.endpoints[1].failures, 0, "idle EOF is not a failure")
  r:close()
end

function tests.timeout_retries_at_most_once()
  local env = mock({ respond = function() end })
  local r = relay(env)
  local c = env.client(query(4))
  until_true(r, function() return #c.output > 0 end)
  eq(env.upstream_queries, 2)
  eq(#env.tcp_dials, 2)
  eq(r.pending, 0)
  assert(env.time <= 6, "total deadline is bounded")
  r:close()
end

function tests.connection_refused_does_not_spin()
  local env = mock({ connect_mode = function() return "refused" end })
  local r = relay(env)
  local c = env.client(query(4))
  until_true(r, function() return #c.output > 0 end)
  eq(#env.tcp_dials, 2)
  for _, ep in ipairs(r.endpoints) do eq(ep.state, "closed") end
  local before = env.time
  steps(r, 1)
  assert(env.time >= before + 1, "select must wait with failed sockets removed")
  r:close()
end

function tests.select_error_stops_or_sleeps()
  local env = mock({ select_error = true })
  local r = relay(env)
  local ok, err = r:step()
  eq(ok, nil); eq(err, "select failed"); eq(r.stopped, true)
  r:close()
  env = mock({ select_error = true })
  local sleeps = 0
  r = relay(env, { sleep = function(seconds) sleeps = sleeps + seconds; env.time = env.time + seconds end })
  steps(r, 3)
  eq(sleeps, 3)
  r:close()
end

function tests.unauthorized_clients_and_partial_query_deadline()
  local env = mock()
  local r = relay(env)
  local denied = env.client(query(1), "10.0.0.2")
  local slow = env.client()
  slow.input = "\0"
  until_true(r, function() return slow.closed end)
  eq(denied.closed, true)
  eq(#env.tcp_dials, 0)
  eq(r.client_count, 0)
  r:close()
end

function tests.bounds_and_abandoned_client_correlation()
  local env = mock({ respond = function() end })
  local r = relay(env, { max_clients_per_ip = 32 })
  local clients = {}
  for n = 1, 33 do clients[n] = env.client(query(n)) end
  until_true(r, function() return r.pending == 32 and env.upstream_queries == 4 end)
  eq(r.client_count, 32)
  eq(r.pending, 32)
  eq(#env.pending_accept, 1)
  local abandoned
  for _, job in pairs(r.jobs) do if job.state == "waiting" then abandoned = job; break end end
  if abandoned and abandoned.endpoint then
    r:_close_client(abandoned.client)
    local ep = abandoned.endpoint
    ep.socket.input = frame(answer(wire.with_id(abandoned.query.raw, abandoned.upstream_id)))
    steps(r, 1)
    eq(ep.failures, 0)
  end
  r:close()
end

function tests.cidr_and_zone_boundary()
  eq(Relay.cidr_matches("198.18.40.30", "198.18.32.0/20"), true)
  eq(Relay.cidr_matches("198.18.48.30", "198.18.32.0/20"), false)
  eq(Relay.cidr_matches("255.255.255.255", "0.0.0.0/0"), true)
  eq(Relay.cidr_matches("192.0.0.1", "128.0.0.0/1"), true)
  eq(Relay.cidr_matches("127.255.255.255", "128.0.0.0/1"), false)
  eq(Relay.cidr_matches("198.18.32.43", "198.18.32.42/31"), true)
  eq(Relay.cidr_matches("198.18.32.44", "198.18.32.42/31"), false)
  eq(Relay.cidr_matches("198.18.32.42", "198.18.32.42/32"), true)
  eq(Relay.cidr_matches("198.18.32.43", "198.18.32.42/32"), false)
  local env = mock()
  local r = relay(env)
  eq(r:_local({ canonical_name = canonical_name("router01.is.example.test.") }), true)
  eq(r:_local({ canonical_name = canonical_name("notis.example.test.") }), false)
  eq(r:_local({ canonical_name = canonical_name("is.example.test.") }), true)
  local dotted_label = "x.is.example.test"
  eq(r:_local({ name = dotted_label .. ".", canonical_name = string.char(#dotted_label) .. dotted_label .. "\0" }), false)
  local dotted_prefix = "x.is"
  eq(r:_local({ name = "x.is.example.test.", canonical_name = string.char(#dotted_prefix)
    .. dotted_prefix .. canonical_name("example.test.") }), false)
  r:close()
end

function tests.maximum_65535_response_partial_and_client_halfclose()
  local env = mock({ read_chunk = 4093, send_chunk = 2047 })
  local long_name = string.rep("x", 65532)
  local r = relay(env, { max_query = 65535 })
  local q = query(65530, long_name)
  eq(#q, 65535)
  local c = env.client(q)
  c.eof = true
  until_true(r, function() return #c.output == 65537 end)
  eq(c.output, frame(answer(q)))
  eq(c.closed, true, "half-closed client receives full response before close")
  eq(#env.tcp_dials, 1)
  r:close()
end

function tests.halfclose_drains_buffered_batches_with_partial_writes()
  for _, pipeline in ipairs({ 1, 4 }) do
    for _, count in ipairs({ 1, 4, 5, 6, 13 }) do
      for _, cached in ipairs({ false, true }) do
        local env = mock({ send_chunk = 3 }); env.select_advance = 0
        local cache = cached and { get = function(_, q) return answer(q.raw) end } or nil
        local r = relay(env, { client_pipeline = pipeline }, cache)
        local c, expected = env.client(), ""
        for n = 1, count do
          c.input = c.input .. frame(query(2100 + n))
          expected = expected .. frame(answer(query(2100 + n)))
        end
        c.eof = true
        until_true(r, function()
          local state = r.clients[c]
          if state then
            assert(state.jobs + #state.output <= pipeline, "half-close preserves client pipeline bound")
            if state.read_eof then eq(state.read_deadline, nil, "EOF has no read deadline") end
          end
          assert(r.pending <= r.cfg.max_pending, "half-close preserves global pending bound")
          for _, ep in ipairs(r.endpoints) do assert(ep.count <= r.cfg.pipeline, "upstream pipeline bound") end
          return c.closed
        end)
        eq(c.output, expected, "all buffered replies survive EOF and partial writes")
        eq(c.receive_count, 1, "EOF socket is not read again")
        eq(env.upstream_queries, cached and 0 or count)
        eq(r:stats_snapshot().queries, count)
        eq(r:stats_snapshot().client_responses_sent, count)
        eq(r.pending, 0)
        eq(c.close_count, 1)
        r:close()
      end
    end
  end
end

function tests.halfclose_discards_only_truncated_final_frame()
  local tail = frame(query(2299))
  for _, count in ipairs({ 0, 1, 5, 9 }) do
    for _, size in ipairs({ 1, 2, #tail - 1 }) do
      local env = mock({ send_chunk = 3 }); env.select_advance = 0
      local r = relay(env)
      local c, expected = env.client(), ""
      for n = 1, count do
        c.input = c.input .. frame(query(2200 + n))
        expected = expected .. frame(answer(query(2200 + n)))
      end
      c.input, c.eof = c.input .. string.sub(tail, 1, size), true
      until_true(r, function() return c.closed end)
      eq(c.output, expected, "complete frames receive replies; truncated tail receives none")
      eq(env.upstream_queries, count)
      eq(r:stats_snapshot().queries or 0, count)
      eq(r.pending, 0)
      eq(c.close_count, 1)
      r:close()
    end
  end
end

function tests.buffered_batches_without_eof_accept_later_frame_completion()
  local env = mock({ send_chunk = 3 }); env.select_advance = 0
  local r = relay(env)
  local c, expected = env.client(), ""
  for n = 1, 9 do
    c.input = c.input .. frame(query(2300 + n))
    expected = expected .. frame(answer(query(2300 + n)))
  end
  local tail = frame(query(2310))
  c.input = c.input .. string.sub(tail, 1, 1)
  until_true(r, function() return #c.output == #expected end)
  eq(c.output, expected)
  eq(c.closed, nil, "connection without EOF stays open")
  eq(r.clients[c].input, string.sub(tail, 1, 1), "partial frame is retained without EOF")
  assert(r.clients[c].read_deadline, "partial frame retains its deadline")
  c.input = string.sub(tail, 2)
  expected = expected .. frame(answer(query(2310)))
  until_true(r, function() return #c.output == #expected end)
  eq(c.output, expected)
  eq(c.closed, nil)
  eq(env.upstream_queries, 10)
  r:close()
end

function tests.halfclose_buffered_frames_wait_for_jobs_without_read_timeout()
  local held, release = {}, false
  local env = mock({ respond = function(socket, request)
    if release then socket.input = socket.input .. frame(answer(request))
    else held[#held + 1] = { socket = socket, request = request } end
  end }); env.select_advance = 0
  local r = relay(env, { response_timeout = 10, total_timeout = 20 })
  local c, expected = env.client(), ""
  for n = 1, 6 do
    c.input = c.input .. frame(query(2400 + n))
    expected = expected .. frame(answer(query(2400 + n)))
  end
  c.eof = true
  until_true(r, function() return #held == 4 end)
  eq(r.clients[c].read_eof, true)
  assert(#r.clients[c].input > 0, "complete frames wait behind active jobs")
  env.time = 4
  steps(r, 1)
  eq(c.closed, nil, "read timeout does not discard buffered frames after EOF")
  release = true
  for _, item in ipairs(held) do item.socket.input = item.socket.input .. frame(answer(item.request)) end
  until_true(r, function() return c.closed end)
  eq(c.output, expected)
  eq(env.upstream_queries, 6)
  r:close()
end

function tests.halfclose_backpressure_preserves_bounds_and_resumes()
  local env = mock({ send_chunk = 3 })
  local r = relay(env)
  local c, expected = env.client(), ""
  for n = 1, 9 do
    c.input = c.input .. frame(query(2500 + n))
    expected = expected .. frame(answer(query(2500 + n)))
  end
  c.eof, c.write_blocked = true, true
  until_true(r, function() return r.clients[c] and #r.clients[c].output == 4 end)
  local buffered, before = r.clients[c].input, env.time
  steps(r, 1)
  eq(env.time - before, r.cfg.select_timeout, "backpressure allows select to wait")
  eq(r.clients[c].input, buffered, "full output queue stops further buffered queries")
  eq(#r.clients[c].output, 4)
  eq(env.upstream_queries, 4)
  eq(c.receive_count, 1, "EOF does not produce repeated readable wakeups")
  c.write_blocked = false
  until_true(r, function() return c.closed end)
  eq(c.output, expected, "buffered work resumes when client becomes writable")
  eq(env.upstream_queries, 9)
  r:close()
end

function tests.halfclose_backpressure_keeps_hard_output_deadline()
  local env = mock(); env.select_advance = 0
  local r = relay(env)
  local c = env.client()
  for n = 1, 9 do c.input = c.input .. frame(query(2600 + n)) end
  c.eof, c.write_blocked = true, true
  until_true(r, function() return r.clients[c] and #r.clients[c].output == 4 end)
  env.time = 2
  steps(r, 1)
  eq(c.closed, true, "EOF drain is still bounded by the output deadline")
  eq(c.output, "")
  eq(env.upstream_queries, 4, "stalled output prevents further buffered queries")
  eq(r.pending, 0)
  eq(r:stats_snapshot().client_timeouts, 1)
  r:close()
end

function tests.response_write_deadline_starts_after_all_preparation()
  for _, integer_clock in ipairs({ false, true }) do
    local env = mock(); env.select_advance = 0
    if integer_clock then env.api.gettime = function() return math.floor(env.time) end end
    local delayed_wire = {}
    for key, value in pairs(wire) do delayed_wire[key] = value end
    -- Cover both a >2-second preparation and a shorter preparation that crosses
    -- the stale deadline on an integer clock. Include framing in preparation.
    local delays = integer_clock and { 0.5, 0.25, 0.25, 0.5 } or { 0.5, 0.5, 0.5, 1 }
    delayed_wire.validate_response = function(...)
      env.time = env.time + delays[1]
      return wire.validate_response(...)
    end
    delayed_wire.downstream_response = function(...)
      env.time = env.time + delays[2]
      return wire.downstream_response(...)
    end
    delayed_wire.frame = function(raw)
      if string.sub(raw, 3, 3) == "R" then env.time = env.time + delays[4] end
      return frame(raw)
    end
    local cache = { get = function() end }
    function cache:put(_, _, _, saved_at)
      self.saved_at = saved_at
      env.time = env.time + delays[3]
    end
    local r = relay(env, nil, cache, delayed_wire)
    eq(r.cfg.client_write_timeout, 2, "default write timeout remains two seconds")
    env.time = 0.75
    local q = query(2650)
    local c = env.client(q)
    until_true(r, function() return env.upstream_queries == 1 end)
    local job
    for _, value in pairs(r.jobs) do job = value end
    local query_deadline, response_deadline = job.deadline, job.response_deadline
    local received_at = integer_clock and 0 or 0.75
    until_true(r, function() return r.clients[c] and #r.clients[c].output == 1 end)
    local prepared_at = integer_clock and math.floor(env.time) or env.time
    local client = r.clients[c]
    eq(client.output[1].deadline, prepared_at + 2, "write budget starts after framing")
    eq(client.last_activity, prepared_at, "prepared response refreshes client activity")
    eq(cache.saved_at, received_at, "preparation does not extend cached TTL lifetime")
    eq(job.deadline, query_deadline, "query deadline is not restarted")
    eq(job.response_deadline, response_deadline, "upstream response deadline is not restarted")
    until_true(r, function() return #c.output > 0 end)
    eq(c.output, frame(answer(q)), "prepared response reaches the client")
    eq(c.closed, nil)
    eq(r:stats_snapshot().client_timeouts, nil)
    r:close()
  end
end

function tests.prepared_response_keeps_fixed_write_deadline()
  for _, partial_and_followup in ipairs({ false, true }) do
    local env = mock({ send_chunk = 1 }); env.select_advance = 0
    local cache = { get = function() end, put = function() env.time = env.time + 2.5 end }
    local r = relay(env, nil, cache)
    local c = env.client(query(2660)); c.write_blocked = true
    until_true(r, function() return r.clients[c] and #r.clients[c].output == 1 end)
    local client, first = r.clients[c], r.clients[c].output[1]
    eq(first.deadline, 4.5, "slow preparation still leaves a two-second write budget")
    if partial_and_followup then
      env.time, c.write_blocked = 3.5, false
      steps(r, 1)
      eq(first.pos, 2, "one byte is sent before backpressure")
      r:_reply(client, answer(query(2661)))
      eq(#client.output, 2)
      eq(client.output[2].deadline, 5.5, "later response gets its own write budget")
      eq(first.deadline, 4.5, "partial send and later reply do not renew the first deadline")
      c.write_blocked = true
    end
    env.time = 4.499
    steps(r, 1)
    eq(c.closed, nil, "blocked client stays open until the preparation-based deadline")
    env.time = 4.5
    steps(r, 1)
    eq(c.closed, true, "blocked client closes at the original output deadline")
    eq(#c.output, partial_and_followup and 1 or 0, "no output bypasses backpressure")
    eq(r:stats_snapshot().client_timeouts, 1)
    r:close()
  end
end

function tests.halfclose_rate_cutoff_ignores_remaining_buffered_queries()
  local env = mock({ send_chunk = 3 }); env.select_advance = 0
  local cache = { get = function(_, q) return answer(q.raw) end }
  local r = relay(env, { query_rate_per_ip = 1, query_burst_per_ip = 5 }, cache)
  local c, expected = env.client(), ""
  for n = 1, 9 do
    c.input = c.input .. frame(query(2700 + n))
    if n <= 5 then expected = expected .. frame(answer(query(2700 + n))) end
  end
  c.eof = true
  until_true(r, function() return c.closed end)
  eq(c.output, expected .. frame(wire.error_response(query(2706), 2)),
    "EOF still returns one rate failure after accepted replies and ignores the remaining frames")
  eq(r:stats_snapshot().queries, 6)
  eq(r:stats_snapshot().queries_rate_limited, 1)
  eq(env.upstream_queries, 0)
  eq(r.pending, 0)
  r:close()
end

function tests.cache_hit_when_all_pending_slots_occupied()
  local env = mock({ respond = function() end })
  local cache = { get = function(_, q) if q.name == "cached.test." then return answer(q.raw) end end,
    put = function() end }
  local r = relay(env, { max_clients_per_ip = 32 }, cache)
  local clients = {}
  for n = 1, 32 do clients[n] = env.client(query(n)) end
  until_true(r, function() return r.pending == 32 end)
  clients[1].input = frame(query(400, "cached.test."))
  until_true(r, function() return #clients[1].output > 0 end)
  eq(clients[1].output, frame(answer(query(400, "cached.test."))))
  eq(r.pending, 32)
  r:close()
end

function tests.resource_recovery_probe_only_one_and_reset_requires_response()
  local env = mock({ connect_mode = function(_, n) return n == 1 and "resource" or "pending" end,
    respond = function() end })
  local r = relay(env, { max_clients_per_ip = 32 })
  local failed = env.client(query(1))
  until_true(r, function() return #failed.output > 0 end)
  env.time = r.resource_until + 0.1
  local clients = {}
  for n = 2, 8 do clients[#clients + 1] = env.client(query(n)) end
  until_true(r, function() return env.upstream_queries == 1 end)
  eq(#env.tcp_dials, 2)
  eq(r.resource_recovery, true)
  eq(r.endpoints[1].count, 1, "recovery probe is not pipelined")
  local ep = r.endpoints[1]
  local job
  for _, value in pairs(ep.inflight) do job = value end
  ep.socket.input = frame(answer(wire.with_id(job.query.raw, job.upstream_id)))
  steps(r, 1)
  eq(r.resource_recovery, false)
  eq(ep.probe, false)
  eq(ep.count, 4, "normal pipeline resumes only after valid DNS reply")
  r:close()
end

function tests.connection_tokens_even_normal_close()
  local env = mock({ respond = function(s, request) s.input = frame(answer(request)); s.eof = true end })
  local r = relay(env)
  local c = env.client()
  for n = 1, 8 do
    c.input = c.input .. frame(query(n))
    until_true(r, function() return #c.output > 0 end)
    c.output = ""
  end
  eq(#env.tcp_dials, 8)
  for n, time in ipairs(env.tcp_dials) do
    assert(n <= 2 + time, "dial token bucket rate exceeded")
  end
  r:close()
end

function tests.partial_query_deadline_not_extended_by_first_byte()
  local env = mock()
  local r = relay(env)
  local c = env.client()
  steps(r, 1)
  env.time = 2.5
  c.input = "\0"
  steps(r, 1)
  env.time = 3.1
  steps(r, 1)
  eq(c.closed, true)
  r:close()
end

function tests.real_wire_and_cache_modules()
  local real_wire, Cache = require("dns_wire"), require("cache")
  local env = mock({ respond = function(s, raw)
    local q = assert(real_wire.parse_query(raw))
    local response = string.sub(raw, 1, 2) .. "\129\128\0\1\0\1\0\0\0\0" .. q.question
      .. "\192\12\0\1\0\1\0\0\0\60\0\4\192\0\2\1"
    s.input = s.input .. real_wire.frame(response)
  end })
  local r = Relay.new({ listen_host = "198.18.32.42", allowed_clients = { "198.18.32.0/20" },
    upstreams = { { host = "198.18.32.30", port = 15353 } } },
    env.api, function() end, real_wire, Cache.new(256, 1048576))
  local q1 = "\0\100\1\0\0\1\0\0\0\0\0\0\3www\7example\3com\0\0\1\0\1"
  local c = env.client(q1)
  until_true(r, function() return #c.output > 0 end)
  local response1 = string.sub(c.output, 3)
  assert(real_wire.validate_response(response1, assert(real_wire.parse_query(q1))))
  c.output = ""
  local q2 = real_wire.with_id(q1, 101)
  c.input = real_wire.frame(q2)
  until_true(r, function() return #c.output > 0 end)
  local response2 = string.sub(c.output, 3)
  assert(real_wire.validate_response(response2, assert(real_wire.parse_query(q2))))
  eq(real_wire.with_id(response1, 101), response2)
  eq(env.upstream_queries, 1)
  eq(r:stats_snapshot().cache_hits, 1)
  eq(r:stats_snapshot().cache.entries, 1)
  r:close()
end

function tests.response_readiness_does_not_extend_deadline()
  local env = mock({ respond = function() end })
  local r = relay(env, { upstreams = { { host = "198.18.32.30", port = 15353 } } })
  env.client(query(91))
  until_true(r, function() return env.upstream_queries == 1 end)
  local ep, job = r.endpoints[1]
  for _, value in pairs(ep.inflight) do job = value end
  eq(job.state, "waiting")
  local old_socket = ep.socket
  old_socket.input = frame(answer(wire.with_id(job.query.raw, job.upstream_id)))
  env.time, env.select_advance = job.response_deadline - 0.5, 1
  steps(r, 1)
  eq(old_socket.closed, true)
  eq(ep.failures, 1)
  eq(r:stats_snapshot().upstream_responses, nil, "expired readable reply must not succeed")
  eq(r:stats_snapshot().servfail, 1)
  r:close()
end

function tests.healthy_secondary_continues_during_primary_resource_probe()
  local env = mock({ connect_mode = function(s, n)
    if n == 1 then return "refused" end
    return "pending"
  end, respond = function(s, raw)
    if s.host == "198.18.32.31" then s.input = s.input .. frame(answer(raw)) end
  end })
  local r = relay(env)
  local first = env.client(query(101))
  until_true(r, function() return #first.output > 0 end)
  eq(r.endpoints[2].state, "ready")
  eq(r.endpoints[2].probe, false)
  -- Existing secondary is healthy; a previous allocation failure requires a
  -- single primary new-connection probe before lifting the global guard.
  r.resource_recovery, r.resource_until = true, 0
  env.time = 2
  local probe = env.client(query(102))
  until_true(r, function() return r.endpoints[1].state == "ready" and r.endpoints[1].count == 1 end)
  local ordinary = env.client(query(103))
  until_true(r, function() return #ordinary.output > 0 end)
  eq(ordinary.output, frame(answer(query(103))))
  eq(#probe.output, 0, "primary probe still awaits its response")
  eq(r.resource_recovery, true, "secondary response cannot validate new-connection recovery")
  eq(#env.tcp_dials, 3, "reuse healthy secondary without another dial")
  r:close()
end

function tests.accept_resource_failure_waits_without_blocking_existing_clients()
  local env = mock()
  local cache = { get = function(_, q) if q.name == "cached.test." then return answer(q.raw) end end,
    put = function() end }
  local r = relay(env, nil, cache)
  local cached = env.client(query(10, "cached.test."))
  local local_client = env.client(query(11, "router01.is.example.test."))
  until_true(r, function() return #cached.output > 0 and #local_client.output > 0 end)
  cached.output, local_client.output = "", ""
  local queued = env.client(query(12))
  env.accept_error = "Too many open files"
  steps(r, 1)
  eq(#env.accept_failures, 1)
  cached.input = frame(query(13, "cached.test."))
  local_client.input = frame(query(14, "router01.is.example.test."))
  until_true(r, function() return #cached.output > 0 and #local_client.output > 0 end)
  eq(cached.output, frame(answer(query(13, "cached.test."))))
  eq(local_client.output, frame(answer(query(14, "router01.is.example.test."))))
  eq(#env.accept_failures, 1, "existing work must not bypass accept cooldown")
  eq(env.udp_count, 2)
  eq(env.upstream_queries, 0)
  for _, socket in ipairs(env.last_readers) do assert(socket ~= r.listener, "listener monitored during accept cooldown") end
  local before = env.time
  steps(r, 1)
  assert(env.time >= before + 1, "idle event loop must wait despite queued unaccepted connection")
  steps(r, 1)
  eq(#env.accept_failures, 2)
  steps(r, 6)
  eq(#env.accept_failures, 5)
  for index = 2, #env.accept_failures do
    assert(env.accept_failures[index] - env.accept_failures[index-1] >= 1)
  end
  eq(r:stats_snapshot().accept_failures, 5)
  env.accept_error = nil
  env.time = r.accept_retry_at + .01
  until_true(r, function() return #queued.output > 0 end)
  eq(queued.output, frame(answer(query(12))), "accept resumes after cooldown and resource recovery")
  r:close()
end

function tests.invalid_listener_fails_once_and_closes()
  for _, failure in ipairs({ "closed", "Bad file descriptor", "not a socket", "Socket operation on non-socket" }) do
    local env = mock()
    local r = relay(env)
    env.client(query(19))
    env.accept_error = failure
    local listener = r.listener
    local ok, err = r:step()
    eq(ok, nil)
    assert(string.find(err, "listener failed", 1, true))
    eq(r.stopped, true)
    eq(r.listener, nil)
    eq(listener.closed, true)
    eq(listener.close_count, 1)
    eq(#env.accept_failures, 1)
    eq(r:step(), false)
    r:close()
    eq(listener.close_count, 1)
  end
end

function tests.policy_cache_is_separate_and_uses_original_client_address()
  local a = { policy_id = "source_a", upstreams = { { host = "198.18.32.30", port = 15353 } } }
  local b = { policy_id = "source_b", upstreams = { { host = "198.18.32.31", port = 15353 } } }
  local seen = {}
  local policy = route_policy({ a, b }, function(_, address)
    seen[address] = true
    return address == "198.18.32.30" and a or b
  end)
  local env, cache = mock(), policy_cache()
  local r = relay(env, { dns_policy = policy }, cache)
  local ca = env.client(query(301), "198.18.32.30")
  local cb = env.client(query(302), "198.18.40.2")
  until_true(r, function() return #ca.output > 0 and #cb.output > 0 end)
  eq(env.upstream_queries, 2)
  assert(seen["198.18.32.30"] and seen["198.18.40.2"])
  local hosts = {}
  for _, request in ipairs(env.upstream_requests) do hosts[request.host] = true end
  assert(hosts["198.18.32.30"] and hosts["198.18.32.31"])
  assert(cache.entries["source_a:generation:1:example.test."] and cache.entries["source_b:generation:1:example.test."])
  ca.output, cb.output = "", ""
  ca.input, cb.input = frame(query(303)), frame(query(304))
  until_true(r, function() return #ca.output > 0 and #cb.output > 0 end)
  eq(ca.output, frame(answer(query(303))))
  eq(cb.output, frame(answer(query(304))))
  eq(env.upstream_queries, 2, "each source policy should hit only its own cache")
  eq(r:stats_snapshot().cache_hits, 2)
  r:close()
end

function tests.policy_is_frozen_on_job_and_cannot_change_cache_namespace()
  local selected = { policy_id = "original", upstreams = { { host = "198.18.32.30", port = 15353 } } }
  local policy = route_policy({ selected }, function() return selected end)
  local env, cache = mock({ respond = function() end }), policy_cache()
  local r = relay(env, { dns_policy = policy }, cache)
  local c = env.client(query(305))
  until_true(r, function() return env.upstream_queries == 1 end)
  selected.policy_id, selected.upstreams[1].host, r.cfg.policy_id = "changed", "198.18.32.99", "changed"
  local ep = r.endpoints[1]
  ep.socket.input = frame(answer(env.upstream_requests[1].raw))
  until_true(r, function() return #c.output > 0 end)
  eq(cache.inserts[1], "original:generation:1")
  eq(ep.host, "198.18.32.30")
  c.output, c.input = "", frame(query(306))
  until_true(r, function() return #c.output > 0 end)
  eq(env.upstream_queries, 1)
  eq(cache.lookups[#cache.lookups], "original:generation:1")
  r:close()
end

function tests.selected_rule_failure_never_uses_another_rule()
  local a = { policy_id = "selected", upstreams = { { host = "198.18.32.30", port = 15353 } } }
  local b = { policy_id = "other", upstreams = { { host = "198.18.32.31", port = 15353 } } }
  local policy = route_policy({ a, b }, function(_, address) return address == "198.18.32.30" and a or b end)
  local env = mock({ connect_mode = function(s) return s.host == "198.18.32.30" and "refused" or "pending" end })
  local r = relay(env, { dns_policy = policy })
  local failed = env.client(query(307))
  until_true(r, function() return #failed.output > 0 end)
  eq(string.sub(failed.output, 5, 6), "E2")
  eq(#env.tcp_dials, 1)
  eq(r.endpoints[2].socket, nil, "another rule is not a retry fallback")
  local other = env.client(query(308), "198.18.40.2")
  until_true(r, function() return #other.output > 0 end)
  eq(other.output, frame(answer(query(308))))
  eq(env.upstream_requests[1].host, "198.18.32.31")
  r:close()
end

function tests.policy_reject_and_unmatched_do_not_access_cache_or_upstream()
  local reject = { policy_id = "reject", reject = true, upstreams = {} }
  local policy = route_policy({ reject }, function(q)
    if q.name == "rejected.test." then return reject end
    if q.name == "unknown.test." then return { policy_id = "unregistered", upstreams = {} } end
    return nil, "no matching rule"
  end)
  local cache, env = policy_cache(), mock()
  local r = relay(env, { dns_policy = policy }, cache)
  local blocked = env.client(query(309, "rejected.test."))
  local unmatched = env.client(query(310, "unmatched.test."))
  local unknown = env.client(query(311, "unknown.test."))
  local local_client = env.client(query(312, "router01.is.example.test."))
  until_true(r, function() return #unmatched.output > 0 and #unknown.output > 0 and #local_client.output > 0 end)
  eq(#blocked.output, 0, "reject means drop, not SERVFAIL")
  eq(string.sub(unmatched.output, 5, 6), "E2")
  eq(string.sub(unknown.output, 5, 6), "E2")
  eq(local_client.output, frame(answer(query(312, "router01.is.example.test."))))
  eq(#cache.lookups, 0)
  eq(#env.tcp_dials, 0)
  eq(r:stats_snapshot().policy_rejects, 1)
  eq(r:stats_snapshot().policy_unmatched, 2)
  eq(env.udp_count, 1, "local zones retain precedence over external policies")
  r:close()
end

function tests.shared_peer_pipeline_and_edns_descriptors_span_policies()
  local a = { policy_id = "off", upstreams = { { host = "198.18.32.30", port = 15353, edns = false } } }
  local b = { policy_id = "on", upstreams = { { host = "198.18.32.30", port = 15353, edns = true } } }
  local policy = route_policy({ a, b }, function(_, address) return address == "198.18.32.30" and a or b end)
  local transformed, returned, implementation = {}, {}, {}
  for key, value in pairs(wire) do implementation[key] = value end
  implementation.upstream_query = function(q, server)
    transformed[q.id] = server.edns
    eq(q.cache_allow_no_opt, true)
    return q.raw
  end
  implementation.downstream_response = function(raw, q, server) returned[q.id] = server.edns; return raw end
  local env = mock({ respond = function(s, raw, state)
    if state.upstream_queries > 4 then s.input = s.input .. frame(answer(raw)) end
  end })
  local r = relay(env, { dns_policy = policy }, nil, implementation)
  local clients = {}
  for n = 1, 6 do clients[n] = env.client(query(320+n, "shared" .. n .. ".test."), n % 2 == 1 and "198.18.32.30" or "198.18.40.2") end
  until_true(r, function() return env.upstream_queries == 4 end)
  eq(#r.endpoints, 1)
  eq(r.endpoints[1].count, 4)
  eq(#r.queue, 2)
  eq(#env.tcp_dials, 1)
  local responses = ""
  for n = 4, 1, -1 do responses = responses .. frame(answer(env.upstream_requests[n].raw)) end
  r.endpoints[1].socket.input = responses
  until_true(r, function()
    for _, client in ipairs(clients) do if #client.output == 0 then return false end end
    return true
  end)
  for n, client in ipairs(clients) do
    eq(client.output, frame(answer(query(320+n, "shared" .. n .. ".test."))))
    eq(transformed[320+n], n % 2 == 0)
    eq(returned[320+n], n % 2 == 0)
  end
  eq(env.upstream_queries, 6)
  eq(#env.tcp_dials, 1)
  r:close()
end

function tests.policy_connection_cap_queues_busy_and_evicts_only_idle()
  local routes = {}
  for n = 1, 5 do routes[n] = { policy_id = "route" .. n,
    upstreams = { { host = "198.18.32." .. (29+n), port = 15353 } } } end
  local policy = route_policy(routes, function(q) return routes[tonumber(string.match(q.name, "^route(%d)"))] end)
  local env = mock({ respond = function() end })
  local r = relay(env, { dns_policy = policy, response_timeout = 20, total_timeout = 30,
    max_clients_per_ip = 32 })
  for n = 1, 5 do env.client(query(330+n, "route" .. n .. ".test.")) end
  until_true(r, function() return env.upstream_queries == 4 end)
  eq(r.cfg.max_upstream_connections, 4)
  eq(r:_connection_count(), 4)
  eq(#r.queue, 1)
  local busy_sockets, finished, waiting_endpoint = {}
  for _, ep in ipairs(r.endpoints) do
    if ep.socket then
      busy_sockets[#busy_sockets + 1] = ep.socket
      if not finished then finished = ep end
    else waiting_endpoint = ep end
  end
  assert(waiting_endpoint)
  local request
  for _, item in ipairs(env.upstream_requests) do if item.host == finished.host then request = item.raw end end
  finished.socket.input = frame(answer(request))
  until_true(r, function() return env.upstream_queries == 5 end)
  eq(busy_sockets[1].closed, true, "only the completed idle connection is evicted")
  for n = 2, 4 do eq(busy_sockets[n].closed, nil, "busy upstream must survive pool pressure") end
  eq(r:_connection_count(), 4)
  eq(r:stats_snapshot().peak_upstream_connections, 4)
  eq(r:stats_snapshot().upstream_pool_evictions, 1)
  for n, time in ipairs(env.tcp_dials) do assert(n <= 2 + time, "dial limit must remain global") end
  r:close()
end

function tests.policy_idle_pool_replacement_is_lru()
  local routes = {}
  for n = 1, 3 do routes[n] = { policy_id = "route" .. n,
    upstreams = { { host = "198.18.32." .. (29+n), port = 15353 } } } end
  local policy = route_policy(routes, function(q) return routes[tonumber(string.match(q.name, "^route(%d)"))] end)
  local env = mock()
  local r = relay(env, { dns_policy = policy, max_upstream_connections = 2 })
  for _, n in ipairs({ 1, 2, 1 }) do
    local c = env.client(query(340+n, "route" .. n .. ".test."))
    until_true(r, function() return #c.output > 0 end)
  end
  local newest, oldest = r.endpoints[1].socket, r.endpoints[2].socket
  local c = env.client(query(343, "route3.test."))
  until_true(r, function() return #c.output > 0 end)
  eq(newest.closed, nil)
  eq(oldest.closed, true, "least recently used idle peer should be evicted")
  eq(r:_connection_count(), 2)
  r:close()
end

function tests.resource_freeze_is_shared_across_policy_groups()
  local routes = {}
  for n = 1, 3 do routes[n] = { policy_id = "route" .. n,
    upstreams = { { host = "198.18.32." .. (29+n), port = 15353 } } } end
  local policy = route_policy(routes, function(q) return routes[tonumber(string.match(q.name, "^route(%d)"))] end)
  local env = mock({ connect_mode = function(s) return s.host == "198.18.32.30" and "resource" or "pending" end })
  local r = relay(env, { dns_policy = policy })
  local healthy = env.client(query(353, "route3.test."))
  until_true(r, function() return #healthy.output > 0 end)
  local failed = env.client(query(351, "route1.test."))
  until_true(r, function() return #failed.output > 0 end)
  eq(r.resource_recovery, true)
  local other = env.client(query(352, "route2.test."))
  healthy.output, healthy.input = "", frame(query(354, "route3.test."))
  until_true(r, function() return #other.output > 0 and #healthy.output > 0 end)
  eq(string.sub(other.output, 5, 6), "E2")
  eq(healthy.output, frame(answer(query(354, "route3.test."))))
  eq(#env.tcp_dials, 2, "another policy must not bypass global resource freeze")
  eq(r.resource_recovery, true, "existing shared connections cannot complete a new-connection probe")
  r:close()
end

function tests.four_server_route_still_allows_only_two_attempts()
  local route = { policy_id = "fallback", upstreams = {} }
  for n = 1, 4 do route.upstreams[n] = { host = "198.18.32." .. (29+n), port = 15353 } end
  local policy = route_policy({ route }, function() return route end)
  local env = mock({ connect_mode = function() return "refused" end })
  local r = relay(env, { dns_policy = policy })
  local c = env.client(query(360))
  until_true(r, function() return #c.output > 0 end)
  eq(string.sub(c.output, 5, 6), "E2")
  eq(#env.tcp_dials, 2)
  eq(r.endpoints[3].socket, nil)
  eq(r.endpoints[4].socket, nil)
  r:close()
end

function tests.policy_limits_and_unregistered_routes_fail_closed()
  local routes = {}
  for n = 1, 17 do routes[n] = { policy_id = "route" .. n, upstreams = { { host = "198.18.32." .. n } } } end
  local env = mock()
  local ok, err = pcall(relay, env, { dns_policy = route_policy(routes, function() return routes[1] end) })
  eq(ok, false)
  assert(string.find(err, "16 distinct", 1, true))
  eq(env.tcp_created, 0, "validate endpoint limits before opening the listener")
end

function tests.actual_policy_wire_and_cache_preserve_route_and_edns_behavior()
  local Policy, real_wire, Cache = require("dns_policy"), require("dns_wire"), require("cache")
  local policy = assert(Policy.parse("dns server select 10 198.18.32.30 edns=off any _aaplcache._tcp.example.test\n"
    .. "dns server select 9999 198.18.32.31 edns=on any . 198.18.32.1-198.18.32.254\n"
    .. "dns server select 500201 198.18.32.32 edns=off any .\n"))
  local opt = "\0\0\41\4\208\0\0\0\0\0\0"
  local function make_query(name, value, edns)
    return u16(value) .. "\1\0\0\1\0\0\0\0" .. (edns and "\0\1" or "\0\0")
      .. canonical_name(name) .. "\0\1\0\1" .. (edns and opt or "")
  end
  local upstream_opts = {}
  local env = mock({ respond = function(s, raw)
    local q = assert(real_wire.parse_query(raw))
    upstream_opts[s.host] = q.opt ~= nil
    local response = string.sub(raw, 1, 2) .. "\129\128\0\1\0\1\0\0" .. (q.opt and "\0\1" or "\0\0")
      .. q.question .. "\192\12\0\1\0\1\0\0\0\60\0\4\192\0\2" .. string.char(tonumber(string.match(s.host, "(%d+)$")))
      .. (q.opt and opt or "")
    s.input = s.input .. real_wire.frame(response)
  end })
  local cache = Cache.new(256, 1048576)
  local r = relay(env, { dns_policy = policy }, cache, real_wire)
  local q1, q2 = make_query("www.example.com", 701, false), make_query("www.example.com", 702, true)
  local q3 = make_query("_aaplcache._tcp.example.test", 703, true)
  local a, b, c = env.client(q1, "198.18.32.30"), env.client(q2, "198.18.40.2"), env.client(q3, "198.18.40.2")
  until_true(r, function() return #a.output > 0 and #b.output > 0 and #c.output > 0 end)
  for _, item in ipairs({ {a, q1}, {b, q2}, {c, q3} }) do
    local parsed = assert(real_wire.validate_response(string.sub(item[1].output, 3), assert(real_wire.parse_query(item[2]))))
    eq(parsed.rcode, 0)
    eq(parsed.opt, nil, "EDNS introduced on the upstream hop is removed for the legacy client")
  end
  eq(upstream_opts["198.18.32.30"], false)
  eq(upstream_opts["198.18.32.31"], true)
  eq(upstream_opts["198.18.32.32"], false)
  eq(env.upstream_queries, 3)
  eq(cache:stats().entries, 3)
  b.output, b.input = "", real_wire.frame(real_wire.with_id(q2, 704))
  until_true(r, function() return #b.output > 0 end)
  assert(real_wire.validate_response(string.sub(b.output, 3), assert(real_wire.parse_query(real_wire.with_id(q2, 704)))))
  eq(env.upstream_queries, 3, "explicit EDNS-off response should remain cacheable for this policy")
  eq(r:stats_snapshot().cache_hits, 1)
  r:close()
end

function tests.policy_response_transform_failure_is_final_servfail()
  local route = { policy_id = "edns", upstreams = { { host = "198.18.32.30", port = 15353, edns = true } } }
  local policy = route_policy({ route }, function() return route end)
  local implementation = {}
  for key, value in pairs(wire) do implementation[key] = value end
  implementation.downstream_response = function() return nil, "unrepresentable EDNS response" end
  local env, cache = mock(), policy_cache()
  local r = relay(env, { dns_policy = policy }, cache, implementation)
  local c = env.client(query(705))
  until_true(r, function() return #c.output > 0 end)
  eq(string.sub(c.output, 5, 6), "E2")
  eq(env.upstream_queries, 1)
  eq(r.endpoints[1].failures, 0, "valid upstream communication is not a transport fault")
  eq(#cache.inserts, 0)
  eq(r:stats_snapshot().failure_response_transform, 1)
  r:close()
end

function tests.actual_aaaa_filter_preserves_source_policy_and_native_delegation()
  local Policy, real_wire, Cache = require("dns_policy"), require("dns_wire"), require("cache")
  local policy = assert(Policy.parse("dns server select 10 198.18.32.30 any . 198.18.32.1-198.18.32.254\n"
    .. "dns server select 20 198.18.32.31 any .\n"))
  policy.aaaa_filter = true
  local function make_query(value, kind, name)
    return u16(value) .. "\1\0\0\1\0\0\0\0\0\0"
      .. canonical_name(name or "external.example.test") .. u16(kind) .. "\0\1"
  end
  local env = mock({respond = function(s, raw)
    local q = assert(real_wire.parse_query(raw))
    local header = raw:sub(1, 2) .. "\129\128\0\1"
    local records
    if q.qtype == 28 then
      local target = canonical_name("target.example.test")
      header = raw:sub(1, 2) .. "\129\160\0\1\0\2\0\0\0\0"
      records = "\192\12\0\5\0\1\0\0\0\60" .. u16(#target) .. target
        .. target .. "\0\28\0\1\0\0\0\60\0\16" .. string.rep("\0", 15) .. "\1"
    else
      header = header .. "\0\1\0\0\0\0"
      records = "\192\12\0\1\0\1\0\0\0\60\0\4\192\0\2\37"
    end
    s.input = s.input .. frame(header .. q.question .. records)
  end})
  local native_response, create_udp = nil, env.api.udp
  env.api.udp = function()
    local socket = create_udp()
    function socket:sendto(raw, host, port)
      local q = assert(real_wire.parse_query(raw))
      native_response = raw:sub(1, 2) .. "\129\131\0\1\0\0\0\1\0\0" .. q.question
        .. "\192\12\0\6\0\1\0\0\0\60\0\24\192\12\192\12" .. string.rep("\0", 20)
      self.udp_response, self.remote_host, self.remote_port = native_response, host, port
      env.udp_count = env.udp_count + 1
      return #raw
    end
    return socket
  end
  local filter_calls, implementation = 0, {}
  for key, value in pairs(real_wire) do implementation[key] = value end
  implementation.filter_aaaa = function(raw)
    filter_calls = filter_calls + 1
    return real_wire.filter_aaaa(raw)
  end
  local cache, puts = Cache.new(256, 1048576), 0
  local original_put = cache.put
  cache.put = function(self, ...)
    puts = puts + 1
    return original_put(self, ...)
  end
  local r = relay(env, {dns_policy = policy, local_zones = {}, local_names = {"local.example.test"}}, cache, implementation)
  for _, item in ipairs({{731, "198.18.32.30", "198.18.32.30"}, {732, "198.18.40.2", "198.18.32.31"},
    {733, "198.18.32.30", "198.18.32.30"}}) do
    local raw = make_query(item[1], 28)
    local c = env.client(raw, item[2])
    until_true(r, function() return #c.output > 0 end)
    local parsed = assert(real_wire.validate_response(c.output:sub(3), assert(real_wire.parse_query(raw))))
    eq(parsed.ancount, 1, "CNAME is retained while AAAA is filtered")
    eq(parsed.records[1].rtype, 5)
    eq(parsed.ad, false)
    eq(env.upstream_requests[#env.upstream_requests].host, item[3], "original client source selects the DNS server")
  end
  eq(env.upstream_queries, 3, "modified AAAA response is never a cache hit")
  eq(filter_calls, 3)
  eq(puts, 0, "modified replies bypass cache insertion, not only cache eligibility")
  eq(cache:stats().entries, 0)
  local raw = make_query(734, 1)
  local a = env.client(raw, "198.18.40.2")
  until_true(r, function() return #a.output > 0 end)
  eq(puts, 1)
  eq(cache:stats().entries, 1, "unmodified A replies remain cacheable")
  a.output, a.input = "", frame(make_query(735, 1))
  until_true(r, function() return #a.output > 0 end)
  eq(env.upstream_queries, 4, "A reply uses its existing policy cache")
  eq(filter_calls, 3, "filter applies only to AAAA")
  local local_raw = make_query(736, 28, "local.example.test")
  local c = env.client(local_raw, "198.18.40.2")
  until_true(r, function() return #c.output > 0 end)
  eq(c.output, frame(native_response), "native NXDOMAIN/SOA reply is passed through byte for byte")
  eq(env.udp_count, 1)
  eq(filter_calls, 3, "native DNS performs its own AAAA filtering")
  eq(puts, 1, "local native response bypasses cache")
  eq(env.upstream_queries, 4, "native delegation does not create an external TCP request")
  r:close()
end

function tests.actual_aaaa_filter_failure_is_query_local_and_does_not_retry_another_server()
  local real_wire = require("dns_wire")
  local route = {policy_id = "filtered", upstreams = {{host = "198.18.32.30", port = 15353},
    {host = "198.18.32.31", port = 15353}}}
  local policy = route_policy({route}, function() return route end)
  policy.aaaa_filter = true
  local env = mock({respond = function(s, raw)
    local q = assert(real_wire.parse_query(raw))
    local aaaa = "\192\12\0\28\0\1\0\0\0\60\0\16" .. string.rep("\0", 16)
    local unknown = "\192\12\255\0\0\1\0\0\0\60\0\2\192\12"
    s.input = s.input .. frame(raw:sub(1, 2) .. "\129\128\0\1\0\2\0\0\0\0" .. q.question .. aaaa .. unknown)
  end})
  local r = relay(env, {dns_policy = policy}, nil, real_wire)
  local raw = u16(737) .. "\1\0\0\1\0\0\0\0\0\0" .. canonical_name("external.example.test") .. "\0\28\0\1"
  local c = env.client(raw)
  until_true(r, function() return #c.output > 0 end)
  eq(assert(real_wire.validate_response(c.output:sub(3), assert(real_wire.parse_query(raw)))).rcode, 2)
  eq(env.upstream_queries, 1)
  eq(#env.tcp_dials, 1, "unsupported rewrite must not become upstream failover")
  eq(r.endpoints[1].failures, 0, "valid DNS transport remains healthy")
  eq(r.endpoints[2].socket, nil)
  eq(r:stats_snapshot().failure_response_transform, 1)
  r:close()
end

function tests.retry_uses_secondary_when_token_wait_outlasts_primary_backoff()
  local primary_closes = false
  local env = mock({ respond = function(s, raw)
    if primary_closes and s.host == "198.18.32.30" then s.eof = true
    else s.input = s.input .. frame(answer(raw)) end
  end })
  local route = { policy_id = "selected", upstreams = {
    { host = "198.18.32.30", port = 15353 }, { host = "198.18.32.31", port = 15353 } } }
  local policy = route_policy({ route }, function() return route end)
  local r = relay(env, { dns_policy = policy })
  local c = env.client(query(801))
  until_true(r, function() return #c.output > 0 end)
  primary_closes = true
  r.tokens, r.token_time = 0, r.now
  c.output, c.input = "", frame(query(802))
  until_true(r, function() return #c.output > 0 end)
  eq(c.output, frame(answer(query(802))))
  eq(env.upstream_queries, 3, "warmup plus one primary attempt plus one secondary retry")
  eq(env.upstream_requests[2].host, "198.18.32.30")
  eq(env.upstream_requests[3].host, "198.18.32.31")
  eq(#env.tcp_dials, 2, "failed primary is not reopened when its backoff expires with the token")
  eq(r:stats_snapshot().retries, 1)
  r:close()
end

function tests.automatic_local_names_match_exactly_and_keep_other_queries_upstream()
  local env = mock()
  local r = relay(env, {local_zones = {}, local_names = {"Router.Home.Arpa.", "1.2.0.192.in-addr.arpa"}})
  local exact = env.client(query(901, "ROUTER.HOME.ARPA."))
  local child = env.client(query(902, "child.router.home.arpa."))
  local sibling = env.client(query(903, "other.home.arpa."))
  local reverse = env.client(query(904, "1.2.0.192.in-addr.arpa."))
  until_true(r, function() return #exact.output > 0 and #child.output > 0
    and #sibling.output > 0 and #reverse.output > 0 end)
  eq(env.udp_count, 2, "only registered owners and reverse names use the native DNS")
  eq(env.upstream_queries, 2, "children and siblings still use selected upstreams")
  assert(not r:_local({canonical_name = "\16router.home.arpa\0"}), "literal dot label cannot spoof a registered name")
  r:close()
end

function tests.dns_host_ranges_compare_octets_and_include_both_boundaries()
  local env = mock()
  local r = relay(env, {allowed_clients = {"198.18.1.250-198.18.2.10"}})
  for _, address in ipairs({"198.18.1.250", "198.18.1.255", "198.18.2.0", "198.18.2.10"}) do
    assert(r:_allowed(address), "range must allow " .. address)
  end
  for _, address in ipairs({"198.18.1.249", "198.18.2.11", "198.18.0.255", "invalid"}) do
    assert(not r:_allowed(address), "range must reject " .. address)
  end
  local denied = env.client(query(905), "198.18.2.11")
  local allowed = env.client(query(906), "198.18.2.10")
  until_true(r, function() return denied.closed and #allowed.output > 0 end)
  eq(env.upstream_queries, 1, "rejected client cannot create an upstream query")
  r:close()
end

function tests.per_ip_limits_reject_invalid_configuration_before_listen()
  for _, entry in ipairs({
    { "max_clients_per_ip", 0 }, { "max_clients_per_ip", 33 }, { "max_clients_per_ip", 1.5 },
    { "query_rate_per_ip", 0 }, { "query_rate_per_ip", 1001 }, { "query_rate_per_ip", "20" },
    { "query_burst_per_ip", 0 }, { "query_burst_per_ip", 1001 }, { "query_burst_per_ip", 1.5 },
    { "max_client_ips", 0 }, { "max_client_ips", 4097 }, { "max_client_ips", 1.5 },
    { "max_client_ips", 31 }
  }) do
    local env = mock()
    local config = {}; config[entry[1]] = entry[2]
    eq(pcall(relay, env, config), false, "invalid " .. entry[1] .. " rejected")
    eq(env.tcp_created, 0, "invalid limiter configuration opens no socket")
  end
end

function tests.default_per_ip_connection_limit_preserves_other_sources()
  local env = mock(); env.select_advance = 0
  local r, clients = relay(env), {}
  for n = 1, 5 do clients[n] = env.client(query(1000 + n)) end
  local other = env.client(query(1006), "198.18.32.31")
  until_true(r, function() return clients[5].closed and #other.output > 0 end)
  for n = 1, 4 do
    until_true(r, function() return #clients[n].output > 0 end)
    eq(clients[n].output, frame(answer(query(1000 + n))))
  end
  eq(clients[5].output, "", "excess TCP connection is rejected before query parsing")
  eq(other.output, frame(answer(query(1006))))
  eq(r.client_count, 5, "four connections for first IP and one for second")
  clients[1].eof = true
  until_true(r, function() return clients[1].closed end)
  local replacement = env.client(query(1007))
  until_true(r, function() return #replacement.output > 0 end)
  eq(replacement.output, frame(answer(query(1007))), "closed connection returns its IP slot")
  r:close()
end

function tests.default_query_bucket_allows_40_then_refills_20_per_second()
  local env = mock(); env.select_advance = 0
  local r = relay(env)
  local c = env.client()
  for n = 1, 40 do
    c.input = frame(query(1100 + n))
    until_true(r, function() return #c.output > 0 end)
    eq(c.output, frame(answer(query(1100 + n))))
    c.output = ""
  end
  c.input = frame(query(1141)) .. frame(query(1142))
  until_true(r, function() return c.closed end)
  eq(c.output, frame(wire.error_response(query(1141), 2)), "one SERVFAIL, buffered follow-up ignored")
  eq(env.upstream_queries, 40)
  local early = env.client(query(1143))
  until_true(r, function() return early.closed end)
  eq(early.output, "", "reconnect cannot reset exhausted IP bucket")
  env.time = 1
  local recovered = env.client()
  for n = 1, 20 do
    recovered.input = frame(query(1200 + n))
    until_true(r, function() return #recovered.output > 0 end)
    eq(recovered.output, frame(answer(query(1200 + n))))
    recovered.output = ""
  end
  recovered.input = frame(query(1221))
  until_true(r, function() return recovered.closed end)
  eq(recovered.output, frame(wire.error_response(query(1221), 2)))
  eq(env.upstream_queries, 60, "one second restores exactly twenty queries")
  r:close()
end

function tests.query_bucket_is_shared_across_connections_but_not_addresses()
  local env = mock(); env.select_advance = 0
  local r = relay(env, { query_rate_per_ip = 1, query_burst_per_ip = 3 })
  local clients = {}
  for n = 1, 3 do clients[n] = env.client() end
  steps(r, 1)
  for n, c in ipairs(clients) do
    c.input = frame(query(1300 + n))
    until_true(r, function() return #c.output > 0 end)
    eq(c.output, frame(answer(query(1300 + n))))
    c.output = ""
  end
  clients[1].input = frame(query(1304))
  until_true(r, function() return clients[1].closed end)
  eq(clients[1].output, frame(wire.error_response(query(1304), 2)))
  clients[2].input = frame(query(1305))
  until_true(r, function() return clients[2].closed end)
  eq(clients[2].output, frame(wire.error_response(query(1305), 2)))
  local other = env.client(query(1306), "198.18.32.31")
  until_true(r, function() return #other.output > 0 end)
  eq(other.output, frame(answer(query(1306))), "another IP keeps an independent bucket")
  eq(env.upstream_queries, 4)
  r:close()
end

function tests.query_limit_counts_malformed_cached_and_local_requests()
  for _, kind in ipairs({ "malformed", "cached", "local" }) do
    local env = mock(); env.select_advance = 0
    local lookups = 0
    local cache = { get = function(_, q) lookups = lookups + 1; return answer(q.raw) end }
    local r = relay(env, { query_rate_per_ip = 1, query_burst_per_ip = 1 }, kind == "cached" and cache or nil)
    local first = kind == "malformed" and u16(1401) .. "Xinvalid.test."
      or query(1401, kind == "local" and "router01.is.example.test." or "cached.test.")
    local c = env.client(first)
    until_true(r, function() return #c.output > 0 end)
    eq(c.output, frame(kind == "malformed" and wire.error_response(first, 1) or answer(first)))
    c.output, c.input = "", frame(query(1402))
    until_true(r, function() return c.closed end)
    eq(c.output, frame(wire.error_response(query(1402), 2)), kind .. " consumed the IP token")
    eq(env.upstream_queries, 0, "rate rejection creates no upstream work")
    eq(lookups, kind == "cached" and 1 or 0, "rate rejection bypasses cache lookup")
    eq(env.udp_count, kind == "local" and 1 or 0, "rate rejection creates no native DNS work")
    r:close()
  end
end

function tests.rate_rejection_drains_existing_jobs_and_output_before_close()
  local held
  local env = mock({ send_chunk = 5, respond = function(socket, request)
    held = { socket = socket, request = request }
  end }); env.select_advance = 0
  local r = relay(env, { query_rate_per_ip = 1, query_burst_per_ip = 1 })
  local c = env.client(query(1501))
  c.input = c.input .. frame(query(1502)) .. frame(query(1503))
  until_true(r, function() return held and #c.output == #frame(wire.error_response(query(1502), 2)) end)
  eq(c.closed, nil, "pending accepted job survives rate rejection")
  eq(env.upstream_queries, 1, "buffered query after rate failure is ignored")
  c.input = frame(query(1504))
  held.socket.input = frame(answer(held.request))
  until_true(r, function() return c.closed end)
  eq(c.output, frame(wire.error_response(query(1502), 2)) .. frame(answer(query(1501))),
    "one SERVFAIL and original pending answer are both delivered with partial writes")
  eq(env.upstream_queries, 1, "new input after rejection is not processed")
  r:close()
end

function tests.rate_rejection_output_deadline_still_closes_stalled_client()
  local env = mock({ send_chunk = 1 }); env.select_advance = 0
  local cache = { get = function(_, q) return answer(q.raw) end }
  local r = relay(env, { query_rate_per_ip = 1, query_burst_per_ip = 1 }, cache)
  local c = env.client(query(1601))
  c.input = c.input .. frame(query(1602))
  until_true(r, function() return #c.output > 0 end)
  eq(c.closed, nil)
  env.time = 2
  steps(r, 1)
  eq(c.closed, true, "rate-limit drain retains hard output deadline")
  eq(env.upstream_queries, 0)
  r:close()
end

function tests.tracked_ip_capacity_cannot_reset_recently_exhausted_buckets()
  local env = mock(); env.select_advance = 0
  local r = relay(env, { max_clients = 2, max_client_ips = 2, query_rate_per_ip = 1, query_burst_per_ip = 1 })
  for n = 1, 2 do
    local c = env.client(query(1700 + n), "198.18.32." .. (40 + n)); c.eof = true
    until_true(r, function() return c.closed end)
    eq(c.output, frame(answer(query(1700 + n))))
  end
  local excess = env.client(query(1703), "198.18.32.43")
  until_true(r, function() return excess.closed end)
  eq(excess.output, "", "full unrecovered tracking table rejects a new IP")
  local retry = env.client(query(1704), "198.18.32.41")
  until_true(r, function() return retry.closed end)
  eq(retry.output, "", "denied new IP did not erase an exhausted source")
  eq(env.upstream_queries, 2)
  env.time = 1
  local fresh = env.client(query(1705), "198.18.32.43")
  until_true(r, function() return #fresh.output > 0 end)
  eq(fresh.output, frame(answer(query(1705))), "recovered disconnected source can be reclaimed")
  r:close()
end

function tests.tracked_ip_reclamation_keeps_active_connection_state()
  local env = mock(); env.select_advance = 0
  local r = relay(env, { max_clients = 2, max_client_ips = 2, query_rate_per_ip = 1, query_burst_per_ip = 1 })
  local active = env.client(query(1801), "198.18.32.41")
  local closed = env.client(query(1802), "198.18.32.42"); closed.eof = true
  until_true(r, function() return #active.output > 0 and closed.closed end)
  env.time = 1
  local newcomer = env.client(query(1803), "198.18.32.43")
  until_true(r, function() return #newcomer.output > 0 end)
  eq(newcomer.output, frame(answer(query(1803))))
  active.output, active.input = "", frame(query(1804))
  until_true(r, function() return #active.output > 0 end)
  eq(active.output, frame(answer(query(1804))), "live source survives tracking-table reclamation")
  eq(r.client_count, 2)
  r:close()
end

function tests.query_bucket_handles_rate_above_burst_and_large_clock_jump()
  local env = mock(); env.select_advance = 0
  local r = relay(env, { query_rate_per_ip = 1000, query_burst_per_ip = 1 })
  local c = env.client(query(1901))
  until_true(r, function() return #c.output > 0 end)
  c.output, c.input = "", frame(query(1902))
  until_true(r, function() return c.closed end)
  eq(c.output, frame(wire.error_response(query(1902), 2)), "integer division must not refill at zero elapsed time")
  env.time = 1000000000
  local recovered = env.client(query(1903))
  until_true(r, function() return #recovered.output > 0 end)
  eq(recovered.output, frame(answer(query(1903))), "large elapsed time refills without multiplication overflow")
  recovered.output, recovered.input = "", frame(query(1904))
  until_true(r, function() return recovered.closed end)
  eq(recovered.output, frame(wire.error_response(query(1904), 2)), "refill never exceeds burst capacity")
  r:close()
end

function tests.runtime_refresh_discards_old_jobs_connections_and_cache()
  local route = {policy_id = "dynamic", upstreams = {{host = "198.18.32.30", port = 15353}}}
  local policy = route_policy({route}, function() return route end)
  local env, cache = mock({respond = function() end}), policy_cache()
  local refreshes = 0
  local r = relay(env, {dns_policy = policy, client_read_timeout = 100,
    total_timeout = 100, response_timeout = 100,
    policy_refresh = function()
      refreshes = refreshes + 1
      if refreshes == 1 then return false end
      route.upstreams = {{host = "198.18.32.31", port = 15353}}
      return true
    end}, cache)
  local client = env.client(query(2001))
  until_true(r, function() return env.upstream_queries == 1 end)
  local old = r.endpoints[1].socket
  env.time = 30; r.now = r:_clock(); r:_timers()
  eq(refreshes, 1); eq(r.generation, 1); eq(old.closed, nil)
  env.time = 60; r.now = r:_clock(); r:_timers()
  eq(refreshes, 2); eq(r.generation, 2); eq(old.closed, true)
  eq(r.pending, 0); eq(cache.clears, 1); eq(#cache.inserts, 0)
  eq(r.endpoints[1].host, "198.18.32.31")
  r:_client_write(r.clients[client])
  eq(client.output, frame(wire.error_response(query(2001), 2)))
  client.output, client.input = "", frame(query(2002))
  until_true(r, function() return env.upstream_queries == 2 end)
  eq(env.upstream_requests[2].host, "198.18.32.31")
  local fresh = r.endpoints[1].socket
  fresh.input = frame(answer(env.upstream_requests[2].raw))
  until_true(r, function() return #client.output > 0 end)
  eq(cache.inserts[1], "dynamic:generation:2")
  r:close()
end

function tests.runtime_refresh_ignores_old_socket_readiness_returned_by_select()
  local route = {policy_id = "dynamic", upstreams = {{host = "198.18.32.30", port = 15353}}}
  local policy = route_policy({route}, function() return route end)
  local env, cache = mock({respond = function() end}), policy_cache()
  local refreshed = false
  local r = relay(env, {dns_policy = policy, client_read_timeout = 100,
    total_timeout = 100, response_timeout = 100,
    policy_refresh = function()
      if refreshed then return false end
      refreshed = true
      route.upstreams = {{host = "198.18.32.31", port = 15353}}
      return true
    end}, cache)
  local client = env.client(query(2005))
  until_true(r, function() return env.upstream_queries == 1 end)
  local old = r.endpoints[1].socket
  old.input = frame(answer(env.upstream_requests[1].raw))
  -- select returns readiness for the old endpoint while crossing the refresh
  -- deadline. The post-select timers replace the policy before dispatch.
  env.select_advance = 30 - env.time
  steps(r, 1)
  env.select_advance = 0
  eq(old.closed, true)
  eq(r.generation, 2)
  eq(r:stats_snapshot().upstream_responses, nil, "old readiness cannot complete a response")
  eq(#cache.inserts, 0, "old response cannot enter the refreshed cache")
  until_true(r, function() return #client.output > 0 end)
  eq(client.output, frame(wire.error_response(query(2005), 2)))
  eq(r.endpoints[1].host, "198.18.32.31")
  r:close()
end

function tests.unavailable_route_servfails_without_dial_and_refresh_recovers()
  local route = {policy_id = "dynamic", upstreams = {}, unavailable = true}
  local policy = route_policy({route}, function() return route end)
  local env = mock()
  local r = relay(env, {dns_policy = policy, policy_refresh = function()
    route.upstreams, route.unavailable = {{host = "198.18.32.30", port = 15353}}, nil
    return true
  end})
  local client = env.client(query(2010))
  until_true(r, function() return #client.output > 0 end)
  eq(client.output, frame(wire.error_response(query(2010), 2)))
  eq(#env.tcp_dials, 0)
  env.time = 30; r.now = r:_clock(); r:_timers()
  local recovered = env.client(query(2011))
  until_true(r, function() return #recovered.output > 0 end)
  eq(recovered.output, frame(answer(query(2011))))
  eq(#env.tcp_dials, 1)
  r:close()
end

function tests.required_apis_and_initialization_failures_are_bounded()
  for _, name in ipairs({"tcp", "select", "gettime", "udp"}) do
    local env = mock(); env.api[name] = nil
    local ok, err = pcall(relay, env)
    eq(ok, false); assert(tostring(err):find("socket." .. name, 1, true))
    eq(env.tcp_created, 0, "API absence fails before creating listener")
  end
  for _, mode in ipairs({"throw", "bad-time", "bind", "listen", "missing-method"}) do
    local env = mock()
    local original = env.api.tcp
    env.api.tcp = function()
      if mode == "throw" then error("private-factory-details") end
      local socket = original()
      if mode == "bind" or mode == "listen" then socket[mode] = function() error("operation failed") end end
      if mode == "missing-method" then socket.receive = false end
      return socket
    end
    if mode == "bad-time" then env.api.gettime = function() return "not-a-clock" end end
    local ok, err = pcall(relay, env)
    eq(ok, false)
    if mode == "throw" then assert(not tostring(err):find("private-factory-details", 1, true)) end
    for _, socket in ipairs(env.sockets) do eq(socket.closed, true, "failed initialization closes created listener") end
  end
  local env = mock()
  local r = Relay.new({allowed_clients = {"198.18.32.0/20"}, upstreams = {{host = "192.0.2.53"}}},
    env.api, function() error("broken logger") end, wire)
  r:close()
  eq(env.sockets[1].closed, true, "broken startup logger cannot leak listener")
end

function tests.failed_or_nonwaiting_sleep_cannot_spin()
  for _, mode in ipairs({"throw", "false", "no-wait"}) do
    local env = mock({select_error = true})
    local r = relay(env, {sleep = function()
      if mode == "throw" then error("sleep failed") end
      if mode == "false" then return false end
    end})
    local ok, err = r:step()
    eq(ok, nil); eq(err, "select failed"); eq(r.stopped, true)
    r:close()
  end
end

function tests.local_udp_size_edns_tc_and_source_boundaries()
  local real_wire = require("dns_wire")
  local question = "\6router\4home\4arpa\0" .. u16(16) .. u16(1)
  local function qraw(size)
    return u16(301) .. "\1\16\0\1\0\0\0\0" .. u16(size and 1 or 0) .. question
      .. (size and ("\0\0\41" .. u16(size) .. "\0\0\128\0\0\0") or "")
  end
  local function reply(q, size, tc)
    local header = u16(q.id) .. u16(tc and 33664 or 33152) .. "\0\1\0\1\0\0\0\0" .. q.question
    local remaining, chunks = size - #header - 12, {}
    while remaining > 0 do
      local bytes = math.min(255, remaining - 1)
      chunks[#chunks + 1] = string.char(bytes) .. string.rep("x", bytes)
      remaining = remaining - bytes - 1
    end
    local data = table.concat(chunks)
    return header .. "\192\12\0\16\0\1\0\0\0\30" .. u16(#data) .. data
  end
  for _, case in ipairs({
    {"plain", nil, 512, 0}, {"small-edns", 1232, 512, 0}, {"cap-edns", 4096, 2048, 0},
    {"limit-edns", 2048, 2048, 0}, {"tc", 4096, 512, 2}, {"over-limit", 4096, 2049, 2},
    {"incomplete", 4096, 2049, 2}, {"wrong-source", 4096, 512, 2}
  }) do
    local env = mock(); local original_udp = env.api.udp
    local sent_query
    env.api.udp = function()
      local socket = original_udp()
      socket.sendto = function(s, raw, host, port)
        sent_query = assert(real_wire.parse_query(raw))
        eq(sent_query.edns_udp_size, case[2] and math.min(case[2],2048) or nil)
        eq(sent_query.cd, true); eq(sent_query.do_bit == true, case[2] ~= nil)
        local response = reply(sent_query, case[3], case[1] == "tc")
        if case[1] == "incomplete" then response = response:sub(1,2048) end
        s.udp_response, s.remote_host, s.remote_port = response,
          case[1] == "wrong-source" and "192.0.2.99" or host, port
        env.udp_count = env.udp_count + 1
        return #raw
      end
      socket.receivefrom = function(s, maximum)
        eq(maximum, 2048, "Yamaha UDP receive ceiling")
        local raw = s.udp_response; s.udp_response = nil
        if raw then return raw, s.remote_host, s.remote_port end
        return nil, "timeout"
      end
      return socket
    end
    local raw = qraw(case[2])
    local r = relay(env, {local_zones = {}, local_names = {"router.home.arpa"}}, nil, real_wire)
    local c = env.client(raw)
    until_true(r, function() return #c.output >= 2 and #c.output == id(c.output) + 2 end)
    local response = assert(real_wire.validate_response(c.output:sub(3), assert(real_wire.parse_query(raw))))
    eq(response.rcode, case[4], case[1]); eq(response.tc, false)
    eq(env.upstream_queries, 0, "local names never escape to external TCP")
    eq(#env.tcp_dials, 0); eq(env.udp_count, 1)
    r:close()
  end
end

local names = {}
for name in pairs(tests) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do tests[name](); print("PASS " .. name) end
print("relay tests: " .. #names .. " passed")
