--!strict
-- PngDecoder: pure-Luau PNG decoding to RGBA8 (for EditableImage:WritePixelsBuffer).
--
--   PngDecoder.decode(png: buffer, options?) -> { width, height, rgba: buffer, colorType, adler32 }
--
-- Supported: 8-bit colour types 0 (grey), 2 (RGB), 4 (grey + alpha), 6 (RGBA), non-interlaced,
-- every scanline filter (None / Sub / Up / Average / Paeth), any number of IDAT chunks. Anything
-- else (palette, 1/2/4/16-bit depth, Adam7 interlace, bad signature) raises a clear error.
-- Output: row-major RGBA, 4 bytes per pixel, alpha 255 when the source has none. The zlib stream
-- is verified against its Adler-32 (the checksum is returned as `adler32`). Chunk CRCs are not
-- verified (the data is trusted, embedded in the place; Adler-32 covers the pixel stream).
--
-- options = { onProgress: ((fraction: number) -> ())? }  -- 0..1, about every 64 KB of work (inflate,
--           Adler-32 slices, unfilter rows and RGBA expansion rows all report), ending with exactly 1

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Inflate = require(Shared.Util.Inflate)

local PngDecoder = {}

export type Options = { onProgress: ((fraction: number) -> ())? }
export type Image = { width: number, height: number, rgba: buffer, colorType: number, adler32: number }

local SIGNATURE = { 137, 80, 78, 71, 13, 10, 26, 10 }
local CHANNELS = { [0] = 1, [2] = 3, [4] = 2, [6] = 4 }

