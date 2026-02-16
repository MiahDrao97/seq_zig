# Seq Zig

Sends logs from a Zig application to a [Seq](https://datalust.co/) server for structured logging collection.

## Installation
NOTE : Minimum version is Zig master `0.16.0-dev.2565+684032671`.

Fetch via `zig` CLI:
```
zig fetch https://github.com/MiahDrao97/seq_zig/archive/main.tar.gz --save
```

And then add the import in your `build.zig`
```

```

## Setup

See `main.zig` for a sample integration test.

Essentially, you'll have to add an instance of `SeqBackgroundWorker` as a global variable.
This log collector runs on a background thread.
It still writes logs to STDERR, but also collects the logs as JSON to send to a Seq server.
The flush interval and max buffer size are configurable.

## Usage
