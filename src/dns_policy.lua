-- Read-only routing snapshot for static IPv4 Yamaha "dns server" commands.
-- All unsupported routing syntax fails closed; errors never include config.
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

local function servers(words, position, maximum)
    local out, seen = {}, {}
    while position <= #words do
        local _, host = ipv4(words[position])
        if not host then break end
        if #out >= maximum then return nil, "too many DNS servers" end
        if seen[host] then return nil, "duplicate DNS server in route" end
        local descriptor = {host = host, port = 53, edns = false}
        seen[host] = true
        out[#out + 1] = descriptor
        position = position + 1
        local option = words[position]
        if option == "edns=on" or option == "edns=off" then
            descriptor.edns = option == "edns=on"
            position = position + 1
        end
    end
    if #out == 0 then return nil, "static IPv4 DNS server required" end
    return out, position
end

local function selection_rule(words)
    local id = decimal(words[4], 2147483647)
    if not id then return nil, "invalid selection rule number" end
    local route = {policy_id = "select:" .. tostring(id), rule_id = id, upstreams = {}}
    local p = 5
    if words[p] == "reject" then route.reject = true; p = p + 1
    else
        local parsed, next_p = servers(words, p, 2)
        if not parsed then return nil, next_p end
        route.upstreams, p = parsed, next_p
    end
    local qtype = 1
    if types[words[p]] ~= nil then qtype = types[words[p]]; p = p + 1 end
    if route.reject and qtype == 12 then return nil, "reject PTR selection is unsupported" end
    if not words[p] then return nil, "missing selection query pattern" end
    local matcher, err
    if qtype == 12 then
        matcher, err = address_matcher(words[p], false)
        if matcher and matcher.kind == "prefix" and matcher.prefix == 0 then
            return nil, "all-address PTR selection is unsupported"
        end
    else matcher, err = plain_pattern(words[p], route.reject) end
    if not matcher then return nil, err end
    p = p + 1
    local source
    if words[p] then
        source, err = address_matcher(words[p], true)
        if not source then return nil, err end
        p = p + 1
    end
    if p <= #words then return nil, "unsupported selection options" end
    return {id = id, qtype = qtype, matcher = matcher, source = source, route = route}
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
    local rules, ids, fallback, line_number = {}, {}, nil, 0
    local function failure(reason)
        return nil, "DNS policy line " .. line_number .. ": " .. reason
    end
    for line in (config_text .. "\n"):gmatch("(.-)\n") do
        line_number = line_number + 1
        line = line:gsub("\r$", "")
        local words = {}
        for word in line:gmatch("%S+") do words[#words + 1] = word end
        if words[1] == "dns" and words[2] == "server" then
            if #line > cfg.max_line_bytes then return failure("DNS command length limit") end
            if words[3] == "select" then
                if #rules >= cfg.max_rules then return failure("selection rule count limit") end
                local rule, err = selection_rule(words)
                if not rule then return failure(err) end
                if ids[rule.id] then return failure("duplicate selection rule number") end
                ids[rule.id] = true
                rules[#rules + 1] = rule
            else
                if fallback then return failure("duplicate fallback DNS command") end
                local parsed, next_p = servers(words, 3, 4)
                if not parsed then return failure(next_p) end
                if next_p <= #words then return failure("unsupported fallback DNS options") end
                fallback = {policy_id = "default", upstreams = parsed, fallback = true}
            end
        elseif words[1] == "no" and words[2] == "dns" and words[3] == "server" then
            return failure("negative DNS server commands are unsupported in a snapshot")
        end
    end
    table.sort(rules, function(a, b) return a.id < b.id end)
    local routes, endpoints, endpoint_count = {}, {}, 0
    for _, rule in ipairs(rules) do routes[#routes + 1] = rule.route end
    if fallback then routes[#routes + 1] = fallback end
    if #routes == 0 then return nil, "no static DNS routes configured" end
    for _, route in ipairs(routes) do
        for _, upstream in ipairs(route.upstreams) do
            local key = upstream.host .. ":" .. upstream.port
            if not endpoints[key] then endpoints[key] = true; endpoint_count = endpoint_count + 1 end
        end
    end
    if endpoint_count > cfg.max_endpoints then return nil, "unique DNS endpoint count limit" end
    return setmetatable({rules = rules, routes = routes, fallback = fallback,
        endpoint_count = endpoint_count, limits = cfg}, Policy)
end

function Policy:select(query, client_address)
    local source = ipv4(client_address)
    if not source then return nil, "invalid client IPv4 address" end
    local text, err = query_text(query)
    if not text then return nil, err end
    local reverse = query.qtype == 12 and ptr_address(text) or nil
    for _, rule in ipairs(self.rules) do
        if (rule.qtype == 0 or rule.qtype == query.qtype) and address_matches(source, rule.source) then
            local matched
            if rule.qtype == 12 then matched = reverse and address_matches(reverse, rule.matcher)
            else matched = text_matches(text, rule.matcher) end
            if matched then return rule.route end
        end
    end
    if not self.fallback then return nil, "no matching static DNS route or fallback" end
    return self.fallback
end

return M
