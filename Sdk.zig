const std = @import("std");
const builtin = @import("builtin");

pub const Backend = enum {
    gtk,
    cocoa,
    edge,
};

inline fn sdkRoot() []const u8 {
    comptime {
        const thisFile: []const u8 = @src().file;
        const lastSlash = std.mem.lastIndexOf(u8, thisFile, &[_]u8{@as(u8, std.fs.path.sep)});
        if (lastSlash != null) {
            return thisFile[0..lastSlash.?];
        }
        return ".";
    }
}

pub fn getServeModule(b: *std.Build, target: ?std.Build.ResolvedTarget) *std.Build.Module {
    return b.addModule("serve", .{
        .root_source_file = .{ .cwd_relative = sdkRoot() ++ "/vendor/serve/src/serve.zig" },
        .imports = &.{
            .{
                .name = "uri",
                .module = b.createModule(.{
                    .root_source_file = .{ .cwd_relative = sdkRoot() ++ "/vendor/serve/vendor/uri/uri.zig" },
                }),
            },
            .{
                .name = "network",
                .module = b.createModule(.{
                    .root_source_file = .{ .cwd_relative = sdkRoot() ++ "/vendor/serve/vendor/network/network.zig" },
                }),
            },
        },
        .target = target,
    });
}

pub fn getPackage(b: *std.Build, name: []const u8, target: ?std.Build.ResolvedTarget) *std.Build.Module {
    return b.addModule(name, .{
        .root_source_file = .{ .cwd_relative = sdkRoot() ++ "/src/positron.zig" },
        .imports = &.{
            .{ .name = "serve", .module = getServeModule(b, target) },
        },
    });
}

pub fn archName(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .aarch64 => "arm64",
        .x86_64 => "x64",
        .x86 => "x86",
        else => @panic("Unsupported architecture for WebView2"),
    };
}

/// Links positron to `exe`. `exe` must have its final `target` already set!
/// `backend` selects the backend to be used, use `null` for a good default.
pub fn linkPositron(compileStep: *std.Build.Step.Compile, backend: ?Backend, static: bool) void {
    // make webview library standalone
    compileStep.addCSourceFile(.{ .file = .{ .cwd_relative = sdkRoot() ++ "/src/wv/webview.cpp" }, .flags = &[_][]const u8{
        "-std=c++17",
        "-fno-sanitize=undefined",
        "-Bsymbolic",
    } });

    if (compileStep.rootModuleTarget().os.tag == .windows) {

        // Attempts to fix windows building:
        compileStep.addIncludePath(.{ .cwd_relative = sdkRoot() ++ "/vendor/winsdk" });
        compileStep.addIncludePath(.{ .cwd_relative = sdkRoot() ++ "/vendor/Microsoft.Web.WebView2.1.0.902.49/build/native/include" });
        const arch = archName(compileStep.rootModuleTarget().cpu.arch);
        const alloc = compileStep.step.owner.allocator; //alias
        compileStep.addLibraryPath(.{ .cwd_relative = std.fs.path.join(alloc, &.{ sdkRoot() ++ "/vendor/Microsoft.Web.WebView2.1.0.902.49/build/native", arch }) catch @panic("OOM") });
        compileStep.linkSystemLibrary("user32");
        compileStep.linkSystemLibrary("ole32");
        compileStep.linkSystemLibrary("oleaut32");
        compileStep.linkSystemLibrary("shlwapi");
        if (static) {
            compileStep.linkSystemLibrary("WebView2LoaderStatic");
        } else {
            compileStep.addObjectFile(.{ .cwd_relative = std.fs.path.join(alloc, &.{ sdkRoot() ++ "/vendor/Microsoft.Web.WebView2.1.0.902.49/build/native", arch, "WebView2Loader.dll.lib" }) catch @panic("OOM") });
            compileStep.step.dependOn(&compileStep.step.owner.addInstallFileWithDir(
                .{ .cwd_relative = std.fs.path.join(alloc, &.{ sdkRoot() ++ "/vendor/Microsoft.Web.WebView2.1.0.902.49/build/native", arch, "WebView2Loader.dll" }) catch @panic("OOM") },
                if (compileStep.rootModuleTarget().os.tag == .windows) .bin else .lib,
                "WebView2Loader.dll",
            ).step);
        }
        //exe.linkSystemLibrary("windowsapp");
    }

    if (backend) |b| {
        switch (b) {
            .gtk => compileStep.root_module.addCMacro("WEBVIEW_GTK", ""),
            .cocoa => compileStep.root_module.addCMacro("WEBVIEW_COCOA", ""),
            .edge => compileStep.root_module.addCMacro("WEBVIEW_EDGE", ""),
        }
    }

    switch (compileStep.rootModuleTarget().os.tag) {
        //# Windows (x64)
        //$ c++ main.cc -mwindows -L./dll/x64 -lwebview -lWebView2Loader -o webview-example.exe
        .windows => {
            compileStep.addLibraryPath(.{ .cwd_relative = sdkRoot() ++ "/vendor/webview/dll/x64" });
        },
        //# MacOS
        //$ c++ main.cc -std=c++11 -framework WebKit -o webview-example
        .macos => {
            compileStep.linkFramework("WebKit");
        },
        //# Linux
        //$ c++ main.cc `pkg-config --cflags --libs gtk+-3.0 webkit2gtk-4.0` -o webview-example
        .linux => {
            compileStep.linkSystemLibrary2("gtk+-3.0", .{ .weak = true });
        },
        else => std.debug.panic("unsupported os: {s}", .{@tagName(compileStep.rootModuleTarget().os.tag)}),
    }
}
