//! Root module of seq_zig.
//! This utility is ONLY available in multi-threaded builds and cannot exist in a single-threaded context.
//!
//! Set up Seq logging in your root file with the following globals:
//!
//! ```zig
//! // assuming imports...
//! // assuming Allocator interface...
//!
//! // assign the `seqLogFn` to the `logFn`
//! pub const std_options: std.Options = .{ .logFn = seqLogFn };
//! // must be mutable and public with this name
//! pub var seq_background_worker: SeqBackgroundWorker = .init;
//!
//! pub fn main() !void {
//!     try seq_background_worker.start(gpa, .{
//!         // fill these in for your Seq server url and API key...
//!         .url = undefined,
//!         .api_key = "",
//!     });
//!     defer seq_background_worker.shutdown();
//!
//!     // application code...
//! }
//! ```

/// Configuration on the Seq server
pub const SeqConfig = struct {
    /// Seq server URL we're posting logs to
    url: Uri,
    /// API key
    api_key: []const u8,
    /// How often (in milliseconds) we flush collected logs to the Seq server.
    /// Defaults to 10K (10 seconds).
    flush_interval_ms: u32 = 10_000,
    /// Limit space on stored logs before we flush.
    /// Defaults to ~8KB.
    log_capacity: u32 = 8096,
};

/// Worker that holds the background thread, asynchronously batching and sending logs to the Seq server
pub const SeqBackgroundWorker = struct {
    /// Background thread
    thread: Thread,
    /// Seq client
    client: SeqClient,
    /// Kill signal
    sig_kill: Atomic(bool),

    /// Expected field name of the mutable global variable that handles the background process of sending logs to Seq.
    pub const root_decl_name = "seq_background_worker";

    /// This initialized value is inert, leaving the background thread and client undefined
    pub const init: SeqBackgroundWorker = .{
        .thread = undefined,
        .client = undefined,
        .sig_kill = .init(false),
    };

    /// Start the seq client.
    /// `gpa` must be threadsafe.
    pub fn start(self: *SeqBackgroundWorker, gpa: Allocator, config: SeqConfig) Thread.SpawnError!void {
        self.thread = try .spawn(.{}, worker, .{ self, gpa, config });
    }

    /// For a clean shutdown, this sends a kill signal to the background thread.
    /// Flushes all logs on shutdown.
    pub fn shutdown(self: *SeqBackgroundWorker) void {
        self.sig_kill.store(true, .acq_rel);
        self.thread.join();
        // client is created and cleaned up in the background thread; don't want to attempt to deinit() something that could be undefined
        self.* = undefined;
    }

    fn worker(self: *SeqBackgroundWorker, gpa: Allocator, config: SeqConfig) void {
        self.client = SeqClient.init(gpa, config) catch |err| {
            // assuming that we hijacked the log function, so we're going straight to std err
            debug.print("FATAL: SeqBackgroundWorker cannot start: {t} -> {?f}\n", .{ err, @errorReturnTrace() });
            return;
        };
        defer self.client.deinit(gpa);

        while (!self.sig_kill.load(.monotonic)) self.client.evaluate() catch |err| switch (err) {
            Allocator.Error.OutOfMemory => {
                debug.print("FATAL: SeqBackgroundWorker ran out of memory. Returning from background thread...", .{@errorReturnTrace()});
                return;
            },
            // just swallow all other errors
            else => debug.print("ERROR: SeqBackgroundWorker encountered the following error: {t} -> {?f}", .{ err, @errorReturnTrace() }),
        };

        // received sig kill
        debug.print("Flushing Seq client...", .{});
        self.client.flush() catch |err| debug.print("ERROR: Failed to flush Seq client on shutdown: {t} -> {?f}", .{ err, @errorReturnTrace() });
        debug.print("Seq client successfully flushed all logs.", .{});
    }
};

