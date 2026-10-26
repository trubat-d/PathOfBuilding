-- Path of Building
--
-- Module: Jewel Data File Loader
-- Loads compressed jewel data from one file or a numbered set of parts.
--
local t_concat = table.concat

-- (zlib through LuaJIT's FFI: a background thread's Inflate has failed on
-- the larger files - Lethal Pride - where this one doesn't; the app ships
-- zlib1.dll on Windows)
local function ffiInflate(data)
	local okFfi, ffi = pcall(require, "ffi")
	if not okFfi or not ffi then return nil end
	local z
	for _, name in ipairs({ "zlib1", "z", "libz.so.1" }) do
		local okLoad, lib = pcall(ffi.load, name)
		if okLoad and lib then z = lib break end
	end
	if not z then return nil end
	pcall(ffi.cdef, [[
typedef struct pob_z_stream_s { const unsigned char *next_in; unsigned avail_in; unsigned long total_in; unsigned char *next_out; unsigned avail_out; unsigned long total_out; const char *msg; void *state; void *zalloc; void *zfree; void *opaque; int data_type; unsigned long adler; unsigned long reserved; } pob_z_stream;
int inflateInit2_(pob_z_stream *strm, int windowBits, const char *version, int stream_size);
int inflate(pob_z_stream *strm, int flush);
int inflateEnd(pob_z_stream *strm);
const char *zlibVersion(void);
]])
	local ok, result = pcall(function()
		local strm = ffi.new("pob_z_stream")
		if z.inflateInit2_(strm, 15 + 32, z.zlibVersion(), ffi.sizeof(strm)) ~= 0 then return nil end
		strm.next_in = ffi.cast("const unsigned char*", data)
		strm.avail_in = #data
		local chunks = { }
		local bufSize = 4 * 1024 * 1024
		local buf = ffi.new("unsigned char[?]", bufSize)
		while true do
			strm.next_out = buf
			strm.avail_out = bufSize
			local ret = z.inflate(strm, 0)
			chunks[#chunks + 1] = ffi.string(buf, bufSize - strm.avail_out)
			if ret == 1 then break end
			if ret ~= 0 then z.inflateEnd(strm) return nil end
		end
		z.inflateEnd(strm)
		return t_concat(chunks)
	end)
	return ok and result or nil
end

local function loadJewelFile(jewelTypeName, cacheUncompressed)
	local jewelPath = "/Data/TimelessJewelData/" .. jewelTypeName
	local scriptPath = GetScriptPath()
	if scriptPath == "" then
		-- The desktop app supplies its script folder. Headless tests may start in
		-- either the repository root or the src folder, so check both locations.
		local relativePath = "." .. jewelPath
		local file = io.open(relativePath .. ".zip", "rb") or io.open(relativePath .. ".zip.part0", "rb") or io.open(relativePath .. ".bin", "rb")
		if file then
			file:close()
			scriptPath = "."
		else
			scriptPath = "./src"
		end
	end
	cacheUncompressed = cacheUncompressed ~= false

	local uncompressedFileAttr = { }
	if cacheUncompressed then
		local fileHandle = NewFileSearch(scriptPath .. jewelPath .. ".bin")
		if fileHandle then
			uncompressedFileAttr.fileName = fileHandle:GetFileName()
			uncompressedFileAttr.modified = fileHandle:GetFileModifiedTime()
		end
	end

	local compressedFileAttr = { }
	local fileHandle = NewFileSearch(scriptPath .. jewelPath .. ".zip")
	if fileHandle then
		compressedFileAttr.modified = fileHandle:GetFileModifiedTime()
	end
	fileHandle = NewFileSearch(scriptPath .. jewelPath .. ".zip.part*")
	if fileHandle then
		compressedFileAttr.modified = fileHandle:GetFileModifiedTime()
	end

	-- (no file search - a background thread - : the app's uncompressed copy if it made one)
	if cacheUncompressed and not uncompressedFileAttr.modified and not compressedFileAttr.modified then
		local uncompressedFile = io.open(scriptPath .. jewelPath .. ".bin", "rb")
		if uncompressedFile then
			local jewelData = uncompressedFile:read("*a")
			uncompressedFile:close()
			if jewelData and jewelData ~= "" then return jewelData end
		end
	end
	if uncompressedFileAttr.modified and uncompressedFileAttr.modified > (compressedFileAttr.modified or 0) then
		ConPrintf("Uncompressed jewel data is up-to-date, loading " .. uncompressedFileAttr.fileName)
		local uncompressedFile = io.open(scriptPath .. jewelPath .. ".bin", "rb")
		if uncompressedFile then
			local jewelData = uncompressedFile:read("*a")
			uncompressedFile:close()
			-- (an empty copy - a failed write - is made again from the compressed file)
			if jewelData and jewelData ~= "" then
				return jewelData
			end
		end
	end

	if cacheUncompressed then
		ConPrintf("Failed to load " .. scriptPath .. jewelPath .. ".bin, or data is out of date, falling back to compressed file")
	end
	local compressedFile = io.open(scriptPath .. jewelPath .. ".zip", "rb")
	local compressedData
	if compressedFile then
		compressedData = compressedFile:read("*a")
		compressedFile:close()
	else
		local splitFile = { }
		local part = 0
		while true do
			local file = io.open(scriptPath .. jewelPath .. ".zip.part" .. part, "rb")
			if not file then
				break
			end
			splitFile[part + 1] = file:read("*a")
			file:close()
			part = part + 1
		end
		compressedData = t_concat(splitFile, "")
	end

	if not compressedData or compressedData == "" then
		ConPrintf("Failed to load jewel data: " .. jewelTypeName)
		return
	end

	local jewelData = Inflate(compressedData)
	if not jewelData or jewelData == "" then jewelData = ffiInflate(compressedData) end
	if not jewelData or jewelData == "" then
		-- (a background thread's Inflate can come back empty: the app's own
		-- uncompressed copy instead, when there is one)
		local uncompressedFile = io.open(scriptPath .. jewelPath .. ".bin", "rb")
		if uncompressedFile then
			jewelData = uncompressedFile:read("*a")
			uncompressedFile:close()
		end
		if not jewelData or jewelData == "" then
			ConPrintf("Failed to decompress jewel data: " .. jewelTypeName)
			return
		end
		return jewelData
	end
	if cacheUncompressed then
		local uncompressedFile = io.open(scriptPath .. jewelPath .. ".bin", "wb+")
		if uncompressedFile then
			uncompressedFile:write(jewelData)
			uncompressedFile:close()
		end
	end
	return jewelData
end

return loadJewelFile
