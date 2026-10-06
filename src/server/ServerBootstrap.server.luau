--!nonstrict
-- ServerBootstrap: builds the ServerContext, requires every service, calls Init in the documented
-- order (section 6 of docs/ARCHITECTURE.md), then Start. Each step is wrapped in pcall so one
-- failing service never takes the whole server down.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared.Util.Remotes)

local ServicesFolder = script:WaitForChild("Services")

local SERVICE_ORDER = {
	"PlayerDataService",
	"ProgressionService",
	"CityService",
	"AntiCheatService",
	"VehicleService",
	"RewardService",
	"OrderService",
	"TutorialService",
	"ShopService",
	"ContractService",
	"DriverService",
	"DepotService",
	"InteractionService",
}

-- CityLayout is authored data; a missing module is reported, not fatal.
local layout = nil
local cityFolder = Shared:FindFirstChild("City")
local layoutModule = cityFolder and cityFolder:FindFirstChild("CityLayout")
if layoutModule then
	local okLayout, result = pcall(require, layoutModule)
	if okLayout then
		layout = result
	else
		warn("[ServerBootstrap] CityLayout failed to load:", result)
	end
else
	warn("[ServerBootstrap] CityLayout module not found; city services will run without layout data")
end

local ctx = {
	services = {},
	remotes = Remotes,
	layout = layout,
	graph = nil, -- filled by CityService.Init
	world = nil, -- filled by CityService.Init
	isStudio = RunService:IsStudio(),
}

-- Require every service module (documented order first, then any extra modules in the folder).
local ordered = {}
local seen = {}
local function addService(name: string, module: Instance)
	if seen[name] then
		return
	end
	seen[name] = true
	local okRequire, service = pcall(require, module)
	if not okRequire then
		warn(string.format("[ServerBootstrap] failed to require %s: %s", name, tostring(service)))
		return
	end
	if type(service) ~= "table" then
		warn(string.format("[ServerBootstrap] %s did not return a table", name))
		return
	end
	ctx.services[name] = service
	table.insert(ordered, { name = name, service = service })
end

for _, name in ipairs(SERVICE_ORDER) do
	local module = ServicesFolder:FindFirstChild(name)
	if module and module:IsA("ModuleScript") then
		addService(name, module)
	else
		warn(string.format("[ServerBootstrap] service %s not found", name))
	end
end
for _, module in ipairs(ServicesFolder:GetChildren()) do
	if module:IsA("ModuleScript") and not seen[module.Name] then
		addService(module.Name, module)
	end
end

for _, entry in ipairs(ordered) do
	if type(entry.service.Init) == "function" then
		local okInit, err = pcall(entry.service.Init, ctx)
		if not okInit then
			warn(string.format("[ServerBootstrap] %s.Init failed: %s", entry.name, tostring(err)))
		end
	end
end

for _, entry in ipairs(ordered) do
	if type(entry.service.Start) == "function" then
		local okStart, err = pcall(entry.service.Start)
		if not okStart then
			warn(string.format("[ServerBootstrap] %s.Start failed: %s", entry.name, tostring(err)))
		end
	end
end

print(string.format("Delivery Dash City server ready (%d services)", #ordered))
