// SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");
const main = @import("main.zig");
const c = @import("c");

// Reference:
//   https://manned.org/glob.7
//   https://manned.org/man.b4c7391e/rsync#head17
//   https://manned.org/man.401d6ade/arch/gitignore#head4
// Patterns:
//   Single component (none of these patterns match a '/'):
//     *       -> match any character sequence
//     ?       -> match single character
//     [abc]   -> match a single character in the given list
//     [a-c]   -> match a single character in the given range
//     [!a-c]  -> match a single character not in the given range
//     # (these are currently still handled by calling libc fnmatch())
//   Anchored patterns:
//      /pattern
//      /dir/pattern
//      /dir/subdir/pattern
//      # In both rsync and gitignore, anchored patterns are relative to the
//      # directory under consideration. In ncdu they are instead anchored to
//      # the filesystem root (i.e. matched against the absolute path).
//   Non-anchored patterns:
//      somefile
//      subdir/foo
//      sub*/bar
//      # In .gitignore, non-anchored patterns with a slash are implicitly anchored,
//      # in rsync they can match anywhere in a path. We follow rsync here.
//   Dir patterns (trailing '/' matches only dirs):
//      /pattern/
//      somedir/
//      subdir/pattern/
//
// BREAKING CHANGE:
//   ncdu < 2.2 single-component matches may cross directory boundary, e.g.
//   'a*b' matches 'a/b'. This is an old bug, the fix breaks compatibility with
//   old exlude patterns.

const Pattern = struct {
    isdir: bool = undefined,
    isliteral: bool = undefined,
    pattern: [:0]const u8,
    sub: ?*const Pattern = undefined,

    fn isLiteral(str: []const u8) bool {
        for (str) |chr| switch (chr) {
            '[', '*', '?', '\\' => return false,
            else => {},
        };
        return true;
    }

    fn parse(pat_: []const u8) *const Pattern {
        var pat = std.mem.trimStart(u8, pat_, "/");
        const top = main.allocator.create(Pattern) catch unreachable;
        var tail = top;
        tail.sub = null;
        while (std.mem.indexOfScalar(u8, pat, '/')) |idx| {
            tail.pattern = main.allocator.dupeSentinel(u8, pat[0..idx], 0) catch unreachable;
            tail.isdir = true;
            tail.isliteral = isLiteral(tail.pattern);
            pat = pat[idx + 1 ..];
            if (std.mem.allEqual(u8, pat, '/')) return top;

            const next = main.allocator.create(Pattern) catch unreachable;
            tail.sub = next;
            tail = next;
            tail.sub = null;
        }
        tail.pattern = main.allocator.dupeSentinel(u8, pat, 0) catch unreachable;
        tail.isdir = false;
        tail.isliteral = isLiteral(tail.pattern);
        return top;
    }
};

test "parse" {
    const t1 = Pattern.parse("");
    try std.testing.expectEqualStrings(t1.pattern, "");
    try std.testing.expectEqual(t1.isdir, false);
    try std.testing.expectEqual(t1.isliteral, true);
    try std.testing.expectEqual(t1.sub, null);

    const t2 = Pattern.parse("//a//");
    try std.testing.expectEqualStrings(t2.pattern, "a");
    try std.testing.expectEqual(t2.isdir, true);
    try std.testing.expectEqual(t2.isliteral, true);
    try std.testing.expectEqual(t2.sub, null);

    const t3 = Pattern.parse("foo*/bar.zig");
    try std.testing.expectEqualStrings(t3.pattern, "foo*");
    try std.testing.expectEqual(t3.isdir, true);
    try std.testing.expectEqual(t3.isliteral, false);
    try std.testing.expectEqualStrings(t3.sub.?.pattern, "bar.zig");
    try std.testing.expectEqual(t3.sub.?.isdir, false);
    try std.testing.expectEqual(t3.sub.?.isliteral, true);
    try std.testing.expectEqual(t3.sub.?.sub, null);

    const t4 = Pattern.parse("/?/sub/dir/");
    try std.testing.expectEqualStrings(t4.pattern, "?");
    try std.testing.expectEqual(t4.isdir, true);
    try std.testing.expectEqual(t4.isliteral, false);
    try std.testing.expectEqualStrings(t4.sub.?.pattern, "sub");
    try std.testing.expectEqual(t4.sub.?.isdir, true);
    try std.testing.expectEqual(t4.sub.?.isliteral, true);
    try std.testing.expectEqualStrings(t4.sub.?.sub.?.pattern, "dir");
    try std.testing.expectEqual(t4.sub.?.sub.?.isdir, true);
    try std.testing.expectEqual(t4.sub.?.sub.?.isliteral, true);
    try std.testing.expectEqual(t4.sub.?.sub.?.sub, null);
}

