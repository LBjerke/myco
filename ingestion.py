#!/usr/bin/env python3
import os
import sys

from pathlib import Path

def is_probably_binary(path: Path, chunk_size: int = 1024) -> bool:
    """Heuristic to skip binary files."""
    try:
        with path.open("rb") as f:
            chunk = f.read(chunk_size)
        if b"\x00" in chunk:
            return True
        # If a large portion is non-text, treat as binary
        text_chars = bytes(range(32, 127)) + b"\n\r\t\b"
        non_text = sum(c not in text_chars for c in chunk)
        return non_text > 0.3 * max(1, len(chunk))
    except Exception:
        # If we can't read it safely, treat as binary
        return True

def build_file_tree(root: Path) -> str:
    """
    Build a simple ASCII tree of files and directories starting at root.
    """
    lines = []
    root = root.resolve()
    for dirpath, dirnames, filenames in os.walk(root):
        # Sort for stable output
        dirnames.sort()
        filenames.sort()

        rel_dir = Path(dirpath).relative_to(root)
        depth = len(rel_dir.parts)

        # For the root itself, we just print '.'
        if rel_dir == Path('.'):
            lines.append(".")
        else:
            indent = "    " * (depth - 1)
            lines.append(f"{indent}{rel_dir.name}/")

        indent = "    " * depth
        for filename in filenames:
            lines.append(f"{indent}{filename}")

    return "\n".join(lines)

def main():
    # Determine output file
    if len(sys.argv) > 1:
        out_name = sys.argv[1]
    else:
        out_name = "combined_output.txt"

    root = Path(".").resolve()
    output_path = (root / out_name).resolve()

    # Build file tree (includes the output filename if it already exists,
    # which is fine for the tree)
    tree_text = build_file_tree(root)

    with output_path.open("w", encoding="utf-8", errors="replace") as out:
        # Write file tree at the top
        out.write("=== FILE TREE (relative to current directory) ===\n")
        out.write(tree_text)
        out.write("\n\n=== CONCATENATED FILE CONTENTS ===\n\n")

        for dirpath, dirnames, filenames in os.walk(root):
            dirnames.sort()
            filenames.sort()

            for filename in filenames:
                file_path = Path(dirpath) / filename
                # Skip the output file itself
                if file_path.resolve() == output_path:
                    continue

                rel_path = file_path.relative_to(root)

                # Skip obvious binary files
                if is_probably_binary(file_path):
                    continue

                out.write("\n\n")
                out.write("==================================================\n")
                out.write(f"FILE: {rel_path}\n")
                out.write("==================================================\n")

                try:
                    with file_path.open("r", encoding="utf-8", errors="replace") as f:
                        for line in f:
                            out.write(line)
                except Exception as e:
                    out.write(f"\n[Could not read file: {e}]\n")

    print(f"Done. Written to {output_path}")

if __name__ == "__main__":
    main()
