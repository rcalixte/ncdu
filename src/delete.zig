// SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");
const main = @import("main.zig");
const model = @import("model.zig");
const ui = @import("ui.zig");
const browser = @import("browser.zig");
const scan = @import("scan.zig");
const sink = @import("sink.zig");
const mem_sink = @import("mem_sink.zig");
const util = @import("util.zig");
const c = @import("c");

var parent: *model.Dir = undefined;
var entry: *model.Entry = undefined;
var next_sel: ?*model.Entry = undefined; // Which item to select if deletion succeeds
var state: enum { confirm, busy, err } = .confirm;
var confirm: enum { yes, no, ignore } = .no;
var error_option: enum { abort, ignore, all } = .abort;
var error_code: anyerror = undefined;

pub fn setup(p: *model.Dir, e: *model.Entry, n: ?*model.Entry) void {
    parent = p;
    entry = e;
    next_sel = n;
    state = if (main.config.confirm_delete) .confirm else .busy;
    confirm = .no;
}

// Returns true to abort scanning.
fn err(io: std.Io, e: anyerror) bool {
    if (main.config.ignore_delete_errors)
        return false;
    error_code = e;
    state = .err;

    while (main.state == .delete and state == .err)
        main.handleEvent(io, true, false);

    return main.state != .delete;
}

fn deleteItem(io: std.Io, dir: std.Io.Dir, path: [:0]const u8, ptr: *align(1) ?*model.Entry) bool {
    entry = ptr.*.?;
    main.handleEvent(io, false, false);
    if (main.state != .delete)
        return true;

    if (entry.dir()) |d| {
        var fd = dir.openDir(io, path, .{ .follow_symlinks = false, .iterate = false }) catch |e| return err(io, e);
        var it = &d.sub.ptr;
        parent = d;
        defer parent = parent.parent.?;
        while (it.*) |n| {
            if (deleteItem(io, fd, n.name(), it)) {
                fd.close(io);
                return true;
            }
            if (it.* == n) // item deletion failed, make sure to still advance to next
                it = &n.next.ptr;
        }
        fd.close(io);
        dir.deleteDir(io, path) catch |e|
            return if (e != error.DirNotEmpty or d.sub.ptr == null) err(io, e) else false;
    } else dir.deleteFile(io, path) catch |e| return err(io, e);
    ptr.*.?.zeroStats(parent);
    ptr.* = ptr.*.?.next.ptr;
    return false;
}

// Returns true if the item has been deleted successfully.
fn deleteCmd(io: std.Io, environ_map: *std.process.Environ.Map, path: [:0]const u8, ptr: *align(1) ?*model.Entry) bool {
    {
        environ_map.put("NCDU_DELETE_PATH", path) catch @panic("Failed to put NCDU_DELETE_PATH in environment");

        // Since we're passing the path as an environment variable and go through
        // the shell anyway, we can refer to the variable and avoid error-prone
        // shell escaping.
        const cmd = std.fmt.allocPrint(main.allocator, "{s} \"$NCDU_DELETE_PATH\"", .{main.config.delete_command}) catch unreachable;
        defer main.allocator.free(cmd);
        ui.runCmd(io, &.{ "/bin/sh", "-c", cmd }, null, environ_map, true);
    }

    const stat = scan.statAt(std.Io.Dir.cwd(), path, false, null) catch {
        // Stat failed. Would be nice to display an error if it's not
        // 'FileNotFound', but w/e, let's just assume the item has been
        // deleted as expected.
        ptr.*.?.zeroStats(parent);
        ptr.* = ptr.*.?.next.ptr;
        return true;
    };

    // If either old or new entry is not a dir, remove & re-add entry in the in-memory tree.
    if (ptr.*.?.pack.etype != .dir or stat.etype != .dir) {
        ptr.*.?.zeroStats(parent);
        const e = model.Entry.create(main.allocator, io, stat.etype, main.config.extended and !stat.ext.isEmpty(), ptr.*.?.name());
        e.next.ptr = ptr.*.?.next.ptr;
        mem_sink.statToEntry(io, &stat, e, parent);
        ptr.* = e;

        var it: ?*model.Dir = parent;
        while (it) |p| : (it = p.parent) {
            if (stat.etype != .link) {
                p.entry.pack.blocks +|= e.pack.blocks;
                p.entry.size +|= e.size;
            }
            p.items +|= 1;
        }
    }

    // If new entry is a dir, recursively scan.
    if (ptr.*.?.dir()) |d| {
        main.state = .refresh;
        sink.global.sink = .mem;
        mem_sink.global.root = d;
    }
    return false;
}

