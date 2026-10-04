// SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");
const builtin = @import("builtin");
const main = @import("main.zig");
const util = @import("util.zig");
const model = @import("model.zig");
const sink = @import("sink.zig");
const ui = @import("ui.zig");
const exclude = @import("exclude.zig");
const c = @import("c");

// This function only works on Linux
fn isKernfs(dir: std.Io.Dir) bool {
    var buf: c.struct_statfs = undefined;
    if (c.fstatfs(dir.handle, &buf) != 0) return false; // silently ignoring errors isn't too nice.
    const iskern = switch (util.castTruncate(u32, buf.f_type)) {
        // These numbers are documented in the Linux 'statfs(2)' man page, so I assume they're stable.
        0x42494e4d, // BINFMTFS_MAGIC
        0xcafe4a11, // BPF_FS_MAGIC
        0x27e0eb, // CGROUP_SUPER_MAGIC
        0x63677270, // CGROUP2_SUPER_MAGIC
        0x64626720, // DEBUGFS_MAGIC
        0x1cd1, // DEVPTS_SUPER_MAGIC
        0x9fa0, // PROC_SUPER_MAGIC
        0x6165676c, // PSTOREFS_MAGIC
        0x73636673, // SECURITYFS_MAGIC
        0xf97cff8c, // SELINUX_MAGIC
        0x62656572, // SYSFS_MAGIC
        0x74726163, // TRACEFS_MAGIC
        => true,
        else => false,
    };
    return iskern;
}

fn clamp(comptime T: type, comptime field: anytype, x: anytype) @FieldType(T, @tagName(field)) {
    return util.castClamp(@FieldType(T, @tagName(field)), x);
}

fn truncate(comptime T: type, comptime field: anytype, x: anytype) @FieldType(T, @tagName(field)) {
    return util.castTruncate(@FieldType(T, @tagName(field)), x);
}

pub fn statAt(parent: std.Io.Dir, name: [:0]const u8, follow: bool, symlink: ?*bool) !sink.Stat {
    // std.posix.fstatatZ() in Zig 0.14 is not suitable due to https://github.com/ziglang/zig/issues/23463
    const Stat = if (builtin.target.os.tag == .linux) std.os.linux.Statx else std.c.Stat;
    var stat: Stat = undefined;
    if (builtin.target.os.tag == .linux) {
        const errno = std.os.linux.statx(parent.handle, name, if (follow) 0 else std.os.linux.AT.SYMLINK_NOFOLLOW, .BASIC_STATS, &stat);
        if (errno != 0) {
            return switch (std.os.linux.errno(errno)) {
                .NOENT => return error.FileNotFound,
                .NAMETOOLONG => return error.NameTooLong,
                .NOMEM => return error.OutOfMemory,
                .ACCES => return error.AccessDenied,
                else => return error.Unexpected,
            };
        }
    } else if (std.c.fstatat(parent.handle, name, &stat, if (follow) 0 else std.c.AT.SYMLINK_NOFOLLOW) != 0) {
        return switch (std.c._errno().*) {
            @backingInt(std.c.E.NOENT) => error.FileNotFound,
            @backingInt(std.c.E.NAMETOOLONG) => error.NameTooLong,
            @backingInt(std.c.E.NOMEM) => error.OutOfMemory,
            @backingInt(std.c.E.ACCES) => error.AccessDenied,
            else => error.Unexpected,
        };
    }
    if (symlink) |s| s.* = std.c.S.ISLNK(stat.mode);
    return sink.Stat{
        .etype = if (std.c.S.ISDIR(stat.mode))
            .dir
        else if (stat.nlink > 1)
            .link
        else if (!std.c.S.ISREG(stat.mode))
            .nonreg
        else
            .reg,
        .blocks = clamp(sink.Stat, .blocks, stat.blocks),
        .size = clamp(sink.Stat, .size, stat.size),
        .dev = truncate(sink.Stat, .dev, if (builtin.target.os.tag == .linux)
            makedev(stat.dev_major, stat.dev_minor)
        else
            stat.dev),
        .ino = truncate(sink.Stat, .ino, stat.ino),
        .nlink = clamp(sink.Stat, .nlink, stat.nlink),
        .ext = .{
            .pack = .{
                .hasmtime = true,
                .hasuid = true,
                .hasgid = true,
                .hasmode = true,
            },
            .mtime = clamp(model.Ext, .mtime, if (builtin.target.os.tag == .linux) stat.mtime.sec else stat.mtime().sec),
            .uid = truncate(model.Ext, .uid, stat.uid),
            .gid = truncate(model.Ext, .gid, stat.gid),
            .mode = truncate(model.Ext, .mode, stat.mode),
        },
    };
}

