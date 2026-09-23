package.path = "src/?.lua;" .. package.path
local wire, cache = require("dns_wire"), require("cache")
local char = string.char
local count = 0
local function check(value, message)
    count = count + 1
    assert(value, message or ("assertion " .. count .. " failed"))
    return value
end
local function equal(actual, expected, message)
    check(actual == expected, (message or "values differ") .. ": " .. tostring(actual) .. " ~= " .. tostring(expected))
end
local function u16(n) return char((n - n % 256) / 256, n % 256) end
local function u32(n)
    local low = n % 65536
    return u16((n - low) / 65536) .. u16(low)
end
local function name(n)
    local parts = {}
    for label in n:gmatch("[^.]+") do parts[#parts + 1] = char(#label) .. label end
    return table.concat(parts) .. "\0"
end
local function opt(options, flags, payload)
    options = options or ""
    return "\0" .. u16(41) .. u16(payload or 1232) .. u32(flags or 0) .. u16(#options) .. options
end
local function query(n, id, qtype, additional, flags, qclass)
    return u16(id or 123) .. u16(flags or 256) .. u16(1) .. u16(0) .. u16(0)
        .. u16(additional and 1 or 0) .. name(n or "Example.COM")
        .. u16(qtype or 1) .. u16(qclass or 1) .. (additional or "")
end
local function rr(rtype, ttl, rdata, owner, rclass)
    return (owner or "\192\12") .. u16(rtype) .. u16(rclass or 1) .. u32(ttl) .. u16(#rdata) .. rdata
end
local function answer(q, records, additionals, flags)
    return u16(q.id) .. u16(flags or 33152) .. u16(1) .. u16(#records) .. u16(0)
        .. u16(additionals and #additionals or 0) .. q.question
        .. table.concat(records) .. (additionals and table.concat(additionals) or "")
end
local function parsed(raw) return check(wire.parse_query(raw)) end
local function rejected_query(raw)
    local value, err = wire.parse_query(raw)
    check(value == nil and type(err) == "string", "malformed or unsupported query accepted")
end
local function rejected_response(raw, q)
    local value, err = wire.validate_response(raw, q)
    check(value == nil and type(err) == "string", "malformed response accepted")
end
local function cache_bypass(raw, q)
    check(wire.validate_response(raw, q), "cache bypass must still permit forwarding")
    local isolated = cache.new()
    check(not isolated:put(q, "bypass", raw, 0), "nonpositive or ambiguous answer cached")
    equal(isolated:stats().entries, 0)
    check(isolated:get(q, "bypass", 1) == nil)
end

local q = parsed(query())
equal(q.name, "example.com.")
equal(q.canonical_name, "\7example\3com\0")
equal(q.qtype, 1)
check(q.cacheable and q.retryable)
local response = answer(q, {rr(1, 120, char(192, 0, 2, 10))})
local r = check(wire.validate_response(response, q))
equal(r.min_ttl, 120)
equal(r.ttl_fields[1].ttl, 120)
equal(wire.u16(wire.with_id(response, 65535), 1), 65535)
check(wire.validate_response(wire.with_id(response, 999), q, 999))
rejected_response(wire.with_id(response, 999), q)
equal(wire.frame(response):sub(3), response)
equal(wire.u16(wire.frame(response)), #response)

-- Cache IDs, question case, TTL decrement, and exact expiry boundary.
local c = cache.new(256, 1048576)
check(c:put(q, "filtered", response, 1000))
local mixed = parsed(query("eXamPle.coM", 456))
local cached = check(c:get(mixed, "filtered", 1030))
local cached_r = check(wire.validate_response(cached, mixed))
equal(cached_r.id, 456)
equal(cached_r.question, mixed.question)
equal(cached_r.min_ttl, 90)
check(c:get(mixed, "unfiltered", 1030) == nil, "policy cache crossed")
check(c:get(mixed, "filtered", 1119) ~= nil)
check(c:get(mixed, "filtered", 1120) == nil)
equal(c:stats().expirations, 1)
equal(c:stats().entries, 0)
equal(c:stats().bytes, 0)
check(c:put(q, "filtered", response, 1000))
if 1 / 2 ~= 0 then
    -- Yamaha's parser rejects fractional numeric literals, even in branches
    -- that do not execute. Standard Lua additionally exercises fractional time.
    local fractional_time = tonumber("1000.75")
    equal(check(wire.validate_response(check(c:get(q, "filtered", fractional_time)), q)).min_ttl, 120)
else
    equal(check(wire.validate_response(check(c:get(q, "filtered", 1000)), q)).min_ttl, 120)
end
check(c:get(q, "filtered", 999) == nil, "backwards clock served stale data")

-- Every RR TTL is adjusted; compressed CNAME targets remain valid. An
-- additional record with a shorter TTL limits the complete cached message.
local qchain = parsed(query("alias.example.com"))
local target = name("real.example.com")
local chain = answer(qchain, {
    rr(5, 300, target), rr(1, 90, char(192, 0, 2, 1), target),
}, {rr(1, 20, char(192, 0, 2, 2), target)})
check(c:put(qchain, "filtered", chain, 100))
local chain_r = check(wire.validate_response(check(c:get(qchain, "filtered", 119)), qchain))
equal(chain_r.ttl_fields[1].ttl, 281)
equal(chain_r.ttl_fields[2].ttl, 71)
equal(chain_r.ttl_fields[3].ttl, 1)
check(c:get(qchain, "filtered", 120) == nil)
local high_ttl_rr = rr(1, 0, char(192, 0, 2, 10))
high_ttl_rr = high_ttl_rr:sub(1, 6) .. "\128\0\0\0" .. high_ttl_rr:sub(11)
local high_ttl = answer(q, {high_ttl_rr})
equal(check(wire.validate_response(high_ttl, q)).min_ttl, 0)
check(not c:put(q, "filtered", high_ttl, 0))

-- Positive results only; failures, truncation and empty answers are relayed,
-- but are never reused as cache data.
for _, flags in ipairs({33154, 33155, 33664}) do
    local special = answer(q, {rr(1, 120, char(192, 0, 2, 10))}, nil, flags)
    check(wire.validate_response(special, q))
    check(not c:put(q, "filtered", special, 0))
end
check(not c:put(q, "filtered", answer(q, {}), 0))

-- CNAME-only responses can be NODATA at the target or a referral, despite
-- having NOERROR and a nonempty answer section. They are not positive answers
-- to an A/AAAA query and must not enter this positive-only cache.
local qempty = parsed(query("alias.example", 321, 28))
local cname_only = rr(5, 3600, name("empty.example"))
local soa_data = "\0\0" .. u32(1) .. u32(3600) .. u32(600) .. u32(86400) .. u32(60)
local negative_soa = rr(6, 60, soa_data, name("example"))
local nodata = u16(qempty.id) .. u16(33152) .. u16(1) .. u16(1) .. u16(1)
    .. u16(0) .. qempty.question .. cname_only .. negative_soa
check(wire.validate_response(nodata, qempty))
check(not c:put(qempty, "filtered", nodata, 0))
check(not c:put(qempty, "filtered", answer(qempty, {cname_only}), 0))
local direct_cname = parsed(query("alias.example", 322, 5))
check(c:put(direct_cname, "filtered", answer(direct_cname, {cname_only}), 0))
local complete_alias = answer(qempty, {cname_only, rr(28, 30, string.rep("\0", 15) .. "\1", name("empty.example"))})
check(c:put(qempty, "filtered", complete_alias, 0))

-- The requested type must belong to QNAME or its completed CNAME chain.
-- An unrelated answer must not turn CNAME NODATA into a cached positive.
local qvictim = parsed(query("victim.example", 323))
local alias_empty = rr(5, 3600, name("empty.example"))
local unrelated_a = rr(1, 3600, char(192, 0, 2, 66), name("unrelated.example"))
local long_soa = rr(6, 3600, soa_data, name("example"))
local unrelated_nodata = u16(qvictim.id) .. u16(33152) .. u16(1) .. u16(2) .. u16(1)
    .. u16(0) .. qvictim.question .. alias_empty .. unrelated_a .. long_soa
cache_bypass(unrelated_nodata, qvictim)
cache_bypass(answer(qvictim, {unrelated_a}), qvictim)
cache_bypass(answer(qvictim, {alias_empty, unrelated_a}), qvictim)
cache_bypass(answer(qvictim, {alias_empty}, {
    rr(1, 60, "1234", name("empty.example")),
}), qvictim) -- Additional data cannot complete an answer chain.
cache_bypass(answer(qvictim, {
    alias_empty, rr(1, 60, "1234", name("empty.example"), 3),
}), qvictim)
cache_bypass(answer(qvictim, {
    rr(5, 60, name("empty.example"), nil, 3),
    rr(1, 60, "1234", name("empty.example")),
}), qvictim)

-- Shuffling the answer section, using compressed target suffixes, and case
-- changes do not alter reachability. Identical CNAME duplicates are harmless.
local middle_name, final_name = name("middle.example"), name("final.example")
local shuffled = answer(qvictim, {
    rr(1, 60, "1234", final_name),
    rr(5, 60, name("FINAL.example"), middle_name),
    rr(5, 60, name("MIDDLE.EXAMPLE")),
    rr(5, 60, middle_name),
})
check(c:put(qvictim, "shuffled", shuffled, 0))
check(wire.validate_response(check(c:get(qvictim, "shuffled", 59)), qvictim))
-- victim.example's example suffix begins at wire offset 19.
local compressed = answer(qvictim, {
    rr(5, 60, "\5empty\192\19"),
    rr(1, 60, "1234", name("EMPTY.example")),
})
check(c:put(qvictim, "compressed", compressed, 0))
check(wire.validate_response(check(c:get(qvictim, "compressed", 59)), qvictim))
-- A target may also be an entire prior owner name, with the target RR first.
local prior_target = answer(qvictim, {
    rr(1, 60, "1234", final_name),
    rr(5, 60, u16(49152 + 12 + #qvictim.question)),
})
check(c:put(qvictim, "prior-target", prior_target, 0))

-- Conflicting aliases, CNAME/data coexistence, loops, and unfinished chains
-- stay forwardable, but none establishes an unambiguous positive cache entry.
for _, records in ipairs({
    {alias_empty, rr(5, 60, final_name), rr(1, 60, "1234", final_name)},
    {rr(5, 60, final_name), rr(1, 60, "1234"), rr(1, 60, "1234", final_name)},
    {rr(5, 60, middle_name), rr(5, 60, final_name, middle_name),
        rr(16, 60, "\1x", middle_name), rr(1, 60, "1234", final_name)},
    {rr(5, 60, qvictim.canonical_name), unrelated_a},
    {rr(5, 60, middle_name), rr(5, 60, qvictim.canonical_name, middle_name), unrelated_a},
    {rr(5, 60, middle_name), rr(5, 60, final_name, middle_name), unrelated_a},
}) do
    cache_bypass(answer(qvictim, records), qvictim)
end
cache_bypass(answer(direct_cname, {
    rr(5, 60, middle_name), rr(5, 60, final_name),
}), direct_cname)
cache_bypass(answer(direct_cname, {rr(5, 60, final_name, middle_name)}), direct_cname)
cache_bypass(answer(direct_cname, {rr(5, 60, direct_cname.canonical_name)}), direct_cname)
cache_bypass(answer(direct_cname, {rr(5, 60, final_name), rr(1, 60, "1234")}), direct_cname)
local direct_any = parsed(query("victim.example", 324, 255))
check(not direct_any.cacheable)
cache_bypass(answer(direct_any, {rr(1, 60, "1234")}), direct_any)

-- A long reversed chain exercises indexed lookup rather than answer-order
-- dependence or repeated whole-section scans. The record count bounds walks.
local qdeep = parsed(query("hop0.example", 325))
local reverse_chain = {rr(1, 60, "1234", name("hop512.example"))}
for i = 511, 0, -1 do
    reverse_chain[#reverse_chain + 1] = rr(5, 60, name("hop" .. (i + 1) .. ".example"),
        name("hop" .. i .. ".example"))
end
check(c:put(qdeep, "deep", answer(qdeep, reverse_chain), 0))
check(wire.validate_response(check(c:get(qdeep, "deep", 59)), qdeep))
reverse_chain[1] = rr(5, 60, name("hop0.example"), name("hop512.example"))
cache_bypass(answer(qdeep, reverse_chain), qdeep)

-- Maximum-length names remain valid when the response owner is compressed.
-- Count pointer hops separately from the up-to-127 ordinary labels.
local qlong = parsed(query(string.rep("a.", 127), 65432))
equal(#qlong.canonical_name, 255)
local long_answer = answer(qlong, {rr(1, 30, char(192, 0, 2, 1))})
check(wire.validate_response(long_answer, qlong))
check(c:put(qlong, "filtered", long_answer, 0))
check(wire.validate_response(check(c:get(qlong, "filtered", 29)), qlong))
local pointer_records, previous_owner = {}, 12
local next_owner = 12 + #qlong.question
for i = 1, 129 do
    local record = rr(1, 30, char(192, 0, 2, 1), u16(49152 + previous_owner))
    pointer_records[i] = record
    previous_owner, next_owner = next_owner, next_owner + #record
    if i == 128 then check(wire.validate_response(answer(qlong, pointer_records), qlong)) end
end
rejected_response(answer(qlong, pointer_records), qlong)

-- LRU: reads promote the requested item, writes do not scan all entries.
local lru = cache.new(2, 1048576)
local qa, qb, qc = parsed(query("a.example")), parsed(query("b.example")), parsed(query("c.example"))
local ra = answer(qa, {rr(1, 30, char(192, 0, 2, 1))})
local rb = answer(qb, {rr(1, 30, char(192, 0, 2, 2))})
local rc = answer(qc, {rr(1, 30, char(192, 0, 2, 3))})
check(lru:put(qa, "p", ra, 0)); check(lru:put(qb, "p", rb, 0))
check(lru:get(qa, "p", 1)); check(lru:put(qc, "p", rc, 1))
check(lru:get(qb, "p", 1) == nil)
check(lru:get(qa, "p", 1)); check(lru:get(qc, "p", 1))
equal(lru:stats().evictions, 1)
equal(lru:stats().entries, 2)
check(lru:put(qa, "p", ra, 2))
equal(lru:stats().entries, 2)
equal(lru:stats().bytes, #ra + #rc)
local bytecap = cache.new(256, #ra + #rb - 1)
check(bytecap:put(qa, "p", ra, 0)); check(bytecap:put(qb, "p", rb, 0))
equal(bytecap:stats().entries, 1)
equal(bytecap:stats().bytes, #rb)
check(not cache.new(256, #ra - 1):put(qa, "p", ra, 0))
check(not cache.new(0, 1048576):put(qa, "p", ra, 0))
-- Expired LRU victims are reclaimed on insertion; unrelated expired entries
-- may remain until read/evicted, but both configured caps always hold.
check(bytecap:put(qa, "p", ra, 31))
equal(bytecap:stats().expirations, 1)

-- EDNS empty OPT is rebuilt on a cache hit, never TTL-aged or copied as state.
local qe = parsed(query("example.com", 42, 1, opt()))
check(qe.cacheable)
local re = answer(qe, {rr(1, 45, char(192, 0, 2, 20))}, {opt(nil, 0, 4096)})
check(c:put(qe, "filtered", re, 100))
local re_cached = check(wire.validate_response(check(c:get(qe, "filtered", 110)), qe))
equal(re_cached.min_ttl, 35)
equal(re_cached.edns_udp_size, 1232)
equal(re_cached.edns_version, 0)
check(not re_cached.do_bit)
local qe_size = parsed(query("example.com", 42, 1, opt(nil, 0, 4096)))
check(c:get(qe_size, "filtered", 110) == nil)
check(c:get(q, "filtered", 110) == nil)
for _, specialopt in ipairs({
    opt(nil, 32768), -- DNSSEC DO
    opt(u16(8) .. u16(4) .. "\0\1\0\0"), -- ECS
    opt(u16(10) .. u16(8) .. "12345678"), -- COOKIE
    opt(u16(12) .. u16(2) .. "\0\0"), -- padding (conservative bypass)
}) do
    local qs = parsed(query("example.com", 42, 1, specialopt))
    check(not qs.cacheable and qs.retryable)
    local rs = answer(qs, {rr(1, 45, char(192, 0, 2, 20))}, {specialopt})
    check(wire.validate_response(rs, qs))
    check(not c:put(qs, "filtered", rs, 100))
end
check(not parsed(query("example.com", 42, 48)).cacheable)
check(not parsed(query("example.com", 42, 1, nil, 272)).cacheable) -- CD
check(not parsed(query("example.com", 42, 1, nil, 288)).cacheable) -- AD
rejected_query(query("example.com", 42, 1, opt(u16(11) .. u16(0))))
rejected_response(answer(qe, {rr(1, 45, char(192, 0, 2, 20))}, {opt(u16(11) .. u16(2) .. u16(100))}), qe)
rejected_query(query("example.com", 42, 1, opt(u16(8) .. u16(99) .. "x")))
rejected_query(query("example.com", 42, 1, opt(nil, 65536))) -- EDNS version 1
rejected_query(query("example.com", 42, 252))
rejected_query(query("example.com", 42, 251))
rejected_query(query("example.com", 42, 1, nil, 10240)) -- UPDATE
rejected_query(query("example.com", 42, 1, rr(250, 0, "opaque")))
rejected_query(query("example.com", 42, 1, rr(24, 0, "opaque")))

-- Maximum-size response: valid TXT chunks add up to 65,535 bytes.
local qbig = parsed(query("large.example", 65535, 16))
local desired = 65535 - (12 + #qbig.question + 12)
local chunks, remaining = {}, desired
while remaining > 0 do
    local length = remaining > 256 and 255 or remaining - 1
    chunks[#chunks + 1] = char(length) .. string.rep("Z", length)
    remaining = remaining - length - 1
end
local big = answer(qbig, {rr(16, 120, table.concat(chunks))})
equal(#big, 65535)
equal(wire.frame(big):sub(1, 2), "\255\255")
check(wire.validate_response(big, qbig))
check(c:put(qbig, "filtered", big, 1))
equal(check(c:get(qbig, "filtered", 1)), big)
equal(#check(c:get(qbig, "filtered", 2)), 65535)
check(wire.frame(big .. "x") == nil)

-- Many small records stress TTL metadata rather than payload size. Check the
-- first, middle and last TTL and the exact saved-byte limit independently of
-- the single large TXT test above. Unknown RDATA stays byte-for-byte opaque.
local qpacked = parsed(query(".", 65000, 16))
local packed_record = rr(16, 120, "\0", "\0")
local packed_room = 65535 - 12 - #qpacked.question
local packed_count = (packed_room - packed_room % #packed_record) / #packed_record
local packed = u16(qpacked.id) .. u16(33152) .. u16(1) .. u16(packed_count)
    .. u16(0) .. u16(0) .. qpacked.question .. string.rep(packed_record, packed_count)
local packed_cache = cache.new(256, #packed, packed_count)
check(packed_cache:put(qpacked, "packed", packed, 0))
local packed_result = check(wire.validate_response(check(packed_cache:get(qpacked, "packed", 119)), qpacked))
equal(#packed_result.records, packed_count)
equal(packed_result.ttl_fields[1].ttl, 1)
equal(packed_result.ttl_fields[(packed_count - packed_count % 2) / 2].ttl, 1)
equal(packed_result.ttl_fields[packed_count].ttl, 1)
equal(packed_cache:stats().bytes, #packed)
check(packed_cache:put(qa, "packed", ra, 119))
equal(packed_cache:stats().entries, 1)
equal(packed_cache:stats().bytes, #ra)
check(packed_cache:get(qpacked, "packed", 119) == nil)

-- A separate metadata cap bounds total retained TTL tables, even when many
-- tiny RRs fit below the saved-message byte cap. Eviction shares the same LRU.
local metadata_cache = cache.new(256, 1048576, 3)
local two_a = answer(qa, {rr(1, 30, "1234"), rr(1, 30, "5678")})
local two_b = answer(qb, {rr(1, 30, "1234"), rr(1, 30, "5678")})
check(metadata_cache:put(qa, "metadata", two_a, 0))
check(metadata_cache:put(qb, "metadata", rb, 0))
equal(metadata_cache:stats().ttl_fields, 3)
check(metadata_cache:get(qa, "metadata", 1))
check(metadata_cache:put(qc, "metadata", rc, 1))
equal(metadata_cache:stats().entries, 2)
equal(metadata_cache:stats().ttl_fields, 3)
check(metadata_cache:get(qb, "metadata", 1) == nil)
check(metadata_cache:get(qa, "metadata", 1))
equal(metadata_cache:stats().evictions, 1)
check(metadata_cache:put(qb, "metadata", two_b, 1))
equal(metadata_cache:stats().ttl_fields, 2)
equal(metadata_cache:stats().entries, 1)
equal(metadata_cache:stats().evictions, 3)
check(metadata_cache:put(qb, "metadata", rb, 2))
equal(metadata_cache:stats().ttl_fields, 1, "replacement releases old TTL fields")
check(metadata_cache:get(qb, "metadata", 32) == nil)
equal(metadata_cache:stats().ttl_fields, 0, "expiry releases TTL fields")
local metadata_default = cache.new()
equal(metadata_default:stats().max_ttl_fields, 4096)
check(not metadata_default:put(qpacked, "metadata", packed, 0))
equal(metadata_default:stats().metadata_rejections, 1)
equal(metadata_default:stats().entries, 0)
equal(metadata_default:stats().bytes, 0)
equal(metadata_default:stats().ttl_fields, 0)
check(not cache.new(256, 1048576, 0):put(qa, "metadata", ra, 0))
check(not pcall(cache.new, 256, 1048576, -1))
local qunknown = parsed(query("opaque.example", 4321, 65280))
local opaque_data = "\192\0\255\255\0literal binary data"
local opaque_response = answer(qunknown, {rr(65280, 30, opaque_data)})
check(c:put(qunknown, "opaque", opaque_response, 100))
local opaque_hit = check(c:get(qunknown, "opaque", 110))
local opaque_parsed = check(wire.validate_response(opaque_hit, qunknown))
equal(opaque_hit:sub(opaque_parsed.records[1].rdata, opaque_parsed.records[1].finish), opaque_data)
equal(opaque_parsed.min_ttl, 20)
local no_recursion = parsed(query("opaque.example", 4321, 65280, nil, 0))
check(c:get(no_recursion, "opaque", 110) == nil, "RD variants must not share cache entries")
local wrong_type = parsed(query("opaque.example", 4321, 1))
rejected_response(opaque_response, wrong_type)
-- The relay supports only IN questions. Other classes must fail parsing and
-- yield FORMERR through the same error-response path as other bad queries.
for _, qclass in ipairs({0, 2, 3, 4, 254, 255, 256, 65535}) do
    local wrong_class_raw = query("opaque.example", 4321, 65280, nil, nil, qclass)
    rejected_query(wrong_class_raw)
    local formerr = check(wire.error_response(wrong_class_raw, 1))
    equal(wire.u16(formerr, 1), 4321)
    equal(formerr:byte(4) % 16, 1)
    equal(wire.u16(formerr, 5), 0)
end
local wrong_class_response = opaque_response:sub(1, qunknown.question_end - 2)
    .. u16(3) .. opaque_response:sub(qunknown.question_end + 1)
rejected_response(wrong_class_response, qunknown)

-- Bounded malformed packet handling: missing sections, bad compression,
-- oversized names, malformed RDATA/options, mismatched questions and IDs.
for n = 0, #response - 1 do rejected_response(response:sub(1, n), q) end
rejected_response(response .. "x", q)
rejected_query(query():sub(1, 4) .. u16(65535) .. query():sub(7))
rejected_query(query():sub(1, 12) .. "\192\12" .. u16(1) .. u16(1)) -- self
rejected_query(query():sub(1, 12) .. "\192\14" .. u16(1) .. u16(1)) -- forward
rejected_query(query():sub(1, 12) .. "\192\0" .. u16(1) .. u16(1)) -- header
rejected_query(query():sub(1, 12) .. char(64) .. string.rep("x", 64) .. "\0" .. u16(1) .. u16(1))
rejected_query(query():sub(1, 12) .. string.rep(char(63) .. string.rep("x", 63), 4) .. "\0" .. u16(1) .. u16(1))
rejected_response(answer(q, {rr(1, 1, "abc")}), q)
rejected_response(answer(q, {rr(28, 1, "abc")}), q)
rejected_response(answer(q, {rr(16, 1, char(255) .. "abc")}), q)
rejected_response(answer(q, {rr(5, 1, "\192\0")}), q)
rejected_response(answer(q, {rr(5, 1, "\192\12x")}), q)
rejected_response(answer(q, {rr(1, 1, "1234", "\192\13")}), q) -- middle of label
rejected_response(answer(qe, {rr(1, 1, "1234")}, {opt(), opt()}), qe)
rejected_response(answer(q, {rr(1, 1, "1234")}, {opt(u16(11) .. u16(1) .. "x")}), q)
local other = parsed(query("other.example"))
rejected_response(answer(other, {rr(1, 1, "1234")}), q)

-- Deterministic random input does not throw, even when byte strings look like
-- partial DNS headers or backward compression chains.
local seed = 12345
for i = 1, 500 do
    local data, length = {}, i % 97
    for j = 1, length do
        seed = (seed * 109 + 89) % 65536
        data[j] = char(seed % 256)
    end
    local raw = table.concat(data)
    check(pcall(wire.parse_query, raw))
    check(pcall(wire.validate_response, raw, q))
end
local err_response = check(wire.error_response(q, 2))
local err_parsed = check(wire.validate_response(err_response, q))
equal(err_parsed.rcode, 2)
equal(err_parsed.question, q.question)
equal(#check(wire.error_response("\1\2", 1)), 12)
check(wire.error_response("x", 1) == nil)

print("wire/cache: " .. count .. " checks passed")
