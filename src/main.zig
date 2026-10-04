// SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

pub const program_version = "2.12";

const std = @import("std");
const model = @import("model.zig");
const scan = @import("scan.zig");
const json_import = @import("json_import.zig");
const json_export = @import("json_export.zig");
const bin_export = @import("bin_export.zig");
const bin_reader = @import("bin_reader.zig");
const sink = @import("sink.zig");
const mem_src = @import("mem_src.zig");
const mem_sink = @import("mem_sink.zig");
const ui = @import("ui.zig");
const browser = @import("browser.zig");
const delete = @import("delete.zig");
const util = @import("util.zig");
const exclude = @import("exclude.zig");
const c = @import("c");

test "imports" {
    _ = model;
    _ = scan;
    _ = json_import;
    _ = json_export;
    _ = bin_export;
    _ = bin_reader;
    _ = sink;
    _ = mem_src;
    _ = mem_sink;
    _ = ui;
    _ = browser;
    _ = delete;
    _ = util;
    _ = exclude;
}

var _io: std.Io = undefined;

// "Custom" allocator that wraps the libc allocator and calls ui.oom() on error.
// This allocator never returns an error, it either succeeds or causes ncdu to quit.
// (Which means you'll find a lot of "catch unreachable" sprinkled through the code,
// they look scarier than they are)
fn wrapAlloc(_: *anyopaque, len: usize, ptr_alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
    while (true) {
        if (std.heap.c_allocator.vtable.alloc(undefined, len, ptr_alignment, return_address)) |r|
            return r
        else {}
        ui.oom(_io);
    }
}

pub const allocator = std.mem.Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = wrapAlloc,
        // AFAIK, all uses of resize() to grow an allocation will fall back to alloc() on failure.
        .resize = std.heap.c_allocator.vtable.resize,
        .remap = std.heap.c_allocator.vtable.remap,
        .free = std.heap.c_allocator.vtable.free,
    },
};

// Custom panic impl to reset the terminal before spewing out an error message.
pub const panic = std.debug.FullPanic(struct {
    pub fn panicFn(msg: []const u8, first_trace_addr: ?usize) noreturn {
        @branchHint(.cold);
        ui.deinit();
        std.debug.defaultPanic(msg, first_trace_addr);
    }
}.panicFn);

pub const config = struct {
    pub const SortCol = enum { name, blocks, size, items, mtime };
    pub const SortOrder = enum { asc, desc };

    pub var same_fs: bool = false;
    pub var extended: bool = false;
    pub var follow_symlinks: bool = false;
    pub var exclude_caches: bool = false;
    pub var exclude_kernfs: bool = false;
    pub var threads: usize = 1;
    pub var complevel: u8 = 4;
    pub var compress: bool = false;
    pub var export_block_size: ?usize = null;

    pub var update_delay: u64 = 100 * std.time.ns_per_ms;
    pub var scan_ui: ?enum { none, line, full } = null;
    pub var si: bool = false;
    pub var nc_tty: bool = false;
    pub var ui_color: enum { off, dark, darkbg } = .off;
    pub var thousands_sep: []const u8 = ",";

    pub var show_hidden: bool = true;
    pub var show_blocks: bool = true;
    pub var show_shared: enum { off, shared, unique } = .shared;
    pub var show_items: bool = false;
    pub var show_mtime: bool = false;
    pub var show_graph: bool = true;
    pub var show_percent: bool = false;
    pub var graph_style: enum { hash, half, eighth } = .hash;
    pub var sort_col: SortCol = .blocks;
    pub var sort_order: SortOrder = .desc;
    pub var sort_dirsfirst: bool = false;
    pub var sort_natural: bool = true;

    pub var imported: bool = false;
    pub var binreader: bool = false;
    pub var can_delete: ?bool = null;
    pub var can_shell: ?bool = null;
    pub var can_refresh: ?bool = null;
    pub var confirm_quit: bool = false;
    pub var confirm_delete: bool = true;
    pub var ignore_delete_errors: bool = false;
    pub var delete_command: [:0]const u8 = "";
};

