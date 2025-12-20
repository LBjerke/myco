// Minimal animated TUI renderer for simulations; uses ANSI and ASCII shapes.
const std = @import("std");
const events = @import("events.zig");

pub const NodeSnapshot = struct {
    id: u16,
    is_down: bool,
    services: usize,
    missing: usize,
    last_deployed: u64,
    mac_failures: u64,
};

pub const NetStats = struct {
    sent: u64,
    delivered: u64,
    drop_loss: u64,
    drop_congestion: u64,
    drop_partition: u64,
    drop_crypto: u64,
    bytes_in_flight: usize,
};

const Color = enum {
    none,
    dim,
    white,
    green,
    cyan,
    yellow,
    magenta,
    red,
};

const Cell = struct { ch: u8 = ' ', color: Color = .none };
const Point = struct { x: usize, y: usize };

const Canvas = struct {
    width: usize,
    height: usize,
    cells: []Cell,

    fn init(buf: []Cell, w: usize, h: usize) Canvas {
        return .{ .width = w, .height = h, .cells = buf };
    }

    fn clear(self: *Canvas) void {
        for (self.cells) |*c| c.* = .{};
    }

    fn idx(self: *const Canvas, x: usize, y: usize) usize {
        return y * self.width + x;
    }

    fn set(self: *Canvas, x: usize, y: usize, ch: u8, color: Color) void {
        if (x >= self.width or y >= self.height) return;
        const i = self.idx(x, y);
        self.cells[i] = .{ .ch = ch, .color = color };
    }
};

pub fn render(
    writer: anytype,
    tick: u64,
    converged: bool,
    stats: NetStats,
    nodes: []const NodeSnapshot,
    events_view: []const events.PacketEvent,
) !void {
    try writer.writeAll("\x1b[2J\x1b[H"); // clear + home

    try writer.print("MycoSim TUI  tick={d}  state={s}\n", .{ tick, if (converged) "converged" else "running" });
    try writer.print("Net: sent={d} delivered={d} drop_loss={d} drop_cong={d} drop_part={d} drop_crypto={d} bytes_in_flight={d}\n\n", .{
        stats.sent,
        stats.delivered,
        stats.drop_loss,
        stats.drop_congestion,
        stats.drop_partition,
        stats.drop_crypto,
        stats.bytes_in_flight,
    });

    var cell_buf: [96 * 34]Cell = undefined;
    var canvas = Canvas.init(cell_buf[0..], 96, 34);
    canvas.clear();

    var positions_buf: [12]Point = undefined;
    const positions_len = computePositions(&positions_buf, nodes);
    const positions = positions_buf[0..positions_len];

    drawLinks(&canvas, positions, events_view, tick);
    drawPackets(&canvas, positions, events_view, tick);
    drawNodes(&canvas, nodes, positions);

    try flushCanvas(writer, &canvas);
    try writer.writeAll("\nLegend: ");
    try writer.writeAll(colorSeq(.cyan));
    try writer.writeAll("S=Sync ");
    try writer.writeAll(colorSeq(.green));
    try writer.writeAll("D=Deploy ");
    try writer.writeAll(colorSeq(.yellow));
    try writer.writeAll("R=Request ");
    try writer.writeAll(colorSeq(.magenta));
    try writer.writeAll("C=Control ");
    try writer.writeAll(colorSeq(.red));
    try writer.writeAll("x=drop ");
    try writer.writeAll(colorSeq(.none));
    try writer.writeAll("(lines show recent packet paths)\n");
}

fn drawNodes(canvas: *Canvas, nodes: []const NodeSnapshot, positions: []const Point) void {
    const show = @min(nodes.len, positions.len);
    for (nodes[0..show], positions[0..show]) |n, pos| {
        drawHex(canvas, pos, n);
    }
}

fn drawLinks(canvas: *Canvas, positions: []const Point, evs: []const events.PacketEvent, tick: u64) void {
    _ = tick;
    var seen = std.AutoHashMap(u32, bool).init(std.heap.page_allocator);
    defer seen.deinit();

    for (evs) |e| {
        const src_idx = e.src;
        const dst_idx = e.dest;
        if (src_idx >= positions.len or dst_idx >= positions.len) continue;
        const key = (@as(u32, src_idx) << 16) | @as(u32, dst_idx);
        if (seen.contains(key)) continue;
        seen.put(key, true) catch continue;
        const src = positions[src_idx];
        const dst = positions[dst_idx];
        drawLine(canvas, src, dst, '.', .dim);
    }
}

fn drawPackets(canvas: *Canvas, positions: []const Point, evs: []const events.PacketEvent, tick: u64) void {
    const speed_cells: usize = 2; // cells per tick
    for (evs) |e| {
        if (e.src >= positions.len or e.dest >= positions.len) continue;
        var path: [128]Point = undefined;
        const len = linePath(positions[e.src], positions[e.dest], &path);
        if (len == 0) continue;
        const age = tick - e.tick;
        const step: usize = @intCast(age * speed_cells);
        const idx = @min(len - 1, step);
        const p = path[idx];
        const color = colorForPacket(e.msg_type, e.kind);
        const glyph: u8 = switch (e.msg_type) {
            1 => 'D', // Deploy
            2 => 'S', // Sync
            3 => 'R', // Request
            4 => 'C', // Control
            else => '*',
        };
        canvas.set(p.x, p.y, glyph, color);
    }
}

