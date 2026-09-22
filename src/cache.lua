-- Bounded O(1) lookup / LRU, with expiry checked only for the requested key.
-- The byte cap counts saved DNS messages, not Lua table metadata. A separate
-- total TTL-field cap bounds the dominant per-record metadata allocation.
local wire = require("dns_wire")
local M = {}
local Cache = {}
Cache.__index = Cache

local function unlink(self, node)
    if node.previous then node.previous.next = node.next else self.first = node.next end
    if node.next then node.next.previous = node.previous else self.last = node.previous end
    node.previous, node.next = nil, nil
end

local function newest(self, node)
    node.previous, node.next = self.last, nil
    if self.last then self.last.next = node else self.first = node end
    self.last = node
end

local function remove(self, node)
    unlink(self, node)
    self.index[node.key] = nil
    self.count, self.bytes = self.count - 1, self.bytes - node.entry.size
    self.ttl_fields = self.ttl_fields - node.ttl_count
end

local function key_for(q, policy)
    if not q or not q.cacheable or not q.cache_key then return nil end
    policy = tostring(policy or "default")
    return tostring(#policy) .. ":" .. policy .. q.cache_key
end

function M.new(max_entries, max_bytes, max_ttl_fields)
    max_entries, max_bytes = max_entries or 256, max_bytes or 1048576
    max_ttl_fields = max_ttl_fields or 4096
    assert(max_entries >= 0 and max_entries % 1 == 0, "invalid cache entry limit")
    assert(max_bytes >= 0 and max_bytes % 1 == 0, "invalid cache byte limit")
    assert(max_ttl_fields >= 0 and max_ttl_fields % 1 == 0, "invalid cache TTL-field limit")
    return setmetatable({max_entries = max_entries, max_bytes = max_bytes,
        max_ttl_fields = max_ttl_fields, index = {}, count = 0, bytes = 0, ttl_fields = 0,
        counters = {hits = 0, misses = 0, bypasses = 0, expirations = 0,
            evictions = 0, inserts = 0, rejections = 0, metadata_rejections = 0}}, Cache)
end

function Cache:get(q, policy, now)
    local key = key_for(q, policy)
    if not key then
        self.counters.bypasses = self.counters.bypasses + 1
        return nil
    end
    local node = self.index[key]
    if not node then
        self.counters.misses = self.counters.misses + 1
        return nil
    end
    if now < node.saved_at or now - node.saved_at >= node.entry.min_ttl then
        remove(self, node)
        self.counters.expirations = self.counters.expirations + 1
        self.counters.misses = self.counters.misses + 1
        return nil
    end
    local age = now - node.saved_at
    local raw = wire.cache_render(node.entry, q, age - age % 1)
    if not raw then
        self.counters.misses = self.counters.misses + 1
        return nil
    end
    unlink(self, node)
    newest(self, node)
    self.counters.hits = self.counters.hits + 1
    return raw
end

function Cache:put(q, policy, response, now)
    local key = key_for(q, policy)
    if not key then
        self.counters.rejections = self.counters.rejections + 1
        return false, "query bypasses cache"
    end
    local entry, err = wire.cache_prepare(response, q)
    if not entry or self.max_entries == 0 or (entry and entry.size > self.max_bytes) then
        self.counters.rejections = self.counters.rejections + 1
        return false, err or "entry exceeds cache capacity"
    end
    local ttl_count = #entry.ttl_fields
    if ttl_count > self.max_ttl_fields then
        self.counters.rejections = self.counters.rejections + 1
        self.counters.metadata_rejections = self.counters.metadata_rejections + 1
        return false, "entry exceeds cache TTL-field capacity"
    end
    local existing = self.index[key]
    if existing then remove(self, existing) end
    while self.count >= self.max_entries or self.bytes + entry.size > self.max_bytes
        or self.ttl_fields + ttl_count > self.max_ttl_fields do
        local victim = self.first
        if now >= victim.saved_at and now - victim.saved_at >= victim.entry.min_ttl then
            self.counters.expirations = self.counters.expirations + 1
        else
            self.counters.evictions = self.counters.evictions + 1
        end
        remove(self, victim)
    end
    local node = {key = key, entry = entry, saved_at = now, ttl_count = ttl_count}
    self.index[key] = node
    newest(self, node)
    self.count, self.bytes = self.count + 1, self.bytes + entry.size
    self.ttl_fields = self.ttl_fields + ttl_count
    self.counters.inserts = self.counters.inserts + 1
    return true
end

function Cache:clear()
    self.index, self.first, self.last = {}, nil, nil
    self.count, self.bytes, self.ttl_fields = 0, 0, 0
end

function Cache:stats()
    local out = {entries = self.count, bytes = self.bytes,
        ttl_fields = self.ttl_fields, max_ttl_fields = self.max_ttl_fields,
        max_entries = self.max_entries, max_bytes = self.max_bytes}
    for k, v in pairs(self.counters) do out[k] = v end
    return out
end

return M
