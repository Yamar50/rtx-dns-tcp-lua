-- Yamaha DNS routing snapshot with refreshable PP/DHCP source state.
-- Unknown routing semantics fail closed; diagnostics never include config.
-- Lua 5.1 and Yamaha signed-integer Lua compatible; no 32-bit IPv4 arithmetic.
local M = {}
local Policy = {}
Policy.__index = Policy

local types = {a = 1, aaaa = 28, ptr = 12, mx = 15, ns = 2, cname = 5, any = 0}
local defaults = {max_rules = 256, max_endpoints = 16, max_config_bytes = 1048576, max_line_bytes = 4096}

local function decimal(value, maximum)
    if type(value) ~= "string" or not value:match("^%d+$") then return nil end
    local clean = value:gsub("^0+", "")
    if clean == "" then clean = "0" end
    local bound = tostring(maximum)
    if #clean > #bound or (#clean == #bound and clean > bound) then return nil end
    return tonumber(clean)
end

local function ipv4(value)
    if type(value) ~= "string" then return nil end
    local a, b, c, d = value:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    local values, canonical = {a, b, c, d}, {}
    for i = 1, 4 do
        -- Avoid ambiguity with runtimes interpreting zero-prefixed addresses
        -- as octal. Yamaha show config normally emits canonical decimal IPv4.
        if #values[i] > 1 and values[i]:sub(1, 1) == "0" then return nil end
        local n = decimal(values[i], 255)
        if not n then return nil end
        values[i], canonical[i] = n, tostring(n)
    end
    return values, table.concat(canonical, ".")
end

local function compare(a, b)
    for i = 1, 4 do
        if a[i] < b[i] then return -1 end
        if a[i] > b[i] then return 1 end
    end
    return 0
end

local function address_matcher(value, allow_range)
    local first, last = value:match("^([^%-]+)%-([^%-]+)$")
    if first then
        if not allow_range then return nil, "address ranges are unsupported here" end
        first, last = ipv4(first), ipv4(last)
        if not first or not last or compare(first, last) > 0 then return nil, "invalid IPv4 range" end
        return {kind = "range", first = first, last = last}
    end
    local address, prefix = value:match("^([^/]+)/(%d+)$")
    if address then
        local parsed = ipv4(address)
        prefix = decimal(prefix, 32)
        if not parsed or not prefix then return nil, "invalid IPv4 prefix" end
        return {kind = "prefix", address = parsed, prefix = prefix}
    end
    local parsed = ipv4(value)
    if not parsed then return nil, "invalid IPv4 address" end
    return {kind = "address", address = parsed}
end

local function address_matches(address, matcher)
    if not matcher then return true end
    if matcher.kind == "range" then
        return compare(address, matcher.first) >= 0 and compare(address, matcher.last) <= 0
    end
    if matcher.kind == "address" then return compare(address, matcher.address) == 0 end
    local bits = matcher.prefix
    for i = 1, 4 do
        if bits >= 8 then
            if address[i] ~= matcher.address[i] then return false end
            bits = bits - 8
        elseif bits > 0 then
            local width = 2 ^ (8 - bits)
            return address[i] - address[i] % width == matcher.address[i] - matcher.address[i] % width
        else return true end
    end
    return true
end

local function plain_pattern(value, reject)
    value = string.lower(value)
    local leading, trailing = false, false
    if reject then
        if value:sub(1, 1) == "*" then leading = true; value = value:sub(2) end
        if value:sub(-1) == "*" then trailing = true; value = value:sub(1, -2) end
        if leading and value == "" then return {kind = "all"} end
    end
    if value == "." and not leading and not trailing then
        if reject then return {kind = "exact", text = ""} end
        return {kind = "all"}
    end
    -- A final root dot is optional in a complete name. Before a trailing '*'
    -- the dot is a literal prefix separator (NetVolante.*), so preserve it.
    if not trailing and value:sub(-1) == "." then value = value:sub(1, -2) end
    if value == "" or value:find("[^a-z0-9_.%-]") or value:find("..", 1, true) then
        return nil, "unsupported DNS name pattern"
    end
    -- Patterns are literal text suffixes as specified by Yamaha, not
    -- necessarily domain suffixes at label boundaries.
    if reject then
        if leading and trailing then return {kind = "contains", text = value} end
        if leading then return {kind = "suffix", text = value} end
        if trailing then return {kind = "prefix", text = value} end
        return {kind = "exact", text = value}
    end
    return {kind = "suffix", text = value}
end

