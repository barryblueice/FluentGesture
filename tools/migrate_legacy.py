"""Convert the original single-stroke MessagePack library to schema v1 JSON.

Usage: python tools/migrate_legacy.py gestures_db.msgpack --output migrated.json
Requires msgpack only for this one-time conversion (pip install msgpack).
Existing output files are never overwritten.
"""
import argparse
import json
import math
from pathlib import Path


def convert(library):
    if not isinstance(library, dict) or len(library) > 200:
        raise ValueError("Expected a dictionary with at most 200 templates")
    templates = []
    names = set()
    for name, points in library.items():
        if not isinstance(name, str) or not 1 <= len(name.strip()) <= 60:
            raise ValueError("Invalid template name")
        name = name.strip()
        if name in names:
            raise ValueError(f"Duplicate name: {name}")
        names.add(name)
        if not isinstance(points, (list, tuple)) or not 2 <= len(points) <= 4096:
            raise ValueError(f"Invalid point count: {name}")
        stroke = []
        for point in points:
            if not isinstance(point, (list, tuple)) or len(point) != 2:
                raise ValueError(f"Invalid point: {name}")
            if any(type(v) not in (int, float) or not math.isfinite(v)
                   or abs(v) > 1e8 for v in point):
                raise ValueError(f"Invalid coordinates: {name}")
            # The Qt demo normalized each stroke into a 100 x 100 square.
            stroke.append([point[0] / 100, point[1] / 100])
        if sum(math.dist(a, b) for a, b in zip(stroke, stroke[1:])) <= 0.015:
            raise ValueError(f"Stroke too short: {name}")
        templates.append({"name": name, "strokes": [stroke]})
    return {"version": 1, "templates": templates}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        import msgpack
        if args.source.stat().st_size > 32 * 1024 * 1024:
            raise ValueError("Input exceeds 32 MiB")
        library = msgpack.unpackb(args.source.read_bytes(), raw=False)
        contents = json.dumps(convert(library), ensure_ascii=False, indent=2)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("x", encoding="utf-8") as output:
            output.write(contents + "\n")
        print(f"Converted {len(library)} templates to {args.output}")
    except (OSError, ValueError, ImportError) as error:
        parser.exit(1, f"Migration failed: {error}\n")


if __name__ == "__main__":
    main()
