-- Bounded DNS-over-TCP relay. Lua 5.1 / Yamaha integer Lua compatible.
-- All sockets are nonblocking. Only select may wait; no DNS operation blocks
-- unrelated clients. The wire and cache implementations are injected for tests.
local Relay = {}
Relay.__index = Relay

local defaults = {
  listen_host = "127.0.0.1", listen_port = 53053, backlog = 32,
  max_clients = 32, max_pending = 32, client_pipeline = 4, pipeline = 4,
  max_clients_per_ip = 4, query_rate_per_ip = 20, query_burst_per_ip = 40,
  max_client_ips = 256,
  max_query = 4096, connect_timeout = 1, response_timeout = 2,
  total_timeout = 5, client_read_timeout = 3, client_write_timeout = 2,
  idle_timeout = 30, dial_rate = 1, dial_burst = 2, resource_backoff = 30,
  select_timeout = 1, stats_interval = 60, policy_id = "default",
  local_dns_host = "127.0.0.1", local_dns_port = 53,
  local_zones = {}, local_names = {}, allowed_clients = {}, upstreams = {}
}

local function call(object, method, ...)
  local ok, a, b, c = pcall(object[method], object, ...)
  if not ok then return nil, a end
  return a, b, c
end

local function close(socket)
  if socket then pcall(socket.close, socket) end
end

local function waiting(err)
  err = string.lower(tostring(err or ""))
  return err == "timeout" or string.find(err, "in progress", 1, true)
    or string.find(err, "would block", 1, true)
    or string.find(err, "temporarily unavailable", 1, true)
end

local function resource_error(err)
  err = string.lower(tostring(err or ""))
  local patterns = { "assign requested address", "address not available",
    "too many open", "no buffer", "out of memory", "not enough memory" }
  for _, pattern in ipairs(patterns) do
    if string.find(err, pattern, 1, true) then return true end
  end
  return false
end

local function invalid_listener(err)
  err = string.lower(tostring(err or ""))
  return err == "closed" or string.find(err, "bad file descriptor", 1, true)
    or string.find(err, "bad descriptor", 1, true)
    or string.find(err, "not a socket", 1, true)
    or string.find(err, "non-socket", 1, true)
    or string.find(err, "invalid socket", 1, true)
end

