# Custom vehicle meshes: import guide

The three Meshy vehicles are converted and ready under `assets/meshes/`:

| Folder | Files | Size in studs (w × h × l) | Triangles |
|---|---|---|---|
| `assets/meshes/Bicycle/` | `Bicycle_Body.obj`, `Bicycle.mtl`, `Bicycle_Texture.png` | 2.68 × 3.65 × 6.2 | 2,853 |
| `assets/meshes/Scooter/` | `Scooter_Body.obj`, `Scooter.mtl`, `Scooter_Texture.png` | 2.99 × 4.27 × 6.4 | 2,879 |
| `assets/meshes/Van/` | `Van_Body.obj`, `Van.mtl`, `Van_Texture.png` | 7.23 × 7.25 × 13.5 | 3,035 |

What the conversion did (`tools/mesh_convert.py`): rotated each model so it faces -Z (Roblox forward), scaled it to the game's length, put the wheels on the ground at the vehicle's ride height, centred it on its wheel line (the scooter was also straightened by 7.7°), and downscaled the 4096 px texture to Roblox's 1024 px limit. The `*_converted.png` files show side/top/front views of the result.

Wheels are part of each body mesh, so they do not spin yet. The builder already accepts separate wheel meshes (`MeshAssets.<Vehicle>.wheels`); when you have wheel models, drop them in the same way and they will rotate and steer.

## Importing (about five minutes, once)

Roblox needs the meshes uploaded to your account; that cannot be done from this repository.

1. In Roblox Studio open the place, then **File → Import 3D** (or the Asset Manager → Import). Select `assets/meshes/Bicycle/Bicycle_Body.obj`.
2. In the importer: set **Scale Unit** to **Studs** (so 1 unit = 1 stud; do not use metres), keep *Merge meshes* off, and make sure the texture is detected (the preview shows the painted model). Click **Import**.
3. A `MeshPart` appears in the workspace. Select it and read two values in the Properties panel:
   - **MeshId**, like `rbxassetid://123456789`
   - **TextureID**, like `rbxassetid://987654321`
   Delete the MeshPart from the workspace afterwards (the game builds vehicles itself).
4. Repeat for `Scooter_Body.obj` and `Van_Body.obj`.
5. Open `src/shared/Config/MeshAssets.luau` and paste the numbers:
   ```lua
   Bicycle = { body = { meshId = 123456789, textureId = 987654321 }, wheels = {} },
   Scooter = { body = { meshId = ..., textureId = ... }, wheels = {} },
   Van     = { body = { meshId = ..., textureId = ... }, wheels = {} },
   ```
6. Rebuild or sync with Rojo (`rojo build default.project.json -o dist/DeliveryDashCity.rbxl`, or **Connect** with the Rojo plugin while `rojo serve` runs) and press Play. The server creates each vehicle body from the uploaded mesh (`AssetService:CreateMeshPartAsync`) and uses the mesh-specific seat, cargo and chassis values from `VehicleDefinitions.mesh`. If an id is wrong or the asset is not accessible, the server prints one warning and falls back to the built-in blocky vehicle, so nothing breaks.

If the Studio importer created the texture as a **SurfaceAppearance** child instead of a TextureID, copy the `ColorMap` id into `textureId`; the builder applies it as the mesh texture.

## Checking in Studio

- The bike's saddle should sit at the rider's hips and the wheels on the road; if the model floats or sinks, adjust `mesh.body.offset` (y) in `VehicleDefinitions`.
- If a vehicle faces backwards, the conversion rotation is wrong for that file: re-run `python3 tools/mesh_convert.py <obj> <VehicleId> <length> <rideHeight> assets/meshes/<VehicleId> 0 180`.
- Paint cosmetics (bike colours, van paint, decals) do not recolour textured meshes; they still apply to the built-in vehicles.

## Re-converting new Meshy exports

```
python3 tools/mesh_convert.py <path/to/model.obj> Bicycle 6.2 1.5 assets/meshes/Bicycle 0
python3 tools/mesh_convert.py <path/to/model.obj> Scooter 6.4 1.5 assets/meshes/Scooter 0 [yawFixDegrees]
python3 tools/mesh_convert.py <path/to/model.obj> Van 13.5 2.4 assets/meshes/Van 0
```
The script prints the bounding-box centre; copy it into `VehicleDefinitions.mesh.body.offset`. `tools/mesh_analyze.py <obj>` prints bounds, components and renders orthographic views of any OBJ.
