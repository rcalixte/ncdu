// SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

// Ncurses wrappers and TUI helper functions.

const std = @import("std");
const main = @import("main.zig");
const util = @import("util.zig");
const c = @import("c");

pub var inited: bool = false;
pub var main_thread: std.Thread.Id = undefined;
pub var oom_threads = std.atomic.Value(usize).init(0);

pub var rows: u32 = undefined;
pub var cols: u32 = undefined;

pub fn die(comptime fmt: []const u8, args: anytype) noreturn {
    deinit();
    std.debug.print(fmt, args);
    std.process.exit(1);
}

pub fn quit() noreturn {
    deinit();
    std.process.exit(0);
}

// Should be called when malloc fails. Will show a message to the user, wait
// for a second and return to give it another try.
// Glitch: this function may be called while we're in the process of drawing
// the ncurses window, in which case the deinit/reinit will cause the already
// drawn part to be discarded. A redraw will fix that, but that tends to only
// happen after user input.
// Also, init() and other ncurses-related functions may have hidden allocation,
// no clue if ncurses will consistently report OOM, but we're not handling that
// right now.
pub fn oom(io: std.Io) void {
    @branchHint(.cold);
    if (main_thread == std.Thread.getCurrentId()) {
        const haveui = inited;
        deinit();
        std.debug.print("\x1b7\x1b[JOut of memory, trying again in 1 second. Hit Ctrl-C to abort.\x1b8", .{});
        io.sleep(.fromSeconds(1), .awake) catch {};
        if (haveui)
            init();
    } else {
        _ = oom_threads.fetchAdd(1, .monotonic);
        io.sleep(.fromSeconds(1), .awake) catch {};
        _ = oom_threads.fetchSub(1, .monotonic);
    }
}

// Dumb strerror() alternative for Zig file I/O, not complete.
// (Would be nicer if Zig just exposed errno so I could call strerror() directly)
pub fn errorString(e: anyerror) [:0]const u8 {
    return switch (e) {
        error.AccessDenied => "Access denied",
        error.DirNotEmpty => "Directory not empty",
        error.DiskQuota => "Disk quota exceeded",
        error.FileBusy => "File is busy",
        error.FileNotFound => "No such file or directory",
        error.FileSystem => "I/O error", // This one is shit, Zig uses this for both EIO and ELOOP in execve().
        error.FileTooBig => "File too big",
        error.InputOutput => "I/O error",
        error.InvalidExe => "Invalid executable",
        error.IsDir => "Is a directory",
        error.NameTooLong => "Filename too long",
        error.NoSpaceLeft => "No space left on device",
        error.NotDir => "Not a directory",
        error.OutOfMemory, error.SystemResources => "Out of memory",
        error.ProcessFdQuotaExceeded => "Process file descriptor limit exceeded",
        error.ReadOnlyFilesystem => "Read-only filesystem",
        error.SymlinkLoop => "Symlink loop",
        error.SystemFdQuotaExceeded => "System file descriptor limit exceeded",
        error.EndOfStream => "Unexpected end of file",
        else => @errorName(e),
    };
}

var to_utf8_buf: std.ArrayListUnmanaged(u8) = .empty;

fn toUtf8BadChar(ch: u8) bool {
    return switch (ch) {
        0...0x1F, 0x7F => true,
        else => false,
    };
}

// Utility function to convert a string to valid (mostly) printable UTF-8.
// Invalid codepoints will be encoded as '\x##' strings.
// Returns the given string if it's already valid, otherwise points to an
// internal buffer that will be invalidated on the next call.
// (Doesn't check for non-printable Unicode characters)
// (This program assumes that the console locale is UTF-8, but file names may not be)
pub fn toUtf8(in: [:0]const u8) [:0]const u8 {
    const hasBadChar = blk: {
        for (in) |ch| if (toUtf8BadChar(ch)) break :blk true;
        break :blk false;
    };
    if (!hasBadChar and std.unicode.utf8ValidateSlice(in)) return in;
    var i: usize = 0;
    to_utf8_buf.shrinkRetainingCapacity(0);
    while (i < in.len) {
        if (std.unicode.utf8ByteSequenceLength(in[i])) |cp_len| {
            if (!toUtf8BadChar(in[i]) and i + cp_len <= in.len) {
                if (std.unicode.utf8Decode(in[i .. i + cp_len])) |_| {
                    to_utf8_buf.appendSlice(main.allocator, in[i .. i + cp_len]) catch unreachable;
                    i += cp_len;
                    continue;
                } else |_| {}
            }
        } else |_| {}
        var aw: std.Io.Writer.Allocating = .init(main.allocator);
        aw.writer.print("\\x{X:0>2}", .{in[i]}) catch unreachable;
        i += 1;
    }
    return util.arrayListBufZ(&to_utf8_buf, main.allocator);
}

