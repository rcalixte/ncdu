// SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");
const main = @import("main.zig");
const model = @import("model.zig");
const util = @import("util.zig");
const sink = @import("sink.zig");
const ui = @import("ui.zig");
const bin_export = @import("bin_export.zig");
const c = @import("c");

const CborMajor = bin_export.CborMajor;
const ItemKey = bin_export.ItemKey;

// Two ways to read a bin export:
//
// 1. Streaming import
//   - Read blocks sequentially, assemble items into model.Entry's and stitch
//     them together on the go.
//   - Does not use the sink.zig API, since sub-level items are read before their parent dirs.
//   - Useful when:
//     - User attempts to do a refresh or delete while browsing a file through (2)
//     - Reading from a stream
//
// 2. Random access browsing
//   - Read final block first to get the root item, then have browser.zig fetch
//     dir listings from this file.
//   - The default reader mode, requires much less memory than (1) and provides
//     a snappier first-browsing experience.
//
// The approach from (2) can also be used to walk through the entire directory
// tree and stream it to sink.zig (either for importing or converting to JSON).
// That would allow for better code reuse and low-memory conversion, but
// performance will not be as good as a direct streaming read. Needs
// benchmarks.
//
// This file only implements (2) at the moment.

pub const global = struct {
    var fd: std.Io.File = undefined;
    var index: []u8 = undefined;
    var blocks: [8]Block = @splat(.{});
    var counter: u64 = 0;

    // Last itemref being read/parsed. This is a hack to provide *some* context on error.
    // Providing more context mainly just bloats the binary and decreases
    // performance for fairly little benefit. Nobody's going to debug a corrupted export.
    var lastitem: ?u64 = null;
};

const Block = struct {
    num: u32 = std.math.maxInt(u32),
    last: u64 = 0,
    data: []u8 = undefined,
};

inline fn bigu16(v: [2]u8) u16 {
    return std.mem.bigToNative(u16, @bitCast(v));
}
inline fn bigu32(v: [4]u8) u32 {
    return std.mem.bigToNative(u32, @bitCast(v));
}
inline fn bigu64(v: [8]u8) u64 {
    return std.mem.bigToNative(u64, @bitCast(v));
}

fn die() noreturn {
    @branchHint(.cold);
    if (global.lastitem) |e|
        ui.die("Error reading item {x} from file\n", .{e})
    else
        ui.die("Error reading from file\n", .{});
}

fn readBlock(io: std.Io, num: u32) []const u8 {
    // Simple linear search, only suitable if we keep the number of in-memory blocks small.
    var block: *Block = &global.blocks[0];
    for (&global.blocks) |*b| {
        if (b.num == num) {
            if (b.last != global.counter) {
                global.counter += 1;
                b.last = global.counter;
            }
            return b.data;
        }
        if (block.last > b.last) block = b;
    }
    if (block.num != std.math.maxInt(u32))
        main.allocator.free(block.data);
    block.num = num;
    global.counter += 1;
    block.last = global.counter;

    if (num > global.index.len / 8 - 1) die();
    const offlen = bigu64(global.index[num * 8 ..][0..8].*);
    const off = offlen >> 24;
    const len = offlen & 0xffffff;
    if (len <= 12) die();

    // Only read the compressed data part, assume block header, number and footer are correct.
    const buf = main.allocator.alloc(u8, @intCast(len - 12)) catch unreachable;
    defer main.allocator.free(buf);
    const rdlen = global.fd.readPositionalAll(io, buf, off + 8) catch |e|
        ui.die("Error reading from file: {s}\n", .{ui.errorString(e)});
    if (rdlen != buf.len) die();

    const rawlen = c.ZSTD_getFrameContentSize(buf.ptr, buf.len);
    if (rawlen <= 0 or rawlen >= (1 << 24)) die();
    block.data = main.allocator.alloc(u8, @intCast(rawlen)) catch unreachable;

    const res = c.ZSTD_decompress(block.data.ptr, block.data.len, buf.ptr, buf.len);
    if (res != block.data.len) ui.die("Error decompressing block {} (expected {} got {})\n", .{ num, block.data.len, res });

    return block.data;
}

