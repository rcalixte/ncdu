// SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");
const main = @import("main.zig");
const model = @import("model.zig");
const sink = @import("sink.zig");
const mem_sink = @import("mem_sink.zig");
const bin_reader = @import("bin_reader.zig");
const delete = @import("delete.zig");
const ui = @import("ui.zig");
const c = @import("c");
const util = @import("util.zig");

// Currently opened directory.
pub var dir_parent: *model.Dir = undefined;
pub var dir_path: [:0]u8 = undefined;
var dir_parents: std.ArrayListUnmanaged(model.Ref) = .empty;
var dir_alloc = std.heap.ArenaAllocator.init(main.allocator);

// Used to keep track of which dir is which ref, so we can enter it.
// Only used for binreader browsing.
var dir_refs: std.ArrayListUnmanaged(struct { ptr: *model.Dir, ref: u64 }) = .empty;

// Sorted list of all items in the currently opened directory.
// (first item may be null to indicate the "parent directory" item)
var dir_items: std.ArrayListUnmanaged(?*model.Entry) = .empty;

var dir_max_blocks: u64 = 0;
var dir_max_size: u64 = 0;
var dir_has_shared: bool = false;
var dir_loading: u64 = 0;

// Index into dir_items that is currently selected.
var cursor_idx: usize = 0;

const View = struct {
    // Index into dir_items, indicates which entry is displayed at the top of the view.
    // This is merely a suggestion, it will be adjusted upon drawing if it's
    // out of bounds or if the cursor is not otherwise visible.
    top: usize = 0,

    // The hash(name) of the selected entry (cursor), this is used to derive
    // cursor_idx after sorting or changing directory.
    cursor_hash: u64 = 0,

    fn dirHash() u64 {
        return std.hash.Wyhash.hash(0, dir_path);
    }

    // Update cursor_hash and save the current view to the hash table.
    fn save(self: *@This()) void {
        self.cursor_hash = if (dir_items.items.len == 0)
            0
        else if (dir_items.items[cursor_idx]) |e|
            e.nameHash()
        else
            0;
        opened_dir_views.put(dirHash(), self.*) catch {};
    }

    // Should be called after dir_parent or dir_items has changed, will load the last saved view and find the proper cursor_idx.
    fn load(self: *@This(), sel: u64) void {
        if (opened_dir_views.get(dirHash())) |v|
            self.* = v
        else
            self.* = @This(){};
        cursor_idx = 0;
        for (dir_items.items, 0..) |e, i| {
            const h = if (e) |x| x.nameHash() else 0;
            if (if (sel != 0) h == sel else self.cursor_hash == h) {
                cursor_idx = i;
                break;
            }
        }
    }
};

var current_view = View{};

// Directories the user has browsed to before, and which item was last selected.
// The key is the hash of dir_path;
var opened_dir_views = std.AutoHashMap(u64, View).init(main.allocator);

fn sortIntLt(a: anytype, b: @TypeOf(a)) ?bool {
    return if (a == b) null else if (main.config.sort_order == .asc) a < b else a > b;
}

fn sortLt(_: void, ap: ?*model.Entry, bp: ?*model.Entry) bool {
    const a = ap.?;
    const b = bp.?;

    if (main.config.sort_dirsfirst and a.pack.etype.isDirectory() != b.pack.etype.isDirectory())
        return a.pack.etype.isDirectory();

    switch (main.config.sort_col) {
        .name => {}, // name sorting is the fallback
        .blocks => {
            if (sortIntLt(a.pack.blocks, b.pack.blocks)) |r| return r;
            if (sortIntLt(a.size, b.size)) |r| return r;
        },
        .size => {
            if (sortIntLt(a.size, b.size)) |r| return r;
            if (sortIntLt(a.pack.blocks, b.pack.blocks)) |r| return r;
        },
        .items => {
            const ai = if (a.dir()) |d| d.items else 0;
            const bi = if (b.dir()) |d| d.items else 0;
            if (sortIntLt(ai, bi)) |r| return r;
            if (sortIntLt(a.pack.blocks, b.pack.blocks)) |r| return r;
            if (sortIntLt(a.size, b.size)) |r| return r;
        },
        .mtime => {
            if (!a.pack.isext or !b.pack.isext) return a.pack.isext;
            if (sortIntLt(a.ext().?.mtime, b.ext().?.mtime)) |r| return r;
        },
    }

    const an = (if (main.config.sort_order == .asc) a else b).name();
    const bn = (if (main.config.sort_order == .asc) b else a).name();
    return if (main.config.sort_natural)
        util.strnatcmp(an, bn) == .lt
    else
        std.mem.lessThan(u8, an, bn);
}