fn makedev(major: u32, minor: u32) u64 {
    var dev: u64 = 0;
    dev |= (@as(u64, major) & 0xfffff000) << 32;
    dev |= (@as(u64, major) & 0x00000fff) << 8;
    dev |= (@as(u64, minor) & 0xffffff00) << 12;
    dev |= (@as(u64, minor) & 0x000000ff);
    return dev;
}

fn isCacheDir(io: std.Io, dir: std.Io.Dir) bool {
    const sig = "Signature: 8a477f597d28d172789f06886806bc55";
    const f = dir.openFile(io, "CACHEDIR.TAG", .{}) catch return false;
    defer f.close(io);
    var buf: [sig.len]u8 = undefined;
    const len = f.readPositionalAll(io, &buf, 0) catch return false;
    return len == sig.len and std.mem.eql(u8, &buf, sig);
}

const State = struct {
    // Simple LIFO queue. Threads attempt to fully scan their assigned
    // directory before consulting this queue for their next task, so there
    // shouldn't be too much contention here.
    // TODO: unless threads keep juggling around leaf nodes, need to measure
    // actual use.
    // There's no real reason for this to be LIFO other than that that was the
    // easiest to implement. Queue order has an effect on scheduling, but it's
    // impossible for me to predict how that ends up affecting performance.
    queue: [QUEUE_SIZE]*Dir = undefined,
    queue_len: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    queue_lock: std.Io.Mutex = .init,
    queue_cond: std.Io.Condition = .init,

    threads: []Thread,
    waiting: usize = 0,

    // No clue what this should be set to. Dir structs aren't small so we don't
    // want too have too many of them.
    const QUEUE_SIZE = 16;

    // Returns true if the given Dir has been queued, false if the queue is full.
    fn tryPush(self: *State, io: std.Io, d: *Dir) bool {
        if (self.queue_len.load(.acquire) == QUEUE_SIZE) return false;
        {
            self.queue_lock.lock(io) catch {};
            defer self.queue_lock.unlock(io);
            if (self.queue_len.load(.monotonic) == QUEUE_SIZE) return false;
            const slot = self.queue_len.fetchAdd(1, .monotonic);
            self.queue[slot] = d;
        }
        self.queue_cond.signal(io);
        return true;
    }

    // Blocks while the queue is empty, returns null when all threads are blocking.
    fn waitPop(self: *State, io: std.Io) ?*Dir {
        self.queue_lock.lock(io) catch {};
        defer self.queue_lock.unlock(io);

        self.waiting += 1;
        while (self.queue_len.load(.monotonic) == 0) {
            if (self.waiting == self.threads.len) {
                self.queue_cond.broadcast(io);
                return null;
            }
            self.queue_cond.wait(io, &self.queue_lock) catch {};
        }
        self.waiting -= 1;

        const slot = self.queue_len.fetchSub(1, .monotonic) - 1;
        defer self.queue[slot] = undefined;
        return self.queue[slot];
    }
};

const Dir = struct {
    fd: std.Io.Dir,
    dev: u64,
    pat: exclude.Patterns,
    it: std.Io.Dir.Iterator,
    sink: *sink.Dir,

    fn create(fd: std.Io.Dir, dev: u64, pat: exclude.Patterns, s: *sink.Dir) *Dir {
        const d = main.allocator.create(Dir) catch unreachable;
        d.* = .{
            .fd = fd,
            .dev = dev,
            .pat = pat,
            .sink = s,
            .it = fd.iterate(),
        };
        return d;
    }

    fn destroy(d: *Dir, io: std.Io, t: *Thread) void {
        d.pat.deinit();
        d.fd.close(io);
        d.sink.unref(io, t.sink);
        main.allocator.destroy(d);
    }
};