const CborReader = struct {
    buf: []const u8,

    fn head(r: *CborReader) CborVal {
        if (r.buf.len < 1) die();
        var v = CborVal{
            .rd = r,
            .major = @enumFromInt(r.buf[0] >> 5),
            .indef = false,
            .arg = 0,
        };
        switch (r.buf[0] & 0x1f) {
            0x00...0x17 => |n| {
                v.arg = n;
                r.buf = r.buf[1..];
            },
            0x18 => {
                if (r.buf.len < 2) die();
                v.arg = r.buf[1];
                r.buf = r.buf[2..];
            },
            0x19 => {
                if (r.buf.len < 3) die();
                v.arg = bigu16(r.buf[1..3].*);
                r.buf = r.buf[3..];
            },
            0x1a => {
                if (r.buf.len < 5) die();
                v.arg = bigu32(r.buf[1..5].*);
                r.buf = r.buf[5..];
            },
            0x1b => {
                if (r.buf.len < 9) die();
                v.arg = bigu64(r.buf[1..9].*);
                r.buf = r.buf[9..];
            },
            0x1f => switch (v.major) {
                .bytes, .text, .array, .map, .simple => {
                    v.indef = true;
                    r.buf = r.buf[1..];
                },
                else => die(),
            },
            else => die(),
        }
        return v;
    }

    // Read the next CBOR value, skipping any tags
    fn next(r: *CborReader) CborVal {
        while (true) {
            const v = r.head();
            if (v.major != .tag) return v;
        }
    }
};

const CborVal = struct {
    rd: *CborReader,
    major: CborMajor,
    indef: bool,
    arg: u64,

    fn end(v: *const CborVal) bool {
        return v.major == .simple and v.indef;
    }

    fn int(v: *const CborVal, T: type) T {
        switch (v.major) {
            .pos => return std.math.cast(T, v.arg) orelse die(),
            .neg => {
                if (std.math.minInt(T) == 0) die();
                if (v.arg > std.math.maxInt(T)) die();
                return -@as(T, @intCast(v.arg)) + (-1);
            },
            else => die(),
        }
    }

    fn isTrue(v: *const CborVal) bool {
        return v.major == .simple and v.arg == 21;
    }

    // Read either a byte or text string.
    // Doesn't validate UTF-8 strings, doesn't support indefinite-length strings.
    fn bytes(v: *const CborVal) []const u8 {
        if (v.indef or (v.major != .bytes and v.major != .text)) die();
        if (v.rd.buf.len < v.arg) die();
        defer v.rd.buf = v.rd.buf[@intCast(v.arg)..];
        return v.rd.buf[0..@intCast(v.arg)];
    }

    // Skip current value.
    fn skip(v: *const CborVal) void {
        // indefinite-length bytes, text, array or map; skip till break marker.
        if (v.major != .simple and v.indef) {
            while (true) {
                const n = v.rd.next();
                if (n.end()) return;
                n.skip();
            }
        }
        switch (v.major) {
            .bytes, .text => {
                if (v.rd.buf.len < v.arg) die();
                v.rd.buf = v.rd.buf[@intCast(v.arg)..];
            },
            .array => {
                if (v.arg > (1 << 24)) die();
                for (0..@intCast(v.arg)) |_| v.rd.next().skip();
            },
            .map => {
                if (v.arg > (1 << 24)) die();
                for (0..@intCast(v.arg *| 2)) |_| v.rd.next().skip();
            },
            else => {},
        }
    }

    fn etype(v: *const CborVal) model.EType {
        const n = v.int(i32);
        return if (std.enums.fromInt(model.EType, n)) |i| i else if (n < 0)
            .pattern
        else
            .nonreg;
    }

    fn itemref(v: *const CborVal, cur: u64) u64 {
        if (v.major == .pos) return v.arg;
        if (v.major == .neg) {
            if (v.arg >= (cur & 0xffffff)) die();
            return cur - v.arg - 1;
        }
        return die();
    }
};

