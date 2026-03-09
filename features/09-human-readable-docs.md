# Feature: Human-Readable Documentation

**Status**: ✅ Complete

## Original Ask

Improve documentation to make the project easier for humans to understand. The codebase was well-documented architecturally, but lacked beginner-friendly resources.

## Why This Matters

Technical projects often suffer from the "curse of knowledge" - developers understand their creation so well they forget what it's like to be new. The original Myco documentation:

- Jumped straight into technical details without explaining concepts
- Used jargon (CRDT, ECS, HLC, WAL) without defining terms
- Had no visual overview of how components fit together
- Provided no help when things went wrong

This created friction for:
- New contributors trying to understand the project
- Users deciding if Myco is right for their use case
- Operators debugging issues

## Where Code Was Added/Changed

| File | Action | Description |
|------|--------|-------------|
| `GLOSSARY.md` | Created | Definitions of technical terms with plain-language explanations |
| `TROUBLESHOOTING.md` | Created | Common issues and solutions for build/runtime problems |
| `README.md` | Modified | Added architecture diagram and links to new docs |

## Architecture

```
Documentation Structure:
+----------------------+     +-------------------+
|      README.md       |---->|   GLOSSARY.md     |
|  (entry point)      |     | (term definitions)|
+----------+-----------+     +-------------------+
           |
           | +-------------------+
           |->|  TROUBLESHOOTING |
           |  |       .md       |
           |  | (common issues)  |
           +-------------------+

Key Improvements:
1. Visual architecture diagram (block diagram showing data flow)
2. Glossary with analogies (e.g., "CRDTs are like Google Docs")
3. Troubleshooting guide with copy-paste commands
4. Links from README to both new docs
```

### Documentation Files

1. **GLOSSARY.md**
   - 30+ terms defined
   - Categorized: Core Concepts, Data Structures, Myco-Specific, Technical
   - Each term includes:
     - Plain-language explanation
     - Analogy where helpful
     - How Myco uses the concept

2. **TROUBLESHOOTING.md**
   - Organized by problem area (Build, Runtime, Networking, Data)
   - Each issue includes:
     - Problem description
     - Solution with copy-paste commands
   - Common error message lookup table

3. **README.md Changes**
   - Added "How It Works" section with ASCII diagram
   - Data flow explanation (1-4 steps)
   - Links to GLOSSARY and TROUBLESHOOTING
   - Updated Project Layout section

## Design Decisions

### Why Plain Language?

Technical documentation should be accessible to the target audience. For Myco, that includes:
- Hobbyists with Raspberry Pis
- Homelab enthusiasts
- Developers learning distributed systems

Analogies help bridge the gap between abstract concepts and intuition.

### Why ASCII Diagrams?

- No external image dependencies
- Renders in any markdown viewer
- Easy to update in version control
- Clear enough for architecture overview

### Why Copy-Paste Commands?

Most troubleshooting involves running specific commands. Providing exact commands:
- Reduces user error
- Speeds up resolution
- Makes the docs more actionable

## Testing

- All markdown files render correctly in GitHub/GitLab web UI
- All links are relative and work from any directory
- Commands are valid bash syntax
- ASCII diagrams are properly formatted (box-drawing characters)

## Summary

This feature adds human-centered documentation resources:

1. **GLOSSARY.md** — So users can look up unfamiliar terms
2. **TROUBLESHOOTING.md** — So users can solve problems without asking for help
3. **README.md improvements** — So users can visualize how the system works

These changes reduce the learning curve for new users and contributors while maintaining the existing architectural documentation for those who need it.

## See Also

- [README.md](../README.md) — Main documentation with new architecture diagram
- [GLOSSARY.md](../GLOSSARY.md) — Technical term definitions
- [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) — Common issues and solutions
- [proposal/01-overview.md](../proposal/01-overview.md) — Detailed architecture (for contributors)
