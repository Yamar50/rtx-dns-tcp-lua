package.path = "src/?.lua;" .. package.path
local Policy = require("dns_policy")
local checks = 0
local function check(value, message)
    checks = checks + 1
    assert(value, message or ("dynamic policy assertion " .. checks))
    return value
end
local function equal(actual, expected, message)
    check(actual == expected, (message or "values differ") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end
local function parse(config, limits)
    local policy, err = Policy.parse(config, limits)
    return check(policy, err)
end
local function selected(policy, name, qtype, sender)
    local labels = {}
    for label in (name or "example.test"):gmatch("[^.]+") do labels[#labels + 1] = string.char(#label) .. label end
    local route, err = policy:select({canonical_name = table.concat(labels) .. "\0", qtype = qtype or 1}, sender or "198.18.0.1")
    return check(route, err)
end
local states, connections = {}, {}
local runtime = {}
function runtime:source(kind, id)
    return states[kind .. ":" .. tostring(id)] or {state = "unknown"}
end
function runtime:pp_state(id) return connections[tostring(id)] or "unknown" end
local function state(kind, id, status, servers)
    states[kind .. ":" .. tostring(id)] = {state = status, servers = servers or {}}
end
local function host(policy, name, qtype, sender)
    local route = selected(policy, name, qtype, sender)
    check(not route.unavailable and not route.reject)
    return route.upstreams[1].host
end

-- Coexisting ordinary configurations retain independent records and prefer
-- fixed > PP > DHCP. A PP configuration does not escape to DHCP on absence.
local coexist = parse([[dns server dhcp lan2 edns=on
dns server pp 2 edns=off
dns server 192.0.2.1 edns=on]])
check(coexist.dynamic)
check(coexist.ordinary.fixed and coexist.ordinary.pp and coexist.ordinary.dhcp)
state("pp", "2", "present", {"192.0.2.2"})
state("dhcp", "lan2", "present", {"192.0.2.3"})
equal(coexist:refresh(runtime), false)
equal(host(coexist), "192.0.2.1")
local ordinary_pp = parse("dns server dhcp lan2\ndns server pp 2")
check(ordinary_pp:refresh(runtime))
equal(host(ordinary_pp), "192.0.2.2")
state("pp", "2", "absent")
check(ordinary_pp:refresh(runtime))
check(selected(ordinary_pp).unavailable)
equal(#ordinary_pp.fallback.upstreams, 0)
local ordinary_dhcp = parse("dns server dhcp lan2 edns=on")
check(ordinary_dhcp:refresh(runtime))
equal(host(ordinary_dhcp), "192.0.2.3")
check(ordinary_dhcp.fallback.upstreams[1].edns)

-- All selected routes retain their identities as acquired DNS changes.
-- Acquired and inline-default EDNS settings do not overwrite one another.
local p = parse([[dns server 192.0.2.254
dns server select 10 pp 1 edns=on 192.0.2.10 edns=off any pp.example
dns server select 20 dhcp lan1 edns=off 192.0.2.20 edns=on any dhcp.example
dns server select 30 dhcp lan3 any ordinary.example
dns server select 40 pp 3 any wait.example
dns server select 99 192.0.2.99 any .]])
local identities = {}
for i, route in ipairs(p.routes) do identities[i] = route end
state("pp", "1", "present", {"203.0.113.1", "203.0.113.2"})
state("dhcp", "lan1", "present", {"203.0.113.3"})
state("dhcp", "lan3", "absent")
state("pp", "3", "absent")
check(p:refresh(runtime))
equal(host(p, "pp.example"), "203.0.113.1")
check(selected(p, "pp.example").upstreams[1].edns)
equal(#selected(p, "pp.example").upstreams, 2)
equal(host(p, "dhcp.example"), "203.0.113.3")
check(not selected(p, "dhcp.example").upstreams[1].edns)
equal(host(p, "ordinary.example"), "192.0.2.254")
equal(selected(p, "ordinary.example").policy_id, "select:30")
check(selected(p, "wait.example").unavailable)
equal(selected(p, "wait.example").policy_id, "select:40")
state("pp", "1", "absent")
state("dhcp", "lan1", "absent")
check(p:refresh(runtime))
equal(host(p, "pp.example"), "192.0.2.10")
check(not selected(p, "pp.example").upstreams[1].edns)
equal(host(p, "dhcp.example"), "192.0.2.20")
check(selected(p, "dhcp.example").upstreams[1].edns)
equal(p:refresh(runtime), false)
for i, route in ipairs(p.routes) do equal(route, identities[i]) end
-- Ambiguous/read-error state is not absence, and never selects an alternative.
state("pp", "1", "unknown")
state("dhcp", "lan1", "unknown")
state("dhcp", "lan3", "unknown")
check(p:refresh(runtime))
for _, name in ipairs({"pp.example", "dhcp.example", "ordinary.example"}) do
    local route = selected(p, name)
    check(route.unavailable and #route.upstreams == 0)
end
state("pp", "1", "present", {"203.0.113.4"})
check(p:refresh(runtime))
equal(host(p, "pp.example"), "203.0.113.4")
-- Recovery compares actual state, including a relay-enforced outage.
p.routes[1].upstreams, p.routes[1].unavailable, p.routes[1].reason = {}, true, "refresh failed"
check(p:refresh(runtime))
equal(host(p, "pp.example"), "203.0.113.4")

-- The restriction PP is independent of the PP supplying DNS. DOWN skips the
-- rule; unknown cannot skip it; UP uses the already chosen source.
local restrict = parse([[dns server 192.0.2.254
dns server select 1 pp 1 any restricted.example 198.18.0.1-198.18.0.9 restrict pp 7
dns server select 2 192.0.2.2 any .]])
check(restrict.dynamic)
connections["7"] = "down"
check(restrict:refresh(runtime))
equal(selected(restrict, "restricted.example").rule_id, 2)
connections["7"] = "unknown"
check(restrict:refresh(runtime))
check(selected(restrict, "restricted.example").unavailable)
equal(selected(restrict, "unrelated.example").rule_id, 2)
equal(selected(restrict, "restricted.example", 1, "198.18.0.10").rule_id, 2)
connections["7"] = "up"
check(restrict:refresh(runtime))
equal(host(restrict, "restricted.example"), "203.0.113.4")
equal(restrict:refresh(runtime), false)
connections["7"] = "down"
check(restrict:refresh(runtime), "restriction alone changes route generation")

-- IPv6 configuration and acquired values are recognized but do not imply
-- IPv6 TCP support. Same-route IPv4 candidates remain usable.
local ipv6 = parse([[dns server 2001:db8::1 192.0.2.254
dns server select 1 2001:db8::2 aaaa v6.example
dns server select 2 2001:db8::3 192.0.2.2 any mixed.example
dns server select 3 dhcp lan4 192.0.2.3 any acquired.example]])
check(selected(ipv6, "v6.example", 28).unavailable)
equal(host(ipv6, "mixed.example"), "192.0.2.2")
equal(host(ipv6, "elsewhere.example"), "192.0.2.254")
state("dhcp", "lan4", "present", {"2001:db8::4"})
ipv6:refresh(runtime)
check(selected(ipv6, "acquired.example").unavailable, "unsupported transport is not source absence")
state("dhcp", "lan4", "present", {"2001:db8::4", "192.0.2.4"})
check(ipv6:refresh(runtime))
equal(host(ipv6, "acquired.example"), "192.0.2.4")
state("dhcp", "lan4", "present", {"fe80::1%lan4", "192.0.2.4"})
ipv6:refresh(runtime)
equal(host(ipv6, "acquired.example"), "192.0.2.4", "scoped IPv6 does not invalidate a usable IPv4 candidate")
local scoped = parse("dns server fe80::1%lan2 192.0.2.5")
equal(host(scoped), "192.0.2.5")
check(parse("dns server fe80::1%2").fallback.unavailable)
state("dhcp", "lan4", "present", {"fe80::1%bad;command", "192.0.2.4"})
ipv6:refresh(runtime)
check(selected(ipv6, "acquired.example").unavailable)
state("dhcp", "lan4", "absent")
check(ipv6:refresh(runtime))
equal(host(ipv6, "acquired.example"), "192.0.2.3")
local mapped = parse("dns server ::ffff:192.0.2.1")
check(mapped.fallback.unavailable)

-- NAT46 semantics cannot be silently dropped, including on acquired/default
-- candidates. An unneeded NAT46 acquired option does not infect a plain
-- inline alternative when acquisition is definitively absent.
local nat = parse([[dns server 192.0.2.254
dns server select 1 192.0.2.1 nat46=1 any nat.example
dns server select 2 dhcp lan4 nat46=2 192.0.2.2 any dynamic.example
dns server select 3 pp 3 192.0.2.3 nat46=3 any default.example]])
nat:refresh(runtime)
check(selected(nat, "nat.example").unavailable)
equal(host(nat, "dynamic.example"), "192.0.2.2")
check(selected(nat, "default.example").unavailable)
state("dhcp", "lan4", "present", {"192.0.2.4"})
check(nat:refresh(runtime))
check(selected(nat, "dynamic.example").unavailable)
equal(host(nat, "unrelated.example"), "192.0.2.254")

-- Known PTR rejection is IPv4 numeric matching, not text pattern matching.
local ptr = parse([[dns server 192.0.2.254
dns server select 1 reject ptr 198.18.0.1
dns server select 2 reject ptr 198.18.2.0/23]])
check(selected(ptr, "1.0.18.198.in-addr.arpa", 12).reject)
check(selected(ptr, "255.3.18.198.in-addr.arpa", 12).reject)
equal(host(ptr, "1.4.18.198.in-addr.arpa", 12), "192.0.2.254")
equal(host(ptr, "1.0.18.198.in-addr.arpa", 1), "192.0.2.254")
local ptr_unknown = parse("dns server 192.0.2.254\ndns server select 1 reject ptr *.in-addr.arpa")
check(selected(ptr_unknown, "1.0.18.198.in-addr.arpa", 12).unavailable)
check(not selected(ptr_unknown, "1.0.18.198.in-addr.arpa", 12).reject)
equal(host(ptr_unknown, "unrelated.example", 1), "192.0.2.254")

-- Ordered opaque barriers preserve only trustworthy parsed conditions.
local opaque = parse([[dns server 192.0.2.254
dns server select 1 192.0.2.1 edns=maybe aaaa private.example 198.18.0.1
dns server select 2 192.0.2.2 any public.example
dns server select 3 future-source some-argument aaaa decoy.example
dns server select 4 192.0.2.4 any .]])
check(selected(opaque, "private.example", 28).unavailable)
equal(host(opaque, "public.example", 1), "192.0.2.2")
equal(selected(opaque, "private.example", 1).rule_id, 3)
equal(selected(opaque, "private.example", 28, "198.18.0.2").rule_id, 3)
check(selected(opaque, "unrelated.example", 16).unavailable, "unknown source cannot scavenge a type token")
local unknown_type = parse("dns server 192.0.2.254\ndns server select 1 192.0.2.1 txt private.example")
check(selected(unknown_type, "private.example", 16).unavailable)
local opaque_reject = parse("dns server 192.0.2.254\ndns server select 1 reject any bad*middle.example")
check(selected(opaque_reject, "anything.example").unavailable)
check(not selected(opaque_reject, "anything.example").reject)
local bounded_unknown = parse("dns server 192.0.2.254\ndns server select 1 192.0.2.1 any private.example future-condition")
check(selected(bounded_unknown, "private.example").unavailable)
equal(host(bounded_unknown, "public.example"), "192.0.2.254")

-- Implicit DHCP is used only when there are no DNS commands at all. A policy
-- containing only select rules retains precisely those declared routes.
local implicit = parse("ip lan1 address dhcp")
check(implicit.dynamic and #implicit.routes == 1 and implicit.fallback.unavailable)
state("dhcp", "auto", "present", {"192.0.2.100"})
check(implicit:refresh(runtime))
equal(host(implicit), "192.0.2.100")
local only_select = parse("dns server select 1 192.0.2.1 any .")
check(not only_select.dynamic and #only_select.routes == 1 and not only_select.fallback)

-- Invalid runtime data fails closed, replacing rather than retaining stale
-- DNS. Endpoint growth is bounded even when the configuration itself is small.
local invalid = parse("dns server dhcp lan5")
for _, value in ipairs({{}, {"not-an-IP"}, {"192.0.2.1", "192.0.2.2", "192.0.2.3", "192.0.2.4", "192.0.2.5"}}) do
    state("dhcp", "lan5", "present", value)
    invalid:refresh(runtime)
    check(selected(invalid).unavailable)
end
state("dhcp", "lan5", "present", {"192.0.2.5"})
invalid:refresh(runtime)
equal(host(invalid), "192.0.2.5")
invalid:refresh({source = function() error("private-runtime-sentinel") end})
check(selected(invalid).unavailable)
check(not selected(invalid).reason:find("sentinel", 1, true))
local limited = parse("dns server 192.0.2.1\ndns server select 1 dhcp lan5 any private.example", {max_endpoints = 1})
limited:refresh(runtime)
check(selected(limited, "private.example").unavailable)
equal(limited.endpoint_count, 0)
equal(limited.limit_error, "unique DNS endpoint count limit")
state("dhcp", "lan5", "present", {"192.0.2.1"})
check(limited:refresh(runtime))
equal(limited.endpoint_count, 1)
equal(limited.limit_error, nil)
equal(host(limited, "private.example"), "192.0.2.1")

print("dynamic DNS policy: " .. checks .. " checks passed")
