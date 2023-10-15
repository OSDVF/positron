const std = @import("std");

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

pub fn getPackage(b: *std.Build, name: []const u8) *std.Build.Module {
    return b.addModule(name, .{
        .source_file = .{ .path = sdkRoot() ++ "/src/positron.zig" },
        .dependencies = &.{
            .{
                .name = "serve",
                .module = b.createModule(.{
                    .source_file = .{ .path = sdkRoot() ++ "/vendor/serve/src/serve.zig" },
                    .dependencies = &.{
                        .{
                            .name = "uri",
                            .module = b.createModule(.{
                                .source_file = .{ .path = sdkRoot() ++ "/vendor/serve/vendor/uri/uri.zig" },
                            }),
                        },
                        .{
                            .name = "network",
                            .module = b.createModule(.{
                                .source_file = .{ .path = sdkRoot() ++ "/vendor/serve/vendor/network/network.zig" },
                            }),
                        },
                    },
                }),
            },
        },
    });
}

/// Links positron to `exe`. `exe` must have its final `target` already set!
/// `backend` selects the backend to be used, use `null` for a good default.
pub fn linkPositron(compileStep: *std.build.Step.Compile, backend: ?Backend) void {
    compileStep.linkLibC();
    compileStep.linkSystemLibrary("c++");

    // make webview library standalone
    compileStep.addCSourceFile(.{ .file = .{ .path = sdkRoot() ++ "/src/wv/webview.cpp" }, .flags = &[_][]const u8{
        "-std=c++17",
        "-fno-sanitize=undefined",
    } });

    if (compileStep.target.isWindows()) {

        // Attempts to fix windows building:
        compileStep.addIncludePath(.{ .path = sdkRoot() ++ "/vendor/winsdk" });

        compileStep.addIncludePath(.{ .path = sdkRoot() ++ "/vendor/Microsoft.Web.WebView2.1.0.902.49/build/native/include" });
        compileStep.addLibraryPath(.{ .path = sdkRoot() ++ "/vendor/Microsoft.Web.WebView2.1.0.902.49/build/native/x64" });
        compileStep.linkSystemLibrary("user32");
        compileStep.linkSystemLibrary("ole32");
        compileStep.linkSystemLibrary("oleaut32");
        compileStep.addObjectFile(.{ .path = sdkRoot() ++ "/vendor/Microsoft.Web.WebView2.1.0.902.49/build/native/x64/WebView2Loader.dll.lib" });
        //exe.linkSystemLibrary("windowsapp");
    }

    if (backend) |b| {
        switch (b) {
            .gtk => compileStep.defineCMacro("WEBVIEW_GTK", null),
            .cocoa => compileStep.defineCMacro("WEBVIEW_COCOA", null),
            .edge => compileStep.defineCMacro("WEBVIEW_EDGE", null),
        }
    }

    switch (compileStep.target.getOsTag()) {
        //# Windows (x64)
        //$ c++ main.cc -mwindows -L./dll/x64 -lwebview -lWebView2Loader -o webview-example.exe
        .windows => {
            compileStep.addLibraryPath(.{ .path = sdkRoot() ++ "/vendor/webview/dll/x64" });
        },
        //# MacOS
        //$ c++ main.cc -std=c++11 -framework WebKit -o webview-example
        .macos => {
            compileStep.linkFramework("WebKit");
        },
        //# Linux
        //$ c++ main.cc `pkg-config --cflags --libs gtk+-3.0 webkit2gtk-4.0` -o webview-example
        .linux => {
            compileStep.linkSystemLibrary("gtk+-3.0");
            compileStep.linkSystemLibrary("webkit2gtk-4.0");
        },
        else => std.debug.panic("unsupported os: {s}", .{@tagName(compileStep.target.getOsTag())}),
    }
}
