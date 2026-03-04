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
/// 1 reader; multiple writers
pub const RingBuf = struct {
    /// The bytes themselves
    bytes: []u8,
    /// The reader's location
    r_loc: Atomic(u32),
    /// The writer's location
    w_loc: Atomic(u32),
    /// Moves to the left when a chunk of data is too large for the rest of the buffer
    /// Indicates that we're wrapping around
    watermark: Atomic(u32),
    // TODO : Member to deliniate the separations of aggregated logs.
    // We write in chunks and we want the reader to pick up those same chunks.
    // This memory won't move during the lifetime of this buffer, so we can safely store pointers to specific bytes.

    //      |______________________________|
    //      ^                              ^
    // r_loc, w_loc                    watermark

    pub fn init(gpa: Allocator, size: u32) Allocator.Error!RingBuf {
        return .{
            .bytes = try gpa.alloc(u8, size),
            .r_loc = .init(0),
            .w_loc = .init(0),
            .watermark = .init(size),
        };
    }

    pub fn deinit(self: *RingBuf, gpa: Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }

    //      |========|_____________________|
    //      ^        ^                     ^
    //    r_loc    w_loc               watermark

    pub fn reader(self: *RingBuf) error{Empty}!Reader {
        const head: u32 = self.w_loc.load(.monotonic);
        var tail: u32 = self.r_loc.raw;

        // assuming this is empty
        if (head == tail) {
            // check again
            tail = self.w_loc.load(.acquire);
            if (head == tail) return error.Empty;
        }

        const len: u32 = tail -% head;
        _ = len;
        return .init(self);
    }

    // |____|====================|_________|
    //      ^                    ^         ^
    //    r_loc                w_loc   watermark

    pub fn writer(self: *RingBuf) error{NoSpace}!Writer {
        const tail: u32 = self.r_loc.load(.monotonic);
        var head: u32 = self.w_loc.raw;

        // assuming this is empty
        if (head == tail) {
            head = self.w_loc.load(.acquire);
            if (head == tail) return error.NoSpace;
        }

        return .init(self);
    }

    /// The reader interface never returns `error.ReadFailed`
    pub const Reader = struct {
        ring: *RingBuf,
        // TODO:

        fn init(ring: *RingBuf) Reader {
            return .{ .ring = ring };
        }
    };

    /// `error.WriteFailed` indicates the buffer is full (i.e. would overtake the reader position)
    pub const Writer = struct {
        ring: *RingBuf,
        // TODO:

        fn init(ring: *RingBuf) Writer {
            return .{ .ring = ring };
        }
    };
};

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Value;
const SinglyLinkedList = std.SinglyLinkedList;
const EpochSeconds = std.time.epoch.EpochSeconds;
const EpochDay = std.time.epoch.EpochDay;
const YearAndDay = std.time.epoch.YearAndDay;
const MonthAndDay = std.time.epoch.MonthAndDay;
