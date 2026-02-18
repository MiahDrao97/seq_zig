//! Root module of seq_zig.
//! This utility is ONLY available in multi-threaded builds and cannot exist in a single-threaded context.
//!
//! Set up Seq logging in your root file with the following globals:
//!
//! ```zig
//! // assuming imports...
//!
//! // must be mutable and public with this name
//! pub var seq_background_worker: SeqBackgroundWorker = .init;
//! // optionally declare additional properties to send in each log message
//! pub const additional_log_props = .{
//!     .application = "My Awesome App",
//! };
//!
//! pub fn main() !void {
//!     // assuming Io and Allocator interfaces...
//!
//!     try seq_background_worker.start(io, gpa, .{
//!         // fill these in for your Seq server url and API key...
//!         .url = undefined,
//!         .api_key = "",
//!     });
//!     defer seq_background_worker.shutdown();
//!
//!     // application code...
//! }
//! ```

pub const log = @import("log.zig");

/// Configuration on the Seq server
pub const SeqConfig = struct {
    /// Seq server base URL we're posting logs to (with or without trailing /).
    /// Currently, the /ingest/clef endpoint is used.
    base_url: []const u8,
    /// API key
    api_key: []const u8,
    /// Minimum logging level enabled
    minimum_level: SeqLogLevel = switch (@import("builtin").mode) {
        .Debug => .Debug,
        .ReleaseSafe => .Information,
        else => .Warning,
    },
    /// How often (in milliseconds) we flush collected logs to the Seq server.
    /// Defaults to 5K (5 seconds).
    flush_interval_ms: u32 = 5_000,
    /// Once the collected logs exceeds this threshold, they will be flushed.
    /// Defaults to ~8KB.
    log_capacity: u32 = 8096,
};

/// Worker that holds the background thread, asynchronously batching and sending logs to the Seq server
pub const SeqBackgroundWorker = struct {
    /// Background thread
    thread: Thread,
    /// Seq client
    client: SeqClient,
    /// Signal controlling the state of the background worker
    signal: Atomic(Signal),

    /// Expected field name of the mutable global variable that handles the background process of sending logs to Seq.
    pub const root_decl_name = "seq_background_worker";

    const Signal = enum(u8) {
        /// Not running yet; some fields remain unitialized, and it wouldn't be safe to write logs yet
        staged,
        /// All fields initialized, and we can safely record logs
        running,
        /// The kill signal is set
        stopped,
    };

    /// This initialized value is inert, leaving the background thread and client undefined
    pub const init: SeqBackgroundWorker = .{
        .thread = undefined,
        .client = undefined,
        .signal = .init(.staged),
    };

    /// Start the seq client.
    /// `gpa` must be threadsafe.
    pub fn start(self: *SeqBackgroundWorker, io: Io, gpa: Allocator, config: SeqConfig) Thread.SpawnError!void {
        self.thread = try .spawn(.{}, worker, .{ self, io, gpa, config });
    }

    /// For a clean shutdown, this sends a kill signal to the background thread.
    /// Flushes all logs on shutdown.
    pub fn shutdown(self: *SeqBackgroundWorker) void {
        self.signal.store(.stopped, .seq_cst);
        self.thread.join();
        // client is created and cleaned up in the background thread; don't want to attempt to deinit() something that could be undefined
        self.* = undefined;
    }

    fn worker(self: *SeqBackgroundWorker, io: Io, gpa: Allocator, config: SeqConfig) void {
        self.client = SeqClient.init(io, gpa, config) catch |err| {
            if (@errorReturnTrace()) |t| debug.dumpStackTrace(t);
            std_log.err("FATAL: SeqBackgroundWorker cannot start: {t}", .{err});
            self.signal.store(.stopped, .seq_cst);
            return;
        };
        defer self.client.deinit(gpa);

        // everything is initialized!
        self.signal.store(.running, .seq_cst);
        while (self.signal.load(.monotonic) == .running) self.client.evaluate() catch |err| {
            if (@errorReturnTrace()) |t| debug.dumpStackTrace(t);
            switch (err) {
                // any others that should kill the background thread?
                error.OutOfMemory, error.ConnectionRefused => |e| {
                    std_log.err("FATAL: SeqBackgroundWorker encountered unrecoverable error: {t}. Returning from background thread...", .{e});
                    return;
                },
                else => std_log.err("ERROR: SeqBackgroundWorker encountered the following error: {t}", .{err}),
            }
        };

        // received sig kill
        std_log.info("Flushing Seq client...", .{});
        if (self.client.flush()) {
            std_log.info("Seq client successfully flushed all logs.", .{});
        } else |err| {
            if (@errorReturnTrace()) |t| debug.dumpStackTrace(t);
            std_log.err("ERROR: Failed to flush Seq client on shutdown: {t}", .{err});
        }
    }

    fn oomKill(self: *SeqBackgroundWorker, err_return_trace: ?*builtin.StackTrace) void {
        if (err_return_trace) |t| debug.dumpStackTrace(t);
        std_log.err("FATAL: SeqBackgroundWorker ran out of memory. Killing background thread...", .{});
        // kill the background worker
        self.signal.store(.stopped, .release);
    }
};

