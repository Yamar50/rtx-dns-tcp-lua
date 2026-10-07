-- Read-only dynamic DNS snapshots. No configuration or status text is retained.
-- Source availability is separate from the caller's transport capabilities.
-- All numeric parsing is bounded before conversion for Yamaha integer Lua 5.1.
local M, Reader = {}, {}
local Interfaces = require("interfaces")
local StatusText = require("status_text")
Reader.__index = Reader
local MAX_TEXT, MAX_LINE, MAX_SOURCES, MAX_SERVERS = 1048576, 4096, 32, 64

local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
-- CP932 trail bytes can be ASCII letters. Never case-fold those bytes.
local function compact(s)
    s = s:gsub("%s", "")
    return s:find("[\128-\255]") and s or s:lower()
end
local function number(s, max)
    if type(s) ~= "string" or not s:match("^%d+$") then return nil end
    s = s:gsub("^0+", ""); if s == "" then s = "0" end
    local bound = tostring(max)
    if #s > #bound or (#s == #bound and s > bound) then return nil end
    return tonumber(s)
end
local pp_id = Interfaces.pp_id
local function interface(id)
    return Interfaces.valid(id, "status")
end
local function ipv4(s)
    if type(s) ~= "string" then return nil end
    local a, b, c, d = s:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then return nil end
    local parts, values = {a, b, c, d}, {}
    for i = 1, 4 do
        if #parts[i] > 1 and parts[i]:sub(1, 1) == "0" then return nil end
        values[i] = number(parts[i], 255)
        if values[i] == nil then return nil end
    end
    return values