// Should be called when:
// - config.sort_* changes
// - dir_items changes (i.e. from loadDir())
// - files in this dir have changed in a way that affects their ordering
fn sortDir(next_sel: u64) void {
    // No need to sort the first item if that's the parent dir reference,
    // excluding that allows sortLt() to ignore null values.
    const lst = dir_items.items[(if (dir_items.items.len > 0 and dir_items.items[0] == null) @as(usize, 1) else 0)..];
    std.mem.sort(?*model.Entry, lst, {}, sortLt);
    current_view.load(next_sel);
}

// Must be called when:
// - dir_parent changes (i.e. we change directory)
// - config.show_hidden changes
// - files in this dir have been added or removed
pub fn loadDir(io: std.Io, next_sel: u64) void {
    // XXX: The current dir listing is wiped before loading the new one, which
    // causes the screen to flicker a bit when the loading indicator is drawn.
    // Should we keep the old listing around?
    main.event_delay_timer = std.Io.Clock.real.now(io);
    _ = dir_alloc.reset(.free_all);
    dir_items.shrinkRetainingCapacity(0);
    dir_refs.shrinkRetainingCapacity(0);
    dir_max_size = 1;
    dir_max_blocks = 1;
    dir_has_shared = false;

    if (dir_parents.items.len > 1)
        dir_items.append(main.allocator, null) catch unreachable;
    var ref = dir_parent.sub;
    while (!ref.isNull()) {
        const e =
            if (main.config.binreader)
                bin_reader.get(io, ref.ref, dir_alloc.allocator())
            else
                ref.ptr.?;

        if (e.pack.blocks > dir_max_blocks) dir_max_blocks = e.pack.blocks;
        if (e.size > dir_max_size) dir_max_size = e.size;
        const shown = main.config.show_hidden or blk: {
            const excl = switch (e.pack.etype) {
                .pattern, .otherfs, .kernfs => true,
                else => false,
            };
            const name = e.name();
            break :blk !excl and name[0] != '.' and name[name.len - 1] != '~';
        };
        if (shown) {
            dir_items.append(main.allocator, e) catch unreachable;
            if (e.dir()) |d| {
                if (d.shared_blocks > 0 or d.shared_size > 0) dir_has_shared = true;
                if (main.config.binreader) dir_refs.append(main.allocator, .{ .ptr = d, .ref = ref.ref }) catch unreachable;
            }
        }

        ref = e.next;
        dir_loading += 1;
        if ((dir_loading & 65) == 0)
            main.handleEvent(io, false, false);
    }
    sortDir(next_sel);
    dir_loading = 0;
}

pub fn initRoot(io: std.Io) void {
    if (main.config.binreader) {
        const ref = bin_reader.getRoot();
        dir_parent = bin_reader.get(io, ref, main.allocator).dir() orelse ui.die("Invalid import\n", .{});
        dir_parents.append(main.allocator, .{ .ref = ref }) catch unreachable;
    } else {
        dir_parent = model.root;
        dir_parents.append(main.allocator, .{ .ptr = &dir_parent.entry }) catch unreachable;
    }
    dir_path = main.allocator.dupeSentinel(u8, dir_parent.entry.name(), 0) catch unreachable;
    loadDir(io, 0);
}

fn enterSub(io: std.Io, e: *model.Dir) void {
    if (main.config.binreader) {
        const ref = blk: {
            for (dir_refs.items) |r| if (r.ptr == e) break :blk r.ref;
            return;
        };
        dir_parent.entry.destroy(main.allocator);
        dir_parent = bin_reader.get(io, ref, main.allocator).dir() orelse unreachable;
        dir_parents.append(main.allocator, .{ .ref = ref }) catch unreachable;
    } else {
        dir_parent = e;
        dir_parents.append(main.allocator, .{ .ptr = &e.entry }) catch unreachable;
    }

    const newpath = std.Io.Dir.path.joinZ(main.allocator, &[_][]const u8{ dir_path, e.entry.name() }) catch unreachable;
    main.allocator.free(dir_path);
    dir_path = newpath;
}

fn enterParent(io: std.Io) void {
    std.debug.assert(dir_parents.items.len > 1);

    _ = dir_parents.pop();
    const p = dir_parents.items[dir_parents.items.len - 1];
    if (main.config.binreader) {
        dir_parent.entry.destroy(main.allocator);
        dir_parent = bin_reader.get(io, p.ref, main.allocator).dir() orelse unreachable;
    } else dir_parent = p.ptr.?.dir() orelse unreachable;

    const newpath = main.allocator.dupeSentinel(u8, std.Io.Dir.path.dirname(dir_path) orelse unreachable, 0) catch unreachable;
    main.allocator.free(dir_path);
    dir_path = newpath;
}