// List of patterns to be matched at one particular level.
// There are 2 different types of lists: those where all patterns have a
// sub-pointer (where the pattern only matches directories at this level, and
// the match result is only used to construct the PatternList of the
// subdirectory) and patterns without a sub-pointer (where the match result
// determines whether the file/dir at this level should be included or not).
fn PatternList(comptime withsub: bool) type {
    return struct {
        literals: std.HashMapUnmanaged(*const Pattern, Val, Ctx, 80) = .{},
        wild: std.ArrayListUnmanaged(*const Pattern) = .empty,

        // Not a fan of the map-of-arrays approach in the 'withsub' case, it
        // has a lot of extra allocations. Linking the Patterns together in a
        // list would be nicer, but that involves mutable Patterns, which in
        // turn prevents multithreaded scanning. An alternative would be a
        // sorted array + binary search, but that slows down lookups. Perhaps a
        // custom hashmap with support for duplicate keys?
        const Val = if (withsub) std.ArrayListUnmanaged(*const Pattern) else void;

        const Ctx = struct {
            pub fn hash(_: Ctx, p: *const Pattern) u64 {
                return std.hash.Wyhash.hash(0, p.pattern);
            }
            pub fn eql(_: Ctx, a: *const Pattern, b: *const Pattern) bool {
                return std.mem.eql(u8, a.pattern, b.pattern);
            }
        };

        const Self = @This();

        fn append(self: *Self, pat: *const Pattern) void {
            std.debug.assert((pat.sub != null) == withsub);
            if (pat.isliteral) {
                const e = self.literals.getOrPut(main.allocator, pat) catch unreachable;
                if (!e.found_existing) {
                    e.key_ptr.* = pat;
                    e.value_ptr.* = if (withsub) .empty else {};
                }
                if (!withsub and !pat.isdir and e.key_ptr.*.isdir) e.key_ptr.* = pat;
                if (withsub)
                    if (pat.sub) |s| e.value_ptr.*.append(main.allocator, s) catch unreachable;
            } else self.wild.append(main.allocator, pat) catch unreachable;
        }

        fn match(self: *const Self, name: [:0]const u8) ?bool {
            var ret: ?bool = null;
            if (self.literals.getKey(&.{ .pattern = name })) |p| ret = p.isdir;
            for (self.wild.items) |p| {
                if (ret == false) return ret;
                if (c.fnmatch(p.pattern.ptr, name.ptr, 0) == 0) ret = p.isdir;
            }
            return ret;
        }

        fn enter(self: *const Self, out: *Patterns, name: [:0]const u8) void {
            if (self.literals.get(&.{ .pattern = name })) |lst| for (lst.items) |sub| out.append(sub);
            for (self.wild.items) |p| if (c.fnmatch(p.pattern.ptr, name.ptr, 0) == 0) out.append(p.sub.?);
        }

        fn deinit(self: *Self) void {
            if (withsub) {
                var it = self.literals.valueIterator();
                while (it.next()) |e| e.deinit(main.allocator);
            }
            self.literals.deinit(main.allocator);
            self.wild.deinit(main.allocator);
            self.* = undefined;
        }
    };
}

