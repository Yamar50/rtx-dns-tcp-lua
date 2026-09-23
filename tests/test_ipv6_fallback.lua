package.path = "src/?.lua;" .. package.path
local Policy = require("dns_policy")
local checks = 0
local function check(value, message)
    checks = checks + 1
    assert(value, message or ("IPv6 fallback assertion " .. checks))
    return value
end
local function equal(actual, expected, message)
    check(actual == expected, (message or "values differ") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end
local function parse(config, states, connections, limits)
    local policy, err = Policy.parse(config, limits)
    check(policy, err)
    local runtime = {states = states or {}, connections = connections or {}, calls = {}}
    function runtime:source(kind, id)
        self.calls[#self.calls + 1] = kind .. ":" .. id
        return self.states[kind .. ":" .. id] or {state = "unknown"}
    end
    function runtime:pp_state(id) return self.connections[id] or "unknown" end
    policy:refresh(runtime)
    return policy, runtime
end
local function select(policy, name, qtype, sender)
    local labels = {}
    for label in (name or "www.example.test"):gmatch("[^.]+") do
        labels[#labels + 1] = string.char(#label) .. label
    end
    return policy:select({canonical_name = table.concat(labels) .. "\0", qtype = qtype or 1}, sender or "198.18.0.1")
end
local function available(policy, id, host, name, qtype, sender)
    local route, err = select(policy, name, qtype, sender)
    check(route, err)
    equal(route.policy_id, id)
    check(not route.unavailable and not route.reject)
    equal(route.upstreams[1].host, host)
    return route
end
local function blocked(policy, id, reason, name, qtype, sender)
    local route, err = select(policy, name, qtype, sender)
    check(route, err)
    equal(route.policy_id, id)
    check(route.unavailable and not route.reject)
    equal(#route.upstreams, 0)
    equal(route.unavailable_kind, reason)
    return route
end
local ordinary = "dns server 192.0.2.254\n"
local first = "dns server select 1 2001:db8::53 any .\n"
local last = "dns server select 99 192.0.2.99 any ."

-- A/AAAA/TXT all use IPv4 transport. Every later rule must still match its
-- own type, name, sender and restriction; a candidate's family is independent.
local matching = parse(ordinary .. first .. [[dns server select 2 192.0.2.2 a example.test 198.18.0.1
dns server select 3 192.0.2.3 aaaa example.test
dns server select 4 192.0.2.4 any txt.example.test]])
available(matching, "select:2", "192.0.2.2")
available(matching, "select:3", "192.0.2.3", nil, 28)
available(matching, "select:4", "192.0.2.4", "txt.example.test", 16)
available(matching, "default", "192.0.2.254", "outside.test")
available(matching, "default", "192.0.2.254", nil, 1, "198.18.0.2")
available(matching, "default", "192.0.2.254", nil, 16)
local ptr = parse(ordinary .. first .. "dns server select 2 192.0.2.2 ptr 198.18.0.0/24")
available(ptr, "select:2", "192.0.2.2", "7.0.18.198.in-addr.arpa", 12)
available(ptr, "default", "192.0.2.254", "7.1.18.198.in-addr.arpa", 12)

-- Both mixed fixed candidates and mixed acquired candidates use the IPv4
-- in their own route; they never prefer the next rule or ordinary DNS.
for _, values in ipairs({"2001:db8::1 192.0.2.1", "192.0.2.1 2001:db8::1"}) do
    available(parse(ordinary .. "dns server select 1 " .. values .. " any .\n" .. last), "select:1", "192.0.2.1")
end
local dynamic, runtime = parse(ordinary .. [[dns server select 1 dhcp onu1 192.0.2.10 any .
dns server select 2 pp 1 any .]], {
    ["dhcp:onu1"] = {state = "present", servers = {"fe80::1%onu1"}},
    ["pp:1"] = {state = "present", servers = {"192.0.2.2"}}
})
available(dynamic, "select:2", "192.0.2.2")
local identity = dynamic.rules[1].route
runtime.states["dhcp:onu1"] = {state = "present", servers = {"2001:db8::1", "192.0.2.1"}}
check(dynamic:refresh(runtime))
available(dynamic, "select:1", "192.0.2.1")
equal(dynamic.rules[1].route, identity)
equal(identity.unavailable_kind, nil)
runtime.states["dhcp:onu1"] = {state = "unknown"}
check(dynamic:refresh(runtime))
blocked(dynamic, "select:1", "source_unknown")
runtime.states["dhcp:onu1"] = {state = "absent"}
check(dynamic:refresh(runtime))
available(dynamic, "select:1", "192.0.2.10")
runtime.states["dhcp:onu1"] = {state = "present", servers = {"2001:db8::1"}}
check(dynamic:refresh(runtime))
available(dynamic, "select:2", "192.0.2.2")
equal(dynamic:refresh(runtime), false)
runtime.states["pp:1"] = {state = "present", servers = {"2001:db8::2"}}
check(dynamic:refresh(runtime))
available(dynamic, "default", "192.0.2.254")
runtime.states["pp:1"] = {state = "unknown"}
dynamic:refresh(runtime)
blocked(dynamic, "select:2", "source_unknown")
runtime.states["pp:1"] = {state = "absent"}
dynamic:refresh(runtime)
blocked(dynamic, "select:2", "source_absent")

-- Clear absence retains the existing inline/ordinary alternatives. A chosen
-- alternative that is itself known IPv6-only is subject to the same extension.
available(parse(first .. "dns server dhcp lan1", {
    ["dhcp:lan1"] = {state = "present", servers = {"192.0.2.5"}}
}), "default", "192.0.2.5")
available(parse(first .. "dns server pp 1", {
    ["pp:1"] = {state = "present", servers = {"192.0.2.6"}}
}), "default", "192.0.2.6")
available(parse(ordinary .. "dns server select 1 pp 1 2001:db8::1 any .\n" .. last,
    {["pp:1"] = {state = "absent"}}), "select:99", "192.0.2.99")
available(parse("dns server 2001:db8::254\ndns server select 1 dhcp lan1 any .\n" .. last,
    {["dhcp:lan1"] = {state = "absent"}}), "select:99", "192.0.2.99")
available(parse(ordinary .. "dns server select 1 dhcp lan1 any .\n" .. last,
    {["dhcp:lan1"] = {state = "absent"}}), "select:1", "192.0.2.254")

-- Ordinary fixed > PP > DHCP priority does not become recursive failover.
local normal_priority = parse(first .. [[dns server 2001:db8::254
dns server pp 1
dns server dhcp lan1]], {
    ["pp:1"] = {state = "present", servers = {"192.0.2.2"}},
    ["dhcp:lan1"] = {state = "present", servers = {"192.0.2.3"}}
})
blocked(normal_priority, "default", "ipv6_only")
blocked(parse(first .. "dns server pp 1\ndns server dhcp lan1", {
    ["pp:1"] = {state = "unknown"},
    ["dhcp:lan1"] = {state = "present", servers = {"192.0.2.3"}}
}), "default", "source_unknown")
blocked(parse(first .. "dns server select 2 2001:db8::2 any ."), "select:1", "ipv6_only")
blocked(parse(first .. "dns server 2001:db8::254"), "default", "ipv6_only")
local unmatched = parse("dns server select 1 2001:db8::1 any private.test")
equal(select(unmatched), nil)

-- Explicit denial and unknown semantics remain barriers even after an
-- earlier IPv6-only rule. Restrict DOWN alone means a known nonmatch.
local reject = parse(ordinary .. first .. "dns server select 2 reject any *\n" .. last)
local denied = check(select(reject))
equal(denied.policy_id, "select:2")
check(denied.reject and not denied.unavailable)
for _, row in ipairs({
    {"dns server select 2 2001:db8::2 any . restrict pp 7", "restrict_unknown"},
    {"dns server select 2 future-source argument any decoy.test", "condition_unknown"},
    {"dns server select 2 2001:db8::2 any bad*middle.test", "condition_unknown"},
    {"dns server select 2 2001:db8::2 txt private.test", "condition_unknown"},
    {"dns server select 2 2001:db8::2 any . future-condition", "condition_unknown"},
    {"dns server select 2 2001:db8::2 edns=maybe any .", "options_unsupported"},
    {"dns server select 2 2001:db8::2 nat46=1 any .", "nat46"},
    {"dns server select 2 dhcp lan1 nat46=1 any .", "nat46"},
    {"dns server select 2 pp 1 2001:db8::2 nat46=1 any .", "nat46"},
    {"dns server select 2 dhcp lan1 edns=maybe any .", "source_unsupported"},
    {"dns server select 2 reject any bad*middle.test", "condition_unknown"}
}) do
    blocked(parse(ordinary .. first .. row[1] .. "\n" .. last, {
        ["dhcp:lan1"] = {state = "present", servers = {"2001:db8::1"}},
        ["pp:1"] = {state = "absent"}
    }), "select:2", row[2])
end
local restricted, restrictions = parse(ordinary .. first
    .. "dns server select 2 2001:db8::2 any . restrict pp 7\n" .. last)
blocked(restricted, "select:2", "restrict_unknown")
restrictions.connections["7"] = "down"
check(restricted:refresh(restrictions))
available(restricted, "select:99", "192.0.2.99")
restrictions.connections["7"] = "up"
check(restricted:refresh(restrictions))
available(restricted, "select:99", "192.0.2.99")
restrictions.connections["7"] = "unknown"
check(restricted:refresh(restrictions))
blocked(restricted, "select:2", "restrict_unknown")

-- A malformed acquired list must not become proof of IPv6-only status.
for _, servers in ipairs({{}, {"bad-address"}, {"2001:db8::1", "bad-address"},
    {"fe80::1%future1"}, {[1] = "2001:db8::1", [3] = "bad-address"},
    {[1] = "2001:db8::1", extra = "bad-address"},
    {"2001:db8::1", "2001:db8::2", "2001:db8::3", "2001:db8::4", "2001:db8::5"}}) do
    blocked(parse(ordinary .. first .. "dns server select 2 dhcp lan1 any .\n" .. last,
        {["dhcp:lan1"] = {state = "present", servers = servers}}), "select:2", "source_unknown")
end
local too_many, limits_runtime = parse(first .. [[dns server select 2 dhcp lan1 any private.test
dns server select 3 pp 1 any other.test]], {
    ["dhcp:lan1"] = {state = "present", servers = {"192.0.2.2"}},
    ["pp:1"] = {state = "present", servers = {"192.0.2.3"}}
}, nil, {max_endpoints = 1})
blocked(too_many, "select:1", "endpoint_limit")
limits_runtime.states["pp:1"] = {state = "present", servers = {"192.0.2.2"}}
check(too_many:refresh(limits_runtime))
available(too_many, "select:2", "192.0.2.2", "private.test")

-- Known DHCP grammar localizes an unsupported interface to its conditions.
-- Unknown grammar or reserved/malformed arguments remain opaque barriers.
for _, id in ipairs({"pdp1", "onu2", "lan1.1", "future_interface"}) do
    local unknown, unknown_runtime = parse(ordinary .. first
        .. "dns server select 2 dhcp " .. id .. " any private.test 198.18.0.1\n" .. last)
    blocked(unknown, "select:2", "source_unsupported", "private.test")
    available(unknown, "select:99", "192.0.2.99")
    available(unknown, "select:99", "192.0.2.99", "private.test", 1, "198.18.0.2")
    equal(#unknown_runtime.calls, 0)
    available(parse(ordinary .. "dns server dhcp " .. id), "default", "192.0.2.254")
end
for _, argument in ipairs({"any .", "bad;token any decoy.test", "future-source arg any decoy.test"}) do
    blocked(parse(ordinary .. first .. "dns server select 2 dhcp " .. argument .. "\n" .. last),
        "select:2", "condition_unknown")
end
for _, id in ipairs({"lan1", "lan1/2", "vlan2", "wan1", "onu1", "bridge1"}) do
    available(parse("dns server dhcp " .. id,
        {["dhcp:" .. id] = {state = "present", servers = {"192.0.2.1"}}}), "default", "192.0.2.1")
end
for _, id in ipairs({"lan1", "lan1/2", "lan1.2", "vlan2", "wan1", "onu1", "bridge1", "0", "2"}) do
    available(parse(ordinary .. "dns server select 1 fe80::1%" .. id .. " any ."), "default", "192.0.2.254")
end

-- The documented PDP WAN syntax has a known selection boundary even though
-- acquisition is unsupported. Preserve its conditions; never use an inline
-- default or a supplied runtime value as a substitute for a PDP reader.
local pdp_config = ordinary .. first .. [[dns server select 2 pdp wan1 edns=on 192.0.2.20 edns=off aaaa private.test 198.18.0.1
dns server select 99 192.0.2.99 any .]]
for _, state in ipairs({"present", "absent", "unknown"}) do
    local pdp, pdp_runtime = parse(pdp_config, {
        ["pdp:wan1"] = {state = state, servers = {"192.0.2.21"}}
    })
    blocked(pdp, "select:2", "source_unsupported", "private.test", 28)
    available(pdp, "select:99", "192.0.2.99", "private.test", 1)
    available(pdp, "select:99", "192.0.2.99", "other.test", 28)
    available(pdp, "select:99", "192.0.2.99", "private.test", 28, "198.18.0.2")
    equal(#pdp_runtime.calls, 0)
end
local pdp_default_a = parse(ordinary .. "dns server select 1 pdp wan1 private.test")
blocked(pdp_default_a, "select:1", "source_unsupported", "private.test", 1)
available(pdp_default_a, "default", "192.0.2.254", "private.test", 28)
local pdp_ptr = parse(ordinary .. "dns server select 1 pdp wan1 ptr 198.18.0.0/24")
blocked(pdp_ptr, "select:1", "source_unsupported", "7.0.18.198.in-addr.arpa", 12)
available(pdp_ptr, "default", "192.0.2.254", "7.1.18.198.in-addr.arpa", 12)
local pdp_restrict, pdp_runtime = parse(ordinary .. first
    .. "dns server select 2 pdp wan1 any . restrict pp 7\n" .. last)
blocked(pdp_restrict, "select:2", "restrict_unknown")
pdp_runtime.connections["7"] = "down"
check(pdp_restrict:refresh(pdp_runtime))
available(pdp_restrict, "select:99", "192.0.2.99")
pdp_runtime.connections["7"] = "up"
check(pdp_restrict:refresh(pdp_runtime))
blocked(pdp_restrict, "select:2", "source_unsupported")
equal(#pdp_runtime.calls, 0)
for _, source in ipairs({"pdp", "pdp wan2", "pdp lan1", "pdp any", "pdp bad;token"}) do
    blocked(parse(ordinary .. first .. "dns server select 2 " .. source .. " any decoy.test\n" .. last),
        "select:2", "condition_unknown")
end
blocked(parse(ordinary .. first .. "dns server select 2 pdp wan1 edns=maybe any .\n" .. last),
    "select:2", "source_unsupported")

-- The official ordinary priority is fixed > PP > PDP > DHCP. Unsupported
-- PDP prevents lower-priority DHCP use but cannot obscure a fixed/PP source.
local pdp_ordinary = "dns server pdp wan1 edns=on\ndns server dhcp lan1"
local pdp_states = {
    ["dhcp:lan1"] = {state = "present", servers = {"192.0.2.3"}},
    ["pp:1"] = {state = "present", servers = {"192.0.2.2"}}
}
local pdp_only, pdp_only_runtime = parse(first .. pdp_ordinary, pdp_states)
blocked(pdp_only, "default", "source_unsupported")
equal(pdp_only.fallback.spec.kind, "pdp")
equal(#pdp_only_runtime.calls, 0)
available(parse(ordinary .. pdp_ordinary, pdp_states), "default", "192.0.2.254")
available(parse(first .. "dns server pp 1\n" .. pdp_ordinary, pdp_states), "default", "192.0.2.2")
blocked(parse(first .. "dns server pp 1\n" .. pdp_ordinary,
    {["pp:1"] = {state = "absent"}}), "default", "source_absent")
blocked(parse(ordinary .. "dns server pdp wan2"), "default", "source_unsupported")

print("IPv6-only DNS fallback: " .. checks .. " checks passed")
