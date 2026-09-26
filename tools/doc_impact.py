#!/usr/bin/env python3
"""Read the maintenance map and report review scope; never modify repository files.

Examples: doc_impact.py --check; doc_impact.py --topic online-installer;
doc_impact.py src/installer.lua; doc_impact.py --diff HEAD
Output is JSON. Exit 2 means invalid input, invalid map, or an unmapped path.
Listed checks are instructions for review, not checks performed by this tool.
"""
import argparse
from fnmatch import fnmatchcase
import json
from pathlib import Path, PurePosixPath
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[1]
PATH_ROLES = ("triggers", "authority", "review", "artifacts", "historical")


def strings(value, label):
    if not isinstance(value, list) or any(not isinstance(v, str) or not v for v in value):
        raise ValueError(label + " must be an array of nonempty strings")
    return value


def repo_path(value):
    """Reject paths outside the repository and Markdown URL/anchor notation."""
    if (not isinstance(value, str) or not value or "\\" in value or "#" in value
            or "://" in value or PurePosixPath(value).is_absolute()
            or ".." in PurePosixPath(value).parts):
        raise ValueError("expected repository-relative path/glob: " + repr(value))
    normalized = str(PurePosixPath(value))
    if normalized == ".":
        raise ValueError("expected a file path, not the repository root")
    return normalized


def load_map(path):
    with path.open(encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict) or type(data.get("schema_version")) is not int or data["schema_version"] != 1:
        raise ValueError("unsupported maintenance map schema_version (expected 1)")
    if not isinstance(data.get("policy"), dict):
        raise ValueError("policy must be an object")
    surfaces = data.get("external_surfaces")
    if not isinstance(surfaces, dict) or any(not isinstance(v, dict) for v in surfaces.values()):
        raise ValueError("external_surfaces must map IDs to objects")
    for identifier, surface in surfaces.items():
        if "maintained" not in surface:
            continue
        entries = surface["maintained"]
        if not isinstance(entries, list):
            raise ValueError(identifier + ".maintained must be an array")
        tags = set()
        for entry in entries:
            if not isinstance(entry, dict):
                raise ValueError(identifier + ".maintained entries must be objects")
            tag = entry.get("tag")
            if not isinstance(tag, str) or not tag or tag in tags:
                raise ValueError(identifier + ".maintained tags must be nonempty and unique")
            tags.add(tag)
            repo_path(entry.get("source"))
    coverage = data.get("coverage")
    if not isinstance(coverage, dict):
        raise ValueError("coverage must be an object")
    for role in ("include", "exclude"):
        for pattern in strings(coverage.get(role), "coverage." + role):
            repo_path(pattern)
    groups = data.get("groups")
    if not isinstance(groups, list) or not groups:
        raise ValueError("groups must be a nonempty array")
    seen = set()
    for group in groups:
        if not isinstance(group, dict):
            raise ValueError("each group must be an object")
        identifier = group.get("id")
        if not isinstance(identifier, str) or not identifier or identifier in seen:
            raise ValueError("group IDs must be nonempty and unique: " + repr(identifier))
        seen.add(identifier)
        if not isinstance(group.get("title"), str) or not group["title"]:
            raise ValueError(identifier + ".title must be a nonempty string")
        for role in PATH_ROLES:
            for pattern in strings(group.get(role), identifier + "." + role):
                repo_path(pattern)
        for surface in strings(group.get("external"), identifier + ".external"):
            if surface not in surfaces:
                raise ValueError(identifier + ": unknown external surface " + surface)
        strings(group.get("checks"), identifier + ".checks")
    return data


def git(root, *arguments):
    result = subprocess.run(["git", "-C", str(root), *arguments], capture_output=True)
    if result.returncode:
        raise ValueError(result.stderr.decode("utf-8", errors="replace").strip())
    return result.stdout.decode("utf-8", errors="surrogateescape")


def inventory(root):
    candidates = git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z").split("\0")
    return sorted({p for p in candidates if p and (root / p).is_file()})


def patterns(group):
    return [pattern for role in PATH_ROLES for pattern in group[role]]


def matches(path, candidates):
    return any(fnmatchcase(path, pattern) for pattern in candidates)


