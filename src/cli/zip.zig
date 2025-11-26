const std = @import("std");

// miniz C bindings
const c = @cImport({
    @cInclude("miniz.h");
});

/// Compression method for ZIP entries
pub const CompressionMethod = enum(u16) {
    store = 0,
    deflate = 8,
};

/// Compress data using deflate algorithm
pub fn deflateCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len == 0) {
        return allocator.alloc(u8, 0);
    }

    // Allocate buffer for compressed data (worst case: slightly larger than input)
    const max_compressed_size = c.mz_compressBound(@intCast(data.len));
    const compressed = try allocator.alloc(u8, max_compressed_size);
    errdefer allocator.free(compressed);

    var compressed_size: c_ulong = max_compressed_size;

    // Use raw deflate (no zlib header) for ZIP compatibility
    var stream: c.mz_stream = std.mem.zeroes(c.mz_stream);
    stream.next_in = data.ptr;
    stream.avail_in = @intCast(data.len);
    stream.next_out = compressed.ptr;
    stream.avail_out = @intCast(compressed.len);

    // Initialize deflate with raw deflate (negative window bits = no header)
    if (c.mz_deflateInit2(&stream, c.MZ_DEFAULT_COMPRESSION, c.MZ_DEFLATED, -c.MZ_DEFAULT_WINDOW_BITS, 9, c.MZ_DEFAULT_STRATEGY) != c.MZ_OK) {
        return error.DeflateInitFailed;
    }
    defer _ = c.mz_deflateEnd(&stream);

    // Compress
    if (c.mz_deflate(&stream, c.MZ_FINISH) != c.MZ_STREAM_END) {
        return error.DeflateFailed;
    }

    compressed_size = stream.total_out;

    // Resize to actual compressed size
    return allocator.realloc(compressed, compressed_size);
}

/// Decompress deflate data
pub fn deflateDecompress(allocator: std.mem.Allocator, compressed: []const u8, uncompressed_size: usize) ![]u8 {
    if (compressed.len == 0 or uncompressed_size == 0) {
        return allocator.alloc(u8, 0);
    }

    const decompressed = try allocator.alloc(u8, uncompressed_size);
    errdefer allocator.free(decompressed);

    var stream: c.mz_stream = std.mem.zeroes(c.mz_stream);
    stream.next_in = compressed.ptr;
    stream.avail_in = @intCast(compressed.len);
    stream.next_out = decompressed.ptr;
    stream.avail_out = @intCast(decompressed.len);

    // Initialize inflate with raw deflate (negative window bits = no header)
    if (c.mz_inflateInit2(&stream, -c.MZ_DEFAULT_WINDOW_BITS) != c.MZ_OK) {
        return error.InflateInitFailed;
    }
    defer _ = c.mz_inflateEnd(&stream);

    // Decompress
    const result = c.mz_inflate(&stream, c.MZ_FINISH);
    if (result != c.MZ_STREAM_END) {
        return error.InflateFailed;
    }

    return decompressed;
}

