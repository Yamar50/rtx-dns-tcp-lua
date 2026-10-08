-- Native RTX1210 status lines captured 2026-10-07/08; identifiers replaced.
-- CP932 measured; corresponding UTF-8 copies test compatibility only.
package.path = 'src/?.lua;' .. package.path
local Runtime, Policy = require('dns_runtime'), require('dns_policy')
local count = 0
local function eq(a,b) count=count+1; assert(a==b, tostring(a)..' ~= '..tostring(b)) end
local rows = {
  {"Current PPPoE session status is disabled.", "down"},
  {"PPPoE\131Z\131b\131V\131\135\131\147\130\205\140\187\141\221\142g\151p\130\197\130\171\130\220\130\185\130\241", "down"},
  {"PPPoE\227\130\187\227\131\131\227\130\183\227\131\167\227\131\179\227\129\175\231\143\190\229\156\168\228\189\191\231\148\168\227\129\167\227\129\141\227\129\190\227\129\155\227\130\147", "down"},
  {"Current PPPoE session status is Offline.", "down"},
  {"PPPoE\131Z\131b\131V\131\135\131\147\130\205\140p\130\193\130\196\130\162\130\220\130\185\130\241", "down"},
  {"PPPoE\227\130\187\227\131\131\227\130\183\227\131\167\227\131\179\227\129\175\231\182\153\227\129\163\227\129\166\227\129\132\227\129\190\227\129\155\227\130\147", "down"},
  {"Current PPPoE session status is In connecting process.", "connecting"},
  {"PPPoE\131Z\131b\131V\131\135\131\147\130\205\144\218\145\177\143\136\151\157\146\134\130\197\130\183", "connecting"},
  {"PPPoE\227\130\187\227\131\131\227\130\183\227\131\167\227\131\179\227\129\175\230\142\165\231\182\154\229\135\166\231\144\134\228\184\173\227\129\167\227\129\153", "connecting"},
  {"Current PPPoE session status is Connected.", "up"},
  {"PPPoE\131Z\131b\131V\131\135\131\147\130\205\144\218\145\177\130\179\130\234\130\196\130\162\130\220\130\183", "up"},
  {"PPPoE\227\130\187\227\131\131\227\130\183\227\131\167\227\131\179\227\129\175\230\142\165\231\182\154\227\129\149\227\130\140\227\129\166\227\129\132\227\129\190\227\129\153", "up"},
  {"PPTP\131Z\131b\131V\131\135\131\147\130\205\144\218\145\177\130\179\130\234\130\196\130\162\130\220\130\183", "up"},
  {"PPTP\227\130\187\227\131\131\227\130\183\227\131\167\227\131\179\227\129\175\230\142\165\231\182\154\227\129\149\227\130\140\227\129\166\227\129\132\227\129\190\227\129\153", "up"},
  {"\137\241\144\252\130\205\140\187\141\221\142g\151p\130\197\130\171\130\220\130\185\130\241", "down"},
  {"\229\155\158\231\183\154\227\129\175\231\143\190\229\156\168\228\189\191\231\148\168\227\129\167\227\129\141\227\129\190\227\129\155\227\130\147", "down"},
  {"PPPoE\131Z\131b\131V\131\135\131\147\130\205\136\234\147x\130\224\140p\130\193\130\196\130\162\130\220\130\185\130\241", "down"},
  {"PPPoE\227\130\187\227\131\131\227\130\183\227\131\167\227\131\179\227\129\175\228\184\128\229\186\166\227\130\130\231\182\153\227\129\163\227\129\166\227\129\132\227\129\190\227\129\155\227\130\147", "down"},
}
for _, row in ipairs(rows) do
  local body = 'PP[01]:\n' .. row[1] .. '\n'
  local dns = 'IPCP Local: IP-Address Primary-DNS(192.0.2.53), Remote: IP-Address\n'
  local r = assert(Runtime.new('dns server pp 1', function() return true, body .. dns end))
  r:refresh(); eq(r:pp_state(1),row[2])
  local result = r:source('pp','1')
  eq(result.state, row[2]=='up' and 'present' or row[2]=='down' and 'absent' or 'unknown')
  if row[2]=='up' then eq(result.servers[1],'192.0.2.53') end