const Row = struct {
    row: u32,
    col: u32 = 0,
    bg: ui.Bg = .default,
    item: ?*model.Entry,

    const Self = @This();

    fn flag(self: *Self) void {
        defer self.col += 2;
        const item = self.item orelse return;
        const ch: u7 = switch (item.pack.etype) {
            .dir => if (item.dir().?.pack.err)
                '!'
            else if (item.dir().?.pack.suberr)
                '.'
            else if (item.dir().?.sub.isNull())
                'e'
            else
                return,
            .link => 'H',
            .pattern => '<',
            .otherfs => '>',
            .kernfs => '^',
            .nonreg => '@',
            else => return,
        };
        ui.move(self.row, self.col);
        self.bg.fg(.flag);
        ui.addch(ch);
    }

    fn size(self: *Self) void {
        var width = if (main.config.si) @as(u32, 9) else 10;
        if (dir_has_shared and main.config.show_shared != .off)
            width += 2 + width;
        defer self.col += width;
        const item = self.item orelse return;
        const siz = if (main.config.show_blocks) util.blocksToSize(item.pack.blocks) else item.size;
        var shr = if (item.dir()) |d| (if (main.config.show_blocks) util.blocksToSize(d.shared_blocks) else d.shared_size) else 0;
        if (main.config.show_shared == .unique) shr = siz -| shr;

        ui.move(self.row, self.col);
        ui.addsize(self.bg, siz);
        if (dir_has_shared and shr > 0 and main.config.show_shared != .off) {
            self.bg.fg(.flag);
            ui.addstr(if (main.config.show_shared == .unique) " U " else " S ");
            ui.addsize(self.bg, shr);
        }
    }

    fn graph(self: *Self) void {
        if ((!main.config.show_graph and !main.config.show_percent) or self.col + 20 > ui.cols) return;

        const bar_size = @max(ui.cols / 7, 10);
        defer self.col += 3 +
            (if (main.config.show_graph) bar_size else 0) +
            (if (main.config.show_percent) @as(u32, 6) else 0) +
            (if (main.config.show_graph and main.config.show_percent) @as(u32, 1) else 0);
        const item = self.item orelse return;

        ui.move(self.row, self.col);
        self.bg.fg(.default);
        ui.addch('[');
        if (main.config.show_percent) {
            self.bg.fg(.num);
            var num: u64 = if (main.config.show_blocks) item.pack.blocks else item.size;
            var denom: u64 = if (main.config.show_blocks) dir_parent.entry.pack.blocks else dir_parent.entry.size;
            if (num > (1 << 54)) { // avoid overflow
                num >>= 10;
                denom >>= 10;
            }
            ui.addstr(&util.fmt5dec(@intCast(@min(1000, (num * 1000 + (denom / 2)) / @max(1, denom)))));
            self.bg.fg(.default);
            ui.addch('%');
        }
        if (main.config.show_graph and main.config.show_percent) ui.addch(' ');
        if (main.config.show_graph) {
            var max = if (main.config.show_blocks) dir_max_blocks else dir_max_size;
            var num = if (main.config.show_blocks) item.pack.blocks else item.size;
            if (max < bar_size) {
                max *= bar_size;
                num *= bar_size;
            }

            const perblock = std.math.divFloor(u64, max, bar_size) catch unreachable;
            self.bg.fg(.graph);
            for (0..bar_size) |_| {
                const frac = @min(@as(usize, 8), (num *| 8) / perblock);
                ui.addstr(switch (main.config.graph_style) {
                    .hash => ([_][:0]const u8{ " ", " ", " ", " ", " ", " ", " ", " ", "#" })[frac],
                    .half => ([_][:0]const u8{ " ", " ", " ", " ", "▌", "▌", "▌", "▌", "█" })[frac],
                    .eighth => ([_][:0]const u8{ " ", "▏", "▎", "▍", "▌", "▋", "▊", "▉", "█" })[frac],
                });
                num -|= perblock;
            }
        }
        self.bg.fg(.default);
        ui.addch(']');
    }

    fn items(self: *Self) void {
        if (!main.config.show_items or self.col + 10 > ui.cols) return;
        defer self.col += 7;
        const n = (if (self.item) |d| d.dir() orelse return else return).items;
        ui.move(self.row, self.col);
        self.bg.fg(.num);
        if (n < 1000)
            ui.addprint("  {d:>4}", .{n})
        else if (n < 10_000) {
            ui.addch(' ');
            ui.addnum(self.bg, n);
        } else if (n < 100_000)
            ui.addnum(self.bg, n)
        else if (n < 999_950) {
            ui.addstr(&util.fmt5dec(@intCast((n + 50) / 100)));
            self.bg.fg(.default);
            ui.addch('k');
        } else if (n < 999_950_000) {
            ui.addstr(&util.fmt5dec(@intCast((n + 50_000) / 100_000)));
            self.bg.fg(.default);
            ui.addch('M');
        } else {
            self.bg.fg(.default);
            ui.addstr("  > ");
            self.bg.fg(.num);
            ui.addch('1');
            self.bg.fg(.default);
            ui.addch('G');
        }
    }

    fn mtime(self: *Self) void {
        if (!main.config.show_mtime or self.col + 37 > ui.cols) return;
        defer self.col += 27;
        ui.move(self.row, self.col + 1);
        const ext = if (self.item) |e| e.ext() else dir_parent.entry.ext();
        if (ext) |e| {
            if (e.pack.hasmtime) {
                ui.addts(self.bg, e.mtime);
                return;
            }
        }
        ui.addstr("                 no mtime");
    }

    fn name(self: *Self) void {
        ui.move(self.row, self.col);
        if (self.item) |i| {
            self.bg.fg(if (i.pack.etype == .dir) .dir else .default);
            ui.addch(if (i.pack.etype.isDirectory()) '/' else ' ');
            ui.addstr(ui.shorten(ui.toUtf8(i.name()), ui.cols -| self.col -| 1));
        } else {
            self.bg.fg(.dir);
            ui.addstr("/..");
        }
    }

    fn draw(self: *Self) void {
        if (self.bg == .sel) {
            self.bg.fg(.default);
            ui.move(self.row, 0);
            ui.hline(' ', ui.cols);
        }
        self.flag();
        self.size();
        self.graph();
        self.items();
        self.mtime();
        self.name();
    }
};