/// Assumes a public mutable global variable called "seq_background_worker" of type `SeqBackgroundWorker`.
/// Also calls `std.options.logFn` so whichever log function override you provide will still be respected.
pub fn seqLogFn(
    comptime src: builtin.SourceLocation,
    comptime level: SeqLogLevel,
    comptime scope: @EnumLiteral(),
    comptime log_format: []const u8,
    args: anytype,
    err_return_trace: ?*const builtin.StackTrace,
) void {
    const root = @import("root");
    if (comptime @hasDecl(root, SeqBackgroundWorker.root_decl_name) and
        @TypeOf(@field(root, SeqBackgroundWorker.root_decl_name)) == SeqBackgroundWorker)
    {
        // still call the std log no matter what
        const std_level: std.log.Level = switch (level) {
            .Verbose, .Debug => .debug,
            .Information => .info,
            .Warning => .warn,
            .Error, .Fatal => .err,
        };
        if (comptime std.log.logEnabled(std_level, scope)) {
            std.options.logFn(std_level, scope, log_format, args);
        }

        const background_worker: *SeqBackgroundWorker = &@field(root, SeqBackgroundWorker.root_decl_name);
        // ensure that everything is initialized before proceeding
        while (switch (background_worker.signal.load(.monotonic)) {
            .staged => true,
            .running => false,
            .stopped => return,
        }) {
            // spin...
        }

        background_worker.client.writeLog(
            level,
            scope,
            log_format,
            args,
            src,
            err_return_trace,
        ) catch background_worker.oomKill(@errorReturnTrace());
    } else @compileError("Root source file does not declare a public global variable of type `" ++ @typeName(SeqBackgroundWorker) ++ "` named '" ++ SeqBackgroundWorker.root_decl_name ++ "'");
}

