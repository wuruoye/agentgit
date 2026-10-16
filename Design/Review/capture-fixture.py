"""Capture read-only Git content for the native review sample."""
import argparse
import json
import re
import subprocess
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("repository", type=Path)
    parser.add_argument("commit")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    def git(*arguments):
        return subprocess.check_output(
            ["git", "-C", str(args.repository), *arguments], text=True
        )

    remote_prefixes = tuple(remote + "/" for remote in git("remote").splitlines())

    def reference_priority(reference):
        if reference.startswith("HEAD -> "):
            return 0, reference
        if reference.startswith("tag: "):
            return 2, reference
        if remote_prefixes and reference.startswith(remote_prefixes):
            return 3, reference
        return 1, reference

    commits = []
    for record in git(
        "log", args.commit, "-24", "--decorate=short",
        "--format=%H%x1f%s%x1f%an%x1f%at%x1f%D%x1e"
    ).split("\x1e"):
        if not record.strip():
            continue
        oid, subject, author, timestamp, refs = record.strip("\r\n").split("\x1f", 4)
        commits.append({
            "id": oid, "subject": subject, "author": author,
            "date": datetime.fromtimestamp(int(timestamp), ZoneInfo("Asia/Taipei")).strftime("%b %-d"),
            "references": sorted([ref for ref in refs.split(", ") if ref], key=reference_priority)
        })

    files = []
    current = None
    hunk = None
    old_line = new_line = 0
    for line in git("show", args.commit, "--format=", "--no-color", "--no-ext-diff", "--unified=3").splitlines():
        if line.startswith("diff --git "):
            current = {"path": line.split(" b/", 1)[1], "hunks": [], "added": 0, "deleted": 0}
            files.append(current)
            hunk = None
        elif line.startswith("@@"):
            match = re.match(r"@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@\s?(.*)", line)
            old_line, new_line = int(match[1]), int(match[3])
            hunk = {"id": f"{current['path']}:{new_line}", "title": match[5], "header": line, "lines": []}
            current["hunks"].append(hunk)
        elif hunk is not None and line[:1] in (" ", "+", "-"):
            kind = {" ": "context", "+": "addition", "-": "deletion"}[line[0]]
            hunk["lines"].append({
                "kind": kind, "old": old_line if kind != "addition" else None,
                "new": new_line if kind != "deletion" else None, "text": line[1:]
            })
            if kind != "addition":
                old_line += 1
            if kind != "deletion":
                new_line += 1
            if kind == "addition":
                current["added"] += 1
            elif kind == "deletion":
                current["deleted"] += 1

    fixture = {
        "commits": commits, "files": files,
        "message": git("show", "-s", "--format=%B", args.commit).strip(),
        "added": sum(file["added"] for file in files),
        "deleted": sum(file["deleted"] for file in files)
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(fixture, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"files": len(files), "hunks": sum(len(f["hunks"]) for f in files),
                      "added": fixture["added"], "deleted": fixture["deleted"]}))


if __name__ == "__main__":
    main()
