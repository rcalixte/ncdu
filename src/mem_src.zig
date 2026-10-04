// SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");
const main = @import("main.zig");
const model = @import("model.zig");
const sink = @import("sink.zig");

// Emit the memory tree to the sink in depth-first order from a single thread,
// suitable for JSON export.

fn toStat(e: *model.Entry) sink.Stat {
    const el = e.link();
    return sink.Stat{
        .etype = e.pack.etype,
        .blocks = e.pack.blocks,
        .size = e.size,
        .dev = if (e.dir()) |d|
            model.devices.list.items[d.pack.dev]
        else if (el) |l|
            model.devices.list.items[l.parent.pack.dev]
        else
            undefined,
        .ino = if (el) |l| l.ino else undefined,
        .nlink = if (el) |l| l.pack.nlink else 1,
        .ext = if (e.ext()) |x| x.* else .{},
    };
}

const Ctx = struct {
    sink: *sink.Thread,
    stat: sink.Stat,
};

fn rec(io: std.Io, ctx: *Ctx, dir: *sink.Dir, entry: *model.Entry) void {
    if ((ctx.sink.files_seen.load(.monotonic) & 65) == 0)
        main.handleEvent(io, false, false);

    ctx.stat = toStat(entry);
    switch (entry.pack.etype) {
        .dir => {
            const d = entry.dir().?;
            var ndir = dir.addDir(io, ctx.sink, entry.name(), &ctx.stat);
            ctx.sink.setDir(io, ndir);
            if (d.pack.err) ndir.setReadError(io, ctx.sink);
            var it = d.sub.ptr;
            while (it) |e| : (it = e.next.ptr) rec(io, ctx, ndir, e);
            ctx.sink.setDir(io, dir);
            ndir.unref(io, ctx.sink);
        },
        .reg, .nonreg, .link => dir.addStat(io, ctx.sink, entry.name(), &ctx.stat),
        else => dir.addSpecial(io, ctx.sink, entry.name(), entry.pack.etype),
    }
}

pub fn run(io: std.Io, d: *model.Dir) void {
    const sink_threads = sink.createThreads(1);

    var ctx: Ctx = .{
        .sink = &sink_threads[0],
        .stat = toStat(&d.entry),
    };
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    d.fmtPath(main.allocator, true, &buf);
    const root = sink.createRoot(io, buf.items, &ctx.stat);
    buf.deinit(main.allocator);

    var it = d.sub.ptr;
    while (it) |e| : (it = e.next.ptr) rec(io, &ctx, root, e);

    root.unref(io, ctx.sink);
    sink.done(io);
}
