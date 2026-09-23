package.path = "src/?.lua;" .. package.path
local Auto = require("auto_config")
local Policy = require("dns_policy")
local Runtime = require("dns_runtime")
local checks = 0
local function check(value, message)
    checks = checks + 1
    assert(value, message or ("NVR compatibility assertion " .. checks))
    return value
end
local function equal(actual, expected, message)
    check(actual == expected, (message or "values differ") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end
local function parse(module, config)
    local value, err = module.parse(config)
    return check(value, err)
end
local function reject(module, config)
    local ok, value, err = pcall(module.parse, config)
    check(ok, "parser must return an error rather than throw")
    equal(value, nil, "unsupported ONU identifier accepted")
    check(type(err) == "string")
end
local function reader(config, responses)
    local calls = {}
    local value, err = Runtime.new(config, function(command, quiet)
        equal(quiet, "off")
        calls[#calls + 1] = command
        if responses[command] == false then return false, "unavailable" end
        return true, responses[command]
    end)
    return check(value, err), calls
end
local function source(runtime, id, state, servers)
    local item = runtime:source("dhcp", id)
    equal(item.state, state, "DHCP source state for " .. id)
    equal(table.concat(item.servers, ","), table.concat(servers or {}, ","))
    return item
end
local function selected(policy, name)
    local labels = {}
    for label in (name or "example.test"):gmatch("[^.]+") do labels[#labels + 1] = string.char(#label) .. label end
    local route, err = policy:select({canonical_name = table.concat(labels) .. "\0", qtype = 1}, "192.0.2.20")
    return check(route, err)
end
local function host(policy, name)
    local route = selected(policy, name)
    check(not route.unavailable and not route.reject, "expected usable IPv4 DNS route")
    return route.upstreams[1].host
end

-- All NVR510 fixtures below are synthetic, not captured from an NVR device.
-- Documentation-range addresses exercise parser compatibility, not hardware
-- or firmware verification. Existing main/relay tests cover refresh wiring.
local function dhcp(id, dns, address)
    local text = "Interface: " .. id .. " primary\nIP Address: " .. (address or "192.0.2.2/24")
        .. "\nDHCP Server: 192.0.2.1\nLease remaining: 1 hour\nCommon information\n"
    for i, ip in ipairs(dns or {}) do text = text .. (i == 1 and "DNS Server: " or "          : ") .. ip .. "\n" end
    return text .. "Default gateway: 192.0.2.1\n"
end
local function dhcpv6(id, dns, state)
    local text = "DHCPv6 status\nLAN1 [server]\n  info-req:\n    state: reply\n    client:\n"
        .. "      DNS server[1]: 2001:db8:ffff::53\n" .. id .. " [client]\n"
        .. "  info-req:\n    state: " .. (state or "established") .. "\n    server:\n"
    for i, ip in ipairs(dns or {}) do text = text .. "      DNS server[" .. i .. "]: " .. ip .. "\n" end
    return text
end

-- Ordinary and selected acquisition use the exact ONU interface and refresh
-- acquired DNS without losing rule identity or using another interface.
local config = [[ip onu1 address dhcp
dns server dhcp onu1
dns server select 10 dhcp onu1 203.0.113.53 any onu.example
]]
local policy = parse(Policy, config)
check(policy.dynamic)
equal(policy.ordinary.dhcp.id, "onu1")
equal(policy.routes[1].spec.id, "onu1")
local responses = {["show status dhcpc"] = dhcp("ONU1", {"198.51.100.53", "198.51.100.54"})}
local runtime, calls = reader(config, responses)
source(runtime, "onu1", "unknown")
check(runtime:refresh())
source(runtime, "onu1", "present", {"198.51.100.53", "198.51.100.54"})
equal(#calls, 1)
equal(calls[1], "show status dhcpc")
check(policy:refresh(runtime))
equal(host(policy), "198.51.100.53")
equal(host(policy, "onu.example"), "198.51.100.53")
local identity = selected(policy, "onu.example")
responses["show status dhcpc"] = dhcp("ONU1", {"198.51.100.55"})
check(runtime:refresh())
check(policy:refresh(runtime))
equal(host(policy, "onu.example"), "198.51.100.55")
equal(selected(policy, "onu.example"), identity)
equal(runtime:refresh(), false)
equal(policy:refresh(runtime), false)
responses["show status dhcpc"] = dhcp("ONU1", {})
runtime:refresh(); source(runtime, "onu1", "absent")
policy:refresh(runtime)
check(selected(policy).unavailable)
equal(host(policy, "onu.example"), "203.0.113.53")
for _, bad in ipairs({false, dhcp("LAN1", {"198.51.100.53"}), dhcp("ONU2", {"198.51.100.53"})}) do
    responses["show status dhcpc"] = bad
    runtime:refresh(); source(runtime, "onu1", "unknown")
    policy:refresh(runtime)
    check(selected(policy, "onu.example").unavailable, "unknown status must not use an inline fallback")
end
responses["show status dhcpc"] = dhcp("ONU1", {"198.51.100.53"}, "not assigned")
runtime:refresh(); source(runtime, "onu1", "absent")

-- Native-form labels and a secondary DHCP slot share the same ONU source.
responses["show status dhcpc"] = [[インタフェース: ONU1 primary
IP アドレス: 192.0.2.2/24
インタフェース: ONU1 secondary
IP アドレス: 192.0.2.3/24
共通情報
DNS サーバ: 198.51.100.53
          : 198.51.100.54
デフォルトゲートウェイ: 192.0.2.1
]]
runtime:refresh(); source(runtime, "onu1", "present", {"198.51.100.53", "198.51.100.54"})
local secondary = reader("ip onu1 secondary address dhcp\ndns server dhcp onu1", responses)
secondary:refresh(); source(secondary, "onu1", "present", {"198.51.100.53", "198.51.100.54"})
local implicit = reader("ip onu1 address dhcp", responses)
implicit:refresh(); source(implicit, "auto", "present", {"198.51.100.53", "198.51.100.54"})
local multiple = reader("ip lan1 address dhcp\nip onu1 address dhcp\ndns server dhcp onu1", responses)
multiple:refresh(); source(multiple, "onu1", "unknown")
responses["show status dhcpc"] = dhcp("ONU1", {"198.51.100.53"})
    .. "Interface: LAN1 primary\nIP Address: 203.0.113.2/24\n"
runtime:refresh(); source(runtime, "onu1", "unknown")
local unconfigured, no_calls = reader("dns server dhcp onu1", {})
unconfigured:refresh(); source(unconfigured, "onu1", "absent"); equal(#no_calls, 0)

-- Only the official ONU name is newly accepted, without adding broad onu*
-- aliases, split ports, or tagged variants to any configuration parser.
for _, id in ipairs({"onu", "onu0", "onu2", "onu01", "onu1/1", "onu1.1", "onu1x", "onu1;show"}) do
    reject(Policy, "dns server dhcp " .. id)
    reject(Policy, "dns server select 1 dhcp " .. id .. " any .")
    reject(Auto, "ip " .. id .. " address 192.0.2.1/24\ndns host " .. id)
    local ok, err = unconfigured:register("dhcp", id)
    equal(ok, nil); check(type(err) == "string")
end
check(unconfigured:register("dhcp", "onu1"))

-- DHCPv6 DNS and %onu1 scope are recognized. Source availability does not
-- imply IPv6 transport support or permit fallback while IPv6 DNS is present.
local v6config = [[ipv6 lan1 dhcp service server
ipv6 onu1 dhcp service client ir=on
dns server select 1 dhcp onu1 203.0.113.53 any .
dns server select 2 203.0.113.54 any .
]]
local v6responses = {["show status ipv6 dhcp"] = dhcpv6("ONU1", {"2001:db8::53", "fe80::1%onu1"})}
local v6runtime, v6calls = reader(v6config, v6responses)
local v6policy = parse(Policy, v6config)
v6runtime:refresh(); source(v6runtime, "onu1", "present", {"2001:db8::53", "fe80::1%onu1"})
v6policy:refresh(v6runtime)
equal(selected(v6policy).rule_id, 2, "IPv6-only acquisition must fallback to a later usable rule")
equal(host(v6policy), "203.0.113.54")
for _, state in ipairs({"renew", "rebind"}) do
    v6responses["show status ipv6 dhcp"] = dhcpv6("ONU1", {"fe80::1%onu1"}, state)
    v6runtime:refresh(); source(v6runtime, "onu1", "present", {"fe80::1%onu1"})
end
v6responses["show status ipv6 dhcp"] = dhcpv6("ONU1", {"2001:db8::53"}, "solicit")
v6runtime:refresh(); source(v6runtime, "onu1", "absent")
v6policy:refresh(v6runtime); equal(host(v6policy), "203.0.113.53")
for _, bad in ipairs({dhcpv6("ONU2", {"2001:db8::53"}), dhcpv6("ONU1", {"fe80::1%onu2"}),
    dhcpv6("ONU1", {"2001:db8::53"}, "unknown-new-state")}) do
    v6responses["show status ipv6 dhcp"] = bad
    v6runtime:refresh(); source(v6runtime, "onu1", "unknown")
    v6policy:refresh(v6runtime); check(selected(v6policy).unavailable)
end
local dualconfig = "ip onu1 address dhcp\n" .. v6config
local dualresponses = {["show status dhcpc"] = dhcp("ONU1", {"198.51.100.53"}),
    ["show status ipv6 dhcp"] = dhcpv6("ONU1", {"fe80::1%onu1"})}
local dualruntime, dualcalls = reader(dualconfig, dualresponses)
dualruntime:refresh(); source(dualruntime, "onu1", "present", {"198.51.100.53", "fe80::1%onu1"})
equal(#dualcalls, 2)
local dualpolicy = parse(Policy, dualconfig)
dualpolicy:refresh(dualruntime); equal(host(dualpolicy), "198.51.100.53")
equal(host(parse(Policy, "dns server fe80::1%onu1 198.51.100.53")), "198.51.100.53")
check(selected(parse(Policy, "dns server fe80::1%onu1")).unavailable)
for _, id in ipairs({"onu", "onu2", "onu01", "onu1/1", "onu1.1"}) do
    local invalid = parse(Policy, "dns server fe80::1%" .. id .. " 198.51.100.53")
    check(selected(invalid).unavailable, "invalid IPv6 scope must not admit trailing IPv4")
end

-- Explicit ONU ACLs include both static subnets and can select a permitted
-- router address for native local DNS. Dynamic ONU ACLs remain unsupported.
local addresses = [[ip onu1 address 192.0.2.42/24
ip onu1 secondary address 198.51.100.42/255.255.255.0
]]
local onu_acl = parse(Auto, addresses .. "dns host onu1\nip host router.home.arpa 192.0.2.42")
equal(table.concat(onu_acl.allowed_clients, ","), "192.0.2.1-192.0.2.255,198.51.100.1-198.51.100.255")
equal(onu_acl.local_dns_host, "192.0.2.42")
local secondary_peer = parse(Auto, addresses .. "dns host 198.51.100.42\nip host router.home.arpa 192.0.2.42")
equal(secondary_peer.local_dns_host, "198.51.100.42")
reject(Auto, "ip onu1 address dhcp\ndns host onu1")
reject(Auto, "ip onu1 address 192.0.2.1/24\nip onu1 secondary address dhcp\ndns host onu1")
reject(Auto, "dns host onu1")

-- The public trial keeps dns host lan's existing scope until ONU inclusion
-- is verified. Adding an ONU must not expand either lan or lan1 authority.
local lan_addresses = [[ip lan1 address 203.0.113.42/24
ip lan1 secondary address 198.18.0.42/24
ip lan1/1 address 198.18.1.42/24
ip vlan1 address 198.18.2.42/24
ip bridge1 address 198.18.3.42/24
ip wan1 address dhcp
]]
local before = parse(Auto, lan_addresses .. "dns host lan\nip host router.home.arpa 203.0.113.42")
equal(#before.allowed_clients, 5)
for _, onu_addresses in ipairs({addresses, "ip onu1 address dhcp\n"}) do
    local after = parse(Auto, onu_addresses .. lan_addresses .. "dns host lan\nip host router.home.arpa 203.0.113.42")
    equal(table.concat(after.allowed_clients, ","), table.concat(before.allowed_clients, ","))
    equal(after.local_dns_host, "203.0.113.42")
    local explicit = parse(Auto, onu_addresses .. lan_addresses .. "dns host lan1\nip host router.home.arpa 203.0.113.42")
    equal(table.concat(explicit.allowed_clients, ","), "203.0.113.1-203.0.113.255,198.18.0.1-198.18.0.255")
    equal(explicit.local_dns_host, "203.0.113.42")
end
reject(Auto, addresses .. "dns host lan")

print("NVR compatibility (synthetic fixtures): " .. checks .. " checks passed")