var shorten_buf: std.ArrayListUnmanaged(u8) = .empty;

// Shorten the given string to fit in the given number of columns.
// If the string is too long, only the prefix and suffix will be printed, with '...' in between.
// Input is assumed to be valid UTF-8.
// Return value points to the input string or to an internal buffer that is
// invalidated on a subsequent call.
pub fn shorten(in: [:0]const u8, max_width: u32) [:0]const u8 {
    if (max_width < 4) return "...";
    var total_width: u32 = 0;
    var prefix_width: u32 = 0;
    var prefix_end: u32 = 0;
    var prefix_done = false;
    var it = std.unicode.Utf8View.initUnchecked(in).iterator();
    while (it.nextCodepoint()) |cp| {
        // XXX: libc assumption: wchar_t is a Unicode point. True for most modern libcs?
        // (The "proper" way is to use mbtowc(), but I'd rather port the musl wcwidth implementation to Zig so that I *know* it'll be Unicode.
        // On the other hand, ncurses also use wcwidth() so that would cause duplicated code. Ugh)
        const cp_width_ = c.wcwidth(cp);
        const cp_width: u32 = @intCast(if (cp_width_ < 0) 0 else cp_width_);
        const cp_len = std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
        total_width += cp_width;
        if (!prefix_done and prefix_width + cp_width <= @divFloor(max_width - 1, 2) - 1) {
            prefix_width += cp_width;
            prefix_end += cp_len;
        } else prefix_done = true;
    }
    if (total_width <= max_width) return in;

    shorten_buf.shrinkRetainingCapacity(0);
    shorten_buf.appendSlice(main.allocator, in[0..prefix_end]) catch unreachable;
    shorten_buf.appendSlice(main.allocator, "...") catch unreachable;

    var start_width: u32 = prefix_width;
    var start_len: u32 = prefix_end;
    it = std.unicode.Utf8View.initUnchecked(in[prefix_end..]).iterator();
    while (it.nextCodepoint()) |cp| {
        const cp_width_ = c.wcwidth(cp);
        const cp_width: u32 = @intCast(if (cp_width_ < 0) 0 else cp_width_);
        const cp_len = std.unicode.utf8CodepointSequenceLength(cp) catch unreachable;
        start_width += cp_width;
        start_len += cp_len;
        if (total_width - start_width <= max_width - prefix_width - 3) {
            shorten_buf.appendSlice(main.allocator, in[start_len..]) catch unreachable;
            break;
        }
    }
    return util.arrayListBufZ(&shorten_buf, main.allocator);
}

fn shortenTest(in: [:0]const u8, max_width: u32, out: [:0]const u8) !void {
    try std.testing.expectEqualStrings(out, shorten(in, max_width));
}

