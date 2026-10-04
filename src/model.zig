// SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");
const main = @import("main.zig");
const ui = @import("ui.zig");
const util = @import("util.zig");

// Numbers are used in the binfmt export, so must be stable.
pub const EType = enum(i3) {
    dir = 0,
    reg = 1,
    nonreg = 2,
    link = 3,
    err = -1,
    pattern = -2,
    otherfs = -3,
    kernfs = -4,

    pub fn base(t: EType) EType {
        return switch (t) {
            .dir, .link => t,
            else => .reg,
        };
    }

    // Whether this entry should be displayed as a "directory".
    // Some dirs are actually represented in this data model as a File for efficiency.
    pub fn isDirectory(t: EType) bool {
        return switch (t) {
            .dir, .otherfs, .kernfs => true,
            else => false,
        };
    }
};

// Type for the Entry.Packed.blocks field. Smaller than a u64 to make room for flags.
pub const Blocks = u60;

// Entries read from bin_reader may refer to other entries by itemref rather than pointer.
// This is a hack that allows browser.zig to use the same types for in-memory
// and bin_reader-backed directory trees. Most code can only deal with
// in-memory trees and accesses the .ptr field directly.
pub const Ref = extern union {
    ptr: ?*Entry align(1),
    ref: u64 align(1),

    pub fn isNull(r: Ref) bool {
        if (main.config.binreader)
            return r.ref == std.math.maxInt(u64)
        else
            return r.ptr == null;
    }
};

// Memory layout:
//      (Ext +) Dir + name
//  or: (Ext +) Link + name
//  or: (Ext +) File + name
//
// Entry is always the first part of Dir, Link and File, so a pointer cast to
// *Entry is always safe and an *Entry can be casted to the full type. The Ext
// struct, if present, is placed before the *Entry pointer.
// These are all packed structs and hence do not have any alignment, which is
// great for saving memory but perhaps not very great for code size or
// performance.
pub const Entry = extern struct {
    pack: Packed align(1),
    size: u64 align(1) = 0,
    next: Ref = .{ .ptr = null },

    pub const Packed = packed struct(u64) {
        etype: EType,
        isext: bool,
        blocks: Blocks = 0, // 512-byte blocks
    };

    const Self = @This();

    pub fn dir(self: *Self) ?*Dir {
        return if (self.pack.etype == .dir) @ptrCast(self) else null;
    }

    pub fn link(self: *Self) ?*Link {
        return if (self.pack.etype == .link) @ptrCast(self) else null;
    }

    pub fn file(self: *Self) ?*File {
        return if (self.pack.etype != .dir and self.pack.etype != .link) @ptrCast(self) else null;
    }

    pub fn name(self: *const Self) [:0]const u8 {
        const self_name = switch (self.pack.etype) {
            .dir => &@as(*const Dir, @ptrCast(self)).name,
            .link => &@as(*const Link, @ptrCast(self)).name,
            else => &@as(*const File, @ptrCast(self)).name,
        };
        const name_ptr: [*:0]const u8 = @ptrCast(self_name);
        return std.mem.sliceTo(name_ptr, 0);
    }

    pub fn nameHash(self: *const Self) u64 {
        return std.hash.Wyhash.hash(0, self.name());
    }

    pub fn ext(self: *Self) ?*Ext {
        if (!self.pack.isext) return null;
        return @ptrCast(@as([*]Ext, @ptrCast(self)) - 1);
    }

    fn alloc(comptime T: type, allocator: std.mem.Allocator, io: std.Io, etype: EType, isext: bool, ename: []const u8) *Entry {
        const size = (if (isext) @as(usize, @sizeOf(Ext)) else 0) + @sizeOf(T) + ename.len + 1;
        var ptr = blk: while (true) {
            const alignment = if (@typeInfo(@TypeOf(std.mem.Allocator.allocWithOptions)).@"fn".params[3].type == ?u29) 1 else std.mem.Alignment.@"1";
            if (allocator.allocWithOptions(u8, size, alignment, null)) |p|
                break :blk p
            else |_| {}
            ui.oom(io);
        };
        if (isext) {
            @as(*Ext, @ptrCast(ptr)).* = .{};
            ptr = ptr[@sizeOf(Ext)..];
        }
        const e: *T = @ptrCast(ptr);
        e.* = .{ .entry = .{ .pack = .{ .etype = etype, .isext = isext } } };
        const n = @as([*]u8, @ptrCast(&e.name))[0 .. ename.len + 1];
        @memcpy(n[0..ename.len], ename);
        n[ename.len] = 0;
        return &e.entry;
    }

    pub fn create(allocator: std.mem.Allocator, io: std.Io, etype: EType, isext: bool, ename: []const u8) *Entry {
        return switch (etype) {
            .dir => alloc(Dir, allocator, io, etype, isext, ename),
            .link => alloc(Link, allocator, io, etype, isext, ename),
            else => alloc(File, allocator, io, etype, isext, ename),
        };
    }

    pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
        const ptr: [*]u8 = if (self.ext()) |e| @ptrCast(e) else @ptrCast(self);
        const esize: usize = switch (self.pack.etype) {
            .dir => @sizeOf(Dir),
            .link => @sizeOf(Link),
            else => @sizeOf(File),
        };
        const size = (if (self.pack.isext) @as(usize, @sizeOf(Ext)) else 0) + esize + self.name().len + 1;
        allocator.free(ptr[0..size]);
    }

    fn hasErr(self: *Self) bool {
        return if (self.dir()) |d|
            d.pack.err or d.pack.suberr
        else
            self.pack.etype == .err;
    }

    fn removeLinks(self: *Entry) void {
        if (self.dir()) |d| {
            var it = d.sub.ptr;
            while (it) |e| : (it = e.next.ptr) e.removeLinks();
        }
        if (self.link()) |l| l.removeLink();
    }

    fn zeroStatsRec(self: *Entry) void {
        self.pack.blocks = 0;
        self.size = 0;
        if (self.dir()) |d| {
            d.items = 0;
            d.pack.err = false;
            d.pack.suberr = false;
            var it = d.sub.ptr;
            while (it) |e| : (it = e.next.ptr) e.zeroStatsRec();
        }
    }

    // Recursively set stats and those of sub-items to zero and removes counts
    // from parent directories; as if this item does not exist in the tree.
    // XXX: Does not update the 'suberr' flag of parent directories, make sure
    // to call updateSubErr() afterwards.
    pub fn zeroStats(self: *Entry, parent: ?*Dir) void {
        self.removeLinks();

        var it = parent;
        while (it) |p| : (it = p.parent) {
            p.entry.pack.blocks -|= self.pack.blocks;
            p.entry.size -|= self.size;
            p.items -|= 1 + (if (self.dir()) |d| d.items else 0);
        }
        self.zeroStatsRec();
    }
};

