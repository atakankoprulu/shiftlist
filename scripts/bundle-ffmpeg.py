#!/usr/bin/env python3
"""Copies Homebrew's ffmpeg + ffprobe and every Homebrew dylib they load into an .app bundle.

Usage: bundle-ffmpeg.py <Shiftlist.app> <codesign identity or ->

Binaries go to Contents/MacOS, libraries to Contents/Frameworks, and all load paths are rewritten
to be relative so the app works on a Mac without Homebrew.
"""
import os
import shutil
import subprocess
import sys

app, identity = sys.argv[1], sys.argv[2]
macos = os.path.join(app, "Contents", "MacOS")
frameworks = os.path.join(app, "Contents", "Frameworks")
os.makedirs(frameworks, exist_ok=True)


def load_commands(path):
    lines = subprocess.run(["otool", "-L", path], capture_output=True, text=True, check=True).stdout.splitlines()[1:]
    return [line.strip().split(" (")[0] for line in lines]


def resolve(dep, loader):
    if dep.startswith("/opt/homebrew") or dep.startswith("/usr/local"):
        return os.path.realpath(dep)
    if dep.startswith("@rpath/") or dep.startswith("@loader_path/"):
        return os.path.realpath(os.path.join(os.path.dirname(loader), dep.split("/", 1)[1]))
    return None  # system library


copied = {}  # real source path -> bundled file name


def bundle(src):
    """Copies one dylib (and, recursively, its dependencies) into Frameworks."""
    if src in copied:
        return copied[src]
    name = os.path.basename(src)
    copied[src] = name
    dst = os.path.join(frameworks, name)
    shutil.copy2(src, dst)
    os.chmod(dst, 0o755)
    subprocess.run(["install_name_tool", "-id", f"@rpath/{name}", dst], check=True, stderr=subprocess.DEVNULL)
    relink(dst, src, "@loader_path")
    return name


def relink(path, original, prefix):
    for dep in load_commands(original):
        real = resolve(dep, original)
        if real and os.path.exists(real):
            name = bundle(real)
            subprocess.run(["install_name_tool", "-change", dep, f"{prefix}/{name}", path], check=True, stderr=subprocess.DEVNULL)


for tool in ["ffmpeg", "ffprobe"]:
    src = os.path.realpath(f"/opt/homebrew/bin/{tool}")
    dst = os.path.join(macos, tool)
    shutil.copy2(src, dst)
    os.chmod(dst, 0o755)
    relink(dst, src, "@executable_path/../Frameworks")

# install_name_tool invalidates signatures; sign the inner code before the app itself.
for name in sorted(os.listdir(frameworks)):
    subprocess.run(["codesign", "--force", "--sign", identity, os.path.join(frameworks, name)], check=True, capture_output=True)
for tool in ["ffmpeg", "ffprobe"]:
    subprocess.run(["codesign", "--force", "--sign", identity, os.path.join(macos, tool)], check=True, capture_output=True)

size = sum(os.path.getsize(os.path.join(frameworks, f)) for f in os.listdir(frameworks))
print(f"ffmpeg gömüldü: {len(copied)} kütüphane, {size // 1024 // 1024} MB")
