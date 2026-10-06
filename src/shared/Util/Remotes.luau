--!strict
-- Remote names and accessors. The server creates all remotes at startup (createAll);
-- clients wait for them. Response convention: { ok = true, ... } or { ok = false, error = Code, message = text }.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = {}

Remotes.FOLDER_NAME = "Remotes"

Remotes.Functions = {
	"GetSnapshot",
	"AcceptOrder",
	"CancelOrder",
	"RequestPickup",
	"RequestDelivery",
	"SpawnVehicle",
	"DespawnVehicle",
	"MountVehicle",
	"DismountVehicle",
	"RecoverVehicle",
	"PurchaseVehicle",
	"EquipVehicle",
	"PurchaseUpgrade",
	"PurchaseCosmetic",
	"EquipCosmetic",
	"PurchaseDepot",
	"UnlockDriverSlot",
	"HireDriver",
	"AssignDriver",
	"CollectDepotEarnings",
	"JoinContract",
	"AdvanceTutorial",
	"SaveSettings",
}

Remotes.Events = {
	"ProfileUpdated",
	"OrdersUpdated",
	"OrderEvent",
	"VehicleStateChanged",
	"ContractUpdated",
	"DepotUpdated",
	"Notify",
	"TutorialUpdated",
	"WorldEvent",
	"ClientHeartbeat", -- client -> server telemetry only
}

local function getFolder(): Folder
	local folder = ReplicatedStorage:FindFirstChild(Remotes.FOLDER_NAME)
	if folder then
		return folder :: Folder
	end
	if RunService:IsServer() then
		local created = Instance.new("Folder")
		created.Name = Remotes.FOLDER_NAME
		created.Parent = ReplicatedStorage
		return created
	end
	return ReplicatedStorage:WaitForChild(Remotes.FOLDER_NAME) :: Folder
end

function Remotes.createAll()
	local folder = getFolder()
	for _, name in ipairs(Remotes.Functions) do
		if not folder:FindFirstChild(name) then
			local remote = Instance.new("RemoteFunction")
			remote.Name = name
			remote.Parent = folder
		end
	end
	for _, name in ipairs(Remotes.Events) do
		if not folder:FindFirstChild(name) then
			local remote = Instance.new("RemoteEvent")
			remote.Name = name
			remote.Parent = folder
		end
	end
end

function Remotes.getFunction(name: string): RemoteFunction
	local folder = getFolder()
	local remote = folder:FindFirstChild(name)
	if not remote then
		if RunService:IsServer() then
			Remotes.createAll()
			remote = folder:FindFirstChild(name)
		else
			remote = folder:WaitForChild(name, 30)
		end
	end
	assert(remote, "Unknown remote function " .. tostring(name))
	return remote :: RemoteFunction
end

function Remotes.getEvent(name: string): RemoteEvent
	local folder = getFolder()
	local remote = folder:FindFirstChild(name)
	if not remote then
		if RunService:IsServer() then
			Remotes.createAll()
			remote = folder:FindFirstChild(name)
		else
			remote = folder:WaitForChild(name, 30)
		end
	end
	assert(remote, "Unknown remote event " .. tostring(name))
	return remote :: RemoteEvent
end

function Remotes.ok(extra: { [string]: any }?): { [string]: any }
	local result: { [string]: any } = { ok = true }
	if extra then
		for key, value in pairs(extra) do
			result[key] = value
		end
	end
	return result
end

function Remotes.fail(code: string, message: string?, extra: { [string]: any }?): { [string]: any }
	local result: { [string]: any } = { ok = false, error = code, message = message or code }
	if extra then
		for key, value in pairs(extra) do
			result[key] = value
		end
	end
	return result
end

return Remotes
