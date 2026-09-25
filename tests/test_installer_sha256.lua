package.path = "src/?.lua;" .. package.path
local sha = require("installer_sha256")
local count = 0
local function equal(actual, expected)
    count = count + 1
    assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
end

-- Published SHA-256 known-answer vectors, including a two-block message.
equal(sha.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
equal(sha.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
equal(sha.hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
equal(sha.hex("The quick brown fox jumps over the lazy dog"),
    "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")

-- Independent Python hashlib values for binary data around padding boundaries.
local boundaries = {
    {55, "3904ac4e18abecf4265e4a6d2b90381697804c134ac75cef8737b56eabf53776"},
    {56, "abbaba13e6e30ce62615b7f1fdcf0aaa30a6cda7e71fa7a00a3f1627afd19051"},
    {63, "4260f4c3b5f769f1a57957007ae3e4a285ecdfec7c55956204b0084411b6c705"},
    {64, "d801524cf855f9f15d06e4c69e380a1f7ed872736f3766e693f72b21a25b910e"},
    {65, "1705e377fba4daeb60a0f56e79754f0851085f856278c151e7f13718a45508e2"},
    {119, "d01e0e9067bc916ce70139459706da6025904939b668a587e3c7b87f2d7ca7f7"},
    {120, "36305e0e627761ab10d6a59013d46434bc616fa26f33b10dc2874bb3d1ec2154"},
    {127, "e72900ef77a9950306e473769d066e78dfde3c6c8e30c05444edf96f711ad3db"},
    {128, "3cea7f04e525a3de0cef6f29fa28ad0fcee47158d97b2d30b68d93dee3f2597d"},
    {129, "f3324b6b37d23f9fc59881def685873dd749a78190299f4898b69659503804e1"},
}
for _, row in ipairs(boundaries) do
    local data = {}
    for i = 0, row[1] - 1 do data[#data + 1] = string.char((i * 29 + 17) % 256) end
    equal(sha.hex(table.concat(data)), row[2])
end

-- A full installer-sized input checks bit-length encoding across 65536 bits,
-- a digest full of binary input values, and periodic cooperative yielding.
local values = {}
for i = 0, 255 do values[#values + 1] = string.char(i) end
local data = string.rep(table.concat(values), 600)
local yields = 0
equal(sha.hex(data, function() yields = yields + 1 end),
    "41dae6b28c30ab57faaf5c4707cb4bcda0dcff3057a394447eaad9a67d06ad82")
equal(yields, 75)
equal(sha.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
equal(pcall(sha.hex, {}), false)
equal(pcall(sha.hex, "", true), false)
equal(pcall(sha.hex, data, function() error("cancel hashing") end), false)

local function load_with_bit(bits)
    local env = setmetatable({ bit = bits }, { __index = _G })
    env._G = env
    local chunk
    if setfenv then
        chunk = assert(loadfile("src/installer_sha256.lua"))
        setfenv(chunk, env)
    else
        chunk = assert(loadfile("src/installer_sha256.lua", "t", env))
    end
    return chunk()
end
local calls = 0
local function bitop(a, b, exclusive)
    assert(a >= 0 and a <= 65535 and b >= 0 and b <= 65535, "native bit operand exceeds a 16-bit limb")
    calls = calls + 1
    local result, power = 0, 1
    for _ = 1, 16 do
        local av, bv = a % 2, b % 2
        if (exclusive and av ~= bv) or (not exclusive and av == 1 and bv == 1) then result = result + power end
        a, b, power = (a - av) / 2, (b - bv) / 2, power * 2
    end
    return result
end
local accelerated = load_with_bit({
    bxor = function(a, b) return bitop(a, b, true) end,
    band = function(a, b) return bitop(a, b, false) end,
})
local probe_calls = calls
equal(accelerated.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
equal(calls > probe_calls, true)
equal(accelerated.hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
-- Incompatible or throwing bit libraries must fall back to portable arithmetic.
local incompatible = load_with_bit({ bxor = function() return 0 end, band = function() return 0 end })
equal(incompatible.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
local throwing = load_with_bit({ bxor = function() error("unsupported") end, band = function() return 0 end })
equal(throwing.hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
print("installer SHA256: " .. count .. " assertions passed")
