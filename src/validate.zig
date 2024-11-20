const std = @import("std");

pub fn main() !void {
    var arena_instance = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_instance.allocator();
    const all_args = try std.process.argsAlloc(arena);
    if (all_args.len != 2) @panic("unexpected number of cmdline args");
    const out_dir_path = all_args[1];

    var out_dir = try std.fs.cwd().openDir(out_dir_path, .{ .iterate = true });
    defer out_dir.close();

    var out_dir_it = out_dir.iterate();
    var count: usize = 0;
    while (try out_dir_it.next()) |entry| {
        switch (entry.kind) {
            .file => try checkFile(arena, out_dir_path, out_dir, entry.name),
            else => |k| std.debug.panic("unexpected file kind '{s}'", .{@tagName(k)}),
        }
        count += 1;
    }
    try std.io.getStdOut().writer().print("verified {} files\n", .{count});
}

fn checkFile(allocator: std.mem.Allocator, dir_path: []const u8, dir: std.fs.Dir, sub_path: []const u8) !void {
    try std.io.getStdOut().writer().print("{s}\n", .{sub_path});
    const content = blk: {
        var file = try dir.openFile(sub_path, .{});
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, std.math.maxInt(usize));
    };
    defer allocator.free(content);

    var diagnostics = std.json.Diagnostics{};
    var scanner = std.json.Scanner.initCompleteInput(allocator, content);
    defer scanner.deinit();
    scanner.enableDiagnostics(&diagnostics);
    const json = std.json.parseFromTokenSourceLeaky(
        std.json.Value,
        allocator,
        &scanner,
        .{},
    ) catch |err| {
        std.log.err(
            "{s}{c}{s}:{}:{}: {s}",
            .{
                dir_path,              std.fs.path.sep,         sub_path,
                diagnostics.getLine(), diagnostics.getColumn(), @errorName(err),
            },
        );
        std.process.exit(0xff);
    };
    _ = json;
}