/// Assign this log function to `std_options.logFn` in your root file.
/// Assumes a public mutable global variable called "seq_background_worker" of type `SeqBackgroundWorker`.
/// If that doesn't exist, then only the default log written to STDERR occurs.
pub fn seqLogFn(
    comptime level: LogLevel,
    comptime scope: @Type(.enum_literal),
    comptime log: []const u8,
    args: anytype,
) void {
    // still write to std err no matter what
    defaultStdErr(level, scope, log, args);

    var root = @import("root");
    if (comptime @hasDecl(@TypeOf(root), SeqBackgroundWorker.root_decl_name) and
        @TypeOf(@field(root, SeqBackgroundWorker.root_decl_name)) == SeqBackgroundWorker)
    {
        const background_worker: *SeqBackgroundWorker = &@field(root, SeqBackgroundWorker.root_decl_name);
        background_worker.client.writeLog(level, scope, log, args) catch {
            debug.print("FATAL: SeqBackgroundWorker ran out of memory. Killing background thread...", .{@errorReturnTrace()});
            // kill the background worker
            background_worker.sig_kill.store(true, .acq_rel);
        };
    }
}

const SeqClient = struct {
    bytes: Io.Writer.Allocating,
    indices: ArrayList(LogIndex),
    connection: HttpClient,
    config: SeqConfig,
    sw: Stopwatch,
    mutex: Mutex,

    fn init(gpa: Allocator, config: SeqConfig) (Allocator.Error || Stopwatch.Error)!SeqClient {
        return .{
            .bytes = try .initCapacity(gpa, config.log_capacity * 2),
            .indices = try .initCapacity(gpa, @divTrunc(config.log_capacity, 2)),
            .connection = .{ .allocator = gpa },
            .config = config,
            .sw = try .start(),
            .mutex = .{},
        };
    }

    fn writeLog(
        self: *SeqClient,
        comptime level: LogLevel,
        comptime scope: @Type(.enum_literal),
        comptime log: []const u8,
        args: anytype,
    ) Allocator.Error!void {
        const ArgsType = @TypeOf(args);
        const is_tuple: bool = @typeInfo(ArgsType).@"struct".is_tuple;

        // critical section
        self.mutex.lock();
        defer self.mutex.unlock();

        const offset: LogIndex = @enumFromInt(self.bytes.written().len);
        try self.indices.append(self.bytes.allocator, offset);

        var date_time_buf: [24]u8 = undefined;

        var seq_payload: SeqBody(ArgsType) = undefined;
        seq_payload.scope = scope;
        seq_payload.@"@t" = util.utcNowAsIsoString(&date_time_buf); // timestamp
        seq_payload.@"@l" = switch (level) { // log level
            .debug => .Debug,
            .info => .Information,
            .warn => .Warning,
            .err => .Error,
        };

        var arena: ArenaAllocator = .init(self.bytes.allocator);
        defer arena.deinit();
        if (!is_tuple) {
            // copy fields from args struct, which then become parameterized values given to Seq

            comptime var i: usize = 0;
            comptime var begin_arg_name: usize = undefined;
            comptime var begin_specifier: usize = undefined;
            comptime var arg_name_len: usize = 0;
            comptime var specifier_len: usize = 0;

            const state: enum { begin_field, arg_name, specificier, none } = .none;
            loop: switch (state) {
                .none => {
                    if (i >= log.len) break :loop;
                    if (log[i] == '{') continue :loop .begin_field;
                    i += 1;
                    continue :loop .none;
                },
                .begin_field => {
                    debug.assert(log[i] == '[');
                    i += 1;
                    begin_arg_name = i;
                    continue :loop .arg_name;
                },
                .arg_name => {
                    defer i += 1;
                    if (log[i] == ']') {
                        begin_specifier = i + 1;
                        continue :loop .specificier;
                    }
                    arg_name_len += 1;
                    continue :loop .arg_name;
                },
                .specifier => {
                    defer i += 1;
                    if (log[i] == '}') {
                        defer {
                            arg_name_len = 0;
                            specifier_len = 0;
                        }
                        const arg_name: []const u8 = log[begin_arg_name..][0..arg_name_len];
                        const specifier: []const u8 = log[begin_specifier..][0..specifier_len];

                        var stream: Io.Writer.Allocating = .init(arena.allocator());
                        stream.writer.print("{" ++ specifier ++ "}", .{@field(args, arg_name)}) catch return error.OutOfMemory;
                        @field(seq_payload, arg_name) = stream.written();

                        continue :loop .none;
                    }
                    specifier_len += 1;
                    continue :loop .specificier;
                },
            }
        }

        // very unlikely that we'll allocate any more than this, but it's technically possible, so I don't trust a stack buffer
        var message_stream: Io.Writer.Allocating = try .initCapacity(arena.allocator(), log.len);
        message_stream.writer.print(log, args) catch return error.OutOfMemory;
        seq_payload.@"@m" = message_stream.written();

        var serializer: json.Stringify = .{
            .writer = &self.bytes.writer,
            .options = .{},
        };
        // write the payload body into the bytes
        serializer.write(seq_payload) catch return error.OutOfMemory;

        // append a null byte at the end
        try self.bytes.writer.writeByte(0);
    }

    fn evaluate(self: *SeqClient) HttpClient.RequestError!void {
        // returns nanoseconds elapsed
        const ms: u64 = @trunc(
            @as(f64, @floatFromInt(self.sw.read())) / 1_000_000.0,
        );
        if (ms >= self.config.flush_interval_ms or
            self.bytes.written().len >= self.config.log_capacity)
        {
            try self.flush();
        }
    }

    fn flush(self: *SeqClient) HttpClient.RequestError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.indices.items) |idx| {
            // these should be the JSON bodies prepared to be sent
            const entry: []u8 = std.mem.sliceTo(self.bytes.written()[@intFromEnum(idx)..], 0);
            var request: HttpRequest = try self.connection.request(.POST, self.config.url, .{
                .headers = .{ .authorization = self.config.api_key },
            });
            defer request.deinit();

            _ = try request.sendBody(entry);
            // TODO : report error responses from server
        }
        self.reset();
    }

    fn reset(self: *SeqClient) void {
        self.bytes.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
    }

    fn deinit(self: *SeqClient, gpa: Allocator) void {
        self.connection.deinit();
        self.bytes.deinit();
        self.indices.deinit(gpa);
        self.* = undefined;
    }
};

