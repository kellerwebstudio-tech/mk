--!strict
-- Vehicle definitions: masks, economy, handling tables and declarative visual specs.
-- Coordinates in visual specs are relative to the Chassis centre: +X right, +Y up, -Z forward.
-- The chassis centre sits `handling.rideHeight` studs above the ground while driving.
-- Colours are {r, g, b} (0-255) or a paint slot name ("Primary", "Accent", "Decal").
-- Materials/shapes are Enum names as strings so this module stays pure data.
-- rot = {x, y, z} in degrees is applied as CFrame.new(offset) * CFrame.Angles(rad(x), rad(y), rad(z)).
-- Cylinders have their axis along local X; a cylinder lying along the vehicle (Z) uses rot = {pitch, 90, 0}.

export type VisualPart = {
	name: string,
	shape: string, -- "Block" | "Cylinder" | "Ball" | "Wedge"
	size: { number }, -- {x, y, z}
	offset: { number }, -- {x, y, z}
	rot: { number }?, -- degrees {x, y, z}
	color: any, -- {r,g,b} or slot name
	material: string?,
	transparency: number?,
	reflectance: number?,
}

export type WheelSpec = {
	name: string,
	radius: number,
	width: number,
	offset: { number },
	steerable: boolean,
	color: { number }?,
}

export type Handling = {
	maxSpeed: number,
	reverseSpeed: number,
	acceleration: number,
	brakeDeceleration: number,
	coastDeceleration: number,
	turnRate: number, -- radians per second at turnFullSpeed
	turnFullSpeed: number, -- speed at which the full turn rate is reached
	minTurnFactor: number, -- turn rate factor when nearly stopped
	highSpeedTurnFactor: number, -- turn rate factor at maxSpeed
	steerResponse: number, -- smoothing speed for steering input
	rideHeight: number,
	probeExtra: number, -- extra raycast length below ride height
	verticalGain: number, -- ride-height correction gain (1/s)
	maxClimbRate: number, -- max vertical correction speed
	maxFallSpeed: number,
	leanAngle: number, -- degrees of cosmetic body lean (two-wheelers)
	wheelSteerAngle: number, -- degrees of cosmetic front wheel steer
	blockedSpeedFraction: number,
	blockedTime: number,
	bumpSlowdown: number,
	maxSlopeDegrees: number,
	cameraDistance: number,
	cameraHeight: number,
	cameraLookAhead: number,
	fovSpeedBoost: number,
}

export type CargoLayout = {
	columns: number,
	rows: number,
	spacingX: number,
	spacingY: number,
	spacingZ: number,
}

-- Optional custom-mesh block (applies only while MeshAssets.hasBody(id); see Config/MeshAssets).
-- body.size/offset come from assets/meshes/<id>/meta.json (bounding box of the imported OBJ, in
-- studs, relative to the chassis centre). The offsets override the generated-part values because
-- the mesh's saddle / cargo rack / cab sit elsewhere than the block build.
export type MeshWheelSpec = {
	name: string,
	radius: number,
	offset: { number },
	steerable: boolean,
}

export type MeshSpec = {
	body: { size: { number }, offset: { number } },
	seatOffset: { number }?,
	cargoOffset: { number }?,
	cargoLayout: CargoLayout?,
	chassisSize: { number }?,
	dismountOffset: { number }?,
	wheels: { MeshWheelSpec },
}

-- The placement values a builder/service needs, resolved for generated parts or for the mesh.
export type EffectiveLayout = {
	seatOffset: { number },
	cargoOffset: { number },
	cargoLayout: CargoLayout,
	chassisSize: { number },
	dismountOffset: { number },
}

export type VehicleDefinition = {
	id: string,
	displayName: string,
	description: string,
	mask: number,
	price: number,
	repRequired: number,
	baseCapacity: number,
	handling: Handling,
	chassisSize: { number },
	seatOffset: { number },
	cargoOffset: { number },
	cargoLayout: CargoLayout,
	dismountOffset: { number },
	engineSound: string?,
	defaultColors: { Primary: { number }, Accent: { number }, Decal: { number } },
	visual: { parts: { VisualPart }, wheels: { WheelSpec } },
	mesh: MeshSpec?,
	order: number,
}

