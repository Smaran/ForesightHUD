"""Build the ForesightHUD release zips from this repo.

    python build.py --author "Name" [--sync] [--stamp-installed]

--sync first copies the mod files from the installed mod (%AppData%/Balatro/Mods/ForesightHUD)
into ForesightHUD/ here (the copy in this repo is what gets packaged and published).

dist/ForesightHUD-thunderstore-<ver>.zip  flat: manifest.json, icon.png, README.md, CHANGELOG.md,
                                          LICENSE + the mod files at the root (Thunderstore layout)
dist/ForesightHUD-<ver>.zip               ForesightHUD/<mod files + README + LICENSE> for
                                          manual install / GitHub / Nexus

The mod's own ForesightHUD.json (version, author) is stamped into the package copies only;
run with --stamp-installed to also update the installed manifest.
"""
import argparse
import json
import re
import sys
import zipfile
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
INSTALLED = Path.home() / "AppData/Roaming/Balatro/Mods/ForesightHUD"
MOD = HERE / "ForesightHUD"
MOD_FILES = ["ForesightHUD.lua", "config.lua", "ForesightHUD.json"]
DOCS = ["README.md", "CHANGELOG.md", "LICENSE"]


def fail(msg):
    sys.exit("BUILD FAILED: " + msg)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--author", required=True)
    ap.add_argument("--stamp-installed", action="store_true")
    ap.add_argument("--sync", action="store_true")
    ap.add_argument("--shots", action="store_true",
                    help="rewrite the README screenshot block from screenshots/*.png|jpg (sorted by name)")
    a = ap.parse_args()
    if a.shots:
        files = sorted(f for f in (HERE / "screenshots").glob("*") if f.suffix.lower() in (".png", ".jpg", ".jpeg"))
        lines = [f"![{re.sub(r'^[0-9]+[-_ ]*', '', f.stem).replace('-', ' ').replace('_', ' ')}]"
                 f"(https://raw.githubusercontent.com/Smaran/ForesightHUD/main/screenshots/{f.name})" for f in files]
        rd = (HERE / "README.md").read_text(encoding="utf-8")
        block = "<!--SHOTS-->\n" + "\n\n".join(lines) + "\n<!--/SHOTS-->"
        rd = re.sub(r"<!--SHOTS-->.*?<!--/SHOTS-->", lambda m: block, rd, flags=re.S)
        (HERE / "README.md").write_text(rd, encoding="utf-8")
        print(f"README: {len(lines)} screenshot(s)")
    if a.sync:
        MOD.mkdir(exist_ok=True)
        for f in MOD_FILES: (MOD / f).write_bytes((INSTALLED / f).read_bytes())

    ts = json.loads((HERE / "manifest.json").read_text(encoding="utf-8"))
    ver = ts["version_number"]
    if not re.fullmatch(r"\d+\.\d+\.\d+", ver): fail("version_number must be Major.Minor.Patch")
    if not re.fullmatch(r"[A-Za-z0-9_]+", ts["name"]): fail("name: only A-Z a-z 0-9 _")
    if len(ts["description"]) > 250: fail("description > 250 chars")
    with Image.open(HERE / "icon.png") as im:
        if im.size != (256, 256) or im.format != "PNG": fail("icon.png must be a 256x256 PNG")
    readme = re.sub(r"<!--.*?-->", "", (HERE / "README.md").read_text(encoding="utf-8"), flags=re.S)
    if re.search(r"!\[[^\]]*\]\((?!https://)", readme): fail("README image with a relative URL (Thunderstore needs https://)")
    for shot in re.findall(r"raw\.githubusercontent\.com/[^/]+/[^/]+/[^/]+/(screenshots/[^)\s]+)", readme):
        if not (HERE / shot).is_file(): fail(f"README links {shot}, which is missing (add it and push before uploading)")

    lua = (MOD / "ForesightHUD.lua").read_text(encoding="utf-8")
    if re.search(r"\\u\{", lua): fail("\\u{} escape in ForesightHUD.lua (LuaJIT can't parse it)")
    smods = json.loads((MOD / "ForesightHUD.json").read_text(encoding="utf-8"))
    smods["version"] = ver
    smods["author"] = [a.author]
    smods_text = json.dumps(smods, indent=2, ensure_ascii=False) + "\n"
    lic = (HERE / "LICENSE").read_text(encoding="utf-8").replace("{{AUTHOR}}", a.author)
    if "{{" in lic: fail("unfilled placeholder in LICENSE")

    def payload():
        for f in MOD_FILES:
            yield f, smods_text.encode() if f == "ForesightHUD.json" else (MOD / f).read_bytes()
        for f in DOCS:
            yield f, lic.encode() if f == "LICENSE" else (HERE / f).read_bytes()

    dist = HERE / "dist"
    dist.mkdir(exist_ok=True)
    tsz = dist / f"ForesightHUD-thunderstore-{ver}.zip"
    with zipfile.ZipFile(tsz, "w", zipfile.ZIP_DEFLATED) as z:
        z.write(HERE / "manifest.json", "manifest.json")
        z.write(HERE / "icon.png", "icon.png")
        for name, data in payload(): z.writestr(name, data)
    man = dist / f"ForesightHUD-{ver}.zip"
    with zipfile.ZipFile(man, "w", zipfile.ZIP_DEFLATED) as z:
        for name, data in payload(): z.writestr("ForesightHUD/" + name, data)

    if a.stamp_installed:
        (INSTALLED / "ForesightHUD.json").write_text(smods_text, encoding="utf-8")
    for p in (tsz, man):
        with zipfile.ZipFile(p) as z: print(p.name, sorted(z.namelist()))


if __name__ == "__main__":
    main()
