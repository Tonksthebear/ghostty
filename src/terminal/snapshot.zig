const std = @import("std");
const Allocator = std.mem.Allocator;
const ansi = @import("ansi.zig");
const color = @import("color.zig");
const charsets = @import("charsets.zig");
const kitty = @import("kitty.zig");
const mouse = @import("mouse.zig");
const modespkg = @import("modes.zig");
const osc = @import("osc.zig");
const pagepkg = @import("page.zig");
const point = @import("point.zig");
const stylepkg = @import("style.zig");
const size = @import("size.zig");
const PageList = @import("PageList.zig");
const Screen = @import("Screen.zig");
const ScreenSet = @import("ScreenSet.zig");
const Tabstops = @import("Tabstops.zig");
const Terminal = @import("Terminal.zig");
const hyperlink = @import("hyperlink.zig");

const ModeBits = std.meta.Int(.unsigned, @bitSizeOf(modespkg.ModePacked));

pub const terminal_version: u8 = 1;
pub const screen_version: u8 = 1;

pub const Error = Allocator.Error || error{
    InvalidSnapshot,
};

const Reader = struct {
    data: []const u8,
    idx: usize = 0,

    fn remaining(self: Reader) usize {
        return self.data.len - self.idx;
    }

    fn take(self: *Reader, n: usize) Error![]const u8 {
        const end = std.math.add(usize, self.idx, n) catch return error.InvalidSnapshot;
        if (end > self.data.len) return error.InvalidSnapshot;
        const result = self.data[self.idx..end];
        self.idx = end;
        return result;
    }

    fn int(self: *Reader, comptime T: type) Error!T {
        const byte_len = @divExact(@typeInfo(T).int.bits, 8);
        const bytes = try self.take(byte_len);
        return std.mem.readInt(T, @ptrCast(bytes.ptr), .little);
    }

    fn readBool(self: *Reader) Error!bool {
        return switch (try self.int(u8)) {
            0 => false,
            1 => true,
            else => error.InvalidSnapshot,
        };
    }

    fn enumValue(self: *Reader, comptime T: type, comptime Int: type) Error!T {
        return std.meta.intToEnum(T, try self.int(Int)) catch error.InvalidSnapshot;
    }

    fn slice(self: *Reader) Error![]const u8 {
        const len = try self.int(u32);
        return self.take(@intCast(len));
    }
};

pub fn exportAlloc(t: *const Terminal, alloc: Allocator) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    try appendInt(&out, alloc, u8, terminal_version);
    try appendInt(&out, alloc, u16, t.cols);
    try appendInt(&out, alloc, u16, t.rows);

    const has_alt = t.screens.get(.alternate) != null;
    try appendInt(&out, alloc, u8, if (has_alt) 2 else 1);
    try appendInt(&out, alloc, u8, screenKeyByte(t.screens.active_key));

    try exportScreenBlob(&out, alloc, .primary, t.screens.get(.primary).?);
    if (has_alt) try exportScreenBlob(&out, alloc, .alternate, t.screens.get(.alternate).?);

    try appendInt(&out, alloc, u16, t.scrolling_region.top);
    try appendInt(&out, alloc, u16, t.scrolling_region.bottom);
    try appendInt(&out, alloc, u16, t.scrolling_region.left);
    try appendInt(&out, alloc, u16, t.scrolling_region.right);

    try appendModeState(&out, alloc, t.modes);
    try appendColors(&out, alloc, t.colors);
    try appendTabstops(&out, alloc, t.tabstops);
    try appendOptionalCodepoint(&out, alloc, t.previous_char);
    try appendInt(&out, alloc, u8, @intFromEnum(t.status_display));
    try appendInt(&out, alloc, i32, @intFromEnum(t.mouse_shape));
    try appendInt(&out, alloc, u8, @intFromEnum(t.flags.shell_redraws_prompt));
    try appendBool(&out, alloc, t.flags.modify_other_keys_2);
    try appendInt(&out, alloc, u8, @intFromEnum(t.flags.mouse_event));
    try appendInt(&out, alloc, u8, @intFromEnum(t.flags.mouse_format));
    try appendInt(&out, alloc, u8, @intFromEnum(t.flags.mouse_shift_capture));
    try appendString(&out, alloc, t.getPwd() orelse "");
    try appendString(&out, alloc, t.getTitle() orelse "");

    return try out.toOwnedSlice(alloc);
}

pub fn importInto(t: *Terminal, data: []const u8) Error!void {
    var reader: Reader = .{ .data = data };

    const version = try reader.int(u8);
    if (version != terminal_version) return error.InvalidSnapshot;

    const cols = try reader.int(u16);
    const rows = try reader.int(u16);
    if (cols == 0 or rows == 0) return error.InvalidSnapshot;

    const screen_count = try reader.int(u8);
    if (screen_count == 0 or screen_count > 2) return error.InvalidSnapshot;
    const active_key = try screenKeyFromByte(try reader.int(u8));

    const alloc = t.gpa();
    var temp = try Terminal.init(alloc, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback = 0,
    });
    var committed = false;
    defer if (!committed) temp.deinit(alloc);

    var have_primary = false;
    var have_alt = false;
    var i: usize = 0;
    while (i < screen_count) : (i += 1) {
        const key = try screenKeyFromByte(try reader.int(u8));
        const blob_len = try reader.int(u32);
        const blob = try reader.take(blob_len);

        switch (key) {
            .primary => {
                if (have_primary) return error.InvalidSnapshot;
                have_primary = true;
                try importScreenBlob(temp.screens.get(.primary).?, blob);
            },
            .alternate => {
                if (have_alt) return error.InvalidSnapshot;
                have_alt = true;
                const alt = try temp.screens.getInit(alloc, .alternate, .{
                    .cols = cols,
                    .rows = rows,
                    .max_scrollback = 0,
                });
                try importScreenBlob(alt, blob);
            },
        }
    }

    if (!have_primary) return error.InvalidSnapshot;
    if (active_key == .alternate and !have_alt) return error.InvalidSnapshot;
    if (!have_alt) temp.screens.remove(alloc, .alternate);

    temp.scrolling_region = .{
        .top = try reader.int(u16),
        .bottom = try reader.int(u16),
        .left = try reader.int(u16),
        .right = try reader.int(u16),
    };
    if (temp.scrolling_region.bottom >= temp.rows or
        temp.scrolling_region.right >= temp.cols or
        temp.scrolling_region.top > temp.scrolling_region.bottom or
        temp.scrolling_region.left > temp.scrolling_region.right)
    {
        return error.InvalidSnapshot;
    }

    temp.modes = try readModeState(&reader);
    temp.colors = try readColors(&reader);
    try readTabstops(&reader, alloc, &temp.tabstops);
    temp.previous_char = try readOptionalCodepoint(&reader);
    temp.status_display = try readStatusDisplay(&reader);
    temp.mouse_shape = try readMouseShape(&reader);
    temp.flags.shell_redraws_prompt = try reader.enumValue(osc.semantic_prompt.Redraw, u8);
    temp.flags.modify_other_keys_2 = try reader.readBool();
    temp.flags.mouse_event = try reader.enumValue(mouse.Event, u8);
    temp.flags.mouse_format = try reader.enumValue(mouse.Format, u8);
    temp.flags.mouse_shift_capture = try reader.enumValue(@FieldType(@TypeOf(temp.flags), "mouse_shift_capture"), u8);
    try temp.setPwd(try reader.slice());
    try temp.setTitle(try reader.slice());

    if (reader.remaining() != 0) return error.InvalidSnapshot;

    temp.screens.switchTo(active_key);

    var old = t.*;
    const old_alloc = old.gpa();
    t.* = temp;
    committed = true;

    t.flags.dirty.clear = true;
    t.flags.dirty.palette = true;
    old.deinit(old_alloc);
}