pub var state: enum { scan, browse, refresh, shell, delete } = .scan;

const stdin = std.Io.File.stdin();
const stdout = std.Io.File.stdout();

// Simple generic argument parser, supports getopt_long() style arguments.
const Args = struct {
    lst: []const [:0]const u8,
    short: ?[:0]const u8 = null, // Remainder after a short option, e.g. -x<stuff> (which may be either more short options or an argument)
    last: ?[]const u8 = null,
    last_arg: ?[:0]const u8 = null, // In the case of --option=<arg>
    shortbuf: [2]u8 = undefined,
    argsep: bool = false,
    ignerror: bool = false,

    const Self = @This();
    const Option = struct {
        opt: bool,
        val: []const u8,

        fn is(self: @This(), cmp: []const u8) bool {
            return self.opt and std.mem.eql(u8, self.val, cmp);
        }
    };

    fn init(lst: []const [:0]const u8) Self {
        return Self{ .lst = lst };
    }

    fn pop(self: *Self) ?[:0]const u8 {
        if (self.lst.len == 0) return null;
        defer self.lst = self.lst[1..];
        return self.lst[0];
    }

    fn shortopt(self: *Self, s: [:0]const u8) Option {
        self.shortbuf[0] = '-';
        self.shortbuf[1] = s[0];
        self.short = if (s.len > 1) s[1.. :0] else null;
        self.last = &self.shortbuf;
        return .{ .opt = true, .val = &self.shortbuf };
    }

    pub fn die(self: *const Self, comptime msg: []const u8, args: anytype) !noreturn {
        if (self.ignerror) return error.InvalidArg;
        ui.die(msg, args);
    }

    /// Return the next option or positional argument.
    /// 'opt' indicates whether it's an option or positional argument,
    /// 'val' will be either -x, --something or the argument.
    pub fn next(self: *Self) !?Option {
        if (self.last_arg != null) try self.die("Option '{s}' does not expect an argument.\n", .{self.last.?});
        if (self.short) |s| return self.shortopt(s);
        const val = self.pop() orelse return null;
        if (self.argsep or val.len == 0 or val[0] != '-') return Option{ .opt = false, .val = val };
        if (val.len == 1) try self.die("Invalid option '-'.\n", .{});
        if (val.len == 2 and val[1] == '-') {
            self.argsep = true;
            return self.next();
        }
        if (val[1] == '-') {
            if (std.mem.indexOfScalar(u8, val, '=')) |sep| {
                if (sep == 2) try self.die("Invalid option '{s}'.\n", .{val});
                self.last_arg = val[sep + 1 .. :0];
                self.last = val[0..sep];
                return Option{ .opt = true, .val = self.last.? };
            }
            self.last = val;
            return Option{ .opt = true, .val = val };
        }
        return self.shortopt(val[1.. :0]);
    }

    /// Returns the argument given to the last returned option. Dies with an error if no argument is provided.
    pub fn arg(self: *Self) ![:0]const u8 {
        if (self.short) |a| {
            defer self.short = null;
            return a;
        }
        if (self.last_arg) |a| {
            defer self.last_arg = null;
            return a;
        }
        if (self.pop()) |o| return o;
        try self.die("Option '{s}' requires an argument.\n", .{self.last.?});
    }
};