var state: enum { main, quit, help, info } = .main;
var message: ?[]const [:0]const u8 = null;

const quit = struct {
    fn draw() void {
        const box = ui.Box.create(4, 22, "Confirm quit");
        box.move(2, 2);
        ui.addstr("Really quit? (");
        ui.style(.key);
        ui.addch('y');
        ui.style(.default);
        ui.addch('/');
        ui.style(.key);
        ui.addch('N');
        ui.style(.default);
        ui.addch(')');
    }

    fn keyInput(ch: i32) void {
        switch (ch) {
            'y', 'Y' => ui.quit(),
            else => state = .main,
        }
    }
};

const info = struct {
    const Tab = enum { info, links };

    var tab: Tab = .info;
    var entry: ?*model.Entry = null;
    var links: ?std.ArrayListUnmanaged(*model.Link) = null;
    var links_top: usize = 0;
    var links_idx: usize = 0;

    fn lt(_: void, a: *model.Link, b: *model.Link) bool {
        const pa = a.path(false);
        const pb = b.path(false);
        defer main.allocator.free(pa);
        defer main.allocator.free(pb);
        return std.mem.lessThan(u8, pa, pb);
    }

    // Set the displayed entry to the currently selected item and open the tab.
    fn set(e: ?*model.Entry, t: Tab) void {
        if (e != entry) {
            if (links) |*l| l.deinit(main.allocator);
            links = null;
            links_top = 0;
            links_idx = 0;
        }
        entry = e;
        if (e == null) {
            state = .main;
            return;
        }
        state = .info;
        tab = t;
        if (tab == .links and links == null and !main.config.binreader) {
            var list: std.ArrayListUnmanaged(*model.Link) = .empty;
            var l = e.?.link().?;
            while (true) {
                list.append(main.allocator, l) catch unreachable;
                l = l.next;
                if (&l.entry == e)
                    break;
            }
            std.sort.heap(*model.Link, list.items, {}, lt);
            for (list.items, 0..) |n, i| if (&n.entry == e) {
                links_idx = i;
            };
            links = list;
        }
    }

    fn drawLinks(box: ui.Box, row: *u32, rows: u32, cols: u32) void {
        if (main.config.binreader) {
            box.move(2, 2);
            ui.addstr("This feature is not available when reading from file.");
            return;
        }
        const numrows = rows -| 4;
        if (links_idx < links_top) links_top = links_idx;
        if (links_idx >= links_top + numrows) links_top = links_idx - numrows + 1;

        for (0..numrows) |i| {
            if (i + links_top >= links.?.items.len) break;
            const e = links.?.items[i + links_top];
            ui.style(if (i + links_top == links_idx) .sel else .default);
            box.move(row.*, 2);
            ui.addch(if (&e.entry == entry) '*' else ' ');
            const path = e.path(false);
            defer main.allocator.free(path);
            ui.addstr(ui.shorten(ui.toUtf8(path), cols -| 5));
            row.* += 1;
        }
        ui.style(.default);
        box.move(rows - 2, 4);
        ui.addprint("{:>3}/{}", .{ links_idx + 1, links.?.items.len });
    }

    fn drawSizeRow(box: ui.Box, row: *u32, label: [:0]const u8, size: u64) void {
        box.move(row.*, 3);
        ui.addstr(label);
        ui.addsize(.default, size);
        ui.addstr(" (");
        ui.addnum(.default, size);
        ui.addch(')');
        row.* += 1;
    }

    fn drawSize(box: ui.Box, row: *u32, label: [:0]const u8, size: u64, shared: u64) void {
        ui.style(.bold);
        drawSizeRow(box, row, label, size);
        if (shared > 0) {
            ui.style(.default);
            drawSizeRow(box, row, "     > shared: ", shared);
            drawSizeRow(box, row, "     > unique: ", size -| shared);
        }
    }

    fn drawInfo(box: ui.Box, row: *u32, cols: u32, e: *model.Entry) void {
        // Name
        box.move(row.*, 3);
        ui.style(.bold);
        ui.addstr("Name: ");
        ui.style(.default);
        ui.addstr(ui.shorten(ui.toUtf8(e.name()), cols - 11));
        row.* += 1;

        // Type / Mode+UID+GID
        box.move(row.*, 3);
        ui.style(.bold);
        if (e.ext()) |ext| {
            var buf: [32]u8 = undefined;
            if (ext.pack.hasmode) {
                ui.addstr("Mode: ");
                ui.style(.default);
                ui.addmode(ext.mode);
                ui.style(.bold);
            }
            if (ext.pack.hasuid) {
                ui.addstr("  UID: ");
                ui.style(.default);
                ui.addstr(std.mem.printSentinel(&buf, "{d:<6}", .{ext.uid}, 0) catch unreachable);
                ui.style(.bold);
            }
            if (ext.pack.hasgid) {
                ui.addstr(" GID: ");
                ui.style(.default);
                ui.addstr(std.mem.printSentinel(&buf, "{d:<6}", .{ext.gid}, 0) catch unreachable);
            }
        } else {
            ui.addstr("Type: ");
            ui.style(.default);
            ui.addstr(switch (e.pack.etype) {
                .dir => "Directory",
                .nonreg => "Other",
                .reg, .link => "File",
                else => "Excluded",
            });
        }
        row.* += 1;

        // Last modified
        if (e.ext()) |ext| {
            if (ext.pack.hasmtime) {
                box.move(row.*, 3);
                ui.style(.bold);
                ui.addstr("Last modified: ");
                ui.addts(.default, ext.mtime);
                row.* += 1;
            }
        }

        // Disk usage & Apparent size
        drawSize(box, row, "   Disk usage: ", util.blocksToSize(e.pack.blocks), if (e.dir()) |d| util.blocksToSize(d.shared_blocks) else 0);
        drawSize(box, row, "Apparent size: ", e.size, if (e.dir()) |d| d.shared_size else 0);

        // Number of items
        if (e.dir()) |d| {
            box.move(row.*, 3);
            ui.style(.bold);
            ui.addstr("    Sub items: ");
            ui.addnum(.default, d.items);
            row.* += 1;
        }

        // Number of links + inode (dev?)
        if (e.link()) |l| {
            box.move(row.*, 3);
            ui.style(.bold);
            ui.addstr("   Link count: ");
            ui.addnum(.default, l.pack.nlink);
            box.move(row.*, 23);
            ui.style(.bold);
            ui.addstr("  Inode: ");
            ui.style(.default);
            var buf: [32]u8 = undefined;
            ui.addstr(std.mem.printSentinel(&buf, "{}", .{l.ino}, 0) catch unreachable);
            row.* += 1;
        }
    }

    fn draw() void {
        const e = dir_items.items[cursor_idx].?;
        // XXX: The dynamic height is a bit jarring, especially when that
        // causes the same lines of information to be placed on different rows
        // for each item. Think it's better to have a dynamic height based on
        // terminal size and scroll if the content doesn't fit.
        const rows = 5 + // border + padding + close message
            if (tab == .links and !main.config.binreader) 8 else 4 + // name + type + disk usage + apparent size
                (if (e.ext() != null) @as(u32, 1) else 0) + // last modified
                (if (e.link() != null) @as(u32, 1) else 0) + // link count
                (if (e.dir()) |d| 1 + // sub items
                    (if (d.shared_size > 0) @as(u32, 2) else 0) +
                    (if (d.shared_blocks > 0) @as(u32, 2) else 0) else 0);
        const cols = 60; // TODO: dynamic width?
        const box = ui.Box.create(rows, cols, "Item info");
        var row: u32 = 2;

        // Tabs
        if (e.pack.etype == .link) {
            box.tab(cols - 19, tab == .info, 1, "Info");
            box.tab(cols - 10, tab == .links, 2, "Links");
        }

        switch (tab) {
            .info => drawInfo(box, &row, cols, e),
            .links => drawLinks(box, &row, rows, cols),
        }

        // "Press i to close this window"
        box.move(rows - 2, cols - 30);
        ui.style(.default);
        ui.addstr("Press ");
        ui.style(.key);
        ui.addch('i');
        ui.style(.default);
        ui.addstr(" to close this window");
    }

    fn keyInput(io: std.Io, ch: i32) bool {
        if (entry.?.pack.etype == .link) {
            switch (ch) {
                '1', 'h', c.KEY_LEFT => {
                    set(entry, .info);
                    return true;
                },
                '2', 'l', c.KEY_RIGHT => {
                    set(entry, .links);
                    return true;
                },
                else => {},
            }
        }
        if (tab == .links and !main.config.binreader) {
            if (keyInputSelection(ch, &links_idx, links.?.items.len, 5))
                return true;
            if (ch == 10) { // Enter - go to selected entry
                const l = links.?.items[links_idx];
                dir_parent = l.parent;
                loadDir(io, l.entry.nameHash());
                set(null, .info);
            }
        }
        if (keyInputSelection(ch, &cursor_idx, dir_items.items.len, ui.rows -| 3)) {
            set(dir_items.items[cursor_idx], .info);
            return true;
        }
        switch (ch) {
            'i', 'q' => set(null, .info),
            else => return false,
        }
        return true;
    }
};