fn exportScreenBlob(
    out: *std.ArrayList(u8),
    alloc: Allocator,
    key: ScreenSet.Key,
    screen: *const Screen,
) Error!void {
    var blob: std.ArrayList(u8) = .empty;
    defer blob.deinit(alloc);

    try appendInt(&blob, alloc, u8, screen_version);
    try appendInt(&blob, alloc, u64, screen.pages.explicit_max_size);

    const page_count = countPages(screen);
    try appendInt(&blob, alloc, u32, @intCast(page_count));

    var it = screen.pages.pages.first;
    while (it) |node| : (it = node.next) {
        const page = &node.data;
        try appendInt(&blob, alloc, u32, @intCast(page.memory.len));
        try appendInt(&blob, alloc, u16, page.size.cols);
        try appendInt(&blob, alloc, u16, page.size.rows);
        try appendInt(&blob, alloc, u16, page.capacity.cols);
        try appendInt(&blob, alloc, u16, page.capacity.rows);
        try appendInt(&blob, alloc, u16, page.capacity.styles);
        try appendInt(&blob, alloc, u16, page.capacity.hyperlink_bytes);
        try appendInt(&blob, alloc, u32, page.capacity.grapheme_bytes);
        try appendInt(&blob, alloc, u32, page.capacity.string_bytes);
        try appendBool(&blob, alloc, page.dirty);
        try blob.appendSlice(alloc, page.memory);
    }

    try appendInt(&blob, alloc, u16, screen.cursor.x);
    try appendInt(&blob, alloc, u16, screen.cursor.y);
    try appendInt(&blob, alloc, u8, @intFromEnum(screen.cursor.cursor_style));
    try appendBool(&blob, alloc, screen.cursor.pending_wrap);
    try appendBool(&blob, alloc, screen.cursor.protected);
    try appendStyle(&blob, alloc, screen.cursor.style);
    try appendInt(&blob, alloc, stylepkg.Id, screen.cursor.style_id);
    try appendInt(&blob, alloc, u8, @intFromEnum(screen.cursor.semantic_content));
    try appendBool(&blob, alloc, screen.cursor.semantic_content_clear_eol);
    try appendInt(&blob, alloc, u32, screen.cursor.hyperlink_implicit_id);
    try appendInt(&blob, alloc, hyperlink.Id, screen.cursor.hyperlink_id);
    try appendSavedCursor(&blob, alloc, screen.saved_cursor);
    try appendCharsetState(&blob, alloc, screen.charset);
    try appendInt(&blob, alloc, u8, @intFromEnum(screen.protected_mode));
    try appendKeyFlagStack(&blob, alloc, screen.kitty_keyboard);
    try appendBool(&blob, alloc, screen.semantic_prompt.seen);
    try appendSemanticClick(&blob, alloc, screen.semantic_prompt.click);

    try appendInt(out, alloc, u8, screenKeyByte(key));
    try appendInt(out, alloc, u32, @intCast(blob.items.len));
    try out.appendSlice(alloc, blob.items);
}

fn importScreenBlob(screen: *Screen, blob: []const u8) Error!void {
    var reader: Reader = .{ .data = blob };

    const version = try reader.int(u8);
    if (version != screen_version) return error.InvalidSnapshot;

    const explicit_max_size = try reader.int(u64);
    const page_count = try reader.int(u32);
    if (page_count == 0) return error.InvalidSnapshot;

    var pages: std.ArrayList(PageList.SnapshotPage) = .empty;
    defer pages.deinit(screen.alloc);

    var i: usize = 0;
    while (i < page_count) : (i += 1) {
        const memory_len = try reader.int(u32);
        const page_size: pagepkg.Size = .{
            .cols = try reader.int(u16),
            .rows = try reader.int(u16),
        };
        const page_cap: pagepkg.Capacity = .{
            .cols = try reader.int(u16),
            .rows = try reader.int(u16),
            .styles = try reader.int(u16),
            .hyperlink_bytes = try reader.int(u16),
            .grapheme_bytes = try reader.int(u32),
            .string_bytes = try reader.int(u32),
        };
        const dirty = try reader.readBool();
        const memory = try reader.take(memory_len);
        try pages.append(screen.alloc, .{
            .capacity = page_cap,
            .size = page_size,
            .dirty = dirty,
            .memory = memory,
        });
    }

    try screen.pages.snapshotReplace(pages.items);
    screen.pages.explicit_max_size = std.math.cast(usize, explicit_max_size) orelse return error.InvalidSnapshot;
    screen.no_scrollback = screen.pages.explicit_max_size == 0;

    const cursor_x = try reader.int(u16);
    const cursor_y = try reader.int(u16);
    if (cursor_x >= screen.pages.cols or cursor_y >= screen.pages.rows) return error.InvalidSnapshot;

    const cursor_pin = screen.pages.pin(.{ .active = .{ .x = cursor_x, .y = cursor_y } }) orelse
        return error.InvalidSnapshot;
    screen.cursor.page_pin.* = cursor_pin;
    screen.cursor.cursor_style = try reader.enumValue(Screen.CursorStyle, u8);
    screen.cursor.pending_wrap = try reader.readBool();
    screen.cursor.protected = try reader.readBool();
    screen.cursor.style = try readStyle(&reader);
    const current_style_id = try reader.int(stylepkg.Id);
    screen.cursor.semantic_content = try reader.enumValue(pagepkg.Cell.SemanticContent, u8);
    screen.cursor.semantic_content_clear_eol = try reader.readBool();
    const current_hyperlink_implicit_id = try reader.int(u32);
    const current_hyperlink_id = try reader.int(hyperlink.Id);
    screen.saved_cursor = try readSavedCursor(&reader);
    screen.charset = try readCharsetState(&reader);
    screen.protected_mode = try reader.enumValue(ansi.ProtectedMode, u8);
    screen.kitty_keyboard = try readKeyFlagStack(&reader);
    screen.semantic_prompt = .{
        .seen = try reader.readBool(),
        .click = try readSemanticClick(&reader),
    };

    if (reader.remaining() != 0) return error.InvalidSnapshot;

    screen.cursorReload();
    try restoreCursorStyle(screen, current_style_id);
    screen.cursor.hyperlink_implicit_id = current_hyperlink_implicit_id;
    try restoreCursorHyperlink(screen, current_hyperlink_id);
}

fn appendModeState(out: *std.ArrayList(u8), alloc: Allocator, state: modespkg.ModeState) Error!void {
    try appendInt(out, alloc, ModeBits, @bitCast(state.values));
    try appendInt(out, alloc, ModeBits, @bitCast(state.saved));
    try appendInt(out, alloc, ModeBits, @bitCast(state.default));
}

fn readModeState(reader: *Reader) Error!modespkg.ModeState {
    return .{
        .values = @bitCast(try reader.int(ModeBits)),
        .saved = @bitCast(try reader.int(ModeBits)),
        .default = @bitCast(try reader.int(ModeBits)),
    };
}

fn appendColors(out: *std.ArrayList(u8), alloc: Allocator, colors_: Terminal.Colors) Error!void {
    try appendDynamicRGB(out, alloc, colors_.background);
    try appendDynamicRGB(out, alloc, colors_.foreground);
    try appendDynamicRGB(out, alloc, colors_.cursor);
    try appendPalette(out, alloc, &colors_.palette.current);
    try appendPalette(out, alloc, &colors_.palette.original);
    try appendPaletteMask(out, alloc, colors_.palette.mask);
}

fn readColors(reader: *Reader) Error!Terminal.Colors {
    var result: Terminal.Colors = undefined;
    result.background = try readDynamicRGB(reader);
    result.foreground = try readDynamicRGB(reader);
    result.cursor = try readDynamicRGB(reader);
    result.palette.current = try readPalette(reader);
    result.palette.original = try readPalette(reader);
    result.palette.mask = try readPaletteMask(reader);
    return result;
}