test "shorten" {
    _ = c.setlocale(c.LC_ALL, ""); // libc wcwidth() may not recognize Unicode without this
    const t = shortenTest;
    try t("abcde", 3, "...");
    try t("abcde", 5, "abcde");
    try t("abcde", 4, "...e");
    try t("abcdefgh", 6, "a...gh");
    try t("abcdefgh", 7, "ab...gh");
    try t("ＡＢＣＤＥＦＧＨ", 16, "ＡＢＣＤＥＦＧＨ");
    try t("ＡＢＣＤＥＦＧＨ", 7, "Ａ...Ｈ");
    try t("ＡＢＣＤＥＦＧＨ", 8, "Ａ...Ｈ");
    try t("ＡＢＣＤＥＦＧＨ", 9, "Ａ...ＧＨ");
    try t("ＡaＢＣＤＥＦＧＨ", 8, "Ａ...Ｈ"); // could optimize this, but w/e
    try t("ＡＢＣＤＥＦＧaＨ", 8, "Ａ...aＨ");
    try t("ＡＢＣＤＥＦＧＨ", 15, "ＡＢＣ...ＦＧＨ");
    try t("❤︎a❤︎a❤︎a", 5, "❤︎...︎a"); // Variation selectors; not great, there's an additional U+FE0E before 'a'.
    try t("ą́ą́ą́ą́ą́ą́", 5, "ą́...̨́ą́"); // Combining marks, similarly bad.
}

const StyleAttr = struct { fg: i16, bg: i16, attr: u32 };
const StyleDef = struct {
    name: [:0]const u8,
    off: StyleAttr,
    dark: StyleAttr,
    darkbg: StyleAttr,
    fn style(self: *const @This()) StyleAttr {
        return switch (main.config.ui_color) {
            .off => self.off,
            .dark => self.dark,
            .darkbg => self.darkbg,
        };
    }
};