const Thread = struct {
    thread_num: usize,
    sink: *sink.Thread,
    state: *State,
    stack: std.ArrayListUnmanaged(*Dir) = .empty,
    thread: std.Thread = undefined,
    namebuf: [4096]u8 = undefined,

    fn scanOne(t: *Thread, io: std.Io, dir: *Dir, name_: []const u8) void {
        if (name_.len > t.namebuf.len - 1) {
            dir.sink.addSpecial(io, t.sink, name_, .err);
            return;
        }

        @memcpy(t.namebuf[0..name_.len], name_);
        t.namebuf[name_.len] = 0;
        const name = t.namebuf[0..name_.len :0];

        const excluded = dir.pat.match(name);
        if (excluded == false) { // matched either a file or directory, so we can exclude this before stat()ing.
            dir.sink.addSpecial(io, t.sink, name, .pattern);
            return;
        }

        var symlink: bool = undefined;
        var stat = statAt(dir.fd, name, false, &symlink) catch {
            dir.sink.addSpecial(io, t.sink, name, .err);
            return;
        };

        if (main.config.follow_symlinks and symlink) {
            if (statAt(dir.fd, name, true, &symlink)) |nstat| {
                if (nstat.etype != .dir) {
                    stat = nstat;
                    // Symlink targets may reside on different filesystems,
                    // this will break hardlink detection and counting so let's disable it.
                    if (stat.etype == .link and stat.dev != dir.dev) {
                        stat.etype = .reg;
                        stat.nlink = 1;
                    }
                }
            } else |_| {}
        }

        if (main.config.same_fs and stat.dev != dir.dev) {
            dir.sink.addSpecial(io, t.sink, name, .otherfs);
            return;
        }

        if (stat.etype != .dir) {
            dir.sink.addStat(io, t.sink, name, &stat);
            return;
        }

        if (excluded == true) {
            dir.sink.addSpecial(io, t.sink, name, .pattern);
            return;
        }

        var edir = dir.fd.openDir(io, name, .{ .follow_symlinks = false, .iterate = true }) catch {
            const s = dir.sink.addDir(io, t.sink, name, &stat);
            s.setReadError(io, t.sink);
            s.unref(io, t.sink);
            return;
        };

        if (@import("builtin").os.tag == .linux and
            main.config.exclude_kernfs and
            stat.dev != dir.dev and
            isKernfs(edir))
        {
            edir.close(io);
            dir.sink.addSpecial(io, t.sink, name, .kernfs);
            return;
        }

        if (main.config.exclude_caches and isCacheDir(io, edir)) {
            dir.sink.addSpecial(io, t.sink, name, .pattern);
            edir.close(io);
            return;
        }

        const s = dir.sink.addDir(io, t.sink, name, &stat);
        const ndir = Dir.create(edir, stat.dev, dir.pat.enter(name), s);
        if (main.config.threads == 1 or !t.state.tryPush(io, ndir))
            t.stack.append(main.allocator, ndir) catch unreachable;
    }

    fn run(t: *Thread, io: std.Io) void {
        defer t.stack.deinit(main.allocator);
        while (t.state.waitPop(io)) |dir| {
            t.stack.append(main.allocator, dir) catch unreachable;

            while (t.stack.items.len > 0) {
                const d = t.stack.items[t.stack.items.len - 1];

                t.sink.setDir(io, d.sink);
                if (t.thread_num == 0) main.handleEvent(io, false, false);

                const entry = d.it.next(io) catch blk: {
                    dir.sink.setReadError(io, t.sink);
                    break :blk null;
                };
                if (entry) |e|
                    t.scanOne(io, d, e.name)
                else {
                    t.sink.setDir(io, null);
                    t.stack.pop().?.destroy(io, t);
                }
            }
        }
    }
};

pub fn scan(io: std.Io, path: [:0]const u8) !void {
    const sink_threads = sink.createThreads(main.config.threads);
    defer sink.done(io);

    var symlink: bool = undefined;
    const stat = try statAt(std.Io.Dir.cwd(), path, true, &symlink);
    const fd = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });

    var state = State{
        .threads = main.allocator.alloc(Thread, main.config.threads) catch unreachable,
    };
    defer main.allocator.free(state.threads);

    const root = sink.createRoot(io, path, &stat);
    const dir = Dir.create(fd, stat.dev, exclude.getPatterns(path), root);
    _ = state.tryPush(io, dir);

    for (sink_threads, state.threads, 0..) |*s, *t, n|
        t.* = .{ .sink = s, .state = &state, .thread_num = n };

    // XXX: Continue with fewer threads on error?
    for (state.threads[1..]) |*t| {
        t.thread = std.Thread.spawn(
            .{ .stack_size = 128 * 1024, .allocator = main.allocator },
            Thread.run,
            .{ t, io },
        ) catch |e| ui.die("Error spawning thread: {}\n", .{e});
    }
    state.threads[0].run(io);
    for (state.threads[1..]) |*t| t.thread.join();
}