/// ZIP file writer with optional compression support
pub const ZipWriter = struct {
    file: std.fs.File,
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(CentralDirEntry),
    bytes_written: u32,
    dos_time: u16,
    dos_date: u16,
    compression: CompressionMethod,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Self {
        return initWithCompression(allocator, path, .deflate);
    }

    pub fn initWithCompression(allocator: std.mem.Allocator, path: []const u8, compression: CompressionMethod) !Self {
        const file = try std.fs.cwd().createFile(path, .{});

        // Get current time and convert to DOS format
        const now = std.time.timestamp();
        const dos = timestampToDos(now);

        return Self{
            .file = file,
            .allocator = allocator,
            .entries = .{},
            .bytes_written = 0,
            .dos_time = dos.time,
            .dos_date = dos.date,
            .compression = compression,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.filename);
        }
        self.entries.deinit(self.allocator);
        self.file.close();
    }

    /// Add a file to the ZIP archive with configured compression
    pub fn addFile(self: *Self, filename: []const u8, data: []const u8) !void {
        const local_header_offset = self.bytes_written;

        // Calculate CRC32 of uncompressed data
        const crc = std.hash.Crc32.hash(data);

        // Compress if needed
        var compressed_data: []const u8 = data;
        var compressed_owned: ?[]u8 = null;
        var method = self.compression;

        if (self.compression == .deflate and data.len > 0) {
            const compressed = deflateCompress(self.allocator, data) catch {
                // Fall back to store on compression error
                method = .store;
                compressed_data = data;
                compressed_owned = null;
                return self.writeEntry(filename, data, data, crc, .store, local_header_offset);
            };

            // Only use compression if it actually saves space
            if (compressed.len < data.len) {
                compressed_data = compressed;
                compressed_owned = compressed;
            } else {
                self.allocator.free(compressed);
                method = .store;
            }
        }
        defer if (compressed_owned) |owned| self.allocator.free(owned);

        try self.writeEntry(filename, compressed_data, data, crc, method, local_header_offset);
    }

    fn writeEntry(self: *Self, filename: []const u8, compressed_data: []const u8, original_data: []const u8, crc: u32, method: CompressionMethod, local_header_offset: u32) !void {
        const compressed_size: u32 = @intCast(compressed_data.len);
        const uncompressed_size: u32 = @intCast(original_data.len);

        // Write local file header
        var header: [30]u8 = undefined;

        // Local file header signature (0x04034b50)
        std.mem.writeInt(u32, header[0..4], 0x04034b50, .little);
        // Version needed to extract (2.0 = 20 for deflate)
        std.mem.writeInt(u16, header[4..6], if (method == .deflate) 20 else 10, .little);
        // General purpose bit flag
        std.mem.writeInt(u16, header[6..8], 0, .little);
        // Compression method
        std.mem.writeInt(u16, header[8..10], @intFromEnum(method), .little);
        // Last mod file time (DOS format)
        std.mem.writeInt(u16, header[10..12], self.dos_time, .little);
        // Last mod file date (DOS format)
        std.mem.writeInt(u16, header[12..14], self.dos_date, .little);
        // CRC-32
        std.mem.writeInt(u32, header[14..18], crc, .little);
        // Compressed size
        std.mem.writeInt(u32, header[18..22], compressed_size, .little);
        // Uncompressed size
        std.mem.writeInt(u32, header[22..26], uncompressed_size, .little);
        // File name length
        std.mem.writeInt(u16, header[26..28], @intCast(filename.len), .little);
        // Extra field length
        std.mem.writeInt(u16, header[28..30], 0, .little);

        try self.file.writeAll(&header);
        try self.file.writeAll(filename);
        self.bytes_written += 30 + @as(u32, @intCast(filename.len));

        // Write file data
        try self.file.writeAll(compressed_data);
        self.bytes_written += compressed_size;

        // Store entry for central directory
        try self.entries.append(self.allocator, .{
            .filename = try self.allocator.dupe(u8, filename),
            .compressed_size = compressed_size,
            .uncompressed_size = uncompressed_size,
            .crc32 = crc,
            .method = method,
            .local_header_offset = local_header_offset,
        });
    }

    /// Add a file from disk to the ZIP archive
    pub fn addFileFromDisk(self: *Self, filename: []const u8, disk_path: []const u8) !void {
        const data = try std.fs.cwd().readFileAlloc(self.allocator, disk_path, 100 * 1024 * 1024);
        defer self.allocator.free(data);
        try self.addFile(filename, data);
    }

    /// Finalize the ZIP file by writing central directory and end record
    pub fn finish(self: *Self) !void {
        const central_dir_offset = self.bytes_written;
        var central_dir_size: u32 = 0;

        // Write central directory entries
        for (self.entries.items) |entry| {
            var cd_header: [46]u8 = undefined;

            // Central directory file header signature (0x02014b50)
            std.mem.writeInt(u32, cd_header[0..4], 0x02014b50, .little);
            // Version made by (Unix = 3, version 2.0 = 20) -> 0x0314
            std.mem.writeInt(u16, cd_header[4..6], 0x0314, .little);
            // Version needed to extract
            std.mem.writeInt(u16, cd_header[6..8], if (entry.method == .deflate) 20 else 10, .little);
            // General purpose bit flag
            std.mem.writeInt(u16, cd_header[8..10], 0, .little);
            // Compression method
            std.mem.writeInt(u16, cd_header[10..12], @intFromEnum(entry.method), .little);
            // Last mod file time
            std.mem.writeInt(u16, cd_header[12..14], self.dos_time, .little);
            // Last mod file date
            std.mem.writeInt(u16, cd_header[14..16], self.dos_date, .little);
            // CRC-32
            std.mem.writeInt(u32, cd_header[16..20], entry.crc32, .little);
            // Compressed size
            std.mem.writeInt(u32, cd_header[20..24], entry.compressed_size, .little);
            // Uncompressed size
            std.mem.writeInt(u32, cd_header[24..28], entry.uncompressed_size, .little);
            // File name length
            std.mem.writeInt(u16, cd_header[28..30], @intCast(entry.filename.len), .little);
            // Extra field length
            std.mem.writeInt(u16, cd_header[30..32], 0, .little);
            // File comment length
            std.mem.writeInt(u16, cd_header[32..34], 0, .little);
            // Disk number start
            std.mem.writeInt(u16, cd_header[34..36], 0, .little);
            // Internal file attributes
            std.mem.writeInt(u16, cd_header[36..38], 0, .little);
            // External file attributes (Unix permissions: 0644 << 16)
            std.mem.writeInt(u32, cd_header[38..42], 0x81a40000, .little);
            // Relative offset of local header
            std.mem.writeInt(u32, cd_header[42..46], entry.local_header_offset, .little);

            try self.file.writeAll(&cd_header);
            try self.file.writeAll(entry.filename);

            central_dir_size += 46 + @as(u32, @intCast(entry.filename.len));
        }

        // Write end of central directory record
        var eocd: [22]u8 = undefined;

        // End of central directory signature (0x06054b50)
        std.mem.writeInt(u32, eocd[0..4], 0x06054b50, .little);
        // Number of this disk
        std.mem.writeInt(u16, eocd[4..6], 0, .little);
        // Disk where central directory starts
        std.mem.writeInt(u16, eocd[6..8], 0, .little);
        // Number of central directory records on this disk
        std.mem.writeInt(u16, eocd[8..10], @intCast(self.entries.items.len), .little);
        // Total number of central directory records
        std.mem.writeInt(u16, eocd[10..12], @intCast(self.entries.items.len), .little);
        // Size of central directory
        std.mem.writeInt(u32, eocd[12..16], central_dir_size, .little);
        // Offset of start of central directory
        std.mem.writeInt(u32, eocd[16..20], central_dir_offset, .little);
        // Comment length
        std.mem.writeInt(u16, eocd[20..22], 0, .little);

        try self.file.writeAll(&eocd);
    }
};

const CentralDirEntry = struct {
    filename: []const u8,
    compressed_size: u32,
    uncompressed_size: u32,
    crc32: u32,
    method: CompressionMethod,
    local_header_offset: u32,
};

/// Convert Unix timestamp to DOS date/time format
fn timestampToDos(timestamp: i64) struct { time: u16, date: u16 } {
    // Convert to epoch seconds then to broken-down time
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, timestamp)) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    const year = year_day.year;
    const month = month_day.month.numeric();
    const day = month_day.day_index + 1;

    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();
    const second = day_seconds.getSecondsIntoMinute();

    // DOS date: bits 0-4 = day, bits 5-8 = month, bits 9-15 = year - 1980
    // DOS time: bits 0-4 = second/2, bits 5-10 = minute, bits 11-15 = hour
    const dos_year: u16 = if (year >= 1980) @intCast(year - 1980) else 0;

    const dos_date: u16 = (@as(u16, dos_year) << 9) | (@as(u16, month) << 5) | @as(u16, day);
    const dos_time: u16 = (@as(u16, hour) << 11) | (@as(u16, minute) << 5) | (@as(u16, second) >> 1);

    return .{ .time = dos_time, .date = dos_date };
}