fn argConfig(io: std.Io, args: *Args, opt: Args.Option, environ: std.process.Environ, infile: bool) !void {
    if (opt.is("-q") or opt.is("--slow-ui-updates"))
        config.update_delay = 2 * std.time.ns_per_s
    else if (opt.is("--fast-ui-updates"))
        config.update_delay = 100 * std.time.ns_per_ms
    else if (opt.is("-x") or opt.is("--one-file-system"))
        config.same_fs = true
    else if (opt.is("--cross-file-system"))
        config.same_fs = false
    else if (opt.is("-e") or opt.is("--extended"))
        config.extended = true
    else if (opt.is("--no-extended"))
        config.extended = false
    else if (opt.is("-r") and !(config.can_delete orelse true))
        config.can_shell = false
    else if (opt.is("-r")) config.can_delete = false else if (opt.is("--enable-shell"))
        config.can_shell = true
    else if (opt.is("--disable-shell"))
        config.can_shell = false
    else if (opt.is("--enable-delete"))
        config.can_delete = true
    else if (opt.is("--disable-delete"))
        config.can_delete = false
    else if (opt.is("--enable-refresh"))
        config.can_refresh = true
    else if (opt.is("--disable-refresh"))
        config.can_refresh = false
    else if (opt.is("--show-hidden"))
        config.show_hidden = true
    else if (opt.is("--hide-hidden"))
        config.show_hidden = false
    else if (opt.is("--show-itemcount"))
        config.show_items = true
    else if (opt.is("--hide-itemcount"))
        config.show_items = false
    else if (opt.is("--show-mtime"))
        config.show_mtime = true
    else if (opt.is("--hide-mtime"))
        config.show_mtime = false
    else if (opt.is("--show-graph"))
        config.show_graph = true
    else if (opt.is("--hide-graph"))
        config.show_graph = false
    else if (opt.is("--show-percent"))
        config.show_percent = true
    else if (opt.is("--hide-percent"))
        config.show_percent = false
    else if (opt.is("--group-directories-first"))
        config.sort_dirsfirst = true
    else if (opt.is("--no-group-directories-first"))
        config.sort_dirsfirst = false
    else if (opt.is("--enable-natsort"))
        config.sort_natural = true
    else if (opt.is("--disable-natsort"))
        config.sort_natural = false
    else if (opt.is("--graph-style")) {
        const val = try args.arg();
        if (std.mem.eql(u8, val, "hash"))
            config.graph_style = .hash
        else if (std.mem.eql(u8, val, "half-block"))
            config.graph_style = .half
        else if (std.mem.eql(u8, val, "eighth-block") or std.mem.eql(u8, val, "eigth-block"))
            config.graph_style = .eighth
        else
            try args.die("Unknown --graph-style option: {s}.\n", .{val});
    } else if (opt.is("--sort")) {
        var val: []const u8 = try args.arg();
        var ord: ?config.SortOrder = null;
        if (std.mem.endsWith(u8, val, "-asc")) {
            val = val[0 .. val.len - 4];
            ord = .asc;
        } else if (std.mem.endsWith(u8, val, "-desc")) {
            val = val[0 .. val.len - 5];
            ord = .desc;
        }
        if (std.mem.eql(u8, val, "name")) {
            config.sort_col = .name;
            config.sort_order = ord orelse .asc;
        } else if (std.mem.eql(u8, val, "disk-usage")) {
            config.sort_col = .blocks;
            config.sort_order = ord orelse .desc;
        } else if (std.mem.eql(u8, val, "apparent-size")) {
            config.sort_col = .size;
            config.sort_order = ord orelse .desc;
        } else if (std.mem.eql(u8, val, "itemcount")) {
            config.sort_col = .items;
            config.sort_order = ord orelse .desc;
        } else if (std.mem.eql(u8, val, "mtime")) {
            config.sort_col = .mtime;
            config.sort_order = ord orelse .asc;
        } else try args.die("Unknown --sort option: {s}.\n", .{val});
    } else if (opt.is("--shared-column")) {
        const val = try args.arg();
        if (std.mem.eql(u8, val, "off"))
            config.show_shared = .off
        else if (std.mem.eql(u8, val, "shared"))
            config.show_shared = .shared
        else if (std.mem.eql(u8, val, "unique"))
            config.show_shared = .unique
        else
            try args.die("Unknown --shared-column option: {s}.\n", .{val});
    } else if (opt.is("--apparent-size"))
        config.show_blocks = false
    else if (opt.is("--disk-usage"))
        config.show_blocks = true
    else if (opt.is("-0"))
        config.scan_ui = .none
    else if (opt.is("-1"))
        config.scan_ui = .line
    else if (opt.is("-2"))
        config.scan_ui = .full
    else if (opt.is("--si"))
        config.si = true
    else if (opt.is("--no-si"))
        config.si = false
    else if (opt.is("-L") or opt.is("--follow-symlinks"))
        config.follow_symlinks = true
    else if (opt.is("--no-follow-symlinks"))
        config.follow_symlinks = false
    else if (opt.is("--exclude")) {
        const arg = if (infile) (try util.expandUser(allocator, environ, try args.arg())) else try args.arg();
        defer if (infile) allocator.free(arg);
        exclude.addPattern(arg);
    } else if (opt.is("-X") or opt.is("--exclude-from")) {
        const arg = if (infile) (try util.expandUser(allocator, environ, try args.arg())) else try args.arg();
        defer if (infile) allocator.free(arg);
        readExcludeFile(io, arg) catch |e| try args.die("Error reading excludes from {s}: {s}.\n", .{ arg, ui.errorString(e) });
    } else if (opt.is("--exclude-caches"))
        config.exclude_caches = true
    else if (opt.is("--include-caches"))
        config.exclude_caches = false
    else if (opt.is("--exclude-kernfs"))
        config.exclude_kernfs = true
    else if (opt.is("--include-kernfs"))
        config.exclude_kernfs = false
    else if (opt.is("-c") or opt.is("--compress"))
        config.compress = true
    else if (opt.is("--no-compress"))
        config.compress = false
    else if (opt.is("--compress-level")) {
        const val = try args.arg();
        const num = std.fmt.parseInt(u8, val, 10) catch try args.die("Invalid number for --compress-level: {s}.\n", .{val});
        if (num <= 0 or num > 20) try args.die("Invalid number for --compress-level: {s}.\n", .{val});
        config.complevel = num;
    } else if (opt.is("--export-block-size")) {
        const val = try args.arg();
        const num = std.fmt.parseInt(u14, val, 10) catch try args.die("Invalid number for --export-block-size: {s}.\n", .{val});
        if (num < 4 or num > 16000) try args.die("Invalid number for --export-block-size: {s}.\n", .{val});
        config.export_block_size = @as(usize, num) * 1024;
    } else if (opt.is("--confirm-quit")) config.confirm_quit = true else if (opt.is("--no-confirm-quit"))
        config.confirm_quit = false
    else if (opt.is("--confirm-delete"))
        config.confirm_delete = true
    else if (opt.is("--no-confirm-delete"))
        config.confirm_delete = false
    else if (opt.is("--delete-command"))
        config.delete_command = try allocator.dupeSentinel(u8, try args.arg(), 0)
    else if (opt.is("--color")) {
        const val = try args.arg();
        if (std.mem.eql(u8, val, "off"))
            config.ui_color = .off
        else if (std.mem.eql(u8, val, "dark"))
            config.ui_color = .dark
        else if (std.mem.eql(u8, val, "dark-bg"))
            config.ui_color = .darkbg
        else
            try args.die("Unknown --color option: {s}.\n", .{val});
    } else if (opt.is("-t") or opt.is("--threads")) {
        const val = try args.arg();
        config.threads = std.fmt.parseInt(u8, val, 10) catch try args.die("Invalid number of --threads: {s}.\n", .{val});
    } else return error.UnknownOption;
}

