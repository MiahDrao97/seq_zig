//! Almost a mirror of `std.log` except with 2 more log levels (reflecting Seq's log levels)
//! and requiring a source location as the first parameter.
//!
//! Still calls the log function in `std.log` with the given scope and translated log level.

/// Declare a scoped log
pub fn scoped(scope: @EnumLiteral()) type {
    return struct {
        pub fn verbose(comptime src: SourceLocation, comptime format: []const u8, args: anytype) void {
            seq_zig.seqLogFn(src, .Verbose, scope, format, args, null);
        }

        pub fn debug(comptime src: SourceLocation, comptime format: []const u8, args: anytype) void {
            seq_zig.seqLogFn(src, .Debug, scope, format, args, null);
        }

        pub fn info(comptime src: SourceLocation, comptime format: []const u8, args: anytype) void {
            seq_zig.seqLogFn(src, .Information, scope, format, args, null);
        }

        pub fn warn(comptime src: SourceLocation, comptime format: []const u8, args: anytype) void {
            seq_zig.seqLogFn(src, .Warning, scope, format, args, null);
        }

        pub fn err(
            comptime src: SourceLocation,
            comptime format: []const u8,
            args: anytype,
            err_trace: ?*const std.builtin.StackTrace,
        ) void {
            seq_zig.seqLogFn(src, .Error, scope, format, args, err_trace);
        }

        pub fn fatal(
            comptime src: SourceLocation,
            comptime format: []const u8,
            args: anytype,
            err_trace: ?*const std.builtin.StackTrace,
        ) void {
            seq_zig.seqLogFn(src, .Fatal, scope, format, args, err_trace);
        }
    };
}

/// Default log scope
pub const default = scoped(.default);

/// Call verbose logging with the default scope
pub const verbose = default.verbose;

/// Call debug logging with the default scope
pub const debug = default.debug;

/// Call info logging with the default scope
pub const info = default.info;

/// Call warn logging with the default scope
pub const warn = default.warn;

/// Call error logging with the default scope
pub const err = default.err;

/// Call fatal logging with the default scope
pub const fatal = default.fatal;

const std = @import("std");
const seq_zig = @import("root.zig");
const SourceLocation = std.builtin.SourceLocation;
const SeqLogLevel = seq_zig.SeqLogLevel;
