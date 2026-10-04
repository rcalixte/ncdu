// SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");
const main = @import("main.zig");
const model = @import("model.zig");
const sink = @import("sink.zig");
const util = @import("util.zig");
const ui = @import("ui.zig");
const c = @import("c");

pub const global = struct {
    var fd: std.Io.File = undefined;
    var index: std.ArrayListUnmanaged(u8) = .empty;
    var file_off: u64 = 0;
    var lock: std.Io.Mutex = .init;
    var root_itemref: u64 = 0;
};

pub const SIGNATURE = "\xbfncduEX1";

pub const ItemKey = enum(u5) {
    // all items
    type = 0, // EType
    name = 1, // bytes
    prev = 2, // itemref
    // Only for non-specials
    asize = 3, // u64
    dsize = 4, // u64
    // Only for .dir
    dev = 5, //       u64        only if different from parent dir
    rderr = 6, //     bool       true = error reading directory list, false = error in sub-item, absent = no error
    cumasize = 7, //  u64
    cumdsize = 8, //  u64
    shrasize = 9, //  u64
    shrdsize = 10, // u64
    items = 11, //    u64
    sub = 12, //      itemref    only if dir is not empty
    // Only for .link
    ino = 13, //   u64
    nlink = 14, // u32
    // Extended mode
    uid = 15, //   u32
    gid = 16, //   u32
    mode = 17, //  u16
    mtime = 18, // u64
    _,
};

// Pessimistic upper bound on the encoded size of an item, excluding the name field.
// 2 bytes for map start/end, 11 per field (2 for the key, 9 for a full u64).
const MAX_ITEM_LEN = 2 + 11 * @typeInfo(ItemKey).@"enum".field_names.len;

pub const CborMajor = enum(u3) { pos, neg, bytes, text, array, map, tag, simple };

inline fn bigu16(v: u16) [2]u8 {
    return @bitCast(std.mem.nativeToBig(u16, v));
}
inline fn bigu32(v: u32) [4]u8 {
    return @bitCast(std.mem.nativeToBig(u32, v));
}
inline fn bigu64(v: u64) [8]u8 {
    return @bitCast(std.mem.nativeToBig(u64, v));
}

inline fn blockHeader(id: u4, len: u28) [4]u8 {
    return bigu32((@as(u32, id) << 28) | len);
}

inline fn cborByte(major: CborMajor, arg: u5) u8 {
    return (@as(u8, @backingInt(major)) << 5) | arg;
}

// (Uncompressed) data block size.
// Start with 64k, then use increasingly larger block sizes as the export file
// grows. This is both to stay within the block number limit of the index block
// and because, with a larger index block, the reader will end up using more
// memory anyway.
fn blockSize(num: u32) usize {
    //                        block size    uncompressed data in this num range
    //                 # mil      # KiB         # GiB
    return main.config.export_block_size orelse
        if (num < (1 << 20)) 64 << 10 //            64
        else if (num < (2 << 20)) 128 << 10 //     128
        else if (num < (4 << 20)) 256 << 10 //     512
        else if (num < (8 << 20)) 512 << 10 //    2048
        else if (num < (16 << 20)) 1024 << 10 //  8192
        else 2048 << 10; //                      32768
}

// Upper bound on the return value of blockSize()
// (config.export_block_size may be larger than the sizes listed above, let's
// stick with the maximum block size supported by the file format to be safe)
const MAX_BLOCK_SIZE: usize = 1 << 28;

