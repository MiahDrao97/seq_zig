//! Sample integration test.

/// Seq background worker
pub var seq_background_worker: SeqBackgroundWorker = .init;
/// Additional properties to add to every log (optional)
pub const additional_log_props = .{
    .Application = "Zig Test App",
};

pub fn main(init: std.process.Init) !void {
    // Prints to stderr, ignoring potential errors.
    std.debug.print("Beginning integration test\n", .{});

    try seq_background_worker.start(init.io, init.gpa, .{
        .base_url = "http://localhost:5341",
        .api_key = "",
    });
    defer seq_background_worker.shutdown();

    log.debug(@src(), "This is a debug log with {[value]d}", .{ .value = 4 });
    log.info(@src(), "This is an info log with {[string]s}", .{ .string = "asdf" });
    log.warn(@src(), "WARNING: This could be dangerous {[value]d}", .{ .value = -1 });
    log.err(@src(), "ERROR: It was dangerous {[string]s}", .{ .string = "dead" });
}

const std = @import("std");
const seq_zig = @import("seq_zig");
const builtin = @import("builtin");
const log = seq_zig.log.scoped(.integration_test);
const Io = std.Io;
const SeqBackgroundWorker = seq_zig.SeqBackgroundWorker;
const SeqConfig = seq_zig.SeqConfig;
const seqLogFn = seq_zig.seqLogFn;
const Allocator = std.mem.Allocator;
const DebugAllocator = std.heap.DebugAllocator;
