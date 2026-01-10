/// Override standard options
pub const std_options: std.Options = .{ .logFn = seqLogFn };
/// Seq background worker
pub var seq_background_worker: SeqBackgroundWorker = .init;

var debug_allocator: DebugAllocator(.{}) = .init;
const gpa: Allocator = switch (builtin.mode) {
    .Debug => debug_allocator.allocator(),
    .ReleaseSafe, .ReleaseFast => std.heap.smp_allocator,
    .ReleaseSmall => std.heap.page_allocator,
};

pub fn main() !void {
    defer if (builtin.mode == .Debug)
        std.debug.assert(debug_allocator.deinit() == .ok);

    var threaded: Io.Threaded = .init(gpa, .{ .environ = .empty });
    defer threaded.deinit();

    // Prints to stderr, ignoring potential errors.
    std.debug.print("Beginning integration test\n", .{});

    try seq_background_worker.start(threaded.io(), gpa, .{
        .url = try std.Uri.parse("http://localhost:5341/api/ingest/clef"),
        .api_key = "",
    });
    defer seq_background_worker.shutdown();

    log.debug("This is a debug log", .{});
    log.info("This is an info log", .{});
    log.warn("WARNING", .{});
    log.err("ERROR", .{});
}

const std = @import("std");
const seq_zig = @import("seq_zig");
const builtin = @import("builtin");
const log = std.log.scoped(.integration_test);
const Io = std.Io;
const SeqBackgroundWorker = seq_zig.SeqBackgroundWorker;
const SeqConfig = seq_zig.SeqConfig;
const seqLogFn = seq_zig.seqLogFn;
const Allocator = std.mem.Allocator;
const DebugAllocator = std.heap.DebugAllocator;