pub const Thread = struct {
    buf: []u8 = undefined,
    off: usize = MAX_BLOCK_SIZE, // pretend we have a full block to trigger a flush() for the first write
    block_num: u32 = std.math.maxInt(u32),
    itemref: u64 = 0, // ref of item currently being written

    // unused, but kept around for easy debugging
    fn compressNone(in: []const u8, out: []u8) usize {
        @memcpy(out[0..in.len], in);
        return in.len;
    }

    fn compressZstd(io: std.Io, in: []const u8, out: []u8) usize {
        while (true) {
            const r = c.ZSTD_compress(out.ptr, out.len, in.ptr, in.len, main.config.complevel);
            if (c.ZSTD_isError(r) == 0) return r;
            ui.oom(io); // That *ought* to be the only reason the above call can fail.
        }
    }

    fn createBlock(t: *Thread, io: std.Io) std.ArrayListUnmanaged(u8) {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        if (t.block_num == std.math.maxInt(u32) or t.off == 0) return out;

        out.ensureTotalCapacityPrecise(main.allocator, 12 + @as(usize, @intCast(c.ZSTD_COMPRESSBOUND(@as(c_int, @intCast(t.off)))))) catch unreachable;
        out.items.len = out.capacity;
        const bodylen = compressZstd(io, t.buf[0..t.off], out.items[8..]);
        out.items.len = 12 + bodylen;

        out.items[0..4].* = blockHeader(0, @intCast(out.items.len));
        out.items[4..8].* = bigu32(t.block_num);
        out.items[8 + bodylen ..][0..4].* = blockHeader(0, @intCast(out.items.len));
        return out;
    }

    fn flush(t: *Thread, io: std.Io, expected_len: usize) void {
        @branchHint(.unlikely);
        var block = t.createBlock(io);
        defer block.deinit(main.allocator);

        global.lock.lock(io) catch {};
        defer global.lock.unlock(io);
        // This can only really happen when the root path exceeds our block size,
        // in which case we would probably have error'ed out earlier anyway.
        if (expected_len > t.buf.len) ui.die("Error writing data: path too long.\n", .{});

        if (block.items.len > 0) {
            if (global.file_off >= (1 << 40)) ui.die("Export data file has grown too large, please report a bug.\n", .{});
            global.index.items[4..][t.block_num * 8 ..][0..8].* = bigu64((global.file_off << 24) + block.items.len);
            global.file_off += block.items.len;
            global.fd.writeStreamingAll(io, block.items) catch |e|
                ui.die("Error writing to file: {s}.\n", .{ui.errorString(e)});
        }

        t.off = 0;
        t.block_num = @intCast((global.index.items.len - 4) / 8);
        const items: [8]u8 = @splat(0);
        global.index.appendSlice(main.allocator, &items) catch unreachable;
        if (global.index.items.len + 12 >= (1 << 28)) ui.die("Too many data blocks, please report a bug.\n", .{});

        const newsize = blockSize(t.block_num);
        if (t.buf.len != newsize) t.buf = main.allocator.realloc(t.buf, newsize) catch unreachable;
    }

    fn cborHead(t: *Thread, major: CborMajor, arg: u64) void {
        if (arg <= 23) {
            t.buf[t.off] = cborByte(major, @intCast(arg));
            t.off += 1;
        } else if (arg <= std.math.maxInt(u8)) {
            t.buf[t.off] = cborByte(major, 24);
            t.buf[t.off + 1] = @truncate(arg);
            t.off += 2;
        } else if (arg <= std.math.maxInt(u16)) {
            t.buf[t.off] = cborByte(major, 25);
            t.buf[t.off + 1 ..][0..2].* = bigu16(@intCast(arg));
            t.off += 3;
        } else if (arg <= std.math.maxInt(u32)) {
            t.buf[t.off] = cborByte(major, 26);
            t.buf[t.off + 1 ..][0..4].* = bigu32(@intCast(arg));
            t.off += 5;
        } else {
            t.buf[t.off] = cborByte(major, 27);
            t.buf[t.off + 1 ..][0..8].* = bigu64(arg);
            t.off += 9;
        }
    }

    fn cborIndef(t: *Thread, major: CborMajor) void {
        t.buf[t.off] = cborByte(major, 31);
        t.off += 1;
    }

    fn itemKey(t: *Thread, key: ItemKey) void {
        t.cborHead(.pos, @backingInt(key));
    }

    fn itemRef(t: *Thread, key: ItemKey, ref: ?u64) void {
        const r = ref orelse return;
        t.itemKey(key);
        // Full references compress like shit and most of the references point
        // into the same block, so optimize that case by using a negative
        // offset instead.
        if ((r >> 24) == t.block_num)
            t.cborHead(.neg, t.itemref - r - 1)
        else
            t.cborHead(.pos, r);
    }

    // Reserve space for a new item, write out the type, prev and name fields and return the itemref.
    fn itemStart(t: *Thread, io: std.Io, itype: model.EType, prev_item: ?u64, name: []const u8) u64 {
        const min_len = name.len + MAX_ITEM_LEN;
        if (t.off + min_len > t.buf.len) t.flush(io, min_len);

        t.itemref = (@as(u64, t.block_num) << 24) | t.off;
        t.cborIndef(.map);
        t.itemKey(.type);
        if (@backingInt(itype) >= 0)
            t.cborHead(.pos, @intCast(@backingInt(itype)))
        else
            t.cborHead(.neg, @intCast(-1 - @backingInt(itype)));
        t.itemKey(.name);
        t.cborHead(.bytes, name.len);
        @memcpy(t.buf[t.off..][0..name.len], name);
        t.off += name.len;
        t.itemRef(.prev, prev_item);
        return t.itemref;
    }

    fn itemExt(t: *Thread, stat: *const sink.Stat) void {
        if (!main.config.extended) return;
        if (stat.ext.pack.hasuid) {
            t.itemKey(.uid);
            t.cborHead(.pos, stat.ext.uid);
        }
        if (stat.ext.pack.hasgid) {
            t.itemKey(.gid);
            t.cborHead(.pos, stat.ext.gid);
        }
        if (stat.ext.pack.hasmode) {
            t.itemKey(.mode);
            t.cborHead(.pos, stat.ext.mode);
        }
        if (stat.ext.pack.hasmtime) {
            t.itemKey(.mtime);
            t.cborHead(.pos, stat.ext.mtime);
        }
    }

    fn itemEnd(t: *Thread) void {
        t.cborIndef(.simple);
    }
};

