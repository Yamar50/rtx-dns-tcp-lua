-- DNS wire handling for Lua 5.1 and Yamaha's integer-number Lua runtime.
-- No bit library, floating point arithmetic, or math.floor is required.
local M = {}
local byte, char, sub = string.byte, string.char, string.sub
local concat = table.concat

function M.u16(s, p)
    p = p or 1
    if p < 1 or p + 1 > #s then return nil end
    return byte(s, p) * 256 + byte(s, p + 1)
end

local function pack16(n)
    return char((n - n % 256) / 256, n % 256)
end

local function pack32(n)
    local low = n % 65536
    return pack16((n - low) / 65536) .. pack16(low)
end

local function ttl32(s, p)
    -- RFC 2181 section 8: a received TTL with its high bit set is zero.
    -- Check before multiplication to avoid signed 32-bit Yamaha overflow.
    if byte(s, p) >= 128 then return 0 end
    return byte(s, p) * 16777216 + byte(s, p + 1) * 65536
        + byte(s, p + 2) * 256 + byte(s, p + 3)
end

local function lower_ascii(s)
    return (s:gsub("[A-Z]", function(c) return char(byte(c) + 32) end))
end

-- Returns normalized wire labels (unambiguous even when a label contains a
-- dot), a human-readable name, next position, and whether compression was used.
local function name_at(s, start, known_names)
    local p, next_p, steps, wire_len, pointer_hops = start, nil, 0, 1, 0
    local labels, wire, compressed = {}, {}, false
    while true do
        steps = steps + 1
        -- A valid 255-octet name can contain 127 one-octet labels. Allow its
        -- labels plus the bounded pointer walk, rather than counting one
        -- ordinary owner pointer against a 128-step combined budget.
        if steps > 256 or p < 1 or p > #s then
            return nil, "invalid or excessively compressed name"
        end
        local n = byte(s, p)
        if n == 0 then
            if known_names then known_names[p] = true end
            next_p = next_p or p + 1
            wire[#wire + 1] = "\0"
            return concat(wire), concat(labels, ".") .. ".", next_p, compressed
        elseif n >= 192 then
            pointer_hops = pointer_hops + 1
            if pointer_hops > 128 then return nil, "excessive compression pointer chain" end
            if p + 1 > #s then return nil, "short compression pointer" end
            local target = (n - 192) * 256 + byte(s, p + 1) + 1
            -- Compression points to a prior occurrence, never forward or self.
            if target >= p then return nil, "forward or circular compression pointer" end
            if known_names and not known_names[target] then
                return nil, "compression pointer is not a prior name boundary"
            end
            if known_names then known_names[p] = true end
            next_p, compressed, p = next_p or p + 2, true, target
        elseif n >= 64 then
            return nil, "unsupported label encoding"
        else
            if known_names then known_names[p] = true end
            if p + n > #s then return nil, "short label" end
            wire_len = wire_len + n + 1
            if wire_len > 255 then return nil, "name exceeds 255 octets" end
            local label = lower_ascii(sub(s, p + 1, p + n))
            labels[#labels + 1], wire[#wire + 1] = label, char(n) .. label
            p = p + n + 1
        end
    end
end

local dnssec_types = {
    [24] = true, [25] = true, [30] = true, [43] = true, [46] = true,
    [47] = true, [48] = true, [50] = true, [51] = true, [59] = true,
    [60] = true, [32768] = true, [32769] = true,
}

local single_name = {
    [2] = true, [3] = true, [4] = true, [5] = true, [7] = true,
    [8] = true, [9] = true, [12] = true, [39] = true,
}

local function read_name_in(s, p, finish, known_names)
    local canon, err_or_name, next_p = name_at(s, p, known_names)
    if not canon then return nil, err_or_name end
    if next_p > finish + 1 then return nil, "name exceeds RDATA" end
    return next_p
end

local function char_string_end(s, p, finish)
    if p > finish then return nil, "missing character string" end
    local next_p = p + 1 + byte(s, p)
    if next_p > finish + 1 then return nil, "character string exceeds RDATA" end
    return next_p
end

local function bitmap_valid(s, p, finish)
    local previous = -1
    while p <= finish do
        if p + 1 > finish then return nil, "short type bitmap" end
        local window, length = byte(s, p), byte(s, p + 1)
        if window <= previous or length < 1 or length > 32 or p + 1 + length > finish then
            return nil, "invalid type bitmap"
        end
        previous, p = window, p + 2 + length
    end
    return true
end

local function validate_rdata(s, rr, known_names)
    local t, p, finish = rr.rtype, rr.rdata, rr.finish
    if t == 1 and rr.rdlength ~= 4 then return nil, "invalid A length" end
    if t == 28 and rr.rdlength ~= 16 then return nil, "invalid AAAA length" end
    if single_name[t] then
        local after, err = read_name_in(s, p, finish, known_names)
        if not after then return nil, err end
        if after ~= finish + 1 then return nil, "extra name RDATA" end
    elseif t == 6 then -- SOA
        local err
        p, err = read_name_in(s, p, finish, known_names)
        if not p then return nil, err end
        p, err = read_name_in(s, p, finish, known_names)
        if not p then return nil, err end
        if p + 19 ~= finish then return nil, "invalid SOA length" end
    elseif t == 14 or t == 17 then -- MINFO / RP
        local err
        p, err = read_name_in(s, p, finish, known_names)
        if not p then return nil, err end
        p, err = read_name_in(s, p, finish, known_names)
        if not p then return nil, err end
        if p ~= finish + 1 then return nil, "extra two-name RDATA" end
    elseif t == 15 or t == 18 or t == 21 or t == 36 or t == 33 then
        local prefix = t == 33 and 6 or 2
        if rr.rdlength < prefix + 1 then return nil, "short preference/name RDATA" end
        local after, err = read_name_in(s, p + prefix, finish, known_names)
        if not after then return nil, err end
        if after ~= finish + 1 then return nil, "extra preference/name RDATA" end
    elseif t == 16 or t == 99 then -- TXT / SPF
        if rr.rdlength < 1 then return nil, "empty TXT RDATA" end
        while p <= finish do
            local err
            p, err = char_string_end(s, p, finish)
            if not p then return nil, err end
        end
    elseif t == 35 then -- NAPTR
        if rr.rdlength < 8 then return nil, "short NAPTR" end
        p = p + 4
        for _ = 1, 3 do
            local err
            p, err = char_string_end(s, p, finish)
            if not p then return nil, err end
        end
        local after, err = read_name_in(s, p, finish, known_names)
        if not after then return nil, err end
        if after ~= finish + 1 then return nil, "extra NAPTR RDATA" end
    elseif t == 46 then -- RRSIG signer name; signature is opaque.
        if rr.rdlength < 20 then return nil, "short RRSIG" end
        local after, err = read_name_in(s, p + 18, finish, known_names)
        if not after then return nil, err end
        if after > finish then return nil, "missing RRSIG signature" end
    elseif t == 47 then -- NSEC
        local after, err = read_name_in(s, p, finish, known_names)
        if not after then return nil, err end
        if after > finish then return nil, "missing NSEC type bitmap" end
        return bitmap_valid(s, after, finish)
    elseif t == 64 or t == 65 then -- SVCB / HTTPS
        if rr.rdlength < 3 then return nil, "short SVCB" end
        local after, err = read_name_in(s, p + 2, finish, known_names)
        if not after then return nil, err end
        p = after
        local previous = -1
        while p <= finish do
            if p + 3 > finish then return nil, "short SVCB parameter" end
            local key, length = M.u16(s, p), M.u16(s, p + 2)
            if key <= previous or p + 3 + length > finish then
                return nil, "invalid SVCB parameter"
            end
            previous, p = key, p + 4 + length
        end
    end
    -- Unknown RR data remains opaque (RFC 3597). Owner and RDLENGTH are checked.
    return true
end

local function parse_message(raw)
    if type(raw) ~= "string" or #raw < 12 or #raw > 65535 then
        return nil, "DNS message length outside 12..65535"
    end
    local h1, h2 = byte(raw, 3), byte(raw, 4)
    local m = {
        raw = raw, id = M.u16(raw, 1), qr = h1 >= 128,
        opcode = ((h1 - h1 % 8) / 8) % 16,
        rd = h1 % 2 == 1, tc = h1 % 4 >= 2,
        cd = h2 % 32 >= 16, ad = h2 % 64 >= 32, rcode = h2 % 16,
        qdcount = M.u16(raw, 5), ancount = M.u16(raw, 7),
        nscount = M.u16(raw, 9), arcount = M.u16(raw, 11),
        ttl_fields = {}, records = {}, cacheable = true,
    }
    if m.qdcount ~= 1 then return nil, "exactly one question is required" end
    local known_names = {}
    local canon, name, p, compressed = name_at(raw, 13, known_names)
    if not canon then return nil, name end
    if p + 3 > #raw then return nil, "short question" end
    m.canonical_name, m.name = canon, name
    m.qtype, m.qclass = M.u16(raw, p), M.u16(raw, p + 2)
    m.type, m.class = m.qtype, m.qclass
    m.question_end, m.question_compressed = p + 3, compressed
    m.question = sub(raw, 13, p + 3)
    p = p + 4
    -- Each RR needs at least a root name plus ten header bytes. This also
    -- bounds work for forged 16-bit section counts before entering the loop.
    local total = m.ancount + m.nscount + m.arcount
    if total > (#raw - p + 1 - (#raw - p + 1) % 11) / 11 then
        return nil, "section counts exceed message"
    end
    for i = 1, total do
        local owner, owner_err, next_p = name_at(raw, p, known_names)
        if not owner then return nil, owner_err end
        if next_p + 9 > #raw then return nil, "short resource record" end
        local rr = {
            start = p, owner = owner, rtype = M.u16(raw, next_p), rclass = M.u16(raw, next_p + 2),
            ttl_pos = next_p + 4, rdlength = M.u16(raw, next_p + 8),
            rdata = next_p + 10,
            section = i <= m.ancount and "answer" or
                (i <= m.ancount + m.nscount and "authority" or "additional"),
        }
        rr.finish = rr.rdata + rr.rdlength - 1
        if rr.finish > #raw then return nil, "RDATA exceeds message" end
        if rr.rtype == 41 then
            if m.opt or owner ~= "\0" or rr.section ~= "additional" then
                return nil, "invalid or duplicate OPT"
            end
            m.opt = rr
            m.edns_udp_size = rr.rclass
            m.edns_version = byte(raw, rr.ttl_pos + 1)
            m.extended_rcode = byte(raw, rr.ttl_pos)
            m.do_bit = byte(raw, rr.ttl_pos + 2) >= 128
            m.edns_special = rr.rdlength > 0 or m.edns_version ~= 0
                or byte(raw, rr.ttl_pos + 2) % 128 ~= 0
                or byte(raw, rr.ttl_pos + 3) ~= 0
            local opt_p = rr.rdata
            while opt_p <= rr.finish do
                if opt_p + 3 > rr.finish then return nil, "short EDNS option" end
                local code, length = M.u16(raw, opt_p), M.u16(raw, opt_p + 2)
                if opt_p + 3 + length > rr.finish then return nil, "EDNS option exceeds OPT" end
                if code == 11 then m.tcp_keepalive = true end
                opt_p = opt_p + 4 + length
            end
        else
            rr.ttl = ttl32(raw, rr.ttl_pos)
            m.ttl_fields[#m.ttl_fields + 1] = {pos = rr.ttl_pos, ttl = rr.ttl}
            if not m.min_ttl or rr.ttl < m.min_ttl then m.min_ttl = rr.ttl end
            if dnssec_types[rr.rtype] then m.dnssec = true end
            if rr.rtype == 250 or (rr.rtype == 24 and rr.section == "additional") then
                m.signed = true
            end
            local ok, err = validate_rdata(raw, rr, known_names)
            if not ok then return nil, err end
        end
        m.records[#m.records + 1], p = rr, rr.finish + 1
    end
    if p ~= #raw + 1 then return nil, "trailing data after DNS sections" end
    m.cacheable = m.qclass == 1 and m.opcode == 0 and not m.tc
        and not m.cd and not m.ad and not m.do_bit and not m.edns_special
        and not m.dnssec and not dnssec_types[m.qtype] and not m.signed
        and not compressed and m.qtype ~= 255
    return m
end

function M.parse_query(raw)
    local q, err = parse_message(raw)
    if not q then return nil, err end
    if q.qr or q.opcode ~= 0 then return nil, "only ordinary QUERY is supported" end
    if byte(raw, 3) >= 2 or byte(raw, 4) % 16 ~= 0 or byte(raw, 4) % 128 >= 64 then
        return nil, "invalid QUERY header flags"
    end
    if q.ancount ~= 0 or q.nscount ~= 0 then return nil, "QUERY contains answer or authority records" end
    if q.qtype == 251 or q.qtype == 252 then return nil, "zone transfers are unsupported" end
    if q.signed then return nil, "TSIG and SIG(0) cannot be relayed with rewritten IDs" end
    if q.tcp_keepalive then return nil, "EDNS TCP Keepalive is not negotiated by this proxy" end
    if q.edns_version and q.edns_version ~= 0 then return nil, "unsupported EDNS version" end
    if q.arcount > (q.opt and 1 or 0) then
        return nil, "only OPT additional records are supported in QUERY"
    end
    if q.extended_rcode and q.extended_rcode ~= 0 then return nil, "nonzero EDNS query RCODE" end
    q.retryable = true
    q.cache_key = q.canonical_name .. pack16(q.qtype) .. pack16(q.qclass)
        .. char(q.rd and 1 or 0, q.cd and 1 or 0, q.do_bit and 1 or 0)
        .. (q.opt and "e" .. pack16(q.edns_udp_size) or "n")
    return q
end

function M.with_id(raw, id)
    if type(raw) ~= "string" or #raw < 2 or type(id) ~= "number"
        or id < 0 or id > 65535 or id % 1 ~= 0 then return nil, "invalid ID or message" end
    return pack16(id) .. sub(raw, 3)
end

-- EDNS is hop-specific. Explicit policy mode reproduces the selected
-- server's edns setting; nil preserves the original static relay behavior.
function M.upstream_query(q, server)
    if server.edns == nil then return q.raw end
    if server.edns == false then
        if not q.opt then return q.raw end
        -- parse_query permits only a single trailing OPT in additional.
        if q.opt.finish ~= #q.raw or q.arcount ~= 1 then
            return nil, "cannot remove nontrailing query OPT"
        end
        return sub(q.raw, 1, 10) .. "\0\0" .. sub(q.raw, 13, q.opt.start - 1)
    end
    if q.opt then return q.raw end
    if #q.raw + 11 > 65535 then return nil, "query exceeds DNS frame after EDNS" end
    return sub(q.raw, 1, 10) .. "\0\1" .. sub(q.raw, 13)
        .. "\0" .. pack16(41) .. pack16(1232) .. "\0\0\0\0\0\0"
end

function M.downstream_response(raw, q, server)
    if server.edns ~= true or q.opt then return raw end
    local r, err = M.validate_response(raw, q)
    if not r then return nil, err end
    if not r.opt then return raw end
    -- A legacy client cannot represent an extended RCODE. Also do not move
    -- records that could contain compression pointers by deleting a middle OPT.
    if (r.extended_rcode or 0) ~= 0 then return nil, "extended RCODE for legacy client" end
    if r.opt.finish ~= #raw then return nil, "cannot remove nontrailing response OPT" end
    return sub(raw, 1, 10) .. pack16(r.arcount - 1) .. sub(raw, 13, r.opt.start - 1)
end

function M.frame(raw)
    if type(raw) ~= "string" or #raw < 12 or #raw > 65535 then
        return nil, "invalid DNS frame size"
    end
    return pack16(#raw) .. raw
end

function M.validate_response(raw, q, expected_id)
    local r, err = parse_message(raw)
    if not r then return nil, err end
    if not r.qr or r.opcode ~= 0 then return nil, "not an ordinary QUERY response" end
    if r.id ~= (expected_id or q.id) or r.canonical_name ~= q.canonical_name
        or r.qtype ~= q.qtype or r.qclass ~= q.qclass then
        return nil, "response ID or question mismatch"
    end
    if r.signed then return nil, "signed response cannot have its ID rewritten" end
    if r.tcp_keepalive then return nil, "unsolicited EDNS TCP Keepalive is unsupported" end
    return r
end

-- These RDATA formats contain no DNS compression references. Unknown types
-- remain safe to relay unchanged, but are not safe to relocate speculatively.
local filter_opaque_types = {
    [1] = true, [16] = true, [41] = true, [43] = true, [44] = true,
    [48] = true, [50] = true, [51] = true, [52] = true, [53] = true,
    [59] = true, [60] = true, [99] = true, [256] = true, [257] = true,
}

local function filter_rdata(raw, rr)
    local t, p, finish = rr.rtype, rr.rdata, rr.finish
    if filter_opaque_types[t] then return sub(raw, p, finish) end
    local parts = {}
    local function copy_to(next_p)
        parts[#parts + 1], p = sub(raw, p, next_p - 1), next_p
    end
    local function expand_name()
        -- parse_message already validated every pointer against known name
        -- boundaries. Expand from the original message, never from moved data.
        local name, err, next_p = name_at(raw, p)
        if not name then return nil, err end
        if next_p > finish + 1 then return nil, "name exceeds filtered RDATA" end
        parts[#parts + 1], p = name, next_p
        return true
    end
    local names, tail = 1, false
    if single_name[t] then
        -- The whole RDATA is one name.
    elseif t == 6 then names, tail = 2, true -- SOA: two names and five integers.
    elseif t == 14 or t == 17 then names = 2 -- MINFO / RP
    elseif t == 15 or t == 18 or t == 21 or t == 36 or t == 33 then
        copy_to(p + (t == 33 and 6 or 2))
    elseif t == 35 then -- NAPTR: order, preference, three strings, replacement.
        copy_to(p + 4)
        for _ = 1, 3 do
            local next_p, err = char_string_end(raw, p, finish)
            if not next_p then return nil, err end
            copy_to(next_p)
        end
    elseif t == 46 then copy_to(p + 18); tail = true -- RRSIG
    elseif t == 47 then tail = true -- NSEC
    elseif t == 64 or t == 65 then copy_to(p + 2); tail = true -- SVCB / HTTPS
    else return nil, "AAAA filter cannot rewrite this resource record type" end
    for _ = 1, names do
        local ok, err = expand_name()
        if not ok then return nil, err end
    end
    if tail then copy_to(finish + 1) end
    if p ~= finish + 1 then return nil, "extra filtered RDATA" end
    return concat(parts)
end

-- Filter external AAAA replies after response validation and route selection.
-- Returns bytes, changed; failures return nil, error. Callers must not cache a
-- changed reply: filtering is local policy, not authenticated denial of AAAA.
function M.filter_aaaa(raw)
    local m, err = parse_message(raw)
    if not m then return nil, err end
    if not m.qr or m.opcode ~= 0 then return nil, "AAAA filter requires a QUERY response" end
    if m.qtype ~= 28 or m.rcode ~= 0 or (m.extended_rcode or 0) ~= 0 then return raw, false end
    local removed, changed = {}, false
    for _, rr in ipairs(m.records) do
        if rr.rtype == 28 then
            removed[rr.owner .. pack16(rr.rclass)], changed = true, true
        end
    end
    if not changed then return raw, false end
    if m.signed then return nil, "AAAA filter cannot rewrite a signed message" end

    local records, counts, length = {}, {answer = 0, authority = 0, additional = 0}, 12 + #m.question
    for _, rr in ipairs(m.records) do
        local remove = rr.rtype == 28 or (rr.rtype == 46 and M.u16(raw, rr.rdata) == 28
            and removed[rr.owner .. pack16(rr.rclass)])
        if not remove then
            local data, data_error = filter_rdata(raw, rr)
            if not data then return nil, data_error end
            local record_length = #rr.owner + 10 + #data
            if #data > 65535 or length + record_length > 65535 then
                return nil, "AAAA filtered response exceeds DNS message limit"
            end
            -- TTL bytes (including OPT flags) and opaque RDATA fields retain
            -- their exact values; every owner and embedded name is relocated.
            records[#records + 1] = rr.owner .. pack16(rr.rtype) .. pack16(rr.rclass)
                .. sub(raw, rr.ttl_pos, rr.ttl_pos + 3) .. pack16(#data) .. data
            counts[rr.section], length = counts[rr.section] + 1, length + record_length
        end
    end
    local flags = byte(raw, 4) - (m.ad and 32 or 0)
    local filtered = sub(raw, 1, 3) .. char(flags) .. pack16(1)
        .. pack16(counts.answer) .. pack16(counts.authority) .. pack16(counts.additional)
        .. m.question .. concat(records)
    local checked, check_error = parse_message(filtered)
    if not checked then return nil, check_error end
    return filtered, true
end

function M.error_response(query, rcode)
    local raw = type(query) == "table" and query.raw or query
    if type(raw) ~= "string" or #raw < 2 then return nil, "query has no ID" end
    local q = type(query) == "table" and query or M.parse_query(raw)
    local high = #raw >= 3 and byte(raw, 3) or 0
    local low = #raw >= 4 and byte(raw, 4) or 0
    local opcode = ((high - high % 8) / 8) % 16
    -- RA signals this is a recursive proxy; preserve the client's RD and CD.
    local flags = char(128 + opcode * 8 + high % 2, 128 + (low % 32 >= 16 and 16 or 0) + rcode % 16)
    if q and not q.question_compressed then
        return sub(raw, 1, 2) .. flags .. "\0\1\0\0\0\0\0\0" .. q.question
    end
    return sub(raw, 1, 2) .. flags .. "\0\0\0\0\0\0\0\0"
end

function M.cache_prepare(response, q)
    if not q.cacheable then return nil, "query bypasses cache" end
    local r, err = M.validate_response(response, q)
    if not r then return nil, err end
    if not r.cacheable or r.rcode ~= 0 or (r.extended_rcode or 0) ~= 0
        or r.ancount == 0 or not r.min_ttl or r.min_ttl == 0 then
        return nil, "response is not positive cacheable data"
    end
    -- NOERROR with CNAME records can still be NODATA or a referral for the
    -- final name (RFC 2308 section 2.2). Only cache a complete positive answer
    -- for the requested type; a direct CNAME query remains eligible.
    local requested_answer = false
    for i = 1, r.ancount do
        local rr = r.records[i]
        if rr.rtype == q.qtype and rr.rclass == q.qclass then
            requested_answer = true
            break
        end
    end
    if not requested_answer then return nil, "no answer of the requested type and class" end
    if r.question_compressed or #r.question ~= #q.question then
        return nil, "cache question layout differs"
    end
    if (q.opt and not r.opt and not q.cache_allow_no_opt) or (r.opt and not q.opt) then
        return nil, "EDNS negotiation differs"
    end
    -- OPT is hop metadata, not cached DNS data. Only the common trailing,
    -- empty OPT layout is accepted; regenerate it for each requesting client.
    if r.opt and (r.opt.finish ~= #response or r.opt.rdlength ~= 0) then
        return nil, "cache requires a trailing empty OPT"
    end
    local template = r.opt and sub(response, 1, r.opt.start - 1) or response
    return {raw = template, size = #response, ttl_fields = r.ttl_fields,
        min_ttl = r.min_ttl, question_end = r.question_end, cache_key = q.cache_key,
        regenerate_opt = r.opt ~= nil}
end

function M.cache_render(entry, q, elapsed)
    if type(elapsed) ~= "number" or elapsed < 0 or elapsed % 1 ~= 0
        or elapsed >= entry.min_ttl or q.cache_key ~= entry.cache_key then
        return nil, "expired or mismatched cache entry"
    end
    -- All replacements have the same length, preserving compression offsets.
    local parts = {pack16(q.id), sub(entry.raw, 3, 12), q.question}
    local p = entry.question_end + 1
    for i = 1, #entry.ttl_fields do
        local f = entry.ttl_fields[i]
        parts[#parts + 1] = sub(entry.raw, p, f.pos - 1)
        parts[#parts + 1] = pack32(f.ttl - elapsed)
        p = f.pos + 4
    end
    parts[#parts + 1] = sub(entry.raw, p)
    if entry.regenerate_opt then
        parts[#parts + 1] = "\0" .. pack16(41) .. pack16(q.edns_udp_size)
            .. "\0\0\0\0\0\0"
    end
    return concat(parts)
end

return M
