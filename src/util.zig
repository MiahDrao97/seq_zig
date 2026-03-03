//! Utility functions

/// UTC now, formatted as YYYY-MM-DDThh:mm:ss.fffZ
pub fn utcNowAsIsoString(io: Io, buf: *[24]u8) []const u8 {
    const timestamp: Io.Timestamp = .now(io, .real);
    const ms_now: i64 = timestamp.toMilliseconds();
    const sec_now: i64 = std.math.divFloor(i64, ms_now, 1000) catch unreachable;
    const minutes_now: i64 = std.math.divFloor(i64, sec_now, 60) catch unreachable;
    const hours_now: i64 = std.math.divFloor(i64, minutes_now, 60) catch unreachable;

    const ms: i64 = @mod(ms_now, 1000);
    const sec: i64 = @mod(sec_now, 60);
    const min: i64 = @mod(minutes_now, 60);
    const hour: i64 = @mod(hours_now, 24);

    const epoch_seconds: EpochSeconds = .{ .secs = @bitCast(sec_now) };
    const epoch_day: EpochDay = epoch_seconds.getEpochDay();
    const year_day: YearAndDay = epoch_day.calculateYearDay();
    const month_day: MonthAndDay = year_day.calculateMonthDay();

    return std.fmt.bufPrint(buf, "{:0>4}-{:0>2}-{:0>2}T{:0>2}:{:0>2}:{:0>2}.{:0>3}Z", .{
        @abs(year_day.year),
        @abs(month_day.month.numeric()),
        @abs(month_day.day_index + 1),
        @abs(hour),
        @abs(min),
        @abs(sec),
        @abs(ms),
    }) catch {
        var panic_buf: [64]u8 = undefined;
        @panic(std.fmt.bufPrint(&panic_buf, "Buffer size {d} was too small for ISO datetime format.", .{buf.len}) catch &panic_buf);
    };
}

/// FIXME :
/// Not in use
/// Test before putting in place with the SeqClient
pub const RingBuf = struct {
    /// The bytes themselves
    bytes: []u8,
    /// The reader's location
    r_loc: Loc,
    /// The writer's location
    w_loc: Loc,
    /// Moves to the left when a chunk of data is too large for the rest of the buffer
    /// Indicates that we're wrapping around
    watermark: Atomic(u32),

    //      |______________________________|
    //      ^                              ^
    // r_loc, w_loc                    watermark

    pub fn init(gpa: Allocator, size: u32) Allocator.Error!RingBuf {
        return .{
            .bytes = try gpa.alloc(u8, size),
            .r_loc = .{},
            .w_loc = .{},
            .watermark = .init(size),
        };
    }

    pub fn deinit(self: *RingBuf, gpa: Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }

    //      |========|_____________________|
    //      ^        ^                     ^
    //    r_loc    w_loc                watermark

    pub fn reader(self: *RingBuf) error{Empty}!Reader {
        const head: u32 = self.r_loc.start.raw;
        var tail: u32 = self.r_loc.safe_end;

        // assuming this is empty
        if (head == tail) {
            tail = self.w_loc.start.load(.acquire);
            if (head == tail) return error.Empty;
            self.r_loc.safe_end = tail;
        }

        const len: u32 = tail -% head;
        return .init(self, head, len);
    }

    // |____|====================|_________|
    //      ^                    ^         ^
    //    r_loc                w_loc   watermark

    pub fn writer(self: *RingBuf) error{NoSpace}!Writer {
        const tail: u32 = self.w_loc.start.raw;
        var head: u32 = self.w_loc.safe_end;

        // assuming this is empty
        if (head == tail) {
            head = self.r_loc.start.load(.acquire);
            if (head == tail) return error.NoSpace;
            self.w_loc.safe_end = head;
        }

        return .init(self, tail, head);
    }

    /// The reader interface never returns `error.ReadFailed`
    pub const Reader = struct {
        ring: *RingBuf,
        offset: u32,
        len: u32,
        read_complete: bool,
        interface: Io.Reader,

        const vtable: Io.Reader.VTable = .{
            .stream = stream,
        };

        fn init(ring: *RingBuf, offset: u32, len: u32) Reader {
            return .{
                .ring = ring,
                .offset = offset,
                .len = len,
                .read_complete = false,
                .interface = .{
                    .buffer = &.{},
                    .end = 0,
                    .seek = 0,
                    .vtable = &vtable,
                },
            };
        }

        fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
            const self: *Reader = @fieldParentPtr("interface", r);
            if (self.read_complete) return error.EndOfStream;
            const l: usize = @min(self.len, @intFromEnum(limit));
            if (self.offset + l > self.ring.bytes.len) {
                // we're wrapping around, so this requires up to 2 writes
                try w.write(self.ring.bytes[self.offset..]);
                const remaining: u32 = @intCast(l - (self.ring.bytes.len - self.offset));
                if (remaining > 0) {
                    try w.write(self.ring.bytes[0..remaining]);
                }
                self.ring.w_loc.start.store(remaining, .release);
            } else {
                try w.write(self.ring.bytes[self.offset..][0..l]);
                self.ring.w_loc.start.store(@intCast(self.offset + l), .release);
            }
            self.read_complete = true;
            return l;
        }
    };

    /// `error.WriteFailed` indicates the buffer is full (i.e. would overtake the reader position)
    pub const Writer = struct {
        ring: *RingBuf,
        pos: u32,
        safe_end: u32,
        interface: Io.Writer,

        const vtable: Io.Writer.VTable = .{
            .drain = drain,
        };

        fn init(ring: *RingBuf, offset: u32, safe_end: u32) Writer {
            return .{
                .ring = ring,
                .pos = offset,
                .safe_end = safe_end,
                .interface = .{
                    .buffer = &.{},
                    .vtable = &vtable,
                },
            };
        }

        fn drain(w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
            const self: *Writer = @fieldParentPtr("interface", w);
            _ = splat;

            var written: usize = 0;
            for (data) |datum| {
                if (self.safe_end -% self.pos <= datum.len) {
                    self.safe_end = self.ring.r_loc.start.load(.acquire);
                    if (self.safe_end -% self.pos <= datum.len) return error.WriteFailed;
                    self.ring.w_loc.safe_end = self.safe_end;
                }
                if (self.ring.bytes.len - self.pos < data.len) {

                    // move the watermark left:
                    // Once the reader hits the watermark, it'll get set back to the far right.
                    // |====|------------|================|XXXXX|
                    //      ^            ^                ^
                    //    w_loc        r_loc          watermark

                    const remaining: u32 = @intCast(data.len - (self.ring.bytes.len - self.pos));
                    @memcpy(self.ring.bytes[self.pos..], datum[0 .. datum.len - remaining]);
                    @memcpy(self.ring.bytes[0..remaining], datum[remaining..]);
                    self.pos = remaining;
                } else {
                    @memcpy(self.ring.bytes[self.pos..datum.len], datum);
                    self.pos += @as(u32, @intCast(datum.len));
                }
                self.ring.w_loc.start.store(self.pos, .release);
                written += datum.len;
            }

            return written;
        }
    };

    const Loc = struct {
        start: Atomic(u32) = .init(0),
        safe_end: u32 = 0,
    };
};

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;
const EpochSeconds = std.time.epoch.EpochSeconds;
const EpochDay = std.time.epoch.EpochDay;
const YearAndDay = std.time.epoch.YearAndDay;
const MonthAndDay = std.time.epoch.MonthAndDay;
