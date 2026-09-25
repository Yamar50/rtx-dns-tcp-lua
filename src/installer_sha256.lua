-- SHA-256 for the installer, implemented from the algorithm in FIPS 180-4.
-- A word is two unsigned 16-bit limbs. No operation needs unsigned 32-bit
-- numbers, floating point, native bit operations, or Lua newer than 5.1.
local M = {}
local byte, char, concat = string.byte, string.char, table.concat
local powers = { [0] = 1 }
for n = 1, 16 do powers[n] = powers[n - 1] * 2 end

-- Small nibble tables keep memory bounded without one operation per bit.
local xt, at = {}, {}
for a = 0, 15 do
    for b = 0, 15 do
        local x, y, v, av, bit = a, b, 0, 0, 1
        for _ = 1, 4 do
            local xb, yb = x % 2, y % 2
            if xb ~= yb then v = v + bit end
            if xb == 1 and yb == 1 then av = av + bit end
            x, y, bit = (x - xb) / 2, (y - yb) / 2, bit * 2
        end
        local p = a * 16 + b + 1
        xt[p], at[p] = v, av
    end
end

local function combine(a, b, lookup)
    local a0, b0 = a % 16, b % 16
    local result = lookup[a0 * 16 + b0 + 1]
    a, b = (a - a0) / 16, (b - b0) / 16
    a0, b0 = a % 16, b % 16
    result = result + lookup[a0 * 16 + b0 + 1] * 16
    a, b = (a - a0) / 16, (b - b0) / 16
    a0, b0 = a % 16, b % 16
    result = result + lookup[a0 * 16 + b0 + 1] * 256
    a, b = (a - a0) / 16, (b - b0) / 16
    return result + lookup[a * 16 + b + 1] * 4096
end

local function xor(a, b) return combine(a, b, xt) end
local function band(a, b) return combine(a, b, at) end

-- Yamaha provides this library from _RT_LUA_VERSION 1.01. Use only positive
-- 16-bit operands, so its unsigned32/BIGNUM rules cannot change our arithmetic.
-- Feature probes also keep this module usable with other Lua implementations.
local native = rawget(_G, "bit")
if type(native) == "table" and type(native.bxor) == "function" and type(native.band) == "function" then
    local ok, valid = pcall(function()
        for _, pair in ipairs({{0, 0}, {65535, 0}, {65535, 65535}, {32768, 32767}, {43690, 21845}, {4660, 22136}}) do
            local a, b = pair[1], pair[2]
            if native.bxor(a, b) ~= xor(a, b) or native.band(a, b) ~= band(a, b) then return false end
        end
        return true
    end)
    if ok and valid then xor, band = native.bxor, native.band end
end

local function rotate(h, l, n)
    if n >= 16 then h, l, n = l, h, n - 16 end
    local p, q = powers[n], powers[16 - n]
    local hr, lr = h % p, l % p
    return (h - hr) / p + lr * q, (l - lr) / p + hr * q
end

local function sigma(h, l, a, b, c, shift)
    local ah, al = rotate(h, l, a)
    local bh, bl = rotate(h, l, b)
    local ch, cl
    if shift then
        local p = powers[c]
        local hr, lr = h % p, l % p
        ch, cl = (h - hr) / p, (l - lr) / p + hr * powers[16 - c]
    else
        ch, cl = rotate(h, l, c)
    end
    return xor(xor(ah, bh), ch), xor(xor(al, bl), cl)
end

