#!/usr/bin/env python3
"""Downsample the official Natural Earth I 50m ZIP into the bundled relief JPEG."""

import argparse
import io
import zipfile
from pathlib import Path

from PIL import Image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    with zipfile.ZipFile(args.source) as archive:
        names = [name for name in archive.namelist() if name.endswith("NE1_50M_LC_SR_W.tif")]
        if len(names) != 1:
            raise ValueError("Expected the official Natural Earth I 50m relief TIFF")
        with Image.open(io.BytesIO(archive.read(names[0]))) as image:
            if image.size != (10800, 5400):
                raise ValueError("Expected a 10800x5400 equirectangular source")
            output = image.convert("RGB").resize((5400, 2700), Image.Resampling.LANCZOS)
            args.destination.parent.mkdir(parents=True, exist_ok=True)
            output.save(args.destination, "JPEG", quality=89, optimize=True)
    print(f"Prepared relief: {args.destination}")


if __name__ == "__main__":
    main()