// List of all patterns that should be matched at one level.
pub const Patterns = struct {
    nonsub: PatternList(false) = .{},
    sub: PatternList(true) = .{},
    isroot: bool = false,

    fn append(self: *Patterns, pat: *const Pattern) void {
        if (pat.sub == null)
            self.nonsub.append(pat)
        else
            self.sub.append(pat);
    }

    // Matches patterns in this level plus unanchored patterns.
    // Returns null if nothing matches, otherwise whether the given item should
    // only be exluced if it's a directory.
    // (Should not be called on root_unanchored)
    pub fn match(self: *const Patterns, name: [:0]const u8) ?bool {
        const a = self.nonsub.match(name);
        if (a == false) return false;
        const b = root_unanchored.nonsub.match(name);
        if (b == false) return false;
        return a orelse b;
    }

    // Construct the list of patterns for a subdirectory.
    pub fn enter(self: *const Patterns, name: [:0]const u8) Patterns {
        var ret = Patterns{};
        self.sub.enter(&ret, name);
        root_unanchored.sub.enter(&ret, name);
        return ret;
    }

    pub fn deinit(self: *Patterns) void {
        // getPatterns() result should be deinit()ed, except when it returns the root,
        // let's simplify that and simply don't deinit root.
        if (self.isroot) return;
        self.nonsub.deinit();
        self.sub.deinit();
        self.* = undefined;
    }
};

// Unanchored patterns that should be checked at every level
var root_unanchored: Patterns = .{};

// Patterns anchored at the root
var root: Patterns = .{ .isroot = true };

pub fn addPattern(pattern: []const u8) void {
    if (pattern.len == 0) return;
    const p = Pattern.parse(pattern);
    if (pattern[0] == '/')
        root.append(p)
    else
        root_unanchored.append(p);
}

// Get the patterns for the given (absolute) path, assuming the given path
// itself hasn't been excluded. This function is slow, directory walking code
// should use Patterns.enter() instead.
pub fn getPatterns(path_: []const u8) Patterns {
    var path = std.mem.trim(u8, path_, "/");
    if (path.len == 0) return root;
    var pat = root;
    defer pat.deinit();
    while (std.mem.indexOfScalar(u8, path, '/')) |idx| {
        const name = main.allocator.dupeSentinel(u8, path[0..idx], 0) catch unreachable;
        defer main.allocator.free(name);
        path = path[idx + 1 ..];

        const sub = pat.enter(name);
        pat.deinit();
        pat = sub;
    }

    const name = main.allocator.dupeSentinel(u8, path, 0) catch unreachable;
    defer main.allocator.free(name);
    return pat.enter(name);
}

fn testfoo(p: *const Patterns) !void {
    try std.testing.expectEqual(p.match("root"), null);
    try std.testing.expectEqual(p.match("bar"), false);
    try std.testing.expectEqual(p.match("qoo"), false);
    try std.testing.expectEqual(p.match("xyz"), false);
    try std.testing.expectEqual(p.match("okay"), null);
    try std.testing.expectEqual(p.match("somefile"), false);
    var s = p.enter("okay");
    try std.testing.expectEqual(s.match("bar"), null);
    try std.testing.expectEqual(s.match("xyz"), null);
    try std.testing.expectEqual(s.match("notokay"), false);
    s.deinit();
}

test "Matching" {
    addPattern("/foo/bar");
    addPattern("/foo/qoo/");
    addPattern("/foo/qoo");
    addPattern("/foo/qoo/");
    addPattern("/f??/xyz");
    addPattern("/f??/xyz/");
    addPattern("/*o/somefile");
    addPattern("/a??/okay");
    addPattern("/roo?");
    addPattern("/root/");
    addPattern("excluded");
    addPattern("somefile/");
    addPattern("o*y/not[o]kay");

    var a0 = getPatterns("/");
    try std.testing.expectEqual(a0.match("a"), null);
    try std.testing.expectEqual(a0.match("excluded"), false);
    try std.testing.expectEqual(a0.match("somefile"), true);
    try std.testing.expectEqual(a0.match("root"), false);
    var a1 = a0.enter("foo");
    a0.deinit();
    try testfoo(&a1);
    a1.deinit();

    var b0 = getPatterns("/somedir/somewhere");
    try std.testing.expectEqual(b0.match("a"), null);
    try std.testing.expectEqual(b0.match("excluded"), false);
    try std.testing.expectEqual(b0.match("root"), null);
    try std.testing.expectEqual(b0.match("okay"), null);
    var b1 = b0.enter("okay");
    b0.deinit();
    try std.testing.expectEqual(b1.match("excluded"), false);
    try std.testing.expectEqual(b1.match("okay"), null);
    try std.testing.expectEqual(b1.match("notokay"), false);
    b1.deinit();

    var c0 = getPatterns("/foo/");
    try testfoo(&c0);
    c0.deinit();
}
