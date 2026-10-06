"""Shared helper: bundle Shared/City modules with a Vector3 stub so they run under the plain luau CLI.

Usage from other tools:
    from luau_bundle import bundle, run_luau

`bundle(extra_main)` returns a Luau source string that defines a metatable-based Vector3,
loads CityLayout and RouteGraph through a fake `script`/`require` shim, and then runs
`extra_main` (a Luau snippet that can use `CityLayout`, `RouteGraph` and `Vector3`).
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CITY_DIR = REPO / "src" / "shared" / "City"
BUILD_DIR = REPO / "tests" / "build"

MODULES = ["CityLayout", "RouteGraph"]  # loaded in this order; each may require the others lazily

VECTOR3_STUB = r"""
-- Minimal Vector3 stub for the luau CLI (metatable-based; X/Y/Z, arithmetic, Magnitude, Unit, Dot, Cross, Lerp).
local Vector3 = {}
local V3 = {}
V3.__index = function(self, key)
    if key == "Magnitude" then
        return math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
    elseif key == "Unit" then
        local m = math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
        if m == 0 then return Vector3.new(0, 0, 0) end
        return Vector3.new(self.X / m, self.Y / m, self.Z / m)
    end
    return V3[key]
end
function Vector3.new(x, y, z)
    return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V3)
end
Vector3.zero = Vector3.new(0, 0, 0)
Vector3.one = Vector3.new(1, 1, 1)
Vector3.xAxis = Vector3.new(1, 0, 0)
Vector3.yAxis = Vector3.new(0, 1, 0)
Vector3.zAxis = Vector3.new(0, 0, 1)
V3.__add = function(a, b) return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z) end
V3.__sub = function(a, b) return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z) end
V3.__unm = function(a) return Vector3.new(-a.X, -a.Y, -a.Z) end
V3.__mul = function(a, b)
    if type(a) == "number" then return Vector3.new(a * b.X, a * b.Y, a * b.Z) end
    if type(b) == "number" then return Vector3.new(a.X * b, a.Y * b, a.Z * b) end
    return Vector3.new(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
V3.__div = function(a, b)
    if type(b) == "number" then return Vector3.new(a.X / b, a.Y / b, a.Z / b) end
    return Vector3.new(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
V3.__eq = function(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
V3.__tostring = function(a) return string.format("%g, %g, %g", a.X, a.Y, a.Z) end
function V3:Dot(o) return self.X * o.X + self.Y * o.Y + self.Z * o.Z end
function V3:Cross(o)
    return Vector3.new(self.Y * o.Z - self.Z * o.Y, self.Z * o.X - self.X * o.Z, self.X * o.Y - self.Y * o.X)
end
function V3:Lerp(o, t) return self + (o - self) * t end
function V3:FuzzyEq(o, eps)
    eps = eps or 1e-5
    return math.abs(self.X - o.X) <= eps and math.abs(self.Y - o.Y) <= eps and math.abs(self.Z - o.Z) <= eps
end
-- (Vector3 stays a chunk-level local; module functions below capture it as an upvalue)
"""

SHIM_HEADER = r"""
-- Module shim: each module runs inside a function with a fake `script` whose Parent exposes sibling
-- module keys, and a `require` that resolves those keys (so `require(script.Parent.CityLayout)` works).
local __loaders = {}
local __cache = {}
local __nativeRequire = require
local __parent = {}
local __scripts = {}
local function __require(target)
    if type(target) == "table" and target.__moduleName then
        local name = target.__moduleName
        if __cache[name] == nil then
            local loader = __loaders[name]
            if loader == nil then error("unknown module " .. tostring(name)) end
            __cache[name] = loader(__scripts[name], __require)
        end
        return __cache[name]
    end
    return __nativeRequire(target)
end
"""


def _module_source(name: str) -> str:
    path = CITY_DIR / f"{name}.luau"
    return path.read_text(encoding="utf-8")


def bundle(main: str) -> str:
    parts = [VECTOR3_STUB, SHIM_HEADER]
    for name in MODULES:
        parts.append(f'__parent["{name}"] = {{ __moduleName = "{name}", Name = "{name}" }}\n')
    for name in MODULES:
        parts.append(f'__scripts["{name}"] = {{ Name = "{name}", Parent = __parent }}\n')
    for name in MODULES:
        src = _module_source(name)
        parts.append(f'__loaders["{name}"] = function(script, require)\n{src}\nend\n')
    for name in MODULES:
        parts.append(f'local {name} = __require(__parent["{name}"])\n')
    parts.append("\n-- main --\n")
    parts.append(main)
    return "".join(parts)


def tools_dir() -> Path:
    env = os.environ.get("DDC_TOOLS")
    if env:
        return Path(env)
    # Fallback: look for a sibling "tools" dir containing the luau binary next to the scratchpad layout.
    candidates = [
        Path("/tmp/claude-0/-home-user-mk/3419e611-d3a8-57fd-a159-26d72f1bea4b/scratchpad/tools"),
    ]
    for c in candidates:
        if (c / "luau").exists():
            return c
    raise SystemExit("Set DDC_TOOLS to the directory containing the `luau` binary")


def run_luau(source: str, out_name: str) -> subprocess.CompletedProcess:
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    out_path = BUILD_DIR / out_name
    out_path.write_text(source, encoding="utf-8")
    luau = tools_dir() / "luau"
    return subprocess.run([str(luau), str(out_path)], capture_output=True, text=True)


if __name__ == "__main__":
    print(bundle("print('bundle ok')"), file=sys.stdout)