local VehicleDefinitions = {}

VehicleDefinitions.Mask = {
	Bicycle = 1,
	Scooter = 2,
	Van = 4,
	Foot = 7,
}

VehicleDefinitions.RoadKindMask = {
	Road = 7,
	Street = 3,
	Alley = 1,
	BikePath = 1,
	Bridge = 7,
	BikeBridge = 1,
	Industrial = 7,
	Ramp = 7,
}

VehicleDefinitions.Order = { "Bicycle", "Scooter", "Van" }

local BLACK = { 35, 35, 38 }
local DARK = { 60, 60, 66 }
local METAL = { 170, 172, 180 }
local GLASS = { 150, 200, 230 }
local RUBBER = { 28, 28, 30 }

VehicleDefinitions.Vehicles = {
	Bicycle = {
		id = "Bicycle",
		displayName = "Courier Bicycle",
		description = "Light and agile. Fits every alley and bike path. Carries 1 order (more with baskets).",
		mask = 1,
		price = 0,
		repRequired = 0,
		baseCapacity = 1,
		order = 1,
		handling = {
			maxSpeed = 38,
			reverseSpeed = 6,
			acceleration = 22,
			brakeDeceleration = 40,
			coastDeceleration = 10,
			turnRate = 2.6,
			turnFullSpeed = 10,
			minTurnFactor = 0.4,
			highSpeedTurnFactor = 0.6,
			steerResponse = 12,
			rideHeight = 1.5,
			probeExtra = 5,
			verticalGain = 10,
			maxClimbRate = 40,
			maxFallSpeed = 120,
			leanAngle = 14,
			wheelSteerAngle = 32,
			blockedSpeedFraction = 0.35,
			blockedTime = 0.3,
			bumpSlowdown = 0.5,
			maxSlopeDegrees = 42,
			cameraDistance = 13,
			cameraHeight = 5.5,
			cameraLookAhead = 7,
			fovSpeedBoost = 6,
		},
		chassisSize = { 1.4, 1.2, 5.6 },
		seatOffset = { 0, 1.55, 0.7 },
		cargoOffset = { 0, 1.35, 2.2 },
		cargoLayout = { columns = 1, rows = 3, spacingX = 0, spacingY = 0.85, spacingZ = 0 },
		dismountOffset = { -2.6, -1.5, 0 },
		engineSound = "BicycleChain",
		defaultColors = { Primary = { 226, 76, 60 }, Accent = { 240, 230, 200 }, Decal = { 255, 255, 255 } },
		visual = {
			parts = {
				{ name = "DownTube", shape = "Cylinder", size = { 2.3, 0.3, 0.3 }, offset = { 0, 0.35, -0.65 }, rot = { 29, 90, 0 }, color = "Primary", material = "SmoothPlastic" },
				{ name = "TopTube", shape = "Cylinder", size = { 2.3, 0.26, 0.26 }, offset = { 0, 1.05, -0.45 }, rot = { 2, 90, 0 }, color = "Primary", material = "SmoothPlastic" },
				{ name = "SeatTube", shape = "Block", size = { 0.25, 1.6, 0.25 }, offset = { 0, 0.55, 0.5 }, rot = { 15, 0, 0 }, color = "Primary", material = "SmoothPlastic" },
				{ name = "HeadTube", shape = "Block", size = { 0.3, 1.0, 0.3 }, offset = { 0, 0.95, -1.72 }, rot = { 18, 0, 0 }, color = "Primary", material = "SmoothPlastic" },
				{ name = "Fork", shape = "Block", size = { 0.25, 1.4, 0.25 }, offset = { 0, 0.05, -1.95 }, rot = { 18, 0, 0 }, color = "Accent", material = "SmoothPlastic" },
				{ name = "Handlebar", shape = "Cylinder", size = { 1.7, 0.18, 0.18 }, offset = { 0, 1.6, -1.62 }, color = DARK, material = "Metal" },
				{ name = "GripLeft", shape = "Cylinder", size = { 0.4, 0.24, 0.24 }, offset = { -0.75, 1.6, -1.62 }, color = BLACK, material = "Rubber" },
				{ name = "GripRight", shape = "Cylinder", size = { 0.4, 0.24, 0.24 }, offset = { 0.75, 1.6, -1.62 }, color = BLACK, material = "Rubber" },
				{ name = "SeatPost", shape = "Block", size = { 0.15, 0.6, 0.15 }, offset = { 0, 1.2, 0.68 }, color = METAL, material = "Metal" },
				{ name = "Saddle", shape = "Block", size = { 0.7, 0.2, 1.1 }, offset = { 0, 1.45, 0.75 }, color = BLACK, material = "Fabric" },
				{ name = "Chainstay", shape = "Block", size = { 0.2, 0.2, 1.9 }, offset = { 0, -0.3, 1.1 }, color = "Primary", material = "SmoothPlastic" },
				{ name = "SeatStay", shape = "Block", size = { 0.2, 0.2, 2.1 }, offset = { 0, 0.4, 1.35 }, rot = { 51, 0, 0 }, color = "Primary", material = "SmoothPlastic" },
				{ name = "Crank", shape = "Block", size = { 0.9, 0.35, 0.35 }, offset = { 0, -0.2, 0.3 }, color = DARK, material = "Metal" },
				{ name = "PedalLeft", shape = "Block", size = { 0.5, 0.1, 0.35 }, offset = { -0.65, -0.2, 0.55 }, color = BLACK, material = "SmoothPlastic" },
				{ name = "PedalRight", shape = "Block", size = { 0.5, 0.1, 0.35 }, offset = { 0.65, -0.2, 0.05 }, color = BLACK, material = "SmoothPlastic" },
				{ name = "Basket", shape = "Block", size = { 1.4, 0.9, 1.0 }, offset = { 0, 1.45, -2.45 }, color = "Accent", material = "Fabric" },
				{ name = "RearRack", shape = "Block", size = { 1.0, 0.1, 1.6 }, offset = { 0, 0.9, 2.2 }, color = DARK, material = "Metal" },
				{ name = "RearRackLegL", shape = "Block", size = { 0.1, 1.2, 0.1 }, offset = { -0.45, 0.3, 2.3 }, color = DARK, material = "Metal" },
				{ name = "RearRackLegR", shape = "Block", size = { 0.1, 1.2, 0.1 }, offset = { 0.45, 0.3, 2.3 }, color = DARK, material = "Metal" },
				{ name = "Bell", shape = "Ball", size = { 0.3, 0.3, 0.3 }, offset = { -0.4, 1.75, -1.62 }, color = METAL, material = "Metal" },
			},
			wheels = {
				{ name = "FrontWheel", radius = 1.1, width = 0.3, offset = { 0, -0.4, -2.0 }, steerable = true, color = RUBBER },
				{ name = "RearWheel", radius = 1.1, width = 0.3, offset = { 0, -0.4, 2.0 }, steerable = false, color = RUBBER },
			},
		},
		-- Imported Meshy bicycle (assets/meshes/Bicycle). Used only while MeshAssets.hasBody("Bicycle").
		mesh = {
			body = { size = { 2.682, 3.647, 6.2 }, offset = { 0, 0.323, 0 } },
			seatOffset = { 0, 1.6, 0.5 },
			cargoOffset = { 0, 2.45, 2.3 },
			cargoLayout = { columns = 1, rows = 2, spacingX = 0, spacingY = 0.85, spacingZ = 0 },
			wheels = {}, -- baked into the body mesh for now
		},
	},

	Scooter = {
		id = "Scooter",
		displayName = "City Scooter",
		description = "Faster with a top box. Uses roads and streets, but alleys and bike paths are off limits. Carries 3 orders.",
		mask = 2,
		price = 1500,
		repRequired = 150,
		baseCapacity = 3,
		order = 2,
		handling = {
			maxSpeed = 55,
			reverseSpeed = 8,
			acceleration = 26,
			brakeDeceleration = 46,
			coastDeceleration = 8,
			turnRate = 2.1,
			turnFullSpeed = 14,
			minTurnFactor = 0.35,
			highSpeedTurnFactor = 0.5,
			steerResponse = 9,
			rideHeight = 1.5,
			probeExtra = 5,
			verticalGain = 10,
			maxClimbRate = 40,
			maxFallSpeed = 120,
			leanAngle = 10,
			wheelSteerAngle = 26,
			blockedSpeedFraction = 0.35,
			blockedTime = 0.3,
			bumpSlowdown = 0.5,
			maxSlopeDegrees = 40,
			cameraDistance = 14,
			cameraHeight = 6,
			cameraLookAhead = 8,
			fovSpeedBoost = 8,
		},
		chassisSize = { 2.0, 1.4, 6.0 },
		seatOffset = { 0, 1.45, 0.6 },
		cargoOffset = { 0, 2.3, 2.6 },
		cargoLayout = { columns = 1, rows = 3, spacingX = 0, spacingY = 0.85, spacingZ = 0 },
		dismountOffset = { -2.8, -1.5, 0 },
		engineSound = "ScooterEngine",
		defaultColors = { Primary = { 64, 160, 220 }, Accent = { 245, 245, 240 }, Decal = { 255, 255, 255 } },
		visual = {
			parts = {
				{ name = "Floorboard", shape = "Block", size = { 1.6, 0.25, 2.2 }, offset = { 0, -0.55, 0.2 }, color = "Primary", material = "SmoothPlastic" },
				{ name = "FrontShield", shape = "Block", size = { 1.7, 2.2, 0.4 }, offset = { 0, 0.75, -1.9 }, rot = { 12, 0, 0 }, color = "Primary", material = "SmoothPlastic" },
				{ name = "FrontFender", shape = "Block", size = { 1.0, 0.6, 1.6 }, offset = { 0, 0.3, -2.4 }, color = "Accent", material = "SmoothPlastic" },
				{ name = "Handlebar", shape = "Cylinder", size = { 1.9, 0.2, 0.2 }, offset = { 0, 2.15, -1.75 }, color = DARK, material = "Metal" },
				{ name = "GripLeft", shape = "Cylinder", size = { 0.45, 0.28, 0.28 }, offset = { -0.85, 2.15, -1.75 }, color = BLACK, material = "Rubber" },
				{ name = "GripRight", shape = "Cylinder", size = { 0.45, 0.28, 0.28 }, offset = { 0.85, 2.15, -1.75 }, color = BLACK, material = "Rubber" },
				{ name = "Headlight", shape = "Block", size = { 0.7, 0.5, 0.3 }, offset = { 0, 1.7, -2.12 }, color = { 255, 240, 170 }, material = "Neon" },
				{ name = "SeatBase", shape = "Block", size = { 1.4, 0.8, 2.6 }, offset = { 0, 0.6, 1.0 }, color = "Primary", material = "SmoothPlastic" },
				{ name = "Saddle", shape = "Block", size = { 1.3, 0.35, 2.3 }, offset = { 0, 1.2, 1.0 }, color = BLACK, material = "Fabric" },
				{ name = "RearBody", shape = "Block", size = { 1.5, 1.0, 1.4 }, offset = { 0, 0.3, 2.3 }, color = "Primary", material = "SmoothPlastic" },
				{ name = "TopBox", shape = "Block", size = { 1.6, 1.2, 1.4 }, offset = { 0, 1.7, 2.6 }, color = "Accent", material = "SmoothPlastic" },
				{ name = "Taillight", shape = "Block", size = { 0.8, 0.3, 0.1 }, offset = { 0, 0.5, 3.02 }, color = { 255, 60, 60 }, material = "Neon" },
				{ name = "Exhaust", shape = "Cylinder", size = { 1.2, 0.3, 0.3 }, offset = { 0.75, -0.2, 1.9 }, rot = { 0, 90, 0 }, color = METAL, material = "Metal" },
				{ name = "MirrorLeft", shape = "Block", size = { 0.35, 0.3, 0.08 }, offset = { -0.95, 2.6, -1.8 }, color = METAL, material = "Metal" },
				{ name = "MirrorRight", shape = "Block", size = { 0.35, 0.3, 0.08 }, offset = { 0.95, 2.6, -1.8 }, color = METAL, material = "Metal" },
				{ name = "Kickstand", shape = "Block", size = { 0.1, 0.8, 0.1 }, offset = { -0.7, -0.6, 0.6 }, rot = { 0, 0, 25 }, color = DARK, material = "Metal" },
			},
			wheels = {
				{ name = "FrontWheel", radius = 0.9, width = 0.5, offset = { 0, -0.6, -2.4 }, steerable = true, color = RUBBER },
				{ name = "RearWheel", radius = 0.9, width = 0.5, offset = { 0, -0.6, 2.2 }, steerable = false, color = RUBBER },
			},
		},
		-- Imported Meshy scooter (assets/meshes/Scooter). Used only while MeshAssets.hasBody("Scooter").
		mesh = {
			body = { size = { 2.985, 4.273, 6.4 }, offset = { 0, 0.637, 0 } },
			seatOffset = { 0, 0.95, 0.3 },
			cargoOffset = { 0, 2.8, 1.6 },
			cargoLayout = { columns = 1, rows = 2, spacingX = 0, spacingY = 0.85, spacingZ = 0 },
			wheels = {},
		},
	},

	Van = {
		id = "Van",
		displayName = "Delivery Van",
		description = "Big capacity for bulk orders and industrial routes. Slow in tight corners; roads only. Carries 8 orders.",
		mask = 4,
		price = 8000,
		repRequired = 600,
		baseCapacity = 8,
		order = 3,
		handling = {
			maxSpeed = 62,
			reverseSpeed = 14,
			acceleration = 18,
			brakeDeceleration = 36,
			coastDeceleration = 6,
			turnRate = 1.35,
			turnFullSpeed = 16,
			minTurnFactor = 0.3,
			highSpeedTurnFactor = 0.45,
			steerResponse = 6,
			rideHeight = 2.4,
			probeExtra = 6,
			verticalGain = 9,
			maxClimbRate = 40,
			maxFallSpeed = 120,
			leanAngle = 0,
			wheelSteerAngle = 30,
			blockedSpeedFraction = 0.35,
			blockedTime = 0.3,
			bumpSlowdown = 0.5,
			maxSlopeDegrees = 35,
			cameraDistance = 24,
			cameraHeight = 10,
			cameraLookAhead = 10,
			fovSpeedBoost = 8,
		},
		chassisSize = { 6.0, 3.0, 13.5 },
		-- Seat surface sits at y 0.65 (inside the opaque CabLower block) so a seated R15 rig
		-- fits under the cab roof (underside 4.9); keep roughly 4 studs between the two.
		seatOffset = { -1.5, 0.4, -4.3 },
		cargoOffset = { -0.8, -0.3, 4.0 },
		cargoLayout = { columns = 2, rows = 3, spacingX = 1.6, spacingY = 0.85, spacingZ = -1.3 },
		dismountOffset = { -5.0, -2.4, -4.3 },
		engineSound = "VanEngine",
		defaultColors = { Primary = { 245, 245, 245 }, Accent = { 226, 76, 60 }, Decal = { 40, 90, 180 } },
		visual = {
			parts = {
				{ name = "CargoBox", shape = "Block", size = { 6.0, 6.0, 7.6 }, offset = { 0, 2.3, 1.6 }, color = "Primary", material = "SmoothPlastic" },
				{ name = "CabLower", shape = "Block", size = { 6.0, 2.4, 4.6 }, offset = { 0, 0.5, -4.45 }, color = "Primary", material = "SmoothPlastic" },
				{ name = "CabRoof", shape = "Block", size = { 5.6, 0.4, 3.2 }, offset = { 0, 5.1, -3.6 }, color = "Primary", material = "SmoothPlastic" },
				{ name = "Windshield", shape = "Block", size = { 5.4, 3.4, 0.25 }, offset = { 0, 3.4, -5.3 }, rot = { 22, 0, 0 }, color = GLASS, material = "Glass", transparency = 0.35, reflectance = 0.2 },
				{ name = "CabBack", shape = "Block", size = { 5.6, 3.2, 0.3 }, offset = { 0, 3.6, -2.1 }, color = "Primary", material = "SmoothPlastic" },
				{ name = "SideWindowL", shape = "Block", size = { 0.2, 2.4, 2.2 }, offset = { -2.95, 3.5, -3.6 }, color = GLASS, material = "Glass", transparency = 0.35 },
				{ name = "SideWindowR", shape = "Block", size = { 0.2, 2.4, 2.2 }, offset = { 2.95, 3.5, -3.6 }, color = GLASS, material = "Glass", transparency = 0.35 },
				{ name = "PillarL", shape = "Block", size = { 0.3, 3.4, 0.3 }, offset = { -2.85, 3.4, -4.9 }, rot = { 22, 0, 0 }, color = "Primary", material = "SmoothPlastic" },
				{ name = "PillarR", shape = "Block", size = { 0.3, 3.4, 0.3 }, offset = { 2.85, 3.4, -4.9 }, rot = { 22, 0, 0 }, color = "Primary", material = "SmoothPlastic" },
				{ name = "Hood", shape = "Block", size = { 5.8, 0.5, 1.6 }, offset = { 0, 1.95, -5.95 }, color = "Primary", material = "SmoothPlastic" },
				{ name = "Grille", shape = "Block", size = { 3.0, 1.0, 0.2 }, offset = { 0, 0.6, -6.8 }, color = DARK, material = "Metal" },
				{ name = "HeadlightL", shape = "Block", size = { 1.0, 0.6, 0.2 }, offset = { -2.2, 0.9, -6.8 }, color = { 255, 240, 180 }, material = "Neon" },
				{ name = "HeadlightR", shape = "Block", size = { 1.0, 0.6, 0.2 }, offset = { 2.2, 0.9, -6.8 }, color = { 255, 240, 180 }, material = "Neon" },
				{ name = "BumperFront", shape = "Block", size = { 6.2, 0.6, 0.5 }, offset = { 0, -0.5, -6.75 }, color = DARK, material = "SmoothPlastic" },
				{ name = "BumperRear", shape = "Block", size = { 6.2, 0.6, 0.5 }, offset = { 0, -0.5, 5.55 }, color = DARK, material = "SmoothPlastic" },
				{ name = "TaillightL", shape = "Block", size = { 0.5, 1.4, 0.15 }, offset = { -2.6, 0.9, 5.45 }, color = { 255, 50, 50 }, material = "Neon" },
				{ name = "TaillightR", shape = "Block", size = { 0.5, 1.4, 0.15 }, offset = { 2.6, 0.9, 5.45 }, color = { 255, 50, 50 }, material = "Neon" },
				{ name = "RearDoorLine", shape = "Block", size = { 0.1, 5.4, 0.15 }, offset = { 0, 2.4, 5.45 }, color = DARK, material = "SmoothPlastic" },
				{ name = "DecalL", shape = "Block", size = { 0.08, 2.2, 5.2 }, offset = { -3.02, 2.7, 1.6 }, color = "Decal", material = "SmoothPlastic" },
				{ name = "DecalR", shape = "Block", size = { 0.08, 2.2, 5.2 }, offset = { 3.02, 2.7, 1.6 }, color = "Decal", material = "SmoothPlastic" },
				{ name = "StripeL", shape = "Block", size = { 0.08, 0.5, 11.5 }, offset = { -3.02, 0.6, -0.4 }, color = "Accent", material = "SmoothPlastic" },
				{ name = "StripeR", shape = "Block", size = { 0.08, 0.5, 11.5 }, offset = { 3.02, 0.6, -0.4 }, color = "Accent", material = "SmoothPlastic" },
				{ name = "MirrorL", shape = "Block", size = { 0.4, 0.7, 0.25 }, offset = { -3.3, 3.0, -5.2 }, color = DARK, material = "SmoothPlastic" },
				{ name = "MirrorR", shape = "Block", size = { 0.4, 0.7, 0.25 }, offset = { 3.3, 3.0, -5.2 }, color = DARK, material = "SmoothPlastic" },
				{ name = "RoofRack", shape = "Block", size = { 5.0, 0.2, 6.0 }, offset = { 0, 5.4, 1.6 }, color = DARK, material = "Metal" },
				{ name = "Underbody", shape = "Block", size = { 5.6, 0.8, 12.0 }, offset = { 0, -0.9, -0.5 }, color = BLACK, material = "SmoothPlastic" },
			},
			wheels = {
				{ name = "FrontWheelL", radius = 1.3, width = 0.9, offset = { -2.5, -1.1, -4.0 }, steerable = true, color = RUBBER },
				{ name = "FrontWheelR", radius = 1.3, width = 0.9, offset = { 2.5, -1.1, -4.0 }, steerable = true, color = RUBBER },
				{ name = "RearWheelL", radius = 1.3, width = 0.9, offset = { -2.5, -1.1, 3.6 }, steerable = false, color = RUBBER },
				{ name = "RearWheelR", radius = 1.3, width = 0.9, offset = { 2.5, -1.1, 3.6 }, steerable = false, color = RUBBER },
			},
		},
		-- Imported Meshy van (assets/meshes/Van). Used only while MeshAssets.hasBody("Van").
		mesh = {
			body = { size = { 7.228, 7.251, 13.5 }, offset = { 0, 1.226, 0 } },
			seatOffset = { -1.5, 0.4, -4.3 },
			cargoOffset = { -0.8, -0.3, 4.0 },
			cargoLayout = { columns = 2, rows = 3, spacingX = 1.6, spacingY = 0.85, spacingZ = -1.3 },
			chassisSize = { 6.6, 3.0, 13.5 },
			dismountOffset = { -5.2, -2.4, -4.3 },
			wheels = {},
		},
	},
} :: { [string]: VehicleDefinition }