pub const Dir = struct {
    // TODO: When items are written out into blocks depth-first, parent dirs
    // will end up getting their items distributed over many blocks, which will
    // significantly slow down reading that dir's listing. It may be worth
    // buffering some items at the Dir level before flushing them out to the
    // Thread buffer.

    // The lock protects all of the below, and is necessary because final()
    // accesses the parent dir and may be called from other threads.
    // I'm not expecting much lock contention, but it's possible to turn
    // last_item into an atomic integer and other fields could be split up for
    // subdir use.
    lock: std.Io.Mutex = .init,
    last_sub: ?u64 = null,
    stat: sink.Stat,
    items: u64 = 0,
    size: u64 = 0,
    blocks: u64 = 0,
    err: bool = false,
    suberr: bool = false,
    shared_size: u64 = 0,
    shared_blocks: u64 = 0,
    inodes: Inodes = Inodes.init(main.allocator),

    const Inodes = std.AutoHashMap(u64, Inode);
    const Inode = struct {
        size: u64,
        blocks: u64,
        nlink: u32,
        nfound: u32,
    };

    pub fn addSpecial(d: *Dir, io: std.Io, t: *Thread, name: []const u8, sp: model.EType) void {
        d.lock.lock(io) catch {};
        defer d.lock.unlock(io);
        d.items += 1;
        if (sp == .err) d.suberr = true;
        d.last_sub = t.itemStart(io, sp, d.last_sub, name);
        t.itemEnd();
    }

    pub fn addStat(d: *Dir, io: std.Io, t: *Thread, name: []const u8, stat: *const sink.Stat) void {
        d.lock.lock(io) catch {};
        defer d.lock.unlock(io);
        d.items += 1;
        if (stat.etype != .link) {
            d.size +|= stat.size;
            d.blocks +|= stat.blocks;
        }
        d.last_sub = t.itemStart(io, stat.etype, d.last_sub, name);
        t.itemKey(.asize);
        t.cborHead(.pos, stat.size);
        t.itemKey(.dsize);
        t.cborHead(.pos, util.blocksToSize(stat.blocks));

        if (stat.etype == .link) {
            const lnk = d.inodes.getOrPut(stat.ino) catch unreachable;
            if (!lnk.found_existing) lnk.value_ptr.* = .{
                .size = stat.size,
                .blocks = stat.blocks,
                .nlink = stat.nlink,
                .nfound = 1,
            } else lnk.value_ptr.nfound += 1;
            t.itemKey(.ino);
            t.cborHead(.pos, stat.ino);
            t.itemKey(.nlink);
            t.cborHead(.pos, stat.nlink);
        }

        t.itemExt(stat);
        t.itemEnd();
    }

    pub fn addDir(d: *Dir, io: std.Io, stat: *const sink.Stat) Dir {
        d.lock.lock(io) catch {};
        defer d.lock.unlock(io);
        d.items += 1;
        d.size +|= stat.size;
        d.blocks +|= stat.blocks;
        return .{ .stat = stat.* };
    }

    pub fn setReadError(d: *Dir, io: std.Io) void {
        d.lock.lock(io) catch {};
        defer d.lock.unlock(io);
        d.err = true;
    }

    // XXX: older JSON exports did not include the nlink count and have
    // this field set to '0'.  We can deal with that when importing to
    // mem_sink, but the hardlink counting algorithm used here really does need
    // that information. Current code makes sure to count such links only once
    // per dir, but does not count them towards the shared_* fields. That
    // behavior is similar to ncdu 1.x, but the difference between memory
    // import and this file export might be surprising.
    fn countLinks(d: *Dir, parent: ?*Dir) void {
        var parent_new: u32 = 0;
        var it = d.inodes.iterator();
        while (it.next()) |kv| {
            const v = kv.value_ptr;
            d.size +|= v.size;
            d.blocks +|= v.blocks;
            if (v.nlink > 1 and v.nfound < v.nlink) {
                d.shared_size +|= v.size;
                d.shared_blocks +|= v.blocks;
            }

            const p = parent orelse continue;
            // All contained in this dir, no need to keep this entry around
            if (v.nlink > 0 and v.nfound >= v.nlink) {
                p.size +|= v.size;
                p.blocks +|= v.blocks;
                _ = d.inodes.remove(kv.key_ptr.*);
            } else if (!p.inodes.contains(kv.key_ptr.*))
                parent_new += 1;
        }

        // Merge remaining inodes into parent
        const p = parent orelse return;
        if (d.inodes.count() == 0) return;

        // If parent is empty, just transfer
        if (p.inodes.count() == 0) {
            p.inodes.deinit();
            p.inodes = d.inodes;
            d.inodes = Inodes.init(main.allocator); // So we can deinit() without affecting parent
            // Otherwise, merge
        } else {
            p.inodes.ensureUnusedCapacity(parent_new) catch unreachable;
            it = d.inodes.iterator();
            while (it.next()) |kv| {
                const v = kv.value_ptr;
                const plnk = p.inodes.getOrPutAssumeCapacity(kv.key_ptr.*);
                if (!plnk.found_existing)
                    plnk.value_ptr.* = v.*
                else
                    plnk.value_ptr.*.nfound += v.nfound;
            }
        }
    }

    pub fn final(d: *Dir, io: std.Io, t: *Thread, name: []const u8, parent: ?*Dir) void {
        if (parent) |p| p.lock.lock(io) catch {};
        defer if (parent) |p| p.lock.unlock(io);

        if (parent) |p| {
            // Different dev? Don't merge the 'inodes' sets, just count the
            // links here first so the sizes get added to the parent.
            if (p.stat.dev != d.stat.dev) d.countLinks(null);

            p.items += d.items;
            p.size +|= d.size;
            p.blocks +|= d.blocks;
            if (d.suberr or d.err) p.suberr = true;

            // Same dir, merge inodes
            if (p.stat.dev == d.stat.dev) d.countLinks(p);

            p.last_sub = t.itemStart(io, .dir, p.last_sub, name);
        } else {
            d.countLinks(null);
            global.root_itemref = t.itemStart(io, .dir, null, name);
        }
        d.inodes.deinit();

        t.itemKey(.asize);
        t.cborHead(.pos, d.stat.size);
        t.itemKey(.dsize);
        t.cborHead(.pos, util.blocksToSize(d.stat.blocks));
        if (parent == null or parent.?.stat.dev != d.stat.dev) {
            t.itemKey(.dev);
            t.cborHead(.pos, d.stat.dev);
        }
        if (d.err or d.suberr) {
            t.itemKey(.rderr);
            t.cborHead(.simple, if (d.err) 21 else 20);
        }
        t.itemKey(.cumasize);
        t.cborHead(.pos, d.size +| d.stat.size);
        t.itemKey(.cumdsize);
        t.cborHead(.pos, util.blocksToSize(d.blocks +| d.stat.blocks));
        if (d.shared_size > 0) {
            t.itemKey(.shrasize);
            t.cborHead(.pos, d.shared_size);
        }
        if (d.shared_blocks > 0) {
            t.itemKey(.shrdsize);
            t.cborHead(.pos, util.blocksToSize(d.shared_blocks));
        }
        t.itemKey(.items);
        t.cborHead(.pos, d.items);
        t.itemRef(.sub, d.last_sub);
        t.itemExt(&d.stat);
        t.itemEnd();
    }
};