fn appendTabstops(out: *std.ArrayList(u8), alloc: Allocator, tabstops: Tabstops) Error!void {
    try appendInt(out, alloc, u32, @intCast(tabstops.cols));
    try appendSliceLen(out, alloc, std.mem.asBytes(&tabstops.prealloc_stops));
    try appendSliceLen(out, alloc, tabstops.dynamic_stops);
}

fn readTabstops(reader: *Reader, alloc: Allocator, tabstops: *Tabstops) Error!void {
    const cols = try reader.int(u32);
    const prealloc = try reader.slice();
    const dynamic = try reader.slice();
    if (prealloc.len != @sizeOf(@TypeOf(tabstops.prealloc_stops))) return error.InvalidSnapshot;

    tabstops.deinit(alloc);
    tabstops.* = .{};
    try tabstops.resize(alloc, @intCast(cols));

    @memcpy(std.mem.asBytes(&tabstops.prealloc_stops), prealloc);
    if (dynamic.len != tabstops.dynamic_stops.len) return error.InvalidSnapshot;
    @memcpy(tabstops.dynamic_stops, dynamic);
    tabstops.cols = @intCast(cols);
}

fn appendOptionalCodepoint(
    out: *std.ArrayList(u8),
    alloc: Allocator,
    cp: ?u21,
) Error!void {
    try appendBool(out, alloc, cp != null);
    if (cp) |v| try appendInt(out, alloc, u32, v);
}

fn readOptionalCodepoint(reader: *Reader) Error!?u21 {
    if (!try reader.readBool()) return null;
    return std.math.cast(u21, try reader.int(u32)) orelse return error.InvalidSnapshot;
}

fn appendSavedCursor(
    out: *std.ArrayList(u8),
    alloc: Allocator,
    saved: ?Screen.SavedCursor,
) Error!void {
    try appendBool(out, alloc, saved != null);
    if (saved) |v| {
        try appendInt(out, alloc, u16, v.x);
        try appendInt(out, alloc, u16, v.y);
        try appendStyle(out, alloc, v.style);
        try appendBool(out, alloc, v.protected);
        try appendBool(out, alloc, v.pending_wrap);
        try appendBool(out, alloc, v.origin);
        try appendCharsetState(out, alloc, v.charset);
    }
}

fn readSavedCursor(reader: *Reader) Error!?Screen.SavedCursor {
    if (!try reader.readBool()) return null;
    return .{
        .x = try reader.int(u16),
        .y = try reader.int(u16),
        .style = try readStyle(reader),
        .protected = try reader.readBool(),
        .pending_wrap = try reader.readBool(),
        .origin = try reader.readBool(),
        .charset = try readCharsetState(reader),
    };
}

fn appendCharsetState(
    out: *std.ArrayList(u8),
    alloc: Allocator,
    charset: Screen.CharsetState,
) Error!void {
    try appendInt(out, alloc, u8, @intFromEnum(charset.charsets.g0));
    try appendInt(out, alloc, u8, @intFromEnum(charset.charsets.g1));
    try appendInt(out, alloc, u8, @intFromEnum(charset.charsets.g2));
    try appendInt(out, alloc, u8, @intFromEnum(charset.charsets.g3));
    try appendInt(out, alloc, u8, @intFromEnum(charset.gl));
    try appendInt(out, alloc, u8, @intFromEnum(charset.gr));
    try appendBool(out, alloc, charset.single_shift != null);
    if (charset.single_shift) |slot| try appendInt(out, alloc, u8, @intFromEnum(slot));
}

fn readCharsetState(reader: *Reader) Error!Screen.CharsetState {
    var state: Screen.CharsetState = .{};
    state.charsets.g0 = try reader.enumValue(charsets.Charset, u8);
    state.charsets.g1 = try reader.enumValue(charsets.Charset, u8);
    state.charsets.g2 = try reader.enumValue(charsets.Charset, u8);
    state.charsets.g3 = try reader.enumValue(charsets.Charset, u8);
    state.gl = try reader.enumValue(charsets.Slots, u8);
    state.gr = try reader.enumValue(charsets.Slots, u8);
    state.single_shift = if (try reader.readBool())
        try reader.enumValue(charsets.Slots, u8)
    else
        null;
    return state;
}

fn appendKeyFlagStack(
    out: *std.ArrayList(u8),
    alloc: Allocator,
    stack: kitty.KeyFlagStack,
) Error!void {
    try appendInt(out, alloc, u8, @intCast(stack.idx));
    for (stack.flags) |flags| try appendInt(out, alloc, u8, @intCast(flags.int()));
}

fn readKeyFlagStack(reader: *Reader) Error!kitty.KeyFlagStack {
    var stack: kitty.KeyFlagStack = .{};
    stack.idx = std.math.cast(u3, try reader.int(u8)) orelse return error.InvalidSnapshot;
    for (&stack.flags) |*flags| {
        const value = try reader.int(u8);
        if (value > std.math.maxInt(u5)) return error.InvalidSnapshot;
        flags.* = @bitCast(@as(u5, @intCast(value)));
    }
    return stack;
}

fn appendSemanticClick(
    out: *std.ArrayList(u8),
    alloc: Allocator,
    click: Screen.SemanticPrompt.SemanticClick,
) Error!void {
    switch (click) {
        .none => try appendInt(out, alloc, u8, 0),
        .click_events => try appendInt(out, alloc, u8, 1),
        .cl => |v| {
            try appendInt(out, alloc, u8, 2);
            try appendInt(out, alloc, u8, @intFromEnum(v));
        },
    }
}

fn readSemanticClick(reader: *Reader) Error!Screen.SemanticPrompt.SemanticClick {
    return switch (try reader.int(u8)) {
        0 => .none,
        1 => .click_events,
        2 => .{ .cl = try reader.enumValue(osc.semantic_prompt.Click, u8) },
        else => error.InvalidSnapshot,
    };
}

fn restoreCursorHyperlink(
    screen: *Screen,
    current_id: hyperlink.Id,
) Error!void {
    screen.cursor.hyperlink_id = 0;
    screen.cursor.hyperlink = null;
    if (current_id == 0) return;

    var page = &screen.cursor.page_pin.node.data;
    if (current_id >= page.hyperlink_set.layout.cap) return error.InvalidSnapshot;

    const item = &page.hyperlink_set.items.ptr(page.memory)[current_id];
    if (item.meta.ref == 0) return error.InvalidSnapshot;

    const entry = page.hyperlink_set.get(page.memory, current_id);
    const link = try screen.alloc.create(hyperlink.Hyperlink);
    errdefer screen.alloc.destroy(link);
    link.* = .{
        .uri = try screen.alloc.dupe(u8, entry.uri.slice(page.memory)),
        .id = switch (entry.id) {
            .implicit => |id| .{ .implicit = id },
            .explicit => |slice| .{ .explicit = try screen.alloc.dupe(u8, slice.slice(page.memory)) },
        },
    };
    errdefer link.deinit(screen.alloc);

    screen.cursor.hyperlink_id = current_id;
    screen.cursor.hyperlink = link;
}

fn restoreCursorStyle(
    screen: *Screen,
    current_id: stylepkg.Id,
) Error!void {
    if (current_id == stylepkg.default_id) {
        if (!screen.cursor.style.default()) return error.InvalidSnapshot;
        screen.cursor.style_id = stylepkg.default_id;
        return;
    }

    var page = &screen.cursor.page_pin.node.data;
    if (current_id >= page.styles.layout.cap) return error.InvalidSnapshot;

    const item = &page.styles.items.ptr(page.memory)[current_id];
    if (item.meta.ref == 0) return error.InvalidSnapshot;

    const current_style = page.styles.get(page.memory, current_id);
    if (!current_style.eql(screen.cursor.style)) return error.InvalidSnapshot;

    screen.cursor.style_id = current_id;
}