const DevId = u30; // Can be reduced to make room for more flags in Dir.Packed.

pub const Dir = extern struct {
    entry: Entry,

    sub: Ref = .{ .ptr = null },
    parent: ?*Dir align(1) = null,

    // entry.{blocks,size}: Total size of all unique files + dirs. Non-shared hardlinks are counted only once.
    //   (i.e. the space you'll need if you created a filesystem with only this dir)
    // shared_*: Unique hardlinks that still have references outside of this directory.
    //   (i.e. the space you won't reclaim by deleting this dir)
    // (space reclaimed by deleting a dir =~ entry. - shared_)
    shared_blocks: u64 align(1) = 0,
    shared_size: u64 align(1) = 0,
    items: u32 align(1) = 0,

    pack: Packed align(1) = .{},

    // Only used to find the @offsetOff, the name is written at this point as a 0-terminated string.
    // (Old C habits die hard)
    name: [0]u8 = undefined,

    pub const Packed = packed struct(u32) {
        // Indexes into the global 'devices.list' array
        dev: DevId = 0,
        err: bool = false,
        suberr: bool = false,
    };

    pub fn fmtPath(self: *const @This(), alloc: std.mem.Allocator, withRoot: bool, out: *std.ArrayListUnmanaged(u8)) void {
        if (!withRoot and self.parent == null) return;
        var components: std.ArrayListUnmanaged([:0]const u8) = .empty;
        defer components.deinit(main.allocator);
        var it: ?*const @This() = self;
        while (it) |e| : (it = e.parent)
            if (withRoot or e.parent != null)
                components.append(main.allocator, e.entry.name()) catch unreachable;

        var i: usize = components.items.len - 1;
        while (true) {
            if (i != components.items.len - 1 and !(out.items.len != 0 and out.items[out.items.len - 1] == '/'))
                out.append(main.allocator, '/') catch unreachable;
            out.appendSlice(alloc, components.items[i]) catch unreachable;
            if (i == 0) break;
            i -= 1;
        }
    }

    // Only updates the suberr of this Dir, assumes child dirs have already
    // been updated and does not propagate to parents.
    pub fn updateSubErr(self: *@This()) void {
        self.pack.suberr = false;
        var sub = self.sub.ptr;
        while (sub) |e| : (sub = e.next.ptr) {
            if (e.hasErr()) {
                self.pack.suberr = true;
                break;
            }
        }
    }
};

