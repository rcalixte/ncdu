// SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");
const c = @import("c");

// Cast any integer type to the target type, clamping the value to the supported maximum if necessary.
pub fn castClamp(comptime T: type, x: anytype) T {
    // (adapted from std.math.cast)
    if (std.math.maxInt(@TypeOf(x)) > std.math.maxInt(T) and x > std.math.maxInt(T)) {
        return std.math.maxInt(T);
    } else if (std.math.minInt(@TypeOf(x)) < std.math.minInt(T) and x < std.math.minInt(T)) {
        return std.math.minInt(T);
    } else {
        return @intCast(x);
    }
}

// Cast any integer type to the target type, truncating if necessary.
pub fn castTruncate(comptime T: type, x: anytype) T {
    const Ti = @typeInfo(T).int;
    const Xi = @typeInfo(@TypeOf(x)).int;
    const nx: @Int(Ti.signedness, Xi.bits) = @bitCast(x);
    return if (Xi.bits > Ti.bits) @truncate(nx) else nx;
}

// Multiplies by 512, saturating.
pub fn blocksToSize(b: u64) u64 {
    return b *| 512;
}

// Ensure the given arraylist buffer gets zero-terminated and returns a slice
// into the buffer. The returned buffer is invalidated whenever the arraylist
// is freed or written to.
pub fn arrayListBufZ(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator) [:0]const u8 {
    buf.append(alloc, 0) catch unreachable;
    defer buf.items.len -= 1;
    return buf.items[0 .. buf.items.len - 1 :0];
}

// Format an integer as right-aligned '###.#'.
// Pretty much equivalent to:
//   std.fmt.bufPrintZ(.., "{d:>5.1}", @floatFromInt(n)/10.0);
// Except this function doesn't pull in large float formatting tables.
pub fn fmt5dec(n: u14) [5:0]u8 {
    std.debug.assert(n <= 9999);
    var buf: [5:0]u8 = "  0.0".*;
    var v = n;
    buf[4] += @intCast(v % 10);
    v /= 10;
    buf[2] += @intCast(v % 10);
    v /= 10;
    if (v == 0) return buf;
    buf[1] = '0' + @as(u8, @intCast(v % 10));
    v /= 10;
    if (v == 0) return buf;
    buf[0] = '0' + @as(u8, @intCast(v));
    return buf;
}

test "fmt5dec" {
    const eq = std.testing.expectEqualStrings;
    try eq("  0.0", &fmt5dec(0));
    try eq("  0.5", &fmt5dec(5));
    try eq("  9.5", &fmt5dec(95));
    try eq(" 12.5", &fmt5dec(125));
    try eq("123.9", &fmt5dec(1239));
    try eq("999.9", &fmt5dec(9999));
}

// Straightforward Zig port of strnatcmp() from https://github.com/sourcefrog/natsort/
// (Requiring nul-terminated strings is ugly, but we've got them anyway and it does simplify the code)
pub fn strnatcmp(a: [:0]const u8, b: [:0]const u8) std.math.Order {
    var ai: usize = 0;
    var bi: usize = 0;
    const isDigit = std.ascii.isDigit;
    while (true) {
        while (std.ascii.isWhitespace(a[ai])) ai += 1;
        while (std.ascii.isWhitespace(b[bi])) bi += 1;

        if (isDigit(a[ai]) and isDigit(b[bi])) {
            if (a[ai] == '0' or b[bi] == '0') { // compare_left
                while (true) {
                    if (!isDigit(a[ai]) and !isDigit(b[bi])) break;
                    if (!isDigit(a[ai])) return .lt;
                    if (!isDigit(b[bi])) return .gt;
                    if (a[ai] < b[bi]) return .lt;
                    if (a[ai] > b[bi]) return .gt;
                    ai += 1;
                    bi += 1;
                }
            } else { // compare_right - for right-aligned numbers
                var bias = std.math.Order.eq;
                while (true) {
                    if (!isDigit(a[ai]) and !isDigit(b[bi])) {
                        if (bias != .eq or (a[ai] == 0 and b[bi] == 0))
                            return bias
                        else
                            break;
                    }
                    if (!isDigit(a[ai])) return .lt;
                    if (!isDigit(b[bi])) return .gt;
                    if (bias == .eq) {
                        if (a[ai] < b[bi]) bias = .lt;
                        if (a[ai] > b[bi]) bias = .gt;
                    }
                    ai += 1;
                    bi += 1;
                }
            }
        }
        if (a[ai] == 0 and b[bi] == 0) return .eq;
        if (a[ai] < b[bi]) return .lt;
        if (a[ai] > b[bi]) return .gt;
        ai += 1;
        bi += 1;
    }
}