/// Client that interfaces with the Seq server
const SeqClient = struct {
    /// Ingestion endpoint of the Seq server
    seq_ingestion_endpoint: Uri,
    /// Raw bytes of the URI
    seq_endpoint_raw: []const u8,
    /// Interned JSON payloads to be sent to the Seq server
    bytes: Io.Writer.Allocating,
    /// Offsets with the contiguous region of `bytes`, indicating the start of a new JSON payload until the next null byte
    indices: ArrayList(LogIndex),
    /// Arena for scratch space as needed
    arena: ArenaAllocator,
    /// Http client
    connection: HttpClient,
    /// Configuration
    config: SeqConfig,
    /// The last time the logs sent to the client
    last_flush: Io.Timestamp,
    /// Mutex to ensure that writes and flushes do not interfere with one another (ref to the mutex in the background worker)
    mutex: Io.Mutex,

    const ParamsAndSpecifiers = struct {
        param: []const u8,
        specifier: []const u8,
    };

    const Error = HttpClient.ConnectError ||
        HttpRequest.ReceiveHeadError ||
        std.http.Reader.BodyError ||
        error{NonSuccessResponse};

    fn init(io: Io, gpa: Allocator, config: SeqConfig) (Allocator.Error || Uri.ParseError)!SeqClient {
        const base_url: []const u8 = mem.trimEnd(u8, config.base_url, "/");
        const uri_raw: []u8 = try gpa.alloc(u8, base_url.len + ingestion_path.len);
        errdefer gpa.free(uri_raw);

        @memcpy(uri_raw[0..base_url.len], base_url);
        @memcpy(uri_raw[base_url.len..], ingestion_path);

        var indices: ArrayList(LogIndex) = try .initCapacity(gpa, @divTrunc(config.log_capacity, 2));
        errdefer indices.deinit(gpa);

        var bytes: Io.Writer.Allocating = try .initCapacity(gpa, @intFromFloat(@as(f64, @floatFromInt(config.log_capacity)) * 1.5));
        errdefer bytes.deinit();

        return .{
            .seq_ingestion_endpoint = try .parse(uri_raw),
            .seq_endpoint_raw = uri_raw,
            .bytes = bytes,
            .indices = indices,
            .arena = .init(gpa),
            .connection = .{ .io = io, .allocator = gpa },
            .config = config,
            .last_flush = .now(io, .real),
            .mutex = .init,
        };
    }

    fn getIo(self: *const SeqClient) Io {
        return self.connection.io;
    }

    fn writeLog(
        self: *SeqClient,
        comptime level: SeqLogLevel,
        comptime scope: @EnumLiteral(),
        comptime log_format: []const u8,
        args: anytype,
        src: builtin.SourceLocation,
        err_return_trace: ?*const builtin.StackTrace,
    ) Allocator.Error!void {
        const ArgsType = @TypeOf(args);

        if (level.lessThan(self.config.minimum_level)) {
            return;
        }

        var src_stream: Io.Writer.Allocating = .init(self.arena.allocator());
        defer _ = self.arena.reset(.{ .retain_with_limit = @divTrunc(self.config.log_capacity, 2) });

        src_stream.writer.print("{s}.{s}<{s}>:{d}", .{
            src.module,
            src.file,
            src.fn_name,
            src.line,
        }) catch return error.OutOfMemory;

        var seq_payload: SeqBody(ArgsType) = undefined;
        seq_payload.scope = @tagName(scope);
        seq_payload.location = src_stream.written();
        seq_payload.@"@l" = level;
        seq_payload.error_trace = if (err_return_trace) |err_trace| write_err_trace: {
            var err_trace_stream: Io.Writer.Allocating = .init(self.arena.allocator());
            const terminal: Io.Terminal = .{ .writer = &err_trace_stream.writer, .mode = .no_color };

            debug.writeStackTrace(err_trace, terminal) catch return error.OutOfMemory;
            break :write_err_trace err_trace_stream.written();
        } else null;

        var date_time_buf: [24]u8 = undefined;
        seq_payload.@"@t" = util.utcNowAsIsoString(self.getIo(), &date_time_buf); // timestamp

        if (!@typeInfo(ArgsType).@"struct".is_tuple) {
            // copy fields from args struct, which then become parameterized values given to Seq
            const params: [@typeInfo(ArgsType).@"struct".fields.len]ParamsAndSpecifiers = parametersAndSpecifiers(log_format, ArgsType);
            inline for (&params) |p| {
                var stream: Io.Writer.Allocating = .init(self.arena.allocator());
                stream.writer.print("{" ++ p.specifier ++ "}", .{@field(args, p.param)}) catch return error.OutOfMemory;
                @field(seq_payload, p.param) = stream.written();
            }
        }

        // very unlikely that we'll allocate any more than this, but it's technically possible, so I don't trust a stack buffer
        var message_stream: Io.Writer.Allocating = try .initCapacity(self.arena.allocator(), log_format.len);
        message_stream.writer.print(log_format, args) catch return error.OutOfMemory;
        seq_payload.@"@m" = message_stream.written();

        // critical section
        {
            self.mutex.lockUncancelable(self.getIo());
            defer self.mutex.unlock(self.getIo());

            const offset: LogIndex = @enumFromInt(self.bytes.written().len);
            try self.indices.append(self.bytes.allocator, offset);

            var serializer: json.Stringify = .{
                .writer = &self.bytes.writer,
                .options = .{ .emit_null_optional_fields = false },
            };
            // write the payload body into the bytes
            serializer.write(seq_payload) catch return error.OutOfMemory;

            // append a null byte at the end
            self.bytes.writer.writeByte(0) catch return error.OutOfMemory;
        }
    }

    inline fn parametersAndSpecifiers(
        comptime log_format: []const u8,
        comptime TArgs: type,
    ) [@typeInfo(TArgs).@"struct".fields.len]ParamsAndSpecifiers {
        comptime {
            var result: [@typeInfo(TArgs).@"struct".fields.len]ParamsAndSpecifiers = undefined;
            var idx: usize = 0;
            var begin_arg_name: usize = undefined;
            var begin_specifier: usize = undefined;
            var arg_name_len: usize = 0;
            var specifier_len: usize = 0;
            var state: enum { begin_field, arg_name, specifier, none } = .none;

            outer: for (log_format, 0..) |char, i| switch (state) {
                .none => if (char == '{') {
                    state = .begin_field;
                },
                .begin_field => {
                    debug.assert(char == '[' and i + 1 < log_format.len); // should be checked by comptime
                    begin_arg_name = i + 1;
                    state = .arg_name;
                },
                .arg_name => {
                    if (char == ']') {
                        begin_specifier = i + 1;
                        state = .specifier;
                    } else arg_name_len += 1;
                },
                .specifier => {
                    if (char == '}') {
                        defer {
                            arg_name_len = 0;
                            specifier_len = 0;
                            state = .none;
                        }
                        const arg_name: []const u8 = log_format[begin_arg_name..][0..arg_name_len];
                        const specifier: []const u8 = log_format[begin_specifier..][0..specifier_len];
                        for (0..idx) |j| {
                            if (mem.eql(u8, arg_name, result[j].param)) continue :outer;
                        }
                        result[idx] = .{ .param = arg_name, .specifier = specifier };
                        idx += 1;
                    } else specifier_len += 1;
                },
            };
            return result;
        }
    }

    fn evaluate(self: *SeqClient) Error!void {
        if (self.last_flush.durationTo(.now(self.getIo(), .real)).toMilliseconds() >= self.config.flush_interval_ms or
            self.bytes.written().len >= self.config.log_capacity)
        {
            try self.flush();
        }
    }

    fn flush(self: *SeqClient) Error!void {
        self.mutex.lockUncancelable(self.getIo());
        defer self.mutex.unlock(self.getIo());

        for (self.indices.items) |idx| {
            // these should be the JSON bodies prepared to be sent
            const entry: []u8 = mem.sliceTo(self.bytes.written()[@intFromEnum(idx)..], 0);
            var request: HttpRequest = try self.connection.request(.POST, self.seq_ingestion_endpoint, .{
                .headers = .{
                    .authorization = .{ .override = self.config.api_key },
                },
            });
            defer request.deinit();

            try request.sendBodyComplete(entry);
            var buf: struct { redirect: [1024]u8, resp_body: [1024]u8 } = undefined;
            var response: HttpResponse = try request.receiveHead(&buf.redirect);
            if (response.head.status.class() != .success) {
                const reader: *Io.Reader = response.reader(&buf.resp_body);

                var stream: Io.Writer.Allocating = .init(self.bytes.allocator);
                defer stream.deinit();

                _ = reader.stream(&stream.writer, .unlimited) catch |err| switch (err) {
                    Io.Reader.StreamError.ReadFailed => return response.bodyErr().?,
                    Io.Reader.StreamError.WriteFailed => return error.OutOfMemory,
                    Io.Reader.StreamError.EndOfStream => {},
                };
                std_log.err("Seq server responded with non-success code {d}: {s}", .{ response.head.status, stream.written() });
                return error.NonSuccessResponse;
            }
        }
        self.reset();
    }

    fn reset(self: *SeqClient) void {
        self.bytes.clearRetainingCapacity();
        self.indices.clearRetainingCapacity();
        self.last_flush = .now(self.getIo(), .real);
    }

    fn deinit(self: *SeqClient, gpa: Allocator) void {
        gpa.free(self.seq_endpoint_raw);
        self.connection.deinit();
        self.bytes.deinit();
        self.indices.deinit(gpa);
        self.arena.deinit();
        self.* = undefined;
    }

    test writeLog {
        var client: SeqClient = try .init(testing.io, testing.allocator, .{ .base_url = "https://my_seq.com", .api_key = "" });
        defer client.deinit(testing.allocator);

        // empty args
        {
            defer client.reset();

            try client.writeLog(.Debug, .testing, "This is a log", .{}, @src(), null);
            const Body = SeqBody(@TypeOf(.{}));

            const written: []const u8 = mem.sliceTo(client.bytes.written(), 0);
            const parsed: json.Parsed(Body) = try json.parseFromSlice(Body, testing.allocator, written, .{});
            defer parsed.deinit();

            try testing.expectEqualStrings(parsed.value.scope, @tagName(.testing));
            try testing.expectEqual(parsed.value.@"@l", .Debug);
            try testing.expectEqualStrings(parsed.value.@"@m", "This is a log");
        }
        // tuple
        {
            defer client.reset();

            try client.writeLog(.Debug, .testing, "This is a log {d}: {s}", .{ 0, "yay" }, @src(), null);
            const Body = SeqBody(@TypeOf(.{}));

            const written: []const u8 = mem.sliceTo(client.bytes.written(), 0);
            const parsed: json.Parsed(Body) = try json.parseFromSlice(Body, testing.allocator, written, .{});
            defer parsed.deinit();

            try testing.expectEqualStrings(parsed.value.scope, @tagName(.testing));
            try testing.expectEqual(parsed.value.@"@l", .Debug);
            try testing.expectEqualStrings(parsed.value.@"@m", "This is a log 0: yay");
        }
        // struct
        {
            defer client.reset();
            const args = .{ .num = 0, .message = "yay" };

            try client.writeLog(.Debug, .testing, "This is a log {[num]d}: {[message]s}", args, @src(), null);
            const Body = SeqBody(@TypeOf(args));

            const written: []const u8 = mem.sliceTo(client.bytes.written(), 0);
            const parsed: json.Parsed(Body) = try json.parseFromSlice(Body, testing.allocator, written, .{});
            defer parsed.deinit();

            try testing.expectEqualStrings(@tagName(.testing), parsed.value.scope);
            try testing.expectEqual(.Debug, parsed.value.@"@l");
            try testing.expectEqualStrings("This is a log 0: yay", parsed.value.@"@m");
            try testing.expectEqualStrings(std.fmt.comptimePrint("{d}", .{args.num}), parsed.value.num);
            try testing.expectEqualStrings(args.message, parsed.value.message);
        }
        // struct with repeated fields
        {
            defer client.reset();
            const args = .{ .num = 0, .message = "yay" };

            try client.writeLog(.Debug, .testing, "This is a log {[num]d}{[num]d}: {[message]s}", args, @src(), null);
            const Body = SeqBody(@TypeOf(args));

            const written: []const u8 = mem.sliceTo(client.bytes.written(), 0);
            const parsed: json.Parsed(Body) = try json.parseFromSlice(Body, testing.allocator, written, .{});
            defer parsed.deinit();

            try testing.expectEqualStrings(@tagName(.testing), parsed.value.scope);
            try testing.expectEqual(.Debug, parsed.value.@"@l");
            try testing.expectEqualStrings("This is a log 00: yay", parsed.value.@"@m");
            try testing.expectEqualStrings(std.fmt.comptimePrint("{d}", .{args.num}), parsed.value.num);
            try testing.expectEqualStrings(args.message, parsed.value.message);
        }
        // struct with repeated fields (different specifiers on the same field)
        {
            defer client.reset();
            const args = .{ .num = 0, .message = "yay" };

            try client.writeLog(.Debug, .testing, "This is a log {[num]d} {[num]d:0>4}: {[message]s}", args, @src(), null);
            const Body = SeqBody(@TypeOf(args));

            const written: []const u8 = mem.sliceTo(client.bytes.written(), 0);
            const parsed: json.Parsed(Body) = try json.parseFromSlice(Body, testing.allocator, written, .{});
            defer parsed.deinit();

            try testing.expectEqualStrings(@tagName(.testing), parsed.value.scope);
            try testing.expectEqual(.Debug, parsed.value.@"@l");
            try testing.expectEqualStrings("This is a log 0 0000: yay", parsed.value.@"@m");
            try testing.expectEqualStrings(std.fmt.comptimePrint("{d}", .{args.num}), parsed.value.num);
            try testing.expectEqualStrings(args.message, parsed.value.message);
        }
    }
};