// File that's been hardlinked (i.e. nlink > 1)
pub const Link = extern struct {
    entry: Entry,
    parent: *Dir align(1) = undefined,
    next: *Link align(1) = undefined, // circular linked list of all *Link nodes with the same dev,ino.
    prev: *Link align(1) = undefined,
    // dev is inherited from the parent Dir
    ino: u64 align(1) = undefined,
    pack: Pack align(1) = .{},
    name: [0]u8 = undefined,

    const Pack = packed struct(u32) {
        // Whether this Inode is counted towards the parent directories.
        // Is kept synchronized between all Link nodes with the same dev/ino.
        counted: bool = false,
        // Number of links for this inode. When set to '0', we don't know the
        // actual nlink count; which happens for old JSON dumps.
        nlink: u31 = undefined,
    };

    // Return value should be freed with main.allocator.
    pub fn path(self: *const @This(), withRoot: bool) [:0]const u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        self.parent.fmtPath(main.allocator, withRoot, &out);
        out.append(main.allocator, '/') catch unreachable;
        out.appendSlice(main.allocator, self.entry.name()) catch unreachable;
        return out.toOwnedSliceSentinel(main.allocator, 0) catch unreachable;
    }

    // Add this link to the inodes map and mark it as 'uncounted'.
    pub fn addLink(l: *@This()) void {
        const d = inodes.map.getOrPut(l) catch unreachable;
        if (!d.found_existing) {
            l.next = l;
            l.prev = l;
        } else {
            inodes.setStats(d.key_ptr.*, false);
            l.next = d.key_ptr.*;
            l.prev = d.key_ptr.*.prev;
            l.next.prev = l;
            l.prev.next = l;
        }
        inodes.addUncounted(l);
    }

    // Remove this link from the inodes map and remove its stats from parent directories.
    fn removeLink(l: *@This()) void {
        inodes.setStats(l, false);
        const entry = inodes.map.getEntry(l) orelse return;
        if (l.next == l) {
            _ = inodes.map.remove(l);
            _ = inodes.uncounted.remove(l);
        } else {
            // XXX: If this link is actually removed from the filesystem, then
            // the nlink count of the existing links should be updated to
            // reflect that. But we can't do that here, because this function
            // is also called before doing a filesystem refresh - in which case
            // the nlink count likely won't change. Best we can hope for is
            // that a refresh will encounter another link to the same inode and
            // trigger an nlink change.
            if (entry.key_ptr.* == l)
                entry.key_ptr.* = l.next;
            inodes.addUncounted(l.next);
            l.next.prev = l.prev;
            l.prev.next = l.next;
        }
    }
};

// Anything that's not an (indexed) directory or hardlink. Excluded directories are also "Files".
pub const File = extern struct {
    entry: Entry,
    name: [0]u8 = undefined,
};

pub const Ext = extern struct {
    pack: Pack = .{},
    mtime: u64 align(1) = 0,
    uid: u32 align(1) = 0,
    gid: u32 align(1) = 0,
    mode: u16 align(1) = 0,

    pub const Pack = packed struct(u8) {
        hasmtime: bool = false,
        hasuid: bool = false,
        hasgid: bool = false,
        hasmode: bool = false,
        _pad: u4 = 0,
    };

    pub fn isEmpty(e: *const Ext) bool {
        return !e.pack.hasmtime and !e.pack.hasuid and !e.pack.hasgid and !e.pack.hasmode;
    }
};

// List of st_dev entries. Those are typically 64bits, but that's quite a waste
// of space when a typical scan won't cover many unique devices.
pub const devices = struct {
    var lock: std.Io.Mutex = .init;
    // id -> dev
    pub var list: std.ArrayListUnmanaged(u64) = .empty;
    // dev -> id
    var lookup = std.AutoHashMap(u64, DevId).init(main.allocator);

    pub fn getId(io: std.Io, dev: u64) DevId {
        lock.lock(io) catch {};
        defer lock.unlock(io);
        const d = lookup.getOrPut(dev) catch unreachable;
        if (!d.found_existing) {
            if (list.items.len >= std.math.maxInt(DevId)) ui.die("Maximum number of device identifiers exceeded.\n", .{});
            d.value_ptr.* = @as(DevId, @intCast(list.items.len));
            list.append(main.allocator, dev) catch unreachable;
        }
        return d.value_ptr.*;
    }
};

