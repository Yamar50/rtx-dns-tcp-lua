package.path = 'src/?.lua;' .. package.path
local wire, Cache = require('dns_wire'), require('cache')
local count = 0
local function check(v, message) count = count + 1; assert(v, message or ('check ' .. count)) end
local function u16(n) return string.char((n-n%256)/256,n%256) end
local function make_query(extra)
  return '\0\7\1\0\0\1\0\0\0\0' .. u16(extra and 1 or 0)
    .. '\7example\4test\0\0\1\0\1' .. (extra or '')
end
local function opt(flags, data)
  data = data or ''
  return '\0\0\41\4\208' .. (flags or '\0\0\0\0') .. u16(#data) .. data
end
local function response(q, extra, extra_count)
  return '\0\7\129\128\0\1\0\1\0\0' .. u16(extra_count or (extra and 1 or 0)) .. q.question
    .. '\192\12\0\1\0\1\0\0\0\30\0\4\192\0\2\10' .. (extra or '')
end
local plain = assert(wire.parse_query(make_query()))
local edns = assert(wire.parse_query(make_query(opt())))
check(wire.upstream_query(edns,{}) == edns.raw)
check(wire.upstream_query(edns,{edns=true}) == edns.raw)
check(wire.upstream_query(plain,{edns=false}) == plain.raw)
check(wire.upstream_query(edns,{edns=false}) == plain.raw)
local added = assert(wire.parse_query(assert(wire.upstream_query(plain,{edns=true}))))
check(added.opt and added.edns_udp_size == 1232)
check(added.id == plain.id and added.question == plain.question)
local special = assert(wire.parse_query(make_query(opt('\0\0\128\0','\0\10\0\4abcd'))))
check(special.do_bit and special.edns_special)
check(wire.upstream_query(special,{edns=false}) == plain.raw)
check(wire.upstream_query(special,{edns=true}) == special.raw)
local raw = response(edns)
local cache = Cache.new(256,1048576)
check(not cache:put(edns,'policy',raw,0), 'legacy mode should retain strict EDNS negotiation')
edns.cache_allow_no_opt = true
check(cache:put(edns,'policy',raw,0), 'explicit edns off permits caching ordinary no-OPT response')
local cached = assert(cache:get(edns,'policy',1))
local parsed = assert(wire.validate_response(cached,edns))
check(parsed.min_ttl == 29 and not parsed.opt)
check(not cache:get(edns,'another-policy',1), 'policy must isolate cached EDNS variants')
special.cache_allow_no_opt = true
check(not cache:put(special,'policy',response(special),0), 'DO/options remain uncacheable')
local withopt = response(plain,opt())
check(wire.downstream_response(withopt,plain,{edns=true}) == response(plain))
check(wire.downstream_response(withopt,edns,{edns=true}) == withopt)
check(wire.downstream_response(raw,edns,{edns=false}) == raw)
check(wire.downstream_response(withopt,plain,{}) == withopt)
check(not wire.downstream_response(response(plain,opt('\1\0\0\0')),plain,{edns=true}))
local additional = '\192\12\0\1\0\1\0\0\0\30\0\4\192\0\2\11'
check(not wire.downstream_response(response(plain,opt()..additional,2),plain,{edns=true}))
check(wire.downstream_response(response(plain),plain,{edns=true}) == response(plain))
check(not wire.downstream_response('bad',plain,{edns=true}))
check(wire.local_query(plain,2048) == plain.raw, 'local UDP never adds EDNS')
check(wire.local_query(edns,2048) == edns.raw, 'smaller UDP advertisement stays unchanged')
for _, size in ipairs({512,1232,2048,4096,65535}) do
  local extra = '\0\0\41' .. u16(size) .. '\0\0\128\0\0\8\0\10\0\4abcd'
  local raw_query = make_query(extra)
  raw_query = raw_query:sub(1,3) .. '\16' .. raw_query:sub(5) -- CD remains set.
  local q = assert(wire.parse_query(raw_query))
  local sent = wire.local_query(q,2048)
  local parsed = assert(wire.parse_query(sent))
  check(parsed.edns_udp_size == math.min(size,2048), 'local UDP cap ' .. size)
  check(parsed.id == q.id and parsed.question == q.question and parsed.cd and parsed.do_bit)
  local position = q.opt.ttl_pos - 2
  check(sent:sub(1,position-1) == raw_query:sub(1,position-1)
    and sent:sub(position+2) == raw_query:sub(position+2), 'only EDNS size bytes may change')
end
print('policy wire checks passed: ' .. count)
