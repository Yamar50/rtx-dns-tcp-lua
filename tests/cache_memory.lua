-- Finite cache-memory benchmark; no sockets, files, clocks, or router commands.
-- Compatible with Yamaha's integer-only Lua parser and Lua 5.1 syntax.
-- Run locally: lua tests/cache_memory.lua
-- Bundle: python3 tools/build.py --test tests/cache_memory.lua --output <file>
package.path = "src/?.lua;" .. package.path
local wire, Cache = require("dns_wire"), require("cache")
local checks = 0

local function check(value, message)
    checks = checks + 1
    assert(value, message or "cache-memory assertion failed")
    return value
end

local function u16(n) return string.char((n - n % 256) / 256, n % 256) end

local function query(index, qtype)
    local label = "memory" .. index
    local raw = u16(index) .. "\1\0\0\1\0\0\0\0\0\0"
        .. string.char(#label) .. label .. "\7invalid\0" .. u16(qtype) .. "\0\1"
    return check(wire.parse_query(raw))
end

local function answer_header(q, count)
    return u16(q.id) .. "\129\128\0\1" .. u16(count) .. "\0\0\0\0" .. q.question
end

local function address_answer(q)
    return answer_header(q, 1) .. "\192\12\0\1\0\1\0\0\0\120\0\4\192\0\2\1"
end

local function txt_data(length)
    local parts = {}
    while length > 0 do
        local n = length > 256 and 255 or length - 1
        parts[#parts + 1] = string.char(n) .. string.rep("Z", n)
        length = length - n - 1
    end
    return table.concat(parts)
end

local tiny_txt = "\0\0\16\0\1\0\0\0\120\0\1\0"

local function txt_answer(q, records, full_size)
    local header = answer_header(q, records)
    if not full_size then return header .. string.rep(tiny_txt, records) end
    -- The first records are minimal TXT RRs. The last uses the remaining
    -- space, including legal TXT character-string length octets, up to 65535.
    local body = string.rep(tiny_txt, records - 1)
    local length = 65535 - #header - #body - 11
    check(length > 0, "too many records for maximum-size response")
    local raw = header .. body .. "\0\0\16\0\1\0\0\0\120"
        .. u16(length) .. txt_data(length)
    check(#raw == 65535, "maximum-size response length")
    return raw
end

local function verify_caps(c)
    local stats = c:stats()
    check(stats.entries <= stats.max_entries, "entry cap exceeded")
    check(stats.bytes <= stats.max_bytes, "payload byte cap exceeded")
    check(stats.ttl_fields <= stats.max_ttl_fields, "TTL metadata cap exceeded")
    return stats
end

local function measure(label, scenario)
    collectgarbage("collect")
    local baseline = collectgarbage("count")
    local c = scenario()
    -- Only the cache remains referenced; construction strings, parsed packets,
    -- and discarded entries have left the scenario's stack before this GC.
    collectgarbage("collect")
    local retained = collectgarbage("count")
    local stats = verify_caps(c)
    print("DNSCACHE memory case=" .. label .. " runtime=" .. tostring(_VERSION)
        .. " baseline_kib=" .. tostring(baseline)
        .. " retained_kib=" .. tostring(retained)
        .. " cache_delta_kib=" .. tostring(retained - baseline)
        .. " entries=" .. stats.entries .. " bytes=" .. stats.bytes
        .. " ttl_fields=" .. stats.ttl_fields .. " evictions=" .. stats.evictions
        .. " metadata_rejections=" .. stats.metadata_rejections)
    c = nil
    collectgarbage("collect")
    print("DNSCACHE released case=" .. label .. " lua_kib=" .. tostring(collectgarbage("count")))
end

measure("ordinary_256", function()
    local c = Cache.new()
    for i = 1, 256 do
        local q = query(i, 1)
        check(c:put(q, "memory", address_answer(q), 0))
    end
    check(c:stats().entries == 256)
    check(c:stats().ttl_fields == 256)
    local extra = query(257, 1)
    check(c:put(extra, "memory", address_answer(extra), 0))
    check(c:stats().entries == 256 and c:stats().evictions == 1)
    check(c:get(query(1, 1), "memory", 1) == nil)
    check(c:get(query(2, 1), "memory", 1))
    return c
end)

measure("payload_1MiB", function()
    local c = Cache.new()
    for i = 1, 17 do
        local q = query(i, 16)
        check(c:put(q, "memory", txt_answer(q, 1, true), 0))
    end
    check(c:stats().entries == 16 and c:stats().evictions == 1)
    check(c:stats().bytes == 16 * 65535)
    check(c:stats().ttl_fields == 16)
    check(c:get(query(1, 16), "memory", 1) == nil)
    local last = query(17, 16)
    local hit = check(c:get(last, "memory", 1))
    check(#hit == 65535)
    check(check(wire.validate_response(hit, last)).min_ttl == 119)
    return c
end)

measure("metadata_4096", function()
    local c = Cache.new()
    for i = 1, 9 do
        local q = query(i, 16)
        check(c:put(q, "memory", txt_answer(q, 512, false), 0))
    end
    check(c:stats().ttl_fields == 4096)
    check(c:stats().entries == 8 and c:stats().evictions == 1)
    check(c:get(query(1, 16), "memory", 1) == nil)
    local last = query(9, 16)
    local parsed = check(wire.validate_response(check(c:get(last, "memory", 1)), last))
    check(#parsed.ttl_fields == 512 and parsed.min_ttl == 119)
    return c
end)

measure("payload_and_metadata", function()
    local c = Cache.new()
    for i = 1, 17 do
        local q = query(i, 16)
        check(c:put(q, "memory", txt_answer(q, 256, true), 0))
    end
    check(c:stats().entries == 16 and c:stats().evictions == 1)
    check(c:stats().bytes == 16 * 65535)
    check(c:stats().ttl_fields == 4096)
    return c
end)

measure("oversized_metadata_bypass", function()
    local c = Cache.new()
    local ordinary = query(1, 1)
    local saved = address_answer(ordinary)
    check(c:put(ordinary, "memory", saved, 0))
    local large = query(2, 16)
    local raw = txt_answer(large, 4097, false)
    check(wire.validate_response(raw, large), "oversized cache entry must still be relayable")
    check(not c:put(large, "memory", raw, 0))
    local stats = c:stats()
    check(stats.metadata_rejections == 1 and stats.rejections == 1)
    check(stats.entries == 1 and stats.bytes == #saved and stats.ttl_fields == 1)
    check(c:get(ordinary, "memory", 1))
    return c
end)

print("DNSCACHE memory complete checks=" .. checks)