// Lookup table for ino -> *Link entries, used for hard link counting.
pub const inodes = struct {
    // Keys are hashed by their (dev,ino), the *Link points to an arbitrary
    // node in the list. Link entries with the same dev/ino are part of a
    // circular linked list, so you can iterate through all of them with this
    // single pointer.
    const Map = std.HashMap(*Link, void, HashContext, 80);
    pub var map = Map.init(main.allocator);

    // List of nodes in 'map' with !counted, to speed up addAllStats().
    // If this list grows large relative to the number of nodes in 'map', then
    // this list is cleared and uncounted_full is set instead, so that
    // addAllStats() will do a full iteration over 'map'.
    var uncounted = std.HashMap(*Link, void, HashContext, 80).init(main.allocator);
    var uncounted_full = true; // start with true for the initial scan

    pub var lock: std.Io.Mutex = .init;

    const HashContext = struct {
        pub fn hash(_: @This(), l: *Link) u64 {
            var h = std.hash.Wyhash.init(0);
            h.update(std.mem.asBytes(&@as(u32, l.parent.pack.dev)));
            h.update(std.mem.asBytes(&l.ino));
            return h.final();
        }

        pub fn eql(_: @This(), a: *Link, b: *Link) bool {
            return a.ino == b.ino and a.parent.pack.dev == b.parent.pack.dev;
        }
    };

    fn addUncounted(l: *Link) void {
        if (uncounted_full) return;
        if (uncounted.count() > map.count() / 8) {
            uncounted.clearAndFree();
            uncounted_full = true;
        } else (uncounted.getOrPut(l) catch unreachable).key_ptr.* = l;
    }

    // Add/remove this inode from the parent Dir sizes. When removing stats,
    // the list of *Links and their sizes and counts must be in the exact same
    // state as when the stats were added. Hence, any modification to the Link
    // state should be preceded by a setStats(.., false).
    fn setStats(l: *Link, add: bool) void {
        if (l.pack.counted == add) return;

        var nlink: u31 = 0;
        var inconsistent = false;
        var dirs = std.AutoHashMap(*Dir, u32).init(main.allocator);
        defer dirs.deinit();
        var it = l;
        while (true) {
            it.pack.counted = add;
            nlink += 1;
            if (it.pack.nlink != l.pack.nlink) inconsistent = true;
            var parent: ?*Dir = it.parent;
            while (parent) |p| : (parent = p.parent) {
                const de = dirs.getOrPut(p) catch unreachable;
                if (de.found_existing)
                    de.value_ptr.* += 1
                else
                    de.value_ptr.* = 1;
            }
            it = it.next;
            if (it == l)
                break;
        }

        // There's not many sensible things we can do when we encounter
        // inconsistent nlink counts. Current approach is to use the number of
        // times we've seen this link in our tree as fallback for when the
        // nlink counts aren't matching. May want to add a warning of some
        // sorts to the UI at some point.
        if (!inconsistent and l.pack.nlink >= nlink) nlink = l.pack.nlink;

        // XXX: We're also not testing for inconsistent entry sizes, instead
        // using the given 'l' size for all Links. Might warrant a warning as
        // well.

        var dir_iter = dirs.iterator();
        if (add) {
            while (dir_iter.next()) |de| {
                de.key_ptr.*.entry.pack.blocks +|= l.entry.pack.blocks;
                de.key_ptr.*.entry.size +|= l.entry.size;
                if (de.value_ptr.* < nlink) {
                    de.key_ptr.*.shared_blocks +|= l.entry.pack.blocks;
                    de.key_ptr.*.shared_size +|= l.entry.size;
                }
            }
        } else {
            while (dir_iter.next()) |de| {
                de.key_ptr.*.entry.pack.blocks -|= l.entry.pack.blocks;
                de.key_ptr.*.entry.size -|= l.entry.size;
                if (de.value_ptr.* < nlink) {
                    de.key_ptr.*.shared_blocks -|= l.entry.pack.blocks;
                    de.key_ptr.*.shared_size -|= l.entry.size;
                }
            }
        }
    }

    // counters to track progress for addAllStats()
    pub var add_total: usize = 0;
    pub var add_done: usize = 0;

    pub fn addAllStats(io: std.Io) void {
        if (uncounted_full) {
            add_total = map.count();
            add_done = 0;
            var it = map.keyIterator();
            while (it.next()) |e| {
                setStats(e.*, true);
                add_done += 1;
                if ((add_done & 65) == 0) main.handleEvent(io, false, false);
            }
        } else {
            add_total = uncounted.count();
            add_done = 0;
            var it = uncounted.keyIterator();
            while (it.next()) |u| {
                if (map.getKey(u.*)) |e| setStats(e, true);
                add_done += 1;
                if ((add_done & 65) == 0) main.handleEvent(io, false, false);
            }
        }
        uncounted_full = false;
        if (uncounted.count() > 0)
            uncounted.clearAndFree();
    }
};

pub var root: *Dir = undefined;

test "entry" {
    var e = Entry.create(std.testing.allocator, std.testing.io, .reg, false, "hello");
    defer e.destroy(std.testing.allocator);
    try std.testing.expectEqual(e.pack.etype, .reg);
    try std.testing.expect(!e.pack.isext);
    try std.testing.expectEqualStrings(e.name(), "hello");
}
