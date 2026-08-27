local bit = require("bit")

local band = bit.band
local bor = bit.bor
local bxor = bit.bxor
local bnot = bit.bnot
local lshift = bit.lshift
local rshift = bit.rshift
local ror = bit.ror

local Crypto = {}

local function u32(n)
    return band(n, 0xffffffff)
end

local function add(...)
    local result = 0
    for i = 1, select("#", ...) do
        result = u32(result + select(i, ...))
    end
    return result
end

local function be_word(s, i)
    local b1, b2, b3, b4 = s:byte(i, i + 3)
    return bor(lshift(b1, 24), lshift(b2, 16), lshift(b3, 8), b4)
end

local function word_to_be_hex(n)
    return string.format(
        "%02x%02x%02x%02x",
        band(rshift(n, 24), 0xff),
        band(rshift(n, 16), 0xff),
        band(rshift(n, 8), 0xff),
        band(n, 0xff)
    )
end

local sha256_k = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
}

function Crypto.sha256_hex(message)
    message = tostring(message or "")
    local bit_len = #message * 8
    local padding_len = (56 - (#message + 1) % 64) % 64
    message = message .. string.char(0x80) .. string.rep("\0", padding_len)
    message = message .. string.char(
        0, 0, 0, 0,
        band(rshift(bit_len, 24), 0xff),
        band(rshift(bit_len, 16), 0xff),
        band(rshift(bit_len, 8), 0xff),
        band(bit_len, 0xff)
    )

    local h = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    }

    for chunk = 1, #message, 64 do
        local w = {}
        for i = 0, 15 do
            w[i] = be_word(message, chunk + i * 4)
        end
        for i = 16, 63 do
            local s0 = bxor(ror(w[i - 15], 7), ror(w[i - 15], 18), rshift(w[i - 15], 3))
            local s1 = bxor(ror(w[i - 2], 17), ror(w[i - 2], 19), rshift(w[i - 2], 10))
            w[i] = add(w[i - 16], s0, w[i - 7], s1)
        end

        local a, b, c, d, e, f, g, hh = h[1], h[2], h[3], h[4], h[5], h[6], h[7], h[8]
        for i = 0, 63 do
            local s1 = bxor(ror(e, 6), ror(e, 11), ror(e, 25))
            local ch = bxor(band(e, f), band(bnot(e), g))
            local temp1 = add(hh, s1, ch, sha256_k[i + 1], w[i])
            local s0 = bxor(ror(a, 2), ror(a, 13), ror(a, 22))
            local maj = bxor(band(a, b), band(a, c), band(b, c))
            local temp2 = add(s0, maj)
            hh, g, f, e, d, c, b, a = g, f, e, add(d, temp1), c, b, a, add(temp1, temp2)
        end

        h[1] = add(h[1], a)
        h[2] = add(h[2], b)
        h[3] = add(h[3], c)
        h[4] = add(h[4], d)
        h[5] = add(h[5], e)
        h[6] = add(h[6], f)
        h[7] = add(h[7], g)
        h[8] = add(h[8], hh)
    end

    local out = {}
    for i = 1, 8 do
        out[i] = word_to_be_hex(h[i])
    end
    return table.concat(out)
end

return Crypto
