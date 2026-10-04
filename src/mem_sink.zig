// SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");
const main = @import("main.zig");
const model = @import("model.zig");
const sink = @import("sink.zig");

pub const global = struct {
    pub var root: ?*model.Dir = null;
    pub var stats: bool = true; // calculate aggregate directory stats
};

pub const Thread = struct {
    // Arena allocator for model.Entry structs, these are never freed.
    arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator),
};

pub fn statToEntry(io: std.Io, stat: *const sink.Stat, e: *model.Entry, parent: *model.Dir) void {
    e.pack.blocks = stat.blocks;
    e.size = stat.size;
    if (e.dir()) |d| {
        d.parent = parent;
        d.pack.dev = model.devices.getId(io, stat.dev);
    }
    if (e.link()) |l| {
        l.parent = parent;
        l.ino = stat.ino;
        l.pack.nlink = stat.nlink;
        model.inodes.lock.lock(io) catch {};
        defer model.inodes.lock.unlock(io);
        l.addLink();
    }
    if (e.ext()) |ext| ext.* = stat.ext;
}

pub const Dir = struct {
    dir: *model.Dir,
    entries: Map,

    own_blocks: model.Blocks,
    own_bytes: u64,

    // Additional counts collected from subdirectories. Subdirs may run final()
    // from separate threads so these need to be protected.
    blocks: model.Blocks = 0,
    bytes: u64 = 0,
    items: u32 = 0,
    mtime: u64 = 0,
    suberr: bool = false,
    lock: std.Io.Mutex = .init,

    const Map = std.HashMap(*model.Entry, void, HashContext, 80);

    const HashContext = struct {
        pub fn hash(_: @This(), e: *model.Entry) u64 {
            return std.hash.Wyhash.hash(0, e.name());
        }
        pub fn eql(_: @This(), a: *model.Entry, b: *model.Entry) bool {
            return a == b or std.mem.eql(u8, a.name(), b.name());
        }
    };

    const HashContextAdapted = struct {
        pub fn hash(_: @This(), v: []const u8) u64 {
            return std.hash.Wyhash.hash(0, v);
        }
        pub fn eql(_: @This(), a: []const u8, b: *model.Entry) bool {
            return std.mem.eql(u8, a, b.name());
        }
    };

    fn init(dir: *model.Dir) Dir {
        var self = Dir{
            .dir = dir,
            .entries = Map.initContext(main.allocator, HashContext{}),
            .own_blocks = dir.entry.pack.blocks,
            .own_bytes = dir.entry.size,
        };

        var count: Map.Size = 0;
        var it = dir.sub.ptr;
        while (it) |e| : (it = e.next.ptr) count += 1;
        self.entries.ensureUnusedCapacity(count) catch unreachable;

        it = dir.sub.ptr;
        while (it) |e| : (it = e.next.ptr)
            self.entries.putAssumeCapacity(e, {});
        return self;
    }

    fn getEntry(self: *Dir, io: std.Io, t: *Thread, etype: model.EType, isext: bool, name: []const u8) *model.Entry {
        if (self.entries.getKeyAdapted(name, HashContextAdapted{})) |e| {
            // XXX: In-place conversion may be possible in some cases.
            if (e.pack.etype.base() == etype.base() and (!isext or e.pack.isext)) {
                e.pack.etype = etype;
                e.pack.isext = isext;
                _ = self.entries.removeAdapted(name, HashContextAdapted{});
                return e;
            }
        }
        const e = model.Entry.create(t.arena.allocator(), io, etype, isext, name);
        e.next.ptr = self.dir.sub.ptr;
        self.dir.sub.ptr = e;
        return e;
    }

    pub fn addSpecial(self: *Dir, io: std.Io, t: *Thread, name: []const u8, st: model.EType) void {
        self.dir.items += 1;
        if (st == .err) self.dir.pack.suberr = true;
        _ = self.getEntry(io, t, st, false, name);
    }

    pub fn addStat(self: *Dir, io: std.Io, t: *Thread, name: []const u8, stat: *const sink.Stat) *model.Entry {
        if (global.stats) {
            self.dir.items +|= 1;
            if (stat.etype != .link) {
                self.dir.entry.pack.blocks +|= stat.blocks;
                self.dir.entry.size +|= stat.size;
            }
            if (self.dir.entry.ext()) |e| {
                if (stat.ext.mtime > e.mtime) e.mtime = stat.ext.mtime;
            }
        }

        const e = self.getEntry(io, t, stat.etype, main.config.extended and !stat.ext.isEmpty(), name);
        statToEntry(io, stat, e, self.dir);
        return e;
    }

    pub fn addDir(self: *Dir, io: std.Io, t: *Thread, name: []const u8, stat: *const sink.Stat) Dir {
        return init(self.addStat(io, t, name, stat).dir().?);
    }

    pub fn setReadError(self: *Dir) void {
        self.dir.pack.err = true;
    }

    pub fn final(self: *Dir, io: std.Io, parent: ?*Dir) void {
        // Remove entries we've not seen
        if (self.entries.count() > 0) {
            var it = &self.dir.sub.ptr;
            while (it.*) |e| {
                if (self.entries.getKey(e) == e)
                    it.* = e.next.ptr
                else
                    it = &e.next.ptr;
            }
        }
        self.entries.deinit();

        if (!global.stats) return;

        // Grab counts collected from subdirectories
        self.dir.entry.pack.blocks +|= self.blocks;
        self.dir.entry.size +|= self.bytes;
        self.dir.items +|= self.items;
        if (self.suberr) self.dir.pack.suberr = true;
        if (self.dir.entry.ext()) |e| {
            if (self.mtime > e.mtime) e.mtime = self.mtime;
        }

        // Add own counts to parent
        if (parent) |p| {
            p.lock.lock(io) catch {};
            defer p.lock.unlock(io);
            p.blocks +|= self.dir.entry.pack.blocks - self.own_blocks;
            p.bytes +|= self.dir.entry.size - self.own_bytes;
            p.items +|= self.dir.items;
            if (self.dir.entry.ext()) |e| {
                if (e.mtime > p.mtime) p.mtime = e.mtime;
            }
            if (self.suberr or self.dir.pack.suberr or self.dir.pack.err) p.suberr = true;
        }
    }
};