local function text_matches(text, matcher)
    if matcher.kind == "all" then return true end
    if matcher.kind == "exact" then return text == matcher.text end
    if matcher.kind == "prefix" then return text:sub(1, #matcher.text) == matcher.text end
    if matcher.kind == "suffix" then return text:sub(-#matcher.text) == matcher.text end
    return text:find(matcher.text, 1, true) ~= nil
end

local function query_text(query)
    if type(query) ~= "table" or type(query.canonical_name) ~= "string"
        or type(query.qtype) ~= "number" or query.qtype < 1 or query.qtype > 65535
        or query.qtype % 1 ~= 0 then return nil, "invalid query descriptor" end
    local raw, p, labels = query.canonical_name, 1, {}
    if #raw < 1 or #raw > 255 then return nil, "invalid canonical query name" end
    while p <= #raw do
        local n = raw:byte(p)
        if n == 0 then
            if p ~= #raw then return nil, "extra canonical name data" end
            return table.concat(labels, ".")
        end
        if n > 63 or p + n >= #raw then return nil, "invalid canonical name label" end
        local label = raw:sub(p + 1, p + n)
        -- Literal dots or other unusual bytes inside a wire label must not
        -- impersonate separators when matching Yamaha's textual patterns.
        if label:find("[^A-Za-z0-9_%-]") then return nil, "unsupported query label characters" end
        labels[#labels + 1] = string.lower(label)
        p = p + n + 1
    end
    return nil, "unterminated canonical query name"
end

local function ptr_address(text)
    local d, c, b, a = text:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)%.in%-addr%.arpa$")
    if not a then return nil end
    return ipv4(a .. "." .. b .. "." .. c .. "." .. d)
end

-- IPv6 literals are accepted as configuration data; the current relay only
-- supports IPv4 TCP. Normalize to eight groups for duplicate detection.
local function ip_literal(value)
    local _, host = ipv4(value)
    if host then return host, 4 end
    if type(value) ~= "string" or not value:find(":", 1, true) then return nil end
    local text, zone = value:match("^([^%%]+)%%([^%%]+)$")
    text = string.lower(text or value)
    if zone then
        zone = string.lower(zone)
        if not (zone:match("^lan%d+$") or zone:match("^lan%d+[/.]%d+$")
            or zone:match("^vlan%d+$") or zone:match("^wan%d+$") or zone:match("^bridge%d+$")
            or zone == "onu1"
            or decimal(zone, 2147483647)) then return nil end
    end
    if text:find(".", 1, true) then
        local start, tail = text:match("^(.*:)([^:]+)$")
        local bytes = ipv4(tail)
        if not bytes then return nil end
        text = start .. string.format("%x:%x", bytes[1] * 256 + bytes[2], bytes[3] * 256 + bytes[4])
    end
    if text:find("[^0-9a-f:]") or text:find(":::", 1, true) then return nil end
    local left, right = text:match("^(.-)::(.-)$")
    if left and right:find("::", 1, true) then return nil end
    local function groups(part)
        local out = {}
        if part == "" then return out end
        if part:sub(1, 1) == ":" or part:sub(-1) == ":" then return nil end
        for group in part:gmatch("[^:]+") do
            if #group > 4 then return nil end
            out[#out + 1] = string.format("%x", tonumber(group, 16))
        end
        return out
    end
    local a, b = groups(left or text), groups(right or "")
    if not a or not b then return nil end
    if left then
        local missing = 8 - #a - #b
        if missing < 1 then return nil end
        for _ = 1, missing do a[#a + 1] = "0" end
        for _, group in ipairs(b) do a[#a + 1] = group end
    elseif #a ~= 8 then return nil end
    return table.concat(a, ":") .. (zone and "%" .. zone or ""), 6
end

local function interface(value)
    return type(value) == "string" and (value:match("^lan%d+$")
        or value:match("^wan%d*$") or value:match("^bridge%d+$") or value == "onu1") and value or nil
end

local function options(words, p, descriptor)
    while words[p] and words[p]:find("=", 1, true) do
        local word = words[p]
        if word == "edns=on" or word == "edns=off" then
            if descriptor.edns_seen then return nil, "duplicate DNS option" end
            descriptor.edns, descriptor.edns_seen = word == "edns=on", true
        elseif word:match("^nat46=") then
            if descriptor.nat46 then return nil, "duplicate DNS option" end
            local n = decimal(word:sub(7), 2147483647)
            if not n then return nil, "invalid NAT46 tunnel number" end
            descriptor.nat46 = n
        else descriptor.unsupported = true end
        p = p + 1
    end
    return p
end

local function servers(words, p, maximum)
    local out, seen = {}, {}
    while p <= #words do
        local host, family = ip_literal(words[p])
        if not host then break end
        if #out >= maximum then return nil, "too many DNS servers" end
        if seen[host] then return nil, "duplicate DNS server in route" end
        local descriptor = {host = host, family = family, port = 53, edns = false}
        seen[host] = true
        local next_p, err = options(words, p + 1, descriptor)
        if not next_p then return nil, err end
        p = next_p
        out[#out + 1] = descriptor
    end
    return out, p
end

local function source_spec(words, p, selecting)
    local kind = words[p]
    if kind == "pp" or kind == "dhcp" then
        local id
        if kind == "pp" then id = decimal(words[p + 1], 2147483647)
        else id = interface(words[p + 1]) end
        if not id then return nil, "invalid dynamic DNS source" end
        local spec = {kind = kind, id = tostring(id), edns = false}
        local next_p, err = options(words, p + 2, spec)
        if not next_p then return nil, err end
        if selecting then
            local candidates
            candidates, next_p = servers(words, next_p, 1)
            if not candidates then return nil, next_p end
            spec.defaults = candidates
        end
        return spec, next_p
    end
    local candidates, next_p = servers(words, p, selecting and 2 or 4)
    if not candidates then return nil, next_p end
    if #candidates == 0 then
        if not kind then return nil, "missing DNS server" end
        if kind:match("^[%d%.:]+$") then return nil, "invalid DNS server address" end
        return {kind = "opaque", unsupported = true}, p
    end
    return {kind = "fixed", candidates = candidates}, next_p
end

local function selection_rule(words)
    local id = decimal(words[4], 2147483647)
    if not id then return nil, "invalid selection rule number" end
    local route = {policy_id = "select:" .. tostring(id), rule_id = id, upstreams = {}}
    local rule = {id = id, route = route}
    local p, err = 5
    if words[p] == "reject" then
        route.reject = true
        route.spec = {kind = "reject"}
        p = p + 1
    else
        route.spec, p = source_spec(words, p, true)
        if not route.spec then return nil, p end
        if route.spec.kind == "opaque" then
            rule.opaque = true
            -- Unknown source grammar has no trustworthy token boundary.
            -- A later familiar-looking word may be an argument to that source.
            return rule
        end
    end
    rule.qtype = 1
    if types[words[p]] ~= nil then rule.qtype = types[words[p]]; p = p + 1 end
    if not words[p] then return nil, "missing selection query pattern" end
    if rule.qtype == 12 then
        rule.matcher, err = address_matcher(words[p], false)
        if rule.matcher and rule.matcher.kind == "prefix" and rule.matcher.prefix == 0 then
            rule.matcher, rule.opaque = nil, true
        elseif not rule.matcher then
            -- IPv6 PTR ranges and future PTR forms cannot be evaluated safely.
            if words[p]:find(":", 1, true) or words[p]:find("*", 1, true) or words[p] == "." then
                rule.opaque = true
            else return nil, err end
        end
    else
        rule.matcher, err = plain_pattern(words[p], route.reject)
        if not rule.matcher then rule.opaque = true end
    end
    p = p + 1
    if words[p] and words[p] ~= "restrict" then
        rule.source, err = address_matcher(words[p], true)
        if not rule.source then
            if words[p]:match("^[%d%./%-]+$") then return nil, err end
            rule.opaque = true
            -- This could instead be an unknown record type followed by its
            -- query. Do not use an assumed A/name pair to skip such a rule.
            if rule.qtype == 1 and types[words[p - 2]] == nil then
                rule.qtype, rule.matcher = nil, nil
            end
        end
        p = p + 1
    end
    if words[p] == "restrict" then
        if words[p + 1] == "pp" then
            local pp = decimal(words[p + 2], 2147483647)
            if not pp then return nil, "invalid restrict PP number" end
            rule.restrict_pp = tostring(pp)
            p = p + 3
            if route.reject then rule.opaque = true end
        else rule.opaque = true end
    end
    if p <= #words then rule.opaque = true end
    return rule
end

local function usable(candidates)
    local out, seen = {}, {}
    for _, candidate in ipairs(candidates or {}) do
        if candidate.unsupported then return {}, "unsupported DNS option" end
        if candidate.nat46 then return {}, "NAT46 transformation unsupported" end
        if candidate.family == 4 then
            if not seen[candidate.host] then
                out[#out + 1] = {host = candidate.host, port = 53, edns = candidate.edns == true}
                seen[candidate.host] = true
            end
        end
    end
    if #out == 0 then return out, "IPv6 DNS transport unsupported" end
    return out
end

local function source(runtime, kind, id)
    if type(runtime) ~= "table" or type(runtime.source) ~= "function" then
        return {state = "unknown", reason = "DNS source state unavailable"}
    end
    local ok, state = pcall(runtime.source, runtime, kind, id)
    if not ok or type(state) ~= "table" or (state.state ~= "present" and state.state ~= "absent") then
        return {state = "unknown", reason = "DNS source state unknown"}
    end
    return state
end

local function resolve(spec, runtime, ordinary)
    if spec.kind == "reject" then return {}, nil, "reject" end
    if spec.kind == "opaque" or spec.unsupported then return {}, "unsupported DNS source", "unknown" end
    if spec.kind == "fixed" then
        local out, reason = usable(spec.candidates)
        return out, reason, reason and "unsupported" or "present"
    end
    local state = source(runtime, spec.kind, spec.id)
    if state.state == "unknown" then return {}, state.reason, "unknown" end
    if state.state == "absent" then
        if spec.defaults and #spec.defaults > 0 then
            local out, reason = usable(spec.defaults)
            return out, reason, reason and "unsupported" or "default"
        end
        if spec.kind == "dhcp" and ordinary then
            return ordinary.upstreams, ordinary.reason, "ordinary"
        end
        return {}, "DNS source has no acquired servers", "absent"
    end
    if type(state.servers) ~= "table" or #state.servers == 0 or #state.servers > 4 then
        return {}, "invalid acquired DNS server list", "unknown"
    end
    local candidates = {}
    for _, value in ipairs(state.servers) do
        local host, family = ip_literal(value)
        if not host then return {}, "invalid acquired DNS server", "unknown" end
        candidates[#candidates + 1] = {host = host, family = family, edns = spec.edns, nat46 = spec.nat46}
    end
    local out, reason = usable(candidates)
    return out, reason, reason and "unsupported" or "present"
end

local function signature(route)
    local out = {route.reason or "", route.status or "", route.restrict_state or "",
        route.unavailable and "unavailable" or "available"}
    for _, endpoint in ipairs(route.upstreams) do
        out[#out + 1] = endpoint.host .. ":" .. endpoint.port .. ":" .. tostring(endpoint.edns)
    end
    return table.concat(out, "|")
end

function Policy:refresh(runtime)
    local before, changed, diagnostics = {}, false, {}
    for _, route in ipairs(self.routes) do before[route] = signature(route) end
    local function assign(route, ordinary)
        route.upstreams, route.reason, route.status = resolve(route.spec, runtime, ordinary)
        route.unavailable = route.reason ~= nil
    end
    if self.fallback then assign(self.fallback) end
    for _, rule in ipairs(self.rules) do
        local route = rule.route
        assign(route, self.fallback)
        if rule.restrict_pp then
            local ok, state = false, nil
            if type(runtime) == "table" and type(runtime.pp_state) == "function" then
                ok, state = pcall(runtime.pp_state, runtime, rule.restrict_pp)
            end
            route.restrict_state = ok and (state == "up" or state == "down") and state or "unknown"
        end
        if rule.opaque or route.restrict_state == "unknown" then
            route.upstreams = {}
            route.unavailable = true
            route.reason = rule.opaque and "unsupported selection condition" or "restrict PP state unknown"
        end
        -- Unsupported reject conditions must SERVFAIL, not drop a query on
        -- a condition that was never established.
        route.reject = route.spec.kind == "reject" and not route.unavailable
    end
    local endpoints, count = {}, 0
    for _, route in ipairs(self.routes) do
        for _, endpoint in ipairs(route.upstreams) do
            local key = endpoint.host .. ":" .. endpoint.port
            if not endpoints[key] then endpoints[key] = true; count = count + 1 end
        end
    end
    self.limit_error = nil
    if count > self.limits.max_endpoints then
        self.limit_error = "unique DNS endpoint count limit"
        for _, route in ipairs(self.routes) do
            if not route.reject then
                route.upstreams, route.unavailable, route.reason = {}, true, self.limit_error
            end
        end
        count = 0
    end
    self.endpoint_count = count
    for _, route in ipairs(self.routes) do
        if before[route] ~= signature(route) then changed = true end
        if route.unavailable then diagnostics[#diagnostics + 1] = route.policy_id .. ": " .. route.reason end
    end
    return changed, diagnostics
end

function M.parse(config_text, limits)
    if type(config_text) ~= "string" then return nil, "configuration text required" end
    if limits ~= nil and type(limits) ~= "table" then return nil, "invalid DNS policy limits" end
    local cfg = {}
    for key, value in pairs(defaults) do cfg[key] = value end
    for key, value in pairs(limits or {}) do
        if cfg[key] == nil or type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
            return nil, "invalid DNS policy limit"
        end
        cfg[key] = value
    end
    if #config_text > cfg.max_config_bytes then return nil, "DNS policy configuration size limit" end
    if config_text:find("[%z\1-\8\11\12\14-\31\127]") then return nil, "invalid configuration control character" end
    local rules, ids, ordinary, line_number, dynamic, command_count = {}, {}, {}, 0, false, 0
    local function failure(reason)
        return nil, "DNS policy line " .. line_number .. ": " .. reason
    end
    for line in (config_text .. "\n"):gmatch("(.-)\n") do
        line_number = line_number + 1
        line = line:gsub("\r$", "")
        local words = {}
        for word in line:gmatch("%S+") do words[#words + 1] = word end
        if words[1] == "dns" and words[2] == "server" then
            command_count = command_count + 1
            if #line > cfg.max_line_bytes then return failure("DNS command length limit") end
            if words[3] == "select" then
                if #rules >= cfg.max_rules then return failure("selection rule count limit") end
                local rule, err = selection_rule(words)
                if not rule then return failure(err) end
                if ids[rule.id] then return failure("duplicate selection rule number") end
                ids[rule.id] = true
                rules[#rules + 1] = rule
                if rule.restrict_pp or rule.route.spec.kind == "pp" or rule.route.spec.kind == "dhcp" then dynamic = true end
            else
                local spec, next_p = source_spec(words, 3, false)
                if not spec then return failure(next_p) end
                if next_p <= #words then spec.unsupported = true end
                if ordinary[spec.kind] then return failure("duplicate ordinary DNS command") end
                ordinary[spec.kind] = spec
                if spec.kind == "pp" or spec.kind == "dhcp" then dynamic = true end
            end
        elseif words[1] == "no" and words[2] == "dns" and words[3] == "server" then
            return failure("negative DNS server commands are unsupported in a snapshot")
        end
    end
    table.sort(rules, function(a, b) return a.id < b.id end)
    local routes, fallback = {}, nil
    for _, rule in ipairs(rules) do routes[#routes + 1] = rule.route end
    local chosen = ordinary.opaque or ordinary.fixed or ordinary.pp or ordinary.dhcp
    if command_count == 0 then chosen = {kind = "dhcp", id = "auto", edns = false}; dynamic = true end
    if chosen then
        fallback = {policy_id = "default", upstreams = {}, fallback = true, spec = chosen}
        routes[#routes + 1] = fallback
    end
    -- Count all configured IPv4 endpoints, including inactive lower-priority
    -- sources and inline alternatives, so oversized input is rejected at boot.
    local endpoints, endpoint_count = {}, 0
    local function count_spec(spec)
        for _, list in ipairs({spec.candidates or {}, spec.defaults or {}}) do
            for _, candidate in ipairs(list) do
                if candidate.family == 4 and not endpoints[candidate.host] then
                    endpoints[candidate.host] = true; endpoint_count = endpoint_count + 1
                end
            end
        end
    end
    for _, rule in ipairs(rules) do count_spec(rule.route.spec) end
    for _, spec in pairs(ordinary) do count_spec(spec) end
    if endpoint_count > cfg.max_endpoints then return nil, "unique DNS endpoint count limit" end
    local policy = setmetatable({rules = rules, routes = routes, fallback = fallback,
        ordinary = ordinary, endpoint_count = endpoint_count, limits = cfg, dynamic = dynamic}, Policy)
    policy:refresh(nil)
    return policy
end

function Policy:select(query, client_address)
    local sender = ipv4(client_address)
    if not sender then return nil, "invalid client IPv4 address" end
    local text, err = query_text(query)
    if not text then return nil, err end
    local reverse = query.qtype == 12 and ptr_address(text) or nil
    local first_unavailable = nil
    for _, rule in ipairs(self.rules) do
        if (not rule.qtype or rule.qtype == 0 or rule.qtype == query.qtype)
            and address_matches(sender, rule.source) and rule.route.restrict_state ~= "down" then
            local matched = not rule.matcher
            if rule.matcher then
                if rule.qtype == 12 then matched = reverse and address_matches(reverse, rule.matcher)
                else matched = text_matches(text, rule.matcher) end
            end
            if matched then
                if rule.route.reject or not rule.route.unavailable then
                    return rule.route
                end
                if not first_unavailable then
                    first_unavailable = rule.route
                end
            end
        end
    end
    if first_unavailable then return first_unavailable end
    if not self.fallback then return nil, "no matching DNS route or fallback" end
    return self.fallback
end

return M
