--!strict
-- Base64 (RFC 4648, standard alphabet, "=" padding) between Luau strings and buffers.
-- decode ignores ASCII whitespace anywhere in the input and errors on any other foreign character,
-- on a misplaced "=" and on a dangling single character. encode never inserts line breaks.
-- Pure Luau: string + buffer only (fast path: 4 characters -> 3 bytes per iteration).

local Base64 = {}

local ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

-- byte -> 6-bit value, -1 for anything that is not an alphabet character, -2 for "="
local DECODE: { number } = table.create(256, -1)
for i = 1, 64 do
	DECODE[string.byte(ALPHABET, i) + 1] = i - 1
end
DECODE[string.byte("=") + 1] = -2

-- 6-bit value -> one-character string
local ENCODE: { string } = table.create(64)
for i = 1, 64 do
	ENCODE[i] = string.sub(ALPHABET, i, i)
end

local function badChar(s: string, pos: number): never
	local ch = string.sub(s, pos, pos)
	error(string.format("Base64.decode: invalid character %q at position %d", ch, pos), 3)
end

-- Decodes `s` into a new buffer holding exactly the decoded bytes.
function Base64.decode(s: string): buffer
	if type(s) ~= "string" then
		error("Base64.decode expects a string, got " .. typeof(s), 2)
	end
	-- whitespace is tolerated anywhere (chunked modules, wrapped text): strip it once up front
	if string.find(s, "%s") then
		s = (string.gsub(s, "%s+", ""))
	end
	local n = #s
	if n == 0 then
		return buffer.create(0)
	end
	-- the padded tail is handled separately; everything before it is full quartets
	local pad = 0
	if string.byte(s, n) == 61 then -- "="
		pad = 1
		if n >= 2 and string.byte(s, n - 1) == 61 then
			pad = 2
		end
	end
	local rem = n % 4
	-- without padding a dangling 2 or 3 chars are accepted (unpadded input); 1 is never valid
	if rem == 1 then
		error("Base64.decode: input length is invalid (dangling character)", 2)
	end
	local fullQuartets: number
	local tail: number -- number of significant characters in the final partial group (0, 2 or 3)
	if pad > 0 then
		if rem ~= 0 then
			error("Base64.decode: padded input length must be a multiple of 4", 2)
		end
		fullQuartets = n // 4 - 1
		tail = 4 - pad
	else
		fullQuartets = n // 4
		tail = rem
	end
	local outLen = fullQuartets * 3 + (if tail == 3 then 2 elseif tail == 2 then 1 else 0)
	local out = buffer.create(outLen)
	local dec = DECODE
	local o = 0
	local i = 1
	for _ = 1, fullQuartets do
		local a, b, c, d = string.byte(s, i, i + 3)
		local va, vb, vc, vd = dec[a + 1], dec[b + 1], dec[c + 1], dec[d + 1]
		if va < 0 or vb < 0 or vc < 0 or vd < 0 then
			local bad = if va < 0 then i elseif vb < 0 then i + 1 elseif vc < 0 then i + 2 else i + 3
			badChar(s, bad)
		end
		-- 24 bits: va<<18 | vb<<12 | vc<<6 | vd, written little-endian byte by byte
		buffer.writeu8(out, o, va * 4 + vb // 16)
		buffer.writeu8(out, o + 1, (vb % 16) * 16 + vc // 4)
		buffer.writeu8(out, o + 2, (vc % 4) * 64 + vd)
		o += 3
		i += 4
	end
	if tail >= 2 then
		local a, b = string.byte(s, i, i + 1)
		local va, vb = dec[a + 1], dec[b + 1]
		if va < 0 then
			badChar(s, i)
		end
		if vb < 0 then
			badChar(s, i + 1)
		end
		buffer.writeu8(out, o, va * 4 + vb // 16)
		if tail == 3 then
			local c = string.byte(s, i + 2)
			local vc = dec[c + 1]
			if vc < 0 then
				badChar(s, i + 2)
			end
			buffer.writeu8(out, o + 1, (vb % 16) * 16 + vc // 4)
		end
	end
	return out
end

-- Encodes the whole buffer as standard base64 with "=" padding.
function Base64.encode(b: buffer): string
	if type(b) ~= "buffer" then
		error("Base64.encode expects a buffer, got " .. typeof(b), 2)
	end
	local n = buffer.len(b)
	local enc = ENCODE
	local parts: { string } = table.create((n + 2) // 3)
	local k = 0
	local i = 0
	local full = n - n % 3
	while i < full do
		local x = buffer.readu8(b, i)
		local y = buffer.readu8(b, i + 1)
		local z = buffer.readu8(b, i + 2)
		k += 1
		parts[k] = enc[x // 4 + 1] .. enc[(x % 4) * 16 + y // 16 + 1] .. enc[(y % 16) * 4 + z // 64 + 1] .. enc[z % 64 + 1]
		i += 3
	end
	local rem = n - full
	if rem == 1 then
		local x = buffer.readu8(b, i)
		k += 1
		parts[k] = enc[x // 4 + 1] .. enc[(x % 4) * 16 + 1] .. "=="
	elseif rem == 2 then
		local x = buffer.readu8(b, i)
		local y = buffer.readu8(b, i + 1)
		k += 1
		parts[k] = enc[x // 4 + 1] .. enc[(x % 4) * 16 + y // 16 + 1] .. enc[(y % 16) * 4 + 1] .. "="
	end
	return table.concat(parts)
end

return Base64
