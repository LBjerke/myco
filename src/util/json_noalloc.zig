// Minimal JSON helpers that avoid heap allocation.
const std = @import("std");

pub fn skipWhitespace(input: []const u8, idx: *usize) void {
    while (idx.* < input.len and std.ascii.isWhitespace(input[idx.*])) {
        idx.* += 1;
    }
}

pub fn expectChar(input: []const u8, idx: *usize, c: u8) !void {
    skipWhitespace(input, idx);
    if (idx.* >= input.len or input[idx.*] != c) return error.UnexpectedToken;
    idx.* += 1;
}

pub fn parseString(input: []const u8, idx: *usize, dest: []u8) ![]const u8 {
    skipWhitespace(input, idx);
    if (idx.* >= input.len or input[idx.*] != '"') return error.ExpectedString;
    idx.* += 1;

    var out_idx: usize = 0;
    while (idx.* < input.len) : (idx.* += 1) {
        const ch = input[idx.*];
        if (ch == '"') {
            idx.* += 1;
            return dest[0..out_idx];
        }
        if (ch == '\\') {
            idx.* += 1;
            if (idx.* >= input.len) return error.InvalidEscape;
            const esc = input[idx.*];
            const decoded: u8 = switch (esc) {
                '"' => '"',
                '\\' => '\\',
                '/' => '/',
                'b' => 0x08,
                'f' => 0x0c,
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                'u' => return error.UnsupportedEscape,
                else => return error.InvalidEscape,
            };
            if (out_idx >= dest.len) return error.StringTooLong;
            dest[out_idx] = decoded;
            out_idx += 1;
            continue;
        }
        if (ch < 0x20) return error.InvalidString;
        if (out_idx >= dest.len) return error.StringTooLong;
        dest[out_idx] = ch;
        out_idx += 1;
    }
    return error.UnterminatedString;
}

pub fn parseU64(input: []const u8, idx: *usize) !u64 {
    skipWhitespace(input, idx);
    if (idx.* >= input.len) return error.ExpectedNumber;
    if (input[idx.*] == '-') return error.NegativeNumber;
    const start = idx.*;
    while (idx.* < input.len and std.ascii.isDigit(input[idx.*])) {
        idx.* += 1;
    }
    if (idx.* == start) return error.ExpectedNumber;
    return std.fmt.parseInt(u64, input[start..idx.*], 10);
}

pub fn parseU16(input: []const u8, idx: *usize) !u16 {
    const value = try parseU64(input, idx);
    if (value > std.math.maxInt(u16)) return error.NumberOutOfRange;
    return @intCast(value);
}

pub fn parseNull(input: []const u8, idx: *usize) !void {
    skipWhitespace(input, idx);
    if (idx.* + 4 > input.len) return error.UnexpectedToken;
    if (!std.mem.eql(u8, input[idx.* .. idx.* + 4], "null")) return error.UnexpectedToken;
    idx.* += 4;
}

fn skipString(input: []const u8, idx: *usize) !void {
    if (idx.* >= input.len or input[idx.*] != '"') return error.ExpectedString;
    idx.* += 1;
    while (idx.* < input.len) : (idx.* += 1) {
        const ch = input[idx.*];
        if (ch == '"') {
            idx.* += 1;
            return;
        }
        if (ch == '\\') {
            idx.* += 1;
            if (idx.* >= input.len) return error.InvalidEscape;
            if (input[idx.*] == 'u') {
                if (idx.* + 4 >= input.len) return error.InvalidEscape;
                idx.* += 4;
            }
        }
    }
    return error.UnterminatedString;
}

fn skipNumber(input: []const u8, idx: *usize) !void {
    if (idx.* >= input.len) return error.ExpectedNumber;
    if (input[idx.*] == '-') idx.* += 1;
    while (idx.* < input.len and std.ascii.isDigit(input[idx.*])) idx.* += 1;
    if (idx.* < input.len and input[idx.*] == '.') {
        idx.* += 1;
        while (idx.* < input.len and std.ascii.isDigit(input[idx.*])) idx.* += 1;
    }
    if (idx.* < input.len and (input[idx.*] == 'e' or input[idx.*] == 'E')) {
        idx.* += 1;
        if (idx.* < input.len and (input[idx.*] == '+' or input[idx.*] == '-')) idx.* += 1;
        while (idx.* < input.len and std.ascii.isDigit(input[idx.*])) idx.* += 1;
    }
}

pub fn skipValue(input: []const u8, idx: *usize) !void {
    skipWhitespace(input, idx);
    if (idx.* >= input.len) return error.UnexpectedToken;
    switch (input[idx.*]) {
        '"' => try skipString(input, idx),
        '{' => {
            idx.* += 1;
            skipWhitespace(input, idx);
            if (idx.* < input.len and input[idx.*] == '}') {
                idx.* += 1;
                return;
            }
            while (true) {
                try skipString(input, idx);
                try expectChar(input, idx, ':');
                try skipValue(input, idx);
                skipWhitespace(input, idx);
                if (idx.* >= input.len) return error.UnexpectedToken;
                if (input[idx.*] == '}') {
                    idx.* += 1;
                    return;
                }
                try expectChar(input, idx, ',');
            }
        },
        '[' => {
            idx.* += 1;
            skipWhitespace(input, idx);
            if (idx.* < input.len and input[idx.*] == ']') {
                idx.* += 1;
                return;
            }
            while (true) {
                try skipValue(input, idx);
                skipWhitespace(input, idx);
                if (idx.* >= input.len) return error.UnexpectedToken;
                if (input[idx.*] == ']') {
                    idx.* += 1;
                    return;
                }
                try expectChar(input, idx, ',');
            }
        },
        't' => {
            if (idx.* + 4 > input.len or !std.mem.eql(u8, input[idx.* .. idx.* + 4], "true")) return error.UnexpectedToken;
            idx.* += 4;
        },
        'f' => {
            if (idx.* + 5 > input.len or !std.mem.eql(u8, input[idx.* .. idx.* + 5], "false")) return error.UnexpectedToken;
            idx.* += 5;
        },
        'n' => try parseNull(input, idx),
        '-', '0'...'9' => try skipNumber(input, idx),
        else => return error.UnexpectedToken,
    }
}