test "CBOR int parsing" {
    inline for (.{
        .{ .in = "\x00", .t = u1, .exp = 0 },
        .{ .in = "\x01", .t = u1, .exp = 1 },
        .{ .in = "\x18\x18", .t = u8, .exp = 0x18 },
        .{ .in = "\x18\xff", .t = u8, .exp = 0xff },
        .{ .in = "\x19\x07\xff", .t = u64, .exp = 0x7ff },
        .{ .in = "\x19\xff\xff", .t = u64, .exp = 0xffff },
        .{ .in = "\x1a\x00\x01\x00\x00", .t = u64, .exp = 0x10000 },
        .{ .in = "\x1b\x7f\xff\xff\xff\xff\xff\xff\xff", .t = i64, .exp = std.math.maxInt(i64) },
        .{ .in = "\x1b\xff\xff\xff\xff\xff\xff\xff\xff", .t = u64, .exp = std.math.maxInt(u64) },
        .{ .in = "\x1b\xff\xff\xff\xff\xff\xff\xff\xff", .t = i65, .exp = std.math.maxInt(u64) },
        .{ .in = "\x20", .t = i1, .exp = -1 },
        .{ .in = "\x38\x18", .t = i8, .exp = -0x19 },
        .{ .in = "\x39\x01\xf3", .t = i16, .exp = -500 },
        .{ .in = "\x3a\xfe\xdc\xba\x97", .t = i33, .exp = -0xfedc_ba98 },
        .{ .in = "\x3b\x7f\xff\xff\xff\xff\xff\xff\xff", .t = i64, .exp = std.math.minInt(i64) },
        .{ .in = "\x3b\xff\xff\xff\xff\xff\xff\xff\xff", .t = i65, .exp = std.math.minInt(i65) },
    }) |t| {
        var r = CborReader{ .buf = t.in };
        try std.testing.expectEqual(@as(t.t, t.exp), r.next().int(t.t));
        try std.testing.expectEqual(0, r.buf.len);
    }
}

test "CBOR string parsing" {
    var r = CborReader{ .buf = "\x40" };
    try std.testing.expectEqualStrings("", r.next().bytes());
    r.buf = "\x45\x00\x01\x02\x03\x04x";
    try std.testing.expectEqualStrings("\x00\x01\x02\x03\x04", r.next().bytes());
    try std.testing.expectEqualStrings("x", r.buf);
    r.buf = "\x78\x241234567890abcdefghijklmnopqrstuvwxyz-end";
    try std.testing.expectEqualStrings("1234567890abcdefghijklmnopqrstuvwxyz", r.next().bytes());
    try std.testing.expectEqualStrings("-end", r.buf);
}

test "CBOR skip parsing" {
    inline for (.{
        "\x00",
        "\x40",
        "\x41a",
        "\x5f\xff",
        "\x5f\x41a\xff",
        "\x80",
        "\x81\x00",
        "\x9f\xff",
        "\x9f\x9f\xff\xff",
        "\x9f\x9f\x81\x00\xff\xff",
        "\xa0",
        "\xa1\x00\x01",
        "\xbf\xff",
        "\xbf\xc0\x00\x9f\xff\xff",
    }) |s| {
        var r = CborReader{ .buf = s ++ "garbage" };
        r.next().skip();
        try std.testing.expectEqualStrings(r.buf, "garbage");
    }
}

const ItemParser = struct {
    r: CborReader,
    len: ?u64 = null,

    const Field = struct {
        key: ItemKey,
        val: CborVal,
    };

    fn init(buf: []const u8) ItemParser {
        var r = ItemParser{ .r = .{ .buf = buf } };
        const head = r.r.next();
        if (head.major != .map) die();
        if (!head.indef) r.len = head.arg;
        return r;
    }

    fn key(r: *ItemParser) ?CborVal {
        if (r.len) |*l| {
            if (l.* == 0) return null;
            l.* -= 1;
            return r.r.next();
        } else {
            const v = r.r.next();
            return if (v.end()) null else v;
        }
    }

    // Skips over any fields that don't fit into an ItemKey.
    fn next(r: *ItemParser) ?Field {
        while (r.key()) |k| {
            if (k.major == .pos and k.arg <= std.math.maxInt(@typeInfo(ItemKey).@"enum".tag_type)) return .{
                .key = @enumFromInt(k.arg),
                .val = r.r.next(),
            } else {
                k.skip();
                r.r.next().skip();
            }
        }
        return null;
    }
};

