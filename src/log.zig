//! Almost a mirror of `std.log` except with 2 more log levels (reflecting Seq's log levels)
//! and requiring a source location as the first parameter and an optional stack trace as the second parameter.
//!
//! Still calls `std.options.logFn` with the given scope and log level translated from Seq's log levels:
//!     .Verbose, .Debug => .debug
//!     .Information => .info,
//!     .Warning => .warn,
//!     .Error, .Fatal => .err

/// Declare a scoped log
pub fn scoped(scope: @EnumLiteral()) type {
    return struct {
        /// Write a verbose-level log:
        /// This is intended for high-granularity logging that produces a large volume of log output.
        /// Enabling verbose logging tends to make applications less performant.
        pub fn verbose(
            comptime src: SourceLocation,
            trace: Trace,
            comptime format: []const u8,
            args: anytype,
        ) void {
            seq_zig.seqLog(src, trace, .Verbose, scope, format, args);
        }

        /// Write a debug-level log:
        /// Debug level is intended to document certain values/logic paths that may be helpful while investigating potential issues.
        /// Most applications have Debug level disabled by default, but enabling Debug logs for a short period of time shouldn't produce an immense volume of logs.
        pub fn debug(
            comptime src: SourceLocation,
            trace: Trace,
            comptime format: []const u8,
            args: anytype,
        ) void {
            seq_zig.seqLog(src, trace, .Debug, scope, format, args);
        }

        /// Write an info-level log:
        /// The default minimum log level
        pub fn info(
            comptime src: SourceLocation,
            trace: Trace,
            comptime format: []const u8,
            args: anytype,
        ) void {
            seq_zig.seqLog(src, trace, .Information, scope, format, args);
        }

        /// Write a warning-level log:
        /// Indicates that some data or value appears unusual, possibly indicative of a bug.
        pub fn warn(
            comptime src: SourceLocation,
            trace: Trace,
            comptime format: []const u8,
            args: anytype,
        ) void {
            seq_zig.seqLog(src, trace, .Warning, scope, format, args);
        }

        /// Write an error-level log:
        /// Indicates that an error occurred, but not one that would cause the application to exit.
        pub fn err(
            comptime src: SourceLocation,
            trace: Trace,
            comptime format: []const u8,
            args: anytype,
        ) void {
            seq_zig.seqLog(src, trace, .Error, scope, format, args);
        }

        /// Write a fatal-level log:
        /// Indicates that a fatal error occurred, and the application is forced to exit.
        pub fn fatal(
            comptime src: SourceLocation,
            trace: Trace,
            comptime format: []const u8,
            args: anytype,
        ) void {
            seq_zig.seqLog(src, trace, .Fatal, scope, format, args);
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

/// Pass in a trace if you want to include that in your structured log.
/// As of Zig 0.16.0, error return traces and stack traces are different structs, so we need to be able to capture either one.
pub const Trace = union(enum) {
    /// Normal stack trace that can be captured using `std.debug.captureCurrentStackTrace(...)`
    stack_trace: *const std.debug.StackTrace,
    /// Error trace that can be captured using `@errorReturnTrace()`
    error_trace: ?*const std.builtin.StackTrace,
    /// Don't capture a stack trace
    no_trace
};

const std = @import("std");
const seq_zig = @import("root.zig");
const SourceLocation = std.builtin.SourceLocation;
const SeqLogLevel = seq_zig.SeqLogLevel;
