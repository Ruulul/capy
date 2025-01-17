const std = @import("std");
const http = @import("deps.zig").imports.apple_pie;
const install = @import("build_capy.zig").install;

/// Step used to run a web server
const WebServerStep = struct {
    step: std.build.Step,
    exe: *std.build.LibExeObjStep,
    builder: *std.build.Builder,

    pub fn create(builder: *std.build.Builder, exe: *std.build.LibExeObjStep) *WebServerStep {
        const self = builder.allocator.create(WebServerStep) catch unreachable;
        self.* = .{
            .step = std.build.Step.init(.custom, "webserver", builder.allocator, WebServerStep.make),
            .exe = exe,
            .builder = builder,
        };
        return self;
    }

    const Context = struct {
        exe: *std.build.LibExeObjStep,
        builder: *std.build.Builder,
    };

    pub fn make(step: *std.build.Step) !void {
        const self = @fieldParentPtr(WebServerStep, "step", step);
        const allocator = self.builder.allocator;

        var context = Context{ .builder = self.builder, .exe = self.exe };
        const builder = http.router.Builder(*Context);
        std.debug.print("Web server opened at http://localhost:8080/\n", .{});
        try http.listenAndServe(
            allocator,
            try std.net.Address.parseIp("127.0.0.1", 8080),
            &context,
            comptime http.router.Router(*Context, &.{
                builder.get("/", null, index),
                builder.get("/zig-app.wasm", null, wasmFile),
            }),
        );
    }

    fn index(context: *Context, response: *http.Response, request: http.Request, _: ?*const anyopaque) !void {
        const allocator = request.arena;
        const buildRoot = context.builder.build_root;
        const file = try std.fs.cwd().openFile(try std.fs.path.join(allocator, &.{ buildRoot, "src/backends/wasm/page.html" }), .{});
        defer file.close();
        const text = try file.readToEndAlloc(allocator, std.math.maxInt(usize));

        try response.headers.put("Content-Type", "text/html");
        try response.writer().writeAll(text);
    }

    fn wasmFile(context: *Context, response: *http.Response, request: http.Request, _: ?*const anyopaque) !void {
        const allocator = request.arena;
        const path = context.exe.getOutputSource().getPath(context.builder);
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const text = try file.readToEndAlloc(allocator, std.math.maxInt(usize));

        try response.headers.put("Content-Type", "application/wasm");
        try response.writer().writeAll(text);
    }
};

pub fn build(b: *std.build.Builder) !void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    var examplesDir = try std.fs.cwd().openIterableDir("examples", .{});
    defer examplesDir.close();

    const broken = switch (target.getOsTag()) {
        .windows => &[_][]const u8{"fade","foo_app"},
        else => &[_][]const u8{},
    };

    var walker = try examplesDir.walk(b.allocator);
    defer walker.deinit();
    while (try walker.next()) |entry| {
        if (entry.kind == .File and std.mem.eql(u8, std.fs.path.extension(entry.path), ".zig")) {
            const name = try std.mem.replaceOwned(u8, b.allocator, entry.path[0 .. entry.path.len - 4], std.fs.path.sep_str, "-");
            defer b.allocator.free(name);

            // it is not freed as the path is used later for building
            const programPath = b.pathJoin(&.{ "examples", entry.path });

            const exe: *std.build.LibExeObjStep = if (target.toTarget().isWasm())
                b.addSharedLibrary(name, programPath, .unversioned)
            else
                b.addExecutable(name, programPath);
            exe.setTarget(target);
            exe.setBuildMode(mode);
            try install(exe, ".");

            const install_step = b.addInstallArtifact(exe);
            const working = blk: {
                for (broken) |broken_name| {
                    if (std.mem.eql(u8, name, broken_name))
                        break :blk false;
                }
                break :blk true;
            };
            if (working) {
                b.getInstallStep().dependOn(&install_step.step);
            } else {
                std.log.warn("'{s}' is broken (disabled by default)", .{name});
            }

            if (target.toTarget().isWasm()) {
                const serve = WebServerStep.create(b, exe);
                serve.step.dependOn(&exe.install_step.?.step);
                const serve_step = b.step(name, "Start a web server to run this example");
                serve_step.dependOn(&serve.step);
            } else {
                const run_cmd = exe.run();
                run_cmd.step.dependOn(&exe.install_step.?.step);
                if (b.args) |args| {
                    run_cmd.addArgs(args);
                }

                const run_step = b.step(name, "Run this example");
                run_step.dependOn(&run_cmd.step);
            }
        }
    }

    const lib = b.addSharedLibrary("capy", "src/c_api.zig", b.version(0, 1, 0));
    lib.setTarget(target);
    lib.setBuildMode(mode);
    lib.linkLibC();
    try install(lib, ".");
    lib.emit_h = true;
    lib.install();

    const sharedlib_install_step = b.addInstallArtifact(lib);
    b.getInstallStep().dependOn(&sharedlib_install_step.step);

    const buildc_step = b.step("shared", "Build capy as a shared library (with C ABI)");
    buildc_step.dependOn(&lib.install_step.?.step);

    const tests = b.addTest("src/main.zig");
    tests.setTarget(target);
    tests.setBuildMode(mode);
    // tests.emit_docs = .emit;
    try install(tests, ".");

    const test_step = b.step("test", "Run unit tests and also generate the documentation");
    test_step.dependOn(&tests.step);
}