local function words(text)
    local high, low = {}, {}
    for word in text:gmatch("%x+") do
        high[#high + 1] = tonumber(word:sub(1, 4), 16)
        low[#low + 1] = tonumber(word:sub(5, 8), 16)
    end
    return high, low
end

local kh, kl = words([[
428a2f98 71374491 b5c0fbcf e9b5dba5 3956c25b 59f111f1 923f82a4 ab1c5ed5
d807aa98 12835b01 243185be 550c7dc3 72be5d74 80deb1fe 9bdc06a7 c19bf174
e49b69c1 efbe4786 0fc19dc6 240ca1cc 2de92c6f 4a7484aa 5cb0a9dc 76f988da
983e5152 a831c66d b00327c8 bf597fc7 c6e00bf3 d5a79147 06ca6351 14292967
27b70a85 2e1b2138 4d2c6dfc 53380d13 650a7354 766a0abb 81c2c92e 92722c85
a2bfe8a1 a81a664b c24b8b70 c76c51a3 d192e819 d6990624 f40e3585 106aa070
19a4c116 1e376c08 2748774c 34b0bcb5 391c0cb3 4ed8aa4a 5b9cca4f 682e6ff3
748f82ee 78a5636f 84c87814 8cc70208 90befffa a4506ceb bef9a3f7 c67178f2
]])

local function pack16(n)
    return char((n - n % 256) / 256, n % 256)
end

function M.hex(data, yield_fn)
    assert(type(data) == "string", "SHA256 input must be a string")
    assert(yield_fn == nil or type(yield_fn) == "function", "invalid SHA256 yield callback")
    local length = #data
    -- Encode length * 8 without ever multiplying a potentially large length.
    local low = length % 8192
    local rest = (length - low) / 8192
    local middle = rest % 65536
    local trailer = pack16(0) .. pack16((rest - middle) / 65536)
        .. pack16(middle) .. pack16(low * 8)
    data = data .. char(128) .. string.rep(char(0), (119 - length % 64) % 64) .. trailer
    local hh, hl = words("6a09e667 bb67ae85 3c6ef372 a54ff53a 510e527f 9b05688c 1f83d9ab 5be0cd19")
    local wh, wl = {}, {}
    local blocks = 0
    for start = 1, #data, 64 do
        for i = 1, 16 do
            local p = start + (i - 1) * 4
            wh[i], wl[i] = byte(data, p) * 256 + byte(data, p + 1),
                byte(data, p + 2) * 256 + byte(data, p + 3)
        end
        for i = 17, 64 do
            local ah, al = sigma(wh[i - 15], wl[i - 15], 7, 18, 3, true)
            local bh, bl = sigma(wh[i - 2], wl[i - 2], 17, 19, 10, true)
            local sum = wl[i - 16] + al + wl[i - 7] + bl
            local remainder = sum % 65536
            wl[i] = remainder
            wh[i] = (wh[i - 16] + ah + wh[i - 7] + bh + (sum - remainder) / 65536) % 65536
        end
        local ah, al, bh, bl, ch, cl, dh, dl = hh[1], hl[1], hh[2], hl[2], hh[3], hl[3], hh[4], hl[4]
        local eh, el, fh, fl, gh, gl, ih, il = hh[5], hl[5], hh[6], hl[6], hh[7], hl[7], hh[8], hl[8]
        for i = 1, 64 do
            local sh, sl = sigma(eh, el, 6, 11, 25)
            -- Ch(e,f,g) = g XOR (e AND (f XOR g)).
            local chooseh = xor(gh, band(eh, xor(fh, gh)))
            local choosel = xor(gl, band(el, xor(fl, gl)))
            local sum = il + sl + choosel + kl[i] + wl[i]
            local t1l = sum % 65536
            local t1h = (ih + sh + chooseh + kh[i] + wh[i] + (sum - t1l) / 65536) % 65536
            sh, sl = sigma(ah, al, 2, 13, 22)
            -- Maj(a,b,c) = (a AND b) XOR ((a XOR b) AND c).
            local majorh = xor(band(ah, bh), band(xor(ah, bh), ch))
            local majorl = xor(band(al, bl), band(xor(al, bl), cl))
            sum = sl + majorl
            local t2l = sum % 65536
            local t2h = (sh + majorh + (sum - t2l) / 65536) % 65536
            ih, il, gh, gl, fh, fl = gh, gl, fh, fl, eh, el
            sum = dl + t1l
            el = sum % 65536
            eh = (dh + t1h + (sum - el) / 65536) % 65536
            dh, dl, ch, cl, bh, bl = ch, cl, bh, bl, ah, al
            sum = t1l + t2l
            al = sum % 65536
            ah = (t1h + t2h + (sum - al) / 65536) % 65536
        end
        local finalh, finall = {ah, bh, ch, dh, eh, fh, gh, ih}, {al, bl, cl, dl, el, fl, gl, il}
        for i = 1, 8 do
            local sum = hl[i] + finall[i]
            hl[i] = sum % 65536
            hh[i] = (hh[i] + finalh[i] + (sum - hl[i]) / 65536) % 65536
        end
        blocks = blocks + 1
        if yield_fn and blocks % 32 == 0 then yield_fn() end
    end
    local result = {}
    for i = 1, 8 do result[i] = string.format("%04x%04x", hh[i], hl[i]) end
    return concat(result)
end

return M