pub fn createRoot(stat: *const sink.Stat, threads: []sink.Thread) Dir {
    for (threads) |*t| {
        t.sink.bin.buf = main.allocator.alloc(u8, blockSize(0)) catch unreachable;
    }

    return .{ .stat = stat.* };
}

pub fn done(io: std.Io, threads: []sink.Thread) void {
    for (threads) |*t| {
        t.sink.bin.flush(io, 0);
        main.allocator.free(t.sink.bin.buf);
    }

    const needle: [1]u8 = @splat(0);
    while (std.mem.endsWith(u8, global.index.items, &needle))
        global.index.shrinkRetainingCapacity(global.index.items.len - 8);
    global.index.appendSlice(main.allocator, &bigu64(global.root_itemref)) catch unreachable;
    global.index.appendSlice(main.allocator, &blockHeader(1, @intCast(global.index.items.len + 4))) catch unreachable;
    global.index.items[0..4].* = blockHeader(1, @intCast(global.index.items.len));
    global.fd.writeStreamingAll(io, global.index.items) catch |e|
        ui.die("Error writing to file: {s}.\n", .{ui.errorString(e)});
    global.index.clearAndFree(main.allocator);

    global.fd.close(io);
}

pub fn setupOutput(io: std.Io, fd: std.Io.File) void {
    global.fd = fd;
    fd.writeStreamingAll(io, SIGNATURE) catch |e|
        ui.die("Error writing to file: {s}.\n", .{ui.errorString(e)});
    global.file_off = 8;

    // Placeholder for the index block header.
    global.index.appendSlice(main.allocator, "aaaa") catch unreachable;
}