const styles = [_]StyleDef{
    .{
        .name = "default",
        .off = .{ .fg = -1, .bg = -1, .attr = 0 },
        .dark = .{ .fg = -1, .bg = -1, .attr = 0 },
        .darkbg = .{ .fg = c.COLOR_WHITE, .bg = c.COLOR_BLACK, .attr = 0 },
    },
    .{
        .name = "bold",
        .off = .{ .fg = -1, .bg = -1, .attr = c.A_BOLD },
        .dark = .{ .fg = -1, .bg = -1, .attr = c.A_BOLD },
        .darkbg = .{ .fg = c.COLOR_WHITE, .bg = c.COLOR_BLACK, .attr = c.A_BOLD },
    },
    .{
        .name = "bold_hd",
        .off = .{ .fg = -1, .bg = -1, .attr = c.A_BOLD | c.A_REVERSE },
        .dark = .{ .fg = c.COLOR_BLACK, .bg = c.COLOR_CYAN, .attr = c.A_BOLD },
        .darkbg = .{ .fg = c.COLOR_BLACK, .bg = c.COLOR_CYAN, .attr = c.A_BOLD },
    },
    .{
        .name = "box_title",
        .off = .{ .fg = -1, .bg = -1, .attr = c.A_BOLD },
        .dark = .{ .fg = c.COLOR_BLUE, .bg = -1, .attr = c.A_BOLD },
        .darkbg = .{ .fg = c.COLOR_BLUE, .bg = c.COLOR_BLACK, .attr = c.A_BOLD },
    },
    .{
        .name = "hd", // header + footer
        .off = .{ .fg = -1, .bg = -1, .attr = c.A_REVERSE },
        .dark = .{ .fg = c.COLOR_BLACK, .bg = c.COLOR_CYAN, .attr = 0 },
        .darkbg = .{ .fg = c.COLOR_BLACK, .bg = c.COLOR_CYAN, .attr = 0 },
    },
    .{
        .name = "sel",
        .off = .{ .fg = -1, .bg = -1, .attr = c.A_REVERSE },
        .dark = .{ .fg = c.COLOR_WHITE, .bg = c.COLOR_GREEN, .attr = c.A_BOLD },
        .darkbg = .{ .fg = c.COLOR_WHITE, .bg = c.COLOR_GREEN, .attr = c.A_BOLD },
    },
    .{
        .name = "num",
        .off = .{ .fg = -1, .bg = -1, .attr = 0 },
        .dark = .{ .fg = c.COLOR_YELLOW, .bg = -1, .attr = c.A_BOLD },
        .darkbg = .{ .fg = c.COLOR_YELLOW, .bg = c.COLOR_BLACK, .attr = c.A_BOLD },
    },
    .{
        .name = "num_hd",
        .off = .{ .fg = -1, .bg = -1, .attr = c.A_REVERSE },
        .dark = .{ .fg = c.COLOR_YELLOW, .bg = c.COLOR_CYAN, .attr = c.A_BOLD },
        .darkbg = .{ .fg = c.COLOR_YELLOW, .bg = c.COLOR_CYAN, .attr = c.A_BOLD },
    },
    .{
        .name = "num_sel",
        .off = .{ .fg = -1, .bg = -1, .attr = c.A_REVERSE },
        .dark = .{ .fg = c.COLOR_YELLOW, .bg = c.COLOR_GREEN, .attr = c.A_BOLD },
        .darkbg = .{ .fg = c.COLOR_YELLOW, .bg = c.COLOR_GREEN, .attr = c.A_BOLD },
    },
    .{
        .name = "key",
        .off = .{ .fg = -1, .bg = -1, .attr = c.A_BOLD },
        .dark = .{ .fg = c.COLOR_YELLOW, .bg = -1, .attr = c.A_BOLD },
        .darkbg = .{ .fg = c.COLOR_YELLOW, .bg = c.COLOR_BLACK, .attr = c.A_BOLD },
    },
    .{
        .name = "key_hd",
        .off = .{ .fg = -1, .bg = -1, .attr = c.A_BOLD | c.A_REVERSE },
        .dark = .{ .fg = c.COLOR_YELLOW, .bg = c.COLOR_CYAN, .attr = c.A_BOLD },
        .darkbg = .{ .fg = c.COLOR_YELLOW, .bg = c.COLOR_CYAN, .attr = c.A_BOLD },
    },
    .{
        .name = "dir",
        .off = .{ .fg = -1, .bg = -1, .attr = 0 },
        .dark = .{ .fg = c.COLOR_BLUE, .bg = -1, .attr = c.A_BOLD },
        .darkbg = .{ .fg = c.COLOR_BLUE, .bg = c.COLOR_BLACK, .attr = c.A_BOLD },
    },
    .{
        .name = "dir_sel",
        .off = .{ .fg = -1, .bg = -1, .attr = c.A_REVERSE },
        .dark = .{ .fg = c.COLOR_BLUE, .bg = c.COLOR_GREEN, .attr = c.A_BOLD },
        .darkbg = .{ .fg = c.COLOR_BLUE, .bg = c.COLOR_GREEN, .attr = c.A_BOLD },
    },
    .{
        .name = "flag",
        .off = .{ .fg = -1, .bg = -1, .attr = 0 },
        .dark = .{ .fg = c.COLOR_RED, .bg = -1, .attr = 0 },
        .darkbg = .{ .fg = c.COLOR_RED, .bg = c.COLOR_BLACK, .attr = 0 },
    },
    .{
        .name = "flag_sel",
        .off = .{ .fg = -1, .bg = -1, .attr = c.A_REVERSE },
        .dark = .{ .fg = c.COLOR_RED, .bg = c.COLOR_GREEN, .attr = 0 },
        .darkbg = .{ .fg = c.COLOR_RED, .bg = c.COLOR_GREEN, .attr = 0 },
    },
    .{
        .name = "graph",
        .off = .{ .fg = -1, .bg = -1, .attr = 0 },
        .dark = .{ .fg = c.COLOR_MAGENTA, .bg = -1, .attr = 0 },
        .darkbg = .{ .fg = c.COLOR_MAGENTA, .bg = c.COLOR_BLACK, .attr = 0 },
    },
    .{
        .name = "graph_sel",
        .off = .{ .fg = -1, .bg = -1, .attr = c.A_REVERSE },
        .dark = .{ .fg = c.COLOR_MAGENTA, .bg = c.COLOR_GREEN, .attr = 0 },
        .darkbg = .{ .fg = c.COLOR_MAGENTA, .bg = c.COLOR_GREEN, .attr = 0 },
    },
};

pub const Style = lbl: {
    var names: [styles.len][]const u8 = undefined;
    var values: [styles.len]u8 = undefined;
    for (styles, 0..) |s, i| {
        names[i] = s.name;
        values[i] = i;
    }

    break :lbl @Enum(
        u8,
        .exhaustive,
        &names,
        &values,
    );
};

const ui = @This();

