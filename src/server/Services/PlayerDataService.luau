--!nonstrict
-- PlayerDataService: loads, migrates, reconciles, session-locks, autosaves and replicates player profiles.
-- See docs/ARCHITECTURE.md sections 4 and 5.1. Everything persisted goes through UpdateAsync; a profile
-- that failed to load (or is locked by another live server) is used read-only and never written.

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Types = require(Shared.Types)
local Signal = require(Shared.Util.Signal)
local TableUtil = require(Shared.Util.TableUtil)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local CosmeticDefinitions = require(Shared.Definitions.CosmeticDefinitions)

type Profile = Types.Profile

local DATASTORE_NAME = "DDC_Profiles_v1"
local SCHEMA_VERSION = 1
local LOAD_BACKOFF = { 1, 2, 4 } -- seconds between load attempts (4 attempts total)
local SAVE_BACKOFF = { 1, 2, 4 }
local LOCK_RETRIES = 3 -- extra attempts when another server holds the session lock
local LOCK_RETRY_DELAY = 2 -- 3 retries over 6 seconds
local BIND_TO_CLOSE_TIMEOUT = 25
local REPLICATE_INTERVAL = 0.25 -- at most 4 ProfileUpdated per second per player
local WAIT_POLL = 0.1

local okJob, jobIdValue = pcall(function()
	return game.JobId
end)
local JOB_ID: string = if okJob and type(jobIdValue) == "string" then jobIdValue else ""

local PlayerDataService = {}

PlayerDataService.ProfileLoaded = Signal.new()
PlayerDataService.ProfileUnloading = Signal.new()

-------------------------------------------------------------------------------
-- Default profile and migrations
-------------------------------------------------------------------------------

local function buildDefaultProfile(): Profile
	local ownedCosmetics = {}
	for _, cosmeticId in pairs(CosmeticDefinitions.Defaults) do
		ownedCosmetics[cosmeticId] = true
	end
	return {
		schemaVersion = SCHEMA_VERSION,
		cash = EconomyConfig.startingCash,
		reputation = EconomyConfig.startingReputation,
		ownedVehicles = { Bicycle = true },
		equippedVehicle = "Bicycle",
		upgrades = {},
		depot = { owned = false, slotsUnlocked = 0, drivers = {} },
		cosmetics = { owned = ownedCosmetics, equipped = TableUtil.deepCopy(CosmeticDefinitions.Defaults) },
		tutorial = { completed = false, step = 0 },
		stats = {
			deliveries = 0,
			totalEarned = 0,
			bestTimes = {},
			distance = 0,
			contractsCompleted = 0,
			lateDeliveries = 0,
			milestonesGranted = {},
		},
		settings = {
			cameraSensitivity = 1,
			reducedMotion = false,
			autoRecenter = true,
			musicVolume = 0.6,
			sfxVolume = 0.8,
			showMinimap = true,
			invertCameraY = false,
		},
		lastSeen = 0,
	} :: any
end

PlayerDataService.DEFAULT_PROFILE = buildDefaultProfile()
PlayerDataService.SCHEMA_VERSION = SCHEMA_VERSION
PlayerDataService.DATASTORE_NAME = DATASTORE_NAME

-- Migrations[n] upgrades a profile stored with schemaVersion n to n + 1. They run in order until the
-- profile reaches SCHEMA_VERSION; reconcile() then fills any new fields with defaults.
local Migrations: { [number]: (Profile) -> () } = {
	[0] = function(profile)
		-- Unversioned / pre-release data: nothing to rename, reconcile adds the v1 fields.
		if type(profile.stats) ~= "table" then
			profile.stats = nil
		end
	end,
}

local function migrate(profile: any): any
	local version = tonumber(profile.schemaVersion) or 0
	while version < SCHEMA_VERSION do
		local step = Migrations[version]
		if step then
			step(profile)
		end
		version += 1
	end
	profile.schemaVersion = SCHEMA_VERSION
	return profile
end

-- Builds the in-memory profile from the raw stored value (or nil for a new player).
local function buildProfile(raw: any): Profile
	local profile: any = if type(raw) == "table" then TableUtil.deepCopy(raw) else {}
	profile.lock = nil
	profile = migrate(profile)
	TableUtil.reconcile(profile, PlayerDataService.DEFAULT_PROFILE)
	profile.schemaVersion = SCHEMA_VERSION
	return profile
end

-------------------------------------------------------------------------------
-- Session state
-------------------------------------------------------------------------------

type Session = {
	player: Player,
	key: string,
	profile: Profile?,
	loaded: boolean,
	dirty: boolean,
	saving: boolean,
	readOnly: boolean,
	replicateScheduled: boolean,
	lastReplicate: number,
	leaderstats: Folder?,
}