// Returns the item that should be selected in the browser.
pub fn delete(init: std.process.Init) ?*model.Entry {
    while (main.state == .delete and state == .confirm)
        main.handleEvent(init.io, true, false);
    if (main.state != .delete)
        return entry;

    // Find the pointer to this entry
    const e = entry;
    var it = &parent.sub.ptr;
    while (it.*) |n| : (it = &n.next.ptr)
        if (it.* == entry)
            break;

    var path: std.ArrayListUnmanaged(u8) = .empty;
    defer path.deinit(main.allocator);
    parent.fmtPath(main.allocator, true, &path);
    if (path.items.len == 0 or path.items[path.items.len - 1] != '/')
        path.append(main.allocator, '/') catch unreachable;
    path.appendSlice(main.allocator, entry.name()) catch unreachable;

    if (main.config.delete_command.len == 0) {
        _ = deleteItem(init.io, std.Io.Dir.cwd(), util.arrayListBufZ(&path, main.allocator), it);
        model.inodes.addAllStats(init.io);
        return if (it.* == e) e else next_sel;
    } else {
        const isdel = deleteCmd(init.io, init.environ_map, util.arrayListBufZ(&path, main.allocator), it);
        model.inodes.addAllStats(init.io);
        return if (isdel) next_sel else it.*;
    }
}

fn drawConfirm() void {
    browser.draw();
    const box = ui.Box.create(6, 60, "Confirm delete");
    box.move(1, 2);
    if (main.config.delete_command.len == 0) {
        ui.addstr("Are you sure you want to delete \"");
        ui.addstr(ui.shorten(ui.toUtf8(entry.name()), 21));
        ui.addch('"');
        if (entry.pack.etype != .dir)
            ui.addch('?')
        else {
            box.move(2, 18);
            ui.addstr("and all of its contents?");
        }
    } else {
        ui.addstr("Are you sure you want to run \"");
        ui.addstr(ui.shorten(ui.toUtf8(main.config.delete_command), 25));
        ui.addch('"');
        box.move(2, 4);
        ui.addstr("on \"");
        ui.addstr(ui.shorten(ui.toUtf8(entry.name()), 50));
        ui.addch('"');
    }

    box.move(4, 15);
    ui.style(if (confirm == .yes) .sel else .default);
    ui.addstr("yes");

    box.move(4, 25);
    ui.style(if (confirm == .no) .sel else .default);
    ui.addstr("no");

    box.move(4, 31);
    ui.style(if (confirm == .ignore) .sel else .default);
    ui.addstr("don't ask me again");
    box.move(4, switch (confirm) {
        .yes => 15,
        .no => 25,
        .ignore => 31,
    });
}

fn drawProgress() void {
    var path: std.ArrayListUnmanaged(u8) = .empty;
    defer path.deinit(main.allocator);
    parent.fmtPath(main.allocator, false, &path);
    path.append(main.allocator, '/') catch unreachable;
    path.appendSlice(main.allocator, entry.name()) catch unreachable;

    // TODO: Item counts and progress bar would be nice.

    const box = ui.Box.create(6, 60, "Deleting...");
    box.move(2, 2);
    ui.addstr(ui.shorten(ui.toUtf8(util.arrayListBufZ(&path, main.allocator)), 56));
    box.move(4, 41);
    ui.addstr("Press ");
    ui.style(.key);
    ui.addch('q');
    ui.style(.default);
    ui.addstr(" to abort");
}

fn drawErr() void {
    var path: std.ArrayListUnmanaged(u8) = .empty;
    defer path.deinit(main.allocator);
    parent.fmtPath(main.allocator, false, &path);
    path.append(main.allocator, '/') catch unreachable;
    path.appendSlice(main.allocator, entry.name()) catch unreachable;

    const box = ui.Box.create(6, 60, "Error");
    box.move(1, 2);
    ui.addstr("Error deleting ");
    ui.addstr(ui.shorten(ui.toUtf8(util.arrayListBufZ(&path, main.allocator)), 41));
    box.move(2, 4);
    ui.addstr(ui.errorString(error_code));

    box.move(4, 14);
    ui.style(if (error_option == .abort) .sel else .default);
    ui.addstr("abort");

    box.move(4, 23);
    ui.style(if (error_option == .ignore) .sel else .default);
    ui.addstr("ignore");

    box.move(4, 33);
    ui.style(if (error_option == .all) .sel else .default);
    ui.addstr("ignore all");
}

pub fn draw() void {
    switch (state) {
        .confirm => drawConfirm(),
        .busy => drawProgress(),
        .err => drawErr(),
    }
}

pub fn keyInput(ch: i32) void {
    switch (state) {
        .confirm => switch (ch) {
            'h', c.KEY_LEFT => confirm = switch (confirm) {
                .ignore => .no,
                else => .yes,
            },
            'l', c.KEY_RIGHT => confirm = switch (confirm) {
                .yes => .no,
                else => .ignore,
            },
            'q' => main.state = .browse,
            '\n' => switch (confirm) {
                .yes => state = .busy,
                .no => main.state = .browse,
                .ignore => {
                    main.config.confirm_delete = false;
                    state = .busy;
                },
            },
            else => {},
        },
        .busy => {
            if (ch == 'q')
                main.state = .browse;
        },
        .err => switch (ch) {
            'h', c.KEY_LEFT => error_option = switch (error_option) {
                .all => .ignore,
                else => .abort,
            },
            'l', c.KEY_RIGHT => error_option = switch (error_option) {
                .abort => .ignore,
                else => .all,
            },
            'q' => main.state = .browse,
            '\n' => switch (error_option) {
                .abort => main.state = .browse,
                .ignore => state = .busy,
                .all => {
                    main.config.ignore_delete_errors = true;
                    state = .busy;
                },
            },
            else => {},
        },
    }
}