fn appendDynamicRGB(
    out: *std.ArrayList(u8),
    alloc: Allocator,
    value: color.DynamicRGB,
) Error!void {
    try appendBool(out, alloc, value.override != null);
    if (value.override) |rgb| try appendRGB(out, alloc, rgb);
    try appendBool(out, alloc, value.default != null);
    if (value.default) |rgb| try appendRGB(out, alloc, rgb);
}

fn readDynamicRGB(reader: *Reader) Error!color.DynamicRGB {
    return .{
        .override = if (try reader.readBool()) try readRGB(reader) else null,
        .default = if (try reader.readBool()) try readRGB(reader) else null,
    };
}

fn appendPalette(
    out: *std.ArrayList(u8),
    alloc: Allocator,
    palette: *const color.Palette,
) Error!void {
    for (palette) |rgb| try appendRGB(out, alloc, rgb);
}

fn appendPaletteMask(
    out: *std.ArrayList(u8),
    alloc: Allocator,
    mask: color.PaletteMask,
) Error!void {
    var buf: [32]u8 = @splat(0);
    for (0..256) |idx| {
        if (!mask.isSet(idx)) continue;
        buf[idx / 8] |= @as(u8, 1) << @intCast(idx % 8);
    }
    try appendSliceLen(out, alloc, &buf);
}

fn readPalette(reader: *Reader) Error!color.Palette {
    var palette: color.Palette = undefined;
    for (&palette) |*rgb| rgb.* = try readRGB(reader);
    return palette;
}

fn readPaletteMask(reader: *Reader) Error!color.PaletteMask {
    const bytes = try reader.slice();
    if (bytes.len != 32) return error.InvalidSnapshot;

    var mask = color.PaletteMask.initEmpty();
    for (bytes, 0..) |byte, byte_idx| {
        for (0..8) |bit_idx| {
            const bit = @as(u8, 1) << @intCast(bit_idx);
            if ((byte & bit) == 0) continue;
            mask.set(byte_idx * 8 + bit_idx);
        }
    }
    return mask;
}

fn appendStyle(
    out: *std.ArrayList(u8),
    alloc: Allocator,
    s: stylepkg.Style,
) Error!void {
    try appendStyleColor(out, alloc, s.fg_color);
    try appendStyleColor(out, alloc, s.bg_color);
    try appendStyleColor(out, alloc, s.underline_color);
    try appendInt(out, alloc, u16, @bitCast(s.flags));
}

fn readStyle(reader: *Reader) Error!stylepkg.Style {
    return .{
        .fg_color = try readStyleColor(reader),
        .bg_color = try readStyleColor(reader),
        .underline_color = try readStyleColor(reader),
        .flags = @bitCast(try reader.int(u16)),
    };
}

fn appendStyleColor(
    out: *std.ArrayList(u8),
    alloc: Allocator,
    value: stylepkg.Style.Color,
) Error!void {
    switch (value) {
        .none => try appendInt(out, alloc, u8, 0),
        .palette => |idx| {
            try appendInt(out, alloc, u8, 1);
            try appendInt(out, alloc, u8, idx);
        },
        .rgb => |rgb| {
            try appendInt(out, alloc, u8, 2);
            try appendRGB(out, alloc, rgb);
        },
    }
}

fn readStyleColor(reader: *Reader) Error!stylepkg.Style.Color {
    return switch (try reader.int(u8)) {
        0 => .none,
        1 => .{ .palette = try reader.int(u8) },
        2 => .{ .rgb = try readRGB(reader) },
        else => error.InvalidSnapshot,
    };
}

fn appendRGB(out: *std.ArrayList(u8), alloc: Allocator, rgb: color.RGB) Error!void {
    try appendInt(out, alloc, u8, rgb.r);
    try appendInt(out, alloc, u8, rgb.g);
    try appendInt(out, alloc, u8, rgb.b);
}

fn readRGB(reader: *Reader) Error!color.RGB {
    return .{
        .r = try reader.int(u8),
        .g = try reader.int(u8),
        .b = try reader.int(u8),
    };
}

fn readStatusDisplay(reader: *Reader) Error!ansi.StatusDisplay {
    return std.meta.intToEnum(ansi.StatusDisplay, try reader.int(u8)) catch error.InvalidSnapshot;
}

fn readMouseShape(reader: *Reader) Error!mouse.Shape {
    return std.meta.intToEnum(mouse.Shape, try reader.int(i32)) catch error.InvalidSnapshot;
}

fn appendString(out: *std.ArrayList(u8), alloc: Allocator, str: []const u8) Error!void {
    try appendSliceLen(out, alloc, str);
}

fn appendSliceLen(out: *std.ArrayList(u8), alloc: Allocator, slice: []const u8) Error!void {
    try appendInt(out, alloc, u32, std.math.cast(u32, slice.len) orelse return error.InvalidSnapshot);
    try out.appendSlice(alloc, slice);
}

fn appendBool(out: *std.ArrayList(u8), alloc: Allocator, value: bool) Error!void {
    try appendInt(out, alloc, u8, if (value) 1 else 0);
}

fn appendInt(
    out: *std.ArrayList(u8),
    alloc: Allocator,
    comptime T: type,
    value: T,
) Error!void {
    const byte_len = @divExact(@typeInfo(T).int.bits, 8);
    var buf: [byte_len]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try out.appendSlice(alloc, buf[0..]);
}

fn screenKeyByte(key: ScreenSet.Key) u8 {
    return switch (key) {
        .primary => 0,
        .alternate => 1,
    };
}

fn screenKeyFromByte(value: u8) Error!ScreenSet.Key {
    return switch (value) {
        0 => .primary,
        1 => .alternate,
        else => error.InvalidSnapshot,
    };
}

fn countPages(screen: *const Screen) usize {
    var count: usize = 0;
    var it = screen.pages.pages.first;
    while (it) |node| : (it = node.next) {
        count += 1;
    }
    return count;
}

fn roundTripTerminal(
    alloc: Allocator,
    src: *Terminal,
    dst_cols: u16,
    dst_rows: u16,
) !Terminal {
    const testing = std.testing;

    const blob = try exportAlloc(src, alloc);
    defer alloc.free(blob);

    var dst = try Terminal.init(alloc, .{
        .cols = dst_cols,
        .rows = dst_rows,
        .max_scrollback = 0,
    });
    errdefer dst.deinit(alloc);

    try importInto(&dst, blob);

    const round_trip = try exportAlloc(&dst, alloc);
    defer alloc.free(round_trip);

    try expectTerminalEquivalent(alloc, src, &dst);
    try testing.expectEqualSlices(u8, blob, round_trip);

    return dst;
}

fn expectScreenDumpEqual(
    alloc: Allocator,
    src: *const Screen,
    dst: *const Screen,
    pt: point.Point,
) !void {
    const testing = std.testing;

    const src_dump = try src.dumpStringAlloc(alloc, pt);
    defer alloc.free(src_dump);

    const dst_dump = try dst.dumpStringAlloc(alloc, pt);
    defer alloc.free(dst_dump);

    try testing.expectEqualStrings(src_dump, dst_dump);
}

fn expectOptionalStringEqual(expected: ?[:0]const u8, actual: ?[:0]const u8) !void {
    const testing = std.testing;

    try testing.expectEqual(expected != null, actual != null);
    if (expected) |value| {
        try testing.expectEqualStrings(value, actual.?);
    }
}