local ctx: any = nil
local sessions: { [Player]: Session } = {}
local store: any = nil
local closing = false
-- DataStore jobs (saves, and lock releases for a load whose player already left) that BindToClose
-- must wait for even when their session is no longer in `sessions` (a leave-save in flight).
local inflightJobs = 0

local function keyFor(player: Player): string
	return "u_" .. tostring(player.UserId)
end

local function getStore(): any
	if store then
		return store
	end
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(DATASTORE_NAME)
	end)
	if ok then
		store = result
	else
		warn("[PlayerDataService] GetDataStore failed:", result)
	end
	return store
end

local function notify(player: Player, text: string, kind: string, duration: number?)
	if not ctx or not ctx.remotes then
		return
	end
	pcall(function()
		ctx.remotes.getEvent("Notify"):FireClient(player, { text = text, kind = kind, duration = duration })
	end)
end

local function isSaveable(session: Session?): boolean
	return session ~= nil and session.loaded and session.profile ~= nil and not session.readOnly and not session.profile.__loadFailed
end

-------------------------------------------------------------------------------
-- Replication (coalesced) and leaderstats
-------------------------------------------------------------------------------

local function buildPublicProfile(profile: Profile): any
	local copy: any = TableUtil.deepCopy(profile)
	copy.lastSeen = nil
	copy.__loadFailed = nil
	return copy
end

local function ensureLeaderstats(session: Session)
	local player = session.player
	local folder = player:FindFirstChild("leaderstats")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "leaderstats"
		for _, name in ipairs({ "Cash", "Deliveries", "Rep" }) do
			local value = Instance.new("IntValue")
			value.Name = name
			value.Value = 0
			value.Parent = folder
		end
		folder.Parent = player
	end
	session.leaderstats = folder :: Folder
end

local function updateLeaderstats(session: Session)
	local profile = session.profile
	local folder = session.leaderstats
	if not profile or not folder then
		return
	end
	local cash = folder:FindFirstChild("Cash")
	local deliveries = folder:FindFirstChild("Deliveries")
	local rep = folder:FindFirstChild("Rep")
	if cash then
		(cash :: IntValue).Value = math.floor(profile.cash + 0.5)
	end
	if deliveries then
		(deliveries :: IntValue).Value = math.floor((profile.stats.deliveries or 0) + 0.5)
	end
	if rep then
		(rep :: IntValue).Value = math.floor(profile.reputation + 0.5)
	end
end

local function flushReplicate(session: Session)
	session.replicateScheduled = false
	if sessions[session.player] ~= session or not session.profile then
		return
	end
	session.lastReplicate = os.clock()
	if ctx and ctx.remotes then
		local public = buildPublicProfile(session.profile)
		pcall(function()
			ctx.remotes.getEvent("ProfileUpdated"):FireClient(session.player, public)
		end)
	end
end

local function scheduleReplicate(session: Session)
	if session.replicateScheduled then
		return
	end
	session.replicateScheduled = true
	local waitFor = (session.lastReplicate + REPLICATE_INTERVAL) - os.clock()
	if waitFor <= 0 then
		task.defer(flushReplicate, session)
	else
		task.delay(waitFor, flushReplicate, session)
	end
end

-------------------------------------------------------------------------------
-- Loading
-------------------------------------------------------------------------------

-- One UpdateAsync that reads the stored value and claims the session lock in the same write.
-- Returns "ok" (lock claimed, data), "locked" (another live server holds it, data) or "error".
local function attemptLoad(key: string): (string, any)
	local dataStore = getStore()
	if not dataStore then
		return "error", "DataStore unavailable"
	end
	local captured: any = nil
	local locked = false
	local ok, err = pcall(function()
		dataStore:UpdateAsync(key, function(stored)
			captured = stored
			if type(stored) == "table" and type(stored.lock) == "table" then
				local lock = stored.lock
				local age = os.time() - (tonumber(lock.t) or 0)
				if lock.jobId ~= JOB_ID and age < EconomyConfig.sessionLockTimeout then
					locked = true
					return nil -- abort the write, keep the other server's lock
				end
			end
			local data = if type(stored) == "table" then stored else {}
			data.lock = { jobId = JOB_ID, t = os.time() }
			return data
		end)
	end)
	if not ok then
		return "error", err
	end
	if locked then
		return "locked", captured
	end
	return "ok", captured
end

