package.path = "src/?.lua;" .. package.path
local Runtime = require("dns_runtime")
local checks = 0
local function check(value, message)
    checks = checks + 1
    assert(value, message or ("runtime assertion " .. checks))
    return value
end
local function equal(actual, expected)
    check(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
end
local function source(reader, kind, id, state, ips)
    local item = reader:source(kind, id)
    equal(item.state, state)
    check(type(item.reason) == "string")
    equal(table.concat(item.servers, ","), table.concat(ips or {}, ","))
    return item
end
local function new(config, responses, requirements)
    local calls = {}
    local reader, err = Runtime.new(config, function(command, quiet)
        equal(quiet, "off")
        calls[#calls + 1] = command
        local value = responses[command]
        if type(value) == "function" then return value() end
        if value == false then return false, "private-config-sentinel" end
        return true, value
    end, requirements)
    return check(reader, err), calls
end
local function pp(id, state, local_fields, remote_fields)
    return "PP[" .. id .. "]:\nPPPoE session is " .. state .. ".\n"
        .. "IPCP Local: IP-Address " .. (local_fields or "") .. ", Remote: IP-Address "
        .. (remote_fields or "") .. "\nPP IP Address Local: 192.0.2.10, Remote: 192.0.2.1\n"
end
local function dhcp(id, ip, dns, second)
    local text = "Interface: " .. id .. " primary\nIP Address: " .. (ip or "192.0.2.10/24")
        .. "\nDHCP Server: 192.0.2.1\nLease remaining: 1 hour\n"
    if second then text = text .. "Interface: " .. id .. " secondary\nIP Address: 192.0.2.11/24\n" end
    text = text .. "Common information\n"
    if dns then
        for i, address in ipairs(dns) do text = text .. (i == 1 and "DNS Server: " or "          : ") .. address .. "\n" end
    end
    return text .. "Default gateway: 192.0.2.1\n"
end
local function v6(id, dns, state, legacy)
    local text = "DHCPv6 status\nLAN1 [server]\n  info-req:\n    state: reply\n    client:\n"
        .. "      DNS server[1]: 2001:db8:ffff::1\n" .. id .. " [client]\n"
    if not legacy then text = text .. "  info-req:\n" end
    text = text .. "    state: " .. (state or "established") .. "\n    server:\n"
    for i, address in ipairs(dns or {}) do text = text .. "      DNS server[" .. i .. "]: " .. address .. "\n" end
    return text
end

-- Current PP connection state gates even plausible stale local DNS values.
local pp_responses = {['show status pp 1'] = pp("01", "connected",
    "Primary-DNS(198.51.100.1) Secondary-DNS(198.51.100.2)", "Primary-DNS(203.0.113.99)"),
    ['show status pp 2'] = pp("02", "not connected", "Primary-DNS(198.51.100.9)")}
local reader, calls = new([[login password private-config-sentinel
dns server pp 1
dns server select 9 192.0.2.53 any . restrict pp 2
]], pp_responses)
source(reader, "pp", 1, "unknown")
equal(reader:pp_state(1), "unknown")
equal(reader:refresh(), true)
source(reader, "pp", "01", "present", {"198.51.100.1", "198.51.100.2"})
source(reader, "pp", 2, "absent")
equal(reader:pp_state(1), "up"); equal(reader:pp_state(2), "down")
equal(calls[1], "show status pp 1"); equal(calls[2], "show status pp 2")
equal(reader:refresh(), false)
local detached = reader:source("pp", 1)
detached.servers[1], detached.state = "203.0.113.99", "absent"
source(reader, "pp", 1, "present", {"198.51.100.1", "198.51.100.2"})
pp_responses['show status pp 1'] = pp("01", "connected", "", "Primary-DNS(203.0.113.99)")
equal(reader:refresh(), true); source(reader, "pp", 1, "absent"); equal(reader:pp_state(1), "up")
pp_responses['show status pp 1'] = false
equal(reader:refresh(), true); source(reader, "pp", 1, "unknown"); equal(reader:pp_state(1), "unknown")
pp_responses['show status pp 1'] = function() error("private-config-sentinel") end
reader:refresh(); source(reader, "pp", 1, "unknown")
for _, bad in ipairs({pp("02", "connected", "Primary-DNS(198.51.100.1)"),
    pp("01", "connected", "Primary-DNS(198.51.100.1"),
    pp("01", "connected", "Primary-DNS(198.51.100.1) Primary-DNS(198.51.100.2)"),
    pp("01", "connected", "Other-DNS(198.51.100.1)"),
    pp("01", "connected", "Primary-dns(198.51.100.1)"),
    pp("01", "connected", "Primary-DNS(999999999999999999999.1.1.1)"),
    pp("01", "connected", "Primary-DNS(0.0.0.0)"),
    pp("01", "connected", "Primary-DNS(198.051.100.1)"),
    pp("01", "connected", "Primary-DNS(2001:db8::1)"),
    pp("01", "connected", "Primary-DNS(198.51.100.1)") .. "IPCP Local: IP-Address, Remote: IP-Address\n",
    "PP[01]:\nPPPoE session is connected.\n",
    pp("01", "connected", "Primary-DNS(198.51.100.1)") .. "PPPoE session is disconnected.\n",
    "private-config-sentinel", "", "\0"}) do
    pp_responses['show status pp 1'] = bad; reader:refresh(); source(reader, "pp", 1, "unknown")
end

-- UTF-8 and Shift JIS connection phrases are recognized without conversion.
local jp_up = "PPPoEセッションは接続されています"
local jp_down = "PPPoEセッションは接続されていません"
local sj_up = "PPPoE\131\090\131\098\131\086\131\135\131\147\130\205\144\218\145\177\130\179\130\234\130\196\130\162\130\220\130\183"
local sj_down = "PPPoE\131\090\131\098\131\086\131\135\131\147\130\205\144\218\145\177\130\179\130\234\130\196\130\162\130\220\130\185\130\241"
for _, entry in ipairs({{jp_up, "up"}, {sj_up, "up"}, {jp_down, "down"}, {sj_down, "down"}}) do
    pp_responses['show status pp 1'] = "PP[01]:\r\n" .. entry[1]
        .. "\r\nIPCP Local: IP-Address Primary-DNS(198.51.100.1), Remote: IP-Address\r\n"
    reader:refresh(); equal(reader:pp_state(1), entry[2])
end

-- IPv4 common DNS can belong to one configured and observed interface only.
local responses = {['show status dhcpc'] = dhcp("LAN3", nil, {"198.51.100.1", "198.51.100.2"}, true)}
reader, calls = new("ip lan3 address dhcp\ndns server select 10 dhcp lan3 any .", responses)
reader:refresh(); source(reader, "dhcp", "lan3", "present", {"198.51.100.1", "198.51.100.2"})
equal(#calls, 1)
responses['show status dhcpc'] = dhcp("LAN3", nil, {"198.51.100.3"})
equal(reader:refresh(), true); source(reader, "dhcp", "lan3", "present", {"198.51.100.3"})
responses['show status dhcpc'] = dhcp("LAN3", nil, {})
reader:refresh(); source(reader, "dhcp", "lan3", "absent")
responses['show status dhcpc'] = dhcp("LAN3", "not assigned", {"198.51.100.9"})
reader:refresh(); source(reader, "dhcp", "lan3", "absent")
for _, bad in ipairs({"", "unexpected-status", dhcp("LAN2", nil, {"198.51.100.1"}),
    dhcp("LAN3", nil, {"198.51.100.999"}), dhcp("LAN3", nil, {"2001:db8::1"}),
    dhcp("LAN3", nil, {"224.0.0.1"}), dhcp("LAN3", "new-state", {"198.51.100.1"}),
    "Interface: LAN3 primary\nCommon information\nDNS Server: 198.51.100.1\nDefault gateway: 192.0.2.1\n",
    "Interface: LAN3 primary\nIP Address: 192.0.2.1/24\nCommon information\nDNS Server: 198.51.100.1\n",
    (dhcp("LAN3", nil, {"198.51.100.1"}):gsub("DNS Server:", "DNS unknown:")),
    (dhcp("LAN3", nil, {"198.51.100.1"}):gsub("DNS Server:", "Dns List:")),
    (dhcp("LAN3", nil, {"198.51.100.1"}):gsub("DNS Server:", "DNS Server =")),
    dhcp("LAN3", nil, {"198.51.100.1"}) .. "Interface: LAN2 primary\nIP Address: 203.0.113.1/24\n",
    dhcp("LAN3", nil, {"198.51.100.1"}) .. "Interface: LAN3 primary\n",
    string.rep("x", 4097), string.rep("\n", 2049), string.rep("x", 65537)}) do
    responses['show status dhcpc'] = bad; reader:refresh(); source(reader, "dhcp", "lan3", "unknown")
end
responses['show status dhcpc'] = dhcp("LAN3", nil, {"198.51.100.1"})
local multi = new("ip lan2 address dhcp\nip lan3 address dhcp\ndns server dhcp lan3", responses)
multi:refresh(); source(multi, "dhcp", "lan3", "unknown")
local pool = new("ip lan3 address dhcp\nip pp remote address pool dhcp\ndns server dhcp lan3", responses)
pool:refresh(); source(pool, "dhcp", "lan3", "unknown")
local not_client, not_calls = new("dns server dhcp lan2", {})
not_client:refresh(); source(not_client, "dhcp", "lan2", "absent"); equal(#not_calls, 0)

-- Synthetic native-form fixtures contain no actual router addresses or IDs.
local jp_status = [[インタフェース: LAN3 primary
                IP アドレス: 192.0.2.5/24
                DHCP サーバ: 192.0.2.1
               リース残時間: 3時間 3分 6秒
    (タイプ) クライアントID: (01) aa bb cc dd ee ff
インタフェース: LAN3 secondary
                IP アドレス: 192.0.2.6/24
                DHCP サーバ: 192.0.2.1
共通情報
                 DNS サーバ: 198.51.100.1
                           : 198.51.100.2
     デフォルトゲートウェイ: 192.0.2.1
]]
responses['show status dhcpc'] = jp_status
reader:refresh(); source(reader, "dhcp", "lan3", "present", {"198.51.100.1", "198.51.100.2"})
local sj_status = "\131\067\131\147\131\094\131\116\131\070\129\091\131\088: LAN3 primary\n"
    .. "IP \131\065\131\104\131\140\131\088: 192.0.2.5/24\n"
    .. "\139\164\146\202\143\238\149\241\nDNS \131\084\129\091\131\111: 198.51.100.1\n"
    .. " : 198.51.100.2\n\131\102\131\116\131\072\131\139\131\103\131\081\129\091\131\103\131\069\131\070\131\067: 192.0.2.1\n"
responses['show status dhcpc'] = sj_status
reader:refresh(); source(reader, "dhcp", "lan3", "present", {"198.51.100.1", "198.51.100.2"})

-- Client-only IPv6 DNS extraction, including old and current display layouts.
local v6responses = {['show status ipv6 dhcp'] = v6("LAN2", {"2001:db8::53", "fe80::1%lan2"})}
reader, calls = new("ipv6 lan1 dhcp service server\nipv6 lan2 dhcp service client ir=on\ndns server dhcp lan2", v6responses)
reader:refresh(); source(reader, "dhcp", "lan2", "present", {"2001:db8::53", "fe80::1%lan2"})
equal(#calls, 1)
v6responses['show status ipv6 dhcp'] = v6("LAN2", {"2001:db8::54"}, "established", true)
reader:refresh(); source(reader, "dhcp", "lan2", "present", {"2001:db8::54"})
v6responses['show status ipv6 dhcp'] = v6("LAN2", {}, "established")
reader:refresh(); source(reader, "dhcp", "lan2", "absent")
v6responses['show status ipv6 dhcp'] = v6("LAN2", {"2001:db8::54"}, "solicit")
reader:refresh(); source(reader, "dhcp", "lan2", "absent")
for _, state in ipairs({"renew", "rebind"}) do
    v6responses['show status ipv6 dhcp'] = v6("LAN2", {"2001:db8::54"}, state)
    reader:refresh(); source(reader, "dhcp", "lan2", "present", {"2001:db8::54"})
end
for _, bad in ipairs({"", "DHCPv6 status\nLAN1 [server]\nDNS server[1]: 2001:db8::1\n",
    v6("LAN3", {"2001:db8::1"}), v6("LAN2", {"2001:::1"}), v6("LAN2", {"::"}),
    v6("LAN2", {"2001:db8::1%bad;command"}), v6("LAN2", {"2001:db8::1"}, "unknown-new-state"),
    v6("LAN2", {}, "renew"),
    "DHCPv6 status\nLAN2 [client]\nstate: established\nDNS server[1]: 2001:db8::1\n",
    "DHCPv6 status\nLAN2 [client]\nstate: established\nserver:\ndns server[1]: 2001:db8::53\n",
    "DHCPv6 status\nLAN2 [client]\nstate: established\nserver:\nDNS server[1] = not-an-address\n",
    "DHCPv6 status\nLAN2 [client]\nstate: established\nserver:\nDNS new[1]: 2001:db8::1\n"}) do
    v6responses['show status ipv6 dhcp'] = bad; reader:refresh(); source(reader, "dhcp", "lan2", "unknown")
end
v6responses['show status ipv6 dhcp'] = v6("LAN2", {"2001:db8::54"}, "established"):gsub("info%-req:", "prefix:")
    .. "  info-req:\n    state: established\n    server:\n      DNS server[1]: 2001:db8::55\n"
reader:refresh(); source(reader, "dhcp", "lan2", "present", {"2001:db8::54", "2001:db8::55"})

-- Both acquisition families stay associated with the same interface.
local both = {['show status dhcpc'] = dhcp("LAN2", nil, {"198.51.100.1"}),
    ['show status ipv6 dhcp'] = v6("LAN2", {"2001:db8::1"})}
reader = new("ip lan2 address dhcp\nipv6 lan2 dhcp service client\ndns server dhcp lan2", both)
reader:refresh(); source(reader, "dhcp", "lan2", "present", {"198.51.100.1", "2001:db8::1"})
both['show status ipv6 dhcp'] = false
reader:refresh(); source(reader, "dhcp", "lan2", "unknown")
local implicit = new("ip lan3 address dhcp", {['show status dhcpc'] = dhcp("LAN3", nil, {"198.51.100.1"})})
implicit:refresh(); source(implicit, "dhcp", "auto", "present", {"198.51.100.1"})
local none = new("login password private-config-sentinel", {})
none:refresh(); source(none, "dhcp", "auto", "absent")
local auto_multiple = new("ip lan3 address dhcp\nipv6 lan2 dhcp service client", both)
auto_multiple:refresh(); source(auto_multiple, "dhcp", "auto", "unknown")
for _, other in ipairs({"pp", "tunnel"}) do
    local config = "ip lan2 address dhcp\n" .. other .. " select 1\nipv6 " .. other .. " dhcp service client"
    local automatic = new(config, {['show status dhcpc'] = dhcp("LAN2", nil, {"198.51.100.1"})})
    automatic:refresh(); source(automatic, "dhcp", "auto", "unknown")
    local scoped = new(config .. "\ndns server dhcp lan2", {['show status dhcpc'] = dhcp("LAN2", nil, {"198.51.100.1"})})
    scoped:refresh(); source(scoped, "dhcp", "lan2", "present", {"198.51.100.1"})
end
local static_only, static_calls = new("dns server 192.0.2.53", {})
static_only:refresh(); equal(#static_calls, 0)
source(static_only, "dhcp", "auto", "unknown")
-- Documented DNS source kinds share status spelling across native case
-- variants, without allowing unknown identifiers to issue CLI commands.
for _, id in ipairs({"lan1", "lan2/3", "vlan4", "wan1", "onu1", "bridge1"}) do
    local config = "ip " .. id .. " address dhcp\ndns server dhcp " .. id
    local fixture, invoked = new(config, {['show status dhcpc'] = dhcp(id:upper(), nil, {"198.51.100.1"})})
    fixture:refresh(); source(fixture, "dhcp", id, "present", {"198.51.100.1"}); equal(#invoked, 1)
    fixture, invoked = new("ipv6 " .. id .. " dhcp service client\ndns server dhcp " .. id,
        {['show status ipv6 dhcp'] = v6(id:upper(), {"fe80::53%" .. id})})
    fixture:refresh(); source(fixture, "dhcp", id, "present", {"fe80::53%" .. id}); equal(#invoked, 1)
end
for _, id in ipairs({"future1", "tunnel1", "lan0", "lan01", "lan1/0", "wan2", "onu2", "bridge2",
    "lan1.2", "lan2147483648", "lan1/2147483648"}) do
    local fixture, invoked = new("dns server select 1 dhcp " .. id .. " any .\ndns server 192.0.2.53", {})
    fixture:refresh(); source(fixture, "dhcp", id, "unknown"); equal(#invoked, 0)
end
-- A newly seen status interface cannot steal common IPv4 DNS addresses.
local ambiguous = new("ip lan1 address dhcp\nip future1 address dhcp\ndns server dhcp lan1",
    {['show status dhcpc'] = dhcp("LAN1", nil, {"198.51.100.1"})})
ambiguous:refresh(); source(ambiguous, "dhcp", "lan1", "unknown")
local invalid_id, invalid_calls = new("dns server select 1 pp lan1 any .", {})
invalid_id:refresh(); equal(#invalid_calls, 0); source(invalid_id, "pp", "lan1", "unknown")
check(static_only:register("pp", 1)); check(static_only:register("pp", "01"))
static_only:refresh(); equal(#static_calls, 1)
local explicit = new("dns server 192.0.2.53", {['show status pp 1'] = pp("01", "connected")}, {pp = {1}, dhcp = {"lan2"}})
explicit:refresh(); equal(explicit:pp_state(1), "up"); source(explicit, "dhcp", "lan2", "absent")
for _, args in ipairs({{"bad", 1}, {"pp", "1;show config"}, {"pp", "2147483648"}, {"pp", 0},
    {"dhcp", "lan1;show config"}, {"dhcp", "private-config-sentinel"}}) do
    local ok, err = explicit:register(args[1], args[2]); equal(ok, nil); check(type(err) == "string")
end

-- Limits and sanitized diagnostics bound parser work and retained data.
local function reject(config, requirements)
    local ok, value, err = pcall(Runtime.new, config, function() return false end, requirements)
    check(ok); equal(value, nil); check(type(err) == "string")
    check(not err:find("private-config-sentinel", 1, true))
end
reject(false); reject(string.rep("x", 1048577)); reject(string.rep("x", 4097)); reject("\0")
reject("", false); reject("", {unexpected = {1}})
local many = {}
for i = 1, 33 do many[#many + 1] = "dns server select " .. i .. " pp " .. i .. " any ." end
reject(table.concat(many, "\n"))
many = {}
for i = 1, 33 do many[#many + 1] = "ip lan" .. i .. " address dhcp" end
reject(table.concat(many, "\n"))
local large_id = new("dns server pp 2147483647", {['show status pp 2147483647'] = pp("2147483647", "connected")})
large_id:refresh(); equal(large_id:pp_state("2147483647"), "up")
local function private_free(value, seen)
    seen = seen or {}
    if type(value) == "table" and not seen[value] then
        seen[value] = true
        for key, item in pairs(value) do private_free(key, seen); private_free(item, seen) end
    elseif type(value) == "string" then check(not value:find("private-config-sentinel", 1, true)) end
end
private_free(none); private_free(reader); private_free(explicit)
print("dns_runtime: " .. checks .. " checks passed")
