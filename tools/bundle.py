#!/usr/bin/env python3
"""tools/bundle.py — build tests/build/all.luau for the offline Luau test harness.

Reads default.project.json, walks every "$path" directory using Rojo's file-mapping rules,
and emits ONE self-contained Luau file containing, in order:
  (a) tests/shim.luau            — the Roblox API mock (wrapped so `shim` becomes a global)
  (b) a virtual DataModel tree   — every module's source as a Luau long string + its path
  (c) tests/runner.luau, then every tests/specs/*.spec.luau, then the runner invocation

Modules are compiled lazily by the shim (loadstring on first require), so a module with a
syntax error only fails when it is actually required.  Scripts (.server/.client) are never
auto-run; use shim.runScript(instance).

Usage: python3 tools/bundle.py [--project default.project.json] [--out tests/build/all.luau]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parent.parent

SERVICE_LIKE = {
    "Workspace", "Players", "Lighting", "ReplicatedStorage", "ReplicatedFirst", "ServerStorage",
    "ServerScriptService", "StarterGui", "StarterPlayer", "StarterPack", "SoundService", "Teams",
    "Chat", "TextChatService", "HttpService", "RunService", "TweenService", "Debris", "CollectionService",
    "PhysicsService", "DataStoreService", "MarketplaceService", "UserInputService", "ContextActionService",
    "GuiService", "TextService", "LocalizationService", "TeleportService", "BadgeService", "MaterialService",
    "VoiceChatService", "TestService", "ProximityPromptService", "MessagingService", "PathfindingService",
}


# ----------------------------------------------------------------------------------------------
# glob handling (Rojo's globIgnorePaths are relative to the project directory)
# ----------------------------------------------------------------------------------------------
def glob_to_regex(pattern: str) -> re.Pattern:
    out = []
    i = 0
    while i < len(pattern):
        c = pattern[i]
        if c == "*":
            if pattern[i : i + 2] == "**":
                # '**/' matches zero or more directories
                if pattern[i : i + 3] == "**/":
                    out.append("(?:.*/)?")
                    i += 3
                    continue
                out.append(".*")
                i += 2
                continue
            out.append("[^/]*")
        elif c == "?":
            out.append("[^/]")
        elif c in ".+^$(){}[]|\\":
            out.append("\\" + c)
        else:
            out.append(c)
        i += 1
    return re.compile("^" + "".join(out) + "$")


# ----------------------------------------------------------------------------------------------
# Luau literal emission
# ----------------------------------------------------------------------------------------------
def luau_string(s: str) -> str:
    def esc(m: re.Match) -> str:
        ch = m.group(0)
        table = {"\\": "\\\\", '"': '\\"', "\n": "\\n", "\r": "\\r", "\t": "\\t", "\0": "\\0"}
        if ch in table:
            return table[ch]
        return "\\%d" % ord(ch)

    return '"' + re.sub(r'[\\"\n\r\t\0\x01-\x1f\x7f]', esc, s) + '"'


def luau_long_string(s: str) -> str:
    """Wrap s in a long bracket whose level does not appear in s."""
    level = 0
    while ("]" + "=" * level + "]") in s:
        level += 1
    eq = "=" * level
    # a newline directly after the opening bracket is skipped by the lexer, which keeps line numbers intact
    return "[" + eq + "[\n" + s + "]" + eq + "]"


def luau_value(v, indent: int = 0) -> str:
    pad = "\t" * indent
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        if isinstance(v, float) and (v != v or v in (float("inf"), float("-inf"))):
            return "0/0" if v != v else ("math.huge" if v > 0 else "-math.huge")
        return repr(v)
    if isinstance(v, str):
        return luau_string(v)
    if isinstance(v, list):
        return "{ " + ", ".join(luau_value(x, indent) for x in v) + " }"
    if isinstance(v, dict):
        parts = []
        for k, val in v.items():
            key = k if re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", str(k)) else "[" + luau_string(str(k)) + "]"
            parts.append(f"{pad}\t{key} = {luau_value(val, indent + 1)}")
        if not parts:
            return "{}"
        return "{\n" + ",\n".join(parts) + "\n" + pad + "}"
    raise TypeError(f"cannot emit value of type {type(v).__name__}")


def json_to_module_source(data) -> str:
    return "return " + luau_value(data)


# ----------------------------------------------------------------------------------------------
# tree construction
# ----------------------------------------------------------------------------------------------
class Node:
    def __init__(self, name: str, class_name: str):
        self.name = name
        self.class_name = class_name
        self.properties: dict = {}
        self.attributes: dict = {}
        self.source: str | None = None
        self.file: str | None = None
        self.children: list[Node] = []

    def child(self, name: str) -> "Node | None":
        for c in self.children:
            if c.name == name:
                return c
        return None


class Bundler:
    def __init__(self, project_path: Path, verbose: bool = True):
        self.project_path = project_path
        self.project_dir = project_path.parent
        self.verbose = verbose
        self.warnings: list[str] = []
        with open(project_path, "r", encoding="utf-8") as f:
            self.project = json.load(f)
        self.ignore = [glob_to_regex(p) for p in self.project.get("globIgnorePaths", [])]
        self.module_count = 0

    def warn(self, msg: str) -> None:
        self.warnings.append(msg)
        if self.verbose:
            print("bundle.py: warning: " + msg, file=sys.stderr)

    def rel(self, path: Path) -> str:
        try:
            return PurePosixPath(path.resolve().relative_to(ROOT.resolve())).as_posix()
        except ValueError:
            return path.as_posix()

    def is_ignored(self, path: Path) -> bool:
        try:
            rel = PurePosixPath(path.resolve().relative_to(self.project_dir.resolve())).as_posix()
        except ValueError:
            return False
        return any(rx.match(rel) for rx in self.ignore)

    def read(self, path: Path) -> str:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read()

    # --- project tree ------------------------------------------------------------------------
    def build(self) -> Node:
        tree = self.project.get("tree", {})
        root = Node("game", tree.get("$className", "DataModel"))
        self.apply_project_node(root, tree, is_root=True)
        return root

    def apply_project_node(self, node: Node, spec: dict, is_root: bool = False) -> None:
        if "$properties" in spec:
            node.properties.update(spec["$properties"])
        if "$attributes" in spec:
            node.attributes.update(spec["$attributes"])
        if "$path" in spec:
            self.apply_path(node, self.project_dir / spec["$path"])
            if "$className" in spec:
                node.class_name = spec["$className"]
        for key, child_spec in spec.items():
            if key.startswith("$"):
                continue
            if not isinstance(child_spec, dict):
                self.warn(f"project node '{key}' is not an object; skipped")
                continue
            if "$className" in child_spec:
                class_name = child_spec["$className"]
            elif is_root or (node.class_name == "DataModel"):
                class_name = key  # services are inferred from their name at the DataModel level
            elif "$path" in child_spec:
                class_name = "Folder"  # refined by apply_path
            else:
                class_name = "Folder"
            existing = node.child(key)
            child = existing or Node(key, class_name)
            if existing is None:
                node.children.append(child)
            self.apply_project_node(child, child_spec)

    # --- filesystem mapping (Rojo rules) ------------------------------------------------------
    def apply_path(self, node: Node, path: Path) -> None:
        if not path.exists():
            self.warn(f"$path '{self.rel(path)}' does not exist; '{node.name}' will be an empty Folder")
            return
        if path.is_file():
            self.apply_file_to_node(node, path)
            return
        self.apply_dir(node, path)

    def apply_file_to_node(self, node: Node, path: Path) -> None:
        kind = self.classify(path.name)
        if kind is None:
            self.warn(f"cannot map file '{self.rel(path)}' to an instance; skipped")
            return
        class_name, _ = kind
        node.class_name = class_name
        self.fill_from_file(node, path, class_name)

    def classify(self, filename: str):
        """Return (className, instanceName) for a file name, or None if it is not mapped."""
        lower = filename.lower()
        if lower.endswith(".server.luau") or lower.endswith(".server.lua"):
            return ("Script", filename.rsplit(".", 2)[0])
        if lower.endswith(".client.luau") or lower.endswith(".client.lua"):
            return ("LocalScript", filename.rsplit(".", 2)[0])
        if lower.endswith(".luau") or lower.endswith(".lua"):
            return ("ModuleScript", filename.rsplit(".", 1)[0])
        if lower.endswith(".meta.json") or lower.endswith(".model.json") or lower.endswith(".project.json"):
            return None
        if lower.endswith(".json"):
            return ("ModuleScript", filename[:-5])
        if lower.endswith(".txt"):
            return ("StringValue", filename[:-4])
        return None

    def fill_from_file(self, node: Node, path: Path, class_name: str) -> None:
        node.file = self.rel(path)
        text = self.read(path)
        if class_name in ("Script", "LocalScript", "ModuleScript"):
            if path.name.lower().endswith(".json"):
                try:
                    node.source = json_to_module_source(json.loads(text))
                except (json.JSONDecodeError, TypeError) as e:
                    self.warn(f"invalid JSON module '{self.rel(path)}': {e}")
                    node.source = f"error({luau_string('invalid JSON module: ' + str(e))})"
            else:
                node.source = text
            self.module_count += 1
        elif class_name == "StringValue":
            node.properties["Value"] = text

    def apply_meta(self, node: Node, meta_path: Path) -> None:
        try:
            meta = json.loads(self.read(meta_path))
        except json.JSONDecodeError as e:
            self.warn(f"invalid meta file '{self.rel(meta_path)}': {e}")
            return
        if "className" in meta:
            node.class_name = meta["className"]
        if "properties" in meta and isinstance(meta["properties"], dict):
            node.properties.update(meta["properties"])
        if "attributes" in meta and isinstance(meta["attributes"], dict):
            node.attributes.update(meta["attributes"])

    def apply_dir(self, node: Node, path: Path) -> None:
        entries = sorted(path.iterdir(), key=lambda p: p.name.lower())
        init_file = None
        for entry in entries:
            if entry.is_file() and entry.name.lower() in ("init.luau", "init.lua", "init.server.luau", "init.server.lua", "init.client.luau", "init.client.lua"):
                init_file = entry
                break
        if node.class_name in ("Folder", "DataModel") or node.class_name == node.name:
            if init_file is not None and node.class_name != "DataModel":
                node.class_name = self.classify(init_file.name)[0]
            elif node.class_name == node.name and node.name not in SERVICE_LIKE and node.class_name != "DataModel":
                node.class_name = "Folder"
        if init_file is not None:
            if self.is_ignored(init_file):
                self.warn(f"'{self.rel(init_file)}' matches globIgnorePaths; init file ignored")
            else:
                self.fill_from_file(node, init_file, node.class_name)
        init_meta = path / "init.meta.json"
        if init_meta.exists():
            self.apply_meta(node, init_meta)

        metas: dict[str, Path] = {}
        for entry in entries:
            if entry.is_file() and entry.name.lower().endswith(".meta.json") and entry.name.lower() != "init.meta.json":
                metas[entry.name[: -len(".meta.json")]] = entry

        for entry in entries:
            if self.is_ignored(entry):
                continue
            name = entry.name
            lower = name.lower()
            if entry.is_dir():
                if (entry / "default.project.json").exists():
                    self.warn(f"nested project '{self.rel(entry)}' is not supported; mapped as a plain folder")
                child = Node(name, "Folder")
                self.apply_dir(child, entry)
                node.children.append(child)
                continue
            if lower.startswith("init.") or lower == "init.meta.json":
                continue
            if lower.endswith(".meta.json"):
                continue
            kind = self.classify(name)
            if kind is None:
                if lower.endswith(".md") or lower.endswith(".spec.luau") or name.startswith("."):
                    continue
                if lower.endswith(".model.json") or lower.endswith(".rbxm") or lower.endswith(".rbxmx") or lower.endswith(".csv"):
                    self.warn(f"'{self.rel(entry)}' is not supported by the offline bundler; skipped (an empty Folder is created)")
                    base = name.split(".", 1)[0]
                    node.children.append(Node(base, "Folder"))
                    continue
                self.warn(f"'{self.rel(entry)}' is not mapped by Rojo rules; skipped")
                continue
            class_name, inst_name = kind
            child = Node(inst_name, class_name)
            self.fill_from_file(child, entry, class_name)
            if inst_name in metas:
                self.apply_meta(child, metas[inst_name])
            node.children.append(child)

        for inst_name, meta_path in metas.items():
            if node.child(inst_name) is None and not self.is_ignored(meta_path):
                child = Node(inst_name, "Folder")
                self.apply_meta(child, meta_path)
                node.children.append(child)

    # --- emission ----------------------------------------------------------------------------
    def emit_node(self, node: Node, path: str, out: list[str], indent: int) -> None:
        pad = "\t" * indent
        vpath = (path + "/" if path else "") + node.name
        out.append(f"{pad}{{")
        out.append(f"{pad}\tname = {luau_string(node.name)}, className = {luau_string(node.class_name)}, path = {luau_string(vpath)},")
        if node.properties:
            out.append(f"{pad}\tproperties = {luau_value(node.properties, indent + 1)},")
        if node.attributes:
            out.append(f"{pad}\tattributes = {luau_value(node.attributes, indent + 1)},")
        if node.file:
            out.append(f"{pad}\tfile = {luau_string(node.file)},")
        if node.source is not None:
            out.append(f"{pad}\tsource = {luau_long_string(node.source)},")
        if node.children:
            out.append(f"{pad}\tchildren = {{")
            for child in node.children:
                self.emit_node(child, vpath, out, indent + 2)
            out.append(f"{pad}\t}},")
        out.append(f"{pad}}},")

    def emit_tree(self, root: Node) -> str:
        out = ["shim.defineTree({", f"\tname = \"game\", className = \"DataModel\",", "\tchildren = {"]
        for child in root.children:
            self.emit_node(child, "", out, 2)
        out.append("\t},")
        out.append("})")
        return "\n".join(out)


def wrap_chunk(label: str, source: str, assign_to: str | None = None) -> str:
    """Emit a file's contents as a long string compiled at runtime with its real path as chunkname,
    so error messages and tracebacks point at e.g. tests/specs/foo.spec.luau:12 instead of all.luau."""
    target = f"{assign_to} = " if assign_to else ""
    return (
        f"-- ==== {label} ====\n"
        f"do\n"
        f"\tlocal __fn, __err = loadstring({luau_long_string(source)}, {luau_string('=' + label)})\n"
        f"\tif not __fn then error({luau_string(label + ' failed to compile: ')} .. tostring(__err), 0) end\n"
        f"\t{target}__fn(...)\n"
        f"end\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--project", default=str(ROOT / "default.project.json"))
    parser.add_argument("--out", default=str(ROOT / "tests" / "build" / "all.luau"))
    parser.add_argument("--specs", default=str(ROOT / "tests" / "specs"))
    parser.add_argument("--fixtures", default=str(ROOT / "tests" / "fixtures"))
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args()

    project_path = Path(args.project)
    if not project_path.exists():
        print(f"bundle.py: project file not found: {project_path}", file=sys.stderr)
        return 2
    shim_path = ROOT / "tests" / "shim.luau"
    runner_path = ROOT / "tests" / "runner.luau"
    for required in (shim_path, runner_path):
        if not required.exists():
            print(f"bundle.py: required file missing: {required}", file=sys.stderr)
            return 2

    bundler = Bundler(project_path, verbose=not args.quiet)
    root = bundler.build()

    # test fixtures are mapped into ReplicatedStorage.TestFixtures
    fixtures_dir = Path(args.fixtures)
    if fixtures_dir.exists():
        rs = root.child("ReplicatedStorage")
        if rs is None:
            rs = Node("ReplicatedStorage", "ReplicatedStorage")
            root.children.append(rs)
        fixtures = Node("TestFixtures", "Folder")
        bundler.apply_dir(fixtures, fixtures_dir)
        existing = rs.child("TestFixtures")
        if existing is not None:
            rs.children.remove(existing)
        rs.children.append(fixtures)

    specs_dir = Path(args.specs)
    spec_files = sorted(specs_dir.glob("*.spec.luau")) if specs_dir.exists() else []

    parts: list[str] = []
    parts.append("--!nonstrict")
    parts.append("-- GENERATED by tools/bundle.py — do not edit. Run `bash tests/run.sh`.")
    parts.append("local __ddc_args = { ... }")
    parts.append(wrap_chunk("tests/shim.luau", bundler.read(shim_path), assign_to="shim"))
    parts.append("shim.install()")
    parts.append("-- ==== virtual DataModel ====")
    parts.append(bundler.emit_tree(root))
    parts.append(wrap_chunk("tests/runner.luau", bundler.read(runner_path)))
    for spec in spec_files:
        parts.append(wrap_chunk(bundler.rel(spec), bundler.read(spec)))
    parts.append("-- ==== run ====")
    parts.append("__ddc_runner.run(__ddc_args)")

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(parts) + "\n")

    if not args.quiet:
        print(f"bundle.py: wrote {bundler.rel(out_path)} ({bundler.module_count} modules, {len(spec_files)} spec files, {len(bundler.warnings)} warnings)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
