// SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");
const main = @import("main.zig");
const model = @import("model.zig");
const mem_src = @import("mem_src.zig");
const mem_sink = @import("mem_sink.zig");
const json_export = @import("json_export.zig");
const bin_export = @import("bin_export.zig");
const ui = @import("ui.zig");
const util = @import("util.zig");

// Terminology note:
// "source" is where scan results come from, these are scan.zig, mem_src.zig
//   and json_import.zig.
// "sink" is where scan results go to. This file provides a generic sink API
//   for sources to use. The API forwards the results to specific sink
//   implementations (mem_sink.zig or json_export.zig) and provides progress
//   updates.

// API for sources:
//
// Single-threaded:
//
//   createThreads(1)
//   dir = createRoot(name, stat)
//   dir.addSpecial(name, opt)
//   dir.addFile(name, stat)
//   sub = dir.addDir(name, stat)
//     (no dir.stuff here)
//     sub.addstuff();
//     sub.unref();
//   dir.unref();
//   done()
//
// Multi-threaded interleaving:
//
//   createThreads(n)
//   dir = createRoot(name, stat)
//   dir.addSpecial(name, opt)
//   dir.addFile(name, stat)
//   sub = dir.addDir(...)
//     sub.addstuff();
//   sub2 = dir.addDir(..);
//     sub.unref();
//   dir.unref(); // <- no more direct descendants for x, but subdirs could still be active
//     sub2.addStuff();
//     sub2.unref(); // <- this is where 'dir' is really done.
//   done()
//
// Rule:
//   No concurrent method calls on a single Dir object, but objects may be passed between threads.

// Concise stat struct for fields we're interested in, with the types used by the model.
pub const Stat = struct {
    etype: model.EType = .reg,
    blocks: model.Blocks = 0,
    size: u64 = 0,
    dev: u64 = 0,
    ino: u64 = 0,
    nlink: u31 = 0,
    ext: model.Ext = .{},
};