test "strnatcmp" {
    // Test strings from https://github.com/sourcefrog/natsort/
    // Includes sorted-words, sorted-dates and sorted-fractions.
    const w = [_][:0]const u8{
        "1-02",
        "1-2",
        "1-20",
        "1.002.01",
        "1.002.03",
        "1.002.08",
        "1.009.02",
        "1.009.10",
        "1.009.20",
        "1.010.12",
        "1.011.02",
        "10-20",
        "1999-3-3",
        "1999-12-25",
        "2000-1-2",
        "2000-1-10",
        "2000-3-23",
        "fred",
        "jane",
        "pic01",
        "pic02",
        "pic02a",
        "pic02000",
        "pic05",
        "pic2",
        "pic3",
        "pic4",
        "pic 4 else",
        "pic 5",
        "pic 5 ",
        "pic 5 something",
        "pic 6",
        "pic   7",
        "pic100",
        "pic100a",
        "pic120",
        "pic121",
        "tom",
        "x2-g8",
        "x2-y08",
        "x2-y7",
        "x8-y8",
    };
    // Test each string against each other string, simple and thorough.
    const eq = std.testing.expectEqual;
    for (0..w.len) |i| {
        try eq(strnatcmp(w[i], w[i]), .eq);
        for (0..i) |j| try eq(strnatcmp(w[i], w[j]), .gt);
        for (i + 1..w.len) |j| try eq(strnatcmp(w[i], w[j]), .lt);
    }
}

pub fn expandUser(alloc: std.mem.Allocator, environ: std.process.Environ, path: []const u8) ![:0]u8 {
    if (path.len == 0 or path[0] != '~') return alloc.dupeSentinel(u8, path, 0);

    const len = std.mem.indexOfScalar(u8, path, '/') orelse path.len;
    const home_raw = blk: {
        const pwd = pwd: {
            if (len == 1) {
                if (environ.getPosix("HOME")) |p| break :blk p;
                break :pwd std.c.getpwuid(std.c.getuid());
            } else {
                const name = try alloc.dupeSentinel(u8, path[1..len], 0);
                defer alloc.free(name);
                break :pwd std.c.getpwnam(name);
            }
        };
        if (pwd != null)
            if (pwd.?.dir) |p|
                break :blk std.mem.span(p);
        return alloc.dupeSentinel(u8, path, 0);
    };
    const home = std.mem.trimEnd(u8, home_raw, "/");

    if (home.len == 0 and path.len == len) return alloc.dupeSentinel(u8, "/", 0);
    return try std.mem.concatWithSentinel(alloc, u8, &.{ home, path[len..] }, 0);
}

// Silly abstraction to read a file one line at a time. Only exists to help
// with supporting both Zig 0.14 and 0.15, can be removed once 0.14 support is
// dropped.
pub const LineReader = struct {
    rd: std.Io.File.Reader,

    pub fn init(io: std.Io, f: std.Io.File, buf: []u8) @This() {
        return .{ .rd = f.readerStreaming(io, buf) };
    }

    pub fn read(s: *@This()) !?[]u8 {
        // Can't use takeDelimiter() because that's not available in 0.15.1,
        // Can't use takeDelimiterExclusive() because that changed behavior in 0.15.2.
        const r = &s.rd.interface;
        const result = r.peekDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                const remaining = r.buffer[r.seek..r.end];
                if (remaining.len == 0) return null;
                r.toss(remaining.len);
                return remaining;
            },
            else => |e| return e,
        };
        r.toss(result.len);
        return result[0 .. result.len - 1];
    }
};