pub const Bg = enum {
    default,
    hd,
    sel,

    // Set the style to the selected bg combined with the given fg.
    pub fn fg(self: @This(), s: Style) void {
        ui.style(switch (self) {
            .default => s,
            .hd => switch (s) {
                .default => Style.hd,
                .key => Style.key_hd,
                .num => Style.num_hd,
                else => unreachable,
            },
            .sel => switch (s) {
                .default => Style.sel,
                .num => Style.num_sel,
                .dir => Style.dir_sel,
                .flag => Style.flag_sel,
                .graph => Style.graph_sel,
                else => unreachable,
            },
        });
    }
};

fn updateSize() void {
    // getmax[yx] macros are marked as "legacy", but Zig can't deal with the "proper" getmaxyx macro.
    rows = @intCast(c.getmaxy(c.stdscr));
    cols = @intCast(c.getmaxx(c.stdscr));
}

fn clearScr() void {
    // Send a "clear from cursor to end of screen" instruction, to clear a
    // potential line left behind from scanning in -1 mode.
    std.debug.print("\x1b[J", .{});
}

pub fn init() void {
    if (inited) return;
    clearScr();
    if (main.config.nc_tty) {
        const tty = std.c.fopen("/dev/tty", "r+");
        if (tty == null) die("Error opening /dev/tty: {s}.\n", .{@tagName(std.posix.errno(-1))});
        const term = c.newterm(null, @ptrCast(tty), @ptrCast(tty));
        if (term == null) die("Error initializing ncurses.\n", .{});
        _ = c.set_term(term);
    } else {
        if (c.initscr() == null) die("Error initializing ncurses.\n", .{});
    }
    updateSize();
    _ = c.cbreak();
    _ = c.noecho();
    _ = c.curs_set(0);
    _ = c.keypad(c.stdscr, true);

    _ = c.start_color();
    _ = c.use_default_colors();
    for (styles, 0..) |s, i| _ = c.init_pair(@as(i16, @intCast(i + 1)), s.style().fg, s.style().bg);
    _ = c.bkgd(@intCast(c.COLOR_PAIR(@intFromEnum(Style.default) + 1)));
    inited = true;
}

pub fn deinit() void {
    if (!inited) {
        clearScr();
        return;
    }
    _ = c.erase();
    _ = c.refresh();
    _ = c.endwin();
    inited = false;
}

pub fn style(s: Style) void {
    _ = c.attr_set(styles[@intFromEnum(s)].style().attr, @intFromEnum(s) + 1, null);
}

pub fn move(y: u32, x: u32) void {
    _ = c.move(@as(i32, @intCast(y)), @as(i32, @intCast(x)));
}

// Wraps to the next line if the text overflows, not sure how to disable that.
// (Well, addchstr() does that, but not entirely sure I want to go that way.
// Does that even work with UTF-8? Or do I really need to go wchar madness?)
pub fn addstr(s: [:0]const u8) void {
    _ = c.addstr(s.ptr);
}

// Not to be used for strings that may end up >256 bytes.
pub fn addprint(comptime fmt: []const u8, args: anytype) void {
    var buf: [256:0]u8 = undefined;
    const s = std.fmt.bufPrintSentinel(&buf, fmt, args, 0) catch unreachable;
    addstr(s);
}

pub fn addch(ch: c.chtype) void {
    _ = c.addch(ch);
}