pub const Dir = struct {
    refcnt: std.atomic.Value(usize) = std.atomic.Value(usize).init(1),
    name: []const u8,
    parent: ?*Dir,
    out: Out,

    const Out = union(enum) {
        mem: mem_sink.Dir,
        json: json_export.Dir,
        bin: bin_export.Dir,
    };

    pub fn addSpecial(d: *Dir, io: std.Io, t: *Thread, name: []const u8, sp: model.EType) void {
        std.debug.assert(@backingInt(sp) < 0); // >=0 aren't "special"
        _ = t.files_seen.fetchAdd(1, .monotonic);
        switch (d.out) {
            .mem => |*m| m.addSpecial(io, &t.sink.mem, name, sp),
            .json => |*j| j.addSpecial(io, name, sp),
            .bin => |*b| b.addSpecial(io, &t.sink.bin, name, sp),
        }
        if (sp == .err) {
            global.last_error_lock.lock(io) catch {};
            defer global.last_error_lock.unlock(io);
            if (global.last_error) |p| main.allocator.free(p);
            const p = d.path();
            global.last_error = std.Io.Dir.path.joinZ(main.allocator, &.{ p, name }) catch unreachable;
            main.allocator.free(p);
        }
    }

    pub fn addStat(d: *Dir, io: std.Io, t: *Thread, name: []const u8, stat: *const Stat) void {
        _ = t.files_seen.fetchAdd(1, .monotonic);
        _ = t.addBytes(io, (stat.blocks *| 512) / @max(1, stat.nlink));
        std.debug.assert(stat.etype != .dir);
        switch (d.out) {
            .mem => |*m| _ = m.addStat(io, &t.sink.mem, name, stat),
            .json => |*j| j.addStat(io, name, stat),
            .bin => |*b| b.addStat(io, &t.sink.bin, name, stat),
        }
    }

    pub fn addDir(d: *Dir, io: std.Io, t: *Thread, name: []const u8, stat: *const Stat) *Dir {
        _ = t.files_seen.fetchAdd(1, .monotonic);
        _ = t.addBytes(io, stat.blocks *| 512);
        std.debug.assert(stat.etype == .dir);
        std.debug.assert(d.out != .json or d.refcnt.load(.monotonic) == 1);

        const s = main.allocator.create(Dir) catch unreachable;
        s.* = .{
            .name = main.allocator.dupe(u8, name) catch unreachable,
            .parent = d,
            .out = switch (d.out) {
                .mem => |*m| .{ .mem = m.addDir(io, &t.sink.mem, name, stat) },
                .json => |*j| .{ .json = j.addDir(io, name, stat) },
                .bin => |*b| .{ .bin = b.addDir(io, stat) },
            },
        };
        d.ref();
        return s;
    }

    pub fn setReadError(d: *Dir, io: std.Io, t: *Thread) void {
        _ = t;
        switch (d.out) {
            .mem => |*m| m.setReadError(),
            .json => |*j| j.setReadError(),
            .bin => |*b| b.setReadError(io),
        }
        global.last_error_lock.lock(io) catch {};
        defer global.last_error_lock.unlock(io);
        if (global.last_error) |p| main.allocator.free(p);
        global.last_error = d.path();
    }

    fn path(d: *Dir) [:0]u8 {
        var components: std.ArrayListUnmanaged([]const u8) = .empty;
        defer components.deinit(main.allocator);
        var it: ?*Dir = d;
        while (it) |e| : (it = e.parent) components.append(main.allocator, e.name) catch unreachable;

        var out: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = components.items.len - 1;
        while (true) {
            if (i != components.items.len - 1 and !(out.items.len != 0 and out.items[out.items.len - 1] == '/'))
                out.append(main.allocator, '/') catch unreachable;
            out.appendSlice(main.allocator, components.items[i]) catch unreachable;
            if (i == 0) break;
            i -= 1;
        }
        return out.toOwnedSliceSentinel(main.allocator, 0) catch unreachable;
    }

    fn ref(d: *Dir) void {
        _ = d.refcnt.fetchAdd(1, .monotonic);
    }

    pub fn unref(d: *Dir, io: std.Io, t: *Thread) void {
        if (d.refcnt.fetchSub(1, .release) != 1) return;
        _ = d.refcnt.load(.acquire);

        switch (d.out) {
            .mem => |*m| m.final(io, if (d.parent) |p| &p.out.mem else null),
            .json => |*j| j.final(io),
            .bin => |*b| b.final(io, &t.sink.bin, d.name, if (d.parent) |p| &p.out.bin else null),
        }

        if (d.parent) |p| p.unref(io, t);
        if (d.name.len > 0) main.allocator.free(d.name);
        main.allocator.destroy(d);
    }
};

pub const Thread = struct {
    current_dir: ?*Dir = null,
    lock: std.Io.Mutex = .init,
    // On 32-bit architectures, bytes_seen is protected by the above mutex instead.
    bytes_seen: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    files_seen: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    sink: union {
        mem: mem_sink.Thread,
        json: void,
        bin: bin_export.Thread,
    } = .{ .mem = .{} },

    fn addBytes(t: *Thread, io: std.Io, bytes: u64) void {
        if (@bitSizeOf(usize) >= 64)
            _ = t.bytes_seen.fetchAdd(bytes, .monotonic)
        else {
            t.lock.lock(io) catch {};
            defer t.lock.unlock(io);
            t.bytes_seen.raw += bytes;
        }
    }

    fn getBytes(t: *Thread, io: std.Io) u64 {
        if (@bitSizeOf(usize) >= 64)
            return t.bytes_seen.load(.monotonic)
        else {
            t.lock.lock(io) catch {};
            defer t.lock.unlock(io);
            return t.bytes_seen.raw;
        }
    }

    pub fn setDir(t: *Thread, io: std.Io, d: ?*Dir) void {
        t.lock.lock(io) catch {};
        defer t.lock.unlock(io);
        t.current_dir = d;
    }
};

pub const global = struct {
    pub var state: enum { done, err, zeroing, hlcnt, running } = .running;
    pub var threads: []Thread = undefined;
    pub var sink: enum { json, mem, bin } = .mem;

    pub var last_error: ?[:0]u8 = null;
    var last_error_lock: std.Io.Mutex = .init;
    var need_confirm_quit = false;
};

