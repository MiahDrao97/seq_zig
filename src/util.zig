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

const std = @import("std");
const Io = std.Io;
const EpochSeconds = std.time.epoch.EpochSeconds;
const EpochDay = std.time.epoch.EpochDay;
const YearAndDay = std.time.epoch.YearAndDay;
const MonthAndDay = std.time.epoch.MonthAndDay;
