//! Sample integration test.

/// Seq background worker
pub var seq_background_worker: SeqBackgroundWorker = .init;
/// Additional properties to add to every log (optional)
pub const additional_log_props = .{
    .application = "Zig Test App",
    .version = 1.2,
};

pub fn main(init: std.process.Init) !void {
    // Prints to stderr, ignoring potential errors.
    std.debug.print("Beginning integration test\n", .{});

    try seq_background_worker.start(init.io, init.gpa, .{
        .base_url = "http://localhost:5341",
        .api_key = "",
    });
    defer seq_background_worker.shutdown();

    log.debug(@src(), .no_trace, "This is a debug log with {[value]d}", .{ .value = 4 });
    log.info(@src(), .no_trace, "This is an info log with {[string]s}", .{ .string = "asdf" });
    log.warn(@src(), .no_trace, "This could be dangerous {[value]d}", .{ .value = -1 });
    myFunc() catch |err| {
        log.err(@src(), .{ .error_trace = @errorReturnTrace() }, "It was dangerous {[string]s}: {[error]t}", .{ .string = "dead", .@"error" = err });
    };
}

fn myFunc() error{Doh}!void {
    return error.Doh;
}

const std = @import("std");
const seq_zig = @import("seq_zig");
const builtin = @import("builtin");
const log = seq_zig.log.scoped(.integration_test);
const Io = std.Io;
const SeqBackgroundWorker = seq_zig.SeqBackgroundWorker;
const SeqConfig = seq_zig.SeqConfig;
const Allocator = std.mem.Allocator;
const DebugAllocator = std.heap.DebugAllocator;
