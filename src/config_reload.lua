-- Running DNS configuration supervisor; enabled by the public release profile.
-- Configuration snapshots stay within this task and are never written or logged.
local M = {}
-- YAMAHA integer Lua omits math.floor/ceil. Modulo also works with the host
-- test runtime's fractional socket clock.
local function floor(value) return value - value % 1 end
local function ceil(value)
  local whole = floor(value)
  return whole + (whole < value and 1 or 0)
end

function M.signature(text)
  if type(text) ~= "string" or #text > 1048576 or not text:find("%S") then
    return nil, "missing or oversized configuration snapshot"
  end
  if text:find("[%z\1-\8\11\12\14-\31\127]") then
    return nil, "invalid configuration control character"
  end
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if #line > 4096 then return nil, "configuration line limit" end
    if not line:match("^%s*#") then
      local t = {}
      for word in line:gmatch("%S+") do t[#t + 1] = word end
      local p = t[1] == "no" and 2 or 1
      local a, b, c, d = t[p], t[p + 1], t[p + 2], t[p + 3]
      -- Include every input consumed by the current policy, ACL and dynamic
      -- source parsers, including malformed/negative forms. Do not retain PP
      -- credentials, administrator passwords or unrelated router settings.
      local relevant = a == "dns" and (b == "server" or b == "host" or b == "static" or b == "service")
        or a == "ip" and (b == "host" or c == "address" or c == "secondary"
          or b == "pp" and c == "remote" and d == "address")
        or a == "ipv6" and c == "dhcp" and d == "service"
      if relevant then lines[#lines + 1] = table.concat(t, " ") end
    end
  end
  -- Empty/read-invalid snapshots must not silently select allow-any. An API
  -- success containing a plausible partial config cannot be detected here.
  if #lines == 0 then return nil, "missing DNS and interface configuration" end
  return table.concat(lines, "\n")
end

local function clock(api)
  local last, elapsed = nil, 0
  return function()
    local ok, value = pcall(api.gettime)
    assert(ok and type(value) == "number" and value == value and value - value == 0,
      "config reload requires a finite socket.gettime()")
    if last then
      local delta = value - last
      if delta < 0 then delta = 1 end
      elapsed = elapsed + delta
    end
    last = value
    return elapsed
  end
end

function M.run(config, runtime, start_once, log)
  local interval = config.config_reload_interval
  assert(type(interval) == "number" and interval >= 1 and interval <= 3600 and interval % 1 == 0,
    "config_reload_interval must be an integer in 1..3600")
  assert(config.auto_config == true and config.dns_config ~= "static" and not config.dns_policy,
    "config reload requires automatic running configuration")
  assert(type(runtime.command) == "function" and type(runtime.socket.gettime) == "function",
    "config reload requires command and clock APIs")
  local now = clock(runtime.socket)
  local started = now()
  local deadline = config.duration and (started + config.duration)
  local next_check, signature, pending = started, nil, nil
  local checks, generations, failures = 0, 0, 0
  local last_result, active = {}, false
  local function observe(event, fields)
    if type(config.config_reload_observe) ~= "function" then return end
    local value = {event = event, checks = checks, generation = generations,
      failures = failures, active = active, uptime = floor(now() - started)}
    local ok, kib = pcall(collectgarbage, "count")
    if ok then value.lua_kib = kib end
    for key, item in pairs(fields or {}) do value[key] = item end
    -- Optional diagnostics must not stop DNS or expose snapshots.
    pcall(config.config_reload_observe, value)
  end
  local function expired() return deadline and now() >= deadline end
  local function wait_until(due)
    if deadline and due > deadline then due = deadline end
    while now() < due do
      local before = now()
      local seconds = math.min(30, math.max(1, ceil(due - before)))
      local waited = false
      for _, mode in ipairs({"runtime", "socket", "select"}) do
        if not waited then
          local fn = mode == "runtime" and runtime.sleep or mode == "socket" and runtime.socket.sleep
          if mode == "select" and type(runtime.socket.select) == "function" then
            local ok = pcall(runtime.socket.select, {}, {}, seconds)
            waited = ok and now() > before
          elseif type(fn) == "function" then
            local ok = pcall(fn, seconds)
            waited = ok and now() > before
          end
        end
      end
      -- An unavailable/broken wait API is not a recoverable DNS config error.
      -- Stop instead of spinning continuously on the router CPU.
      assert(waited, "config reload cannot wait safely")
    end
  end
  local function acquire()
    local before = now()
    local ok, accepted, text = pcall(runtime.command, "show config")
    local candidate, reason
    if not ok or not accepted or type(text) ~= "string" then
      reason = "cannot read running DNS configuration"
      text = nil
    else candidate, reason = M.signature(text) end
    -- The parsers consume exactly the projected inputs. Retain that compact
    -- projection only, so passwords and unrelated full config do not survive
    -- while the relay is running. Parser line numbers refer to this projection.
    text = candidate
    local after = now()
    checks = checks + 1
    next_check = after + interval
    local status = reason and "unreadable" or candidate == signature and "unchanged" or "changed"
    local ms = floor((after - before) * 1000)
    log("DNSRELOAD check=" .. checks .. " generation=" .. generations .. " read_ms=" .. ms .. " status=" .. status)
    observe("check", {read_ms = ms, status = status})
    return {text = text, signature = candidate, error = reason}
  end
  while not expired() do
    if not pending then
      wait_until(next_check)
      if expired() then break end
      pending = acquire()
    end
    local snapshot = pending
    pending = nil
    if snapshot.text then
      signature = snapshot.signature
      local control = {}
      control.check = function(relay)
        if now() < next_check then return false end
        if relay then observe("relay", relay:stats_snapshot()) end
        local candidate = acquire()
        if candidate.signature == signature and not candidate.error then return false end
        pending = candidate
        return true
      end
      control.ready = function()
        generations = generations + 1
        active = true
        log("DNSRELOAD active generation=" .. generations .. " checks=" .. checks)
        observe("active")
      end
      local remaining = deadline and math.max(0, deadline - now())
      local before = now()
      local ok, result, reason = pcall(start_once, snapshot.text, control, remaining)
      snapshot = nil
      active = false
      if ok then
        last_result = result or {}
        if reason ~= "config_reload" then
          if reason == nil or expired() then break end
          failures = failures + 1
          log("DNSRELOAD suspended relay stopped; retry_seconds=" .. interval)
          observe("suspended", {reason = "relay_stopped"})
          next_check = now() + interval
        else
          log("DNSRELOAD reinitialize generation=" .. generations .. " uptime=" .. floor(now() - before))
        end
      else
        failures = failures + 1
        -- start_once logs its sanitized parser/runtime diagnostic separately.
        log("DNSRELOAD suspended initialization/runtime failure; retry_seconds=" .. interval)
        observe("suspended", {reason = "initialization_or_runtime_failure"})
        next_check = now() + interval
      end
    else
      failures = failures + 1
      log("DNSRELOAD suspended " .. tostring(snapshot.error) .. "; retry_seconds=" .. interval)
      observe("suspended", {reason = "configuration_unreadable"})
    end
  end
  last_result.config_checks, last_result.config_generations = checks, generations
  last_result.config_failures, last_result.config_active = failures, active
  log("DNSRELOAD stopped checks=" .. checks .. " generations=" .. generations .. " failures=" .. failures)
  observe("stopped")
  return last_result
end

return M
