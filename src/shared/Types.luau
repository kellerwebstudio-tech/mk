--!strict
-- Shared type definitions for Delivery Dash City.
-- This module exports types only; it has no runtime behaviour.

export type VehicleId = "Bicycle" | "Scooter" | "Van"
export type NeighborhoodId = "Downtown" | "Residential" | "Industrial"
export type ItemCategory = "Food" | "Pizza" | "Drinks" | "Grocery" | "Parcel"
export type SizeClass = "Small" | "Medium" | "Large"
export type PackageKey = "FoodBag" | "PizzaBox" | "DrinkCarrier" | "GroceryBag" | "Parcel"
export type OrderState = "Available" | "Accepted" | "ReadyForPickup" | "Collected" | "Delivered" | "Cancelled" | "Expired"
export type VehicleState = "Parked" | "Mounting" | "Driving" | "Dismounting" | "Recovering" | "Despawning"
export type RoadKind = "Road" | "Street" | "Alley" | "BikePath" | "Bridge" | "BikeBridge" | "Industrial" | "Ramp"
export type NotifyKind = "info" | "success" | "warning" | "error"

export type Order = {
	id: string,
	userId: number,
	businessId: string,
	destinationId: string,
	itemCategory: ItemCategory,
	size: SizeClass,
	sizeUnits: number,
	packageKey: PackageKey,
	itemLabel: string,
	basePay: number,
	tipMax: number,
	repReward: number,
	timeLimit: number?,
	availableUntil: number,
	prepTime: number,
	routeDistance: number,
	createdAt: number,
	acceptedAt: number?,
	readyAt: number?,
	collectedAt: number?,
	deliveredAt: number?,
	state: OrderState,
	contractId: string?,
	isTutorial: boolean?,
	rewardGranted: boolean?,
}

export type OrderSpec = {
	businessId: string,
	destinationId: string,
	size: SizeClass?,
	itemCategory: ItemCategory?,
	contractId: string?,
	isTutorial: boolean?,
	timeLimit: number?,
	basePayOverride: number?,
	prepTimeOverride: number?,
	availableFor: number?,
}

export type Payout = {
	base: number,
	tip: number,
	total: number,
	rep: number,
	lateSeconds: number,
	timelinessFactor: number,
	newRecord: boolean?,
	deliveryTime: number?,
}

export type CapacityInfo = {
	current: number,
	max: number,
	load: number,
	committed: number,
}

export type DriverAssignment = {
	id: string,
	category: string,
	startedAt: number,
	endsAt: number,
	revenue: number,
	cost: number,
	net: number,
	completed: boolean,
}

export type DriverSlot = {
	hired: boolean,
	name: string?,
	assignment: DriverAssignment?,
	pending: number,
}

export type DepotData = {
	owned: boolean,
	slotsUnlocked: number,
	drivers: { DriverSlot },
}

export type Settings = {
	cameraSensitivity: number,
	reducedMotion: boolean,
	autoRecenter: boolean,
	musicVolume: number,
	sfxVolume: number,
	showMinimap: boolean,
	invertCameraY: boolean,
}

export type Stats = {
	deliveries: number,
	totalEarned: number,
	bestTimes: { [string]: number },
	distance: number,
	contractsCompleted: number,
	lateDeliveries: number,
}

export type Profile = {
	schemaVersion: number,
	cash: number,
	reputation: number,
	ownedVehicles: { [string]: boolean },
	equippedVehicle: VehicleId,
	upgrades: { [string]: number },
	depot: DepotData,
	cosmetics: { owned: { [string]: boolean }, equipped: { [string]: string } },
	tutorial: { completed: boolean, step: number },
	stats: Stats,
	settings: Settings,
	lastSeen: number,
	__loadFailed: boolean?,
}

export type Result = {
	ok: boolean,
	error: string?,
	message: string?,
	[string]: any,
}

export type ContractJoined = {
	orderIds: { string },
	deadline: number,
	required: number,
	done: number,
}

export type ContractPublicState = {
	id: string?,
	neighborhood: NeighborhoodId?,
	opensAt: number?,
	closesAt: number?,
	graceEndsAt: number?,
	status: "Idle" | "Open" | "Grace",
	nextAt: number,
	offers: { Order }?,
	joined: ContractJoined?,
	eligible: boolean?,
	eligibilityReason: string?,
	serverTime: number,
}

export type DepotCategoryView = {
	id: string,
	name: string,
	unlocked: boolean,
	duration: number,
	revenue: number,
	cost: number,
	net: number,
	requirement: string?,
}

-- One plot in the "Depots in this server" list; `drivers` is the owner's hired-slot count.
export type DepotPublicPlot = {
	plotId: string,
	ownerName: string,
	ownerUserId: number,
	drivers: number,
}

export type DepotPublicState = {
	owned: boolean,
	plotId: string?,
	slotsUnlocked: number,
	drivers: { DriverSlot },
	pendingTotal: number,
	categories: { DepotCategoryView },
	serverTime: number,
	publicPlots: { DepotPublicPlot }?,
}

export type VehicleRecord = {
	model: Model,
	chassis: BasePart,
	seat: VehicleSeat,
	bodyRoot: BasePart,
	vehicleId: string,
	state: VehicleState,
	ownerUserId: number,
	lastSafePosition: Vector3,
	cargoAttachment: Attachment,
	spawnedAt: number,
	lastRecoverAt: number,
}

export type BusinessWorld = {
	model: Model,
	pickupPosition: Vector3,
	arrivalPosition: Vector3,
	doorPart: BasePart?,
}

export type DestinationWorld = {
	model: Model,
	doorPosition: Vector3,
	arrivalPosition: Vector3,
	doorPart: BasePart?,
	facing: Vector3,
}

export type DepotPlotWorld = {
	model: Model,
	origin: CFrame,
	parking: { CFrame },
	signPart: BasePart?,
	plotId: string,
}

export type World = {
	cityFolder: Folder,
	pickupFolder: Folder,
	destinationFolder: Folder,
	depotFolder: Folder,
	runtime: Folder,
	businesses: { [string]: BusinessWorld },
	destinations: { [string]: DestinationWorld },
	depotPlots: { [string]: DepotPlotWorld },
	hubSpawn: CFrame,
	vehiclePads: { CFrame },
}

export type ServerContext = {
	services: { [string]: any },
	remotes: any,
	layout: any,
	graph: any,
	world: World,
	isStudio: boolean,
}

export type ClientContext = {
	state: any,
	remotes: any,
	layout: any,
	graph: any,
	controllers: { [string]: any },
}

return {}
