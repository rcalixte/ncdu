// SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");
const main = @import("main.zig");
const util = @import("util.zig");
const model = @import("model.zig");
const sink = @import("sink.zig");
const ui = @import("ui.zig");
const c = @import("c");

const ZstdReader = struct {
    ctx: ?*c.ZSTD_DStream,
    in: c.ZSTD_inBuffer,
    lastret: usize = 0,
    inbuf: [c.ZSTD_BLOCKSIZE_MAX + 16]u8, // This ZSTD_DStreamInSize() + a little bit extra

    fn create(io: std.Io, head: []const u8) *ZstdReader {
        const r = main.allocator.create(ZstdReader) catch unreachable;
        @memcpy(r.inbuf[0..head.len], head);
        r.in = .{
            .src = &r.inbuf,
            .size = head.len,
            .pos = 0,
        };
        while (true) {
            r.ctx = c.ZSTD_createDStream();
            if (r.ctx != null) break;
            ui.oom(io);
        }
        return r;
    }

    fn destroy(r: *ZstdReader) void {
        _ = c.ZSTD_freeDStream(r.ctx);
        main.allocator.destroy(r);
    }

    fn read(r: *ZstdReader, io: std.Io, f: std.Io.File, out: []u8) !usize {
        while (true) {
            if (r.in.size == r.in.pos) {
                r.in.pos = 0;
                var reader = f.readerStreaming(io, &r.inbuf);
                r.in.size = try reader.getSize();
                if (r.in.size == 0) {
                    if (r.lastret == 0) return 0;
                    return error.ZstdDecompressError; // Early EOF
                }
            }

            var arg = c.ZSTD_outBuffer{ .dst = out.ptr, .size = out.len, .pos = 0 };
            r.lastret = c.ZSTD_decompressStream(r.ctx, &arg, &r.in);
            if (c.ZSTD_isError(r.lastret) != 0) return error.ZstdDecompressError;
            if (arg.pos > 0) return arg.pos;
        }
    }
};

// Using a custom JSON parser here because, while std.json is great, it does
// perform strict UTF-8 validation. Which is correct, of course, but ncdu dumps
// are not always correct JSON as they may contain non-UTF-8 paths encoded as
// strings.

