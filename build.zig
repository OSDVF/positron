const std = @import("std");
const builtin = @import("builtin");

pub const Backend = enum {
    gtk,
    cocoa,
    edge,
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const backend = b.option(Backend, "backend", "Configures the backend that should be used for webview.");
    const libs_locations = b.option([]const []const u8, "libs", "List of directories containing system libraries");
    const static = b.option(bool, "static", "Use static WebView2Loader on Windows");

    const minimal_exe = b.addExecutable(.{
        .name = "positron-minimal",
        .root_source_file = b.path("example/minimal.zig"),
        .target = target,
        .optimize = optimize,
    });

    const httpz = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    });

    const httpz_module = httpz.module("httpz");

    const positron = b.addModule("positron", .{
        .root_source_file = b.path("src/positron.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "httpz", .module = httpz_module },
        },
    });
    try linkWebView(positron, backend, libs_locations orelse blk: {
        const native_paths = try std.zig.system.NativePaths.detect(b.allocator, target.result);
        break :blk native_paths.lib_dirs.items;
    }, static orelse false);
    const target_result = target.result;
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        b.path(b.pathJoin(&.{ "vendor/Microsoft.Web.WebView2.1.0.902.49/build/native", archName(target_result.cpu.arch), "WebView2Loader.dll" })),
        if (target_result.os.tag == .windows) .bin else .lib,
        "WebView2Loader.dll",
    ).step);

    minimal_exe.root_module.addImport("positron", positron);
    b.installArtifact(minimal_exe);

    const exe = b.addExecutable(.{
        .name = "positron-demo",
        .root_source_file = b.path("example/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("positron", positron);

    b.installArtifact(exe);

    const positron_test = b.addTest(.{
        .root_source_file = b.path("src/positron.zig"),
    });
    positron_test.root_module.addImport("positron", positron);

    const test_step = b.step("test", "Runs the test suite");

    test_step.dependOn(&positron_test.step);

    const run_cmd = b.addRunArtifact(exe);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");

    run_step.dependOn(&run_cmd.step);

    // const demo = b.addExecutable("webview-demo", null);

    // // make webview library standalone
    // demo.addCSourceFile("src/minimal.cpp", &[_][]const u8{
    //     "-std=c++17",
    //     "-fno-sanitize=undefined",
    // });
    // demo.linkLibC();
    // demo.linkSystemLibrary("c++");
    // demo.install();

    // demo.addIncludeDir("vendor/Microsoft.Web.WebView2.1.0.902.49/build/native/include");
    // demo.addLibPath("vendor/Microsoft.Web.WebView2.1.0.902.49/build/native/x64");
    // demo.linkSystemLibrary("user32");
    // demo.linkSystemLibrary("ole32");
    // demo.linkSystemLibrary("oleaut32");
    // demo.addObjectFile("vendor/Microsoft.Web.WebView2.1.0.902.49/build/native/x64/WebView2Loader.dll.lib");

    // const exec = demo.run();
    // exec.step.dependOn(b.getInstallStep());

    // const demo_run_step = b.step("run.demo", "Run the app");
    // demo_run_step.dependOn(&exec.step);
}

/// Links positron to `exe`. `exe` must have its final `target` already set!
/// `backend` selects the backend to be used, use `null` for a good default.
fn linkWebView(module: *std.Build.Module, backend: ?Backend, libs_locations: []const []const u8, static: bool) !void {
    const b = module.owner;
    // make webview library standalone
    module.addCSourceFile(.{ .file = b.path("src/wv/webview.cpp"), .flags = &[_][]const u8{
        "-std=c++17",
        "-fno-sanitize=undefined",
        "-Bsymbolic",
    } });
    module.link_libcpp = true;
    const target = if (module.resolved_target) |r| r.result else builtin.target;

    if (target.os.tag == .windows) {

        // Attempts to fix windows building:
        module.addIncludePath(b.path("vendor/winsdk"));
        module.addIncludePath(b.path("vendor/Microsoft.Web.WebView2.1.0.902.49/build/native/include"));
        const arch = archName(target.cpu.arch);
        module.addLibraryPath(b.path(b.pathJoin(&.{ "vendor/Microsoft.Web.WebView2.1.0.902.49/build/native", arch })));
        module.linkSystemLibrary("user32", .{});
        module.linkSystemLibrary("ole32", .{});
        module.linkSystemLibrary("oleaut32", .{});
        module.linkSystemLibrary("shlwapi", .{});
        if (static) {
            module.linkSystemLibrary("WebView2LoaderStatic", .{});
        } else {
            module.addObjectFile(b.path(b.pathJoin(&.{ "vendor/Microsoft.Web.WebView2.1.0.902.49/build/native", arch, "WebView2Loader.dll.lib" })));
        }
        //exe.linkSystemLibrary("windowsapp");
    }

    if (backend) |ba| {
        switch (ba) {
            .gtk => module.addCMacro("WEBVIEW_GTK", ""),
            .cocoa => module.addCMacro("WEBVIEW_COCOA", ""),
            .edge => module.addCMacro("WEBVIEW_EDGE", ""),
        }
    }

    switch (target.os.tag) {
        //# Windows (x64)
        //$ c++ main.cc -mwindows -L./dll/x64 -lwebview -lWebView2Loader -o webview-example.exe
        .windows => {
            //compileStep.addLibraryPath(b.path("vendor/webview/dll/x64" });
        },
        //# MacOS
        //$ c++ main.cc -std=c++11 -framework WebKit -o webview-example
        .macos => {
            module.linkFramework("WebKit", .{});
        },
        //# Linux
        //$ c++ main.cc `pkg-config --cflags --libs gtk+-3.0 webkit2gtk-4.0` -o webview-example
        .linux => {
            if (try systemHasLib(module, libs_locations, "webkit2gtk-4.1")) {
                module.linkSystemLibrary("webkit2gtk-4.1", .{});
            } else {
                module.linkSystemLibrary("webkit2gtk-4.0", .{});
            }
        },
        else => std.debug.panic("unsupported os: {s}", .{@tagName(module.resolved_target.?.result.os.tag)}),
    }
}

pub fn archName(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        .x86 => "x86",
        else => @panic("Unsupported architecture for WebView2"),
    };
}

/// Search for all lib directories
/// TODO: different architectures than system-native
pub fn systemHasLib(module: *std.Build.Module, libs_locations: []const []const u8, lib: []const u8) !bool {
    const b: *std.Build = module.owner;
    const target = module.resolved_target.?.result;

    const libname = try std.mem.concat(b.allocator, u8, &.{ target.libPrefix(), lib });
    defer b.allocator.free(libname);
    if (builtin.os.tag == target.os.tag and builtin.cpu.arch == target.cpu.arch) { // native
        for (module.lib_paths.items) |lib_dir| {
            const path = lib_dir.getPath(b);
            if (try fileWithPrefixExists(b.allocator, path, libname)) |full_name| {
                std.log.info("Found library {s}", .{full_name});
                b.allocator.free(full_name);
                return true;
            }
        }
    }

    for (libs_locations) |location| if (try fileWithPrefixExists(b.allocator, location, libname)) |full_name| {
        std.log.info("Found system library {s}", .{full_name});
        b.allocator.free(full_name);
        return true;
    };
    return false;
}

pub fn fileWithPrefixExists(allocator: std.mem.Allocator, dirname: []const u8, basename: []const u8) !?[]const u8 {
    const full_dirname = try std.fs.path.join(allocator, &.{ dirname, std.fs.path.dirname(basename) orelse "" });
    defer allocator.free(full_dirname);
    var dir = std.fs.openDirAbsolute(full_dirname, .{ .iterate = true }) catch return null;
    defer dir.close();
    var it = dir.iterate();
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    while (try it.next()) |current| {
        if (current.kind == .file or (current.kind == .sym_link and resolve: {
            const target = try dir.readLink(current.name, &buffer);
            break :resolve (dir.statFile(target) catch break :resolve false).kind == .file;
        })) {
            if (std.mem.startsWith(u8, current.name, std.fs.path.basename(basename))) {
                return try std.fs.path.join(allocator, &.{ full_dirname, current.name });
            }
        }
    }
    return null;
}
