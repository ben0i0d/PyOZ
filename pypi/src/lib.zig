const std = @import("std");
const builtin = @import("builtin");
const pyoz = @import("PyOZ");
const version = @import("version");

const project = @import("project.zig");
const builder = @import("builder.zig");
const wheel = @import("wheel.zig");
const symreader = @import("symreader.zig");

fn init_project(name: ?[]const u8, in_current_dir: ?bool, local_pyoz_path: ?[]const u8, package_layout: ?bool) !void {
    try project.create(std.heap.page_allocator, name, in_current_dir orelse false, local_pyoz_path, package_layout orelse false);
}

fn build_wheel(release: ?bool, stubs: ?bool) ![]const u8 {
    // Use page_allocator: the wheel path string must outlive this function
    // because PyOZ's wrapper calls toPy() on the returned slice after we return.
    // Internal allocations from buildWheel are leaked but they're small and one-shot.
    const alloc = std.heap.page_allocator;
    return try wheel.buildWheel(alloc, release orelse false, stubs orelse true);
}

fn develop_mode() !void {
    try builder.developMode(std.heap.page_allocator);
}

fn publish_wheels(test_pypi: ?bool) !void {
    try wheel.publish(std.heap.page_allocator, test_pypi orelse false);
}

fn run_tests(release: ?bool, verbose: ?bool) !void {
    const alloc = std.heap.page_allocator;
    const rel = release orelse false;
    const verb = verbose orelse false;

    // Build the module
    var build_result = try builder.buildModule(alloc, rel);
    defer build_result.deinit(alloc);

    // Extract tests from the compiled module
    const test_content = try symreader.extractTests(alloc, build_result.module_path);
    if (test_content == null or test_content.?.len == 0) {
        std.debug.print("\nNo tests found in module.\n", .{});
        std.debug.print("Add .tests to your pyoz.module() config:\n\n", .{});
        std.debug.print("  .tests = &.{{\n", .{});
        std.debug.print("      pyoz.@\"test\"(\"my test\",\n", .{});
        std.debug.print("          \\\\assert mymod.add(2, 3) == 5\n", .{});
        std.debug.print("      ),\n", .{});
        std.debug.print("  }},\n", .{});
        return;
    }
    defer alloc.free(test_content.?);

    // Write test file
    const test_file = "zig-out/lib/__pyoz_test.py";
    {
        const f = try std.fs.cwd().createFile(test_file, .{});
        defer f.close();
        try f.writeAll(test_content.?);
    }

    std.debug.print("\nRunning tests...\n\n", .{});

    const python_cmd = builder.getPythonCommand();
    const path_sep = if (builtin.os.tag == .windows) ";" else ":";

    const existing_pp = std.process.getEnvVarOwned(alloc, "PYTHONPATH") catch "";
    defer if (existing_pp.len > 0) alloc.free(existing_pp);

    const new_pp = if (existing_pp.len > 0)
        try std.fmt.allocPrint(alloc, "zig-out/lib{s}{s}", .{ path_sep, existing_pp })
    else
        try alloc.dupe(u8, "zig-out/lib");
    defer alloc.free(new_pp);

    var argv_buf: [6][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = python_cmd;
    argc += 1;
    argv_buf[argc] = "-m";
    argc += 1;
    argv_buf[argc] = "unittest";
    argc += 1;
    argv_buf[argc] = test_file;
    argc += 1;
    if (verb) {
        argv_buf[argc] = "-v";
        argc += 1;
    }

    var env_map = try std.process.getEnvMap(alloc);
    defer env_map.deinit();
    try env_map.put("PYTHONPATH", new_pp);

    var child = std.process.Child.init(argv_buf[0..argc], alloc);
    child.env_map = &env_map;
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;

    const term = try child.spawnAndWait();
    if (term.Exited != 0) {
        std.process.exit(1);
    }
}

fn run_bench() !void {
    const alloc = std.heap.page_allocator;

    // Always build in release mode for benchmarks
    var build_result = try builder.buildModule(alloc, true);
    defer build_result.deinit(alloc);

    // Extract benchmarks from the compiled module
    const bench_content = try symreader.extractBenchmarks(alloc, build_result.module_path);
    if (bench_content == null or bench_content.?.len == 0) {
        std.debug.print("\nNo benchmarks found in module.\n", .{});
        std.debug.print("Add .benchmarks to your pyoz.module() config:\n\n", .{});
        std.debug.print("  .benchmarks = &.{{\n", .{});
        std.debug.print("      pyoz.bench(\"my benchmark\",\n", .{});
        std.debug.print("          \\\\mymod.add(100, 200)\n", .{});
        std.debug.print("      ),\n", .{});
        std.debug.print("  }},\n", .{});
        return;
    }
    defer alloc.free(bench_content.?);

    // Write benchmark file
    const bench_file = "zig-out/lib/__pyoz_bench.py";
    {
        const f = try std.fs.cwd().createFile(bench_file, .{});
        defer f.close();
        try f.writeAll(bench_content.?);
    }

    std.debug.print("\nRunning benchmarks...\n", .{});

    const python_cmd = builder.getPythonCommand();
    const path_sep = if (builtin.os.tag == .windows) ";" else ":";

    const existing_pp = std.process.getEnvVarOwned(alloc, "PYTHONPATH") catch "";
    defer if (existing_pp.len > 0) alloc.free(existing_pp);

    const new_pp = if (existing_pp.len > 0)
        try std.fmt.allocPrint(alloc, "zig-out/lib{s}{s}", .{ path_sep, existing_pp })
    else
        try alloc.dupe(u8, "zig-out/lib");
    defer alloc.free(new_pp);

    var env_map = try std.process.getEnvMap(alloc);
    defer env_map.deinit();
    try env_map.put("PYTHONPATH", new_pp);

    const argv = [_][]const u8{ python_cmd, bench_file };
    var child = std.process.Child.init(&argv, alloc);
    child.env_map = &env_map;
    child.stderr_behavior = .Inherit;
    child.stdout_behavior = .Inherit;

    const term = try child.spawnAndWait();
    if (term.Exited != 0) {
        std.process.exit(1);
    }
}

fn get_version() []const u8 {
    return version.string;
}

const PyOZCli = pyoz.module(.{
    .name = "_pyoz",
    .doc = "PyOZ native CLI library - build Python extensions in Zig",
    .classes = &.{},
    .funcs = &.{
        pyoz.kwfunc("init", init_project, "Create a new PyOZ project"),
        pyoz.kwfunc("build", build_wheel, "Build extension module and create wheel"),
        pyoz.func("develop", develop_mode, "Build and install in development mode"),
        pyoz.kwfunc("publish", publish_wheels, "Publish wheel(s) to PyPI"),
        pyoz.kwfunc("run_tests", run_tests, "Run embedded tests"),
        pyoz.func("run_bench", run_bench, "Run embedded benchmarks"),
        pyoz.func("version", get_version, "Get PyOZ version string"),
    },
    .consts = &.{
        pyoz.constant("__version__", version.string),
    },
});

pub export fn PyInit__pyoz() ?*pyoz.PyObject {
    return PyOZCli.init();
}