// Returned buffer is valid until the next readItem().
fn readItem(io: std.Io, ref: u64) ItemParser {
    global.lastitem = ref;
    if (ref >= (1 << (24 + 32))) die();
    const block = readBlock(io, @intCast(ref >> 24));
    if ((ref & 0xffffff) >= block.len) die();
    return ItemParser.init(block[@intCast(ref & 0xffffff)..]);
}

const Import = struct {
    sink: *sink.Thread,
    stat: sink.Stat = .{},
    fields: Fields = .{},
    p: ItemParser = undefined,

    const Fields = struct {
        name: []const u8 = "",
        rderr: bool = false,
        prev: ?u64 = null,
        sub: ?u64 = null,
    };

    fn readFields(ctx: *Import, io: std.Io, ref: u64) void {
        ctx.p = readItem(io, ref);
        var hastype = false;

        while (ctx.p.next()) |kv| switch (kv.key) {
            .type => {
                ctx.stat.etype = kv.val.etype();
                hastype = true;
            },
            .name => ctx.fields.name = kv.val.bytes(),
            .prev => ctx.fields.prev = kv.val.itemref(ref),
            .asize => ctx.stat.size = kv.val.int(u64),
            .dsize => ctx.stat.blocks = @intCast(kv.val.int(u64) / 512),
            .dev => ctx.stat.dev = kv.val.int(u64),
            .rderr => ctx.fields.rderr = kv.val.isTrue(),
            .sub => ctx.fields.sub = kv.val.itemref(ref),
            .ino => ctx.stat.ino = kv.val.int(u64),
            .nlink => ctx.stat.nlink = kv.val.int(u31),
            .uid => {
                ctx.stat.ext.uid = kv.val.int(u32);
                ctx.stat.ext.pack.hasuid = true;
            },
            .gid => {
                ctx.stat.ext.gid = kv.val.int(u32);
                ctx.stat.ext.pack.hasgid = true;
            },
            .mode => {
                ctx.stat.ext.mode = kv.val.int(u16);
                ctx.stat.ext.pack.hasmode = true;
            },
            .mtime => {
                ctx.stat.ext.mtime = kv.val.int(u64);
                ctx.stat.ext.pack.hasmtime = true;
            },
            else => kv.val.skip(),
        };

        if (!hastype) die();
        if (ctx.fields.name.len == 0) die();
    }

    fn import(ctx: *Import, io: std.Io, ref: u64, parent: ?*sink.Dir, dev: u64) void {
        ctx.stat = .{ .dev = dev };
        ctx.fields = .{};
        ctx.readFields(io, ref);

        if (ctx.stat.etype == .dir) {
            const prev = ctx.fields.prev;
            const dir =
                if (parent) |d|
                    d.addDir(io, ctx.sink, ctx.fields.name, &ctx.stat)
                else
                    sink.createRoot(io, ctx.fields.name, &ctx.stat);
            ctx.sink.setDir(io, dir);
            if (ctx.fields.rderr) dir.setReadError(io, ctx.sink);

            ctx.fields.prev = ctx.fields.sub;
            while (ctx.fields.prev) |n| ctx.import(io, n, dir, ctx.stat.dev);

            ctx.sink.setDir(io, parent);
            dir.unref(io, ctx.sink);
            ctx.fields.prev = prev;
        } else {
            const p = parent orelse die();
            if (@intFromEnum(ctx.stat.etype) < 0)
                p.addSpecial(io, ctx.sink, ctx.fields.name, ctx.stat.etype)
            else
                p.addStat(io, ctx.sink, ctx.fields.name, &ctx.stat);
        }

        if ((ctx.sink.files_seen.load(.monotonic) & 65) == 0)
            main.handleEvent(io, false, false);
    }
};

