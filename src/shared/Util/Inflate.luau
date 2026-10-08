--!strict
--!native
-- Inflate: pure-Luau DEFLATE (RFC 1951) and zlib (RFC 1950) decompression over buffers.
--
--   Inflate.zlibDecompress(data, options?) -> (buffer, adler32)
--       Parses the 2-byte zlib header, inflates stored / fixed / dynamic blocks and verifies the
--       Adler-32 trailer ("adler32 mismatch" on failure). The second return is the verified checksum.
--       With onProgress set, the checksum pass is sliced (ADLER_SLICE bytes) and the callback fires
--       between slices too (doneBytes = the final size), so no single block exceeds a few ms.
--   Inflate.inflateRaw(data, offset, options?) -> (buffer, consumedBytes)
--       Raw DEFLATE starting at byte `offset` (0-based); consumedBytes is the number of input bytes
--       the stream occupied (bit-aligned up to the next byte).
--   Inflate.adler32(data, offset?, count?) -> number
--
-- options = {
--     onProgress: ((doneBytes: number, totalHint: number?) -> ())?  -- called about every 64 KB of
--                 output (and at the end) so callers can task.wait() to spread work over frames
--     expectedSize: number?                                           -- output buffer preallocation
-- }
--
-- Performance notes: the Huffman decoders are table-driven (a 10-bit first-level lookup indexed by
-- the next 10 input bits, falling back to a canonical count/symbol walk for the rare longer codes);
-- the bit buffer is a plain number refilled 32 bits at a time with buffer.readu32, so no per-bit
-- function calls happen in the main loop; matches are copied with buffer.copy / buffer.fill.

local Inflate = {}

local FAST_BITS = 10
local FAST_SIZE = 1024
local FAST_MASK = 1023
local MAX_BITS = 15
local PROGRESS_STEP = 65536
local ADLER_SLICE = 262144 -- bytes of Adler-32 work between progress callbacks

-- 2^k for k = 0..56 (index k + 1); the bit buffer never exceeds 2^53 so arithmetic stays exact
local POW2: { number } = table.create(57)
for k = 0, 56 do
	POW2[k + 1] = 2 ^ k
end

-- bit reversal of a byte (index value + 1)
local REV8: { number } = table.create(256)
for v = 0, 255 do
	local r = 0
	local x = v
	for _ = 1, 8 do
		r = r * 2 + x % 2
		x = x // 2
	end
	REV8[v + 1] = r
end

-- length codes 257..285 -> base length / extra bits (index symbol - 256)
local LEN_BASE = { 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 }
local LEN_EXTRA = { 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 }
-- distance codes 0..29 -> base distance / extra bits (index symbol + 1)
local DIST_BASE = { 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 }
local DIST_EXTRA = { 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 }
-- order in which code-length code lengths are transmitted
local CL_ORDER = { 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 }

type Huffman = {
	fast: { number }, -- index (next 10 bits) + 1 -> symbol * 16 + codeLength, 0 = not resolvable in 10 bits
	count: { number }, -- index len + 1 -> number of codes of that length (len 0..15)
	symbol: { number }, -- symbols ordered by (code length, symbol value), 1-based
}

export type Options = {
	onProgress: ((doneBytes: number, totalHint: number?) -> ())?,
	expectedSize: number?,
}