fn drawHex(canvas: *Canvas, center: Point, n: NodeSnapshot) void {
    const lines = [_][]const u8{
        "  _____  ",
        " /     \\ ",
        "|       |",
        "|       |",
        " \\_____/",
    };
    const top_left_x: isize = @as(isize, @intCast(center.x)) - 4;
    const top_left_y: isize = @as(isize, @intCast(center.y)) - 2;
    const base_color: Color = if (n.is_down) .dim else .white;

    for (lines, 0..) |line, dy| {
        for (line, 0..) |ch, dx| {
            const x = top_left_x + @as(isize, @intCast(dx));
            const y = top_left_y + @as(isize, @intCast(dy));
            if (x >= 0 and y >= 0) {
                canvas.set(@intCast(x), @intCast(y), ch, base_color);
            }
        }
    }

    // Center text lines.
    var buf: [9]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "N{d}", .{n.id}) catch "N?";
    blitText(canvas, center.x, center.y, label, base_color);

    var svc_buf: [9]u8 = undefined;
    const svc_txt = std.fmt.bufPrint(&svc_buf, "svc:{d}", .{n.services}) catch "svc:?";
    blitText(canvas, center.x, center.y + 1, svc_txt, base_color);
}

fn blitText(canvas: *Canvas, cx: usize, cy: usize, text: []const u8, color: Color) void {
    const len = text.len;
    const start_x = if (len >= 1 and len <= cx) cx - (len / 2) else cx;
    for (text, 0..) |ch, i| {
        const x = start_x + i;
        canvas.set(x, cy, ch, color);
    }
}

fn drawLine(canvas: *Canvas, a: Point, b: Point, ch: u8, color: Color) void {
    var path: [128]Point = undefined;
    const len = linePath(a, b, &path);
    for (path[0..len]) |p| canvas.set(p.x, p.y, ch, color);
}

fn linePath(a: Point, b: Point, out: []Point) usize {
    var x0: isize = @intCast(a.x);
    var y0: isize = @intCast(a.y);
    const x1: isize = @intCast(b.x);
    const y1: isize = @intCast(b.y);
    const dx = if (x1 >= x0) x1 - x0 else x0 - x1;
    const dy = if (y1 >= y0) y1 - y0 else y0 - y1;
    const sx: isize = if (x0 < x1) 1 else -1;
    const sy: isize = if (y0 < y1) 1 else -1;
    var err: isize = dx - dy;

    var idx: usize = 0;
    while (true) {
        if (idx < out.len) {
            out[idx] = .{ .x = @intCast(x0), .y = @intCast(y0) };
            idx += 1;
        }
        if (x0 == x1 and y0 == y1) break;
        const e2 = err * 2;
        if (e2 > -dy) {
            err -= dy;
            x0 += sx;
        }
        if (e2 < dx) {
            err += dx;
            y0 += sy;
        }
        if (idx >= out.len) break;
    }
    return idx;
}

fn flushCanvas(writer: anytype, canvas: *const Canvas) !void {
    var last_color: Color = .none;
    for (0..canvas.height) |y| {
        for (0..canvas.width) |x| {
            const cell = canvas.cells[canvas.idx(x, y)];
            if (cell.color != last_color) {
                try writer.writeAll(colorSeq(cell.color));
                last_color = cell.color;
            }
            try writer.writeByte(cell.ch);
        }
        try writer.writeAll(colorSeq(.none));
        last_color = .none;
        try writer.writeByte('\n');
    }
}

fn colorSeq(c: Color) []const u8 {
    return switch (c) {
        .none => "\x1b[0m",
        .dim => "\x1b[2m",
        .white => "\x1b[37m",
        .green => "\x1b[32m",
        .cyan => "\x1b[36m",
        .yellow => "\x1b[33m",
        .magenta => "\x1b[35m",
        .red => "\x1b[31m",
    };
}

fn colorForPacket(msg_type: u8, kind: events.EventKind) Color {
    _ = kind;
    return switch (msg_type) {
        1 => .green,
        2 => .cyan,
        3 => .yellow,
        4 => .magenta,
        else => .white,
    };
}

fn computePositions(out: *[12]Point, nodes: []const NodeSnapshot) usize {
    const show = @min(nodes.len, out.len);
    const cols: usize = 4;
    const x_spacing: usize = 22;
    const y_spacing: usize = 8;
    const x_offset: usize = 8;
    const y_offset: usize = 2;
    var idx: usize = 0;
    while (idx < show) : (idx += 1) {
        const row = idx / cols;
        const col = idx % cols;
        out[idx] = .{
            .x = x_offset + col * x_spacing,
            .y = y_offset + row * y_spacing,
        };
    }
    return show;
}