const LogIndex = enum(u32) { _ };

fn SeqBody(comptime TBody: type) type {
    const derived_fields: []StructField = if (@typeInfo(TBody).@"struct".is_tuple)
        &.{} // don't add in fields from a tuple since they're all "0", "1", etc., and that's really meh for structured logging
    else struct_fields: {
        var fields: [@typeInfo(TBody).@"struct".fields.len]StructField = undefined;
        for (&fields, @typeInfo(TBody).@"struct".fields) |*derived, field| derived.* = .{
            .name = field.name,
            .type = []const u8, // all of these are gonna be strings
            .default_value_ptr = "", // default to empty string
            .alignment = 0,
            .is_comptime = false,
        };
        break :struct_fields &fields;
    };

    return @as(type, @Type(.{
        .@"struct" = .{
            .fields = &derived_fields ++ &.{
                .{
                    .name = "@t",
                    .type = []const u8,
                    .default_value_ptr = null,
                    .alignment = 0,
                    .is_comptime = false,
                },
                .{
                    .name = "@l",
                    .type = enum { Verbose, Debug, Information, Warning, Error, Fatal },
                    .default_value_ptr = null,
                    .alignment = 0,
                    .is_comptime = false,
                },
                .{
                    .name = "@m",
                    .type = []const u8,
                    .default_value_ptr = "",
                    .alignment = 0,
                    .is_comptime = false,
                },
                .{
                    .name = "scope",
                    .type = []const u8,
                    .default_value_ptr = "",
                    .alignment = 0,
                    .is_comptime = false,
                },
            },
            .decls = &.{},
            .is_tuple = false,
            .layout = .auto,
        },
    }));
}

test {
    // TODO : Test the serialization and parameterized values
    _ = SeqClient;
}

const std = @import("std");
const util = @import("util.zig");
const Io = std.Io;
const debug = std.debug;
const json = std.json;
const Thread = std.Thread;
const Mutex = Thread.Mutex;
const Atomic = std.atomic.Value;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const Uri = std.Uri;
const HttpClient = std.http.Client;
const HttpRequest = HttpClient.Request;
const Stopwatch = std.time.Timer;
const StructField = std.builtin.Type.StructField;
const LogLevel = std.log.Level;
const defaultStdErr = std.log.defaultLog;
