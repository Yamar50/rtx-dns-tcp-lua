package.path = "src/?.lua;" .. package.path
local Policy = require("dns_policy")
local checks = 0
local function check(value, message)
    checks = checks + 1
    assert(value, message or ("policy assertion " .. checks))
    return value
end
local function equal(actual, expected, message)
    check(actual == expected, (message or "values differ") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end
local function query(name, qtype)
    local labels = {}
    for label in name:gmatch("[^.]+") do labels[#labels + 1] = string.char(#label) .. label end
    return {canonical_name = table.concat(labels) .. "\0", qtype = qtype or 1}
end
local function parse(config, limits)
    local policy, err = Policy.parse(config, limits)
    return check(policy, err)
end
local function selected(policy, name, qtype, source)
    local route, err = policy:select(query(name, qtype), source or "198.18.32.30")
    return check(route, err)
end
local function reject_config(config, limits)
    local ok, result, err = pcall(Policy.parse, config, limits)
    check(ok, "configuration parser threw")
    check(result == nil and type(err) == "string", "unsupported configuration was accepted")
    check(not err:find("private%-config%-sentinel"), "configuration leaked into error")
end

-- Three example DNS selection rules: priority precedes sender range, and the
-- catch-all rule takes precedence over the ordinary static fallback.
local snapshot = [[# Yamaha configuration snapshot
login password private-config-sentinel
ip lan1 address 198.18.32.42/20
dns host lan1
dns service recursive
dns server 1.1.1.3 8.8.8.8
dns server select 500201 1.1.1.2 8.8.8.8 any .
dns server select 10 203.0.113.53 edns=off any _aaplcache._tcp.example.test
dns server select 9999 1.1.1.1 8.8.8.8 any . 198.18.32.1-198.18.32.254
dns private address spoof off
]]
local p = parse(snapshot)
equal(#p.routes, 4)
equal(p.routes[1].policy_id, "select:10")
equal(p.routes[2].policy_id, "select:9999")
equal(p.routes[3].policy_id, "select:500201")
equal(p.routes[4].policy_id, "default")
equal(p.endpoint_count, 5)
equal(selected(p, "_aaplcache._tcp.example.test", 16).upstreams[1].host, "203.0.113.53")
equal(selected(p, "_AAPLCACHE._TCP.EXAMPLE.TEST.", 16, "198.18.40.1"), p.routes[1])
equal(selected(p, "example.com", 16), p.routes[2])
equal(selected(p, "example.com", 28, "198.18.32.1"), p.routes[2])
equal(selected(p, "example.com", 1, "198.18.32.254"), p.routes[2])
equal(selected(p, "example.com", 1, "198.18.32.0"), p.routes[3])
equal(selected(p, "example.com", 1, "198.18.32.255"), p.routes[3])
equal(selected(p, "example.com", 1, "198.18.40.1"), p.routes[3])
equal(selected(p, "1.40.18.198.in-addr.arpa", 12, "198.18.40.1"), p.routes[3])
equal(p.routes[1].upstreams[1].edns, false)
equal(p.routes[2].upstreams[2].host, "8.8.8.8")

-- Do not retain the whole snapshot or unrelated secrets in returned objects.
local seen = {}
local function no_secret(value)
    if type(value) == "string" then check(not value:find("private%-config%-sentinel")) end
    if type(value) ~= "table" or seen[value] then return end
    seen[value] = true
    for key, item in pairs(value) do no_secret(key); no_secret(item) end
end
no_secret(p)

-- Numeric ordering, omitted type=A, literal text suffix semantics, root rule,
-- and all six explicit record types.
local ordered = parse([[dns server 8.8.8.8
dns server select 20 192.0.2.20 any example.com
dns server select 3 192.0.2.3 yamaha.co.jp.
dns server select 100 192.0.2.100 any .
]])
equal(selected(ordered, "rtpro.yamaha.co.jp", 1).rule_id, 3)
equal(selected(ordered, "notyamaha.co.jp", 1).rule_id, 3, "Yamaha literal suffix, not label boundary")
equal(selected(ordered, "yamaha.co.jp", 28).rule_id, 100, "omitted type only matches A")
equal(selected(ordered, "www.example.com", 65).rule_id, 20)
equal(selected(ordered, ".", 1).rule_id, 100)
for kind, qtype in pairs({a = 1, aaaa = 28, mx = 15, ns = 2, cname = 5}) do
    local typed = parse("dns server 8.8.8.8\ndns server select 1 192.0.2.1 " .. kind .. " example.com")
    equal(selected(typed, "www.example.com", qtype).policy_id, "select:1")
    equal(selected(typed, "www.example.com", 16).policy_id, "default")
end

-- Source addresses use octet comparisons, including high-bit addresses and
-- partial masks, without constructing unsigned 32-bit numbers.
local sources = parse([[dns server 8.8.8.8
dns server select 1 192.0.2.1 any . 198.18.32.30
dns server select 2 192.0.2.2 any . 198.18.32.0/20
dns server select 3 192.0.2.3 any . 128.0.0.0/1
dns server select 4 192.0.2.4 any . 0.0.0.0/0
]])
equal(selected(sources, "example", 1, "198.18.32.30").rule_id, 1)
equal(selected(sources, "example", 1, "198.18.47.255").rule_id, 2)
equal(selected(sources, "example", 1, "198.18.48.0").rule_id, 3)
equal(selected(sources, "example", 1, "255.255.255.255").rule_id, 3)
equal(selected(sources, "example", 1, "128.0.0.0").rule_id, 3)
equal(selected(sources, "example", 1, "127.255.255.255").rule_id, 4)
local narrow = parse([[dns server 8.8.8.8
dns server select 1 192.0.2.1 any . 198.18.32.42/31
dns server select 2 192.0.2.2 any . 198.18.32.44/32
]])
equal(selected(narrow, "example", 1, "198.18.32.43").rule_id, 1)
equal(selected(narrow, "example", 1, "198.18.32.44").rule_id, 2)
equal(selected(narrow, "example", 1, "198.18.32.45").policy_id, "default")
local cross_octet = parse("dns server 8.8.8.8\ndns server select 1 192.0.2.1 any . 198.18.31.254-198.18.32.1")
equal(selected(cross_octet, "example", 1, "198.18.32.0").rule_id, 1)
equal(selected(cross_octet, "example", 1, "198.18.31.253").policy_id, "default")
equal(selected(cross_octet, "example", 1, "198.18.32.2").policy_id, "default")

-- PTR targets are decoded from exactly four reverse IPv4 labels. An `any .`
-- rule can still select routes for IPv6 reverse names and other query types.
local ptr = parse([[dns server 8.8.8.8
dns server select 1 192.0.2.1 ptr 198.18.32.42
dns server select 2 192.0.2.2 ptr 198.18.32.0/20
dns server select 3 192.0.2.3 ptr 128.0.0.0/1
]])
equal(selected(ptr, "42.32.18.198.in-addr.arpa", 12).rule_id, 1)
equal(selected(ptr, "255.47.18.198.in-addr.arpa", 12).rule_id, 2)
equal(selected(ptr, "0.48.18.198.in-addr.arpa", 12).rule_id, 3)
equal(selected(ptr, "255.255.255.255.in-addr.arpa", 12).rule_id, 3)
equal(selected(ptr, "42.32.18.198.in-addr.arpa", 1).policy_id, "default")
equal(selected(ptr, "1.0.0.127.in-addr.arpa", 12).policy_id, "default")
equal(selected(ptr, "1.0.0.ip6.arpa", 12).policy_id, "default")
equal(selected(ptr, "32.18.198.in-addr.arpa", 12).policy_id, "default")

-- Rejection is a registered immutable route, never fallback to another DNS.
local reject = parse([[dns server 8.8.8.8
dns server select 1 reject any exact.example
dns server select 2 reject any NetVolante.*
dns server select 3 reject any *yamaha.co.jp
dns server select 4 reject any *middle*
]])
local denied = selected(reject, "exact.example", 16)
check(denied.reject and #denied.upstreams == 0)
equal(denied, reject.routes[1])
equal(selected(reject, "www.exact.example", 16).policy_id, "default")
check(selected(reject, "NetVolante.jp", 1).reject)
check(selected(reject, "NetVolante.rtpro.yamaha.co.jp", 28).reject)
equal(selected(reject, "NetVolanteEvil.example", 1).policy_id, "default")
check(selected(reject, "notyamaha.co.jp", 15).reject)
check(selected(reject, "in-the-middle.example", 2).reject)
local reject_all = parse("dns server select 1 reject any *")
check(selected(reject_all, "example", 16).reject)
local no_fallback = parse("dns server select 1 192.0.2.1 a example.com")
local missing, missing_error = no_fallback:select(query("elsewhere", 1), "198.18.32.30")
check(missing == nil and type(missing_error) == "string")

-- EDNS belongs to each destination descriptor, not the shared physical pool.
local options = parse([[dns server 1.1.1.1 edns=on 8.8.8.8 9.9.9.9 edns=off 192.0.2.4 edns=on
dns server select 1 1.1.1.1 edns=off 8.8.8.8 edns=on any selected.example
]])
equal(options.endpoint_count, 4)
equal(#options.fallback.upstreams, 4)
equal(options.fallback.upstreams[1].edns, true)
equal(options.fallback.upstreams[2].edns, false)
equal(options.fallback.upstreams[4].edns, true)
equal(options.routes[1].upstreams[1].edns, false)
equal(options.routes[1].upstreams[2].edns, true)
check(options.routes[1] ~= options.fallback)
equal(parse("dns server select 2147483647 192.0.2.1 any .").routes[1].rule_id, 2147483647)

-- Canonical-wire validation prevents separator spoofing and falls closed for
-- unusual label bytes, rather than selecting another route by their text.
local literal = "x._aaplcache._tcp.example.test"
for _, bad in ipairs({
    {canonical_name = string.char(#literal) .. literal .. "\0", qtype = 16},
    {canonical_name = "\3a\0b\0", qtype = 1},
    {canonical_name = "\1*\0", qtype = 1},
    {canonical_name = "\192\0", qtype = 1},
    {canonical_name = "\1x", qtype = 1},
    {canonical_name = "\0trailing", qtype = 1},
    {canonical_name = "\0", qtype = 0},
}) do
    local route, err = p:select(bad, "198.18.32.30")
    check(route == nil and type(err) == "string")
end
for _, source in ipairs({"invalid", "198.18.32.999", "198.18.032.1", "2001:db8::1"}) do
    local route, err = p:select(query("example", 1), source)
    check(route == nil and type(err) == "string")
end

-- Unsupported DNS selection syntax invalidates the entire snapshot, even if
-- another otherwise valid catch-all or fallback could answer the query.
local bad_lines = {
    "dns server", "dns server pp 1", "dns server dhcp lan1",
    "dns server 2001:db8::1", "dns server 192.0.2.999", "dns server 192.00.2.1",
    "dns server 192.0.2.1 nat46=1", "dns server 192.0.2.1 edns=maybe",
    "dns server 192.0.2.1 192.0.2.1", "dns server 192.0.2.1 192.0.2.2 192.0.2.3 192.0.2.4 192.0.2.5",
    "dns server select", "dns server select 2147483648 192.0.2.1 any .",
    "dns server select -1 192.0.2.1 any .", "dns server select 1 pp 1 any .",
    "dns server select 1 dhcp lan1 any .", "dns server select 1 2001:db8::1 any .",
    "dns server select 1 192.0.2.1 edns=maybe any .", "dns server select 1 192.0.2.1 nat46=1 any .",
    "dns server select 1 192.0.2.1 any . restrict pp 1", "dns server select 1 192.0.2.1 any . 198.18.32.0/20 restrict pp 1",
    "dns server select 1 192.0.2.1 192.0.2.2 192.0.2.3 any .", "dns server select 1 192.0.2.1",
    "dns server select 1 192.0.2.1 txt example.com", "dns server select 1 192.0.2.1 any private-config-sentinel*",
    "dns server select 1 192.0.2.1 any . 198.18.32.0/33", "dns server select 1 192.0.2.1 any . 198.18.32.9-198.18.32.1",
    "dns server select 1 192.0.2.1 ptr .", "dns server select 1 192.0.2.1 ptr 0.0.0.0/0",
    "dns server select 1 reject ptr 198.18.32.1", "dns server select 1 reject ptr *.in-addr.arpa",
    "dns server select 1 reject any bad*middle.example", "dns server select 1 reject",
    "no dns server", "no dns server select 1", "no dns server dhcp lan1",
}
for _, line in ipairs(bad_lines) do
    reject_config(line)
    reject_config("dns server select 999 192.0.2.99 any .\n" .. line)
end
reject_config("dns server 1.1.1.1\ndns server 8.8.8.8")
reject_config("dns server select 1 192.0.2.1 any .\ndns server select 01 192.0.2.2 any .")
reject_config("# private-config-sentinel\nconsole prompt TEST")
reject_config("dns server 1.1.1.1", {max_rules = 0})
reject_config("dns server 1.1.1.1", {unknown_limit = 3})
reject_config("dns server 1.1.1.1", "invalid limits")
reject_config("dns server 1.1.1.1", {max_config_bytes = 4})
reject_config("dns server 1.1.1.1", {max_line_bytes = 4})
reject_config("dns server select 1 192.0.2.1 any .\ndns server select 2 192.0.2.2 any .", {max_rules = 1})
reject_config("dns server 1.1.1.1 8.8.8.8", {max_endpoints = 1})
equal(parse("dns server 1.1.1.1 edns=on\ndns server select 1 1.1.1.1 edns=off any .", {max_endpoints = 1}).endpoint_count, 1)
local many = {}
for i = 1, 256 do many[#many + 1] = "dns server select " .. i .. " 192.0.2.1 any ." end
equal(#parse(table.concat(many, "\r\n")).routes, 256)
many[#many + 1] = "dns server select 257 192.0.2.1 any ."
reject_config(table.concat(many, "\n"))
local endpoints = {}
for i = 1, 17 do endpoints[#endpoints + 1] = "dns server select " .. i .. " 192.0.2." .. i .. " any ." end
reject_config(table.concat(endpoints, "\n"))

print("dns policy: " .. checks .. " checks passed")