local function ipv4(value)
  if type(value) ~= "string" then return nil end
  local a, b, c, d = string.match(value or "", "^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
  return { a, b, c, d }
end

local function cidr_matches(address, rule)
  local first, last = string.match(rule, "^([^%-]+)%-([^%-]+)$")
  if first then
    local n, lo, hi = ipv4(address), ipv4(first), ipv4(last)
    if not n or not lo or not hi then return false end
    local function compare(a, b)
      for i = 1, 4 do
        if a[i] < b[i] then return -1 end
        if a[i] > b[i] then return 1 end
      end
      return 0
    end
    return compare(n, lo) >= 0 and compare(n, hi) <= 0
  end
  local host, bits = string.match(rule, "^([^/]+)/(%d+)$")
  if not host then return address == rule end
  bits = tonumber(bits)
  local n, base = ipv4(address), ipv4(host)
  if not n or not base or bits > 32 then return false end
  -- Yamaha Lua uses signed integers. Never construct a 32-bit IPv4 number
  -- or a 2^32 netmask; compare complete octets and at most seven extra bits.
  for index = 1, 4 do
    if bits >= 8 then
      if n[index] ~= base[index] then return false end
      bits = bits - 8
    elseif bits > 0 then
      local block = 2 ^ (8 - bits)
      return n[index] - n[index] % block == base[index] - base[index] % block
    else return true end
  end
  return true
end

local function canonical_zone(zone)
  zone = string.lower(zone)
  if zone == "." then return "\0" end
  if string.sub(zone, -1) == "." then zone = string.sub(zone, 1, -2) end
  assert(#zone > 0 and string.sub(zone, 1, 1) ~= "." and not string.find(zone, "..", 1, true),
    "local zone has an empty label")
  local labels = {}
  for label in string.gmatch(zone, "[^.]+") do
    assert(#label <= 63, "local zone label exceeds 63 bytes")
    labels[#labels + 1] = string.char(#label) .. label
  end
  local encoded = table.concat(labels) .. "\0"
  assert(#encoded <= 255, "local zone exceeds 255 bytes")
  return encoded
end

local function canonical_suffix(name, zone)
  -- A literal dot within a DNS wire label is not a label separator. Compare
  -- only positions reached by walking the canonical length-prefixed labels.
  if type(name) ~= "string" then return false end
  local position = 1
  while position <= #name do
    if string.sub(name, position) == zone then return true end
    local length = string.byte(name, position)
    if length == 0 or length > 63 or position + length >= #name then return false end
    position = position + length + 1
  end
  return false
end

local function remove_value(list, value)
  for i = #list, 1, -1 do
    if list[i] == value then table.remove(list, i) end
  end
end

function Relay.new(config, socket_api, logfn, wire, cache)
  assert(socket_api and wire, "socket API and DNS wire module are required")
  local cfg = {}
  for k, v in pairs(defaults) do cfg[k] = v end
  for k, v in pairs(config or {}) do cfg[k] = v end
  if cfg.dns_policy then
    assert(type(cfg.dns_policy.routes) == "table" and type(cfg.dns_policy.select) == "function",
      "dns_policy must expose routes and select")
    assert(type(wire.upstream_query) == "function" and type(wire.downstream_response) == "function",
      "policy mode requires DNS query/response transformations")
  else assert(#cfg.upstreams > 0 and #cfg.upstreams <= 2, "one or two upstreams required") end
  cfg.max_upstream_connections = cfg.max_upstream_connections or (cfg.dns_policy and 4 or 2)
  assert(type(cfg.max_upstream_connections) == "number" and cfg.max_upstream_connections >= 1
    and cfg.max_upstream_connections <= 16 and cfg.max_upstream_connections % 1 == 0,
    "max_upstream_connections must be 1..16")
  -- A hostname here can make the socket library resolve it synchronously,
  -- blocking the whole event loop. Routing targets must be literal IPv4.
  assert(ipv4(cfg.listen_host), "listen_host must be an IPv4 address")
  assert(ipv4(cfg.local_dns_host), "local_dns_host must be an IPv4 address")
  local function valid_port(port)
    return type(port) == "number" and port >= 1 and port <= 65535 and port % 1 == 0
  end
  assert(valid_port(cfg.listen_port), "invalid listen_port")
  assert(valid_port(cfg.local_dns_port), "invalid local_dns_port")
  assert(cfg.max_clients > 0 and cfg.max_clients <= 32, "max_clients must be 1..32")
  local function bounded_integer(value, maximum)
    return type(value) == "number" and value >= 1 and value <= maximum and value % 1 == 0
  end
  assert(bounded_integer(cfg.max_clients_per_ip, 32), "max_clients_per_ip must be 1..32")
  assert(bounded_integer(cfg.query_rate_per_ip, 1000), "query_rate_per_ip must be 1..1000")
  assert(bounded_integer(cfg.query_burst_per_ip, 1000), "query_burst_per_ip must be 1..1000")
  assert(bounded_integer(cfg.max_client_ips, 4096) and cfg.max_client_ips >= cfg.max_clients,
    "max_client_ips must be max_clients..4096")
  assert(cfg.max_pending > 0 and cfg.max_pending <= 32, "max_pending must be 1..32")
  assert(cfg.pipeline > 0 and cfg.pipeline <= 4, "pipeline must be 1..4")
  assert(cfg.client_pipeline > 0 and cfg.client_pipeline <= 4, "client_pipeline must be 1..4")
  assert(cfg.max_query >= 12 and cfg.max_query <= 65535, "max_query must be 12..65535")
  assert(#cfg.allowed_clients > 0, "explicit allowed_clients is required")
  local self = setmetatable({ cfg = cfg, api = socket_api, wire = wire,
    cache = cache, log = logfn or function() end, clients = {}, endpoints = {}, routes = {},
    jobs = {}, queue = {}, local_zones = {}, local_names = {}, client_count = 0, pending = 0, serial = 0,
    client_ips = {}, client_ip_count = 0,
    tokens = cfg.dial_burst, counters = {}, events = {}, stopped = false,
    resource_until = 0, resource_recovery = false, resource_probe = nil, accept_retry_at = 0,
    last_raw = nil, elapsed = 0 }, Relay)
  self.now = self:_clock()
  for _, zone in ipairs(cfg.local_zones) do self.local_zones[#self.local_zones + 1] = canonical_zone(zone) end
  for _, name in ipairs(cfg.local_names) do self.local_names[canonical_zone(name)] = true end
  self.started, self.token_time, self.next_stats = self.now, self.now, self.now + cfg.stats_interval
  self.generation = 1
  self.next_policy_refresh = self.now + 30
  self:_load_routes()
  local listener, err = socket_api.tcp()
  assert(listener, "listener socket: " .. tostring(err))
  local ok
  ok, err = call(listener, "settimeout", 0)
  if not ok then close(listener); error("listener timeout: " .. tostring(err)) end
  ok, err = call(listener, "bind", cfg.listen_host, cfg.listen_port)
  if not ok then close(listener); error("listener bind: " .. tostring(err)) end
  ok, err = call(listener, "listen", cfg.backlog)
  if not ok then close(listener); error("listener listen: " .. tostring(err)) end
  self.listener = listener
  self:_event("start", "listening " .. cfg.listen_host .. ":" .. cfg.listen_port)
  return self
end

-- Build an immutable routing view for this generation.
function Relay:_load_routes()
  local cfg = self.cfg
  local function valid_port(port)
    return type(port) == "number" and port >= 1 and port <= 65535 and port % 1 == 0
  end
  self.routes, self.endpoints = {}, {}
  local declared_routes = cfg.dns_policy and cfg.dns_policy.routes
    or { { policy_id = tostring(cfg.policy_id), upstreams = cfg.upstreams } }
  assert(#declared_routes <= 257, "at most 256 policy rules plus one fallback are supported")
  local endpoints_by_peer, policy_ids = {}, {}
  for _, route in ipairs(declared_routes) do
    assert(type(route.policy_id) == "string" and #route.policy_id > 0, "route policy_id is required")
    assert(not policy_ids[route.policy_id], "route policy_id must be unique")
    policy_ids[route.policy_id] = true
    assert(type(route.upstreams) == "table", "route upstreams must be a table")
    assert(((route.reject or route.unavailable) and #route.upstreams == 0)
      or (not route.reject and #route.upstreams >= 1 and #route.upstreams <= 4), "route requires one to four upstreams or reject")
    -- Copy route metadata so an in-flight query's namespace and allowed peers
    -- cannot change if the caller later modifies its configuration table.
    local state = { policy_id = route.policy_id .. ":generation:" .. self.generation,
      event_id = route.policy_id, reason = route.reason,
      reject = route.reject, unavailable = route.unavailable, entries = {} }
    local route_peers = {}
    for _, upstream in ipairs(route.upstreams) do
      assert(ipv4(upstream.host), "upstream.host must be an IPv4 address")
      assert(valid_port(upstream.port or 53), "invalid upstream port")
      assert(upstream.edns == nil or type(upstream.edns) == "boolean", "upstream.edns must be boolean or nil")
      local port = upstream.port or 53
      local key = upstream.host .. ":" .. port
      assert(not route_peers[key], "an upstream peer must occur only once in a route")
      route_peers[key] = true
      local ep = endpoints_by_peer[key]
      if not ep then
        assert(#self.endpoints < 16, "at most 16 distinct upstream peers are supported")
        ep = { host = upstream.host, port = port, index = #self.endpoints + 1,
          state = "closed", inflight = {}, count = 0, sendq = {}, input = "",
          next_id = 0, failures = 0, retry_at = 0, last_activity = self.now }
        self.endpoints[#self.endpoints + 1], endpoints_by_peer[key] = ep, ep
      end
      state.entries[#state.entries + 1] = { endpoint = ep,
        server = { host = upstream.host, port = port, edns = upstream.edns } }
    end
    self.routes[route] = state
    if not cfg.dns_policy then self.default_route = state end
  end
end

function Relay:_clock()
  local value = self.api.gettime()
  assert(type(value) == "number", "socket.gettime() must return a number")
  if self.last_raw then
    local delta = value - self.last_raw
    -- rt.socket.gettime is uptime. A wrap/backwards jump must not postpone
    -- every existing deadline indefinitely. Advance conservatively one tick.
    if delta < 0 then delta = 1 end
    self.elapsed = self.elapsed + delta
  end
  self.last_raw = value
  return self.elapsed
end

function Relay:_inc(key, amount)
  self.counters[key] = (self.counters[key] or 0) + (amount or 1)
end

function Relay:_event(key, message)
  local event = self.events[key]
  if not event then event = { at = -60, suppressed = 0 }; self.events[key] = event end
  if self.now - event.at >= 60 then
    self.log("DNSRELAY " .. message .. " suppressed=" .. event.suppressed)
    event.at, event.suppressed = self.now, 0
  else event.suppressed = event.suppressed + 1 end
end

function Relay:_allowed(address)
  for _, rule in ipairs(self.cfg.allowed_clients) do
    if cidr_matches(address, rule) then return true end
  end
  return false
end

function Relay:_refill_client_ip(state)
  local elapsed = self.now - state.at
  if elapsed <= 0 then return end
  -- rate >= 1, so elapsed >= burst always fills the bucket. Clamp before
  -- multiplying to avoid signed-integer overflow after a long idle period.
  -- Do not divide burst/rate: Yamaha integer division may truncate to zero.
  local burst = self.cfg.query_burst_per_ip
  if elapsed >= burst then state.tokens = burst
  else state.tokens = math.min(burst, state.tokens + elapsed * self.cfg.query_rate_per_ip) end
  state.at = self.now
end

function Relay:_client_ip(address)
  local state = self.client_ips[address]
  if state then self:_refill_client_ip(state); return state end
  if self.client_ip_count >= self.cfg.max_client_ips then
    -- Preserve depleted buckets across disconnects and address churn. Only
    -- reuse an inactive, fully refilled slot; never grow the table unbounded.
    local victim
    for peer, candidate in pairs(self.client_ips) do
      if candidate.connections == 0 then
        self:_refill_client_ip(candidate)
        if candidate.tokens == self.cfg.query_burst_per_ip then victim = peer; break end
      end
    end
    if not victim then return nil end
    self.client_ips[victim] = nil
    self.client_ip_count = self.client_ip_count - 1
  end
  state = {connections = 0, tokens = self.cfg.query_burst_per_ip, at = self.now}
  self.client_ips[address] = state
  self.client_ip_count = self.client_ip_count + 1
  return state
end

function Relay:_local(query)
  if self.local_names[query.canonical_name] then return true end
  for _, zone in ipairs(self.local_zones) do
    if canonical_suffix(query.canonical_name, zone) then return true end
  end
  return false
end

function Relay:_detach(job)
  if job.endpoint then
    local ep = job.endpoint
    if ep.inflight[job.upstream_id] == job then
      ep.inflight[job.upstream_id] = nil
      ep.count = ep.count - 1
    end
    remove_value(ep.sendq, job)
    job.endpoint = nil
  end
  if job.udp then close(job.udp); job.udp = nil end
  remove_value(self.queue, job)
end

function Relay:_remove_job(job)
  if not self.jobs[job.serial] then return end
  self:_detach(job)
  self.jobs[job.serial] = nil
  self.pending = self.pending - 1
  job.client.jobs = job.client.jobs - 1
end

function Relay:_reply(client, raw)
  if not self.clients[client.socket] then return end
  if #client.output >= self.cfg.client_pipeline then self:_close_client(client); return end
  client.output[#client.output + 1] = {
    data = self.wire.frame(raw), pos = 1, deadline = self.now + self.cfg.client_write_timeout }
  client.last_activity = self.now
end

function Relay:_finish(job, raw, cache_response)
  if not self.jobs[job.serial] then return end
  if cache_response and self.cache and job.generation == self.generation then
    self.cache:put(job.query, job.policy_id, raw, self.now)
  end
  self:_remove_job(job)
  self:_reply(job.client, raw)
  self:_inc("responses")
end

function Relay:_fail(job, reason)
  self:_inc("servfail")
  self:_inc("failure_" .. reason)
  self:_finish(job, self.wire.error_response(job.query, 2), false)
end

function Relay:_close_client(client)
  if not self.clients[client.socket] then return end
  self.clients[client.socket] = nil
  self.client_count = self.client_count - 1
  client.ip_state.connections = client.ip_state.connections - 1
  close(client.socket)
  local abandoned = {}
  for _, job in pairs(self.jobs) do
    if job.client == client then abandoned[#abandoned + 1] = job end
  end
  for _, job in ipairs(abandoned) do
    -- Keep an upstream request's correlation slot until its reply or timeout.
    -- An abandoned client must not make a later valid response look unsolicited.
    if job.endpoint then job.abandoned = true
    else self:_remove_job(job) end
  end
  self:_inc("clients_closed")
end

function Relay:_resource_failure(reason)
  self.resource_until = self.now + self.cfg.resource_backoff
  self.resource_recovery = true
  self.resource_probe = nil
  self:_inc("resource_failures")
  self:_event("resource", "new connections suspended: " .. tostring(reason))
end

function Relay:_endpoint_close(ep, failed, reason)
  close(ep.socket)
  ep.socket, ep.state, ep.input = nil, "closed", ""
  local affected = {}
  for _, job in pairs(ep.inflight) do affected[#affected + 1] = job end
  ep.inflight, ep.sendq, ep.count = {}, {}, 0
  if failed then
    ep.failures = ep.failures + 1
    local delay = 1
    for _ = 2, ep.failures do delay = delay * 2; if delay >= 30 then delay = 30; break end end
    ep.retry_at = self.now + delay
    self:_inc("upstream_failures")
    self:_event("upstream_" .. ep.index, "upstream " .. ep.host .. " failed: " .. tostring(reason))
  end
  if self.resource_probe == ep then
    self.resource_probe = nil
    if self.resource_recovery then self.resource_until = self.now + self.cfg.resource_backoff end
  end
  for _, job in ipairs(affected) do
    job.endpoint, job.data, job.response_deadline = nil, nil, nil
    if failed then
      job.failed_endpoints = job.failed_endpoints or {}
      job.failed_endpoints[ep] = true
    end
    if job.abandoned then self:_remove_job(job)
    elseif job.attempts < 2 and job.query.retryable ~= false and self.now < job.deadline then
      job.state = "queued"; self.queue[#self.queue + 1] = job; self:_inc("retries")
    else self:_fail(job, "upstream") end
  end
end

function Relay:_assign(ep, job, entry)
  local raw, err = job.query.raw
  if self.wire.upstream_query then raw, err = self.wire.upstream_query(job.query, entry.server) end
  if not raw then self:_fail(job, "query_transform"); return false end
  repeat ep.next_id = (ep.next_id + 1) % 65536 until not ep.inflight[ep.next_id]
  job.attempts = job.attempts + 1
  job.endpoint, job.upstream_id, job.state, job.selected_server = ep, ep.next_id, "sending", entry.server
  job.data = self.wire.frame(self.wire.with_id(raw, job.upstream_id))
  job.pos = 1
  ep.inflight[job.upstream_id] = job
  ep.sendq[#ep.sendq + 1], ep.count = job, ep.count + 1
  ep.last_activity = self.now
  remove_value(self.queue, job)
  return true
end

function Relay:_connection_count()
  local count = 0
  for _, ep in ipairs(self.endpoints) do if ep.socket then count = count + 1 end end
  return count
end

function Relay:_connection_slot(target)
  if self:_connection_count() < self.cfg.max_upstream_connections then return true end
  local oldest
  for _, ep in ipairs(self.endpoints) do
    if ep ~= target and ep.socket and ep.state == "ready" and ep.count == 0 and #ep.sendq == 0
      and not ep.probe and (not oldest or ep.last_activity < oldest.last_activity) then oldest = ep end
  end
  if not oldest then return false end
  self:_endpoint_close(oldest, false, "connection pool eviction")
  self:_inc("upstream_pool_evictions")
  return true
end

function Relay:_dial(ep)
  self.tokens = self.tokens - 1
  self:_inc("connection_attempts")
  local ok, socket, err = pcall(self.api.tcp)
  if not ok then socket, err = nil, socket end
  if not socket then
    self:_resource_failure(err or "socket allocation failed")
    self:_endpoint_close(ep, true, err)
    return
  end
  ep.socket = socket
  self.counters.peak_upstream_connections = math.max(self.counters.peak_upstream_connections or 0, self:_connection_count())
  local result
  result, err = call(socket, "settimeout", 0)
  if not result then self:_endpoint_close(ep, true, err); return end
  ep.state, ep.connect_deadline = "connecting", self.now + self.cfg.connect_timeout
  ep.probe = ep.failures > 0 or self.resource_recovery
  if self.resource_recovery then self.resource_probe = ep end
  result, err = call(socket, "connect", ep.host, ep.port)
  if result then ep.state = "ready"; self:_inc("connections_opened")
  elseif not waiting(err) then
    if resource_error(err) then self:_resource_failure(err) end
    self:_endpoint_close(ep, true, err)
  end
end

function Relay:_choose_endpoint(job)
  local entries = job.route.entries
  local has_untried = false
  for _, entry in ipairs(entries) do
    if not job.failed_endpoints or not job.failed_endpoints[entry.endpoint] then has_untried = true; break end
  end
  local function eligible(ep)
    -- Waiting for a global dial token can outlast the primary's one-second
    -- backoff. A retry must still prefer a different peer from this same rule,
    -- rather than spend its final attempt on that failed primary again.
    return not has_untried or not job.failed_endpoints or not job.failed_endpoints[ep]
  end
  local function permitted(ep)
    if ep.state ~= "closed" then return true end
    if ep.retry_at > self.now or self.resource_until > self.now then return false end
    if self.resource_recovery and self.resource_probe then return false end
    return true
  end
  for index, entry in ipairs(entries) do
    local ep = entry.endpoint
    if eligible(ep) and permitted(ep) then
      local probing = (ep.state == "connecting" and ep.probe)
        or (ep.state == "ready" and ep.probe and ep.count >= 1)
    -- A half-open primary is not yet healthy. Keep an already established
    -- healthy secondary useful while that single recovery query is pending.
    -- Ordinary primary congestion still queues and never opens a secondary.
      if probing then
        for next_index = index + 1, #entries do
          local alternative = entries[next_index]
          local other = alternative.endpoint
          if eligible(other) and other.state == "ready" and not other.probe and other.count < self.cfg.pipeline then
            return other, alternative
          end
        end
      end
      return ep, entry
    end
  end
  return nil
end

function Relay:_schedule()
  self.tokens = math.min(self.cfg.dial_burst,
    self.tokens + (self.now - self.token_time) * self.cfg.dial_rate)
  self.token_time = self.now
  local queued = {}
  for _, job in ipairs(self.queue) do queued[#queued + 1] = job end
  for _, job in ipairs(queued) do
    if self.jobs[job.serial] and job.state == "queued" then
      local ep, entry = self:_choose_endpoint(job)
      if not ep then self:_fail(job, "unavailable")
      elseif ep.state == "closed" then
        if self.tokens >= 1 and self:_connection_slot(ep) and self:_assign(ep, job, entry) then self:_dial(ep) end
      elseif ep.state == "ready" and ep.count < (ep.probe and 1 or self.cfg.pipeline) then
        self:_assign(ep, job, entry)
      end
    end
  end
end

function Relay:_local_start(job)
  local ok, socket, err = pcall(self.api.udp)
  if not ok then socket, err = nil, socket end
  if not socket then self:_fail(job, "local_socket"); return end
  job.udp, job.state = socket, "local"
  local result
  result, err = call(socket, "settimeout", 0)
  if result then result, err = call(socket, "sendto", job.query.raw,
    self.cfg.local_dns_host, self.cfg.local_dns_port) end
  if not result then self:_fail(job, "local_send"); return end
  job.response_deadline = self.now + self.cfg.response_timeout
  self:_inc("local_queries")
end

function Relay:_query(client, raw)
  self:_inc("queries")
  local state = client.ip_state
  self:_refill_client_ip(state)
  if state.tokens < 1 then
    self:_inc("queries_rate_limited")
    self:_inc("servfail")
    -- Return one failure, then drain bounded existing work without accepting
    -- more frames. The shared IP bucket survives this connection closing.
    client.rate_limited, client.read_eof, client.read_deadline = true, true, nil
    client.input = ""
    self:_reply(client, self.wire.error_response(raw, 2))
    return
  end
  state.tokens = state.tokens - 1
  local query, err = self.wire.parse_query(raw)
  if not query then
    self:_inc("rejected_queries")
    self:_reply(client, self.wire.error_response(raw, 1))
    return
  end
  local is_local = self:_local(query)
  local route = self.default_route
  if not is_local and self.cfg.dns_policy then
    local ok, selected = pcall(self.cfg.dns_policy.select, self.cfg.dns_policy, query, client.address)
    route = ok and self.routes[selected] or nil
    if (route and route.reject) or (ok and type(selected) == "table" and selected.reject) then
      self:_inc("policy_rejects")
      return
    end
    if not route or route.unavailable then
      self:_event("policy_unavailable_" .. (route and route.event_id or "none"),
        "DNS route " .. (route and route.event_id or "unmatched") .. " unavailable: "
        .. tostring(route and route.reason or "no matching route"))
      self:_inc("policy_unmatched")
      self:_inc("servfail")
      self:_reply(client, self.wire.error_response(query, 2))
      return
    end
    query.cache_allow_no_opt = true
  end
  if not is_local and self.cache then
    local hit = self.cache:get(query, route.policy_id, self.now)
    if hit then self:_inc("cache_hits"); self:_reply(client, hit); return end
    self:_inc("cache_misses")
  end
  if self.pending >= self.cfg.max_pending then
    self:_inc("overload")
    self:_reply(client, self.wire.error_response(query, 2))
    return
  end
  self.serial = self.serial + 1
  local job = { serial = self.serial, client = client, query = query, generation = self.generation,
    route = route, policy_id = route and route.policy_id,
    deadline = self.now + self.cfg.total_timeout, attempts = 0, state = "queued" }
  self.jobs[job.serial] = job
  self.pending, client.jobs = self.pending + 1, client.jobs + 1
  self.counters.peak_pending = math.max(self.counters.peak_pending or 0, self.pending)
  if is_local then self:_local_start(job)
  else self.queue[#self.queue + 1] = job end
end

function Relay:_accept()
  if self.now < self.accept_retry_at then return true end
  for _ = 1, 8 do
    if self.client_count >= self.cfg.max_clients then return true end
    local socket, err = call(self.listener, "accept")
    if not socket then
      if waiting(err) then return true end
      self:_inc("accept_failures")
      self:_event("accept", "accept failed: " .. tostring(err))
      if invalid_listener(err) then
        close(self.listener)
        self.listener, self.stopped = nil, true
        return nil, "listener failed: " .. tostring(err)
      end
      -- A queued connection keeps a listener readable even when accept cannot
      -- allocate its socket. Remove that interest for one second; existing
      -- client, cache, UDP, and upstream work remains event-driven and usable.
      self.accept_retry_at = self.now + 1
      return true
    end
    local address = call(socket, "getpeername")
    if not address or not self:_allowed(address) then close(socket); self:_inc("clients_denied")
    else
      local state = self:_client_ip(address)
      if not state then close(socket); self:_inc("client_ip_table_full")
      elseif state.connections >= self.cfg.max_clients_per_ip then
        close(socket); self:_inc("clients_connection_limited")
      elseif state.tokens < 1 then close(socket); self:_inc("clients_rate_limited")
      else
        local ok = call(socket, "settimeout", 0)
        if not ok then close(socket)
        else
          self.clients[socket] = { socket = socket, address = address, ip_state = state, input = "", output = {},
            jobs = 0, last_activity = self.now, read_deadline = self.now + self.cfg.client_read_timeout }
          state.connections = state.connections + 1
          self.client_count = self.client_count + 1
          self:_inc("clients_accepted")
          self.counters.peak_clients = math.max(self.counters.peak_clients or 0, self.client_count)
        end
      end
    end
  end
  return true
end

-- Consume frames already buffered even if select reports no new network bytes.
function Relay:_client_frames(client)
  if client.rate_limited then return end
  for _ = 1, self.cfg.client_pipeline do
    if client.jobs + #client.output >= self.cfg.client_pipeline or #client.input < 2 then return end
    local length = string.byte(client.input, 1) * 256 + string.byte(client.input, 2)
    if length < 12 or length > self.cfg.max_query then self:_close_client(client); return end
    if #client.input < length + 2 then return end
    local raw = string.sub(client.input, 3, length + 2)
    client.input = string.sub(client.input, length + 3)
    self:_query(client, raw)
    if not self.clients[client.socket] then return end
    if #client.input > 0 then client.read_deadline = self.now + self.cfg.client_read_timeout
    else client.read_deadline = nil end
  end
end

function Relay:_client_read(client)
  local raw, err, partial = call(client.socket, "receive", self.cfg.max_query + 2)
  raw = raw or partial or ""
  if #raw > 0 then
    if #client.input == 0 and not client.read_deadline then
      client.read_deadline = self.now + self.cfg.client_read_timeout
    end
    client.input = client.input .. raw
    client.last_activity = self.now
    if #client.input > (self.cfg.max_query + 2) * 2 then self:_close_client(client); return end
    self:_client_frames(client)
  end
  if err and not waiting(err) then
    if err == "closed" and #client.input == 0 then
      client.read_eof, client.read_deadline = true, nil
      if client.jobs == 0 and #client.output == 0 then self:_close_client(client) end
    else self:_close_client(client) end
  end
end

function Relay:_client_write(client)
  local item = client.output[1]
  if not item then return end
  local last, err, partial = call(client.socket, "send", item.data, item.pos)
  local sent = last or partial
  if sent and sent >= item.pos then item.pos = sent + 1; client.last_activity = self.now end
  if err and not waiting(err) then self:_close_client(client); return end
  if item.pos > #item.data then
    table.remove(client.output, 1); self:_inc("client_responses_sent")
    if client.read_eof and client.jobs == 0 and #client.output == 0 then self:_close_client(client) end
  end
end

function Relay:_upstream_write(ep)
  if ep.state == "connecting" then
    local address, port = call(ep.socket, "getpeername")
    if address ~= ep.host or port ~= ep.port then
      self:_endpoint_close(ep, true, address and "unexpected peer" or port or "connect not established"); return
    end
    ep.state = "ready"
    self:_inc("connections_opened")
  end
  -- Bound work per ready socket even when thousands of responses are queued.
  for _ = 1, self.cfg.pipeline do
    local job = ep.sendq[1]
    if not job then return end
    local last, err, partial = call(ep.socket, "send", job.data, job.pos)
    local sent = last or partial
    if sent and sent >= job.pos then job.pos = sent + 1; ep.last_activity = self.now end
    if err and not waiting(err) then
      if resource_error(err) then self:_resource_failure(err) end
      self:_endpoint_close(ep, true, err); return
    end
    if job.pos <= #job.data then return end
    table.remove(ep.sendq, 1)
    job.data, job.state = nil, "waiting"
    job.response_deadline = self.now + self.cfg.response_timeout
    self:_inc("upstream_queries_sent")
  end
end

function Relay:_upstream_frames(ep)
  for _ = 1, self.cfg.pipeline do
    if #ep.input < 2 then return true end
    local length = string.byte(ep.input, 1) * 256 + string.byte(ep.input, 2)
    if length < 12 then self:_endpoint_close(ep, true, "invalid DNS frame"); return false end
    if #ep.input < length + 2 then return true end
    local raw = string.sub(ep.input, 3, length + 2)
    ep.input = string.sub(ep.input, length + 3)
    local id = string.byte(raw, 1) * 256 + string.byte(raw, 2)
    local job = ep.inflight[id]
    if not job or job.state ~= "waiting" then
      self:_endpoint_close(ep, true, "unmatched response ID"); return false
    end
    local valid = self.wire.validate_response(raw, job.query, id)
    if not valid then self:_endpoint_close(ep, true, "invalid DNS response"); return false end
    if ep.failures > 0 then self:_event("recovered_" .. ep.index, "upstream " .. ep.host .. " recovered") end
    ep.failures, ep.retry_at, ep.probe = 0, 0, false
    if self.resource_probe == ep then
      self.resource_probe, self.resource_recovery, self.resource_until = nil, false, 0
      self:_event("resource_recovered", "new connection resources recovered")
    end
    ep.last_activity = self.now
    self:_inc("upstream_responses")
    raw = self.wire.with_id(raw, job.query.id)
    if job.abandoned then self:_remove_job(job)
    else
      if self.wire.downstream_response then raw = self.wire.downstream_response(raw, job.query, job.selected_server) end
      local changed = false
      if raw and self.cfg.dns_policy and self.cfg.dns_policy.aaaa_filter and job.query.qtype == 28 then
        raw, changed = self.wire.filter_aaaa(raw)
        if changed == true then self:_inc("aaaa_filtered") end
      end
      if raw then self:_finish(job, raw, changed ~= true)
      else self:_fail(job, "response_transform") end
    end
  end
  return true
end

function Relay:_upstream_read(ep)
  local raw, err, partial = call(ep.socket, "receive", 16384)
  raw = raw or partial or ""
  if #raw > 0 then
    ep.input = ep.input .. raw
    ep.last_activity = self.now
    if #ep.input > 65537 + 16384 then self:_endpoint_close(ep, true, "receive buffer limit"); return end
    if not self:_upstream_frames(ep) then return end
  end
  if err and not waiting(err) then
    if ep.count == 0 and #ep.input == 0 then
      self:_inc("upstream_idle_closes"); self:_endpoint_close(ep, false, "idle EOF")
    else self:_endpoint_close(ep, true, err) end
  end
end

function Relay:_local_read(job)
  local raw, address, port = call(job.udp, "receivefrom", 65535)
  if not raw then
    if address and not waiting(address) then self:_fail(job, "local_receive") end
    return
  end
  if address ~= self.cfg.local_dns_host or port ~= self.cfg.local_dns_port then return end
  if not self.wire.validate_response(raw, job.query, job.query.id) then
    self:_fail(job, "local_invalid"); return
  end
  self:_finish(job, raw, false)
end

-- Refresh only runtime state, never the configuration snapshot. Close old sockets
-- before installing routes; all pending jobs fail rather than leaking to a new
-- DNS policy or inserting a late response into the new generation's cache.
function Relay:_refresh_policy()
  if not self.cfg.policy_refresh or self.now < self.next_policy_refresh then return end
  self.next_policy_refresh = self.now + 30
  local ok, changed = pcall(self.cfg.policy_refresh)
  if not ok then
    self:_event("policy_refresh", "DNS runtime refresh failed")
    -- A programming/API failure cannot leave old destinations active forever.
    for _, route in ipairs(self.cfg.dns_policy.routes) do
      route.upstreams, route.unavailable = {}, true
    end
    changed = true
  end
  if not changed then return end
  local pending = {}
  for _, job in pairs(self.jobs) do pending[#pending + 1] = job end
  for _, job in ipairs(pending) do
    if job.abandoned then self:_remove_job(job) else self:_fail(job, "policy_changed") end
  end
  for _, ep in ipairs(self.endpoints) do close(ep.socket); ep.socket = nil end
  if self.cache then self.cache:clear() end
  self.generation = self.generation + 1
  self.resource_probe = nil
  self:_load_routes()
  self:_inc("policy_updates")
  self:_event("policy_updated", "DNS runtime updated generation=" .. self.generation)
end

function Relay:_timers()
  self:_refresh_policy()
  local clients = {}
  for _, client in pairs(self.clients) do clients[#clients + 1] = client end
  for _, client in ipairs(clients) do
    if (client.read_deadline and self.now >= client.read_deadline)
      or (client.output[1] and self.now >= client.output[1].deadline)
      or (client.jobs == 0 and #client.output == 0 and self.now - client.last_activity >= self.cfg.idle_timeout) then
      self:_inc("client_timeouts"); self:_close_client(client)
    end
  end
  for _, ep in ipairs(self.endpoints) do
    if ep.state == "connecting" and self.now >= ep.connect_deadline then
      self:_endpoint_close(ep, true, "connect timeout")
    elseif ep.state == "ready" then
      local expired = false
      for _, job in pairs(ep.inflight) do
        if self.now >= job.deadline or (job.response_deadline and self.now >= job.response_deadline) then expired = true; break end
      end
      if expired then self:_endpoint_close(ep, true, "response timeout")
      elseif ep.count == 0 and self.now - ep.last_activity >= self.cfg.idle_timeout then
        self:_endpoint_close(ep, false, "idle timeout"); self:_inc("upstream_idle_closes")
      end
    end
  end
  local jobs = {}
  for _, job in pairs(self.jobs) do jobs[#jobs + 1] = job end
  for _, job in ipairs(jobs) do
    if self.now >= job.deadline then self:_fail(job, "deadline")
    elseif job.state == "local" and self.now >= job.response_deadline then self:_fail(job, "local_timeout") end
  end
  if self.now >= self.next_stats then
    local snapshot = self:stats_snapshot()
    self.log("DNSRELAY stats queries=" .. (snapshot.queries or 0) .. " responses=" .. (snapshot.responses or 0)
      .. " pending=" .. snapshot.pending .. " clients=" .. snapshot.clients
      .. " dials=" .. (snapshot.connection_attempts or 0) .. " failures=" .. (snapshot.upstream_failures or 0)
      .. " accept_failures=" .. (snapshot.accept_failures or 0)
      .. " ip_connections_limited=" .. (snapshot.clients_connection_limited or 0)
      .. " ip_queries_limited=" .. (snapshot.queries_rate_limited or 0)
      .. " ip_reconnects_limited=" .. (snapshot.clients_rate_limited or 0)
      .. " ip_table_full=" .. (snapshot.client_ip_table_full or 0)
      .. " connections=" .. snapshot.connections .. " cache_hits=" .. (snapshot.cache_hits or 0)
      .. " cache_entries=" .. (snapshot.cache and snapshot.cache.entries or 0)
      .. " cache_bytes=" .. (snapshot.cache and snapshot.cache.bytes or 0)
      .. " cache_ttl_fields=" .. (snapshot.cache and snapshot.cache.ttl_fields or 0)
      .. " lua_kib=" .. tostring(snapshot.lua_kib) .. " uptime=" .. snapshot.uptime)
    self.next_stats = self.now + self.cfg.stats_interval
  end
end

function Relay:step()
  if self.stopped then return false end
  self.now = self:_clock()
  self:_timers()
  for _, client in pairs(self.clients) do self:_client_frames(client) end
  for _, ep in ipairs(self.endpoints) do if ep.state == "ready" then self:_upstream_frames(ep) end end
  self:_schedule()
  local readers, writers, read_kind, write_kind = {}, {}, {}, {}
  local function interest(list, map, socket, kind, object)
    list[#list + 1] = socket; map[socket] = { kind, object }
  end
  if self.listener and self.client_count < self.cfg.max_clients and self.now >= self.accept_retry_at then
    interest(readers, read_kind, self.listener, "accept", self)
  end
  for socket, client in pairs(self.clients) do
    if not client.read_eof and client.jobs + #client.output < self.cfg.client_pipeline then
      interest(readers, read_kind, socket, "client", client)
    end
    if #client.output > 0 then interest(writers, write_kind, socket, "client", client) end
  end
  for _, ep in ipairs(self.endpoints) do
    if ep.socket then
      if ep.state == "ready" then interest(readers, read_kind, ep.socket, "upstream", ep) end
      if ep.state == "connecting" or #ep.sendq > 0 then interest(writers, write_kind, ep.socket, "upstream", ep) end
    end
  end
  for _, job in pairs(self.jobs) do
    if job.udp then interest(readers, read_kind, job.udp, "local", job) end
  end
  local ok, readable, writable, err = pcall(self.api.select, readers, writers, self.cfg.select_timeout)
  self.now = self:_clock()
  if not ok or (not readable and err ~= "timeout") then
    self:_inc("select_errors")
    self:_event("select", "select failed: " .. tostring(ok and err or readable))
    -- A persistent select error must not turn the run loop into a CPU spin.
    if self.cfg.sleep then self.cfg.sleep(1); return true end
    self.stopped = true; return nil, "select failed"
  end
  -- select may have waited across a deadline while making a socket readable.
  -- Expire work first: readiness does not extend a query or partial-I/O limit.
  -- The identity guards below discard interests whose timer closed the socket.
  self:_timers()
  for _, socket in ipairs(readable or {}) do
    local item = read_kind[socket]
    if item then
      if item[1] == "accept" then
        local accepted, accept_error = self:_accept()
        if not accepted then return nil, accept_error end
      elseif item[1] == "client" and self.clients[socket] then self:_client_read(item[2])
      elseif item[1] == "upstream" and item[2].socket == socket then self:_upstream_read(item[2])
      elseif item[1] == "local" and self.jobs[item[2].serial] then self:_local_read(item[2]) end
    end
  end
  for _, socket in ipairs(writable or {}) do
    local item = write_kind[socket]
    if item then
      if item[1] == "client" and self.clients[socket] then self:_client_write(item[2])
      elseif item[1] == "upstream" and item[2].socket == socket then self:_upstream_write(item[2]) end
    end
  end
  self:_timers()
  self:_schedule()
  return true
end

function Relay:stats_snapshot()
  local result = {}
  for key, value in pairs(self.counters) do result[key] = value end
  result.clients, result.pending, result.uptime = self.client_count, self.pending, self.now - self.started
  result.client_ips = self.client_ip_count
  result.connections, result.resource_until = self:_connection_count(), self.resource_until
  local ok, memory = pcall(collectgarbage, "count")
  if ok then result.lua_kib = memory end
  if self.cache and self.cache.stats then result.cache = self.cache:stats() end
  return result
end

function Relay:run(duration)
  local deadline = duration and (self.now + duration) or nil
  local reason
  while not self.stopped do
    if deadline and self.now >= deadline then break end
    if self.cfg.max_requests and (self.counters.queries or 0) >= self.cfg.max_requests and self.pending == 0 then
      local output = false
      for _, client in pairs(self.clients) do if #client.output > 0 then output = true end end
      if not output then break end
    end
    local ok, err = self:step()
    if not ok then reason = err; break end
  end
  local result = self:stats_snapshot()
  self:close()
  return result, reason
end

function Relay:close()
  self.stopped = true
  close(self.listener); self.listener = nil
  for socket in pairs(self.clients) do close(socket) end
  for _, ep in ipairs(self.endpoints) do close(ep.socket); ep.socket = nil end
  for _, job in pairs(self.jobs) do close(job.udp) end
  self.clients, self.jobs, self.queue = {}, {}, {}
  self.client_ips, self.client_ip_count = {}, 0
  self.client_count, self.pending = 0, 0
end

Relay.cidr_matches = cidr_matches
return Relay
