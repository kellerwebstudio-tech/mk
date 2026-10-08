# Custom meshes (vehicles, people, courier vest)

## Embedded mode (no upload) — the active mode

The meshes ship **inside the place**: `tools/mesh_embed.py` packs each `assets/meshes/<VehicleId>/<VehicleId>_Body.obj`
and `<VehicleId>_Texture.png` into Luau data modules under `src/shared/MeshData/<VehicleId>/` (`init.luau` index plus
`G<n>` geometry and `T<n>` texture chunks, each returning one base64 string of at most 150,000 characters). At runtime:

- **Server** (`VehicleBuilder`): with `MeshAssets.Vehicles[id].embedded = true` (the default for Bicycle, Scooter and
  Van) and a data module present (`MeshAssets.isEmbedded(id)`), the vehicle body is an invisible placeholder `Part`
  `MeshBody` of the mesh's size and offset (tag `EmbeddedMeshBody`, attributes `VehicleId`, `EmbeddedMesh`,
  `EmbeddedPart = "Body"`). Nothing is loaded from
  Roblox; `VehicleService` publishes the same placeholder in the shop display copies.
- **Client** (`EmbeddedMeshController`): after joining, one background task per vehicle decodes the texture
  (`Base64` → `Inflate` → `PngDecoder`) and the geometry (`MeshPack`, "DDCM" v1), creates an `EditableImage` and an
  `EditableMesh`, turns them into one `MeshPart` with `AssetService:CreateMeshPartAsync(Content.fromObject(...))` and
  attaches a clone to every placeholder (welded on a live vehicle, anchored on a display). The vehicles are decoded one
  after another and every stage yields regularly, so the frame rate stays smooth; expect roughly 1–3 s per vehicle after join and about 12 MB of texture memory per client
  (three 1024 × 1024 RGBA images). A decode failure warns once and leaves that vehicle as a semi-transparent grey box.

Regenerate the data after changing a mesh or texture (requires Python 3 with numpy and Pillow):

```
python3 tools/mesh_embed.py          # 1024 px textures (default)
python3 tools/mesh_embed.py 512      # smaller textures: faster decode, a quarter of the memory
```

The script rewrites `src/shared/MeshData/<VehicleId>/*.luau` and `src/shared/MeshData/report.json`; then sync with Rojo
as usual. Uploading the meshes is optional: to use uploaded ids instead (one `MeshPart` created by the server, no client
decode), import them as described below and set `embedded = false` for that vehicle in `Shared/Config/MeshAssets.luau`.

## People (NPC figures) — embedded

The eight Meshy people (`NPCCustomerA/B`, `NPCStaff`, `NPCWorker`, `NPCDriver`, `NPCPedestrianA/B/C`) are embedded the
same way (`src/shared/MeshData/<Id>/`, kind `figure`, 512 px texture). `tools/mesh_embed.py` converts each source OBJ
into game coordinates (-Z forward, origin between the feet on the ground, 5.2 studs tall), **splits it into three parts
at the hip line** (`Body`, `LegL`, `LegR`; everything below `HIP_FRACTION` of the height, left/right of x = 0) and
stores every part's bounding box plus, for the legs, the hip `pivot`. A leg blob is written relative to its pivot so
the MeshPart the client builds is centred on its own bounds.

At runtime a person is a **placeholder rig** (`Shared/Util/FigureRig.build`): an invisible `Root` 3 studs above the
feet, an invisible `Body` placeholder welded to it and two leg placeholders on `Motor6D`s named `LeftHip` / `RightHip`
whose `C0`/`C1` put the joint on the hip point (`C0 = pivot - rootCentre`, `C1 = pivot - bboxCentre`). The client
`EmbeddedMeshController` decodes the three parts (one shared `EditableImage`), welds a clone to every placeholder and
the legs swing by writing `Motor6D.Transform = CFrame.Angles(sin(phase) * 0.55, 0, 0)` (`FigureRig.setWalkPose`; the
right leg gets the opposite angle, `setIdlePose` resets both). Who uses which figure (`FigureRig.idForKind`):

| NPC kind | Figure | Where |
|---|---|---|
| Staff | `NPCStaff` | business counters (server, frozen) |
| Driver | `NPCDriver` | hired depot drivers (server, frozen) |
| Worker | `NPCWorker` | depot yards (client, idle) |
| Customer | `NPCCustomerA` / `B` (seed % 2) | idle near destinations and in the doorway after a delivery (client) |
| Pedestrian | `NPCPedestrianA` / `B` / `C` (seed % 3) | walking the pedestrian loops (client) |

Without the data modules (or with a decode failure) the game falls back to the generated part figures, or shows the
placeholders as semi-transparent grey boxes.

## Courier vest — embedded, tinted at runtime

`CourierVest` (kind `accessory`, no texture) is fitted to an R15 `UpperTorso` (2.3 × 1.9 × 1.3 studs, origin at the vest
centre). `ShopService.ApplyUniform` welds an invisible placeholder `CourierVest` to the torso with the attribute
`MeshColor` = the equipped uniform's vest colour; the client attaches the mesh clone and keeps its `Color` in sync
with that attribute (`Material` SmoothPlastic), so changing uniforms only rewrites the attribute. Without the data the
generated vest + trim parts are used.

## Regenerating the embedded data

```
python3 -I tools/mesh_embed.py                     # every entry of MANIFEST (vehicles, people, vest)
python3 -I tools/mesh_embed.py NPCStaff CourierVest  # only those ids
```

New Meshy exports go through the same tool: drop the OBJ/texture into the `source` folder the `MANIFEST` entry names
(the first run keeps a converted copy under `assets/meshes/<Id>/<Id>_Source.obj`), then re-run it and
`python3 -I tools/make_codec_fixtures.py` (the codec specs checksum the real data modules). Figures must face +Z in the
export (the tool rotates them 180 degrees) and stand on their feet; the hip split is automatic.

## Import guide (optional: uploaded ids)

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