const Parser = struct {
    rd: std.Io.File,
    zstd: ?*ZstdReader = null,
    rdoff: usize = 0,
    rdsize: usize = 0,
    byte: u64 = 1,
    line: u64 = 1,
    buf: [129 * 1024]u8 = undefined,
    io: std.Io,

    fn die(p: *Parser, str: []const u8) noreturn {
        ui.die("Error importing file on line {}:{}: {s}.\n", .{ p.line, p.byte, str });
    }

    // Feed back a byte that has just been returned by nextByte()
    fn undoNextByte(p: *Parser, b: u8) void {
        p.byte -= 1;
        p.rdoff -= 1;
        p.buf[p.rdoff] = b;
    }

    fn fill(p: *Parser) void {
        p.rdoff = 0;
        p.rdsize = (if (p.zstd) |z| z.read(p.io, p.rd, &p.buf) else blk: {
            var reader = p.rd.readerStreaming(p.io, &p.buf);
            break :blk reader.getSize();
        }) catch |e| switch (e) {
            error.SystemResources => p.die("out of memory"),
            error.ZstdDecompressError => p.die("decompression error"),
            else => p.die("I/O error"),
        };
    }

    // Returns 0 on EOF.
    // (or if the file contains a 0 byte, but that's invalid anyway)
    // (Returning a '?u8' here is nicer but kills performance by about +30%)
    fn nextByte(p: *Parser) u8 {
        if (p.rdoff == p.rdsize) {
            @branchHint(.unlikely);
            p.fill();
            if (p.rdsize == 0) return 0;
        }
        p.byte += 1;
        defer p.rdoff += 1;
        return (&p.buf)[p.rdoff];
    }

    // next non-whitespace byte
    fn nextChr(p: *Parser) u8 {
        while (true) switch (p.nextByte()) {
            '\n' => {
                p.line += 1;
                p.byte = 1;
            },
            ' ', '\t', '\r' => {},
            else => |b| return b,
        };
    }

    fn expectLit(p: *Parser, lit: []const u8) void {
        for (lit) |b| if (b != p.nextByte()) p.die("invalid JSON");
    }

    fn hexdig(p: *Parser) u16 {
        const b = p.nextByte();
        return switch (b) {
            '0'...'9' => b - '0',
            'a'...'f' => b - 'a' + 10,
            'A'...'F' => b - 'A' + 10,
            else => p.die("invalid hex digit"),
        };
    }

    fn stringContentSlow(p: *Parser, buf: []u8, head: u8, off: usize) []u8 {
        @branchHint(.unlikely);
        var b = head;
        var n = off;
        while (true) {
            switch (b) {
                '"' => break,
                '\\' => switch (p.nextByte()) {
                    '"' => if (n < buf.len) {
                        buf[n] = '"';
                        n += 1;
                    },
                    '\\' => if (n < buf.len) {
                        buf[n] = '\\';
                        n += 1;
                    },
                    '/' => if (n < buf.len) {
                        buf[n] = '/';
                        n += 1;
                    },
                    'b' => if (n < buf.len) {
                        buf[n] = 0x8;
                        n += 1;
                    },
                    'f' => if (n < buf.len) {
                        buf[n] = 0xc;
                        n += 1;
                    },
                    'n' => if (n < buf.len) {
                        buf[n] = 0xa;
                        n += 1;
                    },
                    'r' => if (n < buf.len) {
                        buf[n] = 0xd;
                        n += 1;
                    },
                    't' => if (n < buf.len) {
                        buf[n] = 0x9;
                        n += 1;
                    },
                    'u' => {
                        const first = (p.hexdig() << 12) + (p.hexdig() << 8) + (p.hexdig() << 4) + p.hexdig();
                        var unit = @as(u21, first);
                        if (std.unicode.utf16IsLowSurrogate(first)) p.die("Unexpected low surrogate");
                        if (std.unicode.utf16IsHighSurrogate(first)) {
                            p.expectLit("\\u");
                            const second = (p.hexdig() << 12) + (p.hexdig() << 8) + (p.hexdig() << 4) + p.hexdig();
                            unit = std.unicode.utf16DecodeSurrogatePair(&.{ first, second }) catch p.die("Invalid low surrogate");
                        }
                        if (n + 6 < buf.len)
                            n += std.unicode.utf8Encode(unit, buf[n .. n + 5]) catch unreachable;
                    },
                    else => p.die("invalid escape sequence"),
                },
                0x20, 0x21, 0x23...0x5b, 0x5d...0xff => if (n < buf.len) {
                    buf[n] = b;
                    n += 1;
                },
                else => p.die("invalid character in string"),
            }
            b = p.nextByte();
        }
        return buf[0..n];
    }

    // Read a string (after the ") into buf.
    // Any characters beyond the size of the buffer are consumed but otherwise discarded.
    fn stringContent(p: *Parser, buf: []u8) []u8 {
        // The common case (for ncdu dumps): string fits in the given buffer and does not contain any escapes.
        var n: usize = 0;
        var b = p.nextByte();
        while (n < buf.len and b >= 0x20 and b != '"' and b != '\\') {
            buf[n] = b;
            n += 1;
            b = p.nextByte();
        }
        if (b == '"') return buf[0..n];
        return p.stringContentSlow(buf, b, n);
    }

    fn string(p: *Parser, buf: []u8) []u8 {
        if (p.nextChr() != '"') p.die("expected string");
        return p.stringContent(buf);
    }

    fn uintTail(p: *Parser, head: u8, T: anytype) T {
        if (head == '0') return 0;
        var v: T = head - '0'; // Assumption: T >= u8
        // Assumption: we don't parse JSON "documents" that are a bare uint.
        while (true) switch (p.nextByte()) {
            '0'...'9' => |b| {
                const newv = v *% 10 +% (b - '0');
                if (newv < v) p.die("integer out of range");
                v = newv;
            },
            else => |b| break p.undoNextByte(b),
        };
        if (v == 0) p.die("expected number");
        return v;
    }

    fn uint(p: *Parser, T: anytype) T {
        switch (p.nextChr()) {
            '0'...'9' => |b| return p.uintTail(b, T),
            else => p.die("expected number"),
        }
    }

    fn boolean(p: *Parser) bool {
        switch (p.nextChr()) {
            't' => {
                p.expectLit("rue");
                return true;
            },
            'f' => {
                p.expectLit("alse");
                return false;
            },
            else => p.die("expected boolean"),
        }
    }

    fn obj(p: *Parser) void {
        if (p.nextChr() != '{') p.die("expected object");
    }

    fn key(p: *Parser, first: bool, buf: []u8) ?[]u8 {
        const k = switch (p.nextChr()) {
            ',' => blk: {
                if (first) p.die("invalid JSON");
                break :blk p.string(buf);
            },
            '"' => blk: {
                if (!first) p.die("invalid JSON");
                break :blk p.stringContent(buf);
            },
            '}' => return null,
            else => p.die("invalid JSON"),
        };
        if (p.nextChr() != ':') p.die("invalid JSON");
        return k;
    }

    fn array(p: *Parser) void {
        if (p.nextChr() != '[') p.die("expected array");
    }

    fn elem(p: *Parser, first: bool) bool {
        switch (p.nextChr()) {
            ',' => if (first) p.die("invalid JSON") else return true,
            ']' => return false,
            else => |b| {
                if (!first) p.die("invalid JSON");
                p.undoNextByte(b);
                return true;
            },
        }
    }

    fn skipContent(p: *Parser, head: u8) void {
        switch (head) {
            't' => p.expectLit("rue"),
            'f' => p.expectLit("alse"),
            'n' => p.expectLit("ull"),
            '-', '0'...'9' =>
            // Numbers are kind of annoying, this "parsing" is invalid and ultra-lazy.
            while (true) switch (p.nextByte()) {
                '-', '+', 'e', 'E', '.', '0'...'9' => {},
                else => |b| return p.undoNextByte(b),
            },
            '"' => _ = p.stringContent(&[0]u8{}),
            '[' => {
                var first = true;
                while (p.elem(first)) {
                    first = false;
                    p.skip();
                }
            },
            '{' => {
                var first = true;
                while (p.key(first, &[0]u8{})) |_| {
                    first = false;
                    p.skip();
                }
            },
            else => p.die("invalid JSON"),
        }
    }

    fn skip(p: *Parser) void {
        p.skipContent(p.nextChr());
    }

    fn eof(p: *Parser) void {
        if (p.nextChr() != 0) p.die("trailing garbage");
    }
};

