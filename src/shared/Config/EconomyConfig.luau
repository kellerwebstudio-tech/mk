--!strict
-- Initial economy model. EVERY NUMBER HERE IS A STARTING POINT THAT REQUIRES PLAYTESTING.
-- See docs/DESIGN.md section 4 for the rationale and expected progression timing.

local EconomyConfig = {
	-- Starting state
	startingCash = 0,
	startingReputation = 0,

	-- Order board
	boardMin = 3, -- generator keeps at least this many Available orders
	boardMax = 6, -- and at most this many
	boardLifetime = 150, -- seconds an Available order stays on the board before it Expires
	generationInterval = 5, -- seconds between generator passes per player
	orderTickInterval = 1, -- seconds between lifecycle ticks (ready checks, expiry)

	-- Interaction distances (studs)
	pickupDistance = 18,
	deliveryDistance = 16,
	deliveryArrivalDistance = 20,
	mountDistance = 14,
	depotInteractDistance = 30,

	-- Capacity and batching
	multiOrderUnlockDeliveries = 3, -- deliveries required (after tutorial) before carrying several orders
	onFootCapacity = 1,

	-- Timing
	timeLimitMultiplier = 2.2, -- time limit = max(minTimeLimit, estimatedSeconds * multiplier)
	minTimeLimit = 90,
	lateCutoffMultiplier = 2.0, -- tip reaches zero at timeLimit * this
	estimatedSpeedForTiming = 24, -- studs/s used to estimate a delivery (bicycle, with turns)

	-- Delivery quality
	defaultTipFraction = 0.3, -- tipMax = basePay * fraction (business may override)
	sizeBonus = { Small = 0, Medium = 0.25, Large = 0.6 }, -- fraction of base pay added per size class

	-- Reputation
	tutorialCompletionBonus = 25,
	cancelCollectedPenalty = 2,
	contractBonusRep = 50,
	milestones = { -- deliveries -> rep bonus
		{ deliveries = 10, rep = 25 },
		{ deliveries = 50, rep = 75 },
		{ deliveries = 100, rep = 150 },
		{ deliveries = 250, rep = 300 },
	},

	-- Tutorial orders
	tutorialFirstPay = 45,
	tutorialSecondPay = 50,

	-- Anti-cheat tolerance
	speedTolerance = 1.8, -- allowed distance per second = maxSpeed * tolerance + slack
	speedSlack = 24,
	positionSampleInterval = 1,
	flagDuration = 4,

	-- Persistence
	autosaveInterval = 120,
	saveRetries = 3,
	loadRetries = 4,
	sessionLockTimeout = 120,

	-- Vehicle
	recoverCooldown = 3,
	mountRetryDelay = 0.2,

	-- Depot (see DepotDefinitions for per-category numbers)
	depotPrice = 12000,
	depotRepRequired = 1000,
}

return EconomyConfig
