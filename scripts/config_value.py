#!/usr/bin/env python3
"""Print one value from config/platform.yaml by dotted path, e.g. state.container."""
import pathlib
import sys

import yaml

root = pathlib.Path(__file__).resolve().parent.parent
data = yaml.safe_load((root / "config" / "platform.yaml").read_text())
for part in sys.argv[1].split("."):
    data = data[part]
print(data)