// Should really add some invalid JSON test cases as well, but I'd first like
// to benchmark the performance impact of using error returns instead of
// calling ui.die().
test "JSON parser" {
    const json =
        \\{
        \\  "null": null,
        \\  "true": true,
        \\  "false": false,
        \\  "zero":0 ,"uint": 123,
        \\  "emptyObj": {},
        \\  "emptyArray": [],
        \\  "emptyString": "",
        \\  "encString": "\"\\\/\b\f\n\uBe3F",
        \\  "numbers": [0,1,20,-300, 3.4 ,0e-10  , -100.023e+13 ]
        \\}
    ;
    var p = Parser{ .rd = undefined, .rdsize = json.len, .io = std.testing.io };
    @memcpy(p.buf[0..json.len], json);
    p.skip();

    p = Parser{ .rd = undefined, .rdsize = json.len, .io = std.testing.io };
    @memcpy(p.buf[0..json.len], json);
    var buf: [128]u8 = undefined;
    p.obj();

    try std.testing.expectEqualStrings(p.key(true, &buf).?, "null");
    p.skip();

    try std.testing.expectEqualStrings(p.key(false, &buf).?, "true");
    try std.testing.expect(p.boolean());

    try std.testing.expectEqualStrings(p.key(false, &buf).?, "false");
    try std.testing.expect(!p.boolean());

    try std.testing.expectEqualStrings(p.key(false, &buf).?, "zero");
    try std.testing.expectEqual(0, p.uint(u8));

    try std.testing.expectEqualStrings(p.key(false, &buf).?, "uint");
    try std.testing.expectEqual(123, p.uint(u8));

    try std.testing.expectEqualStrings(p.key(false, &buf).?, "emptyObj");
    p.obj();
    try std.testing.expect(p.key(true, &buf) == null);

    try std.testing.expectEqualStrings(p.key(false, &buf).?, "emptyArray");
    p.array();
    try std.testing.expect(!p.elem(true));

    try std.testing.expectEqualStrings(p.key(false, &buf).?, "emptyString");
    try std.testing.expectEqualStrings(p.string(&buf), "");

    try std.testing.expectEqualStrings(p.key(false, &buf).?, "encString");
    try std.testing.expectEqualStrings(p.string(&buf), "\"\\/\x08\x0c\n\u{be3f}");

    try std.testing.expectEqualStrings(p.key(false, &buf).?, "numbers");
    p.skip();

    try std.testing.expect(p.key(true, &buf) == null);
}

