# Feature: Project Scaffold

## Status: ✅ Complete

## Original Ask

Create bare minimum project structure for greenfield rewrite of Myco, based on the proposal documents. The scaffold should:
- Use Zig as the implementation language
- Follow the best-of-both architecture (ECS storage + functional core + CRDT + WAL)
- Be minimal so the user can do hands-on coding to understand the repo

## Where Code Was Added/Changed

### Files Created

| File | Purpose |
|------|---------|
| `src/main.zig` | Entry point with basic tick loop skeleton |
| `src/util/limits.zig` | System constants (PACKET_SIZE, MAX_NODES, etc.) |
| `build.zig` | Simplified Zig build configuration |
| `build.zig.zon` | Package manifest |

### Files Modified

| File | Change |
|------|--------|
| `build.zig` | Simplified from 151 lines to ~15 lines |
| `build.zig.zon` | Unchanged (already minimal) |

## Architecture

```
myco-greenfield/
├── src/
│   ├── main.zig          # Entry point, tick loop
│   ├── ecs/              # (placeholder)
│   ├── net/              # (placeholder)
│   └── util/             # (placeholder)
├── proposal/             # Reference docs from original
├── build.zig
└── build.zig.zon
```

The build is minimal - just compiles the main.zig executable.

## Testing

- Build verification: `zig build` passes
- Basic tick loop runs (infinite loop with sleep)

## Summary

Initial project scaffold created with bare minimum to get a working Zig build. The main.zig contains a basic tick loop that prints startup messages and sleeps indefinitely. This provides a foundation to build out the actual features incrementally.
