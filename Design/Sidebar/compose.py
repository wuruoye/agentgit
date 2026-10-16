"""Compose the native sidebar renders without resizing the comparison panels."""
import argparse
import base64
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def ink_bounds(image, region):
    x0, y0, x1, y1 = region
    points = [(x, y) for y in range(y0, y1) for x in range(x0, x1)
              if max(image.getpixel((x, y))) < 150]
    return [min(x for x, y in points), min(y for x, y in points),
            max(x for x, y in points) + 1, max(y for x, y in points) + 1]


def selection_bounds(image):
    points = [(x, y) for y in range(650, 850) for x in range(image.width)
              if image.getpixel((x, y)) == (237, 235, 231)]
    return [min(x for x, y in points), min(y for x, y in points),
            max(x for x, y in points) + 1, max(y for x, y in points) + 1]


def comparison(left, right, labels, destination):
    assert left.size == right.size == (910, 1964)
    gutter, margin, header = 32, 24, 80
    canvas = Image.new("RGB", (2 * left.width + gutter + 2 * margin,
                               left.height + header + margin), "#F0F0EF")
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Unicode.ttf", 28)
    for x, panel, title in [(margin, left, labels[0]),
                            (margin + left.width + gutter, right, labels[1])]:
        draw.text((x, 23), title, font=font, fill="#41403D")
        canvas.paste(panel, (x, header))
    canvas.save(destination)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("reference", type=Path)
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "output")
    args = parser.parse_args()
    output = args.output
    original = Image.open(args.reference).convert("RGB")
    assert original.size == (982, 2036), "Use the selected two-line Claude sidebar reference"
    reference = original.crop((36, 36, 946, 2000))
    reference.save(output / "reference.png")
    calibration = Image.open(output / "calibration.png").convert("RGB")
    mapped = Image.open(output / "agentgit.png").convert("RGB")
    assert reference.size == calibration.size == mapped.size == (910, 1964)

    comparison(reference, calibration, ["Claude Desktop · 参考", "原生样板 · 同文校准"], output / "comparison.png")
    comparison(reference, mapped, ["Claude Desktop · 参考", "AgentGit · 内容映射"], output / "agentgit-comparison.png")
    Image.blend(reference, calibration, 0.5).save(output / "overlay.png")

    regions = {
        "navigation_new": (95, 128, 210, 180),
        "navigation_projects": (95, 190, 240, 245),
        "group_pinned": (40, 490, 160, 550),
        "selected_title": (40, 700, 550, 770),
        "ordinary_title": (40, 915, 405, 980),
        "ordinary_session": (40, 975, 270, 1035),
        "group_oct13": (40, 1410, 200, 1475),
    }
    measurements = {
        name: {"reference": ink_bounds(reference, region),
               "sample": ink_bounds(calibration, region)}
        for name, region in regions.items()
    }
    selected = {"reference": selection_bounds(reference), "sample": selection_bounds(calibration)}
    assert selected["reference"] == selected["sample"] == [19, 706, 885, 821]
    assert all(abs(m["reference"][1] - m["sample"][1]) <= 2 for m in measurements.values())
    assert reference.getpixel((5, 5)) == calibration.getpixel((5, 5)) == (250, 249, 247)
    assert reference.getpixel((30, 760)) == calibration.getpixel((30, 760)) == (237, 235, 231)
    report = {
        "panel_pixels": [910, 1964],
        "logical_points": [455, 982],
        "render_scale": 2,
        "reference_crop": [36, 36, 946, 2000],
        "font": "AnthropicSansVariable-TextLight",
        "sizes_pt": {"navigation": 16, "title": 15.7, "session_and_group": 14.5},
        "selection_bounds_px": selected,
        "text_ink_bounds_px": measurements,
        "colors": {"background": "#FAF9F7", "primary": "#41403D", "secondary": "#76746E",
                   "selected_text": "#0B0B0B", "selection": "#EDEBE7"},
        "scope": "Native static sample; fixture content; production app unchanged",
    }
    (output / "measurements.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")

    images = {name: base64.b64encode((output / (name + ".png")).read_bytes()).decode("ascii")
              for name in ["reference", "calibration", "agentgit", "row-states"]}
    template = (Path(__file__).parent / "review-template.html").read_text()
    assert template.count("{{IMAGES}}") == 1
    (output / "review.html").write_text(template.replace("{{IMAGES}}", json.dumps(images)))
    print(json.dumps({"panel_pixels": report["panel_pixels"], "selection": selected,
                      "text_top_error_max_px": max(abs(m["reference"][1] - m["sample"][1]) for m in measurements.values()),
                      "output": str(output)}, ensure_ascii=False))


if __name__ == "__main__":
    main()
