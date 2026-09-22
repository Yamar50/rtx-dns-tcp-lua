package.path = 'src/?.lua;' .. package.path
local wire = require('dns_wire')
local checks = 0
local function check(value, message)
  checks = checks + 1
  assert(value, message or ('AAAA filter check ' .. checks))
  return value
end
local function equal(actual, expected, message)
  check(actual == expected, (message or 'values differ') .. ': ' .. tostring(actual) .. ' ~= ' .. tostring(expected))
end
local function u16(n) return string.char((n - n % 256) / 256, n % 256) end
local function name(value)
  local out = {}
  for label in value:gmatch('[^.]+') do out[#out + 1] = string.char(#label) .. label end
  return table.concat(out) .. '\0'
end
local function pointer(offset) return string.char(192 + (offset - offset % 256) / 256, offset % 256) end
local function query(qname, qtype)
  return assert(wire.parse_query('\18\52\1\0\0\1\0\0\0\0\0\0'
    .. name(qname or 'alias.test') .. u16(qtype or 28) .. '\0\1'))
end
local function rr(owner, kind, data, class, ttl)
  return owner .. u16(kind) .. u16(class or 1) .. (ttl or '\0\0\0\60') .. u16(#data) .. data
end
local function response(q, answers, authority, additional, flags)
  answers, authority, additional = answers or {}, authority or {}, additional or {}
  return q.raw:sub(1, 2) .. '\129' .. string.char(flags or 128) .. '\0\1'
    .. u16(#answers) .. u16(#authority) .. u16(#additional) .. q.question
    .. table.concat(answers) .. table.concat(authority) .. table.concat(additional)
end
local function signature(kind, signer, bytes)
  return u16(kind) .. string.rep('\0', 16) .. signer .. (bytes or '\192\12signature')
end
local function transformed(raw, q)
  local result, changed = wire.filter_aaaa(raw)
  check(result, changed)
  equal(changed, true, 'rewrite flag')
  local parsed = check(wire.validate_response(result, q), 'rebuilt response validates')
  check(not parsed.ad, 'AD cleared after modifying authenticated data')
  for _, record in ipairs(parsed.records) do check(record.rtype ~= 28, 'AAAA removed in every section') end
  return result, parsed
end
local function unchanged(raw)
  local result, changed = wire.filter_aaaa(raw)
  equal(result, raw, 'unchanged response is byte identical')
  equal(changed, false, 'unchanged flag')
end
local function rejected(raw, fragment)
  local ok, result, err = pcall(wire.filter_aaaa, raw)
  check(ok, 'malformed input never throws')
  check(result == nil and type(err) == 'string', 'unsafe rewrite fails')
  if fragment then check(err:find(fragment, 1, true), 'expected failure: ' .. fragment .. ': ' .. err) end
end
local q, at_question, address = query(), pointer(12), string.rep('\0', 15) .. '\1'

-- Direct positive replies become NOERROR/NODATA. RD/RA/CD and all other
-- header flags retain their values, while AD alone is cleared.
do
  local raw = response(q, {rr(at_question, 28, address)}, nil, nil, 176)
  local result, parsed = transformed(raw, q)
  equal(parsed.rcode, 0)
  equal(parsed.ancount, 0)
  equal(parsed.nscount, 0)
  equal(parsed.arcount, 0)
  equal(result:byte(3), raw:byte(3))
  equal(result:byte(4), 144)
  equal(parsed.question, q.question)
  check(not wire.cache_prepare(result, q), 'filtered data is not positive cacheable AAAA')
end

-- A retained owner and CNAME RDATA may point into a removed AAAA RR. Both
-- must be expanded from the old message, not copied with their old offsets.
do
  local target = name('target.test')
  local target_offset = 12 + #q.question
  local raw = response(q, {
    rr(target, 28, address),
    rr(at_question, 5, pointer(target_offset)),
  }, nil, {rr(pointer(target_offset), 1, '\192\0\2\37')}, 160)
  local result, parsed = transformed(raw, q)
  equal(parsed.ancount, 1)
  equal(parsed.arcount, 1)
  equal(parsed.records[1].rtype, 5)
  equal(result:sub(parsed.records[1].rdata, parsed.records[1].finish), target)
  equal(parsed.records[2].owner, target)
  equal(result:sub(parsed.records[2].rdata, parsed.records[2].finish), '\192\0\2\37')
end

-- Drop only signatures of removed AAAA RRsets, by covered type, owner and
-- class, even if the signature appears before its covered record.
do
  local other = name('other.test')
  local raw = response(q, {
    rr(at_question, 46, signature(28, at_question)),
    rr(at_question, 28, address),
    rr(at_question, 5, name('target.test')),
    rr(at_question, 46, signature(5, at_question)),
    rr(other, 46, signature(28, at_question)),
    rr(at_question, 46, signature(28, at_question), 3),
  }, {rr(name('authority.test'), 28, address)}, {
    rr(name('additional.test'), 28, address),
    rr(at_question, 46, signature(28, at_question)),
  }, 160)
  local result, parsed = transformed(raw, q)
  equal(parsed.ancount, 4)
  equal(parsed.nscount, 0)
  equal(parsed.arcount, 0)
  equal(parsed.records[1].rtype, 5)
  equal(wire.u16(result, parsed.records[2].rdata), 5)
  equal(parsed.records[3].owner, other)
  equal(parsed.records[4].rclass, 3)
end

-- Exercise every supported name-bearing RDATA layout with compressed names.
-- Opaque signature/parameter bytes which resemble pointers stay unchanged.
do
  local p = at_question
  local rrs = {rr(p, 28, address)}
  local expected = {}
  local function add(kind, data, expanded)
    rrs[#rrs + 1] = rr(p, kind, data)
    expected[#expected + 1] = {kind = kind, data = expanded}
  end
  local full = q.canonical_name
  for _, kind in ipairs({2, 3, 4, 5, 7, 8, 9, 12, 39}) do add(kind, p, full) end
  local numbers = string.rep('\255', 20)
  add(6, p .. p .. numbers, full .. full .. numbers)
  for _, kind in ipairs({14, 17}) do add(kind, p .. p, full .. full) end
  for _, kind in ipairs({15, 18, 21, 36, 33}) do
    local prefix = string.rep('\1', kind == 33 and 6 or 2)
    add(kind, prefix .. p, prefix .. full)
  end
  local naptr = '\0\1\0\2\1s\0\0'
  add(35, naptr .. p, naptr .. full)
  add(46, signature(5, p), signature(5, full))
  local bitmap = '\0\4\0\0\0\8'
  add(47, p .. bitmap, full .. bitmap)
  local params = '\0\6\0\2\192\12'
  for _, kind in ipairs({64, 65}) do add(kind, '\0\1' .. p .. params, '\0\1' .. full .. params) end
  local raw = response(q, rrs)
  local result, parsed = transformed(raw, q)
  equal(parsed.ancount, #expected)
  for index, item in ipairs(expected) do
    local record = parsed.records[index]
    equal(record.rtype, item.kind)
    equal(result:sub(record.rdata, record.finish), item.data, 'typed RDATA preserved and expanded')
  end
end

-- All explicitly known name-free formats are copied without interpreting
-- pointer-like byte pairs. OPT keeps DO, payload size and options.
do
  local additional, expected = {}, {}
  for _, kind in ipairs({1, 16, 43, 44, 48, 50, 51, 52, 53, 59, 60, 99, 256, 257}) do
    local data = kind == 1 and '\192\0\2\1' or ((kind == 16 or kind == 99) and '\2\192\12' or '\192\12opaque')
    additional[#additional + 1] = rr(at_question, kind, data)
    expected[#expected + 1] = data
  end
  local option = '\0\10\0\2\192\12'
  additional[#additional + 1] = rr('\0', 41, option, 1232, '\0\0\128\0')
  expected[#expected + 1] = option
  local result, parsed = transformed(response(q, {rr(at_question, 28, address)}, nil, additional), q)
  equal(parsed.arcount, #additional)
  check(parsed.do_bit and parsed.edns_special)
  equal(parsed.edns_udp_size, 1232)
  for index, data in ipairs(expected) do
    local record = parsed.records[index]
    equal(result:sub(record.rdata, record.finish), data)
  end
end

-- No filtering policy is inferred for A/ANY. Negative and already empty
-- replies retain their SOA, DNSSEC flags, unknown RRs and exact bytes.
do
  for _, kind in ipairs({1, 255}) do
    unchanged(response(query(nil, kind), {rr(at_question, 28, address), rr(at_question, 65280, '\192\12')}))
  end
  for _, rcode in ipairs({2, 3, 4, 5}) do
    unchanged(response(q, {rr(at_question, 28, address)}, {
      rr(at_question, 6, at_question .. at_question .. string.rep('\0', 20)),
    }, nil, 160 + rcode))
  end
  unchanged(response(q, {}, {}, {}, 160))
  unchanged(response(q, {rr(at_question, 5, name('target.test')), rr(at_question, 65280, '\192\12')}, nil, nil, 160))
  unchanged(response(q, {rr(at_question, 28, address)}, nil, {rr('\0', 41, '', 1232, '\1\0\0\0')}))
  unchanged(response(q, {rr(at_question, 46, signature(28, at_question))}))
end

-- Unknown retained RDATA cannot be relocated, and authenticated whole
-- messages cannot be changed. Invalid compression is rejected before editing.
do
  rejected(response(q, {rr(at_question, 28, address), rr(at_question, 65280, '\192\12')}), 'resource record type')
  rejected(response(q, {rr(at_question, 28, address)}, nil, {rr(at_question, 250, 'signature')}), 'signed message')
  local start = 12 + #q.question
  rejected(response(q, {rr(at_question, 28, address), rr(at_question, 5, pointer(start + 12))}), 'name boundary')
  rejected(response(q, {rr(at_question, 28, address), rr(at_question, 5, pointer(16383))}), 'forward')
  rejected(response(q, {rr(at_question, 28, address:sub(2))}), 'AAAA length')
  rejected(response(q, {rr(at_question, 28, address)}) .. 'trailing', 'trailing')
  rejected(q.raw, 'requires a QUERY response')
  for _, bad in ipairs({'', 'short', '\0\1' .. string.rep('\0', 10)}) do rejected(bad) end
  rejected(nil)
end

-- Compression expansion must remain bounded even when the input is small.
-- Test the actual DNS message limit, including a valid exactly-65535 reply.
do
  local long_name = string.rep('a', 63) .. '.' .. string.rep('b', 63) .. '.'
    .. string.rep('c', 63) .. '.' .. string.rep('d', 61)
  local long_q = query(long_name)
  equal(#long_q.canonical_name, 255)
  local answers = {rr(at_question, 28, address)}
  for _ = 1, 242 do answers[#answers + 1] = rr(at_question, 1, '\192\0\2\1') end
  local raw = response(long_q, answers, nil, {rr('\0', 16, string.char(154) .. string.rep('x', 154))})
  check(#raw < 65535, 'compressed original fits')
  local result = transformed(raw, long_q)
  equal(#result, 65535, 'expanded boundary accepted')
  rejected(response(long_q, answers, nil, {rr('\0', 16, string.char(155) .. string.rep('x', 155))}), 'message limit')
end

print('AAAA filter checks passed: ' .. checks)