fn tryReadArgsFile(io: std.Io, environ: std.process.Environ, path: [:0]const u8) void {
    var f = std.Io.Dir.cwd().openFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return,
        error.NotDir => return,
        else => ui.die("Error opening {s}: {s}\nRun with --ignore-config to skip reading config files.\n", .{ path, ui.errorString(e) }),
    };
    defer f.close(io);

    var line_buf: [4096]u8 = undefined;
    var line_rd = util.LineReader.init(io, f, &line_buf);

    while (true) {
        const line_ = (line_rd.read() catch |e|
            ui.die("Error reading from {s}: {s}\nRun with --ignore-config to skip reading config files.\n", .{ path, ui.errorString(e) })) orelse break;

        var argc: usize = 0;
        var ignerror = false;
        var arglist: [2][:0]const u8 = .{ "", "" };

        var line = std.mem.trim(u8, line_, &std.ascii.whitespace);
        if (line.len > 0 and line[0] == '@') {
            ignerror = true;
            line = line[1..];
        }
        if (line.len == 0 or line[0] == '#') continue;
        if (std.mem.indexOfAny(u8, line, " \t=")) |i| {
            arglist[argc] = allocator.dupeSentinel(u8, line[0..i], 0) catch unreachable;
            argc += 1;
            line = std.mem.trimStart(u8, line[i + 1 ..], &std.ascii.whitespace);
        }
        arglist[argc] = allocator.dupeSentinel(u8, line, 0) catch unreachable;
        argc += 1;

        var args = Args.init(arglist[0..argc]);
        args.ignerror = ignerror;
        while (args.next() catch null) |opt| {
            if (argConfig(io, &args, opt, environ, true)) |_| {} else |_| {
                if (ignerror) break;
                ui.die("Unrecognized option in config file '{s}': {s}.\nRun with --ignore-config to skip reading config files.\n", .{ path, opt.val });
            }
        }
        allocator.free(arglist[0]);
        if (argc == 2) allocator.free(arglist[1]);
    }
}