def check_map(data, root):
    files = inventory(root)
    errors = []
    for identifier, surface in data["external_surfaces"].items():
        for entry in surface.get("maintained", []):
            if repo_path(entry["source"]) not in files:
                errors.append(identifier + ".maintained: missing source " + entry["source"])
    for group in data["groups"]:
        for role in PATH_ROLES:
            for pattern in group[role]:
                if not any(fnmatchcase(path, pattern) for path in files):
                    errors.append(group["id"] + "." + role + ": no file matches " + pattern)
    coverage = data["coverage"]
    relevant = [p for p in files if matches(p, coverage["include"]) and not matches(p, coverage["exclude"])]
    all_patterns = [pattern for group in data["groups"] for pattern in patterns(group)]
    errors.extend("unmapped relevant file: " + p for p in relevant if not matches(p, all_patterns))
    if errors:
        raise ValueError("\n".join(errors))
    return {"map_valid": True, "covered_files": len(relevant), "content_checks_performed": False}


def diff_paths(root, reference):
    # Resolve a revision before diffing so REF cannot inject Git options.
    commit = git(root, "rev-parse", "--verify", "--end-of-options", reference + "^{commit}").strip()
    # --name-status -z preserves spaces; R/C records contain both old and new names.
    fields = git(root, "diff", "--no-ext-diff", "--no-textconv", "--name-status", "-z", "--find-renames", commit, "--").split("\0")
    result = set()
    cursor = 0
    while cursor < len(fields) and fields[cursor]:
        status = fields[cursor]
        count = 2 if status.startswith(("R", "C")) else 1
        names = fields[cursor + 1:cursor + count + 1]
        if len(names) != count or any(not p for p in names):
            raise ValueError("unexpected git diff name-status output")
        result.update(names)
        cursor += count + 1
    result.update(p for p in git(root, "ls-files", "--others", "--exclude-standard", "-z").split("\0") if p)
    return sorted(result)


def impact(data, paths, topics):
    by_id = {group["id"]: group for group in data["groups"]}
    unknown = sorted(set(topics) - by_id.keys())
    if unknown:
        raise ValueError("unknown topic(s): " + ", ".join(unknown))
    selected = set(topics)
    unmatched = []
    for path in paths:
        ids = [group["id"] for group in data["groups"] if matches(path, patterns(group))]
        selected.update(ids)
        if not ids:
            unmatched.append(path)
    if unmatched:
        raise ValueError("unmapped changed path(s): " + ", ".join(unmatched))
    fields = ("id", "title", "authority", "review", "artifacts", "historical", "external", "checks")
    groups = [{key: group[key] for key in fields} for group in data["groups"] if group["id"] in selected]
    surfaces = {key: data["external_surfaces"][key] for group in groups for key in group["external"]}
    return {"changed_paths": paths, "review_status": "not_checked", "groups": groups, "external_surfaces": surfaces}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", help="changed repository-relative files")
    parser.add_argument("--topic", action="append", default=[], help="maintenance group ID; repeatable")
    parser.add_argument("--diff", metavar="REF", help="include differences from Git REF and untracked files")
    parser.add_argument("--check", action="store_true", help="validate map references and inventory coverage")
    parser.add_argument("--list", action="store_true", help="list available topic IDs")
    parser.add_argument("--root", type=Path, default=ROOT, help="repository root")
    parser.add_argument("--map", default="docs/maintenance-map.json", help="repository-relative map path")
    args = parser.parse_args(argv)
    if not (args.paths or args.topic or args.diff or args.check or args.list):
        parser.error("provide paths, --topic, --diff, --check, or --list")
    try:
        root = args.root.resolve()
        data = load_map(root / repo_path(args.map))
        paths = sorted({repo_path(p) for p in args.paths + (diff_paths(root, args.diff) if args.diff else [])})
        result = impact(data, paths, args.topic)
        if args.check:
            result["validation"] = check_map(data, root)
        if args.list:
            result["topics"] = [{"id": g["id"], "title": g["title"]} for g in data["groups"]]
        print(json.dumps(result, ensure_ascii=False, indent=2))
        return 0
    except (ValueError, OSError) as error:
        print(json.dumps({"error": str(error)}, ensure_ascii=False), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
