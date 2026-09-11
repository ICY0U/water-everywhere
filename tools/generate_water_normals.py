"""Generate a seamless, tiling water detail normal map.

Poly Haven and ambientCG are photogrammetry libraries: neither carries a true water
surface normal map (their water-tagged assets are ice, wet ground and puddle overlays).
So the ocean's fine surface detail is generated here instead of downloaded.

The height field is a sum of octaves of periodic value noise. Periodicity is what makes
it tile: the lattice wraps at each octave's period, so opposite edges match exactly and
the texture can repeat across the ocean without visible seams.

Output is a standard OpenGL tangent-space normal map (+Y up), which is what Godot's
`hint_normal` expects.

Usage:  python generate_water_normals.py [size] [output_path]
"""

from __future__ import annotations

import struct
import sys
import zlib
from math import cos, pi, sqrt

SIZE = 512
OUTPUT = "assets/textures/water_normal.png"
# (period in cells, weight) per octave. Periods must divide SIZE for seamless tiling.
OCTAVES = [(4, 1.0), (8, 0.55), (16, 0.28), (32, 0.16), (64, 0.09)]
# Overall bumpiness. Higher = steeper ripples = stronger normals.
HEIGHT_SCALE = 5.0


def _hash(x: int, y: int, period: int, seed: int) -> float:
    """Deterministic pseudo-random gradient in [0, 1), wrapping at `period`."""
    x %= period
    y %= period
    h = (x * 374761393 + y * 668265263 + seed * 2147483647) & 0xFFFFFFFF
    h = (h ^ (h >> 13)) * 1274126177 & 0xFFFFFFFF
    h = h ^ (h >> 16)
    return (h & 0xFFFFFF) / float(0xFFFFFF)


def _smootherstep(t: float) -> float:
    """Ken Perlin's quintic curve: zero 1st and 2nd derivatives at the ends.

    Using this rather than the cubic smoothstep keeps the *normals* continuous across
    lattice cells - a cubic would leave visible creases once we differentiate.
    """
    return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


def value_noise(u: float, v: float, period: int, seed: int) -> float:
    """Periodic value noise sampled at normalised (u, v), tiling every `period` cells."""
    x = u * period
    y = v * period
    x0, y0 = int(x) % period, int(y) % period
    x1, y1 = (x0 + 1) % period, (y0 + 1) % period
    fx, fy = _smootherstep(x - int(x)), _smootherstep(y - int(y))

    a = _hash(x0, y0, period, seed)
    b = _hash(x1, y0, period, seed)
    c = _hash(x0, y1, period, seed)
    d = _hash(x1, y1, period, seed)
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def build_height_field(size: int) -> list[list[float]]:
    """Sum the octaves into a normalised [0, 1] height field."""
    field = [[0.0] * size for _ in range(size)]
    total_weight = sum(w for _, w in OCTAVES)

    for period, weight in OCTAVES:
        for j in range(size):
            v = j / size
            for i in range(size):
                u = i / size
                field[j][i] += value_noise(u, v, period, period * 7 + 11) * weight

    lo = min(min(row) for row in field)
    hi = max(max(row) for row in field)
    span = max(hi - lo, 1e-6)
    for j in range(size):
        for i in range(size):
            field[j][i] = (field[j][i] - lo) / span

    # Bias toward rounded ripples rather than sharp noise: water surfaces are smooth.
    for j in range(size):
        for i in range(size):
            h = field[j][i]
            field[j][i] = 0.5 - 0.5 * cos(h * pi)
    return field


def height_to_normals(field: list[list[float]], size: int) -> bytearray:
    """Central-difference the height field into an RGB tangent-space normal map."""
    out = bytearray()
    for j in range(size):
        for i in range(size):
            # Wrap the neighbour lookups so the derivatives tile too.
            left = field[j][(i - 1) % size]
            right = field[j][(i + 1) % size]
            up = field[(j - 1) % size][i]
            down = field[(j + 1) % size][i]

            dx = (right - left) * HEIGHT_SCALE
            dy = (down - up) * HEIGHT_SCALE
            # Normal of the surface z = h(x, y) is (-dh/dx, -dh/dy, 1), normalised.
            nx, ny, nz = -dx, -dy, 1.0
            length = sqrt(nx * nx + ny * ny + nz * nz)
            nx, ny, nz = nx / length, ny / length, nz / length

            out.append(int((nx * 0.5 + 0.5) * 255))
            out.append(int((ny * 0.5 + 0.5) * 255))
            out.append(int((nz * 0.5 + 0.5) * 255))
    return out


def write_png(path: str, rgb: bytearray, size: int) -> None:
    """Write a minimal 8-bit RGB PNG - avoids a Pillow dependency."""
    raw = bytearray()
    stride = size * 3
    for j in range(size):
        raw.append(0)  # filter type 0 (None) for each scanline
        raw.extend(rgb[j * stride:(j + 1) * stride])

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    header = struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", header)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
        + chunk(b"IEND", b"")
    )
    with open(path, "wb") as fh:
        fh.write(png)


def main() -> None:
    size = int(sys.argv[1]) if len(sys.argv) > 1 else SIZE
    output = sys.argv[2] if len(sys.argv) > 2 else OUTPUT

    for period, _ in OCTAVES:
        if size % period:
            raise SystemExit(
                f"size {size} must be divisible by every octave period; {period} is not."
            )

    print(f"Generating {size}x{size} seamless water normal map...")
    field = build_height_field(size)
    rgb = height_to_normals(field, size)
    write_png(output, rgb, size)
    print(f"Wrote {output}")


if __name__ == "__main__":
    main()
