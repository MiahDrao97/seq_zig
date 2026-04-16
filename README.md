# Seq Zig

Sends logs from a Zig application to a [Seq](https://datalust.co/) server for structured logging collection.

## Installation
NOTE : Minimum version is Zig master `0.16.0-dev.2565+684032671`.

Fetch via `zig` CLI:
```
zig fetch https://github.com/MiahDrao97/seq_zig/archive/master.tar.gz --save
```

And then add the import in your `build.zig`:
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target: ResolvedTarget = b.standardTargetOptions(.{});
    const optimize: OptimizeMode = b.standardOptimizeOption(.{});

    const seq_zig: *Module = b.dependency("seq_zig", .{
        .target = target,
        .optimize = optimize,
    }).module("seq_zig");

    const mod: *Module = b.addModule("my_module", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "seq_zig", .module = seq_zig },
        },
    });

    // rest of your build def...
}
```

## Setup

See `main.zig` for a sample integration test.

Essentially, you'll have to add an instance of `SeqBackgroundWorker` as a global variable.
This log collector runs on a background thread.
It still writes logs to STDERR, but also collects the logs as JSON to send to a Seq server.
The flush interval and max buffer size are configurable.

The following code is an example setup for logging to Seq:
```zig
// main.zig

/// Seq background worker
pub var seq_background_worker: SeqBackgroundWorker = .init;
/// Additional properties to add to every log (optional)
pub const additional_log_props = .{
    .application = "Zig Test App",
};

pub fn main(init: std.process.Init) !void {
    // start the background worker
    try seq_background_worker.start(init.io, init.gpa, .{
        .base_url = "http://localhost:5341",
        .api_key = "",
    });
    defer seq_background_worker.shutdown();

    // rest of your app...
}

const std = @import("std");
const seq_zig = @import("seq_zig");
const SeqBackgroundWorker = seq_zig.SeqBackgroundWorker;
```

## Usage

The logging functions look similar to the ones provided in `std.log`, but there are 2 more parameters and 2 more log levels (verbose and fatal).
The first parameter is a comptime instance of `std.builtin.SourceLocation`, and the second is an optional stack trace:
```zig
const log = seq_zig.log.scoped(.my_logger);

// many non-error logs with start with `@src()` and a strack trace (or `.no_trace`) as the first 2 parameters
// each log level accepts a stack trace if you choose to provide one (`.stack_trace` for `*const std.debug.StackTrace` and `.error_trace` for `?*const std.builtin.StackTrace`)
// other than that, the logging API should feel pretty familiar.
log.info(@src(), .no_trace, "This is an info log with the following message: {[message]s}", .{ .message = "Horray!" });

myFunc() catch |err| {
    // passing in an error return trace
    log.err(@src(), .{ .error_trace = @errorReturnTrace() }, "We had a problem: {[error]t}", .{ .@"error" = err });
};
```
Now you may notice that the log format has named parameters, using a struct for the args rather than a tuple.
This allows us to capture the struct fields as values to query in Seq directly (which is the advantage of structured logging).
Using this library means you'll have to log a little differently, but it should be a relatively small lift.

I'd also point that each log will still call `std.options.logFn`, even if the background worker stops before the application exits (although, it would only stop in the event of OOM or some other unrecoverable error).
That way, you can still define a custom log function or default to the normal logging function, and still write structured logging to Seq on top of that.
