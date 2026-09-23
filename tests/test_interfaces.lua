package.path = "src/?.lua;" .. package.path
local Interfaces = require("interfaces")
local checks = 0
local function equal(actual, expected)
    checks = checks + 1
    assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
end

-- Case folding is required for native status headings, while separators
-- distinguish tagged LANs from split LANs throughout all readers.
local names = {
    {"LAN1", "lan1", "lan", 1},
    {"LAN2/16", "lan2/16", "lan_tag", 2, 16},
    {"LAN3.4", "lan3.4", "lan_split", 3, 4},
    {"VLAN4094", "vlan4094", "vlan", 4094},
    {"WAN1", "wan1", "wan", 1},
    {"ONU1", "onu1", "onu", 1},
    {"BRIDGE1", "bridge1", "bridge", 1},
}
for _, item in ipairs(names) do
    local parsed = Interfaces.classify(item[1])
    equal(type(parsed), "table")
    equal(parsed.name, item[2]); equal(parsed.kind, item[3])
    equal(parsed.index, item[4]); equal(parsed.member, item[5])
    for _, purpose in ipairs({"address", "status", "scope"}) do
        equal(Interfaces.valid(item[1], purpose), item[2])
    end
end
for _, bad in ipairs({"", "lan", "lan0", "lan01", "lan1/0", "lan1.0", "lan1/01", "vlan0",
    "wan", "wan0", "wan2", "onu0", "onu2", "bridge0", "bridge2", "lan-1", "lan1:1",
    "lan1/2/3", "lan1.2.3", "pp1", "tunnel1", "loopback1", "null", "bri1", "pri1",
    " lan1", "lan1 ", "lan1;show config", "lan1\0", "lan2147483648", "lan1/2147483648",
    "lan1.2147483648", "vlan2147483648", "lan" .. string.rep("1", 65)}) do
    equal(Interfaces.classify(bad), nil)
    equal(Interfaces.valid(bad, "dns_host"), nil)
end
equal(Interfaces.classify(false), nil)
equal(Interfaces.classify(1), nil)
equal(Interfaces.classify("lan2147483647").index, 2147483647)
equal(Interfaces.classify("lan2147483647/2147483647").member, 2147483647)
equal(Interfaces.valid("lan1", "unknown"), nil)
for _, name in ipairs({"lan1", "lan1/3", "vlan7", "bridge1"}) do
    equal(Interfaces.valid(name, "dns_host"), name)
    equal(Interfaces.valid(name, "dhcp"), name)
    equal(Interfaces.valid(name, "lan_acl"), name)
end
for _, name in ipairs({"wan1", "onu1"}) do
    equal(Interfaces.valid(name, "dns_host"), name)
    equal(Interfaces.valid(name, "dhcp"), name)
    equal(Interfaces.valid(name, "lan_acl"), nil)
end
-- Existing split LAN addresses remain members of the LAN shorthand, but
-- direct native dns host/DHCP source syntax has not been established.
equal(Interfaces.valid("lan1.2", "address"), "lan1.2")
equal(Interfaces.valid("lan1.2", "lan_acl"), "lan1.2")
equal(Interfaces.valid("lan1.2", "dns_host"), nil)
equal(Interfaces.valid("lan1.2", "dhcp"), nil)
equal(Interfaces.pp_id("01"), "1")
equal(Interfaces.pp_id(1), "1")
equal(Interfaces.pp_id("2147483647"), "2147483647")
for _, bad in ipairs({0, -1, "0", "2147483648", "pp1",
    "1;show config", "1.0", " 1", "1 ", string.rep("0", 65) .. "1"}) do
    equal(Interfaces.pp_id(bad), nil)
end
print("interfaces: " .. checks .. " checks passed")