local function loadSession(session: Session)
	local player = session.player
	local errorAttempts = 0
	local lockAttempts = 0
	local status, raw = "error", nil
	while sessions[player] == session do
		status, raw = attemptLoad(session.key)
		if status == "ok" then
			break
		elseif status == "locked" then
			lockAttempts += 1
			if lockAttempts > LOCK_RETRIES then
				break
			end
			task.wait(LOCK_RETRY_DELAY)
		else
			errorAttempts += 1
			warn(string.format("[PlayerDataService] load attempt %d failed for %s: %s", errorAttempts, session.key, tostring(raw)))
			if errorAttempts >= EconomyConfig.loadRetries then
				break
			end
			task.wait(LOAD_BACKOFF[math.min(errorAttempts, #LOAD_BACKOFF)])
		end
	end
	if sessions[player] ~= session then
		-- The player left while we were loading; release the lock we may have claimed.
		if status == "ok" then
			inflightJobs += 1
			pcall(function()
				getStore():UpdateAsync(session.key, function(stored)
					if type(stored) == "table" and type(stored.lock) == "table" and stored.lock.jobId == JOB_ID then
						stored.lock = nil
						return stored
					end
					return nil
				end)
			end)
			inflightJobs -= 1
		end
		return
	end

	local profile: Profile
	if status == "ok" then
		profile = buildProfile(raw)
	elseif status == "locked" then
		profile = buildProfile(raw)
		profile.__loadFailed = true
		session.readOnly = true
		warn("[PlayerDataService] session locked elsewhere, read-only session for", session.key)
	else
		profile = buildProfile(nil)
		profile.__loadFailed = true
		session.readOnly = true
		warn("[PlayerDataService] load failed, read-only session for", session.key)
	end

	session.profile = profile
	session.loaded = true
	session.dirty = false
	ensureLeaderstats(session)
	updateLeaderstats(session)
	if profile.__loadFailed then
		notify(player, "Progress will not save this session. Please rejoin later.", "warning", 10)
	end
	PlayerDataService.ProfileLoaded:Fire(player, profile)
	scheduleReplicate(session)
end

-------------------------------------------------------------------------------
-- Saving
-------------------------------------------------------------------------------

-- Writes the profile through UpdateAsync with retries. releaseLock=true clears the session lock.
-- Returns true when the write succeeded (or nothing needed writing).
local function saveSession(session: Session, releaseLock: boolean): boolean
	if not isSaveable(session) then
		return false
	end
	-- Serialise saves per session.
	while session.saving do
		task.wait(WAIT_POLL)
	end
	if not isSaveable(session) then
		return false
	end
	if not session.dirty and not releaseLock then
		return true
	end
	session.saving = true
	inflightJobs += 1
	local wasDirty = session.dirty
	session.dirty = false

	local snapshot: any = TableUtil.deepCopy(session.profile)
	snapshot.__loadFailed = nil
	snapshot.lastSeen = os.time()
	snapshot.schemaVersion = SCHEMA_VERSION
	if releaseLock then
		snapshot.lock = nil
	else
		snapshot.lock = { jobId = JOB_ID, t = os.time() }
	end

	local success = false
	local dataStore = getStore()
	if dataStore then
		for attempt = 1, EconomyConfig.saveRetries do
			local ok, err = pcall(function()
				dataStore:UpdateAsync(session.key, function(stored)
					if type(stored) == "table" then
						-- Never write a profile older than the stored schema.
						if (tonumber(stored.schemaVersion) or 0) > snapshot.schemaVersion then
							return nil
						end
						-- Never clobber a session another live server has since claimed.
						local lock = stored.lock
						if type(lock) == "table" and lock.jobId ~= JOB_ID and (os.time() - (tonumber(lock.t) or 0)) < EconomyConfig.sessionLockTimeout then
							return nil
						end
					end
					return snapshot
				end)
			end)
			if ok then
				success = true
				break
			end
			warn(string.format("[PlayerDataService] save attempt %d failed for %s: %s", attempt, session.key, tostring(err)))
			if attempt < EconomyConfig.saveRetries then
				task.wait(SAVE_BACKOFF[math.min(attempt, #SAVE_BACKOFF)])
			end
		end
	end
	if not success and wasDirty then
		session.dirty = true
	end
	inflightJobs -= 1
	session.saving = false
	return success
end

-------------------------------------------------------------------------------
-- Player lifecycle
-------------------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	if sessions[player] then
		return
	end
	local session: Session = {
		player = player,
		key = keyFor(player),
		profile = nil,
		loaded = false,
		dirty = false,
		saving = false,
		readOnly = false,
		replicateScheduled = false,
		lastReplicate = -math.huge,
		leaderstats = nil,
	}
	sessions[player] = session
	task.spawn(loadSession, session)
end

local function onPlayerRemoving(player: Player)
	local session = sessions[player]
	if not session then
		return
	end
	if session.loaded and session.profile then
		PlayerDataService.ProfileUnloading:Fire(player, session.profile)
	end
	sessions[player] = nil
	if isSaveable(session) then
		task.spawn(function()
			-- isSaveable() checks sessions[] membership indirectly via the profile flags only,
			-- so a leaving player's final save still goes through.
			session.dirty = true
			saveSession(session, true)
		end)
	end
end

local function onClose()
	closing = true
	local pending = 0
	for _, session in pairs(sessions) do
		if isSaveable(session) then
			pending += 1
			task.spawn(function()
				session.dirty = true
				saveSession(session, true)
				pending -= 1
			end)
		end
	end
	-- Also wait for saves spawned by onPlayerRemoving (their sessions are already out of `sessions`)
	-- and for lock releases of loads whose player left, so the server never shuts down mid-write.
	local deadline = os.clock() + BIND_TO_CLOSE_TIMEOUT
	while (pending > 0 or inflightJobs > 0) and os.clock() < deadline do
		task.wait(WAIT_POLL)
	end
end

-------------------------------------------------------------------------------
-- Public API
-------------------------------------------------------------------------------

function PlayerDataService.Init(context)
	ctx = context
end

function PlayerDataService.Start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in ipairs(Players:GetPlayers()) do
		onPlayerAdded(player)
	end
	game:BindToClose(onClose)

	-- Autosave loop: only dirty, saveable sessions are written.
	task.spawn(function()
		while not closing do
			task.wait(EconomyConfig.autosaveInterval)
			if closing then
				break
			end
			for _, session in pairs(sessions) do
				if isSaveable(session) and session.dirty and not session.saving then
					task.spawn(saveSession, session, false)
				end
			end
		end
	end)
end

function PlayerDataService.GetProfile(player: Player): Profile?
	local session = sessions[player]
	if session and session.loaded then
		return session.profile
	end
	return nil
end

function PlayerDataService.WaitForProfile(player: Player, timeout: number?): Profile?
	local deadline = os.clock() + (timeout or 30)
	while os.clock() < deadline do
		local profile = PlayerDataService.GetProfile(player)
		if profile then
			return profile
		end
		if not sessions[player] and player.Parent == nil then
			return nil
		end
		task.wait(WAIT_POLL)
	end
	return PlayerDataService.GetProfile(player)
end

function PlayerDataService.IsSaveable(player: Player): boolean
	return isSaveable(sessions[player])
end

-- Runs the mutator against the profile, marks it dirty, mirrors leaderstats and replicates.
function PlayerDataService.Update(player: Player, mutator: (Profile) -> ()): boolean
	local session = sessions[player]
	if not session or not session.loaded or not session.profile then
		return false
	end
	local ok, err = pcall(mutator, session.profile)
	if not ok then
		warn("[PlayerDataService] Update mutator failed:", err)
	end
	session.dirty = true
	updateLeaderstats(session)
	scheduleReplicate(session)
	return ok
end

local function normalizeAmount(amount: any): number?
	if not TableUtil.isFiniteNumber(amount) then
		return nil
	end
	local rounded = math.floor(amount + 0.5)
	if rounded < 0 then
		return nil
	end
	return rounded
end

function PlayerDataService.AddCash(player: Player, amount: number, reason: string): boolean
	local rounded = normalizeAmount(amount)
	if rounded == nil then
		return false
	end
	return PlayerDataService.Update(player, function(profile)
		profile.cash = math.floor(profile.cash + rounded + 0.5)
	end)
end

-- Atomic check-and-deduct: the profile is only touched when it holds enough cash.
function PlayerDataService.TrySpendCash(player: Player, amount: number, reason: string): boolean
	local rounded = normalizeAmount(amount)
	if rounded == nil then
		return false
	end
	local profile = PlayerDataService.GetProfile(player)
	if not profile or profile.cash < rounded then
		return false
	end
	return PlayerDataService.Update(player, function(p)
		p.cash = math.floor(p.cash - rounded + 0.5)
	end)
end

function PlayerDataService.AddReputation(player: Player, amount: number, reason: string): boolean
	local rounded = normalizeAmount(amount)
	if rounded == nil then
		return false
	end
	return PlayerDataService.Update(player, function(profile)
		profile.reputation = math.floor(profile.reputation + rounded + 0.5)
	end)
end

function PlayerDataService.GetPublicProfile(player: Player): any?
	local profile = PlayerDataService.GetProfile(player)
	if not profile then
		return nil
	end
	return buildPublicProfile(profile)
end

-- Forces an immediate save (used by tests and admin tooling). Returns the save result.
function PlayerDataService.SaveNow(player: Player): boolean
	local session = sessions[player]
	if not session then
		return false
	end
	return saveSession(session, false)
end

return PlayerDataService
