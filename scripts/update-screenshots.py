#!/usr/bin/env python3
"""Render the shipping SwiftUI views with demo data and refresh website assets."""
import argparse
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import tempfile


def dimensions(path):
    with path.open("rb") as image:
        header = image.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ValueError(f"Invalid PNG: {path}")
    width, height = struct.unpack(">II", header[16:24])
    if not (0 < width <= 10000 and 0 < height <= 10000):
        raise ValueError(f"Invalid image dimensions: {path}")
    return width, height


def image_size_markup(text, src, size):
    def replace(match):
        tag = match.group()
        if f'src="{src}"' not in tag:
            return tag
        for name, value in zip(("width", "height"), size):
            tag = re.sub(rf'\s{name}="[^"]*"', "", tag)
            tag = tag.replace("<img", f'<img {name}="{value}"', 1)
        return tag
    return re.sub(r"<img\b[^>]*>", replace, text)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--portfolio", type=Path,
                        help="Also refresh the German Juicebar page in a tbuck-www checkout")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    portfolio = args.portfolio.resolve() if args.portfolio else None
    if portfolio and not (portfolio / "content/project/juicebar.md").is_file():
        parser.error("--portfolio must contain content/project/juicebar.md")
    if os.uname().sysname != "Darwin":
        parser.error("Rendering native SwiftUI views requires macOS and Swift 6")
    env = dict(os.environ, JUICEBAR_DISTRIBUTION="source")
    subprocess.run(["swift", "build", "--product", "Juicebar"], cwd=root, env=env, check=True)
    binary_dir = subprocess.check_output(["swift", "build", "--show-bin-path"],
                                         cwd=root, env=env, text=True).strip()
    binary = Path(binary_dir) / "Juicebar"
    copies = []
    markup = {}
    # Fresh directories prevent a failed render from publishing stale files.
    with tempfile.TemporaryDirectory(prefix="juicebar-screenshots-") as temporary:
        for language in ("en", "de"):
            working = Path(temporary) / language
            working.mkdir()
            subprocess.run([str(binary), "--render-previews", f"--language={language}"],
                           cwd=working, env=env, check=True)
            previews = working / ".artifacts/previews"
            for page in ("overview", "usage"):
                source = previews / f"store-{language}-{page}.png"
                copies.append((source, root / "docs/app-store/assets" / source.name))
                if language == "en":
                    copies.append((source, root / f"site/assets/{page}.png"))
                elif portfolio:
                    copies.append((source, portfolio / f"static/res/project/juicebar/{page}.png"))
            if language == "en":
                copies.extend((previews / source, root / "site/assets" / target) for source, target in (
                    ("tray-dark-en.png", "tray.png"), ("menu-limits.png", "menu-limits.png")))
            elif portfolio:
                copies.append((previews / "menu-popover-de.png",
                               portfolio / "static/res/project/juicebar/menu-popover.png"))
        # Validate every output before replacing any tracked asset.
        sizes = [(source, target, dimensions(source)) for source, target in copies]
        for source, target, size in sizes:
            if target.parent == root / "site/assets":
                document, src = root / "site/index.html", f"assets/{target.name}"
            elif portfolio and target.parent == portfolio / "static/res/project/juicebar":
                document, src = portfolio / "content/project/juicebar.md", f"/res/project/juicebar/{target.name}"
            else:
                continue
            markup[document] = image_size_markup(markup.get(document, document.read_text()), src, size)
        for source, target, size in sizes:
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            print(f"Updated {target.relative_to(root) if target.is_relative_to(root) else target}: {size[0]} × {size[1]}")
        for document, content in markup.items():
            document.write_text(content)
    print("Screenshots refreshed. Review the changes before committing and publishing.")


if __name__ == "__main__":
    main()