function VehicleDefinitions.get(vehicleId: string): VehicleDefinition?
	return VehicleDefinitions.Vehicles[vehicleId]
end

-- Seat / cargo / chassis / dismount values for a vehicle: the generated-part numbers, or, when
-- `useMesh` is true and the definition has a `mesh` block, the mesh overrides merged over them.
-- Callers pass useMesh = MeshAssets.hasBody(id) (VehicleBuilder.usesMesh on the server, which also
-- knows about load failures) so every reader of these offsets agrees with the built model.
-- The result is a fresh table; the definition is never mutated.
function VehicleDefinitions.getEffective(vehicleId: string, useMesh: boolean): EffectiveLayout
	local def = VehicleDefinitions.Vehicles[vehicleId]
	assert(def ~= nil, "Unknown vehicle id " .. tostring(vehicleId))
	local mesh = if useMesh then def.mesh else nil
	local function pick<T>(override: T?, base: T): T
		if override ~= nil then
			return override :: T
		end
		return base
	end
	if mesh == nil then
		return {
			seatOffset = def.seatOffset,
			cargoOffset = def.cargoOffset,
			cargoLayout = def.cargoLayout,
			chassisSize = def.chassisSize,
			dismountOffset = def.dismountOffset,
		}
	end
	return {
		seatOffset = pick(mesh.seatOffset, def.seatOffset),
		cargoOffset = pick(mesh.cargoOffset, def.cargoOffset),
		cargoLayout = pick(mesh.cargoLayout, def.cargoLayout),
		chassisSize = pick(mesh.chassisSize, def.chassisSize),
		dismountOffset = pick(mesh.dismountOffset, def.dismountOffset),
	}
end

function VehicleDefinitions.maskAllows(edgeMask: number, vehicleMask: number): boolean
	return bit32.band(edgeMask, vehicleMask) ~= 0
end

function VehicleDefinitions.maskForVehicle(vehicleId: string?): number
	if vehicleId == nil then
		return VehicleDefinitions.Mask.Foot
	end
	local def = VehicleDefinitions.Vehicles[vehicleId]
	return if def then def.mask else VehicleDefinitions.Mask.Foot
end

return VehicleDefinitions
