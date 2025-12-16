import os

# Files extensions to include
EXTENSIONS = ['.zig', '.nix', '.json', '.md', '.txt']
# Directories to completely ignore
SKIP_DIRS = {'.git', 'zig-cache', 'zig-out', 'myco-test', '.zig-cache'}

def is_text_file(filename):
    return any(filename.endswith(ext) for ext in EXTENSIONS)

def dump_file(filepath, out_handle):
    print(f"Processing: {filepath}")
    out_handle.write(f"\n{'='*80}\n")
    out_handle.write(f"FILE: {filepath}\n")
    out_handle.write(f"{'='*80}\n\n")
    
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            out_handle.write(f.read())
    except Exception as e:
        out_handle.write(f"[Error reading file: {e}]")
    
    out_handle.write("\n")

def main():
    output_filename = "myco_source_dump.txt"
    
    with open(output_filename, 'w', encoding='utf-8') as out:
        out.write(f"# MYCO PROJECT DUMP\n\n")
        
        # 1. Dump build.zig first (it's important)
        if os.path.exists("build.zig"):
            dump_file("build.zig", out)

        # 2. Walk the directory
        for root, dirs, files in os.walk("."):
            # Modify dirs in-place to skip unwanted folders
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            
            # Sort files for consistent output
            files.sort()
            
            for file in files:
                if file == "build.zig": continue # Already done
                if file == "dump_project.py": continue # Don't dump self
                if file == output_filename: continue # Don't dump the output
                
                if is_text_file(file):
                    filepath = os.path.join(root, file)
                    # Clean up path (./src/main.zig -> src/main.zig)
                    if filepath.startswith("./"):
                        filepath = filepath[2:]
                        
                    dump_file(filepath, out)

    print(f"\nDone! All source code saved to: {output_filename}")

if __name__ == "__main__":
    main()