fn version(io: std.Io) noreturn {
    stdout.writeStreamingAll(io, "ncdu " ++ program_version ++ "\n") catch {};
    std.process.exit(0);
}

fn help(io: std.Io) noreturn {
    stdout.writeStreamingAll(io,
        \\ncdu <options> <directory>
        \\
        \\Mode selection:
        \\  -h, --help                 This help message
        \\  -v, -V, --version          Print version
        \\  -f FILE                    Import scanned directory from FILE
        \\  -o FILE                    Export scanned directory to FILE in JSON format
        \\  -O FILE                    Export scanned directory to FILE in binary format
        \\  -e, --extended             Enable extended information
        \\  --ignore-config            Don't load config files
        \\
        \\Scan options:
        \\  -x, --one-file-system      Stay on the same filesystem
        \\  --exclude PATTERN          Exclude files that match PATTERN
        \\  -X, --exclude-from FILE    Exclude files that match any pattern in FILE
        \\  --exclude-caches           Exclude directories containing CACHEDIR.TAG
        \\  -L, --follow-symlinks      Follow symbolic links (excluding directories)
        \\  --exclude-kernfs           Exclude Linux pseudo filesystems (procfs,sysfs,cgroup,...)
        \\  -t NUM                     Scan with NUM threads
        \\
        \\Export options:
        \\  -c, --compress             Use Zstandard compression with `-o`
        \\  --compress-level NUM       Set compression level
        \\  --export-block-size KIB    Set export block size with `-O`
        \\
        \\Interface options:
        \\  -0, -1, -2                 UI to use when scanning (0=none,2=full ncurses)
        \\  -q, --slow-ui-updates      "Quiet" mode, refresh interval 2 seconds
        \\  --enable-shell             Enable/disable shell spawning feature
        \\  --enable-delete            Enable/disable file deletion feature
        \\  --enable-refresh           Enable/disable directory refresh feature
        \\  -r                         Read only (--disable-delete)
        \\  -rr                        Read only++ (--disable-delete & --disable-shell)
        \\  --si                       Use base 10 (SI) prefixes instead of base 2
        \\  --apparent-size            Show apparent size instead of disk usage by default
        \\  --hide-hidden              Hide "hidden" or excluded files by default
        \\  --show-itemcount           Show item count column by default
        \\  --show-mtime               Show mtime column by default (requires `-e`)
        \\  --show-graph               Show graph column by default
        \\  --show-percent             Show percent column by default
        \\  --graph-style STYLE        hash / half-block / eighth-block
        \\  --shared-column            off / shared / unique
        \\  --sort COLUMN-(asc/desc)   disk-usage / name / apparent-size / itemcount / mtime
        \\  --enable-natsort           Use natural order when sorting by name
        \\  --group-directories-first  Sort directories before files
        \\  --confirm-quit             Ask confirmation before quitting ncdu
        \\  --no-confirm-delete        Don't ask confirmation before deletion
        \\  --delete-command CMD       Command to run for file deletion
        \\  --color SCHEME             off / dark / dark-bg
        \\
        \\Refer to `man ncdu` for more information.
        \\
    ) catch {};
    std.process.exit(0);
}

