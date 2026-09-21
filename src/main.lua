-- Entrypoint receives an explicit configuration from the generated bundle.
local M = {}
local function service_mode(text)
  -- The documented router default is recursive, so show config may omit it.
  local mode, seen = "recursive", false
  for line in (text .. "\n"):gmatch("(.-)\n") do
    local words = {}
    for word in line:gmatch("%S+") do words[#words + 1] = word end
    local negative = words[1] == "no"
    local first = negative and 2 or 1
    if words[first] == "dns" and words[first + 1] == "service" then
      -- This is a separate setting, not the DNS service enable switch.
      if words[first + 2] == "aaaa" and words[first + 3] == "filter" then
        -- No change to the IPv4 relay activation state.
      else
        if negative or seen or #words ~= 3
          or (words[3] ~= "recursive" and words[3] ~= "off") then
          return nil, "invalid or duplicate dns service setting"
        end
        mode, seen = words[3], true
      end
    end
  end
  return mode
end

function M.read_policy(config, runtime)
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
  local service, service_error = service_mode(text)
  if not service then return nil, service_error end
  if service == "off" then return nil, "dns service is off" end
  -- Only the parsed DNS routing descriptors survive. Never log the full config.
  local policy, err = require("dns_policy").parse(text)
  text = nil
  return policy, err
end

function M.start(config, runtime)
  assert(runtime and runtime.socket, "Yamaha rt.socket runtime is required")
  local wire = require("dns_wire")
  local Cache = require("cache")
  local Relay = require("relay")
  local function log(message)
    if config.console_log ~= false then print(message) end
    if config.syslog ~= false then
      -- Yamaha limits each SYSLOG message to 231 bytes. Preserve the whole
      -- message across records, including when counters or errors grow long.
      local first, prefix = 1, ""
      repeat
        local last = first + 231 - #prefix - 1
        runtime.syslog("info", prefix .. string.sub(message, first, last))
        first, prefix = last + 1, "DNSRELAY continued "
      until first > #message
    end
  end
  local policy, policy_error = M.read_policy(config, runtime)
  assert(not policy_error, policy_error)
  config.dns_policy = policy
  if policy then log("DNSRELAY running DNS policy loaded routes=" .. #policy.routes) end
  config.sleep = function(seconds) runtime.sleep(seconds) end
  local cache = Cache.new(config.cache_entries or 256, config.cache_bytes or 1048576,
    config.cache_ttl_fields or 4096)
  local relay = Relay.new(config, runtime.socket, log, wire, cache)
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