// Format an integer to a human-readable size string.
//   num() = "###.#"
//   unit = " XB" or " XiB"
// Concatenated, these take 8 columns in SI mode or 9 otherwise.
pub const FmtSize = struct {
    buf: [5:0]u8,
    unit: [:0]const u8,

    fn init(u: [:0]const u8, n: u64, mul: u64, div: u64) FmtSize {
        return .{
            .unit = u,
            .buf = util.fmt5dec(@intCast(((n * mul) +| (div / 2)) / div)),
        };
    }

    pub fn fmt(v: u64) FmtSize {
        if (main.config.si) {
            if (v < 1000)
                return FmtSize.init("  B", v, 10, 1)
            else if (v < 999_950)
                return FmtSize.init(" kB", v, 1, 100)
            else if (v < 999_950_000)
                return FmtSize.init(" MB", v, 1, 100_000)
            else if (v < 999_950_000_000)
                return FmtSize.init(" GB", v, 1, 100_000_000)
            else if (v < 999_950_000_000_000)
                return FmtSize.init(" TB", v, 1, 100_000_000_000)
            else if (v < 999_950_000_000_000_000)
                return FmtSize.init(" PB", v, 1, 100_000_000_000_000)
            else
                return FmtSize.init(" EB", v, 1, 100_000_000_000_000_000);
        } else {
            // Cutoff values are obtained by calculating 999.949999999999999999999999 * div with an infinite-precision calculator.
            // (Admittedly, this precision is silly)
            if (v < 1000)
                return FmtSize.init("   B", v, 10, 1)
            else if (v < 1023949)
                return FmtSize.init(" KiB", v, 10, 1 << 10)
            else if (v < 1048523572)
                return FmtSize.init(" MiB", v, 10, 1 << 20)
            else if (v < 1073688136909)
                return FmtSize.init(" GiB", v, 10, 1 << 30)
            else if (v < 1099456652194612)
                return FmtSize.init(" TiB", v, 10, 1 << 40)
            else if (v < 1125843611847281869)
                return FmtSize.init(" PiB", v, 10, 1 << 50)
            else
                return FmtSize.init(" EiB", v, 1, (1 << 60) / 10);
        }
    }

    pub fn num(self: *const FmtSize) [:0]const u8 {
        return &self.buf;
    }

    fn testEql(self: FmtSize, exp: []const u8) !void {
        var buf: [10]u8 = undefined;
        try std.testing.expectEqualStrings(exp, try std.fmt.bufPrint(&buf, "{s}{s}", .{ self.num(), self.unit }));
    }
};

test "fmtsize" {
    main.config.si = true;
    try FmtSize.fmt(0).testEql("  0.0  B");
    try FmtSize.fmt(999).testEql("999.0  B");
    try FmtSize.fmt(1000).testEql("  1.0 kB");
    try FmtSize.fmt(1049).testEql("  1.0 kB");
    try FmtSize.fmt(1050).testEql("  1.1 kB");
    try FmtSize.fmt(999_899).testEql("999.9 kB");
    try FmtSize.fmt(999_949).testEql("999.9 kB");
    try FmtSize.fmt(999_950).testEql("  1.0 MB");
    try FmtSize.fmt(1000_000).testEql("  1.0 MB");
    try FmtSize.fmt(999_850_009).testEql("999.9 MB");
    try FmtSize.fmt(999_899_999).testEql("999.9 MB");
    try FmtSize.fmt(999_900_000).testEql("999.9 MB");
    try FmtSize.fmt(999_949_999).testEql("999.9 MB");
    try FmtSize.fmt(999_950_000).testEql("  1.0 GB");
    try FmtSize.fmt(999_999_999).testEql("  1.0 GB");
    try FmtSize.fmt(std.math.maxInt(u64)).testEql(" 18.4 EB");

    main.config.si = false;
    try FmtSize.fmt(0).testEql("  0.0   B");
    try FmtSize.fmt(999).testEql("999.0   B");
    try FmtSize.fmt(1000).testEql("  1.0 KiB");
    try FmtSize.fmt(1024).testEql("  1.0 KiB");
    try FmtSize.fmt(102400).testEql("100.0 KiB");
    try FmtSize.fmt(1023898).testEql("999.9 KiB");
    try FmtSize.fmt(1023949).testEql("  1.0 MiB");
    try FmtSize.fmt(1048523571).testEql("999.9 MiB");
    try FmtSize.fmt(1048523572).testEql("  1.0 GiB");
    try FmtSize.fmt(1073688136908).testEql("999.9 GiB");
    try FmtSize.fmt(1073688136909).testEql("  1.0 TiB");
    try FmtSize.fmt(1099456652194611).testEql("999.9 TiB");
    try FmtSize.fmt(1099456652194612).testEql("  1.0 PiB");
    try FmtSize.fmt(1125843611847281868).testEql("999.9 PiB");
    try FmtSize.fmt(1125843611847281869).testEql("  1.0 EiB");
    try FmtSize.fmt(std.math.maxInt(u64)).testEql(" 16.0 EiB");
}