fn expectHyperlinkEqual(
    expected: ?*const hyperlink.Hyperlink,
    actual: ?*const hyperlink.Hyperlink,
) !void {
    const testing = std.testing;

    try testing.expectEqual(expected != null, actual != null);
    if (expected) |expected_link| {
        const actual_link = actual.?;
        try testing.expectEqualStrings(expected_link.uri, actual_link.uri);
        try testing.expectEqual(std.meta.activeTag(expected_link.id), std.meta.activeTag(actual_link.id));
        switch (expected_link.id) {
            .implicit => |id| try testing.expectEqual(id, actual_link.id.implicit),
            .explicit => |id| try testing.expectEqualStrings(id, actual_link.id.explicit),
        }
    }
}

fn expectPageListEquivalent(expected: *const PageList, actual: *const PageList) !void {
    const testing = std.testing;

    try testing.expectEqual(expected.cols, actual.cols);
    try testing.expectEqual(expected.rows, actual.rows);
    try testing.expectEqual(expected.page_size, actual.page_size);
    try testing.expectEqual(expected.explicit_max_size, actual.explicit_max_size);
    try testing.expectEqual(expected.total_rows, actual.total_rows);

    var expected_node = expected.pages.first;
    var actual_node = actual.pages.first;
    while (expected_node != null and actual_node != null) {
        const expected_page = &expected_node.?.data;
        const actual_page = &actual_node.?.data;
        try testing.expectEqual(expected_page.size, actual_page.size);
        try testing.expectEqual(expected_page.capacity, actual_page.capacity);
        try testing.expectEqual(expected_page.dirty, actual_page.dirty);
        try testing.expectEqual(expected_page.memory.len, actual_page.memory.len);
        try testing.expectEqualSlices(u8, expected_page.memory, actual_page.memory);

        expected_node = expected_node.?.next;
        actual_node = actual_node.?.next;
    }

    try testing.expect(expected_node == null);
    try testing.expect(actual_node == null);
}

fn expectScreenEquivalent(
    alloc: Allocator,
    expected: *const Screen,
    actual: *const Screen,
) !void {
    const testing = std.testing;

    try testing.expectEqual(expected.no_scrollback, actual.no_scrollback);
    try testing.expectEqual(expected.protected_mode, actual.protected_mode);
    try testing.expectEqualDeep(expected.kitty_keyboard, actual.kitty_keyboard);
    try testing.expectEqualDeep(expected.charset, actual.charset);
    try testing.expectEqual(expected.semantic_prompt.seen, actual.semantic_prompt.seen);
    try testing.expectEqual(expected.semantic_prompt.click, actual.semantic_prompt.click);

    try testing.expectEqual(expected.cursor.x, actual.cursor.x);
    try testing.expectEqual(expected.cursor.y, actual.cursor.y);
    try testing.expectEqual(expected.cursor.cursor_style, actual.cursor.cursor_style);
    try testing.expectEqual(expected.cursor.pending_wrap, actual.cursor.pending_wrap);
    try testing.expectEqual(expected.cursor.protected, actual.cursor.protected);
    try testing.expectEqualDeep(expected.cursor.style, actual.cursor.style);
    try testing.expectEqual(expected.cursor.style_id, actual.cursor.style_id);
    try testing.expectEqual(expected.cursor.hyperlink_id, actual.cursor.hyperlink_id);
    try testing.expectEqual(expected.cursor.hyperlink_implicit_id, actual.cursor.hyperlink_implicit_id);
    try testing.expectEqual(expected.cursor.semantic_content, actual.cursor.semantic_content);
    try testing.expectEqual(
        expected.cursor.semantic_content_clear_eol,
        actual.cursor.semantic_content_clear_eol,
    );
    try expectHyperlinkEqual(expected.cursor.hyperlink, actual.cursor.hyperlink);
    try testing.expectEqual(expected.saved_cursor != null, actual.saved_cursor != null);
    if (expected.saved_cursor) |saved| {
        try testing.expectEqualDeep(saved, actual.saved_cursor.?);
    }

    try expectPageListEquivalent(&expected.pages, &actual.pages);
    try expectScreenDumpEqual(alloc, expected, actual, .{ .screen = .{} });
}

fn expectTerminalEquivalent(
    alloc: Allocator,
    expected: *const Terminal,
    actual: *const Terminal,
) !void {
    const testing = std.testing;

    try testing.expectEqual(expected.cols, actual.cols);
    try testing.expectEqual(expected.rows, actual.rows);
    try testing.expectEqual(expected.scrolling_region, actual.scrolling_region);
    try testing.expectEqualDeep(expected.modes, actual.modes);
    try testing.expectEqualDeep(expected.colors, actual.colors);
    try testing.expectEqual(expected.previous_char, actual.previous_char);
    try testing.expectEqual(expected.status_display, actual.status_display);
    try testing.expectEqual(expected.mouse_shape, actual.mouse_shape);
    try testing.expectEqual(expected.flags.shell_redraws_prompt, actual.flags.shell_redraws_prompt);
    try testing.expectEqual(expected.flags.modify_other_keys_2, actual.flags.modify_other_keys_2);
    try testing.expectEqual(expected.flags.mouse_event, actual.flags.mouse_event);
    try testing.expectEqual(expected.flags.mouse_format, actual.flags.mouse_format);
    try testing.expectEqual(expected.flags.mouse_shift_capture, actual.flags.mouse_shift_capture);
    try testing.expectEqual(expected.tabstops.cols, actual.tabstops.cols);
    try testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&expected.tabstops.prealloc_stops),
        std.mem.asBytes(&actual.tabstops.prealloc_stops),
    );
    try testing.expectEqualSlices(u8, expected.tabstops.dynamic_stops, actual.tabstops.dynamic_stops);
    try expectOptionalStringEqual(expected.getPwd(), actual.getPwd());
    try expectOptionalStringEqual(expected.getTitle(), actual.getTitle());
    try testing.expectEqual(expected.screens.active_key, actual.screens.active_key);
    try testing.expectEqual(
        expected.screens.get(.alternate) != null,
        actual.screens.get(.alternate) != null,
    );

    try expectScreenEquivalent(alloc, expected.screens.get(.primary).?, actual.screens.get(.primary).?);
    if (expected.screens.get(.alternate)) |expected_alt| {
        try expectScreenEquivalent(alloc, expected_alt, actual.screens.get(.alternate).?);
    }
}

fn overwriteInt(
    data: []u8,
    offset: usize,
    comptime T: type,
    value: T,
) void {
    const byte_len = @divExact(@typeInfo(T).int.bits, 8);
    var buf: [byte_len]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    @memcpy(data[offset..][0..buf.len], &buf);
}

fn screenKeyOffset(data: []const u8, index: usize) !usize {
    var reader: Reader = .{ .data = data };
    _ = try reader.int(u8);
    _ = try reader.int(u16);
    _ = try reader.int(u16);
    const screen_count = try reader.int(u8);
    _ = try reader.int(u8);

    if (index >= screen_count) return error.InvalidSnapshot;
    for (0..screen_count) |i| {
        const key_offset = reader.idx;
        _ = try reader.int(u8);
        const blob_len = try reader.int(u32);
        if (i == index) return key_offset;
        _ = try reader.take(blob_len);
    }

    return error.InvalidSnapshot;
}

fn firstPageCapColsOffset(data: []const u8, screen_index: usize) !usize {
    var reader: Reader = .{ .data = data };
    _ = try reader.int(u8);
    _ = try reader.int(u16);
    _ = try reader.int(u16);
    const screen_count = try reader.int(u8);
    _ = try reader.int(u8);

    if (screen_index >= screen_count) return error.InvalidSnapshot;
    for (0..screen_count) |i| {
        _ = try reader.int(u8);
        const blob_len = try reader.int(u32);
        const blob_start = reader.idx;
        if (i == screen_index) {
            if (blob_len < 23) return error.InvalidSnapshot;
            return blob_start + 21;
        }
        _ = try reader.take(blob_len);
    }

    return error.InvalidSnapshot;
}

