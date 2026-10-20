#!/usr/bin/env python3
"""Minimal YAML-subset -> JSON converter (stdlib only).

Purpose: let `scripts/import.sh` accept the YAML that `scripts/export.sh`
writes, without a third-party YAML dependency.

It parses the *block-style YAML subset* produced by this repo's
`export.sh`:
  - `key: value`  (scalar)
  - `key:`        (nested mapping or block list follows)
  - `- item`      (block list of scalars)
  - `- `          (block list of mappings, keys indented under the dash)
  - nested mappings by 2-space (or consistent) indentation
  - scalars: null, true/false, int, float, "quoted", 'quoted', plain
  - flow empty containers: []  {}
  - flow scalar lists: [a, b, "c: d"]   (best-effort)
  - full-line comments (# ...) and the trailing generated-by comment

It is NOT a general YAML parser (no anchors, multi-line |/> scalars, tags,
or complex flow nesting). For arbitrary hand-written YAML, prefer the JSON
twin or a real YAML tool.

Usage:
    python3 yaml2json.py file.yml [outfile.json]     # default: <file>.json
    cat file.yml | python3 yaml2json.py -            # read stdin
"""
import json
import sys


def _strip_comment(line: str) -> str:
    """Remove a full-line or trailing ' #...' comment, respecting quotes."""
    if line.lstrip().startswith("#"):
        return ""
    out = []
    q = None
    for i, ch in enumerate(line):
        if q:
            out.append(ch)
            if ch == q and line[i - 1] != "\\":
                q = None
        else:
            if ch in "\"'":
                q = ch
                out.append(ch)
            elif ch == "#" and (i == 0 or line[i - 1] in " \t"):
                break
            else:
                out.append(ch)
    return "".join(out).rstrip()


def _scalar(tok: str):
    tok = tok.strip()
    if tok == "" or tok in ("~", "null", "Null", "NULL"):
        return None
    if tok in ("true", "True", "TRUE"):
        return True
    if tok in ("false", "False", "FALSE"):
        return False
    if (tok.startswith('"') and tok.endswith('"') and len(tok) >= 2):
        return tok[1:-1].replace('\\"', '"').replace("\\\\", "\\")
    if (tok.startswith("'") and tok.endswith("'") and len(tok) >= 2):
        return tok[1:-1].replace("''", "'")
    # int
    try:
        return int(tok)
    except ValueError:
        pass
    # float
    try:
        return float(tok)
    except ValueError:
        pass
    return tok


def _flow_list(tok: str):
    inner = tok[1:-1].strip()
    if inner == "":
        return []
    parts, cur, q = [], [], None
    for ch in inner:
        if q:
            cur.append(ch)
            if ch == q:
                q = None
        elif ch in "\"'":
            q = ch
            cur.append(ch)
        elif ch == ",":
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    if cur:
        parts.append("".join(cur))
    return [_scalar(p) for p in parts if p.strip() != ""]


def _parse_block(lines, idx, indent):
    """Parse a block starting at lines[idx] whose items are at `indent`.
    Returns (value, next_idx)."""
    # decide list vs mapping by first meaningful line
    probe = lines[idx][1]
    if probe.startswith("- ") or probe == "-":
        return _parse_list(lines, idx, indent)
    return _parse_map(lines, idx, indent)


def _parse_map(lines, idx, indent):
    result = {}
    n = len(lines)
    while idx < n:
        line = lines[idx]
        if line[0] != indent or not line[1].strip():
            break
        content = line[1].strip()
        if ":" not in content:
            raise ValueError("bad mapping line: %r" % line[1])
        key, _, val = content.partition(":")
        key = key.strip()
        val = val.strip()
        if val == "":
            # nested block on following lines
            j = idx + 1
            while j < n and not lines[j][1].strip():
                j += 1
            if j < n and lines[j][0] > indent:
                child_indent = lines[j][0]
                value, idx = _parse_block(lines, j, child_indent)
                result[key] = value
                continue
            result[key] = None
            idx += 1
        elif val == "[]":
            result[key] = []
            idx += 1
        elif val == "{}":
            result[key] = {}
            idx += 1
        elif val.startswith("[") and val.endswith("]"):
            result[key] = _flow_list(val)
            idx += 1
        else:
            result[key] = _scalar(val)
            idx += 1
    return result, idx


def _parse_list(lines, idx, indent):
    result = []
    n = len(lines)
    while idx < n:
        line = lines[idx]
        if line[0] != indent or not (line[1].startswith("- ") or line[1] == "-"):
            break
        after = line[1][1:] if line[1].startswith("- ") else ""
        after = after.strip()
        if after == "":
            # item is a nested block (mapping) on following lines,
            # whose keys sit at any column deeper than the dash column
            j = idx + 1
            while j < n and not lines[j][1].strip():
                j += 1
            if j < n and lines[j][0] > indent and not lines[j][1].startswith("- "):
                value, idx = _parse_map(lines, j, lines[j][0])
                result.append(value)
                continue
            result.append(None)
            idx += 1
        elif ":" in after and not (after.startswith('"') or after.startswith("'")):
            # list item is an inline mapping: "- key: value"
            # Rebuild the item as a flat (indent, text) list: the first key
            # comes from the dash line itself; sibling keys sit at the dash
            # column + 2; nested children (block lists / sub-maps) sit
            # deeper. Collect every line with indent >= item_indent, keeping
            # its original indent, and stop at the first line that falls
            # back below item_indent (the next sibling dash or the parent).
            item_indent = indent + 2
            pseudo = [(item_indent, after)]
            k = idx + 1
            while k < n:
                if not lines[k][1].strip():
                    k += 1
                    continue
                if lines[k][0] >= item_indent:
                    pseudo.append((lines[k][0], lines[k][1].strip()))
                    k += 1
                else:
                    break
            value, _ = _parse_map(pseudo, 0, item_indent)
            result.append(value)
            idx = k
        else:
            if after.startswith("[") and after.endswith("]"):
                result.append(_flow_list(after))
            else:
                result.append(_scalar(after))
            idx += 1
    return result, idx


def yaml_to_json(text: str):
    lines = []
    for raw in text.splitlines():
        no_tab = raw.replace("\t", "  ")
        line = _strip_comment(no_tab)
        if line.strip() == "":
            lines.append((0, ""))
            continue
        indent = len(line) - len(line.lstrip(" "))
        lines.append((indent, line.strip()))
    if not any(l[1] for l in lines):
        return {}
    value, _ = _parse_block(lines, 0, lines[0][0])
    return value


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    src = argv[1]
    if src == "-":
        text = sys.stdin.read()
        base = ""
    else:
        with open(src, "r", encoding="utf-8") as f:
            text = f.read()
        base = src
    data = yaml_to_json(text)
    out = json.dumps(data, indent=2) + "\n"
    if len(argv) >= 3:
        with open(argv[2], "w", encoding="utf-8") as f:
            f.write(out)
        print("wrote %s (%d top-level keys)" % (argv[2], len(data)))
    else:
        if base:
            with open(base + ".json", "w", encoding="utf-8") as f:
                f.write(out)
            print("wrote %s.json (%d top-level keys)" % (base, len(data)))
        else:
            sys.stdout.write(out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
