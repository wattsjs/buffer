#!/usr/bin/env python3
"""Copies the named PNG attachments from an exported xcresult manifest to
<dir>/named/<name>.png so UI walk-through screenshots are easy to find."""
import json, pathlib, shutil, sys

root = pathlib.Path(sys.argv[1])
out = root / "named"
out.mkdir(exist_ok=True)
for test in json.loads((root / "manifest.json").read_text()):
    for item in test.get("attachments", []):
        name, file = item.get("suggestedHumanReadableName", ""), item.get("exportedFileName", "")
        if file.endswith(".png") and name[:2].isdigit():
            shutil.copy(root / file, out / (name.split("_0_")[0].removesuffix(".png") + ".png"))
            print(out / (name.split("_0_")[0].removesuffix(".png") + ".png"))