const LogIndex = enum(u32) { _ };

/// Log levels as determined by [Seq](https://datalust.co/docs/posting-raw-events)
pub const SeqLogLevel = enum(u8) {
    /// Also known as "trace" logging
    /// This is info that would be logged when a --verbose flag is passed in, logging everything imaginable
    Verbose = 0,
    /// One level above verbose
    Debug = 1,
    /// Normal information-level logging for normal operations
    Information = 2,
    /// Give an indication that data or some expected conditions are off, which may be a sign of an error or bug
    Warning = 3,
    /// Error, presumably one that does not result in application exit
    Error = 4,
    /// Error that results in application exit
    Fatal = 5,

    fn lessThan(a: SeqLogLevel, b: SeqLogLevel) bool {
        return @intFromEnum(a) < @intFromEnum(b);
    }
};

fn SeqBody(comptime TBody: type) type {
    // additional props declared at root
    const added_field_names, const added_field_types, const added_field_attrs = added_fields: {
        const root = @import("root");
        if (@hasDecl(root, "additional_log_props") and
            @typeInfo(@TypeOf(root.additional_log_props)) == .@"struct" and
            !@typeInfo(@TypeOf(root.additional_log_props)).@"struct".is_tuple)
        {
            const props_fields = @typeInfo(@TypeOf(root.additional_log_props)).@"struct".fields;
            var names: [props_fields.len][]const u8 = undefined;
            var types: [props_fields.len]type = undefined;
            var attrs: [props_fields.len]StructField.Attributes = undefined;
            for (&names, &types, &attrs, props_fields) |*name, *t, *attr, field| {
                name.* = field.name;
                t.* = field.type;
                attr.* = .{
                    // MUST be comptime-set
                    .@"comptime" = true,
                    .@"align" = @alignOf(field.type),
                    .default_value_ptr = @ptrCast(@as(*const field.type, &@field(root.additional_log_props, field.name))),
                };
            }
            break :added_fields .{ names, types, attrs };
        }
        break :added_fields .{ [_][]const u8{}, [_]type{}, [_]StructField.Attributes{} };
    };
    // derived props from TBody
    const derived_field_names, const derived_field_types, const derived_field_attrs =
        if (@typeInfo(TBody).@"struct".is_tuple)
            // don't add in fields from a tuple since they're all "0", "1", etc., and that's really meh for structured logging
            .{ [_][]const u8{}, [_]type{}, [_]StructField.Attributes{} }
        else derived_fields: {
            var names: [@typeInfo(TBody).@"struct".fields.len][]const u8 = undefined;
            var types: [@typeInfo(TBody).@"struct".fields.len]type = undefined;
            var attrs: [@typeInfo(TBody).@"struct".fields.len]StructField.Attributes = undefined;
            for (&names, &types, &attrs, @typeInfo(TBody).@"struct".fields) |*name, *t, *attr, field| {
                name.* = field.name;
                t.* = []const u8;
                attr.* = .{
                    .@"comptime" = false,
                    .@"align" = @alignOf([]const u8),
                    .default_value_ptr = @ptrCast(@as(*const []const u8, &"")),
                };
            }
            break :derived_fields .{ names, types, attrs };
        };

    const field_names = added_field_names ++ derived_field_names ++ .{ "@t", "@l", "@m", "scope", "location", "error_trace" };
    const field_types = added_field_types ++ derived_field_types ++ .{ []const u8, SeqLogLevel, []const u8, []const u8, []const u8, ?[]const u8 };
    const field_attrs = added_field_attrs ++ derived_field_attrs ++ [_]StructField.Attributes{
        .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf([]const u8) },
        .{ .default_value_ptr = null, .@"comptime" = false, .@"align" = @alignOf(SeqLogLevel) },
        .{ .default_value_ptr = @ptrCast(@as(*const []const u8, &"")), .@"comptime" = false, .@"align" = @alignOf([]const u8) },
        .{ .default_value_ptr = @ptrCast(@as(*const []const u8, &"")), .@"comptime" = false, .@"align" = @alignOf([]const u8) },
        .{ .default_value_ptr = @ptrCast(@as(*const []const u8, &"")), .@"comptime" = false, .@"align" = @alignOf([]const u8) },
        .{ .default_value_ptr = @ptrCast(@as(*const ?[]const u8, &null)), .@"comptime" = false, .@"align" = @alignOf(?[]const u8) },
    };
    return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
}

comptime {
    // unit-test non-pub structs
    _ = SeqClient;
}

fn getSrc(io: Io, debug_info: *debug.SelfInfo, addr: usize) debug.SelfInfoError!?debug.SourceLocation {
    const symbol: debug.Symbol = try debug_info.getSymbol(io, addr);
    return symbol.source_location;
}

const ingestion_path = "/ingest/clef";

const std = @import("std");
const util = @import("util.zig");
const Io = std.Io;
const debug = std.debug;
const builtin = std.builtin;
const json = std.json;
const mem = std.mem;
const testing = std.testing;
const Thread = std.Thread;
const Atomic = std.atomic.Value;
const Allocator = mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const ArrayList = std.ArrayList;
const Uri = std.Uri;
const HttpClient = std.http.Client;
const HttpRequest = HttpClient.Request;
const HttpResponse = HttpClient.Response;
const StructField = builtin.Type.StructField;
const LogLevel = std.log.Level;
const std_log = std.log.scoped(.seq_zig);
