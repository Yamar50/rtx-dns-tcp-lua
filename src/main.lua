-- Entrypoint receives an explicit configuration from the generated bundle.
local M = {}
local function service_mode(text)
  -- The documented router default is recursive, so show config may omit it.
  local mode, seen, aaaa_filter = "recursive", false, false
  local options = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local words = {}
    for word in line:gmatch("%S+") do words[#words + 1] = word end
    local negative = words[1] == "no"
    local first = negative and 2 or 1
    if words[first] == "dns" and words[first + 1] == "service" then
      if words[first + 2] == "aaaa" and words[first + 3] == "filter" then
        if negative or options.aaaa or #words ~= 5 or (words[5] ~= "on" and words[5] ~= "off") then
          return nil, "invalid or duplicate DNS AAAA filter setting"
        end
        aaaa_filter, options.aaaa = words[5] == "on", true
      elseif words[first + 2] == "fallback" then
        if negative or options.fallback or #words ~= 4 or (words[4] ~= "on" and words[4] ~= "off") then
          return nil, "invalid or duplicate DNS service fallback setting"
        end
        options.fallback = true
      else
        if negative or seen or #words ~= 3
          or (words[3] ~= "recursive" and words[3] ~= "off") then
          return nil, "invalid or duplicate dns service setting"
        end
        mode, seen = words[3], true
      end
    end
  end
  return mode, nil, aaaa_filter
end

function M.read_policy(config, runtime)
  if config.auto_config ~= nil and type(config.auto_config) ~= "boolean" then
    return nil, "auto_config must be boolean"
  end
  if config.auto_config and (config.dns_config == "static" or config.dns_policy) then
    return nil, "auto_config requires the running router configuration"
  end
  if config.dns_config ~= nil and config.dns_config ~= "running" and config.dns_config ~= "static" then
    return nil, "dns_config must be omitted, running, or static"
  end
  -- Explicit test fixtures may inject a previously validated snapshot or use
  -- static LAN upstreams. Normal router use needs no Lua-side mode switch.
  if config.dns_policy then return config.dns_policy end
  if config.dns_config == "static" then return nil end
  if type(runtime.command) ~= "function" then return nil, "runtime.command is required for running DNS config" end
  local ok, success, text = pcall(runtime.command, "show config")
  if not ok or not success or type(text) ~= "string" then
    return nil, "cannot read running DNS configuration"
  end
  if #text > 1048576 then return nil, "DNS policy configuration size limit" end
  local service, service_error, aaaa_filter = service_mode(text)
  if not service then return nil, service_error end
  if service == "off" then return nil, "dns service is off" end
  -- Only the parsed DNS routing descriptors survive. Never log the full config.
  local policy, err = require("dns_policy").parse(text)
  if err then return nil, err end
  local automatic
  if config.auto_config then
    automatic, err = require("auto_config").parse(text)
    if not automatic then return nil, err end
  end
  policy.aaaa_filter = aaaa_filter
  local refresh
  if policy.dynamic then
    local reader, runtime_error = require("dns_runtime").new(text, runtime.command)
    if not reader then return nil, runtime_error end
    refresh = function()
      reader:refresh()
      return policy:refresh(reader)
    end
    refresh()
    if policy.limit_error then return nil, policy.limit_error end
  end
  text = nil
  return policy, nil, automatic, refresh
end

function M.start(config, runtime)
  assert(runtime and runtime.socket, "Yamaha rt.socket runtime is required")
  local wire = require("dns_wire")
  local Cache = require("cache")
  local Relay = require("relay")
  local function log(message)
    if config.console_log ~= false then pcall(print, message) end
    if config.syslog ~= false and type(runtime.syslog) == "function" then
      -- Yamaha limits each SYSLOG message to 231 bytes. Preserve the whole
      -- message across records, including when counters or errors grow long.
      local first, prefix = 1, ""
      repeat
        local last = first + 231 - #prefix - 1
        pcall(runtime.syslog, "info", prefix .. string.sub(message, first, last))
        first, prefix = last + 1, "DNSRELAY continued "
      until first > #message
    end
  end
  local policy, policy_error, automatic, refresh = M.read_policy(config, runtime)
  if policy_error then
    log("DNSRELAY startup failed " .. policy_error)
    error(policy_error)
  end
  if type(runtime.sleep) ~= "function" then
    log("DNSRELAY startup failed runtime.sleep API is required")
    error("runtime.sleep API is required")
  end
  if config.syslog ~= false and type(runtime.syslog) ~= "function" then
    log("DNSRELAY startup failed runtime.syslog API is required")
    error("runtime.syslog API is required")
  end
  -- Copy the supplied profile; retain only parsed settings from show config.
  local profile = {}
  for key, value in pairs(config) do profile[key] = value end
  config = profile
  if automatic then
    for key, value in pairs(automatic) do config[key] = value end
    log("DNSRELAY automatic settings loaded ACL=" .. #config.allowed_clients
      .. " local_names=" .. #config.local_names)
  end
  config.dns_policy = policy
  config.policy_refresh = refresh or config.policy_refresh
  if policy then
    log("DNSRELAY running DNS policy loaded routes=" .. #policy.routes)
    for _, route in ipairs(policy.routes) do
      if route.unavailable then
        log("DNSRELAY route " .. route.policy_id .. " unavailable: " .. tostring(route.reason or "unknown"))
      end
    end
  end
  config.sleep = function(seconds) return runtime.sleep(seconds) end
  local cache = Cache.new(config.cache_entries or 256, config.cache_bytes or 1048576,
    config.cache_ttl_fields or 4096)
  local initialized, relay = pcall(Relay.new, config, runtime.socket, log, wire, cache)
  if not initialized then
    log("DNSRELAY startup failed " .. tostring(relay))
    error(relay)
  end
  local ok, result, reason = pcall(function() return relay:run(config.duration) end)
  relay:close()
  if not ok then
    log("DNSRELAY fatal " .. tostring(result))
    error(result)
  end
  local fields = {}
  for key, value in pairs(result) do
    if type(value) ~= "table" then fields[#fields + 1] = key .. "=" .. tostring(value) end
  end
  for key, value in pairs(result.cache or {}) do
    fields[#fields + 1] = "cache_store_" .. key .. "=" .. tostring(value)
  end
  table.sort(fields)
  log("DNSRELAY stopped " .. table.concat(fields, " ") .. " reason=" .. tostring(reason or "duration"))
  return result
end
return M
