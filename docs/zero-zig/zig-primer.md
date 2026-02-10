# Zig Primer for Reading This Repo

This is a minimal Zig cheat sheet focused on reading code, not writing it.

## Imports and modules

- `const std = @import("std");` brings in the Zig standard library.
- `@import("path/to/file.zig")` loads another file as a module.

## Types and values

- `const` is an immutable binding.
- `var` is a mutable binding.
- `struct` is a record type.
- `enum` is a tagged set of values.
- `pub` makes a symbol visible outside the file.

Example:

```zig
pub const Node = struct {
    id: u16,
    fn init(id: u16) Node { return .{ .id = id }; }
};
```

## Error handling

- `!T` means a function returns either `T` or an error.
- `try expr` propagates the error if one occurred.
- `catch` handles the error locally.

Example:

```zig
fn readFile(path: []const u8) ![]u8 {
    const data = try std.fs.cwd().readFileAlloc(alloc, path, 1_000_000);
    return data;
}
```

## Optionals

- `?T` means a value may be null.
- `if (opt) |v| { ... } else { ... }` unwraps.

Example:

```zig
if (maybe_id) |id| {
    use(id);
} else {
    useDefault();
}
```

## Slices, arrays, pointers

- `[N]T` is a fixed array of N items.
- `[]T` is a slice (pointer + length).
- `*T` is a pointer to a single item.

Common patterns in this repo:
- Fixed-size buffers for low allocation.
- Slices passed to functions to avoid copies.

## Control flow and helpers

- `defer` runs a statement when the scope exits.
- `errdefer` runs only on error return.
- `@sizeOf(T)` gets type size.
- `@memcpy`, `@memset`, `std.mem.copyForwards` are used for buffer work.

## Tests

Zig uses inline tests:

```zig
test "example" {
    try std.testing.expectEqual(@as(u64, 3), 1 + 2);
}
```

## Reading tips

- Search for `pub fn init` or `pub fn tick` to find entry points.
- Look for `@import` at the top of files to see dependencies.
- If a file uses `extern struct`, it often maps to a binary layout on the wire.
