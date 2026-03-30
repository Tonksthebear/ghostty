const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const mem = @import("mem.zig");
const Terminal = ghostty_vt.Terminal;

var fuzz_alloc: mem.FuzzAllocator(64 * 1024 * 1024) = .{};

pub export fn zig_fuzz_init() callconv(.c) void {
    fuzz_alloc.init();
}

pub export fn zig_fuzz_test(
    buf: [*]const u8,
    len: usize,
) callconv(.c) void {
    if (len == 0) return;

    fuzz_alloc.reset();
    const alloc = fuzz_alloc.allocator();
    const input = buf[0..len];

    const cols = @as(u16, 1) + input[0] % 120;
    const rows = @as(u16, 1) + (if (input.len > 1) input[1] else input[0]) % 60;
    const data = if (input.len > 2) input[2..] else input[0..0];

    var t = Terminal.init(alloc, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback = 256,
    }) catch return;
    defer t.deinit(alloc);

    t.snapshotImport(data) catch return;
    const exported = t.snapshotExportAlloc(alloc) catch return;
    _ = exported;
}