// Print a formatted human-readable size string onto the given background.
pub fn addsize(bg: Bg, v: u64) void {
    const r = FmtSize.fmt(v);
    bg.fg(.num);
    addstr(r.num());
    bg.fg(.default);
    addstr(r.unit);
}

// Print a full decimal number with thousand separators.
// Max: 18,446,744,073,709,551,615 -> 26 columns
// (Assuming thousands_sep takes a single column)
pub fn addnum(bg: Bg, v: u64) void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
    var f: [64:0]u8 = undefined;
    var i: usize = 0;
    for (s, 0..) |digit, n| {
        if (n != 0 and (s.len - n) % 3 == 0) {
            for (main.config.thousands_sep) |ch| {
                f[i] = ch;
                i += 1;
            }
        }
        f[i] = digit;
        i += 1;
    }
    f[i] = 0;
    bg.fg(.num);
    addstr(&f);
    bg.fg(.default);
}

// Print a file mode, takes 10 columns
pub fn addmode(mode: u32) void {
    addch(switch (mode & std.posix.S.IFMT) {
        std.posix.S.IFDIR => 'd',
        std.posix.S.IFREG => '-',
        std.posix.S.IFLNK => 'l',
        std.posix.S.IFIFO => 'p',
        std.posix.S.IFSOCK => 's',
        std.posix.S.IFCHR => 'c',
        std.posix.S.IFBLK => 'b',
        else => '?',
    });
    addch(if (mode & 0o400 > 0) 'r' else '-');
    addch(if (mode & 0o200 > 0) 'w' else '-');
    addch(if (mode & 0o4000 > 0) 's' else if (mode & 0o100 > 0) @as(u7, 'x') else '-');
    addch(if (mode & 0o040 > 0) 'r' else '-');
    addch(if (mode & 0o020 > 0) 'w' else '-');
    addch(if (mode & 0o2000 > 0) 's' else if (mode & 0o010 > 0) @as(u7, 'x') else '-');
    addch(if (mode & 0o004 > 0) 'r' else '-');
    addch(if (mode & 0o002 > 0) 'w' else '-');
    addch(if (mode & 0o1000 > 0) (if (std.posix.S.ISDIR(mode)) @as(u7, 't') else 'T') else if (mode & 0o001 > 0) @as(u7, 'x') else '-');
}

// Print a timestamp, takes 25 columns
pub fn addts(bg: Bg, ts: u64) void {
    const t = util.castClamp(c.time_t, ts);
    var buf: [32:0]u8 = undefined;
    const len = c.strftime(&buf, buf.len, "%Y-%m-%d %H:%M:%S %z", c.localtime(&t));
    if (len > 0) {
        bg.fg(.num);
        ui.addstr(buf[0..len :0]);
    } else {
        bg.fg(.default);
        ui.addstr("            invalid mtime");
    }
}

pub fn hline(ch: c.chtype, len: u32) void {
    _ = c.hline(ch, @as(i32, @intCast(len)));
}

// Draws a bordered box in the center of the screen.
pub const Box = struct {
    start_row: u32,
    start_col: u32,

    const Self = @This();

    pub fn create(height: u32, width: u32, title: [:0]const u8) Self {
        const s = Self{
            .start_row = (rows >> 1) -| (height >> 1),
            .start_col = (cols >> 1) -| (width >> 1),
        };
        style(.default);
        if (width < 6 or height < 3) return s;

        const acs_map = @extern(*[128]c.chtype, .{ .name = "acs_map" });
        const ulcorner = acs_map['l'];
        const llcorner = acs_map['m'];
        const urcorner = acs_map['k'];
        const lrcorner = acs_map['j'];
        const acs_hline = acs_map['q'];
        const acs_vline = acs_map['x'];

        var i: u32 = 0;
        while (i < height) : (i += 1) {
            s.move(i, 0);
            addch(if (i == 0) ulcorner else if (i == height - 1) llcorner else acs_vline);
            hline(if (i == 0 or i == height - 1) acs_hline else ' ', width - 2);
            s.move(i, width - 1);
            addch(if (i == 0) urcorner else if (i == height - 1) lrcorner else acs_vline);
        }

        s.move(0, 3);
        style(.box_title);
        addch(' ');
        addstr(title);
        addch(' ');
        style(.default);
        return s;
    }

    pub fn tab(s: Self, col: u32, sel: bool, num: u3, label: [:0]const u8) void {
        const bg: Bg = if (sel) .hd else .default;
        s.move(0, col);
        bg.fg(.key);
        addch('0' + @as(u8, num));
        bg.fg(.default);
        addch(':');
        addstr(label);
        style(.default);
    }

    // Move the global cursor to the given coordinates inside the box.
    pub fn move(s: Self, row: u32, col: u32) void {
        ui.move(s.start_row + row, s.start_col + col);
    }
};

