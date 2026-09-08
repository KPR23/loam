#!/usr/bin/env python3
"""Export BudgetArcLayout geometry as standalone SVG (matches Loam/Features/Home/BudgetArcLayout.swift)."""

from __future__ import annotations

import math
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class BudgetArcLayout:
    row_count: int = 2
    column_count: int = 18
    square_size: float = 17.5
    outer_square_size: float = 20.0
    row_gap: float = 9.0
    start_degrees: float = 198.0
    end_degrees: float = -18.0
    horizontal_inset: float = 16.0
    top_inset: float = 10.0
    center_y_ratio: float = 0.72

    @property
    def sweep_degrees(self) -> float:
        return self.start_degrees - self.end_degrees

    @property
    def tile_reach(self) -> float:
        return self.outer_square_size * math.sqrt(2) / 2

    @property
    def row_pitch(self) -> float:
        return (self.square_size + self.outer_square_size) / 2 + self.row_gap

    def square_size_for_row(self, row: int) -> float:
        return self.outer_square_size if row == self.row_count - 1 else self.square_size

    def make_tiles(self, width: float, height: float) -> list[dict]:
        if width <= 0 or height <= 0 or self.row_count <= 0 or self.column_count <= 0:
            return []

        center_x = width / 2
        center_y = height * self.center_y_ratio
        pitch = self.row_pitch
        width_limited = (width / 2) - self.horizontal_inset - self.tile_reach
        top_limited = center_y - self.top_inset - self.tile_reach
        outer_radius = max(self.tile_reach, min(width_limited, top_limited))
        inner_radius = max(self.tile_reach, outer_radius - (self.row_count - 1) * pitch)

        tiles: list[dict] = []
        tile_id = 0

        for column in range(self.column_count):
            t = 0.5 if self.column_count == 1 else column / (self.column_count - 1)
            degrees = self.start_degrees - self.sweep_degrees * t
            angle = math.radians(degrees)

            for row in range(self.row_count):
                tile_size = self.square_size_for_row(row)
                radius = inner_radius + row * pitch
                x = center_x + radius * math.cos(angle)
                y = center_y - radius * math.sin(angle)
                rotation = 90 - degrees

                tiles.append(
                    {
                        "id": tile_id,
                        "row": row,
                        "column": column,
                        "size": tile_size,
                        "x": x,
                        "y": y,
                        "rotation": rotation,
                        "corner_radius": max(3.0, tile_size * 0.2),
                    }
                )
                tile_id += 1

        return tiles


def bounds_for_tiles(tiles: list[dict], padding: float) -> tuple[float, float, float, float]:
    min_x = min_y = float("inf")
    max_x = max_y = float("-inf")

    for tile in tiles:
        half = tile["size"] / 2
        reach = half * math.sqrt(2)
        min_x = min(min_x, tile["x"] - reach)
        max_x = max(max_x, tile["x"] + reach)
        min_y = min(min_y, tile["y"] - reach)
        max_y = max(max_y, tile["y"] + reach)

    return (
        min_x - padding,
        min_y - padding,
        max_x - padding,
        max_y - padding,
    )


def tile_rect_svg(tile: dict, fill: str) -> str:
    half = tile["size"] / 2
    rx = tile["corner_radius"]
    return (
        f'  <rect x="{-half:.4f}" y="{-half:.4f}" width="{tile["size"]:.4f}" '
        f'height="{tile["size"]:.4f}" rx="{rx:.4f}" ry="{rx:.4f}" fill="{fill}" />\n'
    )


def export_svg(
    *,
    width: float,
    height: float,
    layout: BudgetArcLayout,
    output: Path,
    fill: str = "#000000",
    padding: float = 8.0,
    crop_to_content: bool = True,
) -> None:
    tiles = layout.make_tiles(width, height)

    if crop_to_content:
        min_x, min_y, view_w, view_h = bounds_for_tiles(tiles, padding)
        view_box = f"{min_x:.2f} {min_y:.2f} {view_w:.2f} {view_h:.2f}"
    else:
        view_box = f"0 0 {width:.2f} {height:.2f}"

    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>\n',
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{view_box}" fill="none">\n',
        '  <title>Loam budget arc</title>\n',
        '  <desc>Two-row tile arc from BudgetArcLayout (Loam Home hero).</desc>\n',
        '  <g id="budget-arc">\n',
    ]

    for tile in tiles:
        lines.append(
            f'    <g transform="translate({tile["x"]:.4f},{tile["y"]:.4f}) rotate({tile["rotation"]:.4f})">\n'
        )
        lines.append("    " + tile_rect_svg(tile, fill).strip() + "\n")
        lines.append("    </g>\n")

    lines.append("  </g>\n")
    lines.append("</svg>\n")

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("".join(lines), encoding="utf-8")
    print(f"Wrote {output} ({len(tiles)} tiles)")


def main() -> None:
    repo_root = Path(__file__).resolve().parents[1]
    layout = BudgetArcLayout()

    # Matches MonthlySpendHero canvas proportions in HomeView.
    export_svg(
        width=390,
        height=260,
        layout=layout,
        output=repo_root / "Loam/Resources/brand/budget-arc.svg",
    )

    # Minimal variant for icon work — same geometry, fewer columns.
    export_svg(
        width=390,
        height=260,
        layout=BudgetArcLayout(column_count=7),
        output=repo_root / "Loam/Resources/brand/budget-arc-minimal.svg",
    )


if __name__ == "__main__":
    main()
