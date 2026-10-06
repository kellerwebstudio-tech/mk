#!/usr/bin/env python3
"""Export src/shared/City/CityLayout.luau to JSON (tests/build/layout.json) using the luau CLI.

The layout module is bundled with the Vector3 stub (see luau_bundle.py) plus a tiny Luau JSON encoder,
executed with $DDC_TOOLS/luau, and the printed JSON is parsed and re-written by Python.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from luau_bundle import BUILD_DIR, bundle, run_luau  # noqa: E402

JSON_MAIN = r"""
local function isArray(t)
    local n = 0
    for _ in pairs(t) do n += 1 end
    return n == #t
end
local function encode(v, out)
    local tv = type(v)
    if tv == "nil" then
        out[#out + 1] = "null"
    elseif tv == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            out[#out + 1] = "null"
        elseif v == math.floor(v) and math.abs(v) < 1e15 then
            out[#out + 1] = string.format("%d", v)
        else
            out[#out + 1] = string.format("%.6g", v)
        end
    elseif tv == "string" then
        local s = v:gsub('[%c"\\]', function(c)
            if c == '"' then return '\\"' elseif c == "\\" then return "\\\\" end
            return string.format("\\u%04x", string.byte(c))
        end)
        out[#out + 1] = '"' .. s .. '"'
    elseif tv == "table" then
        if isArray(v) then
            out[#out + 1] = "["
            for i, item in ipairs(v) do
                if i > 1 then out[#out + 1] = "," end
                encode(item, out)
            end
            out[#out + 1] = "]"
        else
            out[#out + 1] = "{"
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            for i, k in ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                encode(k, out)
                out[#out + 1] = ":"
                encode(v[k] == nil and v[tonumber(k)] or v[k], out)
            end
            out[#out + 1] = "}"
        end
    else
        out[#out + 1] = "null"
    end
end
local out = {}
encode(CityLayout, out)
print(table.concat(out))
"""


def export() -> dict:
    result = run_luau(bundle(JSON_MAIN), "export_layout.luau")
    if result.returncode != 0:
        sys.stderr.write(result.stdout)
        sys.stderr.write(result.stderr)
        raise SystemExit("luau export failed")
    text = result.stdout.strip().splitlines()[-1]
    data = json.loads(text)
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    out_path = BUILD_DIR / "layout.json"
    out_path.write_text(json.dumps(data, indent=1), encoding="utf-8")
    return data


def main() -> int:
    data = export()
    print(f"exported {len(data['roads'])} roads, {len(data['buildings'])} buildings, "
          f"{len(data['destinations'])} destinations, {len(data['props'])} props -> {BUILD_DIR / 'layout.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