test "snapshot round trip preserves bytes and resizes destination" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var src = try Terminal.init(alloc, .{
        .cols = 5,
        .rows = 3,
        .max_scrollback = 10_000,
    });
    defer src.deinit(alloc);

    try src.printString("one\r\ntwo\r\nthree\r\nfour\r\n");
    src.colors.background.override = .{ .r = 1, .g = 2, .b = 3 };
    src.colors.foreground.default = .{ .r = 4, .g = 5, .b = 6 };
    src.colors.palette.set(42, .{ .r = 7, .g = 8, .b = 9 });
    src.modes.set(.bracketed_paste, true);
    src.previous_char = 'r';
    src.status_display = .main;
    src.mouse_shape = .pointer;
    src.flags.shell_redraws_prompt = .last;
    src.flags.modify_other_keys_2 = true;
    src.flags.mouse_event = .button;
    src.flags.mouse_format = .sgr;
    src.flags.mouse_shift_capture = .true;
    try src.setPwd("/tmp/demo");
    try src.setTitle("snapshot");

    src.screens.active.cursor.style = .{
        .flags = .{ .bold = true, .italic = true },
        .fg_color = .{ .palette = 12 },
        .bg_color = .{ .rgb = .{ .r = 10, .g = 11, .b = 12 } },
    };
    try src.screens.active.manualStyleUpdate();
    src.screens.active.cursor.semantic_content = .prompt;
    src.screens.active.cursor.semantic_content_clear_eol = true;
    try src.screens.active.startHyperlink("https://example.com", null);
    try src.printString("xy");
    src.screens.active.saved_cursor = .{
        .x = src.screens.active.cursor.x,
        .y = src.screens.active.cursor.y,
        .style = src.screens.active.cursor.style,
        .protected = src.screens.active.cursor.protected,
        .pending_wrap = src.screens.active.cursor.pending_wrap,
        .origin = false,
        .charset = src.screens.active.charset,
    };
    src.screens.active.semantic_prompt = .{
        .seen = true,
        .click = .{ .cl = .line },
    };

    var dst = try roundTripTerminal(alloc, &src, 20, 10);
    defer dst.deinit(alloc);

    try testing.expectEqual(src.previous_char, dst.previous_char);
    try testing.expectEqual(src.status_display, dst.status_display);
    try testing.expectEqual(src.mouse_shape, dst.mouse_shape);
    try testing.expectEqual(src.flags.modify_other_keys_2, dst.flags.modify_other_keys_2);
    try testing.expectEqual(src.flags.mouse_event, dst.flags.mouse_event);
    try testing.expectEqual(src.flags.mouse_format, dst.flags.mouse_format);
    try testing.expectEqual(src.flags.mouse_shift_capture, dst.flags.mouse_shift_capture);
    try testing.expectEqualStrings(src.getPwd().?, dst.getPwd().?);
    try testing.expectEqualStrings(src.getTitle().?, dst.getTitle().?);
    try testing.expectEqualDeep(src.modes, dst.modes);
    try testing.expectEqualDeep(src.colors, dst.colors);
    try testing.expectEqualDeep(src.screens.active.kitty_keyboard, dst.screens.active.kitty_keyboard);
    try testing.expectEqual(src.screens.active.semantic_prompt.seen, dst.screens.active.semantic_prompt.seen);
    try testing.expectEqual(src.screens.active.semantic_prompt.click, dst.screens.active.semantic_prompt.click);
    try testing.expectEqual(src.screens.active.protected_mode, dst.screens.active.protected_mode);
    try testing.expectEqual(src.screens.active.cursor.x, dst.screens.active.cursor.x);
    try testing.expectEqual(src.screens.active.cursor.y, dst.screens.active.cursor.y);
}

test "snapshot preserves alternate screen and primary scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var src = try Terminal.init(alloc, .{
        .cols = 5,
        .rows = 2,
        .max_scrollback = 10_000,
    });
    defer src.deinit(alloc);

    try src.printString("aa\r\nbb\r\ncc\r\n");
    try src.switchScreenMode(.@"1049", true);
    try src.printString("ALT");

    var dst = try roundTripTerminal(alloc, &src, 8, 4);
    defer dst.deinit(alloc);

    try testing.expectEqual(ScreenSet.Key.alternate, dst.screens.active_key);
    try testing.expect(dst.screens.get(.alternate) != null);
    try testing.expect(dst.screens.get(.primary) != null);
    try expectScreenDumpEqual(alloc, src.screens.get(.primary).?, dst.screens.get(.primary).?, .{ .screen = .{} });
    try expectScreenDumpEqual(alloc, src.screens.get(.alternate).?, dst.screens.get(.alternate).?, .{ .screen = .{} });
}

test "snapshot preserves empty terminal" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var src = try Terminal.init(alloc, .{
        .cols = 80,
        .rows = 24,
        .max_scrollback = 10_000,
    });
    defer src.deinit(alloc);

    var dst = try roundTripTerminal(alloc, &src, 12, 6);
    defer dst.deinit(alloc);

    const src_str = try src.plainString(alloc);
    defer alloc.free(src_str);
    const dst_str = try dst.plainString(alloc);
    defer alloc.free(dst_str);

    try testing.expectEqualStrings(src_str, dst_str);
    try testing.expectEqual(ScreenSet.Key.primary, dst.screens.active_key);
    try testing.expect(dst.screens.get(.alternate) == null);
}

test "snapshot preserves large scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var src = try Terminal.init(alloc, .{
        .cols = 8,
        .rows = 3,
        .max_scrollback = 10_000,
    });
    defer src.deinit(alloc);

    var line_buf: [16]u8 = undefined;
    for (0..1_200) |i| {
        const line = try std.fmt.bufPrint(&line_buf, "L{d:0>4}\r\n", .{i});
        try src.printString(line);
    }

    var dst = try roundTripTerminal(alloc, &src, 20, 10);
    defer dst.deinit(alloc);

    try testing.expectEqual(src.screens.get(.primary).?.pages.total_rows, dst.screens.get(.primary).?.pages.total_rows);
    try expectScreenDumpEqual(alloc, src.screens.get(.primary).?, dst.screens.get(.primary).?, .{ .screen = .{} });
}

test "snapshot preserves alternate screen when inactive" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var src = try Terminal.init(alloc, .{
        .cols = 6,
        .rows = 2,
        .max_scrollback = 10_000,
    });
    defer src.deinit(alloc);

    try src.printString("p0\r\np1\r\n");
    try src.switchScreenMode(.@"1049", true);
    try src.printString("alt!");
    try src.switchScreenMode(.@"1049", false);
    try src.printString("home");

    var dst = try roundTripTerminal(alloc, &src, 10, 5);
    defer dst.deinit(alloc);

    try testing.expectEqual(ScreenSet.Key.primary, dst.screens.active_key);
    try testing.expect(dst.screens.get(.alternate) != null);
    try expectScreenDumpEqual(alloc, src.screens.get(.primary).?, dst.screens.get(.primary).?, .{ .screen = .{} });
    try expectScreenDumpEqual(alloc, src.screens.get(.alternate).?, dst.screens.get(.alternate).?, .{ .screen = .{} });
}