end
-- Same reported state can conceal retained default/no prior default; direct
-- fixed fallback is intentionally identical. Notification remains preferred.
local state = 'Current PPPoE session status is Connected.'
local ipcp = 'IPCP Local: IP-Address, Remote: IP-Address'
local function scenario(default_line, inline, restriction, extra)
  local config = default_line .. '\ndns server select 2 pp 1 ' .. inline .. ' any .'
    .. (restriction and ' restrict pp 1' or '') .. '\ndns server select 3 192.0.2.3 any .'
  local reader = assert(Runtime.new(config, function() return true,
    'PP[01]:\n'..state..'\n'..ipcp..'\n'..(extra or '') end))
  reader:refresh()
  local p = assert(Policy.parse(config)); p:refresh(reader)
  local selected = assert(p:select({canonical_name='\7example\4test\0',qtype=1},'192.0.2.8'))
  return selected,p,reader
end
for _, inline in ipairs({'','192.0.2.4'}) do
  for _, restricted in ipairs({false,true}) do
    local route,p,r=scenario('dns server 192.0.2.1',inline,restricted)
    eq(route.rule_id,2);eq(route.upstreams[1].host,'192.0.2.1')
    eq(route.unavailable,false);eq(route.ede_text~=nil,true)
    eq(r:source('pp',1).availability,'pp_no_dns')
    eq(p:refresh(r),false)
  end
end
for _, ordinary in ipairs({'','dns server pp 1','dns server 2001:db8::1'}) do
  local route=scenario(ordinary,'192.0.2.4',true)
  eq(route.rule_id,2);eq(route.unavailable,true);eq(#route.upstreams,0)
  eq(route.ede_text~=nil,true)
end
ipcp='IPCP Local: IP-Address Primary-DNS(192.0.2.53) Secondary-DNS(192.0.2.54), Remote: IP-Address'
local route=scenario('dns server 192.0.2.1','192.0.2.4',true)
eq(route.upstreams[1].host,'192.0.2.53');eq(route.ede_text,nil)
for _, unknown in ipairs({'', 'IPCP Local: Primary-DNS(*), Remote: IP-Address',
  'IPCP Local: IP-Address Primary-dns(192.0.2.53), Remote: IP-Address'}) do
  ipcp=unknown
  route=scenario('dns server 192.0.2.1','192.0.2.4',true)
  eq(route.unavailable,true);eq(route.ede_text,nil)
end
ipcp='IPCP Local: IP-Address, Remote: IP-Address'
for _, st in ipairs({'Current PPPoE session status is Offline.','Current line status is disabled.'}) do
  state=st
  route=scenario('dns server 192.0.2.1','192.0.2.4',true)
  eq(route.rule_id,3);eq(route.upstreams[1].host,'192.0.2.3');eq(route.ede_text,nil)
  route=scenario('dns server 192.0.2.1','192.0.2.4',false)
  eq(route.rule_id,2);eq(route.unavailable,true);eq(route.ede_text,nil)
end
state='Current PPPoE session status is In connecting process.'
route=scenario('dns server 192.0.2.1','192.0.2.4',true)
eq(route.unavailable,true);eq(route.ede_text,nil)
-- RTX1210 single IPv4 DHCP client: a lease with gateway but no option 6
-- uses ordinary DNS, not the inline default or a later select rule.
local dc = 'ip lan2 address dhcp\ndns server 192.0.2.1\n'
  .. 'dns server select 2 dhcp lan2 192.0.2.4 any .\n'
  .. 'dns server select 3 192.0.2.3 any .'
local ds = 'Interface: LAN2 primary\n IP address: 192.0.2.8/24\n'
  .. ' DHCP server: 192.0.2.254\nCommon information\n Default gateway: 192.0.2.254\n'
local function dhcp(config, status)
  local reader=assert(Runtime.new(config,function() return true,status end));reader:refresh()
  local policy=assert(Policy.parse(config));policy:refresh(reader)
  return assert(policy:select({canonical_name='\7example\4test\0',qtype=1},'192.0.2.8')),reader
end
local dhcp_reader
route,dhcp_reader=dhcp(dc,ds)
eq(dhcp_reader:source('dhcp','lan2').availability,'dhcp_no_dns')
eq(route.upstreams[1].host,'192.0.2.1');eq(route.rule_id,2);eq(route.ede_text,nil)
route=dhcp(dc,ds..' DNS server: 192.0.2.53\n')
eq(route.upstreams[1].host,'192.0.2.53')
route=dhcp(dc:gsub('dns server 192.0.2.1\n',''),ds)
eq(route.unavailable,true);eq(route.rule_id,2)
route=dhcp(dc,ds:gsub('Common information.*',''))
eq(route.unavailable,true) -- Incomplete common section is not confirmed absence.
route=dhcp(dc..'\nip lan3 address dhcp',ds)
eq(route.unavailable,true) -- Never map an ambiguous common DNS list by guess.
print('native PP/DHCP fixture checks: '..count)
