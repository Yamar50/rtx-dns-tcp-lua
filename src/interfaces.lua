-- Interface spelling shared by config, policy and status readers.
-- This is a syntax classification, not a model or port-existence check.
local M = {}
local MAX_NUMBER, MAX_NAME = 2147483647, 64

local function positive(value, allow_zero_padding)
    if type(value) ~= "string" or #value > MAX_NAME or not value:match("^%d+$") then return nil end
    if not allow_zero_padding and #value > 1 and value:sub(1, 1) == "0" then return nil end
    local clean = value:gsub("^0+", "")
    local bound = "2147483647"
    if clean == "" or #clean > #bound or (#clean == #bound and clean > bound) then return nil end
    return tonumber(clean)
end

function M.classify(value)
    if type(value) ~= "string" or #value > MAX_NAME then return nil end
    value = value:lower()
    local major, minor = value:match("^lan(%d+)/(%d+)$")
    local kind = major and "lan_tag" or nil
    if not major then
        major, minor = value:match("^lan(%d+)%.(%d+)$")
        kind = major and "lan_split" or nil
    end
    if not major then major = value:match("^lan(%d+)$"); kind = major and "lan" or nil end
    if not major then major = value:match("^vlan(%d+)$"); kind = major and "vlan" or nil end
    if not major then
        if value == "wan1" then kind = "wan"
        elseif value == "onu1" then kind = "onu"
        elseif value == "bridge1" then kind = "bridge"
        else return nil end
        major = "1"
    end
    local index = positive(major)
    local member = minor and positive(minor) or nil
    if not index or (minor and not member) then return nil end
    return {name = value, kind = kind, index = index, member = member}
end

-- A name recognized in an address/status does not automatically become a
-- valid argument to every DNS command. In particular, direct dns host and
-- DHCP source syntax for lanN.M has not been established by the manuals.
local address = {lan = true, lan_tag = true, lan_split = true, vlan = true,
    wan = true, onu = true, bridge = true}
local dns = {lan = true, lan_tag = true, vlan = true, wan = true, onu = true, bridge = true}
local purposes = {address = address, status = address, scope = address,
    dhcp = dns, dns_host = dns,
    lan_acl = {lan = true, lan_tag = true, lan_split = true, vlan = true, bridge = true}}

function M.valid(value, purpose)
    local item, allowed = M.classify(value), purposes[purpose]
    return item and allowed and allowed[item.kind] and item.name or nil
end

function M.pp_id(value)
    if type(value) == "number" then
        if value ~= value or value < 1 or value > MAX_NUMBER or value % 1 ~= 0 then return nil end
        value = string.format("%d", value)
    end
    local n = positive(value, true)
    return n and string.format("%d", n) or nil
end

return M