const Ctx = struct {
    p: *Parser,
    sink: *sink.Thread,
    stat: sink.Stat = .{},
    rderr: bool = false,
    namelen: usize = 0,
    namebuf: [32 * 1024]u8 = undefined,
};

fn itemkey(ctx: *Ctx, key: []const u8) void {
    const eq = std.mem.eql;
    switch (if (key.len > 0) key[0] else @as(u8, 0)) {
        'a' => {
            if (eq(u8, key, "asize")) {
                ctx.stat.size = ctx.p.uint(u64);
                return;
            }
        },
        'd' => {
            if (eq(u8, key, "dsize")) {
                ctx.stat.blocks = @intCast(ctx.p.uint(u64) >> 9);
                return;
            }
            if (eq(u8, key, "dev")) {
                ctx.stat.dev = ctx.p.uint(u64);
                return;
            }
        },
        'e' => {
            if (eq(u8, key, "excluded")) {
                var buf: [32]u8 = undefined;
                const typ = ctx.p.string(&buf);
                // "frmlnk" is also possible, but currently considered equivalent to "pattern".
                ctx.stat.etype =
                    if (eq(u8, typ, "otherfs") or eq(u8, typ, "othfs"))
                        .otherfs
                    else if (eq(u8, typ, "kernfs"))
                        .kernfs
                    else
                        .pattern;
                return;
            }
        },
        'g' => {
            if (eq(u8, key, "gid")) {
                ctx.stat.ext.gid = ctx.p.uint(u32);
                ctx.stat.ext.pack.hasgid = true;
                return;
            }
        },
        'h' => {
            if (eq(u8, key, "hlnkc")) {
                if (ctx.p.boolean()) ctx.stat.etype = .link;
                return;
            }
        },
        'i' => {
            if (eq(u8, key, "ino")) {
                ctx.stat.ino = ctx.p.uint(u64);
                return;
            }
        },
        'm' => {
            if (eq(u8, key, "mode")) {
                ctx.stat.ext.mode = ctx.p.uint(u16);
                ctx.stat.ext.pack.hasmode = true;
                return;
            }
            if (eq(u8, key, "mtime")) {
                ctx.stat.ext.mtime = ctx.p.uint(u64);
                ctx.stat.ext.pack.hasmtime = true;
                // Accept decimal numbers, but discard the fractional part because our data model doesn't support it.
                switch (ctx.p.nextByte()) {
                    '.' => while (true) switch (ctx.p.nextByte()) {
                        '0'...'9' => {},
                        else => |b| return ctx.p.undoNextByte(b),
                    },
                    else => |b| return ctx.p.undoNextByte(b),
                }
            }
        },
        'n' => {
            if (eq(u8, key, "name")) {
                if (ctx.namelen != 0) ctx.p.die("duplicate key");
                ctx.namelen = ctx.p.string(&ctx.namebuf).len;
                if (ctx.namelen > ctx.namebuf.len - 5) ctx.p.die("too long file name");
                return;
            }
            if (eq(u8, key, "nlink")) {
                ctx.stat.nlink = ctx.p.uint(u31);
                if (ctx.stat.etype != .dir and ctx.stat.nlink > 1)
                    ctx.stat.etype = .link;
                return;
            }
            if (eq(u8, key, "notreg")) {
                if (ctx.p.boolean()) ctx.stat.etype = .nonreg;
                return;
            }
        },
        'r' => {
            if (eq(u8, key, "read_error")) {
                if (ctx.p.boolean()) {
                    if (ctx.stat.etype == .dir)
                        ctx.rderr = true
                    else
                        ctx.stat.etype = .err;
                }
                return;
            }
        },
        'u' => {
            if (eq(u8, key, "uid")) {
                ctx.stat.ext.uid = ctx.p.uint(u32);
                ctx.stat.ext.pack.hasuid = true;
                return;
            }
        },
        else => {},
    }
    ctx.p.skip();
}