test "snapshot import clears stale destination state" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var src = try Terminal.init(alloc, .{
        .cols = 6,
        .rows = 2,
        .max_scrollback = 10_000,
    });
    defer src.deinit(alloc);
    try src.printString("clean");

    const blob = try exportAlloc(&src, alloc);
    defer alloc.free(blob);

    var dst = try Terminal.init(alloc, .{
        .cols = 10,
        .rows = 5,
        .max_scrollback = 10_000,
    });
    defer dst.deinit(alloc);
    try dst.setPwd("/tmp/stale");
    try dst.setTitle("stale");
    try dst.switchScreenMode(.@"1049", true);
    try dst.printString("ALT");
    try dst.switchScreenMode(.@"1049", false);

    try importInto(&dst, blob);
    try expectTerminalEquivalent(alloc, &src, &dst);

    try testing.expect(dst.screens.get(.alternate) == null);
    try testing.expect(dst.getPwd() == null);
    try testing.expect(dst.getTitle() == null);
}

test "snapshot preserves dynamic tabstops" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var src = try Terminal.init(alloc, .{
        .cols = 520,
        .rows = 2,
        .max_scrollback = 0,
    });
    defer src.deinit(alloc);

    src.tabstops.reset(0);
    src.tabstops.set(4);
    src.tabstops.set(519);
    src.tabstops.unset(4);

    var dst = try roundTripTerminal(alloc, &src, 80, 24);
    defer dst.deinit(alloc);

    try testing.expectEqual(src.tabstops.cols, dst.tabstops.cols);
    try testing.expectEqual(src.tabstops.dynamic_stops.len, dst.tabstops.dynamic_stops.len);
    try testing.expectEqual(src.tabstops.get(4), dst.tabstops.get(4));
    try testing.expectEqual(src.tabstops.get(519), dst.tabstops.get(519));
}

test "snapshot preserves rich terminal state" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var src = try Terminal.init(alloc, .{
        .cols = 12,
        .rows = 4,
        .max_scrollback = 10_000,
    });
    defer src.deinit(alloc);

    src.modes.set(.bracketed_paste, true);
    src.modes.set(.grapheme_cluster, true);
    src.modes.set(.origin, true);
    src.modes.save(.origin);
    src.modes.set(.origin, false);
    src.modes.default.cursor_visible = false;
    src.colors.background.override = .{ .r = 1, .g = 2, .b = 3 };
    src.colors.foreground.default = .{ .r = 4, .g = 5, .b = 6 };
    src.colors.cursor.override = .{ .r = 7, .g = 8, .b = 9 };
    src.colors.cursor.default = .{ .r = 16, .g = 17, .b = 18 };
    var palette_default = color.default;
    palette_default[1] = .{ .r = 30, .g = 31, .b = 32 };
    palette_default[2] = .{ .r = 33, .g = 34, .b = 35 };
    src.colors.palette.changeDefault(palette_default);
    src.colors.palette.set(42, .{ .r = 10, .g = 11, .b = 12 });
    src.colors.palette.set(99, .{ .r = 13, .g = 14, .b = 15 });
    src.tabstops.reset(0);
    src.tabstops.set(3);
    src.tabstops.set(10);
    src.scrolling_region = .{ .top = 1, .bottom = 3, .left = 0, .right = 11 };
    src.previous_char = 'z';
    src.status_display = .status_line;
    src.mouse_shape = .pointer;
    src.flags.shell_redraws_prompt = .last;
    src.flags.modify_other_keys_2 = true;
    src.flags.mouse_event = .button;
    src.flags.mouse_format = .sgr_pixels;
    src.flags.mouse_shift_capture = .false;
    try src.setPwd("/tmp/snapshot-rich");
    try src.setTitle("snapshot-rich");

    src.screens.active.protected_mode = .dec;
    src.screens.active.charset.charsets.g1 = .british;
    src.screens.active.charset.charsets.g2 = .dec_special;
    src.screens.active.charset.gl = .G1;
    src.screens.active.charset.gr = .G2;
    src.screens.active.charset.single_shift = .G3;
    src.screens.active.kitty_keyboard.set(.set, .{
        .disambiguate = true,
        .report_events = true,
    });
    src.screens.active.kitty_keyboard.push(.{
        .report_all = true,
        .report_associated = true,
    });
    src.screens.active.semantic_prompt = .{
        .seen = true,
        .click = .{ .cl = .multiple },
    };
    src.screens.active.cursor.cursor_style = .underline;

    src.screens.active.cursor.style = .{
        .flags = .{ .bold = true, .italic = true, .underline = .double },
        .fg_color = .{ .palette = 12 },
        .bg_color = .{ .rgb = .{ .r = 20, .g = 21, .b = 22 } },
        .underline_color = .{ .rgb = .{ .r = 23, .g = 24, .b = 25 } },
    };
    try src.screens.active.manualStyleUpdate();
    src.screens.active.cursor.protected = true;
    src.screens.active.cursor.semantic_content = .prompt;
    src.screens.active.cursor.semantic_content_clear_eol = true;
    try src.printString("abcdefghijklmnop");
    const prompt_pin = src.screens.active.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?;
    prompt_pin.rowAndCell().row.semantic_prompt = .prompt;
    const continuation_pin = src.screens.active.pages.pin(.{ .active = .{ .x = 0, .y = 1 } }).?;
    continuation_pin.rowAndCell().row.semantic_prompt = .prompt_continuation;
    src.screens.active.cursorAbsolute(0, 2);
    try src.screens.active.startHyperlink("https://implicit.example", null);
    try src.printString("i ");
    src.screens.active.endHyperlink();
    try src.screens.active.startHyperlink("https://explicit.example", "snap-id");
    try src.printString("e\u{301}界🙂");
    src.screens.active.saved_cursor = .{
        .x = src.screens.active.cursor.x,
        .y = src.screens.active.cursor.y,
        .style = src.screens.active.cursor.style,
        .protected = src.screens.active.cursor.protected,
        .pending_wrap = src.screens.active.cursor.pending_wrap,
        .origin = true,
        .charset = src.screens.active.charset,
    };
    src.screens.active.cursorAbsolute(2, 1);
    src.screens.active.cursor.pending_wrap = true;

    var dst = try roundTripTerminal(alloc, &src, 40, 10);
    defer dst.deinit(alloc);

    const src_primary = src.screens.get(.primary).?;
    const dst_primary = dst.screens.get(.primary).?;
    try expectScreenDumpEqual(alloc, src_primary, dst_primary, .{ .screen = .{} });
    try testing.expectEqualDeep(src.modes, dst.modes);
    try testing.expectEqualDeep(src.colors, dst.colors);
    try testing.expectEqual(src.tabstops.get(3), dst.tabstops.get(3));
    try testing.expectEqual(src.tabstops.get(10), dst.tabstops.get(10));
    try testing.expectEqual(src.previous_char, dst.previous_char);
    try testing.expectEqual(src.status_display, dst.status_display);
    try testing.expectEqual(src.mouse_shape, dst.mouse_shape);
    try testing.expectEqual(src.flags.shell_redraws_prompt, dst.flags.shell_redraws_prompt);
    try testing.expectEqual(src.flags.modify_other_keys_2, dst.flags.modify_other_keys_2);
    try testing.expectEqual(src.flags.mouse_event, dst.flags.mouse_event);
    try testing.expectEqual(src.flags.mouse_format, dst.flags.mouse_format);
    try testing.expectEqual(src.flags.mouse_shift_capture, dst.flags.mouse_shift_capture);
    try testing.expectEqualStrings(src.getPwd().?, dst.getPwd().?);
    try testing.expectEqualStrings(src.getTitle().?, dst.getTitle().?);
    try testing.expectEqual(src.scrolling_region, dst.scrolling_region);
    try testing.expectEqual(src_primary.protected_mode, dst_primary.protected_mode);
    try testing.expectEqualDeep(src_primary.charset, dst_primary.charset);
    try testing.expectEqualDeep(src_primary.kitty_keyboard, dst_primary.kitty_keyboard);
    try testing.expectEqual(src_primary.semantic_prompt.seen, dst_primary.semantic_prompt.seen);
    try testing.expectEqual(src_primary.semantic_prompt.click, dst_primary.semantic_prompt.click);
    try testing.expectEqual(src_primary.cursor.x, dst_primary.cursor.x);
    try testing.expectEqual(src_primary.cursor.y, dst_primary.cursor.y);
    try testing.expectEqual(src_primary.cursor.pending_wrap, dst_primary.cursor.pending_wrap);
    try testing.expectEqual(src_primary.cursor.protected, dst_primary.cursor.protected);
    try testing.expectEqualDeep(src_primary.cursor.style, dst_primary.cursor.style);
    try testing.expectEqual(src_primary.cursor.semantic_content, dst_primary.cursor.semantic_content);
    try testing.expectEqual(src_primary.cursor.semantic_content_clear_eol, dst_primary.cursor.semantic_content_clear_eol);
    try testing.expectEqual(src_primary.cursor.hyperlink_implicit_id, dst_primary.cursor.hyperlink_implicit_id);
    try testing.expectEqualDeep(src_primary.saved_cursor.?, dst_primary.saved_cursor.?);
}

