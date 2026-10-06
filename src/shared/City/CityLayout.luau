--!nonstrict
-- CityLayout: authored city data for Delivery Dash City (pure tables, no Instances).
-- Coordinates are studs: X east, Z south, Y up, ground y = 0. Positions are {x=, y=?, z=} (never Vector3).
-- The helper locals below only exist to keep the authored data compact; the module returns a plain table.
-- Validate offline with `python3 tools/validate_layout.py`; render with `python3 tools/render_map.py`.

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function xz(flat)
	local points = {}
	for i = 1, #flat, 2 do
		points[#points + 1] = { x = flat[i], z = flat[i + 1] }
	end
	return points
end

local function xyz(flat)
	local points = {}
	for i = 1, #flat, 3 do
		points[#points + 1] = { x = flat[i], y = flat[i + 1], z = flat[i + 2] }
	end
	return points
end

local roads = {}
local function road(id, name, kind, width, points, sidewalk)
	roads[#roads + 1] = { id = id, name = name, kind = kind, width = width, points = points, sidewalk = sidewalk ~= false, oneWay = false }
end

local buildings = {}
local function building(x, z, w, d, h, style, name, extra)
	local b = { x = x, z = z, w = w, d = d, h = h, rot = 0, style = style, name = name }
	if extra then
		for k, v in pairs(extra) do
			b[k] = v
		end
	end
	buildings[#buildings + 1] = b
	return #buildings
end

-- A row of `n` buildings along X between the outer limits x0..x1, centred on z with depth d.
local function rowX(z, d, x0, x1, n, gap, style, h, namePrefix, extra)
	local indices = {}
	local w = (x1 - x0 - gap * (n - 1)) / n
	for i = 0, n - 1 do
		local cx = x0 + w / 2 + i * (w + gap)
		indices[#indices + 1] = building(cx, z, w, d, h, style, namePrefix .. " " .. (i + 1), extra)
	end
	return indices
end

-- A row of `n` buildings along Z between z0..z1, centred on x with width w (building extent along X).
local function rowZ(x, w, z0, z1, n, gap, style, h, namePrefix, extra)
	local indices = {}
	local d = (z1 - z0 - gap * (n - 1)) / n
	for i = 0, n - 1 do
		local cz = z0 + d / 2 + i * (d + gap)
		indices[#indices + 1] = building(x, cz, w, d, h, style, namePrefix .. " " .. (i + 1), extra)
	end
	return indices
end

-- Door/arrival helper. side = "N" | "S" | "E" | "W" (the face the door is on, i.e. the direction it faces).
-- kerb = distance from the door to the arrival point (the arrival sits on the kerb nearest the door).
local SIDE_DIR = { N = { x = 0, z = -1 }, S = { x = 0, z = 1 }, E = { x = 1, z = 0 }, W = { x = -1, z = 0 } }
local function facade(index, side, kerb)
	local b = buildings[index]
	local dir = SIDE_DIR[side]
	local door = { x = b.x + dir.x * (b.w / 2), z = b.z + dir.z * (b.d / 2) }
	local arrival = { x = door.x + dir.x * kerb, z = door.z + dir.z * kerb }
	return door, { x = dir.x, z = dir.z }, arrival
end

local destinations = {}
local function destination(id, address, neighborhood, kind, index, side, kerb, accepts)
	local door, facing, arrival = facade(index, side, kerb)
	destinations[#destinations + 1] = {
		id = id,
		address = address,
		neighborhood = neighborhood,
		kind = kind,
		door = door,
		facing = facing,
		arrivalPoint = arrival,
		accepts = accepts,
		buildingIndex = index,
		building = buildings[index],
	}
end

local HOUSE_COLORS = {
	{ r = 0.93, g = 0.89, b = 0.78 },
	{ r = 0.80, g = 0.86, b = 0.92 },
	{ r = 0.88, g = 0.80, b = 0.72 },
	{ r = 0.82, g = 0.90, b = 0.80 },
	{ r = 0.95, g = 0.84, b = 0.82 },
}
local houseCounter = 0
local function house(x, z, w, d, name, baseY)
	houseCounter += 1
	local color = HOUSE_COLORS[(houseCounter % #HOUSE_COLORS) + 1]
	return building(x, z, w or 26, d or 20, 12 + (houseCounter % 3) * 2, "House", name, { color = color, baseY = baseY or 0 })
end

-- Height of Hillcrest Road at x (piecewise linear along its polyline).
local HILL = { { 370, 0 }, { 410, 4 }, { 450, 6 }, { 490, 4 }, { 530, 0 }, { 620, 0 } }
local function hillY(x)
	for i = 1, #HILL - 1 do
		local a, b = HILL[i], HILL[i + 1]
		if x >= a[1] and x <= b[1] then
			local t = (x - a[1]) / (b[1] - a[1])
			return a[2] + (b[2] - a[2]) * t
		end
	end
	return 0
end

-------------------------------------------------------------------------------
-- Roads
-------------------------------------------------------------------------------

-- Plaza ring (chamfered square, centre line 80 studs from the plaza centre; inner kerb at 70, outer at 90).
road("PlazaRing", "Plaza Ring", "Road", 20, xz({
	-60, -80, 0, -80, 60, -80, 80, -60, 80, 0, 80, 60, 60, 80, 0, 80, -60, 80, -80, 60, -80, 0, -80, -60, -60, -80,
}))

-- Downtown arteries (Road, width 20, mask 7)
road("BeaconAvenue", "Beacon Avenue", "Road", 20, xz({ -460, 0, -380, 0, -300, 0, -225, 0, -150, 0, -80, 0 }))
road("NorthgateRoad", "Northgate Road", "Road", 20, xz({ -460, -360, -380, -360, -300, -360, -150, -360, 0, -360, 115, -360 }))
road("FoundryRoad", "Foundry Road", "Road", 20, xz({ -460, -200, -380, -200, -300, -200, -225, -200, -150, -200, 0, -200, 115, -200 }))
road("UnionStreet", "Union Street", "Road", 20, xz({ -460, 160, -380, 160, -300, 160, -225, 160, -150, 160, 0, 160, 115, 160 }))
road("WestgateRoad", "Westgate Road", "Road", 20, xz({ -460, -360, -460, -280, -460, -200, -460, -120, -460, 0, -460, 60, -460, 160 }))
road("StationRoad", "Station Road", "Road", 20, xz({ -300, -360, -300, -280, -300, -200, -300, -120, -300, -60, -300, 0, -300, 60, -300, 110, -300, 160 }))
road("TowerRoad", "Tower Road", "Road", 20, xz({ -150, -360, -150, -280, -150, -200, -150, -120, -150, -60, -150, 0, -150, 60, -150, 110, -150, 160 }))
road("PlazaNorthRoad", "Plaza North Road", "Road", 20, xz({ 0, -360, 0, -280, 0, -200, 0, -140, 0, -80 }))
road("PlazaSouthRoad", "Plaza South Road", "Road", 20, xz({ 0, 80, 0, 160 }))

-- Downtown side streets (Street, width 14, mask 3: bicycle + scooter)
road("MillStreet", "Mill Street", "Street", 14, xz({ -460, -280, -380, -280, -300, -280, -150, -280, 0, -280, 115, -280 }))
road("LanternStreet", "Lantern Street", "Street", 14, xz({ -460, -120, -380, -120, -300, -120, -225, -120, -150, -120 }))
road("SliceStreet", "Slice Street", "Street", 14, xz({ -460, 60, -380, 60, -300, 60, -225, 60, -150, 60, -80, 60 }))
road("BakerStreet", "Baker Street", "Street", 14, xz({ -380, -360, -380, -280, -380, -200, -380, -120, -380, 0, -380, 60 }))
road("PrintStreet", "Print Street", "Street", 14, xz({ -225, -200, -225, -120, -225, -60, -225, 0, -225, 60 }))
road("QuayStreetNorth", "Quay Street North", "Street", 14, xz({ 115, -360, 115, -280, 115, -200, 115, -140 }))
road("QuayStreet", "Quay Street", "Street", 14, xz({ 80, 0, 115, 0, 115, 60, 115, 120, 115, 160 }))

-- Downtown alleys (Alley, width 8, mask 1: bicycle only)
road("TowerAlley", "Tower Alley", "Alley", 8, xz({ -300, -60, -225, -60, -150, -60, -80, -60 }), false)
road("LanternAlley", "Lantern Alley", "Alley", 8, xz({ -225, 60, -225, 110, -225, 160 }), false)
road("FishmarketAlley", "Fishmarket Alley", "Alley", 8, xz({ 0, -140, 115, -140 }), false)
road("PrintersAlley", "Printers Alley", "Alley", 8, xz({ -380, 60, -380, 160 }), false)
road("QuayAlley", "Quay Alley", "Alley", 8, xz({ 80, 60, 115, 60 }), false)
road("CobblerAlley", "Cobbler Alley", "Alley", 8, xz({ -300, 110, -225, 110, -150, 110 }), false)

-- Canal crossings
road("CanalRampWest", "Canal Bridge (west ramp)", "Ramp", 20, xyz({ 80, 0, -60, 150, 8, -60 }))
road("CanalBridge", "Canal Bridge", "Bridge", 20, xyz({ 150, 8, -60, 220, 8, -60 }))
road("CanalRampEast", "Canal Bridge (east ramp)", "Ramp", 20, xyz({ 220, 8, -60, 290, 0, -60 }))
road("BikeBridge", "Quay Bike Bridge", "BikeBridge", 6, xyz({ 115, 0, 120, 150, 6, 120, 220, 6, 120, 260, 0, 120, 290, 0, 120 }), false)

-- Residential "Maple Hill" (Road, width 18, mask 7)
road("CanalSideDrive", "Canal Side Drive", "Road", 18, xz({ 290, -340, 290, -200, 290, -60, 290, 100, 290, 120, 290, 180 }))
road("ParkWestRoad", "Park West Road", "Road", 18, xz({ 370, -340, 370, -200, 370, -60, 370, 20, 370, 100, 370, 180 }))
road("ParkEastRoad", "Park East Road", "Road", 18, xz({ 530, -340, 530, -200, 530, -60, 530, 20, 530, 100, 530, 180 }))
road("OrchardRoad", "Orchard Road", "Road", 18, xz({ 620, -340, 620, -200, 620, -60, 620, 100, 620, 180 }))
road("NorthMapleRoad", "North Maple Road", "Road", 18, xz({ 290, -340, 370, -340, 530, -340, 620, -340 }))
road("FreshLane", "Fresh Lane", "Road", 18, xz({ 290, -200, 370, -200 }))
road("HillcrestRoad", "Hillcrest Road", "Road", 18, xyz({ 370, 0, -200, 410, 4, -200, 450, 6, -200, 490, 4, -200, 530, 0, -200, 620, 0, -200 }))
road("BridgeRoad", "Bridge Road", "Road", 18, xz({ 290, -60, 370, -60, 450, -60, 530, -60, 620, -60 }))
road("ParkSouthRoad", "Park South Road", "Road", 18, xz({ 290, 100, 370, 100, 450, 100, 530, 100, 620, 100 }))
road("MapleRow", "Maple Row", "Road", 18, xz({ 290, 180, 370, 180, 440, 180, 530, 180, 620, 180 }))

-- Maple Park paths (BikePath, width 6, mask 1)
road("ParkCrossEW", "Maple Park Walk (east-west)", "BikePath", 6, xz({ 370, 20, 450, 20, 530, 20 }), false)
road("ParkCrossNS", "Maple Park Walk (north-south)", "BikePath", 6, xz({ 450, -60, 450, 20, 450, 100 }), false)
road("ParkDiagonal", "Maple Park Diagonal", "BikePath", 6, xz({ 370, 100, 450, 20, 530, -60 }), false)

-- Greenbelt / rail crossings (Road, width 20, mask 7)
road("RailCrossingWest", "Station Road Crossing", "Road", 20, xz({ -300, 160, -300, 300 }))
road("RailCrossingCentral", "Plaza South Crossing", "Road", 20, xz({ 0, 160, 0, 300 }))
road("RailCrossingEast", "Maple Crossing", "Road", 20, xz({ 440, 180, 440, 300 }))

-- Industrial "Dockside" (Industrial, width 28, mask 7)
road("WharfRoad", "Wharf Road", "Industrial", 28, xz({ -440, 300, -300, 300, -150, 300, 0, 300, 150, 300, 300, 300, 440, 300, 600, 300 }), false)
road("ContainerWay", "Container Way", "Industrial", 28, xz({ -440, 460, -300, 460, -150, 460, 0, 460, 150, 460, 300, 460, 440, 460, 600, 460 }), false)
road("DockRoadA", "Dock Road A", "Industrial", 28, xz({ -440, 300, -440, 460 }), false)
road("DockRoadB", "Dock Road B", "Industrial", 28, xz({ -300, 300, -300, 460 }), false)
road("DockRoadC", "Dock Road C", "Industrial", 28, xz({ -150, 300, -150, 460 }), false)
road("DockRoadD", "Dock Road D", "Industrial", 28, xz({ 0, 300, 0, 460 }), false)
road("DockRoadE", "Dock Road E", "Industrial", 28, xz({ 150, 300, 150, 460 }), false)
road("DockRoadF", "Dock Road F", "Industrial", 28, xz({ 300, 300, 300, 460 }), false)
road("DockRoadG", "Dock Road G", "Industrial", 28, xz({ 440, 300, 440, 460 }), false)
road("DockRoadH", "Dock Road H", "Industrial", 28, xz({ 600, 300, 600, 460 }), false)

-------------------------------------------------------------------------------
-- Buildings: Downtown
-- Column x-ranges (4 studs beyond each kerb): A -446..-391, B -369..-314, C -286..-236, D -214..-164,
-- CD -286..-164 (north of Foundry Road), E -136..-94, EF -136..-14, G 14..104.
-------------------------------------------------------------------------------

local APT, SHOP, OFFICE = "Apartment", "Shop", "Office"

-- Band 1: Northgate Road -> Mill Street (z -346..-291)
rowX(-334, 24, -446, -391, 1, 0, APT, 30, "Northgate Apartments")
rowX(-303, 24, -446, -391, 1, 0, SHOP, 14, "Mill Street Shops")
rowX(-334, 24, -369, -314, 1, 0, OFFICE, 36, "Baker Offices")
rowX(-303, 24, -369, -314, 1, 0, SHOP, 12, "Mill Corner")
rowX(-334, 24, -286, -164, 3, 6, APT, 28, "Station Court")
rowX(-303, 24, -286, -164, 3, 6, SHOP, 14, "Mill Parade")
rowX(-334, 24, -136, -14, 3, 6, OFFICE, 42, "Northgate Offices")
rowX(-303, 24, -136, -14, 3, 6, APT, 26, "Mill Lofts")
rowX(-334, 24, 14, 104, 2, 6, APT, 24, "Quay Apartments")
rowX(-303, 24, 14, 104, 2, 6, SHOP, 12, "Quay Shops")

-- Band 2: Mill Street -> Foundry Road (z -269..-214)
rowX(-257, 24, -446, -391, 1, 0, SHOP, 14, "Westgate Stores")
rowX(-226, 24, -446, -391, 1, 0, APT, 28, "Foundry Flats")
rowX(-257, 24, -369, -314, 1, 0, APT, 32, "Baker Heights")
rowX(-226, 24, -369, -314, 1, 0, OFFICE, 30, "Foundry Offices")
rowX(-257, 24, -286, -164, 3, 6, APT, 26, "Mill Court")
rowX(-226, 24, -286, -164, 3, 6, SHOP, 12, "Foundry Shops")
rowX(-257, 24, -136, -14, 3, 6, OFFICE, 38, "Mill Offices")
rowX(-226, 24, -136, -14, 3, 6, APT, 30, "Foundry Lofts")
rowX(-257, 24, 14, 104, 2, 6, SHOP, 14, "Quay Market Hall")
rowX(-226, 24, 14, 104, 2, 6, APT, 26, "Quay Court")

-- Band 3: Foundry Road -> Lantern Street (z -186..-131), columns A-D
rowX(-174, 24, -446, -391, 1, 0, APT, 26, "Lantern Flats")
rowX(-143, 24, -446, -391, 1, 0, SHOP, 12, "Lantern Stores")
rowX(-174, 24, -369, -314, 1, 0, SHOP, 14, "Foundry Parade")
rowX(-143, 24, -369, -314, 1, 0, APT, 30, "Lantern Court")
rowX(-174, 24, -286, -236, 1, 0, APT, 28, "Print Lofts")
rowX(-143, 24, -286, -236, 1, 0, SHOP, 14, "Lantern Shops")
rowX(-174, 24, -214, -164, 1, 0, OFFICE, 32, "Print Offices")
rowX(-143, 24, -214, -164, 1, 0, APT, 26, "Lantern Terrace")
-- Column EF north of the plaza: Beacon Tower block and the ring-facing row
building(-110, -163, 36, 46, 34, OFFICE, "Beacon Plaza Offices")
local beaconTower = building(-110, -112, 36, 36, 120, "Tower", "Beacon Tower")
rowX(-174, 24, -88, -14, 2, 6, APT, 28, "Foundry Court")
local ringNorthRow = rowX(-109, 30, -88, -14, 2, 6, APT, 32, "Plaza North Apartments")
-- Column G: between Plaza North Road and the quay
rowX(-174, 24, 14, 104, 2, 6, SHOP, 14, "Foundry Quay Shops")
local fishRow = rowX(-116, 28, 14, 146, 3, 6, APT, 24, "Fishmarket Lofts")

-- Band 4: Lantern Street -> Tower Alley / Beacon Avenue (z -109..-81 / -42..-14)
rowX(-95, 28, -446, -391, 1, 0, APT, 26, "Westgate Court")
rowX(-28, 28, -446, -391, 1, 0, SHOP, 14, "Beacon West Stores")
rowX(-95, 28, -369, -314, 1, 0, OFFICE, 30, "Lantern Offices")
rowX(-28, 28, -369, -314, 1, 0, APT, 28, "Beacon Court")
rowX(-61, 24, -446, -391, 1, 0, OFFICE, 22, "Westgate Studios")
rowX(-61, 24, -369, -314, 1, 0, SHOP, 12, "Baker Arcade")
rowX(-95, 28, -286, -236, 1, 0, SHOP, 12, "Lantern Row")
local lanternD = rowX(-95, 28, -214, -164, 1, 0, APT, 30, "Lantern Mews")

-- Band 5: Tower Alley -> Beacon Avenue (z -42..-14)
local beaconC = rowX(-28, 28, -286, -236, 1, 0, APT, 32, "Beacon Heights")
local beaconShops = rowX(-28, 28, -214, -164, 1, 0, SHOP, 14, "Beacon Shops")
building(-115, -28, 42, 28, 30, APT, "Beacon Lofts")

-- Band 6: Beacon Avenue -> Slice Street (z 23..49)
rowX(36, 26, -446, -391, 1, 0, APT, 24, "Slice West Flats")
rowX(36, 26, -369, -314, 1, 0, SHOP, 12, "Slice Street Stores")
rowX(36, 26, -286, -236, 1, 0, OFFICE, 28, "Slice Street Offices")
local sliceD = rowX(36, 26, -214, -164, 1, 0, APT, 26, "Slice Street Flats")
local pizzaBuilding = building(-115, 36, 36, 26, 14, "Pizza", "Slice Street Pizza", { color = { r = 0.85, g = 0.25, b = 0.2 } })

-- Band 7: Slice Street -> Union Street (z 71..99 facing Slice, 118..146 facing Union)
rowX(85, 28, -446, -391, 1, 0, SHOP, 12, "Printers Row")
rowX(132, 28, -446, -391, 1, 0, APT, 28, "Union West Flats")
rowX(85, 28, -369, -314, 1, 0, APT, 30, "Slice Court")
rowX(132, 28, -369, -314, 1, 0, OFFICE, 26, "Union Offices")
local sliceC = rowX(85, 28, -286, -236, 1, 0, APT, 26, "Cobbler Court")
rowX(132, 28, -286, -236, 1, 0, SHOP, 12, "Union Stores")
rowX(85, 28, -214, -164, 1, 0, SHOP, 14, "Lantern Alley Shops")
rowX(132, 28, -214, -164, 1, 0, APT, 30, "Union Court")
rowX(85, 28, -136, -94, 1, 0, APT, 26, "Plaza West Flats")
rowX(132, 28, -136, -94, 1, 0, SHOP, 12, "Tower Road Stores")
rowX(108, 24, -88, -14, 2, 6, APT, 28, "Plaza South Apartments")
local unionParade = rowX(135, 22, -88, -14, 2, 6, SHOP, 12, "Union Parade")

-- Plaza pavilions
local cafeBuilding = building(-46, 10, 22, 24, 10, "Cafe", "Bean & Bun Cafe", { color = { r = 0.55, g = 0.38, b = 0.25 } })
building(0, 40, 28, 12, 9, "Hub", "Dash Hub Kiosk")

-------------------------------------------------------------------------------
-- Buildings: Residential "Maple Hill" (houses w26 d20, setback 8 from the kerb)
-- Lots: R-A x 299..361 (Canal Side Drive -> Park West Road), R-B x 379..521, R-C x 539..611, canal bank x 253..273
-------------------------------------------------------------------------------

local marketBuilding = building(330, -245, 56, 36, 14, "Market", "Fresh Lane Market", { color = { r = 0.35, g = 0.6, b = 0.35 } })

-- R-A (west side faces Canal Side Drive at x=317, east side faces Park West Road at x=343)
house(317, -305, nil, nil, "2 Canal Side Drive")
house(343, -305, nil, nil, "1 Park West Road")
for i, cz in ipairs({ -165, -130, -95 }) do
	house(317, cz, nil, nil, (4 + i * 2) .. " Canal Side Drive")
	house(343, cz, nil, nil, (3 + i * 2) .. " Park West Road")
end
local parkSideHouse
for i, cz in ipairs({ -25, 15, 60 }) do
	house(317, cz, nil, nil, (12 + i * 2) .. " Canal Side Drive")
	local idx = house(343, cz, nil, nil, (11 + i * 2) .. " Park West Road")
	if i == 2 then
		parkSideHouse = idx
	end
end
house(317, 140, nil, nil, "20 Canal Side Drive")
house(343, 140, nil, nil, "19 Park West Road")

-- R-B north: North Maple Road row and the Hillcrest hill rows
for i, cx in ipairs({ 405, 450, 495 }) do
	house(cx, -313, nil, nil, (i * 2) .. " North Maple Road")
end
local hillNorth, hillSouth = {}, {}
for i, cx in ipairs({ 405, 450, 495 }) do
	hillNorth[i] = house(cx, -227, nil, nil, (1 + (i - 1) * 2) .. " Hillcrest Road", hillY(cx))
	hillSouth[i] = house(cx, -173, nil, nil, (2 + (i - 1) * 2) .. " Hillcrest Road", hillY(cx))
end
local bridgeRow = {}
for i, cx in ipairs({ 405, 450, 495 }) do
	bridgeRow[i] = house(cx, -87, nil, nil, (17 + (i - 1) * 2) .. " Bridge Road")
end
-- R-B south: Park South Road row and Maple Row row
for i, cx in ipairs({ 405, 450, 495 }) do
	house(cx, 127, nil, nil, (i * 2) .. " Park South Road")
end
local mapleRowHouses = {}
for i, cx in ipairs({ 405, 450, 495 }) do
	mapleRowHouses[i] = house(cx, 153, nil, nil, (12 + i * 2) .. " Maple Row")
end

-- R-C (west side faces Park East Road at x=557, east side faces Orchard Road at x=593)
for i, cz in ipairs({ -305, -260 }) do
	house(557, cz, nil, nil, (i * 2) .. " Park East Road")
	house(593, cz, nil, nil, (29 + i * 2) .. " Orchard Road")
end
local orchardHouse
for i, cz in ipairs({ -160, -100 }) do
	house(557, cz, nil, nil, (6 + i * 2) .. " Park East Road")
	local idx = house(593, cz, nil, nil, (37 + i * 2) .. " Orchard Road")
	if i == 2 then
		orchardHouse = idx
	end
end
for i, cz in ipairs({ -15, 55 }) do
	house(557, cz, nil, nil, (12 + i * 2) .. " Park East Road")
	house(593, cz, nil, nil, (43 + i * 2) .. " Orchard Road")
end
house(557, 140, nil, nil, "18 Park East Road")
house(593, 140, nil, nil, "49 Orchard Road")

-- Canal bank (faces Canal Side Drive from the west, x=263)
local canalBankHouse
for i, cz in ipairs({ -300, -250, -165, -120, -20, 30, 80, 150 }) do
	local idx = house(263, cz, nil, nil, (i * 2) .. " Canal Bank")
	if cz == 30 then
		canalBankHouse = idx
	end
end

-------------------------------------------------------------------------------
-- Buildings: Industrial "Dockside" (warehouses, margin 6 from the kerb)
-- Columns: IA -420..-320, IB -280..-170, IC -130..-20, ID 20..130, IE 170..280, IF 320..420, IG 460..580
-- Rows: Wharf Road row z 320..366 (c 343), Container Way row z 394..440 (c 417)
-------------------------------------------------------------------------------

local WH = "Warehouse"
local grey = { r = 0.62, g = 0.64, b = 0.66 }
local rust = { r = 0.6, g = 0.42, b = 0.3 }
local navy = { r = 0.35, g = 0.42, b = 0.55 }

local wharfA = building(-370, 343, 90, 46, 22, WH, "Dockside Freight (Bay 1)", { color = navy })
building(-370, 417, 90, 46, 20, WH, "Dockside Freight (Bay 2)", { color = navy })
local crateBuilding = building(-205, 380, 60, 60, 18, WH, "Crate & Co. Supply", { color = rust })
building(-258, 343, 36, 30, 12, OFFICE, "Dockside Gatehouse")
building(-75, 343, 100, 46, 22, WH, "Harbour Cold Store", { color = grey })
building(-75, 417, 100, 46, 24, WH, "Harbour Cold Store Annex", { color = grey })
local wharfD = building(75, 343, 100, 46, 24, WH, "Canal Logistics (Bay 3)", { color = navy })
local containerD = building(75, 417, 100, 46, 20, WH, "Canal Logistics (Bay 4)", { color = navy })
building(225, 343, 100, 46, 22, WH, "Pier Six Storage", { color = grey })
local containerE = building(225, 417, 100, 46, 22, WH, "Pier Six Distribution (Bay 5)", { color = rust })
building(370, 343, 90, 46, 26, WH, "Maple Crossing Depot", { color = grey })
building(370, 417, 90, 46, 20, WH, "Eastside Parcel Hub", { color = rust })
building(520, 343, 110, 46, 22, WH, "Orchard Freight", { color = navy })
building(520, 417, 110, 46, 18, WH, "Dockside Workshops", { color = grey })
-- Rail sheds along the greenbelt (north of Wharf Road)
building(-370, 267, 60, 26, 10, WH, "Rail Shed West", { color = rust })
building(-75, 267, 60, 26, 10, WH, "Rail Shed Central", { color = rust })
building(225, 267, 60, 26, 10, WH, "Rail Shed East", { color = rust })
building(520, 267, 60, 26, 10, WH, "Rail Shed Orchard", { color = rust })

-------------------------------------------------------------------------------
-- Businesses
-------------------------------------------------------------------------------

local businesses = {}
local function business(id, name, index, door, facing, pickupPoint, arrivalPoint, neighborhood)
	businesses[#businesses + 1] = {
		id = id,
		name = name,
		buildingIndex = index,
		building = buildings[index],
		door = door,
		facing = facing,
		pickupPoint = pickupPoint,
		arrivalPoint = arrivalPoint,
		neighborhood = neighborhood,
	}
end

business("SliceStreetPizza", "Slice Street Pizza", pizzaBuilding,
	{ x = -115, z = 49 }, { x = 0, z = 1 }, { x = -115, z = 51 }, { x = -115, z = 52 }, "Downtown")
business("BeanAndBunCafe", "Bean & Bun Cafe", cafeBuilding,
	{ x = -57, z = 10 }, { x = -1, z = 0 }, { x = -62, z = 10 }, { x = -68, z = 10 }, "Downtown")
business("FreshLaneMarket", "Fresh Lane Market", marketBuilding,
	{ x = 330, z = -227 }, { x = 0, z = 1 }, { x = 330, z = -220 }, { x = 330, z = -210 }, "Residential")
business("CrateAndCoSupply", "Crate & Co. Supply", crateBuilding,
	{ x = -175, z = 380 }, { x = 1, z = 0 }, { x = -168, z = 380 }, { x = -163, z = 380 }, "Industrial")

-------------------------------------------------------------------------------
-- Destinations (18): 7 Downtown, 7 Residential, 4 Industrial
-------------------------------------------------------------------------------

local SMALL_MED = { Small = true, Medium = true, Large = false }
local ALL_SIZES = { Small = true, Medium = true, Large = true }

destination("D01", "Beacon Shops, 28 Beacon Avenue", "Downtown", "Shop", beaconShops[1], "S", 4, SMALL_MED)
destination("D02", "Slice Street Flats, 9 Slice Street", "Downtown", "Apartment", sliceD[1], "S", 4, SMALL_MED)
destination("D03", "Cobbler Court, 21 Slice Street", "Downtown", "Apartment", sliceC[1], "N", 4, SMALL_MED)
destination("D04", "Fishmarket Lofts, 3 Fishmarket Alley", "Downtown", "Apartment", fishRow[1], "N", 6, SMALL_MED)
destination("D05", "Beacon Heights, 40 Beacon Avenue", "Downtown", "Apartment", beaconC[1], "S", 4, SMALL_MED)
destination("D06", "Union Parade, 4 Union Street", "Downtown", "Shop", unionParade[2], "S", 4, SMALL_MED)
destination("D07", "Lantern Mews, 15 Lantern Street", "Downtown", "Shop", lanternD[1], "N", 4, SMALL_MED)

destination("D08", "14 Maple Row", "Residential", "House", mapleRowHouses[1], "S", 8, ALL_SIZES)
destination("D09", "3 Hillcrest Road", "Residential", "House", hillNorth[2], "S", 8, ALL_SIZES)
destination("D10", "6 Hillcrest Road", "Residential", "House", hillSouth[3], "N", 8, ALL_SIZES)
destination("D11", "12 Canal Bank", "Residential", "House", canalBankHouse, "E", 8, ALL_SIZES)
destination("D12", "41 Orchard Road", "Residential", "House", orchardHouse, "E", 8, ALL_SIZES)
destination("D13", "15 Park West Road", "Residential", "House", parkSideHouse, "E", 8, ALL_SIZES)
destination("D14", "17 Bridge Road", "Residential", "House", bridgeRow[1], "S", 8, ALL_SIZES)

destination("D15", "Canal Logistics, Bay 3 Wharf Road", "Industrial", "LoadingBay", wharfD, "N", 7, ALL_SIZES)
destination("D16", "Pier Six Distribution, Bay 5 Container Way", "Industrial", "LoadingBay", containerE, "S", 7, ALL_SIZES)
destination("D17", "Dockside Freight, Bay 1 Wharf Road", "Industrial", "LoadingBay", wharfA, "N", 7, ALL_SIZES)
destination("D18", "Canal Logistics, Bay 4 Container Way", "Industrial", "LoadingBay", containerD, "S", 7, ALL_SIZES)

-------------------------------------------------------------------------------
-- Depot plots
-------------------------------------------------------------------------------

local depotPlots = {}
local function plot(id, x, z, w, d, facingZ)
	local parking = {
		{ x = x - 15, z = z + 8 * facingZ * -1, facing = { x = 0, z = facingZ } },
		{ x = x + 15, z = z + 8 * facingZ * -1, facing = { x = 0, z = facingZ } },
	}
	depotPlots[#depotPlots + 1] = { id = id, x = x, z = z, w = w, d = d, facing = { x = 0, z = facingZ }, parking = parking }
end
plot("P1", -370, 503, 60, 50, -1)
plot("P2", -225, 503, 60, 50, -1)
plot("P3", 225, 503, 60, 50, -1)
plot("P4", 370, 503, 60, 50, -1)
plot("P5", 520, 503, 60, 50, -1)
plot("P6", -75, 503, 60, 50, -1)
plot("P7", 36, 124, 44, 48, 1)
plot("P8", 84, 124, 44, 48, 1)

-------------------------------------------------------------------------------
-- Pedestrian loops (client-side NPC walkers)
-------------------------------------------------------------------------------

local pedestrianPaths = {
	{ id = "PlazaWalk", loop = true, points = xz({ -64, -20, -45, -45, 0, -64, 45, -45, 64, 0, 45, 45, 0, 64, -45, 45, -64, 30 }) },
	{ id = "SliceStreetWalk", loop = true, points = xz({ -288, 14, -162, 14, -162, 50, -288, 50 }) },
	{ id = "TowerBlockWalk", loop = true, points = xz({ -138, -186, -92, -186, -92, -66, -138, -66 }) },
	{ id = "QuayWalk", loop = true, points = xz({ 126, 4, 146, 4, 146, 110, 126, 110 }) },
	{ id = "ParkWalk", loop = true, points = xz({ 382, -48, 518, -48, 518, 88, 382, 88 }) },
	{ id = "MarketWalk", loop = true, points = xz({ 301, -329, 359, -329, 359, -211, 301, -211 }) },
	{ id = "CanalSideWalk", loop = true, points = xz({ 301, -189, 359, -189, 359, -71, 301, -71 }) },
	{ id = "CrateYardWalk", loop = true, points = xz({ -284, 316, -166, 316, -166, 444, -284, 444 }) },
}

-------------------------------------------------------------------------------
-- Parked vehicles (sidewalk-side strip of the road, never on arrival pads or route nodes)
-- rot: yaw in degrees, 0 = facing north (-Z), 90 = facing east (+X)
-------------------------------------------------------------------------------

local CAR_COLORS = {
	{ r = 0.8, g = 0.2, b = 0.2 }, { r = 0.2, g = 0.35, b = 0.75 }, { r = 0.9, g = 0.9, b = 0.9 },
	{ r = 0.15, g = 0.15, b = 0.18 }, { r = 0.95, g = 0.75, b = 0.2 }, { r = 0.3, g = 0.6, b = 0.4 },
}
local parkedVehicles = {}
local function parked(x, z, rot, kind)
	local n = #parkedVehicles + 1
	parkedVehicles[n] = { x = x, z = z, rot = rot, color = CAR_COLORS[(n % #CAR_COLORS) + 1], kind = kind or "Car" }
end
parked(-200, 7, 90)
parked(-340, -7, 90)
parked(-143, -250, 0)
parked(-307, 100, 0)
parked(-100, 153, 90)
parked(-350, -193, 90)
parked(-250, -353, 90)
parked(-330, 55, 90)
parked(120, 30, 0)
parked(7, -300, 0)
parked(-420, -60, 0)
parked(296, -150, 0)
parked(600, -54, 90)
parked(420, 106, 90)
parked(330, 174, 90)
parked(614, -250, 0)
parked(560, -194, 90)
parked(-200, 290, 90, "Truck")
parked(340, 450, 90, "Truck")
parked(160, 400, 0, "Truck")
parked(590, 380, 0, "Truck")
parked(520, 290, 90, "Truck")
parked(-430, 380, 0, "Truck")

-------------------------------------------------------------------------------
-- Props
-------------------------------------------------------------------------------

local props = {}
local function prop(kind, x, z, rot)
	props[#props + 1] = { type = kind, x = x, z = z, rot = rot or 0 }
end

-- true when (x,z) is at least `extra` studs outside every road's kerb
local function clearOfRoads(x, z, extra)
	for _, r in ipairs(roads) do
		local pts = r.points
		local limit = r.width / 2 + extra
		for i = 1, #pts - 1 do
			local ax, az, bx, bz = pts[i].x, pts[i].z, pts[i + 1].x, pts[i + 1].z
			local abx, abz = bx - ax, bz - az
			local len2 = abx * abx + abz * abz
			local t = 0
			if len2 > 0 then
				t = math.clamp(((x - ax) * abx + (z - az) * abz) / len2, 0, 1)
			end
			local dx, dz = x - (ax + abx * t), z - (az + abz * t)
			if math.sqrt(dx * dx + dz * dz) < limit then
				return false
			end
		end
	end
	return true
end

-- Lamps along a straight road segment, `offset` studs from the centre line on side (+1/-1), every `spacing` studs.
local function lampsAlong(x0, z0, x1, z1, spacing, offset, side)
	local dx, dz = x1 - x0, z1 - z0
	local len = math.sqrt(dx * dx + dz * dz)
	local ux, uz = dx / len, dz / len
	local nx, nz = -uz * side, ux * side
	local d = spacing / 2
	while d < len do
		local x, z = x0 + ux * d + nx * offset, z0 + uz * d + nz * offset
		if clearOfRoads(x, z, 1.5) then
			prop("Lamp", x, z)
		end
		d += spacing
	end
end

-- Downtown arteries (lamps on both sides every 60) and streets (one side every 60)
lampsAlong(-460, 0, -80, 0, 60, 12, 1)
lampsAlong(-460, 0, -80, 0, 60, 12, -1)
lampsAlong(-460, -360, 115, -360, 60, 12, 1)
lampsAlong(-460, -200, 115, -200, 60, 12, -1)
lampsAlong(-460, 160, 115, 160, 60, 12, -1)
lampsAlong(-460, -360, -460, 160, 60, 12, -1)
lampsAlong(-300, -360, -300, 160, 60, 12, 1)
lampsAlong(-150, -360, -150, 160, 60, 12, -1)
lampsAlong(0, -360, 0, -80, 60, 12, 1)
lampsAlong(0, 80, 0, 300, 60, 12, 1)
lampsAlong(-460, -280, 115, -280, 90, 9, 1)
lampsAlong(-460, 60, -80, 60, 90, 9, 1)
lampsAlong(-460, -120, -150, -120, 90, 9, -1)
lampsAlong(115, -360, 115, -140, 90, 9, 1)
lampsAlong(115, 0, 115, 160, 90, 9, 1)
-- Plaza ring lamps (outer kerb) and bridge approach lamps
for _, p in ipairs({ { -30, -92 }, { 30, -92 }, { 92, -30 }, { 92, 30 }, { -30, 92 }, { 30, 92 }, { -92, -30 }, { -92, 30 } }) do
	prop("Lamp", p[1], p[2])
end
-- (ramps only: a lamp mid-span would hang beside the deck over the canal)
lampsAlong(80, -60, 150, -60, 70, 12, 1)
lampsAlong(80, -60, 150, -60, 70, 12, -1)
lampsAlong(220, -60, 290, -60, 70, 12, 1)
lampsAlong(220, -60, 290, -60, 70, 12, -1)
-- Residential (one side, every 75)
lampsAlong(290, -340, 290, 180, 75, 11, 1)
lampsAlong(370, -340, 370, 180, 75, 11, -1)
lampsAlong(530, -340, 530, 180, 75, 11, 1)
lampsAlong(620, -340, 620, 180, 75, 11, -1)
lampsAlong(290, -340, 620, -340, 75, 11, 1)
lampsAlong(290, -200, 620, -200, 75, 11, -1)
lampsAlong(290, -60, 620, -60, 75, 11, 1)
lampsAlong(290, 100, 620, 100, 75, 11, -1)
lampsAlong(290, 180, 620, 180, 75, 11, 1)
-- Industrial (one side, every 100)
lampsAlong(-440, 300, 600, 300, 100, 16, -1)
lampsAlong(-440, 460, 600, 460, 100, 16, 1)
lampsAlong(-300, 160, -300, 300, 70, 12, 1)
lampsAlong(440, 180, 440, 300, 70, 12, 1)

-- Plaza furniture
for _, p in ipairs({ { -50, 0 }, { 50, 0 }, { -35, -35 }, { 35, -35 }, { 0, -50 }, { 35, 35 }, { -35, 35 } }) do
	prop("Planter", p[1], p[2])
end
for _, p in ipairs({ { -20, -40 }, { 20, -40 }, { -40, -20 }, { 40, -20 }, { 40, 20 }, { -20, 30 } }) do
	prop("Bench", p[1], p[2], 0)
end
prop("Sign", -30, 66, 0)
prop("Sign", -138, -4, 90)
prop("Sign", 92, -74, 0)
-- Hydrants at downtown corners (sidewalk side)
for _, p in ipairs({
	{ -288, 14 }, { -162, -14 }, { -162, 70 }, { -288, -190 }, { -14, -190 }, { -138, -350 }, { -370, 14 }, { -448, -190 },
	{ 14, 150 }, { -162, 150 }, { -14, -290 }, { 104, -190 }, { -288, -290 }, { -448, 70 },
}) do
	prop("Hydrant", p[1], p[2])
end
-- Alley clutter
for _, p in ipairs({ { -270, -66 }, { -190, -66 }, { -120, -54 }, { -231, 90 }, { -219, 135 }, { -386, 130 }, { 40, -146 }, { 90, -134 }, { -260, 116 } }) do
	prop("Dumpster", p[1], p[2])
end
for _, p in ipairs({ { -250, -54 }, { -205, -54 }, { -219, 80 }, { -374, 100 }, { 70, -146 }, { -200, 104 } }) do
	prop("Crate", p[1], p[2])
end
-- Quay promenade benches and trees (between the ring and the canal)
for _, p in ipairs({ { 134, -90 }, { 134, -80 }, { 134, 40 }, { 134, 80 }, { 100, -30 }, { 130, -30 } }) do
	prop("Bench", p[1], p[2], 90)
end
for _, p in ipairs({ { 140, -100 }, { 140, -20 }, { 140, 20 }, { 140, 60 }, { 140, 100 }, { 140, 140 }, { 100, -40 } }) do
	prop("Tree", p[1], p[2])
end
-- Bridge cones
for _, p in ipairs({ { 88, -72 }, { 88, -48 }, { 282, -72 }, { 282, -48 } }) do
	prop("Cone", p[1], p[2])
end

-- Maple Park trees (skip the diagonal path x + z = 470 and the cross paths)
for _, x in ipairs({ 395, 420, 480, 505 }) do
	for _, z in ipairs({ -35, -5, 45, 75 }) do
		local diag = math.abs(x + z - 470) / math.sqrt(2)
		if diag > 8 and math.abs(x - 450) > 8 and math.abs(z - 20) > 8 then
			prop("Tree", x, z)
		end
	end
end
for _, p in ipairs({ { 386, -44 }, { 514, -44 }, { 386, 84 }, { 514, 84 }, { 450, -40 }, { 450, 80 }, { 390, 20 }, { 510, 20 } }) do
	prop("Tree", p[1], p[2])
end
for _, p in ipairs({ { 440, 10 }, { 460, 30 }, { 420, -30 }, { 480, 70 }, { 386, 20 }, { 514, 20 } }) do
	prop("Bench", p[1], p[2], 0)
end
-- Residential street trees (between kerb and houses, every 45 studs, skipping junctions)
local function treesAlong(x0, z0, x1, z1, spacing, offset, side)
	local dx, dz = x1 - x0, z1 - z0
	local len = math.sqrt(dx * dx + dz * dz)
	local ux, uz = dx / len, dz / len
	local nx, nz = -uz * side, ux * side
	local d = spacing
	while d < len - spacing / 2 do
		local x, z = x0 + ux * d + nx * offset, z0 + uz * d + nz * offset
		if clearOfRoads(x, z, 3) then
			prop("Tree", x, z)
		end
		d += spacing
	end
end
treesAlong(290, -340, 290, 180, 45, 13, -1)
treesAlong(370, -340, 370, 180, 45, 13, 1)
treesAlong(530, -340, 530, 180, 45, 13, -1)
treesAlong(620, -340, 620, 180, 45, 13, 1)
treesAlong(290, -340, 620, -340, 45, 13, -1)
treesAlong(290, 180, 620, 180, 45, 13, 1)
-- Backyard trees inside the residential blocks (between the house rows)
for _, p in ipairs({
	{ 330, -205 }, { 330, -150 }, { 330, -110 }, { 330, -5 }, { 330, 40 }, { 330, 150 },
	{ 400, -275 }, { 460, -270 }, { 510, -280 }, { 420, -130 }, { 480, -135 }, { 440, -120 },
	{ 575, -285 }, { 575, -230 }, { 575, -130 }, { 575, -60 }, { 575, 20 }, { 575, 100 }, { 575, 160 },
	{ 240, -290 }, { 240, -180 }, { 240, -10 }, { 240, 60 }, { 240, 160 }, { 410, 165 }, { 490, 115 },
}) do
	prop("Tree", p[1], p[2])
end
-- Greenbelt / rail strip trees and containers
for x = -430, 630, 60 do
	if math.abs(x + 300) > 20 and math.abs(x) > 20 and math.abs(x - 440) > 20 and (x < 145 or x > 225) then
		prop("Tree", x, 212)
	end
end
for x = -400, 600, 120 do
	if math.abs(x + 300) > 24 and math.abs(x) > 24 and math.abs(x - 440) > 24 and (x < 145 or x > 225) then
		prop("Container", x, 238, 90)
	end
end
-- Industrial yards (between the Wharf and Container rows) and dock clutter
for _, cx in ipairs({ -370, -75, 75, 225, 370, 520 }) do
	prop("Container", cx - 20, 380, 90)
	prop("Container", cx + 20, 380, 90)
	prop("Crate", cx, 372)
	prop("Dumpster", cx + 40, 388)
end
for _, p in ipairs({ { -260, 400 }, { -260, 412 }, { -250, 340 }, { -240, 360 } }) do
	prop("Crate", p[1], p[2])
end
for _, p in ipairs({ { -395, 540 }, { -405, 540 }, { 40, 540 }, { 55, 540 }, { 180, 550 }, { 300, 540 }, { 460, 540 }, { 580, 540 } }) do
	prop("Container", p[1], p[2], 0)
end
for _, p in ipairs({ { -140, 290 }, { 10, 310 }, { 300, 470 }, { 440, 290 }, { -300, 470 } }) do
	prop("Cone", p[1], p[2])
end
-- Residential benches and hydrants
for _, p in ipairs({ { 301, -100 }, { 359, 10 }, { 539, 60 }, { 611, -20 } }) do
	prop("Bench", p[1], p[2], 0)
end
for _, p in ipairs({ { 301, -192 }, { 301, 92 }, { 539, -192 }, { 611, 92 }, { 361, -52 } }) do
	prop("Hydrant", p[1], p[2])
end

-------------------------------------------------------------------------------
-- The layout table
-------------------------------------------------------------------------------

local CityLayout = {
	name = "Delivery Dash City",
	bounds = { minX = -560, maxX = 660, minZ = -460, maxZ = 600 },
	groundY = 0,
	killY = -60,

	neighborhoods = {
		{ id = "Downtown", name = "Downtown", center = { x = -180, z = -100 }, bounds = { minX = -480, maxX = 120, minZ = -380, maxZ = 160 }, accent = { r = 0.95, g = 0.55, b = 0.2 } },
		{ id = "Residential", name = "Maple Hill", center = { x = 450, z = -80 }, bounds = { minX = 240, maxX = 640, minZ = -380, maxZ = 200 }, accent = { r = 0.4, g = 0.75, b = 0.4 } },
		{ id = "Industrial", name = "Dockside", center = { x = 80, z = 420 }, bounds = { minX = -480, maxX = 640, minZ = 260, maxZ = 580 }, accent = { r = 0.4, g = 0.55, b = 0.8 } },
	},

	roads = roads,

	water = {
		{ x = 185, z = -110, w = 70, d = 700, surfaceY = -3, depth = 8 }, -- the canal, x 150..220, z -460..240
	},

	bridges = {
		{ roadId = "CanalBridge", fromIndex = 1, toIndex = 2 },
		{ roadId = "BikeBridge", fromIndex = 2, toIndex = 3 },
	},

	buildings = buildings,
	businesses = businesses,
	destinations = destinations,

	landmarks = {
		plaza = { x = 0, z = 0, r = 55 },
		tower = { x = -110, z = -112 },
		park = { x = 450, z = 20, w = 140, d = 140 },
		waterTower = { x = 100, z = 520 },
		hub = { x = 0, z = 50 },
	},

	hub = {
		spawn = { x = 0, z = 62, facing = { x = 0, z = -1 } },
		vehiclePads = {
			{ x = -30, z = 54, facing = { x = 0, z = -1 } },
			{ x = -10, z = 54, facing = { x = 0, z = -1 } },
			{ x = 10, z = 54, facing = { x = 0, z = -1 } },
			{ x = 30, z = 54, facing = { x = 0, z = -1 } },
		},
		kiosk = { x = 0, z = 40 },
	},

	depotPlots = depotPlots,
	pedestrianPaths = pedestrianPaths,
	parkedVehicles = parkedVehicles,
	props = props,

	bikeShortcuts = {
		{ roadId = "TowerAlley", hint = "Bikes only: Tower Alley cuts straight from the plaza to Station Road, skipping the Beacon Avenue loop." },
		{ roadId = "LanternAlley", hint = "Lantern Alley links Slice Street straight down to Union Street - no detour via Tower Road." },
		{ roadId = "BikeBridge", hint = "The Quay bike bridge is the short way over the canal; vans and scooters must use the Canal Bridge." },
	},
}

return CityLayout
