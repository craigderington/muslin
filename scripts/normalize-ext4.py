#!/usr/bin/env python3
"""Normalize imported ext4 inode ownership and all four timestamps, rootlessly."""
import pathlib
import subprocess
import sys

stage, image, epoch = sys.argv[1:]
root = pathlib.Path(stage)
paths = ["/", "/lost+found"] + ["/" + p.relative_to(root).as_posix() for p in sorted(root.rglob("*"))]
commands = []
for path in paths:
    if "\n" in path or "\r" in path:
        raise SystemExit("rootfs paths must not contain newlines")
    quoted = '"' + path.replace("\\", "\\\\").replace('"', '\\"') + '"'
    for field, value in [("uid", "0"), ("gid", "0")]:
        commands.append(f"set_inode_field {quoted} {field} {value}")
    for field in ("atime", "mtime", "ctime", "crtime"):
        commands.append(f"set_inode_field {quoted} {field} @{epoch}")
        commands.append(f"set_inode_field {quoted} {field}_extra 0")
result = subprocess.run(["debugfs", "-w", "-f", "/dev/stdin", image],
                        input="\n".join(commands) + "\n", text=True, capture_output=True, check=True)
errors = [line for line in result.stderr.splitlines() if not line.startswith("debugfs ")]
if errors:
    raise SystemExit("\n".join(errors))
