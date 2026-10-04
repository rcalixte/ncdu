// SPDX-FileCopyrightText: Yorhel <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");
const host_os = @import("builtin").target.os.tag;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pie = b.option(bool, "pie", "Build with PIE support (by default: target-dependant)");
    const strip = b.option(bool, "strip", "Strip debugging info") orelse (optimize != .debug);

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .link_libc = true,
    });
    if (host_os == .macos)
        main_mod.linkSystemLibrary("ncursesw", .{})
    else if (host_os == .freebsd) {
        main_mod.addObjectFile(.{ .cwd_relative = "/usr/lib/libncursesw.so.9" });
        main_mod.linkSystemLibrary("tinfow", .{});
    } else if (host_os == .linux) {
        // some distros don't have an ELF system library for ncurses, so we have to link to it manually
        // Debian - /usr/lib/x86_64-linux-gnu/libncursesw.so.6
        // Fedora, openSUSE - /usr/lib64/libncursesw.so.6
        const debian = "/usr/lib/x86_64-linux-gnu/libncursesw.so.6";
        const fedora = "/usr/lib64/libncursesw.so.6";
        var manual_syslib: []const u8 = "";

        if (std.Io.Dir.cwd().access(b.graph.io, debian, .{}))
            manual_syslib = debian
        else |_| if (std.Io.Dir.cwd().access(b.graph.io, fedora, .{}))
            manual_syslib = fedora
        else |_|
            manual_syslib = "";

        if (manual_syslib.len == 0)
            main_mod.linkSystemLibrary("ncursesw", .{})
        else {
            main_mod.addObjectFile(.{ .cwd_relative = manual_syslib });
            main_mod.linkSystemLibrary("tinfo", .{});
        }
    }
    main_mod.linkSystemLibrary("zstd", .{});

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    main_mod.addImport("c", translate_c.createModule());

    const exe = b.addExecutable(.{
        .name = "ncdu",
        .root_module = main_mod,
    });
    exe.pie = pie;

    // https://github.com/ziglang/zig/blob/faccd79ca5debbe22fe168193b8de54393257604/build.zig#L745-L748
    if (target.result.os.tag.isDarwin()) {
        // useful for package maintainers
        exe.headerpad_max_install_names = true;
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = main_mod,
    });
    unit_tests.pie = pie;

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