// Must be the first thing to call from a source; initializes global state.
pub fn createThreads(num: usize) []Thread {
    // JSON export does not support multiple threads, scan into memory first.
    if (global.sink == .json and num > 1) {
        global.sink = .mem;
        mem_sink.global.stats = false;
    }

    global.state = .running;
    if (global.last_error) |p| main.allocator.free(p);
    global.last_error = null;
    global.threads = main.allocator.alloc(Thread, num) catch unreachable;
    for (global.threads) |*t| t.* = .{
        .sink = switch (global.sink) {
            .mem => .{ .mem = .{} },
            .json => .{ .json = {} },
            .bin => .{ .bin = .{} },
        },
    };
    return global.threads;
}

// Must be the last thing to call from a source.
pub fn done(io: std.Io) void {
    switch (global.sink) {
        .mem => mem_sink.done(io),
        .json => json_export.done(io),
        .bin => bin_export.done(io, global.threads),
    }
    global.state = .done;
    main.allocator.free(global.threads);

    // We scanned into memory, now we need to scan from memory to JSON
    if (global.sink == .mem and !mem_sink.global.stats) {
        global.sink = .json;
        mem_src.run(io, model.root);
    }

    // Clear the screen when done.
    if (main.config.scan_ui == .line) main.handleEvent(io, false, true);
}

pub fn createRoot(io: std.Io, path: []const u8, stat: *const Stat) *Dir {
    const d = main.allocator.create(Dir) catch unreachable;
    d.* = .{
        .name = main.allocator.dupe(u8, path) catch unreachable,
        .parent = null,
        .out = switch (global.sink) {
            .mem => .{ .mem = mem_sink.createRoot(io, path, stat) },
            .json => .{ .json = json_export.createRoot(io, path, stat) },
            .bin => .{ .bin = bin_export.createRoot(stat, global.threads) },
        },
    };
    return d;
}

fn drawConsole(io: std.Io) void {
    const st = struct {
        var ansi: ?bool = null;
        var lines_written: usize = 0;
    };
    const stderr = std.Io.File.stderr();
    const ansi = st.ansi orelse blk: {
        const t = stderr.supportsAnsiEscapeCodes(io) catch false;
        st.ansi = t;
        break :blk t;
    };

    var buf: [4096]u8 = undefined;
    var wr: std.Io.Writer = .fixed(&buf);
    while (ansi and st.lines_written > 0) {
        wr.writeAll("\x1b[1F\x1b[2K") catch {};
        st.lines_written -= 1;
    }

    if (global.state == .hlcnt) {
        wr.writeAll("Counting hardlinks...") catch {};
        if (model.inodes.add_total > 0)
            wr.print(" {} / {}", .{ model.inodes.add_done, model.inodes.add_total }) catch {};
        wr.writeByte('\n') catch {};
        st.lines_written += 1;
    } else if (global.state == .running) {
        var bytes: u64 = 0;
        var files: u64 = 0;
        for (global.threads) |*t| {
            bytes +|= t.getBytes(io);
            files += t.files_seen.load(.monotonic);
        }
        const r = ui.FmtSize.fmt(bytes);
        wr.print("{} files / {s}{s}\n", .{ files, r.num(), r.unit }) catch {};
        st.lines_written += 1;

        for (global.threads, 0..) |*t, i| {
            const dir = blk: {
                t.lock.lock(io) catch {};
                defer t.lock.unlock(io);
                break :blk if (t.current_dir) |d| d.path() else null;
            };
            wr.print("  #{}: {s}\n", .{ i + 1, ui.shorten(ui.toUtf8(dir orelse "(waiting)"), 73) }) catch {};
            st.lines_written += 1;
            if (dir) |p| main.allocator.free(p);
        }
    }

    stderr.writeStreamingAll(io, std.mem.print(&buf, "{d}\n", .{wr.end}) catch @panic("failed to write to stderr")) catch {};
}

