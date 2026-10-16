"""Build comparisons at original pixel sizes; never resize either comparison panel."""
import argparse
import base64
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def comparison(left, right, destination, labels=("当前实际界面 · 110%", "原生样板 · 110%")):
    assert left.size == right.size
    margin, gutter, header = 24, 32, 72
    canvas = Image.new("RGB", (left.width * 2 + margin * 2 + gutter, left.height + header + margin), "#F1F1EF")
    draw = ImageDraw.Draw(canvas)
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Unicode.ttf", 26)
    for x, panel, label in [(margin, left, labels[0]), (margin + left.width + gutter, right, labels[1])]:
        draw.text((x, 22), label, fill="#41403D", font=font)
        canvas.paste(panel, (x, header))
    canvas.save(destination)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("reference", type=Path)
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "output")
    args = parser.parse_args()
    output = args.output
    full = Image.open(args.reference).convert("RGB")
    assert full.size == (5120, 2820), "Use the original Retina screenshot"
    crop = (828, 104, 5120, 2756)
    current = full.crop(crop)
    proposal = Image.open(output / "proposal.png").convert("RGB")
    assert current.size == proposal.size == (4292, 2652)
    metadata = json.loads((output / "render-metadata.json").read_text())
    fixture = json.loads((output / "fixture.json").read_text())
    assert metadata["zoom"] == 1.1 and metadata["retina"] == 2
    assert (metadata["files"], metadata["hunks"], metadata["added"], metadata["deleted"]) == (3, 4, 4, 9)
    diff_rows = sum(len(h["lines"]) for f in fixture["files"] for h in f["hunks"])
    assert diff_rows == 37
    current.save(output / "current.png")
    comparison(current, proposal, output / "comparison.png")
    comparison(current.crop((0, 0, 1740, 1120)), proposal.crop((0, 0, 1740, 1120)), output / "detail-comparison.png")
    comparison(current.crop((0, 0, 792, 1120)), proposal.crop((0, 0, 792, 1120)), output / "commits-comparison.png")
    comparison(current.crop((3292, 0, 4292, 132)), proposal.crop((3292, 0, 4292, 132)), output / "controls-comparison.png")
    comparison(current.crop((792, 0, 4292, 132)), proposal.crop((792, 0, 4292, 132)), output / "toolbar-comparison.png")
    context = full.copy()
    context.paste(proposal, crop[:2])
    context.save(output / "proposal-in-window.png")
    report = metadata | {
        "reference_crop_px": crop, "source_screenshot_px": full.size,
        "comparison_panel_px": proposal.size, "comparison_resized": False,
        "commit": fixture["commits"][0]["id"],
        "diff_rows": diff_rows,
        "scope": "Standalone SwiftUI design sample; static interaction states; production app unchanged"
    }
    (output / "measurements.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    images = {name: base64.b64encode((output / (name + ".png")).read_bytes()).decode()
              for name in ["current", "proposal", "states", "proposal-narrow"]}
    template = (Path(__file__).parent / "review-template.html").read_text()
    assert template.count("{{IMAGES}}") == 1
    (output / "review.html").write_text(template.replace("{{IMAGES}}", json.dumps(images)))
    print(json.dumps({"panel_px": proposal.size, "zoom": metadata["zoom"], "files": metadata["files"],
                      "hunks": metadata["hunks"], "added": metadata["added"], "deleted": metadata["deleted"]}))


if __name__ == "__main__":
    main()