// Resolve an itemref and return a newly allocated entry.
// Dir.parent and Link.next/prev are left uninitialized.
pub fn get(io: std.Io, ref: u64, alloc: std.mem.Allocator) *model.Entry {
    const parser = readItem(io, ref);

    var etype: ?model.EType = null;
    var name: []const u8 = "";
    var p = parser;
    var ext = model.Ext{};
    while (p.next()) |kv| {
        switch (kv.key) {
            .type => etype = kv.val.etype(),
            .name => name = kv.val.bytes(),
            .uid => {
                ext.uid = kv.val.int(u32);
                ext.pack.hasuid = true;
            },
            .gid => {
                ext.gid = kv.val.int(u32);
                ext.pack.hasgid = true;
            },
            .mode => {
                ext.mode = kv.val.int(u16);
                ext.pack.hasmode = true;
            },
            .mtime => {
                ext.mtime = kv.val.int(u64);
                ext.pack.hasmtime = true;
            },
            else => kv.val.skip(),
        }
    }
    if (etype == null or name.len == 0) die();

    var entry = model.Entry.create(alloc, io, etype.?, main.config.extended and !ext.isEmpty(), name);
    entry.next = .{ .ref = std.math.maxInt(u64) };
    if (entry.ext()) |e| e.* = ext;
    if (entry.dir()) |d| d.sub = .{ .ref = std.math.maxInt(u64) };
    p = parser;
    while (p.next()) |kv| switch (kv.key) {
        .prev => entry.next = .{ .ref = kv.val.itemref(ref) },
        .asize => {
            if (entry.pack.etype != .dir) entry.size = kv.val.int(u64);
        },
        .dsize => {
            if (entry.pack.etype != .dir) entry.pack.blocks = @intCast(kv.val.int(u64) / 512);
        },

        .rderr => {
            if (entry.dir()) |d| {
                if (kv.val.isTrue())
                    d.pack.err = true
                else
                    d.pack.suberr = true;
            }
        },
        .dev => {
            if (entry.dir()) |d| d.pack.dev = model.devices.getId(io, kv.val.int(u64));
        },
        .cumasize => entry.size = kv.val.int(u64),
        .cumdsize => entry.pack.blocks = @intCast(kv.val.int(u64) / 512),
        .shrasize => {
            if (entry.dir()) |d| d.shared_size = kv.val.int(u64);
        },
        .shrdsize => {
            if (entry.dir()) |d| d.shared_blocks = kv.val.int(u64) / 512;
        },
        .items => {
            if (entry.dir()) |d| d.items = util.castClamp(u32, kv.val.int(u64));
        },
        .sub => {
            if (entry.dir()) |d| d.sub = .{ .ref = kv.val.itemref(ref) };
        },

        .ino => {
            if (entry.link()) |l| l.ino = kv.val.int(u64);
        },
        .nlink => {
            if (entry.link()) |l| l.pack.nlink = kv.val.int(u31);
        },
        else => kv.val.skip(),
    };
    return entry;
}

pub fn getRoot() u64 {
    return bigu64(global.index[global.index.len - 8 ..][0..8].*);
}

// Walk through the directory tree in depth-first order and pass results to sink.zig.
// Depth-first is required for JSON export, but more efficient strategies are
// possible for other sinks. Parallel import is also an option, but that's more
// complex and likely less efficient than a streaming import.
pub fn import(io: std.Io) void {
    const sink_threads = sink.createThreads(1);
    var ctx = Import{ .sink = &sink_threads[0] };
    ctx.import(io, getRoot(), null, 0);
    sink.done(io);
}

// Assumes that the file signature has already been read and validated.
pub fn open(io: std.Io, fd: std.Io.File) !void {
    global.fd = fd;

    var fd_buf: [16]u8 = undefined;
    const size = try fd.readPositionalAll(io, &fd_buf, 0);
    if (size < 16) return error.EndOfStream;

    // Read index block
    var buf: [4]u8 = undefined;
    if (try fd.readPositionalAll(io, &buf, size - 4) != 4) return error.EndOfStream;
    const index_header = bigu32(buf);
    if ((index_header >> 28) != 1 or (index_header & 7) != 0) die();
    const len = (index_header & 0x0fffffff) - 8; // excluding block header & footer
    if (len >= size) die();
    global.index = main.allocator.alloc(u8, len) catch unreachable;
    if (try fd.readPositionalAll(io, global.index, size - len - 4) != global.index.len) return error.EndOfStream;
}
