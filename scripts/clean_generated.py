#!/usr/bin/env python3
"""List or remove repository-local generated outputs. Never delete tracked files."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUTPUTS = (
    "dist", "clipy_android/build", "clipy_android/.dart_tool",
    "clipy_android/android/.gradle", "clipy_android_native/app/build",
    "clipy_android_native/.gradle", "clipy_android_native/upgradeProbe/build",
    "vendor/common-relay/swift/.build", "clipy_macos/ClipyClone.app",
    "clipy_macos/ClipyClone.app.dSYM",
    "docs/design/menubar-redesign/prototype/node_modules",
    "docs/design/menubar-redesign/prototype/dist",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Remove the listed outputs; otherwise only preview")
    parser.add_argument("--include-nsh", action="store_true", help="Also remove NSH generated outputs after preserving needed experiment evidence")
    args = parser.parse_args()
    git_root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], cwd=ROOT, text=True).strip()).resolve()
    if git_root != ROOT:
        parser.error("Run this script from its original repository")
    paths = {ROOT / p for p in OUTPUTS}
    if args.include_nsh and (ROOT / "clipy_nsh").is_dir():
        for parent, dirs, _ in os.walk(ROOT / "clipy_nsh", followlinks=False):
            for name in list(dirs):
                if name in {".nsh", "target", "dist", "__pycache__"}:
                    paths.add(Path(parent) / name)
                    dirs.remove(name)
        paths.update(ROOT / p for p in (
            "clipy_nsh/host/macos/token/bundle",
            "clipy_nsh/host/macos/token/tests/selection-regression",
        ))
    tracked = [p for p in subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0") if p]
    candidates = []
    for path in sorted(paths):
        if not path.exists() and not path.is_symlink():
            continue
        relative = path.relative_to(ROOT).as_posix()
        if path.is_symlink() or not path.resolve().is_relative_to(ROOT):
            parser.error(f"Refusing linked/outside path: {relative}")
        if any(p == relative or p.startswith(relative + "/") for p in tracked):
            parser.error(f"Refusing output containing tracked files: {relative}")
        ignored = subprocess.run(["git", "check-ignore", "-q", "--", relative], cwd=ROOT).returncode == 0
        if not ignored:
            parser.error(f"Refusing unrecognized, nonignored output: {relative}")
        size = int(subprocess.check_output(["du", "-sk", str(path)], text=True).split()[0])
        candidates.append((path, relative, size))
    print("APPLY" if args.apply else "PREVIEW", flush=True)
    for path, relative, size in candidates:
        print(f"{size / 1024**2:8.3f} GiB  {relative}", flush=True)
        if args.apply:
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
    print(f"{'Removed' if args.apply else 'Listed'} {len(candidates)} outputs; directory accounting {sum(s for _, _, s in candidates) / 1024**2:.2f} GiB", flush=True)


if __name__ == "__main__":
    main()