const help = struct {
    const keys = [_][:0]const u8{
        "up, k",       "Move cursor up",
        "down, j",     "Move cursor down",
        "right/enter", "Open selected directory",
        "left, <, h",  "Open parent directory",
        "n",           "Sort by name (ascending/descending)",
        "s",           "Sort by size (ascending/descending)",
        "C",           "Sort by items (ascending/descending)",
        "M",           "Sort by mtime (-e flag)",
        "d",           "Delete selected file or directory",
        "t",           "Toggle dirs before files when sorting",
        "g",           "Show percentage and/or graph",
        "u",           "Show/hide hard link shared sizes",
        "a",           "Toggle between apparent size and disk usage",
        "c",           "Toggle display of child item counts",
        "m",           "Toggle display of latest mtime (-e flag)",
        "e",           "Show/hide hidden or excluded files",
        "i",           "Show information about selected item",
        "r",           "Recalculate the current directory",
        "b",           "Spawn shell in current directory",
        "q",           "Quit ncdu",
    };
    const keylines = 10;

    const flags = [_][:0]const u8{
        "!", "An error occurred while reading this directory",
        ".", "An error occurred while reading a subdirectory",
        "<", "File or directory is excluded from the statistics",
        "e", "Empty directory",
        ">", "Directory was on another filesystem",
        "@", "This is not a file nor a dir (symlink, socket, ...)",
        "^", "Excluded Linux pseudo-filesystem",
        "H", "Same file was already counted (hard link)",
    };

    // It's kinda ugly, but for nostalgia's sake...
    const logo = [_]u29{
        0b11111100111110000001100110011,
        0b11001100110000000001100110011,
        0b11001100110000011111100110011,
        0b11001100110000011001100110011,
        0b11001100111110011111100111111,
    };

    var tab: enum { keys, flags, about } = .keys;
    var offset: u32 = 0;

    fn drawKeys(box: ui.Box) void {
        var line: u32 = 1;
        var i = offset * 2;
        while (i < (offset + keylines) * 2) : (i += 2) {
            line += 1;
            box.move(line, 13 - @as(u32, @intCast(keys[i].len)));
            ui.style(.key);
            ui.addstr(keys[i]);
            ui.style(.default);
            ui.addch(' ');
            ui.addstr(keys[i + 1]);
        }
        if (offset < keys.len / 2 - keylines) {
            box.move(12, 25);
            ui.addstr("-- more --");
        }
    }

    fn drawFlags(box: ui.Box) void {
        box.move(2, 3);
        ui.style(.bold);
        ui.addstr("X  [size] [graph] [file or directory]");
        box.move(3, 4);
        ui.style(.default);
        ui.addstr("The X is only present in the following cases:");
        var i: u32 = 0;
        while (i < flags.len) : (i += 2) {
            box.move(i / 2 + 5, 4);
            ui.style(.flag);
            ui.addstr(flags[i]);
            ui.style(.default);
            ui.addch(' ');
            ui.addstr(flags[i + 1]);
        }
    }

    fn drawAbout(box: ui.Box) void {
        for (logo, 0..) |s, n| {
            box.move(@as(u32, @intCast(n + 3)), 12);
            var i: u5 = 28;
            while (i != 0) : (i -= 1) {
                ui.style(if (s & (@as(u29, 1) << i) > 0) .sel else .default);
                ui.addch(' ');
            }
        }
        ui.style(.default);
        box.move(3, 43);
        ui.addstr("NCurses");
        box.move(4, 43);
        ui.addstr("Disk");
        box.move(5, 43);
        ui.addstr("Usage");
        ui.style(.num);
        box.move(7, 43);
        ui.addstr(main.program_version);
        ui.style(.default);
        box.move(9, 11);
        ui.addstr("Written by Yorhel <projects@yorhel.nl>");
        box.move(10, 16);
        ui.addstr("https://dev.yorhel.nl/ncdu");
    }

    fn draw() void {
        const box = ui.Box.create(15, 60, "ncdu help");
        box.tab(30, tab == .keys, 1, "Keys");
        box.tab(39, tab == .flags, 2, "Format");
        box.tab(50, tab == .about, 3, "About");

        box.move(13, 42);
        ui.addstr("Press ");
        ui.style(.key);
        ui.addch('q');
        ui.style(.default);
        ui.addstr(" to close");

        switch (tab) {
            .keys => drawKeys(box),
            .flags => drawFlags(box),
            .about => drawAbout(box),
        }
    }

    fn keyInput(ch: i32) void {
        const ctab = tab;
        defer if (ctab != tab or state != .help) {
            offset = 0;
        };
        switch (ch) {
            '1' => tab = .keys,
            '2' => tab = .flags,
            '3' => tab = .about,
            'h', c.KEY_LEFT => tab = if (tab == .about) .flags else .keys,
            'l', c.KEY_RIGHT => tab = if (tab == .keys) .flags else .about,
            'j', ' ', c.KEY_DOWN, c.KEY_NPAGE => {
                const max = switch (tab) {
                    .keys => keys.len / 2 - keylines,
                    else => @as(u32, 0),
                };
                if (offset < max)
                    offset += 1;
            },
            'k', c.KEY_UP, c.KEY_PPAGE => {
                if (offset > 0) offset -= 1;
            },
            else => state = .main,
        }
    }
};

