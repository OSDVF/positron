const std = @import("std");
const Sdk = @import("Sdk.zig");
const ZigServe = @import("vendor/serve/build.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardOptimizeOption(.{});
    const backend = b.option(Sdk.Backend, "backend", "Configures the backend that should be used for webview.");

    const wolfssl = ZigServe.createWolfSSL(b, target.query, mode);

    const minimal_exe = b.addExecutable(.{
        .name = "positron-minimal",
        .root_source_file = .{ .path = "example/minimal.zig" },
        .target = target,
        .optimize = mode,
    });
    minimal_exe.linkLibrary(wolfssl);
    minimal_exe.addIncludePath(.{
        .cwd_relative = "vendor/serve/vendor/wolfssl",
    });
    const positron = Sdk.getPackage(b, "positron");
    minimal_exe.addModule("positron", positron);
    Sdk.linkPositron(minimal_exe, null);

    b.installArtifact(minimal_exe);

    const exe = b.addExecutable(.{
        .name = "positron-demo",
        .root_source_file = .{ .path = "example/main.zig" },
        .target = target,
        .optimize = mode,
    });
    exe.linkLibrary(wolfssl);
    exe.addIncludePath(.{ .cwd_relative = "vendor/serve/vendor/wolfssl" });

    Sdk.linkPositron(exe, backend);
    exe.addModule("positron", positron);

    b.installArtifact(exe);

    const positron_test = b.addTest(.{
        .root_source_file = .{ .path = "src/positron.zig" },
    });

    Sdk.linkPositron(positron_test, null);
    positron_test.addModule("positron", positron);

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
