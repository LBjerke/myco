<!-- Context: project-intelligence/technical | Priority: critical | Version: 1.0 | Updated: 2026-03-04 -->

# Technical Domain

**Purpose**: Tech stack, architecture, and development patterns for the Myco project.
**Last Updated**: 2026-03-04

## Quick Reference
**Update Triggers**: Tech stack changes | New patterns | Architecture decisions
**Audience**: Developers, AI agents

## Primary Stack
| Layer | Technology | Version | Rationale |
|-------|-----------|---------|-----------|
| Language | Zig | 0.13.0+ | Performance, safety, and zero-allocation focus |
| Framework | Custom (Myco) | N/A | Minimalist, simulation-ready architecture |
| Database | In-memory ECS | N/A | High-speed state management without external deps |
| Styling | `zig fmt` | N/A | Standard Zig formatting |

## Code Patterns
### API Endpoint (Minimal HTTP-like)
```zig
pub fn handleRequest(self: *ApiServer, raw_req: []const u8) ![]const u8 {
    noalloc_guard.check();
    if (std.mem.indexOf(u8, raw_req, "GET /metrics") != null) {
        return std.fmt.bufPrint(&self.resp_buf, "HTTP/1.0 200 OK\n\nnode_id {d}", .{self.node.id});
    }
    return error.NotFound;
}
```

### Component / Struct (ECS Pattern)
```zig
pub const World = struct {
    nodes: [limits.MAX_NODES]Node,
    node_count: usize = 0,

    pub fn init() World {
        return .{ .nodes = undefined, .node_count = 0 };
    }
};
```

## Naming Conventions
| Type | Convention | Example |
|------|-----------|---------|
| Files | snake_case | `api_server.zig` |
| Structs | PascalCase | `ApiServer` |
| Functions | camelCase | `handleRequest` |
| Variables | snake_case | `raw_req` |

## Code Standards
- **Zero Allocations**: Prefer stack allocation or fixed-size arrays; use `noalloc_guard`.
- **Error Handling**: Use `try` for explicit error propagation.
- **Co-located Tests**: Include unit tests in the same file as the implementation.
- **Formatting**: Strictly follow `zig fmt` style.

## Security Requirements
- **Memory Safety**: Verify struct sizes before casting memory (e.g., `@sizeOf(Service)`).
- **Buffer Limits**: Always respect `limits.MAX_API_RESPONSE` and other defined bounds.
- **Integrity**: Validate packet MACs and use `noalloc_guard` to prevent runtime allocation exhaustion.
- **Injection Prevention**: Avoid command injection by using fixed-size buffers and avoiding dynamic string execution.

## 📂 Codebase References
**Implementation**: `src/` - Core Zig implementation
**Config**: `build.zig` - Zig build system configuration

## Related Files
- Business Domain (business-domain.md)
- Navigation (navigation.md)