-- Builds the decoding tables for `n` symbols whose code lengths are lengths[1..n] (0 = unused).
local function buildHuffman(lengths: { number }, n: number): Huffman
	local count: { number } = table.create(MAX_BITS + 1, 0)
	for i = 1, n do
		local len = lengths[i]
		count[len + 1] += 1
	end
	count[1] = 0
	-- over-subscribed code sets are invalid; incomplete ones are tolerated (zlib allows a single code)
	local left = 1
	for len = 1, MAX_BITS do
		left = left * 2 - count[len + 1]
		if left < 0 then
			error("Inflate: over-subscribed Huffman code set", 0)
		end
	end
	-- canonical first codes per length and the offsets of each length in `symbol`
	local nextCode: { number } = table.create(MAX_BITS + 1, 0)
	local offs: { number } = table.create(MAX_BITS + 1, 0)
	local code = 0
	local offset = 0
	for len = 1, MAX_BITS do
		code = (code + count[len]) * 2
		nextCode[len + 1] = code
		offs[len + 1] = offset
		offset += count[len + 1]
	end
	local symbol: { number } = table.create(offset, 0)
	local fast: { number } = table.create(FAST_SIZE, 0)
	for sym = 0, n - 1 do
		local len = lengths[sym + 1]
		if len > 0 then
			local c = nextCode[len + 1]
			nextCode[len + 1] = c + 1
			local o = offs[len + 1]
			offs[len + 1] = o + 1
			symbol[o + 1] = sym
			if len <= FAST_BITS then
				-- deflate codes are packed MSB-first, our bit buffer is LSB-first: reverse the code
				local rev = (REV8[c % 256 + 1] * 256 + REV8[c // 256 + 1]) // POW2[16 - len + 1]
				local entry = sym * 16 + len
				local step = POW2[len + 1]
				for idx = rev, FAST_MASK, step do
					fast[idx + 1] = entry
				end
			end
		end
	end
	return { fast = fast, count = count, symbol = symbol }
end

-- Fixed Huffman tables (RFC 1951 3.2.6), built once on first use.
local fixedLit: Huffman? = nil
local fixedDist: Huffman? = nil
local function getFixed(): (Huffman, Huffman)
	if fixedLit == nil or fixedDist == nil then
		local lens: { number } = table.create(288, 8)
		for i = 145, 256 do
			lens[i] = 9
		end
		for i = 257, 280 do
			lens[i] = 7
		end
		local dlens: { number } = table.create(30, 5)
		fixedLit = buildHuffman(lens, 288)
		fixedDist = buildHuffman(dlens, 30)
	end
	return fixedLit :: Huffman, fixedDist :: Huffman
end

-- Slow path for codes longer than FAST_BITS (or invalid codes): canonical walk, one bit at a time.
-- Requires at least MAX_BITS bits in the bit buffer. Returns (symbol, bitbuf, bitcnt).
local function decodeSlow(h: Huffman, bitbuf: number, bitcnt: number): (number, number, number)
	local count = h.count
	local symbol = h.symbol
	local code = 0
	local first = 0
	local index = 0
	for len = 1, MAX_BITS do
		code += bitbuf % 2
		bitbuf = bitbuf // 2
		bitcnt -= 1
		local c = count[len + 1]
		if code - c < first then
			return symbol[index + (code - first) + 1], bitbuf, bitcnt
		end
		index += c
		first = (first + c) * 2
		code *= 2
	end
	error("Inflate: invalid Huffman code", 0)
end

-- Continues an Adler-32 (s1, s2) over data[start, stop). Returns the updated (s1, s2).
local function adlerUpdate(s1: number, s2: number, data: buffer, start: number, stop: number): (number, number)
	local i = start
	while i < stop do
		-- 5552 is the largest block size that keeps s2 below 2^32 before reduction
		local blockEnd = math.min(i + 5552, stop)
		local blockEnd4 = i + (blockEnd - i) // 4 * 4
		while i < blockEnd4 do
			s1 += buffer.readu8(data, i)
			s2 += s1
			s1 += buffer.readu8(data, i + 1)
			s2 += s1
			s1 += buffer.readu8(data, i + 2)
			s2 += s1
			s1 += buffer.readu8(data, i + 3)
			s2 += s1
			i += 4
		end
		while i < blockEnd do
			s1 += buffer.readu8(data, i)
			s2 += s1
			i += 1
		end
		s1 %= 65521
		s2 %= 65521
	end
	return s1, s2
end

-- Adler-32 of data[offset, offset + count).
function Inflate.adler32(data: buffer, offset: number?, count: number?): number
	local start = offset or 0
	local n = count or (buffer.len(data) - start)
	local s1, s2 = adlerUpdate(1, 0, data, start, start + n)
	return s2 * 65536 + s1
end

-- Raw DEFLATE decode of `input` starting at `offset`. Returns (output, consumedBytes).
function Inflate.inflateRaw(input: buffer, offset: number, options: Options?): (buffer, number)
	if type(input) ~= "buffer" then
		error("Inflate.inflateRaw expects a buffer, got " .. typeof(input), 2)
	end
	local inputLen = buffer.len(input)
	offset = offset or 0
	if offset < 0 or offset > inputLen then
		error("Inflate.inflateRaw: offset out of range", 2)
	end
	local onProgress = options and options.onProgress or nil
	local expectedSize = options and options.expectedSize or nil

	-- The stream is copied into a zero-padded buffer so the 32-bit refill never reads out of bounds;
	-- `limit` is the last position a refill may legally read from (a valid stream reads at most 4
	-- bytes past its end).
	local len = inputLen - offset
	local data = buffer.create(len + 8)
	buffer.copy(data, 0, input, offset, len)
	local limit = len + 4

	local POW2 = POW2
	local LEN_BASE, LEN_EXTRA, DIST_BASE, DIST_EXTRA = LEN_BASE, LEN_EXTRA, DIST_BASE, DIST_EXTRA

	local cap = if expectedSize and expectedSize > 0 then expectedSize else math.max(1024, len * 4)
	local out = buffer.create(cap)
	local outPos = 0
	local nextProgress = if onProgress then PROGRESS_STEP else math.huge
	local checkpoint = math.min(cap, nextProgress)

	local pos = 0 -- next byte of `data` to load into the bit buffer
	local bitbuf = 0 -- LSB-first bit buffer, holds exactly `bitcnt` bits
	local bitcnt = 0

	local function grow(minSize: number)
		local newCap = math.max(cap * 2, minSize)
		local bigger = buffer.create(newCap)
		buffer.copy(bigger, 0, out, 0, outPos)
		out = bigger
		cap = newCap
	end

	local function service()
		if outPos >= cap then
			grow(cap + 1)
		end
		if outPos >= nextProgress then
			nextProgress = outPos + PROGRESS_STEP;
			(onProgress :: any)(outPos, expectedSize)
		end
		checkpoint = math.min(cap, nextProgress)
	end

	-- header-side bit reads (not on the hot path)
	local function readBits(n: number): number
		while bitcnt < n do
			if pos > limit then
				error("Inflate: unexpected end of data", 0)
			end
			bitbuf += buffer.readu8(data, pos) * POW2[bitcnt + 1]
			pos += 1
			bitcnt += 8
		end
		local p = POW2[n + 1]
		local v = bitbuf % p
		bitbuf = bitbuf // p
		bitcnt -= n
		return v
	end

	local function decodeSymbol(h: Huffman): number
		while bitcnt < MAX_BITS do
			if pos > limit then
				error("Inflate: unexpected end of data", 0)
			end
			bitbuf += buffer.readu8(data, pos) * POW2[bitcnt + 1]
			pos += 1
			bitcnt += 8
		end
		local entry = h.fast[bitbuf % FAST_SIZE + 1]
		if entry > 0 then
			local l = entry % 16
			bitbuf = bitbuf // POW2[l + 1]
			bitcnt -= l
			return entry // 16
		end
		local sym
		sym, bitbuf, bitcnt = decodeSlow(h, bitbuf, bitcnt)
		return sym
	end

	local final = false
	while not final do
		final = readBits(1) == 1
		local btype = readBits(2)
		if btype == 0 then
			-- stored block: drop to a byte boundary, give unread whole bytes back, then copy
			local r = bitcnt % 8
			bitbuf = bitbuf // POW2[r + 1]
			bitcnt -= r
			pos -= bitcnt // 8
			bitbuf = 0
			bitcnt = 0
			if pos + 4 > len then
				error("Inflate: unexpected end of data", 0)
			end
			local storedLen = buffer.readu16(data, pos)
			local nlen = buffer.readu16(data, pos + 2)
			if storedLen + nlen ~= 65535 then
				error("Inflate: stored block length check failed", 0)
			end
			pos += 4
			if pos + storedLen > len then
				error("Inflate: unexpected end of data", 0)
			end
			if outPos + storedLen > cap then
				grow(outPos + storedLen)
			end
			buffer.copy(out, outPos, data, pos, storedLen)
			outPos += storedLen
			pos += storedLen
			if outPos >= nextProgress then
				service()
			end
		elseif btype == 1 or btype == 2 then
			local lit: Huffman, dist: Huffman
			if btype == 1 then
				lit, dist = getFixed()
			else
				local hlit = readBits(5) + 257
				local hdist = readBits(5) + 1
				local hclen = readBits(4) + 4
				local clLens: { number } = table.create(19, 0)
				for i = 1, hclen do
					clLens[CL_ORDER[i] + 1] = readBits(3)
				end
				local clHuff = buildHuffman(clLens, 19)
				local total = hlit + hdist
				local lens: { number } = table.create(total, 0)
				local i = 1
				while i <= total do
					local sym = decodeSymbol(clHuff)
					if sym < 16 then
						lens[i] = sym
						i += 1
					else
						local value = 0
						local repeatCount
						if sym == 16 then
							if i == 1 then
								error("Inflate: repeat code with no previous length", 0)
							end
							value = lens[i - 1]
							repeatCount = 3 + readBits(2)
						elseif sym == 17 then
							repeatCount = 3 + readBits(3)
						else
							repeatCount = 11 + readBits(7)
						end
						if i + repeatCount - 1 > total then
							error("Inflate: code lengths overflow the declared counts", 0)
						end
						for _ = 1, repeatCount do
							lens[i] = value
							i += 1
						end
					end
				end
				if lens[257] == 0 then
					error("Inflate: missing end-of-block code", 0)
				end
				lit = buildHuffman(lens, hlit)
				local dlens: { number } = table.create(hdist, 0)
				for d = 1, hdist do
					dlens[d] = lens[hlit + d]
				end
				dist = buildHuffman(dlens, hdist)
			end

			local litFast = lit.fast
			local distFast = dist.fast
			-- hot loop: locals only; refills load 32 bits whenever fewer than 21 are buffered
			while true do
				if bitcnt <= 20 then
					if pos > limit then
						error("Inflate: unexpected end of data", 0)
					end
					bitbuf += buffer.readu32(data, pos) * POW2[bitcnt + 1]
					pos += 4
					bitcnt += 32
				end
				local entry = litFast[bitbuf % FAST_SIZE + 1]
				local sym
				if entry > 0 then
					local l = entry % 16
					sym = entry // 16
					bitbuf = bitbuf // POW2[l + 1]
					bitcnt -= l
				else
					sym, bitbuf, bitcnt = decodeSlow(lit, bitbuf, bitcnt)
				end
				if sym < 256 then
					if outPos >= checkpoint then
						service()
					end
					buffer.writeu8(out, outPos, sym)
					outPos += 1
				elseif sym == 256 then
					break
				else
					sym -= 256
					if sym > 29 then
						error("Inflate: invalid length code", 0)
					end
					local length = LEN_BASE[sym]
					local extra = LEN_EXTRA[sym]
					if extra > 0 then
						local p = POW2[extra + 1]
						length += bitbuf % p
						bitbuf = bitbuf // p
						bitcnt -= extra
					end
					if bitcnt <= 20 then
						if pos > limit then
							error("Inflate: unexpected end of data", 0)
						end
						bitbuf += buffer.readu32(data, pos) * POW2[bitcnt + 1]
						pos += 4
						bitcnt += 32
					end
					local dentry = distFast[bitbuf % FAST_SIZE + 1]
					local dsym
					if dentry > 0 then
						local l = dentry % 16
						dsym = dentry // 16
						bitbuf = bitbuf // POW2[l + 1]
						bitcnt -= l
					else
						dsym, bitbuf, bitcnt = decodeSlow(dist, bitbuf, bitcnt)
					end
					if dsym > 29 then
						error("Inflate: invalid distance code", 0)
					end
					local distance = DIST_BASE[dsym + 1]
					local dextra = DIST_EXTRA[dsym + 1]
					if dextra > 0 then
						if bitcnt < dextra then
							if pos > limit then
								error("Inflate: unexpected end of data", 0)
							end
							bitbuf += buffer.readu32(data, pos) * POW2[bitcnt + 1]
							pos += 4
							bitcnt += 32
						end
						local p = POW2[dextra + 1]
						distance += bitbuf % p
						bitbuf = bitbuf // p
						bitcnt -= dextra
					end
					if distance > outPos then
						error("Inflate: distance too far back", 0)
					end
					local target = outPos + length
					if target > cap then
						grow(target)
					end
					local src = outPos - distance
					if distance >= length then
						buffer.copy(out, outPos, out, src, length)
					elseif distance == 1 then
						buffer.fill(out, outPos, buffer.readu8(out, src), length)
					else
						-- overlapping copy: the pattern repeats every `distance` bytes, so the already
						-- written prefix can be doubled until the match is complete
						local done = distance
						buffer.copy(out, outPos, out, src, distance)
						while done < length do
							local n = math.min(done, length - done)
							buffer.copy(out, outPos + done, out, src, n)
							done += n
						end
					end
					outPos = target
					if outPos >= nextProgress then
						service()
					end
				end
			end
		else
			error("Inflate: invalid block type 3", 0)
		end
	end

	-- unread whole bytes in the bit buffer were not part of the stream
	local consumed = pos - bitcnt // 8
	if consumed > len then
		error("Inflate: unexpected end of data", 0)
	end
	if onProgress then
		onProgress(outPos, expectedSize)
	end
	if outPos < cap then
		local trimmed = buffer.create(outPos)
		buffer.copy(trimmed, 0, out, 0, outPos)
		out = trimmed
	end
	return out, consumed
end

-- zlib stream (2-byte header, deflate body, big-endian Adler-32 trailer). Returns (output, adler32).
function Inflate.zlibDecompress(data: buffer, options: Options?): (buffer, number)
	if type(data) ~= "buffer" then
		error("Inflate.zlibDecompress expects a buffer, got " .. typeof(data), 2)
	end
	local n = buffer.len(data)
	if n < 6 then
		error("Inflate: bad zlib header (stream too short)", 2)
	end
	local cmf = buffer.readu8(data, 0)
	local flg = buffer.readu8(data, 1)
	if cmf % 16 ~= 8 or cmf // 16 > 7 or (cmf * 256 + flg) % 31 ~= 0 then
		error("Inflate: bad zlib header", 2)
	end
	if flg // 32 % 2 == 1 then
		error("Inflate: preset dictionaries are not supported", 2)
	end
	local out, consumed = Inflate.inflateRaw(data, 2, options)
	local trailer = 2 + consumed
	if trailer + 4 > n then
		error("Inflate: truncated zlib stream (missing Adler-32 trailer)", 2)
	end
	local expected = buffer.readu8(data, trailer) * 16777216
		+ buffer.readu8(data, trailer + 1) * 65536
		+ buffer.readu8(data, trailer + 2) * 256
		+ buffer.readu8(data, trailer + 3)
	-- The checksum pass is sliced when a progress callback is given so the caller can yield between
	-- slices (a 3 MB pass is tens of milliseconds); the callback sees the final size each time.
	local onProgress = options and options.onProgress or nil
	local outLen = buffer.len(out)
	local s1, s2 = 1, 0
	local start = 0
	while start < outLen do
		local stop = math.min(start + ADLER_SLICE, outLen)
		s1, s2 = adlerUpdate(s1, s2, out, start, stop)
		start = stop
		if onProgress and start < outLen then
			onProgress(outLen, options and options.expectedSize or nil)
		end
	end
	local actual = s2 * 65536 + s1
	if actual ~= expected then
		error(string.format("Inflate: adler32 mismatch (expected %08x, got %08x)", expected, actual), 2)
	end
	return out, actual
end

return Inflate
