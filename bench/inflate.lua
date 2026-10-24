-- Test-only: zlib Inflate for headless PoB (the desktop app provides its own)
local ffi = require("ffi")
ffi.cdef[[
typedef struct z_stream_s { const unsigned char *next_in; unsigned avail_in; unsigned long total_in; unsigned char *next_out; unsigned avail_out; unsigned long total_out; const char *msg; void *state; void *zalloc; void *zfree; void *opaque; int data_type; unsigned long adler; unsigned long reserved; } z_stream;
int inflateInit2_(z_stream *strm, int windowBits, const char *version, int stream_size);
int inflate(z_stream *strm, int flush);
int inflateEnd(z_stream *strm);
const char *zlibVersion(void);
]]
local z = ffi.load("z")
function Inflate(data)
	local strm = ffi.new("z_stream")
	assert(z.inflateInit2_(strm, 15 + 32, z.zlibVersion(), ffi.sizeof(strm)) == 0)
	strm.next_in = ffi.cast("const unsigned char*", data)
	strm.avail_in = #data
	local chunks = {}
	local bufSize = 16 * 1024 * 1024
	local buf = ffi.new("unsigned char[?]", bufSize)
	while true do
		strm.next_out = buf
		strm.avail_out = bufSize
		local ret = z.inflate(strm, 0)
		chunks[#chunks + 1] = ffi.string(buf, bufSize - strm.avail_out)
		if ret == 1 then break end
		assert(ret == 0, "inflate error " .. ret)
	end
	z.inflateEnd(strm)
	return table.concat(chunks)
end