// Returns 0 if no key was pressed in non-blocking mode.
// Returns -1 if it was KEY_RESIZE, requiring a redraw of the screen.
pub fn getch(io: std.Io, block: bool) i32 {
    _ = c.nodelay(c.stdscr, !block);
    // getch() has a bad tendency to not set a sensible errno when it returns ERR.
    // In non-blocking mode, we can only assume that ERR means "no input yet".
    // In blocking mode, give it 100 tries with a 10ms delay in between,
    // then just give up and die to avoid an infinite loop and unresponsive program.
    for (0..100) |_| {
        const ch = c.getch();
        if (ch == c.KEY_RESIZE) {
            updateSize();
            return -1;
        }
        if (ch == c.ERR) {
            if (!block) return 0;
            std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
            continue;
        }
        return ch;
    }
    die("Error reading keyboard input, assuming TTY has been lost.\n(Potentially nonsensical error message: {s})\n", .{@tagName(std.posix.errno(-1))});
}

fn waitInput(io: std.Io) void {
    var buf: [512]u8 = undefined;
    var rd = std.Io.File.stdin().reader(io, &buf);
    _ = rd.interface.discardDelimiterExclusive('\n') catch unreachable;
}

pub fn runCmd(io: std.Io, cmd: []const []const u8, cwd: ?[]const u8, env: *std.process.Environ.Map, reporterr: bool) void {
    deinit();
    defer init();

    // NCDU_LEVEL can only count to 9, keeps the implementation simple.
    if (env.get("NCDU_LEVEL")) |l|
        env.put("NCDU_LEVEL", if (l.len == 0) "1" else switch (l[0]) {
            '0'...'8' => |d| &[1]u8{d + 1},
            '9' => "9",
            else => "1",
        }) catch unreachable
    else
        env.put("NCDU_LEVEL", "1") catch unreachable;

    var child = std.process.spawn(io, .{
        .argv = cmd,
        .cwd = if (cwd) |p| .{ .path = p } else .inherit,
        .environ_map = env,
    }) catch |e| {
        const out = std.fmt.allocPrint(main.allocator, "Error running command: {s}\n\nPress enter to continue.\n", .{ui.errorString(e)}) catch @panic("Failed to print error");
        defer main.allocator.free(out);
        std.Io.File.stdout().writeStreamingAll(io, out) catch @panic("Failed to write error");
        waitInput(io);
        return;
    };

    const term = child.wait(io) catch @panic("Failed to wait for command");

    const n = switch (term) {
        .exited => "exited",
        .signal => "signal",
        .stopped => "stopped",
        .unknown => "unknown",
    };
    const v = switch (term) {
        .exited => |v| v,
        .signal, .stopped => |s| @intFromEnum(s),
        .unknown => |v| v,
    };
    if (term != .exited or (reporterr and v != 0)) {
        const out = std.fmt.allocPrint(main.allocator, "\nCommand returned with {s} code {}.\nPress enter to continue.\n", .{ n, v }) catch @panic("Failed to print error message");
        defer main.allocator.free(out);
        std.Io.File.stdout().writeStreamingAll(io, out) catch @panic("Failed to write error message");
        waitInput(io);
    }
}