pub fn draw() void {
    ui.style(.hd);
    ui.move(0, 0);
    ui.hline(' ', ui.cols);
    ui.move(0, 0);
    ui.addstr("ncdu " ++ main.program_version ++ " ~ Use the arrow keys to navigate, press ");
    ui.style(.key_hd);
    ui.addch('?');
    ui.style(.hd);
    ui.addstr(" for help");
    if (main.config.binreader) {
        ui.move(0, ui.cols -| 11);
        ui.addstr("[from file]");
    } else if (main.config.imported) {
        ui.move(0, ui.cols -| 10);
        ui.addstr("[imported]");
    } else if (!main.config.can_delete.?) {
        ui.move(0, ui.cols -| 10);
        ui.addstr("[readonly]");
    }

    ui.style(.default);
    ui.move(1, 0);
    ui.hline('-', ui.cols);
    ui.move(1, 3);
    ui.addch(' ');
    ui.style(.dir);
    ui.addstr(ui.shorten(ui.toUtf8(dir_path), ui.cols -| 5));
    ui.style(.default);
    ui.addch(' ');

    const numrows = ui.rows -| 3;
    if (cursor_idx < current_view.top) current_view.top = cursor_idx;
    if (cursor_idx >= current_view.top + numrows) current_view.top = cursor_idx - numrows + 1;

    var i: u32 = if (dir_loading > 0) numrows else 0;
    var sel_row: u32 = 0;
    while (i < numrows) : (i += 1) {
        if (i + current_view.top >= dir_items.items.len) break;
        var row = Row{
            .row = i + 2,
            .item = dir_items.items[i + current_view.top],
            .bg = if (i + current_view.top == cursor_idx) .sel else .default,
        };
        if (row.bg == .sel) sel_row = i + 2;
        row.draw();
    }

    ui.style(.hd);
    ui.move(ui.rows - 1, 0);
    ui.hline(' ', ui.cols);
    ui.move(ui.rows - 1, 0);
    if (dir_loading > 0) {
        ui.addstr(" Loading... ");
        ui.addnum(.hd, dir_loading);
    } else {
        ui.addch(if (main.config.show_blocks) '*' else ' ');
        ui.style(if (main.config.show_blocks) .bold_hd else .hd);
        ui.addstr("Total disk usage: ");
        ui.addsize(.hd, util.blocksToSize(dir_parent.entry.pack.blocks));
        ui.style(if (main.config.show_blocks) .hd else .bold_hd);
        ui.addstr("  ");
        ui.addch(if (main.config.show_blocks) ' ' else '*');
        ui.addstr("Apparent size: ");
        ui.addsize(.hd, dir_parent.entry.size);
        ui.addstr("   Items: ");
        ui.addnum(.hd, dir_parent.items);
    }

    switch (state) {
        .main => {},
        .quit => quit.draw(),
        .help => help.draw(),
        .info => info.draw(),
    }
    if (message) |m| {
        const box = ui.Box.create(@intCast(m.len + 5), 60, "Message");
        i = 2;
        for (m) |ln| {
            box.move(i, 2);
            ui.addstr(ln);
            i += 1;
        }
        box.move(i + 1, 33);
        ui.addstr("Press any key to continue");
    }
    if (sel_row > 0) ui.move(sel_row, 0);
}