pub fn createRoot(io: std.Io, path: []const u8, stat: *const sink.Stat) Dir {
    const p = global.root orelse blk: {
        model.root = model.Entry.create(main.allocator, io, .dir, main.config.extended and !stat.ext.isEmpty(), path).dir().?;
        break :blk model.root;
    };
    sink.global.state = .zeroing;
    if (p.items > 10_000) main.handleEvent(io, false, true);
    // Do the zeroStats() here, after the "root" entry has been
    // stat'ed and opened, so that a fatal error on refresh won't
    // zero-out the requested directory.
    p.entry.zeroStats(p.parent);
    sink.global.state = .running;
    p.entry.pack.blocks = stat.blocks;
    p.entry.size = stat.size;
    p.pack.dev = model.devices.getId(io, stat.dev);
    if (p.entry.ext()) |e| e.* = stat.ext;
    return Dir.init(p);
}

pub fn done(io: std.Io) void {
    if (!global.stats) return;

    sink.global.state = .hlcnt;
    main.handleEvent(io, false, true);
    const dir = global.root orelse model.root;
    var it: ?*model.Dir = dir;
    while (it) |p| : (it = p.parent) {
        p.updateSubErr();
        if (p != dir) {
            p.entry.pack.blocks +|= dir.entry.pack.blocks;
            p.entry.size +|= dir.entry.size;
            p.items +|= dir.items + 1;
        }
    }
    model.inodes.addAllStats(io);
}