fn item(io: std.Io, ctx: *Ctx, parent: ?*sink.Dir, dev: u64) void {
    ctx.stat = .{ .dev = dev };
    ctx.namelen = 0;
    ctx.rderr = false;
    const isdir = switch (ctx.p.nextChr()) {
        '[' => blk: {
            ctx.p.obj();
            break :blk true;
        },
        '{' => false,
        else => ctx.p.die("expected object or array"),
    };
    if (parent == null and !isdir) ctx.p.die("parent item must be a directory");
    ctx.stat.etype = if (isdir) .dir else .reg;

    var keybuf: [32]u8 = undefined;
    var first = true;
    while (ctx.p.key(first, &keybuf)) |k| {
        first = false;
        itemkey(ctx, k);
    }
    if (ctx.namelen == 0) ctx.p.die("missing \"name\" field");
    const name = (&ctx.namebuf)[0..ctx.namelen];

    if (ctx.stat.etype == .dir) {
        const ndev = ctx.stat.dev;
        const dir =
            if (parent) |d|
                d.addDir(io, ctx.sink, name, &ctx.stat)
            else
                sink.createRoot(io, name, &ctx.stat);
        ctx.sink.setDir(io, dir);
        if (ctx.rderr) dir.setReadError(io, ctx.sink);
        while (ctx.p.elem(false)) item(io, ctx, dir, ndev);
        ctx.sink.setDir(io, parent);
        dir.unref(io, ctx.sink);
    } else {
        if (@intFromEnum(ctx.stat.etype) < 0)
            parent.?.addSpecial(io, ctx.sink, name, ctx.stat.etype)
        else
            parent.?.addStat(io, ctx.sink, name, &ctx.stat);
        if (isdir and ctx.p.elem(false)) ctx.p.die("unexpected contents in an excluded directory");
    }

    if ((ctx.sink.files_seen.load(.monotonic) & 65) == 0)
        main.handleEvent(io, false, false);
}

pub fn import(io: std.Io, fd: std.Io.File, head: []const u8) void {
    const sink_threads = sink.createThreads(1);
    defer sink.done(io);

    var p = Parser{ .rd = fd, .io = io };
    defer if (p.zstd) |z| z.destroy();

    if (head.len >= 4 and std.mem.eql(u8, head[0..4], "\x28\xb5\x2f\xfd")) {
        p.zstd = ZstdReader.create(io, head);
    } else {
        p.rdsize = head.len;
        @memcpy(p.buf[0..head.len], head);
    }
    p.array();
    if (p.uint(u16) != 1) p.die("incompatible major format version");
    if (!p.elem(false)) p.die("expected array element");
    _ = p.uint(u16); // minor version, ignored for now
    if (!p.elem(false)) p.die("expected array element");

    // metadata object
    p.obj();
    p.skipContent('{');

    // Items
    if (!p.elem(false)) p.die("expected array element");
    var ctx = Ctx{ .p = &p, .sink = &sink_threads[0] };
    item(io, &ctx, null, 0);

    // accept more trailing elements
    while (p.elem(false)) p.skip();
    p.eof();
}
