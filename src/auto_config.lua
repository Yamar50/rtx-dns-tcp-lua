-- Read-only installation defaults derived from a Yamaha running config.
-- No original config text or unrecognised token is included in returned errors.
-- IPv4 calculations use octets, including on Yamaha's signed-integer Lua 5.1.
local Auto = {}

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
    local parts = {a, b, c, d}
    for i = 1, 4 do
        if #parts[i] > 1 and parts[i]:sub(1, 1) == "0" then return nil end
        parts[i] = decimal(parts[i], 255)
        if parts[i] == nil then return nil end
    end
    return parts
end

local function iptext(parts)
    local words = {}
    for i = 1, 4 do words[i] = string.format("%d", parts[i]) end
    return table.concat(words, ".")
end

local function compare(a, b)
    for i = 1, 4 do
        if a[i] < b[i] then return -1 end
        if a[i] > b[i] then return 1 end
    end
    return 0
end

local function step(parts, amount)
    local result = {parts[1], parts[2], parts[3], parts[4]}
    for i = 4, 1, -1 do
        result[i] = result[i] + amount
        if result[i] >= 0 and result[i] <= 255 then return result end
        result[i] = amount == 1 and 0 or 255
    end
    return nil
end

local function prefix(value)
    if type(value) ~= "string" then return nil end
    if value:match("^%d+$") then return decimal(value, 32) end
    local bytes
    local hex = value:match("^0[xX](%x+)$")
    if hex and #hex <= 8 then
        hex = string.rep("0", 8 - #hex) .. hex
        bytes = {}
        for i = 1, 4 do bytes[i] = tonumber(hex:sub(i * 2 - 1, i * 2), 16) end
    else bytes = ipv4(value) end
    if not bytes then return nil end
    local count, ended = 0, false
    for i = 1, 4 do
        for power = 7, 0, -1 do
            local block = 2 ^ power
            local bit = bytes[i] - bytes[i] % block >= block
            if bit then
                if ended then return nil end
                count = count + 1
                bytes[i] = bytes[i] - block
            else ended = true end
        end
    end
    return count
end

local function interface(value)
    return value and (value:match("^lan%d+$") or value:match("^lan%d+/%d+$")
        or value:match("^lan%d+%.%d+$") or value:match("^vlan%d+$")
        or value == "bridge1" or value == "wan1")
end

local function name(value)
    if type(value) ~= "string" then return nil end
    value = value:lower()
    if value:sub(-1) == "." then value = value:sub(1, -2) end
    if value == "" or #value > 253 or value:find("[^a-z0-9_.%-]")
        or value:sub(1, 1) == "." or value:find("..", 1, true) then return nil end
    for label in value:gmatch("[^.]+") do if #label > 63 then return nil end end
    return value
end

local function reverse(parts)
    return parts[4] .. "." .. parts[3] .. "." .. parts[2] .. "." .. parts[1] .. ".in-addr.arpa"
end

local function valid_ipv6(value)
    if type(value) ~= "string" or #value > 45 or value:find("[^0-9a-fA-F:.]") then return false end
    -- DNS transport remains IPv4; this only validates an AAAA record value.
    local tail = value:match("([^:]+%.[^:]+)$")
    if tail then
        if not ipv4(tail) then return false end
        value = value:sub(1, #value - #tail) .. "0:0"
    end
    local doubled = value:find("::", 1, true)
    if value:find(":::" , 1, true) or (doubled and value:find("::", doubled + 2, true)) then return false end
    if (value:sub(1, 1) == ":" and value:sub(1, 2) ~= "::")
        or (value:sub(-1) == ":" and value:sub(-2) ~= "::") then return false end
    local groups = 0
    for group in value:gmatch("[^:]+") do
        if #group < 1 or #group > 4 or not group:match("^%x+$") then return false end
        groups = groups + 1
    end
    return (doubled and groups < 8) or (not doubled and groups == 8)
end

local function valid_ttl(value)
    if value == nil then return true end
    local digits = value:match("^ttl=(%d+)$")
    if not digits then return false end
    digits = digits:gsub("^0+", "")
    return #digits > 0 and (#digits < 10 or (#digits == 10 and digits <= "4294967295"))
end

local function subnet(tokens, position)
    local address, mask = (tokens[position] or ""):match("^([^/]+)/([^/]+)$")
    if not address then return nil, "automatic DNS ACL requires a static IPv4 address with an explicit mask" end
    address, mask = ipv4(address), prefix(mask)
    if not address or mask == nil then return nil, "automatic DNS ACL found an unsupported IPv4 address or mask" end
    if #tokens ~= position then
        if #tokens ~= position + 2 or tokens[position + 1] ~= "broadcast"
            or not ipv4(tokens[position + 2]) then
            return nil, "automatic DNS ACL found unsupported interface address options"
        end
    end
    local first, last, remaining = {}, {}, mask
    for i = 1, 4 do
        local bits = remaining > 8 and 8 or remaining
        local block = 2 ^ (8 - bits)
        first[i] = address[i] - address[i] % block
        last[i] = first[i] + block - 1
        remaining = remaining - bits
    end
    -- The command reference excludes the network address and limited
    -- broadcast (255.255.255.255), not every directed broadcast address.
    first = step(first, 1)
    if compare(last, {255, 255, 255, 255}) == 0 then last = step(last, -1) end
    return {address = address, first = first, last = last}
end

function Auto.parse(text)
    if type(text) ~= "string" or #text > 1048576 then return nil, "automatic configuration exceeds the input limit" end
    local settings = {listen_host = "0.0.0.0", listen_port = 53, allowed_clients = {},
        local_names = {}, local_zones = {}, local_dns_host = "127.0.0.1", local_dns_port = 53}
    local hosts, interfaces, ordered, names = nil, {}, {}, {}
    local function add_name(value)
        value = name(value)
        if not value then return nil, "automatic local DNS found an unsupported owner name" end
        if not names[value] then
            if #settings.local_names >= 1024 then return nil, "automatic local DNS exceeds the name limit" end
            names[value] = true
            settings.local_names[#settings.local_names + 1] = value
        end
        return true
    end
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        if #line > 4096 then return nil, "automatic configuration exceeds the line limit" end
        line = line:gsub("\r$", "")
        if not line:match("^%s*#") then
            local t = {}
            for token in line:gmatch("%S+") do t[#t + 1] = token end
            local dns_host = t[1] == "dns" and t[2] == "host"
            if dns_host or (t[1] == "no" and t[2] == "dns" and t[3] == "host") then
                if hosts then return nil, "automatic DNS ACL found duplicate dns host settings" end
                hosts = {}
                if not dns_host then
                    if #t ~= 3 then return nil, "automatic DNS ACL found unsupported dns host syntax" end
                    hosts[1] = "any"
                else
                    if #t < 3 or #t > 258 then return nil, "automatic DNS ACL exceeds the host limit or is empty" end
                    for i = 3, #t do hosts[#hosts + 1] = t[i] end
                end
            elseif t[1] == "ip" and interface(t[2])
                and (t[3] == "address" or (t[3] == "secondary" and t[4] == "address")) then
                local id, slot = t[2], t[3] == "secondary" and "secondary" or "primary"
                if not interfaces[id] then
                    if #ordered >= 256 then return nil, "automatic configuration exceeds the interface limit" end
                    interfaces[id] = {}; ordered[#ordered + 1] = id
                end
                if interfaces[id][slot] then return nil, "automatic configuration found duplicate interface addresses" end
                local parsed, err = subnet(t, slot == "primary" and 4 or 5)
                interfaces[id][slot] = parsed or {error = err}
            elseif (t[1] == "ip" and t[2] == "host") or (t[1] == "dns" and t[2] == "static") then
                local short = t[1] == "ip"
                local kind, owner, value, ttl = short and "host" or t[3], t[short and 3 or 4],
                    t[short and 4 or 5], t[short and 5 or 6]
                if #t < (short and 4 or 5) or #t > (short and 5 or 6) or not valid_ttl(ttl) then
                    return nil, "automatic local DNS found unsupported static record syntax"
                end
                local address
                if kind == "host" or kind == "a" then
                    address = ipv4(value)
                    if not address then return nil, "automatic local DNS requires an IPv4 static address" end
                elseif kind == "ptr" then
                    address = ipv4(owner)
                    if not address or not name(value) then return nil, "automatic local DNS requires an IPv4 PTR record" end
                    owner = reverse(address)
                elseif kind == "aaaa" then
                    if not valid_ipv6(value) then return nil, "automatic local DNS found an invalid AAAA value" end
                elseif kind == "mx" or kind == "ns" or kind == "cname" then
                    if not name(value) then return nil, "automatic local DNS found an invalid record target" end
                else return nil, "automatic local DNS found an unsupported static record type" end
                local ok, err = add_name(owner)
                if not ok then return nil, err end
                if kind == "host" then
                    ok, err = add_name(reverse(address))
                    if not ok then return nil, err end
                end
            elseif t[1] == "no" and ((t[2] == "ip" and t[3] == "host")
                or (t[2] == "dns" and t[3] == "static")) then
                return nil, "automatic local DNS requires a current configuration snapshot"
            end
        end
    end
    hosts = hosts or {"any"}
    local ranges, seen = {}, {}
    local function add_range(first, last, all)
        if not first or not last or compare(first, last) > 0 then return true end
        local rule = all and "0.0.0.0/0" or (compare(first, last) == 0 and iptext(first)
            or iptext(first) .. "-" .. iptext(last))
        if not seen[rule] then
            if #ranges >= 256 then return nil, "automatic DNS ACL exceeds the range limit" end
            seen[rule] = true
            settings.allowed_clients[#settings.allowed_clients + 1] = rule
            ranges[#ranges + 1] = {first = first, last = last}
        end
        return true
    end
    local function add_interface(id)
        local entry = interfaces[id]
        if not entry then return nil, "automatic DNS ACL cannot resolve a selected interface address" end
        for _, slot in ipairs({"primary", "secondary"}) do
            local item = entry[slot]
            if item then
                if item.error then return nil, item.error end
                local ok, err = add_range(item.first, item.last)
                if not ok then return nil, err end
            end
        end
        return true
    end
    for _, host in ipairs(hosts) do
        local ok, err
        if host == "none" then return nil, "automatic DNS listener is disabled by dns host none"
        elseif host == "any" then
            if #hosts ~= 1 then return nil, "automatic DNS ACL found unsupported dns host keyword mixing" end
            ok, err = add_range({0, 0, 0, 0}, {255, 255, 255, 255}, true)
        elseif host == "lan" then
            if #hosts ~= 1 then return nil, "automatic DNS ACL found unsupported dns host keyword mixing" end
            for _, id in ipairs(ordered) do
                if id ~= "wan1" then
                    ok, err = add_interface(id)
                    if not ok then return nil, err end
                end
            end
            ok = true
        elseif interface(host) then ok, err = add_interface(host)
        else
            local first, last = host:match("^([^%-]+)%-([^%-]+)$")
            if first then first, last = ipv4(first), ipv4(last)
            else first = ipv4(host); last = first end
            if not first or not last or compare(first, last) > 0 then
                return nil, "automatic DNS ACL found an unsupported host or IPv4 range"
            end
            ok, err = add_range(first, last)
        end
        if not ok then return nil, err end
    end
    if #ranges == 0 then return nil, "automatic DNS ACL resolved to no permitted clients" end
    local function allowed(address)
        for _, range in ipairs(ranges) do
            if compare(address, range.first) >= 0 and compare(address, range.last) <= 0 then return true end
        end
        return false
    end
    if #settings.local_names > 0 and not allowed({127, 0, 0, 1}) then
        local peer
        for _, id in ipairs(ordered) do
            for _, slot in ipairs({"primary", "secondary"}) do
                local item = interfaces[id][slot]
                if item and item.address and allowed(item.address) and not peer then peer = iptext(item.address) end
            end
        end
        if not peer then return nil, "automatic local DNS cannot select a router IPv4 address permitted by dns host" end
        settings.local_dns_host = peer
    end
    return settings
end

return Auto