-- rows per progress callback (~64 KB of row data)
local function progressRows(rowLen: number): number
	return math.max(1, 65536 // rowLen)
end

local function readu32be(b: buffer, pos: number): number
	return buffer.readu8(b, pos) * 16777216 + buffer.readu8(b, pos + 1) * 65536 + buffer.readu8(b, pos + 2) * 256 + buffer.readu8(b, pos + 3)
end

-- Reverses the scanline filters in place. raw = height rows of (1 filter byte + stride bytes).
local function unfilter(raw: buffer, width: number, height: number, bpp: number, onRow: ((row: number) -> ())?)
	local stride = width * bpp
	local rowLen = stride + 1
	for row = 0, height - 1 do
		local base = row * rowLen
		local ft = buffer.readu8(raw, base)
		local start = base + 1 -- first pixel byte of this row
		local prior = start - rowLen -- same byte on the previous row (only valid when row > 0)
		if ft == 0 then
			-- None
		elseif ft == 1 then
			-- Sub: add the byte bpp to the left
			for i = start + bpp, start + stride - 1 do
				buffer.writeu8(raw, i, (buffer.readu8(raw, i) + buffer.readu8(raw, i - bpp)) % 256)
			end
		elseif ft == 2 then
			-- Up: add the byte above
			if row > 0 then
				for i = start, start + stride - 1 do
					buffer.writeu8(raw, i, (buffer.readu8(raw, i) + buffer.readu8(raw, i - rowLen)) % 256)
				end
			end
		elseif ft == 3 then
			-- Average: add floor((left + above) / 2)
			if row == 0 then
				for i = start + bpp, start + stride - 1 do
					buffer.writeu8(raw, i, (buffer.readu8(raw, i) + buffer.readu8(raw, i - bpp) // 2) % 256)
				end
			else
				for i = start, start + bpp - 1 do
					buffer.writeu8(raw, i, (buffer.readu8(raw, i) + buffer.readu8(raw, i - rowLen) // 2) % 256)
				end
				for i = start + bpp, start + stride - 1 do
					buffer.writeu8(raw, i, (buffer.readu8(raw, i) + (buffer.readu8(raw, i - bpp) + buffer.readu8(raw, i - rowLen)) // 2) % 256)
				end
			end
		elseif ft == 4 then
			-- Paeth
			if row == 0 then
				-- above and upper-left are 0: the predictor degenerates to the left byte
				for i = start + bpp, start + stride - 1 do
					buffer.writeu8(raw, i, (buffer.readu8(raw, i) + buffer.readu8(raw, i - bpp)) % 256)
				end
			else
				for i = start, start + bpp - 1 do
					-- no left pixel: predictor is the byte above
					buffer.writeu8(raw, i, (buffer.readu8(raw, i) + buffer.readu8(raw, i - rowLen)) % 256)
				end
				-- walk each channel separately so a (left) and c (upper-left) roll along in locals
				for ch = 0, bpp - 1 do
					local a = buffer.readu8(raw, start + ch)
					local c = buffer.readu8(raw, prior + ch)
					for i = start + bpp + ch, start + stride - 1, bpp do
						local b = buffer.readu8(raw, i - rowLen)
						local p = a + b - c
						local pa = math.abs(p - a)
						local pb = math.abs(p - b)
						local pc = math.abs(p - c)
						local pred
						if pa <= pb and pa <= pc then
							pred = a
						elseif pb <= pc then
							pred = b
						else
							pred = c
						end
						a = (buffer.readu8(raw, i) + pred) % 256
						buffer.writeu8(raw, i, a)
						c = b
					end
				end
			end
		else
			error(string.format("PngDecoder: invalid filter type %d on row %d", ft, row), 0)
		end
		if onRow then
			onRow(row)
		end
	end
end

-- Expands the unfiltered rows to RGBA8. onRow (optional) is called before each row is expanded.
local function toRGBA(raw: buffer, width: number, height: number, channels: number, onRow: ((row: number) -> ())?): buffer
	local stride = width * channels
	local rowLen = stride + 1
	local out = buffer.create(width * height * 4)
	local o = 0
	if channels == 4 then
		for row = 0, height - 1 do
			if onRow then
				onRow(row)
			end
			buffer.copy(out, o, raw, row * rowLen + 1, stride)
			o += stride
		end
	elseif channels == 3 then
		for row = 0, height - 1 do
			if onRow then
				onRow(row)
			end
			local i = row * rowLen + 1
			for _ = 1, width do
				-- little-endian u32 = r | g << 8 | b << 16 | 255 << 24
				buffer.writeu32(out, o, buffer.readu8(raw, i) + buffer.readu8(raw, i + 1) * 256 + buffer.readu8(raw, i + 2) * 65536 + 4278190080)
				i += 3
				o += 4
			end
		end
	elseif channels == 2 then
		for row = 0, height - 1 do
			if onRow then
				onRow(row)
			end
			local i = row * rowLen + 1
			for _ = 1, width do
				local g = buffer.readu8(raw, i)
				buffer.writeu32(out, o, g * 65793 + buffer.readu8(raw, i + 1) * 16777216)
				i += 2
				o += 4
			end
		end
	else
		for row = 0, height - 1 do
			if onRow then
				onRow(row)
			end
			local i = row * rowLen + 1
			for _ = 1, width do
				buffer.writeu32(out, o, buffer.readu8(raw, i) * 65793 + 4278190080)
				i += 1
				o += 4
			end
		end
	end
	return out
end

function PngDecoder.decode(png: buffer, options: Options?): Image
	if type(png) ~= "buffer" then
		error("PngDecoder.decode expects a buffer, got " .. typeof(png), 2)
	end
	local n = buffer.len(png)
	if n < 8 + 25 + 12 then
		error("PngDecoder: not a PNG (too short)", 2)
	end
	for i = 1, 8 do
		if buffer.readu8(png, i - 1) ~= SIGNATURE[i] then
			error("PngDecoder: not a PNG (bad signature)", 2)
		end
	end
	local onProgress = options and options.onProgress or nil

	-- walk the chunks: IHDR first, then collect the IDAT ranges
	local pos = 8
	local width, height, bitDepth, colorType = 0, 0, 0, 0
	local sawHeader = false
	local idat: { number } = {} -- pairs of (offset, length)
	local idatTotal = 0
	while pos + 8 <= n do
		local length = readu32be(png, pos)
		local kind = buffer.readstring(png, pos + 4, 4)
		local dataStart = pos + 8
		if dataStart + length + 4 > n then
			error("PngDecoder: truncated chunk " .. kind, 2)
		end
		if kind == "IHDR" then
			if length ~= 13 then
				error("PngDecoder: bad IHDR length", 2)
			end
			width = readu32be(png, dataStart)
			height = readu32be(png, dataStart + 4)
			bitDepth = buffer.readu8(png, dataStart + 8)
			colorType = buffer.readu8(png, dataStart + 9)
			local compression = buffer.readu8(png, dataStart + 10)
			local filterMethod = buffer.readu8(png, dataStart + 11)
			local interlace = buffer.readu8(png, dataStart + 12)
			if width == 0 or height == 0 then
				error("PngDecoder: zero image size", 2)
			end
			if colorType == 3 then
				error("PngDecoder: unsupported PNG (palette / indexed colour); re-save as RGB or RGBA", 2)
			end
			if CHANNELS[colorType] == nil then
				error(string.format("PngDecoder: unsupported colour type %d", colorType), 2)
			end
			if bitDepth ~= 8 then
				error(string.format("PngDecoder: unsupported bit depth %d (only 8-bit channels)", bitDepth), 2)
			end
			if interlace ~= 0 then
				error("PngDecoder: unsupported PNG (interlaced / Adam7); re-save non-interlaced", 2)
			end
			if compression ~= 0 or filterMethod ~= 0 then
				error("PngDecoder: unsupported compression or filter method", 2)
			end
			sawHeader = true
		elseif kind == "IDAT" then
			if not sawHeader then
				error("PngDecoder: IDAT before IHDR", 2)
			end
			table.insert(idat, dataStart)
			table.insert(idat, length)
			idatTotal += length
		elseif kind == "IEND" then
			break
		end
		pos = dataStart + length + 4
	end
	if not sawHeader then
		error("PngDecoder: missing IHDR", 2)
	end
	if idatTotal == 0 then
		error("PngDecoder: no image data (IDAT)", 2)
	end

	local channels = CHANNELS[colorType]
	local stride = width * channels
	local rawSize = height * (stride + 1)

	-- concatenate the IDAT chunks (usually one copy; a single chunk is sliced directly)
	local stream: buffer
	if #idat == 2 then
		stream = buffer.create(idat[2])
		buffer.copy(stream, 0, png, idat[1], idat[2])
	else
		stream = buffer.create(idatTotal)
		local o = 0
		for i = 1, #idat, 2 do
			buffer.copy(stream, o, png, idat[i], idat[i + 1])
			o += idat[i + 1]
		end
	end

	-- progress: inflating is roughly half of the work, unfiltering + expansion the other half
	local inflateOptions: Inflate.Options = { expectedSize = rawSize }
	if onProgress then
		inflateOptions.onProgress = function(done: number)
			onProgress(0.5 * math.min(done / rawSize, 1))
		end
	end
	local raw, adler = Inflate.zlibDecompress(stream, inflateOptions)
	if buffer.len(raw) ~= rawSize then
		error(string.format("PngDecoder: image data has %d bytes, expected %d", buffer.len(raw), rawSize), 2)
	end

	-- progress: 0.5..0.9 while unfiltering, 0.9..1 while expanding to RGBA, exactly 1 at the end
	local onRow: ((row: number) -> ())? = nil
	local onExpandRow: ((row: number) -> ())? = nil
	if onProgress then
		local rowsPerStep = progressRows(stride + 1)
		onRow = function(row: number)
			if row % rowsPerStep == 0 then
				onProgress(0.5 + 0.4 * (row + 1) / height)
			end
		end
		local expandRowsPerStep = progressRows(width * 4)
		onExpandRow = function(row: number)
			if row % expandRowsPerStep == 0 then
				onProgress(0.9 + 0.1 * row / height)
			end
		end
	end
	unfilter(raw, width, height, channels, onRow)
	local rgba = toRGBA(raw, width, height, channels, onExpandRow)
	if onProgress then
		onProgress(1)
	end
	return { width = width, height = height, rgba = rgba, colorType = colorType, adler32 = adler }
end

return PngDecoder