fn readExcludeFile(io: std.Io, path: [:0]const u8) !void {
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);

    var line_buf: [4096]u8 = undefined;
    var line_rd = util.LineReader.init(io, f, &line_buf);
    while (try line_rd.read()) |line| {
        if (line.len > 0)
            exclude.addPattern(line);
    }
}

fn readImport(io: std.Io, path: [:0]const u8) !void {
    const fd =
        if (std.mem.eql(u8, "-", path))
            stdin
        else
            try std.Io.Dir.cwd().openFile(io, path, .{});
    errdefer fd.close(io);

    var buf: [8]u8 = undefined;
    if (fd.readerStreaming(io, &buf).size) |size| if (8 != size) return error.EndOfStream;
    if (std.mem.eql(u8, &buf, bin_export.SIGNATURE)) {
        try bin_reader.open(io, fd);
        config.binreader = true;
    } else {
        json_import.import(io, fd, &buf);
        fd.close(io);
    }
}

pub fn main(init: std.process.Init) !void {
    _io = init.io;
    ui.main_thread = std.Thread.getCurrentId();

    // Grab thousands_sep from the current C locale.
    _ = std.c.setlocale(std.c.LC.ALL, "");
    if (c.localeconv()) |locale| {
        if (locale.*.thousands_sep) |sep| {
            const span = std.mem.sliceTo(sep, 0);
            if (span.len > 0)
                config.thousands_sep = span;
        }
    }

    const loadConf = blk: {
        var args = init.minimal.args.iterate();
        while (args.next()) |a|
            if (std.mem.eql(u8, a, "--ignore-config"))
                break :blk false;
        break :blk true;
    };

    if (loadConf) {
        tryReadArgsFile(init.io, init.minimal.environ, "/etc/ncdu.conf");
        if (init.minimal.environ.getPosix("XDG_CONFIG_HOME")) |p| {
            const path = try std.Io.Dir.path.joinZ(allocator, &.{ p, "ncdu", "config" });
            defer allocator.free(path);
            tryReadArgsFile(init.io, init.minimal.environ, path);
        } else if (init.minimal.environ.getPosix("HOME")) |p| {
            const path = try std.Io.Dir.path.joinZ(allocator, &.{ p, ".config", "ncdu", "config" });
            defer allocator.free(path);
            tryReadArgsFile(init.io, init.minimal.environ, path);
        }
    }

    var scan_dir: ?[:0]const u8 = null;
    var import_file: ?[:0]const u8 = null;
    var export_json: ?[:0]const u8 = null;
    var export_bin: ?[:0]const u8 = null;
    var quit_after_scan = false;
    {
        const arglist = try init.minimal.args.toSlice(allocator);
        defer allocator.free(arglist);
        var args = Args.init(arglist);
        _ = try args.next(); // program name
        while (try args.next()) |opt| {
            if (!opt.opt) {
                // XXX: ncdu 1.x doesn't error, it just silently ignores all but the last argument.
                if (scan_dir != null) ui.die("Multiple directories given, see ncdu -h for help.\n", .{});
                scan_dir = try allocator.dupeSentinel(u8, opt.val, 0);
                continue;
            }
            if (opt.is("-h") or opt.is("-?") or opt.is("--help"))
                help(init.io)
            else if (opt.is("-v") or opt.is("-V") or opt.is("--version"))
                version(init.io)
            else if (opt.is("-o") and (export_json != null or export_bin != null))
                ui.die("The -o flag can only be given once.\n", .{})
            else if (opt.is("-o"))
                export_json = try allocator.dupeSentinel(u8, try args.arg(), 0)
            else if (opt.is("-O") and (export_json != null or export_bin != null))
                ui.die("The -O flag can only be given once.\n", .{})
            else if (opt.is("-O"))
                export_bin = try allocator.dupeSentinel(u8, try args.arg(), 0)
            else if (opt.is("-f") and import_file != null)
                ui.die("The -f flag can only be given once.\n", .{})
            else if (opt.is("-f"))
                import_file = try allocator.dupeSentinel(u8, try args.arg(), 0)
            else if (opt.is("--ignore-config")) {} else if (opt.is("--quit-after-scan"))
                quit_after_scan = true // undocumented feature to help with benchmarking scan/import
            else if (argConfig(init.io, &args, opt, init.minimal.environ, false)) |_| {} else |_| ui.die("Unrecognized option '{s}'.\n", .{opt.val});
        }
    }

    if (config.threads == 0) config.threads = std.Thread.getCpuCount() catch 1;

    if (@import("builtin").os.tag != .linux and config.exclude_kernfs)
        ui.die("The --exclude-kernfs flag is currently only supported on Linux.\n", .{});

    const out_tty = try stdout.isTty(init.io);
    const in_tty = try stdin.isTty(init.io);
    if (config.scan_ui == null) {
        if (export_json orelse export_bin) |f| {
            if (!out_tty or std.mem.eql(u8, f, "-"))
                config.scan_ui = .none
            else
                config.scan_ui = .line;
        } else config.scan_ui = .full;
    }
    if (!in_tty and import_file == null and export_json == null and export_bin == null and !quit_after_scan)
        ui.die("Standard input is not a TTY. Did you mean to import a file using '-f -'?\n", .{});
    config.nc_tty = !in_tty or (if (export_json orelse export_bin) |f| std.mem.eql(u8, f, "-") else false);

    event_delay_timer = std.Io.Clock.real.now(init.io);
    defer ui.deinit();

    if (export_json) |f| {
        const file =
            if (std.mem.eql(u8, f, "-"))
                stdout
            else
                std.Io.Dir.cwd().createFile(init.io, f, .{}) catch |e| ui.die("Error opening export file: {s}.\n", .{ui.errorString(e)});
        json_export.setupOutput(init.io, file);
        sink.global.sink = .json;
    } else if (export_bin) |f| {
        const file =
            if (std.mem.eql(u8, f, "-"))
                stdout
            else
                std.Io.Dir.cwd().createFile(init.io, f, .{}) catch |e| ui.die("Error opening export file: {s}.\n", .{ui.errorString(e)});
        bin_export.setupOutput(init.io, file);
        sink.global.sink = .bin;
    }

    if (import_file) |f| {
        readImport(init.io, f) catch |e| ui.die("Error reading file '{s}': {s}.\n", .{ f, ui.errorString(e) });
        config.imported = true;
        if (config.binreader and (export_json != null or export_bin != null))
            bin_reader.import(init.io);
    } else {
        var buf: [std.Io.Dir.max_path_bytes + 1]u8 = @splat(0);
        const path =
            if (std.Io.Dir.cwd().realPathFile(init.io, scan_dir orelse ".", buf[0 .. buf.len - 1])) |p|
                buf[0..p :0]
            else |_|
                (scan_dir orelse ".");
        scan.scan(init.io, path) catch |e| ui.die("Error opening directory: {s}.\n", .{ui.errorString(e)});
    }
    if (quit_after_scan or export_json != null or export_bin != null) return;

    config.can_shell = config.can_shell orelse !config.imported;
    config.can_delete = config.can_delete orelse !config.imported;
    config.can_refresh = config.can_refresh orelse !config.imported;

    config.scan_ui = .full; // in case we're refreshing from the UI, always in full mode.
    ui.init();
    state = .browse;
    browser.initRoot(init.io);

    while (true) {
        switch (state) {
            .refresh => {
                var full_path: std.ArrayListUnmanaged(u8) = .empty;
                defer full_path.deinit(allocator);
                mem_sink.global.root.?.fmtPath(allocator, true, &full_path);
                scan.scan(init.io, util.arrayListBufZ(&full_path, allocator)) catch {
                    sink.global.last_error = try allocator.dupeSentinel(u8, full_path.items, 0);
                    sink.global.state = .err;
                    while (state == .refresh) handleEvent(init.io, true, true);
                };
                state = .browse;
                browser.loadDir(init.io, 0);
            },
            .shell => {
                const shell = init.minimal.environ.getPosix("NCDU_SHELL") orelse init.minimal.environ.getPosix("SHELL") orelse "/bin/sh";
                ui.runCmd(init.io, &.{shell}, browser.dir_path, init.environ_map, false);
                state = .browse;
            },
            .delete => {
                const next = delete.delete(init);
                if (state != .refresh) {
                    state = .browse;
                    browser.loadDir(init.io, if (next) |n| n.nameHash() else 0);
                }
            },
            else => handleEvent(init.io, true, false),
        }
    }
}