end
local function server(s)
    if type(s) ~= "string" or #s > 110 then return nil end
    s = trim(s):lower()
    local v4 = ipv4(s)
    if v4 then
        if v4[1] == 0 or v4[1] >= 224 then return nil end
        return s
    end
    local address, scope = s:match("^([^%%]+)%%([^%%]+)$")
    if address then
        if not Interfaces.valid(scope, "scope") and not number(scope, 2147483647) then return nil end
    else address = s end
    if #address > 45 or address:find("[^%x:.]") then return nil end
    local tail = address:match("([^:]+%.[^:]+)$")
    if tail then
        if not ipv4(tail) then return nil end
        address = address:sub(1, #address - #tail) .. "0:0"
    end
    local doubled = address:find("::", 1, true)
    if address:find(":::", 1, true) or (doubled and address:find("::", doubled + 2, true))
        or (address:sub(1, 1) == ":" and address:sub(1, 2) ~= "::")
        or (address:sub(-1) == ":" and address:sub(-2) ~= "::") then return nil end
    local groups = 0
    for group in address:gmatch("[^:]+") do
        if #group > 4 or not group:match("^%x+$") then return nil end
        groups = groups + 1
    end
    if not ((doubled and groups < 8) or (not doubled and groups == 8)) then return nil end
    if address:find("[^0:]") == nil then return nil end
    return s
end
local function result(state, reason, servers)
    return {state = state, reason = reason, servers = servers or {}}
end
local function copy(value)
    local out = result(value.state, value.reason)
    out.availability = value.availability
    for i, ip in ipairs(value.servers) do out.servers[i] = ip end
    return out
end
local function add(values, ip)
    for _, old in ipairs(values) do if old == ip then return true end end
    if #values >= MAX_SERVERS then return nil end
    values[#values + 1] = ip
    return true
end
local function lines(text)
    if type(text) ~= "string" or #text == 0 or #text > 65536 or text:find("%z") then return nil end
    local out = {}
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("\r$", "")
        if #line > MAX_LINE or #out >= 2048 then return nil end
        out[#out + 1] = line
    end
    return out
end

-- English keys are case-insensitive; Japanese bytes are matched exactly.
local function lookup(values, sentence)
    local out = {}
    for text, value in pairs(values) do
        local key = compact(text)
        if sentence then key = key:gsub("%.$", "") end
        out[key] = value
    end
    return out
end
local labels = lookup(StatusText.labels)
local missing = lookup(StatusText.missing)
local pp_states = lookup(StatusText.pp_states, true)
local history = lookup(StatusText.history)

local function parse_pp(text, id)
    local ls = lines(text)
    if not ls then return "unknown", result("unknown", "invalid PP status output") end
    local header, state, conflict, historical = false, nil, false, false
    local current_lines = {}
    for _, line in ipairs(ls) do
        local current = line:match("^%s*PP%[(%d+)%]:")
        if current then
            if header or pp_id(current) ~= id then conflict = true end
            header = true
        end
        if history[compact(line)] then historical = true end
        if header and not historical then
            local seen = pp_states[compact(line):gsub("%.$", "")]
            if seen then
                if state and state ~= seen then conflict = true end
                state = seen
            end
            current_lines[#current_lines + 1] = line
        end
    end
    if not header or conflict or not state then
        return "unknown", result("unknown", "unrecognized PP connection state")
    end
    if state == "down" then
        local item = result("absent", "PP is disconnected")
        item.availability = "pp_down"
        return state, item
    end
    if state == "connecting" then
        return state, result("unknown", "PP connection in progress")
    end
    text = table.concat(current_lines, "\n")
    local _, local_count = text:gsub("IPCP%s+Local:", "")
    if local_count ~= 1 then return "up", result("unknown", "missing or duplicate local IPCP status") end
    local part = text:match("IPCP%s+Local:%s*(.-)%s*Remote:")
    if not part then return "up", result("unknown", "missing local IPCP status") end
    local values, found, count = {}, {}, 0
    for kind, ip in part:gmatch("([%a]+)%-DNS%s*%(([^)]*)%)") do
        if (kind ~= "Primary" and kind ~= "Secondary") or found[kind] or not ipv4(trim(ip)) then
            return "up", result("unknown", "invalid local IPCP DNS field")
        end
        ip = server(ip)
        if not ip then return "up", result("unknown", "invalid local IPCP DNS address") end
        found[kind], count = ip, count + 1
    end
    local _, dns_count = part:lower():gsub("dns", "")
    if dns_count ~= count then return "up", result("unknown", "unrecognized local IPCP DNS field") end
    for _, kind in ipairs({"Primary", "Secondary"}) do if found[kind] then add(values, found[kind]) end end
    if #values == 0 then
        local item = result("absent", "local IPCP has no DNS addresses")
        item.availability = "pp_no_dns"
        return "up", item
    end
    return "up", result("present", "local IPCP DNS addresses", values)
end

local function parse_v4(text)
    local ls = lines(text)
    if not ls then return nil end
    local out = {clients = {}, count = 0, servers = {}, common = false, gateway = false}
    local current, dns_continuation
    for _, line in ipairs(ls) do
        local key, value = line:match("^%s*(.-):%s*(.-)%s*$")
        local kind = key and labels[compact(key)] or labels[compact(line)]
        if kind == "interface" then
            local id, slot = value:match("^(%S+)%s+(%a+)$")
            id = interface(id)
            if not id or (slot ~= "primary" and slot ~= "secondary") then return nil end
            if not out.clients[id] then out.clients[id] = {}; out.count = out.count + 1 end
            if out.count > MAX_SOURCES or out.clients[id][slot] then return nil end
            current = {state = "unknown"}; out.clients[id][slot] = current
            dns_continuation = false
        elseif kind == "ip" then
            if not current or current.seen_ip then return nil end
            current.seen_ip = true
            local ip, mask = value:match("^([^/]+)/(%d+)$")
            if ip and ipv4(ip) and number(mask, 32) then
                current.state = ip == "0.0.0.0" and "absent" or "present"
            elseif missing[compact(value)] or value == "0.0.0.0" then current.state = "absent"
            else return nil end
        elseif kind == "common" then
            if out.common then return nil end
            out.common, current, dns_continuation = true, nil, false
        elseif kind == "dns" then
            if not out.common then return nil end
            if missing[compact(value)] or value == "" then dns_continuation = false
            else
                local ip = server(value)
                if not ip or not ipv4(ip) or not add(out.servers, ip) then return nil end
                dns_continuation = true
            end
        elseif key and compact(key) == "" and dns_continuation then
            local ip = server(value)
            if not ip or not ipv4(ip) or not add(out.servers, ip) then return nil end
        elseif kind == "gateway" then
            if not out.common then return nil end
            out.gateway, dns_continuation = true, false
        elseif trim(line) ~= "" then
            dns_continuation = false
            -- Do not silently overlook an unfamiliar additional client block.
            if line:match("%sprimary%s*$") or line:match("%ssecondary%s*$")
                or (key and (key:lower():find("dns", 1, true) or compact(key) == ""))
                or (not key and line:lower():find("dns", 1, true)) then return nil end
        end
    end
    if out.count == 0 then return nil end
    return out
end

local held_states = {established = true, renew = true, rebind = true, renewing = true, rebinding = true}
local empty_states = {init = true, initialize = true, initializing = true, idle = true, solicit = true,
    soliciting = true, request = true, requesting = true, ["info-req"] = true,
    ["information-request"] = true, disabled = true, released = true}
local function parse_v6(text)
    local ls = lines(text)
    if not ls or not text:find("DHCPv6 status", 1, true) then return nil end
    local out, entry, session, reading_server = {}, nil, nil, false
    for _, line in ipairs(ls) do
        local id, role = line:match("^%s*(%S+)%s+%[(%a+)%]%s*$")
        if id then
            id = interface(id)
            entry, session, reading_server = nil, nil, false
            if id and role == "client" then
                if out[id] then return nil end
                entry = {sessions = {}}; out[id] = entry
                session = {servers = {}}; entry.sessions[1] = session
            end
        elseif entry then
            local field, value = line:match("^%s*([^:]+):%s*(.-)%s*$")
            if field then
                field = trim(field)
                if (field == "prefix" or field == "info-req") and value == "" then
                    if session.state or session.server then
                        session = {servers = {}}; entry.sessions[#entry.sessions + 1] = session
                    end
                    reading_server = false
                elseif field == "state" then
                    if session.state then entry.bad = true end
                    session.state = value:lower()
                elseif field == "server" and value == "" then
                    session.server, reading_server = true, true
                elseif field == "client" then reading_server = false
                elseif field:match("^DNS server%[%d+%]$") then
                    local ip = server(value)
                    if not reading_server or not ip or not add(session.servers, ip) then entry.bad = true end
                elseif field:lower():find("dns", 1, true) then entry.bad = true end
            elseif line:lower():find("dns", 1, true) then entry.bad = true end
        end
    end
    for id, item in pairs(out) do
        local values, unknown = {}, item.bad
        for _, s in ipairs(item.sessions) do
            if held_states[s.state] and s.server then
                for _, ip in ipairs(s.servers) do if not add(values, ip) then unknown = true end end
                if s.state ~= "established" and #s.servers == 0 then unknown = true end
            elseif not empty_states[s.state] then unknown = true end
        end
        if unknown then out[id] = result("unknown", "unrecognized DHCPv6 client state")
        elseif #values > 0 then out[id] = result("present", "DHCPv6 client DNS addresses", values)
        else out[id] = result("absent", "DHCPv6 client has no DNS addresses") end
    end
    return out
end

local function combine(a, b)
    if a.state == "unknown" then return a end
    if b.state == "unknown" then return b end
    local values = {}
    for _, item in ipairs({a, b}) do
        for _, ip in ipairs(item.servers) do
            if not add(values, ip) then return result("unknown", "dynamic DNS address limit") end
        end
    end
    if #values == 0 then
        local item = result("absent", "DHCP has no DNS addresses")
        item.availability = a.availability
        return item
    end
    return result("present", "DHCP DNS addresses", values)
end
local function run(reader, command)
    local ok, accepted, output = pcall(reader.command, command, "off")
    if not ok or accepted ~= true or not lines(output) then return nil end
    return output
end
local function v4_source(reader, id, snapshot)
    if not reader.v4[id] and not reader.v4_ambiguous then return result("absent", "IPv4 DHCP client is not configured") end
    if not snapshot then return result("unknown", "unreadable IPv4 DHCP status") end
    local client = snapshot.clients[id]
    if not client then return result("unknown", "missing IPv4 DHCP client status") end
    local has_ip = false
    for _, item in pairs(client) do
        if item.state == "unknown" then return result("unknown", "unrecognized IPv4 DHCP lease state") end
        if item.state == "present" then has_ip = true end
    end
    if not has_ip then
        local item = result("absent", "IPv4 DHCP has no current lease")
        item.availability = "dhcp_no_lease"
        return item
    end
    if reader.v4_ambiguous or reader.v4_count ~= 1 or snapshot.count ~= 1 or not reader.v4[id] then
        return result("unknown", "IPv4 DHCP source is ambiguous")
    end
    if not snapshot.common or not snapshot.gateway then return result("unknown", "incomplete IPv4 DHCP common information") end
    if #snapshot.servers == 0 then
        local item = result("absent", "IPv4 DHCP has no DNS addresses")
        item.availability = "dhcp_no_dns"
        return item
    end
    return result("present", "IPv4 DHCP DNS addresses", snapshot.servers)
end

function Reader:register(kind, id)
    if kind == "pp" then id = pp_id(id)
    elseif kind == "dhcp" then id = id == "auto" and id or Interfaces.valid(id, "dhcp")
    else return nil, "invalid dynamic DNS source kind" end
    if not id then return nil, "invalid dynamic DNS source identifier" end
    if not self.required[kind][id] then
        if self.required_count[kind] >= MAX_SOURCES then return nil, "dynamic DNS source limit" end
        self.required_count[kind] = self.required_count[kind] + 1
        self.required[kind][id] = true
    end
    return true
end

function M.new(config, command, requirements)
    if type(config) ~= "string" or #config > MAX_TEXT or config:find("%z") then return nil, "invalid runtime configuration snapshot" end
    if type(command) ~= "function" then return nil, "runtime command function required" end
    if requirements ~= nil and type(requirements) ~= "table" then return nil, "invalid runtime requirements" end
    local self = setmetatable({command = command, required = {pp = {}, dhcp = {}}, required_count = {pp = 0, dhcp = 0},
        sources = {pp = {}, dhcp = {}}, pp_states = {}, v4 = {}, v4_count = 0, v6 = {},
        configured = {}, initialized = false}, Reader)
    local dns_configured = false
    for line in (config .. "\n"):gmatch("([^\n]*)\n") do
        if #line > MAX_LINE then return nil, "runtime configuration line limit" end
        local t = {}
        if not line:match("^%s*#") then for token in line:gmatch("%S+") do t[#t + 1] = token end end
        if t[1] == "ip" and (t[3] == "address" or (t[3] == "secondary" and t[4] == "address")) then
            local p = t[3] == "address" and 4 or 5
            if t[p] == "dhcp" then
                local id = interface(t[2])
                if id then
                    if not self.v4[id] then self.v4_count = self.v4_count + 1 end
                    self.v4[id], self.configured[id] = true, true
                else self.v4_ambiguous = true end
            end
        elseif t[1] == "ip" and t[2] == "pp" and t[3] == "remote" and t[4] == "address" then
            for i = 5, #t do if t[i] == "dhcp" then self.v4_ambiguous = true end end
        elseif t[1] == "ipv6" and t[3] == "dhcp" and t[4] == "service" and t[5] == "client" then
            local id = interface(t[2])
            if id then self.v6[id], self.configured[id] = true, true
            else self.v6_ambiguous = true end
        elseif t[1] == "dns" and t[2] == "server" then
            dns_configured = true
            local p = t[3] == "select" and 5 or 3
            if t[p] == "pp" or t[p] == "dhcp" then
                local id
                if t[p] == "pp" then id = pp_id(t[p + 1]) else id = Interfaces.valid(t[p + 1], "dhcp") end
                if id then
                    local ok, err = self:register(t[p], id)
                    if not ok then return nil, err end
                end
            end
            for i = p, #t - 2 do
                if t[i] == "restrict" and t[i + 1] == "pp" then
                    local id = pp_id(t[i + 2])
                    if id then
                        local ok, err = self:register("pp", id); if not ok then return nil, err end
                    end
                end
            end
        end
    end
    local count = 0
    for _ in pairs(self.configured) do count = count + 1 end
    if count > MAX_SOURCES then return nil, "DHCP client count limit" end
    if not dns_configured then self:register("dhcp", "auto") end
    for kind, ids in pairs(requirements or {}) do
        if (kind ~= "pp" and kind ~= "dhcp") or type(ids) ~= "table" then return nil, "invalid runtime requirements" end
        for _, id in ipairs(ids) do
            local ok, err = self:register(kind, id); if not ok then return nil, err end
        end
    end
    return self
end

function Reader:source(kind, id)
    if kind == "pp" then id = pp_id(id)
    elseif kind == "dhcp" then id = id == "auto" and id or Interfaces.valid(id, "dhcp") end
    local item = self.sources[kind] and self.sources[kind][id]
    return copy(item or result("unknown", "dynamic DNS source has not been read"))
end
function Reader:pp_state(id) return self.pp_states[pp_id(id)] or "unknown" end
local function same(a, b)
    if not a or a.state ~= b.state or a.reason ~= b.reason or a.availability ~= b.availability or #a.servers ~= #b.servers then return false end
    for i, ip in ipairs(a.servers) do if ip ~= b.servers[i] then return false end end
    return true
end
function Reader:refresh()
    local sources, states, diagnostics, changed = {pp = {}, dhcp = {}}, {}, {}, not self.initialized
    local function save(kind, id, item)
        sources[kind][id] = copy(item)
        if not same(self.sources[kind][id], item) then changed = true end
        if item.state == "unknown" then diagnostics[#diagnostics + 1] = item.reason end
    end
    local pps = {}; for id in pairs(self.required.pp) do pps[#pps + 1] = id end
    table.sort(pps, function(a, b) return tonumber(a) < tonumber(b) end)
    for _, id in ipairs(pps) do
        local text = run(self, "show status pp " .. id)
        local state, item
        if text then state, item = parse_pp(text, id)
        else state, item = "unknown", result("unknown", "unreadable PP status") end
        states[id] = state
        if self.pp_states[id] ~= state then changed = true end
        save("pp", id, item)
    end
    local wanted = {}; for id in pairs(self.required.dhcp) do if id ~= "auto" then wanted[id] = true end end
    if self.required.dhcp.auto then for id in pairs(self.configured) do wanted[id] = true end end
    local need_v4, need_v6 = false, false
    for id in pairs(wanted) do
        if self.v4[id] or self.v4_ambiguous then need_v4 = true end
        if self.v6[id] then need_v6 = true end
    end
    local v4, v6
    if need_v4 then v4 = parse_v4(run(self, "show status dhcpc")) end
    if need_v6 then v6 = parse_v6(run(self, "show status ipv6 dhcp")) end
    local resolved, ordered = {}, {}
    for id in pairs(wanted) do ordered[#ordered + 1] = id end
    table.sort(ordered)
    for _, id in ipairs(ordered) do
        local a = v4_source(self, id, v4)
        local b = result("absent", "DHCPv6 client is not configured")
        if self.v6[id] then b = v6 and v6[id] or result("unknown", "missing DHCPv6 client status") end
        resolved[id] = combine(a, b)
        if self.required.dhcp[id] then save("dhcp", id, resolved[id]) end
    end
    if self.required.dhcp.auto then
        local ids = {}; for id in pairs(self.configured) do ids[#ids + 1] = id end
        local item
        if self.v4_ambiguous or self.v6_ambiguous or #ids > 1 then item = result("unknown", "automatic DHCP source is ambiguous")
        elseif #ids == 1 then item = resolved[ids[1]]
        else item = result("absent", "no DHCP client is configured") end
        save("dhcp", "auto", item)
    end
    self.sources, self.pp_states, self.initialized = sources, states, true
    return changed, diagnostics
end

return M
