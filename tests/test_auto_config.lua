package.path = "src/?.lua;" .. package.path
local Auto = require("auto_config")
local checks = 0
local function check(value, message)
    checks = checks + 1
    assert(value, message or ("automatic configuration assertion " .. checks))
    return value
end
local function equal(actual, expected, message)
    check(actual == expected, (message or "values differ") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end
local function parse(text)
    local result, err = Auto.parse(text)
    return check(result, err)
end
local function reject(text, expected)
    local ok, result, err = pcall(Auto.parse, text)
    check(ok, "parser threw instead of returning an error")
    check(result == nil and type(err) == "string", "configuration unexpectedly accepted")
    check(not err:find("private%-config%-sentinel"), "input was included in an error")
    if expected then check(err:find(expected, 1, true), "unexpected error category: " .. err) end
end
local function contains(values, wanted)
    for _, value in ipairs(values) do if value == wanted then return true end end
    return false
end

-- Native DNS defaults to any; unrelated dynamically assigned WAN addresses
-- cannot prevent the unchanged config's DNS ACL from being inherited.
local defaults = parse("login password private-config-sentinel\nip lan2 address dhcp\n")
equal(defaults.listen_host, "0.0.0.0")
equal(defaults.listen_port, 53)
equal(defaults.local_dns_host, "127.0.0.1")
equal(defaults.local_dns_port, 53)
equal(#defaults.allowed_clients, 1)
equal(defaults.allowed_clients[1], "0.0.0.0/0")
equal(#defaults.local_names, 0)
equal(#defaults.local_zones, 0)
equal(parse("dns host any").allowed_clients[1], "0.0.0.0/0")
equal(parse("no dns host").allowed_clients[1], "0.0.0.0/0")
reject("dns host none", "disabled")
reject("dns host any lan1", "mixing")
reject("dns host lan 192.0.2.5", "mixing")
reject("dns host any\ndns host lan1", "duplicate")

-- An exact address or range is copied without converting unsigned IPv4 to
-- a signed number. Subnet ACLs exclude network and limited broadcast only.
local direct = parse("dns host 198.51.100.7 192.0.2.254-192.0.3.1 255.255.255.254-255.255.255.255")
equal(direct.allowed_clients[1], "198.51.100.7")
equal(direct.allowed_clients[2], "192.0.2.254-192.0.3.1")
equal(direct.allowed_clients[3], "255.255.255.254-255.255.255.255")
local primary = parse("ip lan1 address 192.0.2.42/24\ndns host lan1")
equal(primary.allowed_clients[1], "192.0.2.1-192.0.2.255")
local secondary = parse([[ip lan1 address 192.0.2.42/255.255.255.0
ip lan1 secondary address 198.51.100.1/0xffffff00
ip lan2 address dhcp
dns host lan1
]])
equal(#secondary.allowed_clients, 2)
equal(secondary.allowed_clients[2], "198.51.100.1-198.51.100.255")
equal(parse("ip lan1 address 200.0.0.1/1\ndns host lan1").allowed_clients[1], "128.0.0.1-255.255.255.254")
equal(parse("ip lan1 address 192.0.2.1/0\ndns host lan1").allowed_clients[1], "0.0.0.1-255.255.255.254")
equal(parse("ip lan1 address 192.0.2.1/0x0\ndns host lan1").allowed_clients[1], "0.0.0.1-255.255.255.254")
equal(parse("ip lan1 address 192.0.2.2/31\ndns host lan1").allowed_clients[1], "192.0.2.3")
reject("ip lan1 address 192.0.2.2/32\ndns host lan1", "no permitted clients")
equal(parse("ip lan1 address 192.0.2.42/24 broadcast 192.0.2.255\ndns host lan1").allowed_clients[1],
    "192.0.2.1-192.0.2.255")

-- Physical, split, tagged, port VLAN, bridge and WAN names stay distinct.
for _, id in ipairs({"lan1", "lan1.1", "lan1/1", "vlan1", "bridge1", "wan1"}) do
    local result = parse("ip " .. id .. " address 192.0.2.1/24\ndns host " .. id)
    equal(result.allowed_clients[1], "192.0.2.1-192.0.2.255")
end
local mixed = parse([[ip lan1 address 192.0.2.1/24
ip lan1/1 address 198.51.100.1/24
ip vlan1 address 203.0.113.1/24
dns host lan1 lan1/1 vlan1 127.0.0.1
]])
equal(#mixed.allowed_clients, 4)
equal(mixed.allowed_clients[2], "198.51.100.1-198.51.100.255")
equal(mixed.allowed_clients[4], "127.0.0.1")
local all_lan = parse([[ip lan1 address 192.0.2.1/24
ip lan1 secondary address 198.51.100.1/24
ip bridge1 address 203.0.113.1/24
ip wan1 address dhcp
dns host lan
]])
equal(#all_lan.allowed_clients, 3)
equal(#parse("ip lan1 address 192.0.2.1/24\ndns host lan1 lan1").allowed_clients, 1)
reject("dns host lan1", "cannot resolve")
reject("dns host lan", "no permitted clients")
reject("ip lan1 address dhcp\ndns host lan1", "static IPv4")
reject("ip lan1 address 192.0.2.1/24\nip lan1 secondary address dhcp\ndns host lan1", "static IPv4")
reject("ip lan1 address 192.0.2.1/24\nip lan2 address dhcp\ndns host lan", "static IPv4")
reject("ip lan1 secondary address 192.0.2.1\ndns host lan1", "explicit mask")
reject("ip lan1 address 192.0.2.1/255.0.255.0\ndns host lan1", "mask")
reject("ip lan1 address 192.0.2.1/0xff00ff00\ndns host lan1", "mask")
reject("ip lan1 address 192.0.2.1/99999999999999999999\ndns host lan1", "mask")
reject("ip lan1 address 192.0.2.1/24 extra=private-config-sentinel\ndns host lan1", "options")
reject("dns host tunnel1")
reject("dns host 192.0.2.0/24")
reject("dns host 192.0.2.8-192.0.2.7")
reject("dns host 192.0.002.7")
reject("dns host private-config-sentinel")

-- All static owner types route exactly; only ip host adds a reverse owner.
-- MX, NS, CNAME and PTR targets do not become additional local names.
local records = parse([[# public example
ip host Router.Home.ARPA. 192.0.2.1
dns static a Printer.Home.ARPA 192.0.2.10 ttl=60
dns static aaaa Printer.Home.ARPA. 2001:db8::10 ttl=4294967295
dns static ptr 192.0.2.20 NAS.Home.ARPA.
dns static cname Files.Home.ARPA NAS.Home.ARPA
dns static mx Home.ARPA mail.example.net
dns static ns Lab.Home.ARPA ns.example.net
]])
equal(#records.local_names, 7)
for _, wanted in ipairs({"router.home.arpa", "1.2.0.192.in-addr.arpa", "printer.home.arpa",
    "20.2.0.192.in-addr.arpa", "files.home.arpa", "home.arpa", "lab.home.arpa"}) do
    check(contains(records.local_names, wanted), wanted)
end
check(not contains(records.local_names, "nas.home.arpa"))
check(not contains(records.local_names, "mail.example.net"))
check(not contains(records.local_names, "10.2.0.192.in-addr.arpa"))
equal(#records.local_zones, 0)
equal(#parse("dns static a rootless 192.0.2.1").local_names, 1)
equal(#parse("dns static a _device._tcp.home.arpa 192.0.2.1").local_names, 1)
for _, value in ipairs({"::", "::1", "2001:db8::1", "2001:db8:0:1:2:3:4:5", "::ffff:192.0.2.1"}) do
    equal(#parse("dns static aaaa host.home.arpa " .. value).local_names, 1)
end
for _, line in ipairs({
    "ip host a.home.arpa 192.0.2.999", "ip host a.home.arpa 2001:db8::1",
    "dns static ptr 1.2.0.192.in-addr.arpa host.home.arpa", "dns static ptr 2001:db8::1 host.home.arpa",
    "dns static txt host.home.arpa text", "dns static a host..home.arpa 192.0.2.1",
    "dns static a .host.home.arpa 192.0.2.1", "dns static a host.home.arpa 192.0.2.1 ttl=0",
    "dns static a host.home.arpa 192.0.2.1 ttl=4294967296", "dns static a host.home.arpa 192.0.2.1 unknown",
    "dns static aaaa host.home.arpa 2001:::1", "dns static aaaa host.home.arpa 2001::1::2",
    "dns static aaaa host.home.arpa 1:2:3:4:5:6:7", "dns static aaaa host.home.arpa 1:2:3:4:5:6:7:8:9",
    "dns static aaaa host.home.arpa ::ffff:192.0.2.999", "dns static cname host.home.arpa private-config-sentinel?",
    "no ip host host.home.arpa", "no dns static a host.home.arpa",
}) do reject(line) end

-- Native DNS should see a permitted self address when loopback is excluded.
local local_peer = parse([[ip lan1 address 192.0.2.42/24
ip lan1 secondary address 198.51.100.42/24
dns host lan1
ip host router.home.arpa 192.0.2.42
]])
equal(local_peer.local_dns_host, "192.0.2.42")
equal(parse([[ip lan1 address 192.0.2.42/24
ip lan1 secondary address 198.51.100.42/24
dns host 198.51.100.42
dns static a router.home.arpa 192.0.2.42
]]).local_dns_host, "198.51.100.42")
equal(parse("dns host 127.0.0.1\nip host router.home.arpa 192.0.2.1").local_dns_host, "127.0.0.1")
reject("dns host 192.0.2.7\nip host router.home.arpa 192.0.2.7", "cannot select a router")
equal(#parse("dns host 192.0.2.7").local_names, 0)

-- Bound retained configuration and never expose unrelated credentials.
local many = {}
for i = 1, 1024 do many[#many + 1] = "dns static a host" .. i .. ".home.arpa 192.0.2.1" end
equal(#parse(table.concat(many, "\n")).local_names, 1024)
many[#many + 1] = "dns static a extra.home.arpa 192.0.2.1"
reject(table.concat(many, "\n"), "name limit")
local acl = {}
for i = 0, 255 do acl[#acl + 1] = "192.0.2." .. i end
equal(#parse("dns host " .. table.concat(acl, " ")).allowed_clients, 256)
acl[#acl + 1] = "198.51.100.1"
reject("dns host " .. table.concat(acl, " "), "host limit")
reject(string.rep("#", 4097), "line limit")
reject(string.rep("\n", 1048577), "input limit")
reject(false, "input limit")
reject("ip host " .. string.rep("x", 64) .. ".home.arpa 192.0.2.1", "owner name")
local function private_free(value)
    if type(value) == "table" then
        for key, item in pairs(value) do private_free(key); private_free(item) end
    elseif type(value) == "string" then check(not value:find("private%-config%-sentinel")) end
end
private_free(defaults)
equal(#parse("  # ignored\r\n dns host any\r\n").allowed_clients, 1)
print("auto_config: " .. checks .. " checks passed")