pub var event_delay_timer: std.Io.Timestamp = undefined;

// Draw the screen and handle the next input event.
// In non-blocking mode, screen drawing is rate-limited to keep this function fast.
pub fn handleEvent(io: std.Io, block: bool, force_draw: bool) void {
    while (ui.oom_threads.load(.monotonic) > 0) ui.oom(io);

    if (block or force_draw or event_delay_timer.toMilliseconds() > config.update_delay) {
        if (ui.inited) _ = c.erase();
        switch (state) {
            .scan, .refresh => sink.draw(io),
            .browse => browser.draw(),
            .delete => delete.draw(),
            .shell => unreachable,
        }
        if (ui.inited) _ = c.refresh();
        event_delay_timer = std.Io.Clock.real.now(io);
    }
    if (!ui.inited) {
        std.debug.assert(!block);
        return;
    }

    var firstblock = block;
    while (true) {
        const ch = ui.getch(io, firstblock);
        if (ch == 0) return;
        if (ch == -1) return handleEvent(io, firstblock, true);
        switch (state) {
            .scan, .refresh => sink.keyInput(ch),
            .browse => browser.keyInput(io, ch),
            .delete => delete.keyInput(ch),
            .shell => unreachable,
        }
        firstblock = false;
    }
}

test "argument parser" {
    const lst = [_][:0]const u8{
        "a",
        "-abcd=e",
        "--opt1=arg1",
        "--opt2",
        "arg2",
        "-x",
        "foo",
        "",
        "--",
        "--arg",
        "",
        "-",
    };
    const T = struct {
        a: Args,
        fn opt(self: *@This(), isopt: bool, val: []const u8) !void {
            const o = (try self.a.next()).?;
            try std.testing.expectEqual(isopt, o.opt);
            try std.testing.expectEqualStrings(val, o.val);
            try std.testing.expectEqual(o.is(val), isopt);
        }
        fn arg(self: *@This(), val: []const u8) !void {
            try std.testing.expectEqualStrings(val, try self.a.arg());
        }
    };
    var t = T{ .a = Args.init(&lst) };
    try t.opt(false, "a");
    try t.opt(true, "-a");
    try t.opt(true, "-b");
    try t.arg("cd=e");
    try t.opt(true, "--opt1");
    try t.arg("arg1");
    try t.opt(true, "--opt2");
    try t.arg("arg2");
    try t.opt(true, "-x");
    try t.arg("foo");
    try t.opt(false, "");
    try t.opt(false, "--arg");
    try t.opt(false, "");
    try t.opt(false, "-");
    try std.testing.expectEqual(t.a.next(), null);
}