fn sortToggle(col: main.config.SortCol, default_order: main.config.SortOrder) void {
    if (main.config.sort_col != col)
        main.config.sort_order = default_order
    else if (main.config.sort_order == .asc)
        main.config.sort_order = .desc
    else
        main.config.sort_order = .asc;
    main.config.sort_col = col;
    sortDir(0);
}

fn keyInputSelection(ch: i32, idx: *usize, len: usize, page: u32) bool {
    switch (ch) {
        'j', c.KEY_DOWN => {
            if (idx.* + 1 < len) idx.* += 1;
        },
        'k', c.KEY_UP => {
            if (idx.* > 0) idx.* -= 1;
        },
        c.KEY_HOME => idx.* = 0,
        c.KEY_END, c.KEY_LL => idx.* = len -| 1,
        c.KEY_PPAGE => idx.* = idx.* -| page,
        c.KEY_NPAGE => idx.* = @min(len -| 1, idx.* + page),
        else => return false,
    }
    return true;
}

pub fn keyInput(io: std.Io, ch: i32) void {
    if (dir_loading > 0) return;

    defer current_view.save();

    if (message != null) {
        message = null;
        return;
    }

    switch (state) {
        .main => {}, // fallthrough
        .quit => return quit.keyInput(ch),
        .help => return help.keyInput(ch),
        .info => if (info.keyInput(io, ch)) return,
    }

    switch (ch) {
        'q' => if (main.config.confirm_quit) {
            state = .quit;
        } else ui.quit(),
        '?' => state = .help,
        'i' => if (dir_items.items.len > 0) info.set(dir_items.items[cursor_idx], .info),
        'r' => {
            if (main.config.binreader)
                message = &.{"Refresh feature is not available when reading from file."}
            else if (!main.config.can_refresh.? and main.config.imported)
                message = &.{ "Refresh feature disabled.", "Re-run with --enable-refresh to enable this option." }
            else if (!main.config.can_refresh.?)
                message = &.{"Directory refresh feature disabled."}
            else {
                main.state = .refresh;
                sink.global.sink = .mem;
                mem_sink.global.root = dir_parent;
            }
        },
        'b' => {
            if (!main.config.can_shell.?)
                message = &.{ "Shell feature disabled.", "Re-run with --enable-shell to enable this option." }
            else
                main.state = .shell;
        },
        'd' => {
            if (dir_items.items.len == 0) {} else if (main.config.binreader)
                message = &.{"File deletion is not available when reading from file."}
            else if (!main.config.can_delete.? and main.config.imported)
                message = &.{ "File deletion is disabled.", "Re-run with --enable-delete to enable this option." }
            else if (!main.config.can_delete.?)
                message = &.{"File deletion is disabled."}
            else if (dir_items.items[cursor_idx]) |e| {
                main.state = .delete;
                const next =
                    if (cursor_idx + 1 < dir_items.items.len)
                        dir_items.items[cursor_idx + 1]
                    else if (cursor_idx == 0)
                        null
                    else
                        dir_items.items[cursor_idx - 1];
                delete.setup(dir_parent, e, next);
            }
        },

        // Sort & filter settings
        'n' => sortToggle(.name, .asc),
        's' => sortToggle(if (main.config.show_blocks) .blocks else .size, .desc),
        'C' => sortToggle(.items, .desc),
        'M' => if (main.config.extended) sortToggle(.mtime, .desc),
        'e' => {
            main.config.show_hidden = !main.config.show_hidden;
            loadDir(io, 0);
            state = .main;
        },
        't' => {
            main.config.sort_dirsfirst = !main.config.sort_dirsfirst;
            sortDir(0);
        },
        'a' => {
            main.config.show_blocks = !main.config.show_blocks;
            if (main.config.show_blocks and main.config.sort_col == .size) {
                main.config.sort_col = .blocks;
                sortDir(0);
            }
            if (!main.config.show_blocks and main.config.sort_col == .blocks) {
                main.config.sort_col = .size;
                sortDir(0);
            }
        },

        // Navigation
        10, 'l', c.KEY_RIGHT => {
            if (dir_items.items.len == 0) {} else if (dir_items.items[cursor_idx]) |e| {
                if (e.dir()) |d| {
                    enterSub(io, d);
                    //dir_parent = d;
                    loadDir(io, 0);
                    state = .main;
                }
            } else if (dir_parents.items.len > 1) {
                enterParent(io);
                loadDir(io, 0);
                state = .main;
            }
        },
        'h', '<', c.KEY_BACKSPACE, c.KEY_LEFT => {
            if (dir_parents.items.len > 1) {
                //const h = dir_parent.entry.nameHash();
                enterParent(io);
                loadDir(io, 0);
                state = .main;
            }
        },

        // Display settings
        'c' => main.config.show_items = !main.config.show_items,
        'm' => if (main.config.extended) {
            main.config.show_mtime = !main.config.show_mtime;
        },
        'g' => {
            if (!main.config.show_graph and !main.config.show_percent) {
                main.config.show_graph = true;
                main.config.show_percent = false;
            } else if (main.config.show_graph and !main.config.show_percent) {
                main.config.show_graph = false;
                main.config.show_percent = true;
            } else if (!main.config.show_graph and main.config.show_percent) {
                main.config.show_graph = true;
                main.config.show_percent = true;
            } else if (main.config.show_graph and main.config.show_percent) {
                main.config.show_graph = false;
                main.config.show_percent = false;
            }
        },
        'u' => main.config.show_shared = switch (main.config.show_shared) {
            .off => .shared,
            .shared => .unique,
            .unique => .off,
        },

        else => _ = keyInputSelection(ch, &cursor_idx, dir_items.items.len, ui.rows -| 3),
    }
}