fn drawProgress(io: std.Io) void {
    const st = struct {
        var animation_pos: usize = 0;
    };

    var bytes: u64 = 0;
    var files: u64 = 0;
    for (global.threads) |*t| {
        bytes +|= t.getBytes(io);
        files += t.files_seen.load(.monotonic);
    }

    ui.init();
    const width = ui.cols -| 5;
    const numthreads: u32 = @intCast(@min(global.threads.len, @max(1, ui.rows -| 10)));
    const box = ui.Box.create(8 + numthreads, width, "Scanning...");
    box.move(2, 2);
    ui.addstr("Total items: ");
    ui.addnum(.default, files);

    if (width > 48) {
        box.move(2, 30);
        ui.addstr("size: ");
        ui.addsize(.default, bytes);
    }

    for (0..numthreads) |i| {
        box.move(3 + @as(u32, @intCast(i)), 4);
        const dir = blk: {
            const t = &global.threads[i];
            t.lock.lock(io) catch {};
            defer t.lock.unlock(io);
            break :blk if (t.current_dir) |d| d.path() else null;
        };
        ui.addstr(ui.shorten(ui.toUtf8(dir orelse "(waiting)"), width -| 6));
        if (dir) |p| main.allocator.free(p);
    }

    blk: {
        global.last_error_lock.lock(io) catch {};
        defer global.last_error_lock.unlock(io);
        const err = global.last_error orelse break :blk;
        box.move(4 + numthreads, 2);
        ui.style(.bold);
        ui.addstr("Warning: ");
        ui.style(.default);
        ui.addstr("error scanning ");
        ui.addstr(ui.shorten(ui.toUtf8(err), width -| 28));
        box.move(5 + numthreads, 3);
        ui.addstr("some directory sizes may not be correct.");
    }

    if (global.need_confirm_quit) {
        box.move(6 + numthreads, width -| 20);
        ui.addstr("Press ");
        ui.style(.key);
        ui.addch('y');
        ui.style(.default);
        ui.addstr(" to confirm");
    } else {
        box.move(6 + numthreads, width -| 18);
        ui.addstr("Press ");
        ui.style(.key);
        ui.addch('q');
        ui.style(.default);
        ui.addstr(" to abort");
    }

    if (main.config.update_delay < std.time.ns_per_s and width > 40) {
        const txt = "Scanning...";
        st.animation_pos += 1;
        if (st.animation_pos >= txt.len * 2) st.animation_pos = 0;
        if (st.animation_pos < txt.len) {
            box.move(6 + numthreads, 2);
            for (txt[0 .. st.animation_pos + 1]) |t| ui.addch(t);
        } else {
            var i: u32 = txt.len - 1;
            while (i > st.animation_pos - txt.len) : (i -= 1) {
                box.move(6 + numthreads, 2 + i);
                ui.addch(txt[i]);
            }
        }
    }
}

fn drawError() void {
    const width = ui.cols -| 5;
    const box = ui.Box.create(6, width, "Scan error");

    box.move(2, 2);
    ui.addstr("Unable to open directory:");
    box.move(3, 4);
    ui.addstr(ui.shorten(ui.toUtf8(global.last_error.?), width -| 10));

    box.move(4, width -| 27);
    ui.addstr("Press any key to continue");
}

fn drawMessage(msg: []const u8) void {
    const width = ui.cols -| 5;
    const box = ui.Box.create(4, width, "Scan error");
    box.move(2, 2);
    ui.addstr(msg);
}

pub fn draw(io: std.Io) void {
    switch (main.config.scan_ui.?) {
        .none => {},
        .line => drawConsole(io),
        .full => {
            ui.init();
            switch (global.state) {
                .done => {},
                .err => drawError(),
                .zeroing => {
                    const box = ui.Box.create(4, ui.cols -| 5, "Initializing");
                    box.move(2, 2);
                    ui.addstr("Clearing directory counts...");
                },
                .hlcnt => {
                    const box = ui.Box.create(4, ui.cols -| 5, "Finalizing");
                    box.move(2, 2);
                    ui.addstr("Counting hardlinks... ");
                    if (model.inodes.add_total > 0) {
                        ui.addnum(.default, model.inodes.add_done);
                        ui.addstr(" / ");
                        ui.addnum(.default, model.inodes.add_total);
                    }
                },
                .running => drawProgress(io),
            }
        },
    }
}

pub fn keyInput(ch: i32) void {
    switch (global.state) {
        .done => {},
        .err => main.state = .browse,
        .zeroing => {},
        .hlcnt => {},
        .running => {
            switch (ch) {
                'q' => {
                    if (main.config.confirm_quit)
                        global.need_confirm_quit = !global.need_confirm_quit
                    else
                        ui.quit();
                },
                'y', 'Y' => if (global.need_confirm_quit) ui.quit(),
                else => global.need_confirm_quit = false,
            }
        },
    }
}