test "snapshot import keeps styled cursor overwrite mutation-safe" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var src = try Terminal.init(alloc, .{
        .cols = 6,
        .rows = 2,
        .max_scrollback = 10_000,
    });
    defer src.deinit(alloc);

    try src.setAttribute(.{ .bold = {} });
    try src.print('A');
    try src.setAttribute(.{ .unset = {} });
    src.setCursorPos(1, 1);

    try testing.expectEqual(stylepkg.default_id, src.screens.active.cursor.style_id);
    const src_cell = src.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?.cell;
    try testing.expect(src_cell.style_id != stylepkg.default_id);

    var dst = try roundTripTerminal(alloc, &src, 10, 4);
    defer dst.deinit(alloc);

    try dst.print('B');
    dst.screens.active.assertIntegrity();

    const dst_cell = dst.screens.active.pages.getCell(.{ .screen = .{ .x = 0, .y = 0 } }).?.cell;
    try testing.expectEqual(@as(u21, 'B'), dst_cell.content.codepoint);
    try testing.expectEqual(stylepkg.default_id, dst_cell.style_id);
}

test "snapshot import keeps erase display mutation-safe" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var src = try Terminal.init(alloc, .{
        .cols = 8,
        .rows = 3,
        .max_scrollback = 10_000,
    });
    defer src.deinit(alloc);

    try src.setAttribute(.{ .bold = {} });
    try src.printString("AB\r\nCD");
    try src.setAttribute(.{ .unset = {} });

    var dst = try roundTripTerminal(alloc, &src, 12, 6);
    defer dst.deinit(alloc);

    dst.eraseDisplay(.complete, false);
    dst.screens.active.assertIntegrity();

    const cleared = try dst.plainString(alloc);
    defer alloc.free(cleared);
    try testing.expectEqualStrings("", cleared);
}

test "snapshot import keeps clear then style mutation-safe" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var src = try Terminal.init(alloc, .{
        .cols = 8,
        .rows = 3,
        .max_scrollback = 10_000,
    });
    defer src.deinit(alloc);

    try src.setAttribute(.{ .bold = {} });
    try src.printString("AB\r\nCD");
    try src.setAttribute(.{ .unset = {} });

    var dst = try roundTripTerminal(alloc, &src, 12, 6);
    defer dst.deinit(alloc);

    dst.eraseDisplay(.complete, false);
    const x = dst.screens.active.cursor.x;
    const y = dst.screens.active.cursor.y;
    try dst.setAttribute(.{ .bold = {} });
    try dst.print('Z');
    dst.screens.active.assertIntegrity();

    const cell = dst.screens.active.pages.getCell(.{ .screen = .{ .x = x, .y = y } }).?.cell;
    try testing.expectEqual(@as(u21, 'Z'), cell.content.codepoint);
    try testing.expect(cell.style_id != stylepkg.default_id);
}

test "snapshot import failure leaves destination unchanged" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var src = try Terminal.init(alloc, .{
        .cols = 5,
        .rows = 2,
        .max_scrollback = 10_000,
    });
    defer src.deinit(alloc);
    try src.printString("hello");

    var dst = try Terminal.init(alloc, .{
        .cols = 7,
        .rows = 3,
        .max_scrollback = 10_000,
    });
    defer dst.deinit(alloc);
    try dst.printString("world\r\nstate");

    const before = try exportAlloc(&dst, alloc);
    defer alloc.free(before);
    const blob = try exportAlloc(&src, alloc);
    defer alloc.free(blob);

    try testing.expectError(error.InvalidSnapshot, importInto(&dst, blob[0 .. blob.len - 1]));

    const after = try exportAlloc(&dst, alloc);
    defer alloc.free(after);
    try testing.expectEqualSlices(u8, before, after);
}

test "snapshot import rejects truncated blob" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var src = try Terminal.init(alloc, .{
        .cols = 5,
        .rows = 2,
        .max_scrollback = 10_000,
    });
    defer src.deinit(alloc);
    try src.printString("hello");

    const blob = try exportAlloc(&src, alloc);
    defer alloc.free(blob);

    var dst = try Terminal.init(alloc, .{
        .cols = 5,
        .rows = 2,
        .max_scrollback = 0,
    });
    defer dst.deinit(alloc);

    try testing.expectError(error.InvalidSnapshot, importInto(&dst, blob[0 .. blob.len - 1]));
}

test "snapshot import rejects invalid active screen key" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var src = try Terminal.init(alloc, .{
        .cols = 5,
        .rows = 2,
        .max_scrollback = 10_000,
    });
    defer src.deinit(alloc);
    try src.printString("hello");

    const blob = try exportAlloc(&src, alloc);
    defer alloc.free(blob);

    const corrupt = try alloc.dupe(u8, blob);
    defer alloc.free(corrupt);
    corrupt[6] = 9;

    var dst = try Terminal.init(alloc, .{
        .cols = 5,
        .rows = 2,
        .max_scrollback = 0,
    });
    defer dst.deinit(alloc);

    try testing.expectError(error.InvalidSnapshot, importInto(&dst, corrupt));
}

test "snapshot import rejects duplicate screen keys" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var src = try Terminal.init(alloc, .{
        .cols = 5,
        .rows = 2,
        .max_scrollback = 10_000,
    });
    defer src.deinit(alloc);
    try src.printString("aa\r\nbb\r\n");
    try src.switchScreenMode(.@"1049", true);
    try src.printString("ALT");

    const blob = try exportAlloc(&src, alloc);
    defer alloc.free(blob);

    const corrupt = try alloc.dupe(u8, blob);
    defer alloc.free(corrupt);
    const second_key = try screenKeyOffset(corrupt, 1);
    corrupt[second_key] = 0;

    var dst = try Terminal.init(alloc, .{
        .cols = 5,
        .rows = 2,
        .max_scrollback = 0,
    });
    defer dst.deinit(alloc);

    try testing.expectError(error.InvalidSnapshot, importInto(&dst, corrupt));
}

test "snapshot import rejects impossible page capacity" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var src = try Terminal.init(alloc, .{
        .cols = 5,
        .rows = 2,
        .max_scrollback = 10_000,
    });
    defer src.deinit(alloc);
    try src.printString("hello");

    const blob = try exportAlloc(&src, alloc);
    defer alloc.free(blob);

    const corrupt = try alloc.dupe(u8, blob);
    defer alloc.free(corrupt);
    const cap_cols = try firstPageCapColsOffset(corrupt, 0);
    overwriteInt(corrupt, cap_cols, u16, 1);

    var dst = try Terminal.init(alloc, .{
        .cols = 5,
        .rows = 2,
        .max_scrollback = 0,
    });
    defer dst.deinit(alloc);

    try testing.expectError(error.InvalidSnapshot, importInto(&dst, corrupt));
}
