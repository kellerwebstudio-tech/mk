--!nonstrict
-- tests/shim.luau — offline Roblox API mock for the standalone "luau" CLI.
--
-- This file is a module: it returns the `shim` table.  tools/bundle.py wraps it so that
-- `shim` is also available as a global inside tests/build/all.luau.  Everything here is
-- pure Luau; nothing touches the real Roblox engine.  See docs/TESTING.md for what is
-- mocked faithfully and what is only approximated.
--
-- Layout (search for "---- SECTION"):
--   1. natives + helpers        5. Enum
--   2. Signal                   6. Instance system (classes, properties, events)
--   3. virtual scheduler/clock  7. services + DataModel
--   4. math datatypes           8. modules/require, globals, reset, exports

---- SECTION 1: natives and helpers -------------------------------------------------------

local shim = {}
local NATIVE = _G -- the CLI's real global table (read-only)

local rawget, rawset, rawequal, setmetatable, getmetatable = rawget, rawset, rawequal, setmetatable, getmetatable
local type, pairs, ipairs, next, select, tostring, tonumber = type, pairs, ipairs, next, select, tostring, tonumber
local pcall, xpcall, error, unpack = pcall, xpcall, error, unpack
local coroutine, string, table, math, os, debug, utf8 = coroutine, string, table, math, os, debug, utf8
local loadstring, setfenv, getfenv = loadstring, setfenv, getfenv
local nativeTypeof, nativePrint = typeof, print
local mainThread = coroutine.running()

local function tcopy(t)
	local out = {}
	for k, v in pairs(t) do out[k] = v end
	return out
end

local function clamp(x, lo, hi)
	if x < lo then return lo elseif x > hi then return hi end
	return x
end

local function round(x)
	return math.floor(x + 0.5)
end

local function fmtArgs(...)
	local n = select("#", ...)
	local parts = table.create(n)
	for i = 1, n do
		parts[i] = tostring((select(i, ...)))
	end
	return table.concat(parts, "\t")
end

local function isCallable(v)
	return type(v) == "function" or (type(v) == "table" and getmetatable(v) ~= nil and getmetatable(v).__call ~= nil)
end

-- deep copy of plain data (used for remotes and DataStores); shim datatypes are immutable and shared
local instanceCheck = nil -- set once the Instance system exists
local function deepCopy(v, seen)
	if type(v) ~= "table" then return v end
	if instanceCheck and instanceCheck(v) then return v end
	local mt = getmetatable(v)
	if type(mt) == "table" and rawget(mt, "__type") then return v end
	seen = seen or {}
	if seen[v] then return seen[v] end
	local out = {}
	seen[v] = out
	for k, val in pairs(v) do
		out[deepCopy(k, seen)] = deepCopy(val, seen)
	end
	return out
end
shim.deepCopy = deepCopy

shim.prints = {}
shim.warnings = {}
shim.threadErrors = {}
shim.threadErrorRecords = {}
shim.unknownClasses = {}
shim.quiet = false
shim.boundToClose = {}

local function out(line)
	if not shim.quiet then nativePrint(line) end
end

local function robloxPrint(...)
	local line = fmtArgs(...)
	table.insert(shim.prints, line)
	out(line)
end

local function robloxWarn(...)
	local line = fmtArgs(...)
	table.insert(shim.warnings, line)
	out("[warn] " .. line)
end
shim.print = robloxPrint
shim.warn = robloxWarn

local function recordThreadError(err, co)
	local msg = tostring(err)
	if co then
		local tb = debug.traceback(co, "", 0)
		if tb and tb ~= "" then msg = msg .. "\n" .. tb end
	end
	table.insert(shim.threadErrors, msg)
	table.insert(shim.threadErrorRecords, { thread = co, message = msg })
	out("[thread error] " .. msg)
end

local function fail(level, fmt, ...)
	error(string.format(fmt, ...), level + 1)
end

---- SECTION 2: Signal ----------------------------------------------------------------------

local Signal = {}
Signal.__index = Signal
Signal.__type = "RBXScriptSignal"
Signal.__tostring = function(s) return "Signal(" .. (s._name or "?") .. ")" end

local Connection = {}
Connection.__index = Connection
Connection.__type = "RBXScriptConnection"

function Connection:Disconnect()
	if not self.Connected then return end
	self.Connected = false
	local list = self._signal._connections
	for i = #list, 1, -1 do
		if list[i] == self then table.remove(list, i) break end
	end
end
Connection.disconnect = Connection.Disconnect

local function resumeThread(co, ...)
	local ok, err = coroutine.resume(co, ...)
	if not ok then recordThreadError(err, co) end
end
shim.resumeThread = resumeThread

local function runHandler(fn, ...)
	local co = coroutine.create(fn)
	resumeThread(co, ...)
end

function Signal.new(name)
	return setmetatable({ _connections = {}, _waiters = {}, _name = name }, Signal)
end

function Signal:Connect(fn)
	if not isCallable(fn) then fail(2, "Signal:Connect expects a function, got %s", type(fn)) end
	local conn = setmetatable({ Connected = true, _fn = fn, _signal = self }, Connection)
	table.insert(self._connections, conn)
	return conn
end
Signal.connect = Signal.Connect
Signal.ConnectParallel = Signal.Connect

function Signal:Once(fn)
	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		fn(...)
	end)
	return conn
end

function Signal:Wait()
	local co = coroutine.running()
	if co == mainThread then
		fail(2, "Signal:Wait() would yield the main test thread (%s); call it from a task.spawn thread or inside it()", tostring(self))
	end
	table.insert(self._waiters, co)
	return coroutine.yield()
end
Signal.wait = Signal.Wait

function Signal:Fire(...)
	local snapshot = tcopy(self._connections)
	for _, conn in ipairs(snapshot) do
		if conn.Connected then runHandler(conn._fn, ...) end
	end
	if #self._waiters > 0 then
		local waiters = self._waiters
		self._waiters = {}
		for _, co in ipairs(waiters) do
			if coroutine.status(co) == "suspended" then resumeThread(co, ...) end
		end
	end
end
Signal.fire = Signal.Fire

function Signal:DisconnectAll()
	for _, conn in ipairs(self._connections) do conn.Connected = false end
	self._connections = {}
end
Signal.Destroy = Signal.DisconnectAll

function Signal:GetConnectionCount()
	return #self._connections
end

shim.Signal = Signal

---- SECTION 3: virtual scheduler and clock ------------------------------------------------

shim.clock = 1000 -- os.clock()
shim.realClock = os.clock -- the host clock (wall time), for specs that report real decode/benchmark times
shim.epochStart = 1700000000 -- os.time() at clock start
shim.clockStart = 1000
shim.frame = 0
shim.stepDt = 1 / 30
shim.context = "server"
shim.tweensInstant = false

local sched = { queue = {}, seq = 0, waitingEntry = setmetatable({}, { __mode = "k" }), depth = 0 }
shim._sched = sched

local function now()
	return shim.clock
end

local function schedule(due, kind, target, args, n)
	sched.seq += 1
	local entry = { due = due, seq = sched.seq, kind = kind, target = target, args = args, n = n or 0 }
	local q = sched.queue
	-- sorted insert by (due, seq)
	local lo, hi = 1, #q + 1
	while lo < hi do
		local mid = math.floor((lo + hi) / 2)
		local e = q[mid]
		if e.due < due or (e.due == due and e.seq < entry.seq) then lo = mid + 1 else hi = mid end
	end
	table.insert(q, lo, entry)
	if kind == "wait" then sched.waitingEntry[target] = entry end
	return entry
end

local function cancelEntriesFor(co)
	local q = sched.queue
	for i = #q, 1, -1 do
		if q[i].target == co then table.remove(q, i) end
	end
	sched.waitingEntry[co] = nil
end

local function runEntry(entry)
	entry.cancelled = true
	if entry.kind == "wait" then
		local co = entry.target
		if sched.waitingEntry[co] ~= entry then return end
		sched.waitingEntry[co] = nil
		if coroutine.status(co) == "suspended" then
			resumeThread(co, now() - entry.startedAt)
		end
	elseif entry.kind == "resume" then
		local co = entry.target
		if coroutine.status(co) == "suspended" then
			resumeThread(co, unpack(entry.args, 1, entry.n))
		end
	elseif entry.kind == "call" then
		local target = entry.target
		if type(target) == "thread" then
			if coroutine.status(target) == "suspended" then
				resumeThread(target, unpack(entry.args, 1, entry.n))
			end
		else
			runHandler(target, unpack(entry.args, 1, entry.n))
		end
	end
end

-- Runs every queued entry that is due.  Entries created while running that are due immediately
-- (task.defer chains) are allowed up to a depth limit; task.wait(0) always goes to the next step.
local function runDue()
	local cutoffSeq = sched.seq
	local guard = 0
	while true do
		local q = sched.queue
		local e = q[1]
		if not e or e.due > shim.clock then break end
		if e.seq > cutoffSeq then
			if e.kind == "wait" or guard > 200 then break end
			guard += 1
		end
		table.remove(q, 1)
		runEntry(e)
	end
end

local function nextDue()
	local e = sched.queue[1]
	return e and e.due or nil
end
shim.nextDue = nextDue

local function checkYieldable(fnName)
	local co = coroutine.running()
	if co == mainThread then
		fail(3, "%s cannot yield from the main test thread; use task.spawn(...) or call it inside it()", fnName)
	end
	return co
end

local task = {}
shim.task = task

function task.wait(t)
	local co = checkYieldable("task.wait")
	t = tonumber(t) or 0
	if t < 0 then t = 0 end
	local entry = schedule(now() + t, "wait", co)
	entry.startedAt = now()
	return coroutine.yield()
end

function task.spawn(fnOrThread, ...)
	local co
	if type(fnOrThread) == "thread" then
		co = fnOrThread
		cancelEntriesFor(co)
	elseif isCallable(fnOrThread) then
		co = coroutine.create(fnOrThread)
	else
		fail(2, "task.spawn expects a function or thread, got %s", type(fnOrThread))
	end
	resumeThread(co, ...)
	return co
end

function task.defer(fnOrThread, ...)
	local co
	if type(fnOrThread) == "thread" then
		co = fnOrThread
		cancelEntriesFor(co)
	elseif isCallable(fnOrThread) then
		co = coroutine.create(fnOrThread)
	else
		fail(2, "task.defer expects a function or thread, got %s", type(fnOrThread))
	end
	schedule(now(), "call", co, { ... }, select("#", ...))
	return co
end

function task.delay(t, fnOrThread, ...)
	t = tonumber(t) or 0
	local co
	if type(fnOrThread) == "thread" then
		co = fnOrThread
	elseif isCallable(fnOrThread) then
		co = coroutine.create(fnOrThread)
	else
		fail(2, "task.delay expects a function or thread, got %s", type(fnOrThread))
	end
	schedule(now() + math.max(t, 0), "call", co, { ... }, select("#", ...))
	return co
end

function task.cancel(co)
	if type(co) ~= "thread" then fail(2, "task.cancel expects a thread, got %s", type(co)) end
	cancelEntriesFor(co)
	if coroutine.status(co) == "suspended" then coroutine.close(co) end
end

function task.synchronize() end
function task.desynchronize() end

local function legacyWait(t)
	local elapsed = task.wait(math.max(tonumber(t) or 0.03, 0.03))
	return elapsed, now() - shim.clockStart
end

local function legacySpawn(fn)
	task.defer(fn)
end

local function legacyDelay(t, fn)
	task.delay(t, fn)
end

-- hooks run every step, in order (used by RunService, tweens, UI layout...)
local stepHooks = {}

function shim.step(dt)
	dt = tonumber(dt) or shim.stepDt
	if dt < 0 then dt = 0 end
	shim.clock += dt
	shim.frame += 1
	for _, hook in ipairs(stepHooks) do hook(dt) end
	runDue()
end

function shim.advance(seconds, dt)
	seconds = tonumber(seconds) or 0
	dt = tonumber(dt) or shim.stepDt
	if dt <= 0 then dt = shim.stepDt end
	local target = shim.clock + seconds
	local first = true
	while first or shim.clock < target do
		first = false
		local nxt = math.min(target, shim.clock + dt)
		local due = nextDue()
		if due and due > shim.clock and due < nxt then nxt = due end
		local stepDt = nxt - shim.clock
		shim.step(stepDt)
		shim.clock = nxt -- defeat float drift
		if seconds <= 0 then break end
	end
	if target - shim.clock < 1e-9 then shim.clock = target end
end

-- Run the scheduler until `co` is dead or the virtual budget is exhausted. Returns true if finished.
function shim.runUntilDead(co, budgetSeconds, dt)
	budgetSeconds = budgetSeconds or 120
	local deadline = shim.clock + budgetSeconds
	local idleSteps = 0
	while coroutine.status(co) ~= "dead" do
		if shim.clock >= deadline then return false end
		local due = nextDue()
		if due == nil then
			idleSteps += 1
			if idleSteps > 5000 then return false end
		end
		local nxt = math.min(deadline, shim.clock + (dt or shim.stepDt))
		if due and due > shim.clock and due < nxt then nxt = due end
		shim.step(nxt - shim.clock)
		shim.clock = nxt
	end
	return true
end

function shim.pendingThreads()
	return #sched.queue
end

---- SECTION 4: math datatypes --------------------------------------------------------------

local Vector3, Vector2, CFrame, Color3, BrickColor, UDim, UDim2, Rect, Random, Region3, Ray, Font
local NumberRange, NumberSequence, NumberSequenceKeypoint, ColorSequence, ColorSequenceKeypoint
local TweenInfo, PhysicalProperties, RaycastParams, OverlapParams, DateTime, Content
local Enum -- defined in section 5

local function checkNum(v, what, level)
	if type(v) ~= "number" then fail((level or 2) + 1, "%s expected a number, got %s", what, nativeTypeof(v)) end
	return v
end

local function fmtNum(n)
	if n == math.floor(n) and math.abs(n) < 1e15 then return string.format("%d", n) end
	local s = string.format("%.5f", n)
	s = s:gsub("0+$", ""):gsub("%.$", "")
	return s
end

do -- Vector3
	local V3 = {}
	V3.__type = "Vector3"
	local methods = {}
	local function new(x, y, z)
		return table.freeze(setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, V3))
	end
	local function isV3(v) return type(v) == "table" and getmetatable(v) == V3 end
	V3.__index = function(v, k)
		local m = methods[k]
		if m then return m end
		if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
		elseif k == "Unit" then
			local mag = math.sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z)
			if mag == 0 then return new(0 / 0, 0 / 0, 0 / 0) end
			return new(v.X / mag, v.Y / mag, v.Z / mag)
		elseif k == "x" then return v.X elseif k == "y" then return v.Y elseif k == "z" then return v.Z
		elseif k == "magnitude" then return v.Magnitude elseif k == "unit" then return v.Unit
		end
		fail(2, "%s is not a valid member of Vector3", tostring(k))
	end
	V3.__newindex = function(_, k) fail(2, "Vector3 is immutable (tried to set %s)", tostring(k)) end
	V3.__add = function(a, b)
		if not (isV3(a) and isV3(b)) then fail(2, "Vector3 + %s is not supported", nativeTypeof(isV3(a) and b or a)) end
		return new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
	end
	V3.__sub = function(a, b)
		if not (isV3(a) and isV3(b)) then fail(2, "Vector3 - %s is not supported", nativeTypeof(isV3(a) and b or a)) end
		return new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
	end
	V3.__mul = function(a, b)
		if type(a) == "number" then return new(a * b.X, a * b.Y, a * b.Z) end
		if type(b) == "number" then return new(a.X * b, a.Y * b, a.Z * b) end
		if isV3(a) and isV3(b) then return new(a.X * b.X, a.Y * b.Y, a.Z * b.Z) end
		fail(2, "Vector3 * %s is not supported", nativeTypeof(isV3(a) and b or a))
	end
	V3.__div = function(a, b)
		if type(b) == "number" then return new(a.X / b, a.Y / b, a.Z / b) end
		if isV3(a) and isV3(b) then return new(a.X / b.X, a.Y / b.Y, a.Z / b.Z) end
		if type(a) == "number" then return new(a / b.X, a / b.Y, a / b.Z) end
		fail(2, "Vector3 / %s is not supported", nativeTypeof(b))
	end
	V3.__idiv = function(a, b)
		if type(b) == "number" then return new(a.X // b, a.Y // b, a.Z // b) end
		return new(a.X // b.X, a.Y // b.Y, a.Z // b.Z)
	end
	V3.__unm = function(a) return new(-a.X, -a.Y, -a.Z) end
	V3.__eq = function(a, b) return a.X == b.X and a.Y == b.Y and a.Z == b.Z end
	V3.__tostring = function(v) return fmtNum(v.X) .. ", " .. fmtNum(v.Y) .. ", " .. fmtNum(v.Z) end

	function methods.Dot(a, b) return a.X * b.X + a.Y * b.Y + a.Z * b.Z end
	function methods.Cross(a, b)
		return new(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
	end
	function methods.Lerp(a, b, t) return new(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t, a.Z + (b.Z - a.Z) * t) end
	function methods.FuzzyEq(a, b, eps)
		eps = eps or 1e-5
		return math.abs(a.X - b.X) <= eps and math.abs(a.Y - b.Y) <= eps and math.abs(a.Z - b.Z) <= eps
	end
	function methods.Abs(a) return new(math.abs(a.X), math.abs(a.Y), math.abs(a.Z)) end
	function methods.Ceil(a) return new(math.ceil(a.X), math.ceil(a.Y), math.ceil(a.Z)) end
	function methods.Floor(a) return new(math.floor(a.X), math.floor(a.Y), math.floor(a.Z)) end
	function methods.Sign(a) return new(math.sign(a.X), math.sign(a.Y), math.sign(a.Z)) end
	function methods.Max(a, ...)
		local x, y, z = a.X, a.Y, a.Z
		for i = 1, select("#", ...) do
			local b = select(i, ...)
			x, y, z = math.max(x, b.X), math.max(y, b.Y), math.max(z, b.Z)
		end
		return new(x, y, z)
	end
	function methods.Min(a, ...)
		local x, y, z = a.X, a.Y, a.Z
		for i = 1, select("#", ...) do
			local b = select(i, ...)
			x, y, z = math.min(x, b.X), math.min(y, b.Y), math.min(z, b.Z)
		end
		return new(x, y, z)
	end
	function methods.Angle(a, b, axis)
		local cross = methods.Cross(a, b)
		local ang = math.atan2(cross.Magnitude, methods.Dot(a, b))
		if axis and methods.Dot(cross, axis) < 0 then ang = -ang end
		return ang
	end
	methods.dot, methods.cross, methods.lerp = methods.Dot, methods.Cross, methods.Lerp

	Vector3 = {
		new = function(x, y, z)
			if x ~= nil then checkNum(x, "Vector3.new", 2) end
			if y ~= nil then checkNum(y, "Vector3.new", 2) end
			if z ~= nil then checkNum(z, "Vector3.new", 2) end
			return new(x, y, z)
		end,
		zero = new(0, 0, 0), one = new(1, 1, 1),
		xAxis = new(1, 0, 0), yAxis = new(0, 1, 0), zAxis = new(0, 0, 1),
		FromNormalId = function(normalId)
			local name = normalId.Name
			if name == "Right" then return new(1, 0, 0) elseif name == "Left" then return new(-1, 0, 0)
			elseif name == "Top" then return new(0, 1, 0) elseif name == "Bottom" then return new(0, -1, 0)
			elseif name == "Back" then return new(0, 0, 1) else return new(0, 0, -1) end
		end,
		FromAxis = function(axis)
			local name = axis.Name
			if name == "X" then return new(1, 0, 0) elseif name == "Y" then return new(0, 1, 0) else return new(0, 0, 1) end
		end,
		_is = isV3, _raw = new,
	}
end

do -- Vector2
	local V2 = {}
	V2.__type = "Vector2"
	local methods = {}
	local function new(x, y) return table.freeze(setmetatable({ X = x or 0, Y = y or 0 }, V2)) end
	local function isV2(v) return type(v) == "table" and getmetatable(v) == V2 end
	V2.__index = function(v, k)
		local m = methods[k]
		if m then return m end
		if k == "Magnitude" then return math.sqrt(v.X * v.X + v.Y * v.Y)
		elseif k == "Unit" then
			local mag = math.sqrt(v.X * v.X + v.Y * v.Y)
			if mag == 0 then return new(0 / 0, 0 / 0) end
			return new(v.X / mag, v.Y / mag)
		elseif k == "x" then return v.X elseif k == "y" then return v.Y end
		fail(2, "%s is not a valid member of Vector2", tostring(k))
	end
	V2.__newindex = function(_, k) fail(2, "Vector2 is immutable (tried to set %s)", tostring(k)) end
	V2.__add = function(a, b) return new(a.X + b.X, a.Y + b.Y) end
	V2.__sub = function(a, b) return new(a.X - b.X, a.Y - b.Y) end
	V2.__mul = function(a, b)
		if type(a) == "number" then return new(a * b.X, a * b.Y) end
		if type(b) == "number" then return new(a.X * b, a.Y * b) end
		return new(a.X * b.X, a.Y * b.Y)
	end
	V2.__div = function(a, b)
		if type(b) == "number" then return new(a.X / b, a.Y / b) end
		if type(a) == "number" then return new(a / b.X, a / b.Y) end
		return new(a.X / b.X, a.Y / b.Y)
	end
	V2.__unm = function(a) return new(-a.X, -a.Y) end
	V2.__eq = function(a, b) return a.X == b.X and a.Y == b.Y end
	V2.__tostring = function(v) return fmtNum(v.X) .. ", " .. fmtNum(v.Y) end
	function methods.Dot(a, b) return a.X * b.X + a.Y * b.Y end
	function methods.Cross(a, b) return a.X * b.Y - a.Y * b.X end
	function methods.Lerp(a, b, t) return new(a.X + (b.X - a.X) * t, a.Y + (b.Y - a.Y) * t) end
	function methods.FuzzyEq(a, b, eps) eps = eps or 1e-5 return math.abs(a.X - b.X) <= eps and math.abs(a.Y - b.Y) <= eps end
	function methods.Abs(a) return new(math.abs(a.X), math.abs(a.Y)) end
	function methods.Ceil(a) return new(math.ceil(a.X), math.ceil(a.Y)) end
	function methods.Floor(a) return new(math.floor(a.X), math.floor(a.Y)) end
	function methods.Sign(a) return new(math.sign(a.X), math.sign(a.Y)) end
	function methods.Max(a, b) return new(math.max(a.X, b.X), math.max(a.Y, b.Y)) end
	function methods.Min(a, b) return new(math.min(a.X, b.X), math.min(a.Y, b.Y)) end
	function methods.Angle(a, b, isSigned)
		local ang = math.atan2(methods.Cross(a, b), methods.Dot(a, b))
		if not isSigned then ang = math.abs(ang) end
		return ang
	end
	Vector2 = {
		new = function(x, y)
			if x ~= nil then checkNum(x, "Vector2.new", 2) end
			if y ~= nil then checkNum(y, "Vector2.new", 2) end
			return new(x, y)
		end,
		zero = new(0, 0), one = new(1, 1), xAxis = new(1, 0), yAxis = new(0, 1),
		_is = isV2, _raw = new,
	}
end

do -- CFrame: position + row-major 3x3 rotation matrix (R00..R22), numerically real
	local CF = {}
	CF.__type = "CFrame"
	local methods = {}
	local v3 = Vector3._raw
	local function raw(x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22)
		return table.freeze(setmetatable({
			x = x, y = y, z = z,
			r00 = r00, r01 = r01, r02 = r02,
			r10 = r10, r11 = r11, r12 = r12,
			r20 = r20, r21 = r21, r22 = r22,
		}, CF))
	end
	local function identity() return raw(0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1) end
	local function isCF(v) return type(v) == "table" and getmetatable(v) == CF end

	local function mulCF(a, b)
		return raw(
			a.r00 * b.x + a.r01 * b.y + a.r02 * b.z + a.x,
			a.r10 * b.x + a.r11 * b.y + a.r12 * b.z + a.y,
			a.r20 * b.x + a.r21 * b.y + a.r22 * b.z + a.z,
			a.r00 * b.r00 + a.r01 * b.r10 + a.r02 * b.r20,
			a.r00 * b.r01 + a.r01 * b.r11 + a.r02 * b.r21,
			a.r00 * b.r02 + a.r01 * b.r12 + a.r02 * b.r22,
			a.r10 * b.r00 + a.r11 * b.r10 + a.r12 * b.r20,
			a.r10 * b.r01 + a.r11 * b.r11 + a.r12 * b.r21,
			a.r10 * b.r02 + a.r11 * b.r12 + a.r12 * b.r22,
			a.r20 * b.r00 + a.r21 * b.r10 + a.r22 * b.r20,
			a.r20 * b.r01 + a.r21 * b.r11 + a.r22 * b.r21,
			a.r20 * b.r02 + a.r21 * b.r12 + a.r22 * b.r22
		)
	end
	local function mulPoint(a, v)
		return v3(
			a.r00 * v.X + a.r01 * v.Y + a.r02 * v.Z + a.x,
			a.r10 * v.X + a.r11 * v.Y + a.r12 * v.Z + a.y,
			a.r20 * v.X + a.r21 * v.Y + a.r22 * v.Z + a.z
		)
	end
	local function mulVector(a, v)
		return v3(
			a.r00 * v.X + a.r01 * v.Y + a.r02 * v.Z,
			a.r10 * v.X + a.r11 * v.Y + a.r12 * v.Z,
			a.r20 * v.X + a.r21 * v.Y + a.r22 * v.Z
		)
	end
	local function inverse(a)
		-- R^T and -R^T * p
		local px = -(a.r00 * a.x + a.r10 * a.y + a.r20 * a.z)
		local py = -(a.r01 * a.x + a.r11 * a.y + a.r21 * a.z)
		local pz = -(a.r02 * a.x + a.r12 * a.y + a.r22 * a.z)
		return raw(px, py, pz, a.r00, a.r10, a.r20, a.r01, a.r11, a.r21, a.r02, a.r12, a.r22)
	end
	local function fromAxes(pos, right, up, back)
		return raw(pos.X, pos.Y, pos.Z, right.X, up.X, back.X, right.Y, up.Y, back.Y, right.Z, up.Z, back.Z)
	end
	local function lookAlong(pos, dir, up)
		up = up or v3(0, 1, 0)
		local mag = dir.Magnitude
		if mag < 1e-12 then return raw(pos.X, pos.Y, pos.Z, 1, 0, 0, 0, 1, 0, 0, 0, 1) end
		local look = dir / mag
		local right = look:Cross(up)
		if right.Magnitude < 1e-6 then
			-- dir parallel to up: pick a different up like Roblox does
			up = (math.abs(look.Y) < 0.99) and v3(0, 1, 0) or v3(0, 0, 1)
			right = look:Cross(up)
		end
		right = right.Unit
		local realUp = right:Cross(look).Unit
		return fromAxes(pos, right, realUp, -look)
	end
	local function fromQuaternion(x, y, z, qx, qy, qz, qw)
		local n = math.sqrt(qx * qx + qy * qy + qz * qz + qw * qw)
		if n == 0 then return raw(x, y, z, 1, 0, 0, 0, 1, 0, 0, 0, 1) end
		qx, qy, qz, qw = qx / n, qy / n, qz / n, qw / n
		return raw(x, y, z,
			1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw),
			2 * (qx * qy + qz * qw), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qx * qw),
			2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (qx * qx + qy * qy))
	end
	local function toQuaternion(a)
		local trace = a.r00 + a.r11 + a.r22
		local qx, qy, qz, qw
		if trace > 0 then
			local s = math.sqrt(trace + 1) * 2
			qw = 0.25 * s
			qx = (a.r21 - a.r12) / s
			qy = (a.r02 - a.r20) / s
			qz = (a.r10 - a.r01) / s
		elseif a.r00 > a.r11 and a.r00 > a.r22 then
			local s = math.sqrt(1 + a.r00 - a.r11 - a.r22) * 2
			qw = (a.r21 - a.r12) / s
			qx = 0.25 * s
			qy = (a.r01 + a.r10) / s
			qz = (a.r02 + a.r20) / s
		elseif a.r11 > a.r22 then
			local s = math.sqrt(1 + a.r11 - a.r00 - a.r22) * 2
			qw = (a.r02 - a.r20) / s
			qx = (a.r01 + a.r10) / s
			qy = 0.25 * s
			qz = (a.r12 + a.r21) / s
		else
			local s = math.sqrt(1 + a.r22 - a.r00 - a.r11) * 2
			qw = (a.r10 - a.r01) / s
			qx = (a.r02 + a.r20) / s
			qy = (a.r12 + a.r21) / s
			qz = 0.25 * s
		end
		return qx, qy, qz, qw
	end
	local function anglesXYZ(rx, ry, rz)
		local ca, sa = math.cos(rx), math.sin(rx)
		local cb, sb = math.cos(ry), math.sin(ry)
		local cc, sc = math.cos(rz), math.sin(rz)
		return raw(0, 0, 0,
			cb * cc, -cb * sc, sb,
			ca * sc + sa * sb * cc, ca * cc - sa * sb * sc, -sa * cb,
			sa * sc - ca * sb * cc, sa * cc + ca * sb * sc, ca * cb)
	end
	local function anglesYXZ(rx, ry, rz)
		local ca, sa = math.cos(rx), math.sin(rx)
		local cb, sb = math.cos(ry), math.sin(ry)
		local cc, sc = math.cos(rz), math.sin(rz)
		return raw(0, 0, 0,
			cb * cc + sb * sa * sc, -cb * sc + sb * sa * cc, sb * ca,
			ca * sc, ca * cc, -sa,
			-sb * cc + cb * sa * sc, sb * sc + cb * sa * cc, cb * ca)
	end
	local function fromAxisAngle(axis, angle)
		local u = axis.Unit
		local c, s = math.cos(angle), math.sin(angle)
		local t = 1 - c
		local x, y, z = u.X, u.Y, u.Z
		return raw(0, 0, 0,
			t * x * x + c, t * x * y - s * z, t * x * z + s * y,
			t * x * y + s * z, t * y * y + c, t * y * z - s * x,
			t * x * z - s * y, t * y * z + s * x, t * z * z + c)
	end
	local function withPosition(a, p)
		return raw(p.X, p.Y, p.Z, a.r00, a.r01, a.r02, a.r10, a.r11, a.r12, a.r20, a.r21, a.r22)
	end
	local function orthonormalize(a)
		local right = v3(a.r00, a.r10, a.r20).Unit
		local up = v3(a.r01, a.r11, a.r21)
		up = (up - right * right:Dot(up)).Unit
		local back = right:Cross(up)
		return fromAxes(v3(a.x, a.y, a.z), right, up, back)
	end

	CF.__index = function(cf, k)
		local m = methods[k]
		if m then return m end
		if k == "Position" or k == "p" then return v3(cf.x, cf.y, cf.z)
		elseif k == "X" then return cf.x elseif k == "Y" then return cf.y elseif k == "Z" then return cf.z
		elseif k == "LookVector" or k == "lookVector" then return v3(-cf.r02, -cf.r12, -cf.r22)
		elseif k == "RightVector" or k == "XVector" then return v3(cf.r00, cf.r10, cf.r20)
		elseif k == "UpVector" or k == "YVector" then return v3(cf.r01, cf.r11, cf.r21)
		elseif k == "ZVector" then return v3(cf.r02, cf.r12, cf.r22)
		elseif k == "Rotation" then return raw(0, 0, 0, cf.r00, cf.r01, cf.r02, cf.r10, cf.r11, cf.r12, cf.r20, cf.r21, cf.r22)
		end
		fail(2, "%s is not a valid member of CFrame", tostring(k))
	end
	CF.__newindex = function(_, k) fail(2, "CFrame is immutable (tried to set %s)", tostring(k)) end
	CF.__mul = function(a, b)
		if isCF(a) and isCF(b) then return mulCF(a, b) end
		if isCF(a) and Vector3._is(b) then return mulPoint(a, b) end
		fail(2, "CFrame * %s is not supported", nativeTypeof(isCF(a) and b or a))
	end
	CF.__add = function(a, b)
		if isCF(a) and Vector3._is(b) then return raw(a.x + b.X, a.y + b.Y, a.z + b.Z, a.r00, a.r01, a.r02, a.r10, a.r11, a.r12, a.r20, a.r21, a.r22) end
		fail(2, "CFrame + %s is not supported", nativeTypeof(isCF(a) and b or a))
	end
	CF.__sub = function(a, b)
		if isCF(a) and Vector3._is(b) then return raw(a.x - b.X, a.y - b.Y, a.z - b.Z, a.r00, a.r01, a.r02, a.r10, a.r11, a.r12, a.r20, a.r21, a.r22) end
		fail(2, "CFrame - %s is not supported", nativeTypeof(isCF(a) and b or a))
	end
	CF.__eq = function(a, b)
		return a.x == b.x and a.y == b.y and a.z == b.z
			and a.r00 == b.r00 and a.r01 == b.r01 and a.r02 == b.r02
			and a.r10 == b.r10 and a.r11 == b.r11 and a.r12 == b.r12
			and a.r20 == b.r20 and a.r21 == b.r21 and a.r22 == b.r22
	end
	CF.__tostring = function(a)
		local parts = { a.x, a.y, a.z, a.r00, a.r01, a.r02, a.r10, a.r11, a.r12, a.r20, a.r21, a.r22 }
		for i, n in ipairs(parts) do parts[i] = fmtNum(n) end
		return table.concat(parts, ", ")
	end

	function methods.Inverse(a) return inverse(a) end
	methods.inverse = methods.Inverse
	function methods.ToWorldSpace(a, ...)
		local n = select("#", ...)
		if n == 1 then return mulCF(a, (...)) end
		local res = {}
		for i = 1, n do res[i] = mulCF(a, (select(i, ...))) end
		return unpack(res, 1, n)
	end
	function methods.ToObjectSpace(a, ...)
		local inv = inverse(a)
		local n = select("#", ...)
		if n == 1 then return mulCF(inv, (...)) end
		local res = {}
		for i = 1, n do res[i] = mulCF(inv, (select(i, ...))) end
		return unpack(res, 1, n)
	end
	function methods.PointToWorldSpace(a, ...)
		local n = select("#", ...)
		if n == 1 then return mulPoint(a, (...)) end
		local res = {}
		for i = 1, n do res[i] = mulPoint(a, (select(i, ...))) end
		return unpack(res, 1, n)
	end
	function methods.PointToObjectSpace(a, ...)
		local inv = inverse(a)
		local n = select("#", ...)
		if n == 1 then return mulPoint(inv, (...)) end
		local res = {}
		for i = 1, n do res[i] = mulPoint(inv, (select(i, ...))) end
		return unpack(res, 1, n)
	end
	function methods.VectorToWorldSpace(a, ...)
		local n = select("#", ...)
		if n == 1 then return mulVector(a, (...)) end
		local res = {}
		for i = 1, n do res[i] = mulVector(a, (select(i, ...))) end
		return unpack(res, 1, n)
	end
	function methods.VectorToObjectSpace(a, ...)
		local inv = inverse(a)
		local n = select("#", ...)
		if n == 1 then return mulVector(inv, (...)) end
		local res = {}
		for i = 1, n do res[i] = mulVector(inv, (select(i, ...))) end
		return unpack(res, 1, n)
	end
	methods.toWorldSpace, methods.toObjectSpace = methods.ToWorldSpace, methods.ToObjectSpace
	methods.pointToWorldSpace, methods.pointToObjectSpace = methods.PointToWorldSpace, methods.PointToObjectSpace
	methods.vectorToWorldSpace, methods.vectorToObjectSpace = methods.VectorToWorldSpace, methods.VectorToObjectSpace
	function methods.GetComponents(a)
		return a.x, a.y, a.z, a.r00, a.r01, a.r02, a.r10, a.r11, a.r12, a.r20, a.r21, a.r22
	end
	methods.components = methods.GetComponents
	function methods.ToEulerAnglesXYZ(a)
		local ry = math.asin(clamp(a.r02, -1, 1))
		local rx = math.atan2(-a.r12, a.r22)
		local rz = math.atan2(-a.r01, a.r00)
		return rx, ry, rz
	end
	function methods.ToEulerAnglesYXZ(a)
		local rx = math.asin(clamp(-a.r12, -1, 1))
		local ry = math.atan2(a.r02, a.r22)
		local rz = math.atan2(a.r10, a.r11)
		return rx, ry, rz
	end
	methods.ToOrientation = methods.ToEulerAnglesYXZ
	methods.toEulerAnglesXYZ, methods.toEulerAnglesYXZ = methods.ToEulerAnglesXYZ, methods.ToEulerAnglesYXZ
	function methods.ToEulerAngles(a, order)
		if order and order.Name == "YXZ" then return methods.ToEulerAnglesYXZ(a) end
		return methods.ToEulerAnglesXYZ(a)
	end
	function methods.ToAxisAngle(a)
		local qx, qy, qz, qw = toQuaternion(a)
		qw = clamp(qw, -1, 1)
		local angle = 2 * math.acos(qw)
		local s = math.sqrt(1 - qw * qw)
		if s < 1e-7 then return v3(1, 0, 0), 0 end
		return v3(qx / s, qy / s, qz / s), angle
	end
	methods.toAxisAngle = methods.ToAxisAngle
	function methods.Lerp(a, b, t)
		local ax, ay, az, aw = toQuaternion(a)
		local bx, by, bz, bw = toQuaternion(b)
		local dot = ax * bx + ay * by + az * bz + aw * bw
		if dot < 0 then bx, by, bz, bw, dot = -bx, -by, -bz, -bw, -dot end
		local qx, qy, qz, qw
		if dot > 0.9995 then
			qx, qy, qz, qw = ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t, aw + (bw - aw) * t
		else
			local theta0 = math.acos(clamp(dot, -1, 1))
			local theta = theta0 * t
			local sin0 = math.sin(theta0)
			local s0 = math.cos(theta) - dot * math.sin(theta) / sin0
			local s1 = math.sin(theta) / sin0
			qx, qy, qz, qw = s0 * ax + s1 * bx, s0 * ay + s1 * by, s0 * az + s1 * bz, s0 * aw + s1 * bw
		end
		return fromQuaternion(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t, qx, qy, qz, qw)
	end
	methods.lerp = methods.Lerp
	function methods.Orthonormalize(a) return orthonormalize(a) end
	function methods.FuzzyEq(a, b, eps)
		eps = eps or 1e-5
		local ac = { methods.GetComponents(a) }
		local bc = { methods.GetComponents(b) }
		for i = 1, 12 do
			if math.abs(ac[i] - bc[i]) > eps then return false end
		end
		return true
	end
	function methods.AngleBetween(a, b)
		local rel = mulCF(inverse(a), b)
		local _, angle = methods.ToAxisAngle(rel)
		return angle
	end

	CFrame = {
		new = function(...)
			local n = select("#", ...)
			if n == 0 then return identity() end
			local a, b = ...
			if n == 1 then
				if not Vector3._is(a) then fail(2, "CFrame.new expected a Vector3, got %s", nativeTypeof(a)) end
				return raw(a.X, a.Y, a.Z, 1, 0, 0, 0, 1, 0, 0, 0, 1)
			elseif n == 2 then
				if not (Vector3._is(a) and Vector3._is(b)) then fail(2, "CFrame.new(pos, lookAt) expects two Vector3s") end
				return lookAlong(a, b - a)
			elseif n == 3 then
				return raw(checkNum(a, "CFrame.new"), checkNum(b, "CFrame.new"), checkNum((select(3, ...)), "CFrame.new"), 1, 0, 0, 0, 1, 0, 0, 0, 1)
			elseif n == 7 then
				return fromQuaternion(...)
			elseif n == 12 then
				return raw(...)
			end
			fail(2, "CFrame.new: unsupported argument count %d", n)
		end,
		identity = identity(),
		lookAt = function(pos, target, up)
			return lookAlong(pos, target - pos, up)
		end,
		lookAlong = function(pos, dir, up)
			return lookAlong(pos, dir, up)
		end,
		Angles = anglesXYZ,
		fromEulerAnglesXYZ = anglesXYZ,
		fromEulerAnglesYXZ = anglesYXZ,
		fromOrientation = anglesYXZ,
		fromEulerAngles = function(rx, ry, rz, order)
			if order and order.Name == "YXZ" then return anglesYXZ(rx, ry, rz) end
			return anglesXYZ(rx, ry, rz)
		end,
		fromAxisAngle = fromAxisAngle,
		fromMatrix = function(pos, vx, vy, vz)
			if vz == nil then vz = vx:Cross(vy) end
			return fromAxes(pos, vx, vy, vz)
		end,
		fromRotationBetweenVectors = function(from, to)
			local axis = from:Cross(to)
			if axis.Magnitude < 1e-9 then
				if from:Dot(to) > 0 then return identity() end
				local alt = math.abs(from.X) < 0.9 and v3(1, 0, 0) or v3(0, 1, 0)
				return fromAxisAngle(from:Cross(alt), math.pi)
			end
			return fromAxisAngle(axis, math.acos(clamp(from.Unit:Dot(to.Unit), -1, 1)))
		end,
		_is = isCF, _raw = raw, _withPosition = withPosition,
	}
end

do -- Color3
	local C3 = {}
	C3.__type = "Color3"
	local methods = {}
	local function new(r, g, b) return table.freeze(setmetatable({ R = r or 0, G = g or 0, B = b or 0 }, C3)) end
	local function isC3(v) return type(v) == "table" and getmetatable(v) == C3 end
	C3.__index = function(c, k)
		local m = methods[k]
		if m then return m end
		if k == "r" then return c.R elseif k == "g" then return c.G elseif k == "b" then return c.B end
		fail(2, "%s is not a valid member of Color3", tostring(k))
	end
	C3.__newindex = function(_, k) fail(2, "Color3 is immutable (tried to set %s)", tostring(k)) end
	C3.__eq = function(a, b) return a.R == b.R and a.G == b.G and a.B == b.B end
	C3.__tostring = function(c) return fmtNum(c.R) .. ", " .. fmtNum(c.G) .. ", " .. fmtNum(c.B) end
	local function toHSV(c)
		local r, g, b = c.R, c.G, c.B
		local maxc, minc = math.max(r, g, b), math.min(r, g, b)
		local v = maxc
		local d = maxc - minc
		local s = maxc == 0 and 0 or d / maxc
		local h = 0
		if d ~= 0 then
			if maxc == r then h = (g - b) / d % 6
			elseif maxc == g then h = (b - r) / d + 2
			else h = (r - g) / d + 4 end
			h /= 6
		end
		return h, s, v
	end
	local function fromHSV(h, s, v)
		h = h % 1
		local i = math.floor(h * 6)
		local f = h * 6 - i
		local p, q, t = v * (1 - s), v * (1 - f * s), v * (1 - (1 - f) * s)
		i = i % 6
		if i == 0 then return new(v, t, p) elseif i == 1 then return new(q, v, p) elseif i == 2 then return new(p, v, t)
		elseif i == 3 then return new(p, q, v) elseif i == 4 then return new(t, p, v) else return new(v, p, q) end
	end
	function methods.Lerp(a, b, t) return new(a.R + (b.R - a.R) * t, a.G + (b.G - a.G) * t, a.B + (b.B - a.B) * t) end
	methods.lerp = methods.Lerp
	function methods.ToHSV(c) return toHSV(c) end
	function methods.ToHex(c)
		return string.format("%02x%02x%02x", round(clamp(c.R, 0, 1) * 255), round(clamp(c.G, 0, 1) * 255), round(clamp(c.B, 0, 1) * 255))
	end
	Color3 = {
		new = function(r, g, b) return new(r, g, b) end,
		fromRGB = function(r, g, b) return new((r or 0) / 255, (g or 0) / 255, (b or 0) / 255) end,
		fromHSV = fromHSV,
		toHSV = toHSV,
		fromHex = function(hex)
			hex = tostring(hex):gsub("^#", "")
			if #hex == 3 then hex = hex:sub(1, 1):rep(2) .. hex:sub(2, 2):rep(2) .. hex:sub(3, 3):rep(2) end
			if #hex ~= 6 then fail(2, "Color3.fromHex: invalid hex string '%s'", hex) end
			local n = tonumber(hex, 16)
			if not n then fail(2, "Color3.fromHex: invalid hex string '%s'", hex) end
			return new(math.floor(n / 65536) / 255, (math.floor(n / 256) % 256) / 255, (n % 256) / 255)
		end,
		_is = isC3, _raw = new,
	}
end

do -- BrickColor
	local BC = {}
	BC.__type = "BrickColor"
	local palette = {
		{ "White", 1, 242, 243, 243 }, { "Grey", 2, 161, 165, 162 }, { "Light yellow", 3, 249, 233, 153 },
		{ "Brick yellow", 5, 215, 197, 154 }, { "Light green (Mint)", 6, 194, 218, 184 }, { "Light reddish violet", 9, 232, 186, 200 },
		{ "Pastel Blue", 11, 128, 187, 219 }, { "Light orange brown", 12, 203, 132, 66 }, { "Nougat", 18, 204, 142, 105 },
		{ "Bright red", 21, 196, 40, 28 }, { "Med. reddish violet", 22, 196, 112, 160 }, { "Bright blue", 23, 13, 105, 172 },
		{ "Bright yellow", 24, 245, 205, 48 }, { "Earth orange", 25, 98, 71, 50 }, { "Black", 26, 27, 42, 53 },
		{ "Dark grey", 27, 109, 110, 108 }, { "Dark green", 28, 40, 127, 71 }, { "Medium green", 29, 161, 196, 140 },
		{ "Lig. Yellowich orange", 36, 243, 207, 155 }, { "Bright green", 37, 75, 151, 75 }, { "Dark orange", 38, 160, 95, 53 },
		{ "Light bluish violet", 39, 193, 202, 222 }, { "Transparent", 40, 236, 236, 236 }, { "Tr. Red", 41, 205, 84, 75 },
		{ "Tr. Lg blue", 42, 193, 223, 240 }, { "Tr. Blue", 43, 123, 182, 232 }, { "Tr. Yellow", 44, 247, 241, 141 },
		{ "Light blue", 45, 180, 210, 228 }, { "Tr. Flu. Reddish orange", 47, 217, 133, 108 }, { "Tr. Green", 48, 132, 182, 132 },
		{ "Tr. Flu. Green", 49, 248, 241, 132 }, { "Phosph. White", 50, 236, 232, 222 }, { "Light red", 100, 238, 196, 182 },
		{ "Medium red", 101, 218, 134, 122 }, { "Medium blue", 102, 110, 153, 202 }, { "Light grey", 103, 199, 193, 183 },
		{ "Bright violet", 104, 107, 50, 124 }, { "Br. yellowish orange", 105, 226, 155, 64 }, { "Bright orange", 106, 218, 133, 65 },
		{ "Bright bluish green", 107, 0, 143, 156 }, { "Earth yellow", 108, 104, 92, 67 }, { "Bright bluish violet", 110, 67, 84, 147 },
		{ "Tr. Brown", 111, 191, 183, 177 }, { "Medium bluish violet", 112, 104, 116, 172 }, { "Tr. Medi. reddish violet", 113, 229, 173, 200 },
		{ "Med. yellowish green", 115, 199, 210, 60 }, { "Med. bluish green", 116, 85, 165, 175 }, { "Light bluish green", 118, 183, 215, 213 },
		{ "Br. yellowish green", 119, 164, 189, 71 }, { "Lig. yellowish green", 120, 217, 228, 167 }, { "Med. yellowish orange", 121, 231, 172, 88 },
		{ "Br. reddish orange", 123, 211, 111, 76 }, { "Bright reddish violet", 124, 146, 57, 120 }, { "Light orange", 125, 234, 184, 146 },
		{ "Tr. Bright bluish violet", 126, 165, 165, 203 }, { "Gold", 127, 220, 188, 129 }, { "Dark nougat", 128, 174, 122, 89 },
		{ "Silver", 131, 156, 163, 168 }, { "Neon orange", 133, 213, 115, 61 }, { "Neon green", 134, 216, 221, 86 },
		{ "Sand blue", 135, 116, 134, 157 }, { "Sand violet", 136, 135, 124, 144 }, { "Medium orange", 137, 224, 152, 100 },
		{ "Sand yellow", 138, 149, 138, 115 }, { "Earth blue", 140, 32, 58, 86 }, { "Earth green", 141, 39, 70, 45 },
		{ "Tr. Flu. Blue", 143, 207, 226, 247 }, { "Sand blue metallic", 145, 121, 136, 161 }, { "Sand violet metallic", 146, 149, 142, 163 },
		{ "Sand yellow metallic", 147, 147, 135, 103 }, { "Dark grey metallic", 148, 87, 88, 87 }, { "Black metallic", 149, 22, 29, 50 },
		{ "Light grey metallic", 150, 171, 173, 172 }, { "Sand green", 151, 120, 144, 130 }, { "Sand red", 153, 149, 121, 119 },
		{ "Dark red", 154, 123, 46, 47 }, { "Tr. Flu. Yellow", 157, 255, 246, 123 }, { "Tr. Flu. Red", 158, 225, 164, 194 },
		{ "Gun metallic", 168, 117, 108, 98 }, { "Red flip/flop", 176, 151, 105, 91 }, { "Yellow flip/flop", 178, 180, 132, 85 },
		{ "Silver flip/flop", 179, 137, 135, 136 }, { "Curry", 180, 215, 169, 75 }, { "Fire Yellow", 190, 249, 214, 46 },
		{ "Flame yellowish orange", 191, 232, 171, 45 }, { "Reddish brown", 192, 105, 64, 40 }, { "Flame reddish orange", 193, 207, 96, 36 },
		{ "Medium stone grey", 194, 163, 162, 165 }, { "Royal blue", 195, 70, 103, 164 }, { "Dark Royal blue", 196, 35, 71, 139 },
		{ "Bright reddish lilac", 198, 142, 66, 133 }, { "Dark stone grey", 199, 99, 95, 98 }, { "Lemon metalic", 200, 130, 138, 93 },
		{ "Light stone grey", 208, 229, 228, 223 }, { "Dark Curry", 209, 176, 142, 68 }, { "Faded green", 210, 112, 149, 120 },
		{ "Turquoise", 211, 121, 181, 181 }, { "Light Royal blue", 212, 159, 195, 233 }, { "Medium Royal blue", 213, 108, 129, 183 },
		{ "Rust", 216, 144, 76, 42 }, { "Brown", 217, 124, 92, 70 }, { "Reddish lilac", 218, 150, 112, 159 },
		{ "Lilac", 219, 107, 98, 155 }, { "Light lilac", 220, 167, 169, 206 }, { "Bright purple", 221, 205, 98, 152 },
		{ "Light purple", 222, 228, 173, 200 }, { "Light pink", 223, 220, 144, 149 }, { "Light brick yellow", 224, 240, 213, 160 },
		{ "Warm yellowish orange", 225, 235, 184, 127 }, { "Cool yellow", 226, 253, 234, 141 }, { "Dove blue", 232, 125, 187, 221 },
		{ "Medium lilac", 268, 52, 43, 117 }, { "Slime green", 301, 80, 109, 84 }, { "Smoky grey", 302, 91, 93, 105 },
		{ "Dark blue", 303, 0, 16, 176 }, { "Parsley green", 304, 44, 101, 29 }, { "Steel blue", 305, 82, 124, 174 },
		{ "Storm blue", 306, 51, 88, 130 }, { "Lapis", 307, 16, 42, 220 }, { "Dark indigo", 308, 61, 21, 133 },
		{ "Sea green", 309, 52, 142, 64 }, { "Shamrock", 310, 91, 154, 76 }, { "Fossil", 311, 159, 161, 172 },
		{ "Mulberry", 312, 89, 34, 89 }, { "Forest green", 313, 31, 128, 29 }, { "Cadet blue", 314, 159, 173, 192 },
		{ "Electric blue", 315, 9, 137, 207 }, { "Eggplant", 316, 123, 0, 123 }, { "Moss", 317, 124, 156, 107 },
		{ "Artichoke", 318, 138, 171, 133 }, { "Sage green", 319, 185, 196, 177 }, { "Ghost grey", 320, 202, 203, 209 },
		{ "Lilac", 321, 167, 94, 155 }, { "Plum", 322, 123, 47, 123 }, { "Olivine", 323, 148, 190, 129 },
		{ "Laurel green", 324, 168, 189, 153 }, { "Quill grey", 325, 223, 223, 222 }, { "Crimson", 327, 151, 0, 0 },
		{ "Mint", 328, 177, 229, 166 }, { "Baby blue", 329, 152, 194, 219 }, { "Carnation pink", 330, 255, 152, 220 },
		{ "Persimmon", 331, 255, 89, 89 }, { "Maroon", 332, 117, 0, 0 }, { "Gold", 333, 239, 184, 56 },
		{ "Daisy orange", 334, 248, 217, 109 }, { "Pearl", 335, 231, 231, 236 }, { "Fog", 336, 199, 212, 228 },
		{ "Salmon", 337, 255, 148, 148 }, { "Terra Cotta", 338, 190, 104, 98 }, { "Cocoa", 339, 86, 36, 36 },
		{ "Wheat", 340, 241, 231, 199 }, { "Buttermilk", 341, 254, 243, 187 }, { "Mauve", 342, 224, 178, 208 },
		{ "Sunrise", 343, 212, 144, 189 }, { "Tawny", 344, 150, 85, 85 }, { "Rust", 345, 143, 76, 42 },
		{ "Cashmere", 346, 211, 190, 150 }, { "Khaki", 347, 226, 220, 188 }, { "Lily white", 348, 237, 234, 234 },
		{ "Seashell", 349, 233, 218, 218 }, { "Burgundy", 350, 136, 62, 62 }, { "Cork", 351, 188, 155, 93 },
		{ "Burlap", 352, 199, 172, 120 }, { "Beige", 353, 202, 191, 163 }, { "Oyster", 354, 187, 179, 178 },
		{ "Pine Cone", 355, 108, 88, 75 }, { "Fawn brown", 356, 160, 132, 79 }, { "Hurricane grey", 357, 149, 137, 136 },
		{ "Cloudy grey", 358, 171, 168, 158 }, { "Linen", 359, 175, 148, 131 }, { "Copper", 360, 150, 103, 102 },
		{ "Medium brown", 361, 86, 66, 54 }, { "Bronze", 362, 126, 104, 63 }, { "Flint", 363, 105, 102, 92 },
		{ "Dark taupe", 364, 90, 76, 66 }, { "Burnt Sienna", 365, 106, 57, 9 }, { "Institutional white", 1001, 248, 248, 248 },
		{ "Mid gray", 1002, 205, 205, 205 }, { "Really black", 1003, 17, 17, 17 }, { "Really red", 1004, 255, 0, 0 },
		{ "Deep orange", 1005, 255, 176, 0 }, { "Alder", 1006, 180, 128, 255 }, { "Dusty Rose", 1007, 163, 75, 75 },
		{ "Olive", 1008, 193, 190, 66 }, { "New Yeller", 1009, 255, 255, 0 }, { "Really blue", 1010, 0, 0, 255 },
		{ "Navy blue", 1011, 0, 32, 96 }, { "Deep blue", 1012, 33, 84, 185 }, { "Cyan", 1013, 4, 175, 236 },
		{ "CGA brown", 1014, 170, 85, 0 }, { "Magenta", 1015, 170, 0, 170 }, { "Pink", 1016, 255, 102, 204 },
		{ "Deep orange", 1017, 255, 175, 0 }, { "Teal", 1018, 18, 238, 212 }, { "Toothpaste", 1019, 0, 255, 255 },
		{ "Lime green", 1020, 0, 255, 0 }, { "Camo", 1021, 58, 125, 21 }, { "Grime", 1022, 127, 142, 100 },
		{ "Lavender", 1023, 140, 91, 159 }, { "Pastel light blue", 1024, 175, 221, 255 }, { "Pastel orange", 1025, 255, 201, 201 },
		{ "Pastel violet", 1026, 177, 167, 255 }, { "Pastel blue-green", 1027, 159, 243, 233 }, { "Pastel green", 1028, 204, 255, 204 },
		{ "Pastel yellow", 1029, 255, 255, 204 }, { "Pastel brown", 1030, 255, 204, 153 }, { "Royal purple", 1031, 98, 37, 209 },
		{ "Hot pink", 1032, 255, 0, 191 },
	}
	local byName, byNumber = {}, {}
	local function make(entry)
		local obj = setmetatable({
			Name = entry[1], Number = entry[2],
			Color = Color3.fromRGB(entry[3], entry[4], entry[5]),
			r = entry[3] / 255, g = entry[4] / 255, b = entry[5] / 255,
		}, BC)
		return obj
	end
	for _, entry in ipairs(palette) do
		local obj = make(entry)
		if not byName[entry[1]] then byName[entry[1]] = obj end
		if not byNumber[entry[2]] then byNumber[entry[2]] = obj end
	end
	BC.__index = function(_, k) fail(2, "%s is not a valid member of BrickColor", tostring(k)) end
	BC.__eq = function(a, b) return a.Number == b.Number end
	BC.__tostring = function(c) return c.Name end
	local function nearest(color)
		local best, bestD = byName["Medium stone grey"], math.huge
		for _, entry in ipairs(palette) do
			local obj = byName[entry[1]]
			local d = (obj.r - color.R) ^ 2 + (obj.g - color.G) ^ 2 + (obj.b - color.B) ^ 2
			if d < bestD then best, bestD = obj, d end
		end
		return best
	end
	BrickColor = {
		new = function(a, b, c)
			if type(a) == "string" then
				local obj = byName[a]
				if not obj then robloxWarn("BrickColor.new: unknown name '" .. a .. "', using Medium stone grey") return byName["Medium stone grey"] end
				return obj
			elseif type(a) == "number" and b == nil then
				return byNumber[a] or byName["Medium stone grey"]
			elseif type(a) == "number" then
				return nearest(Color3.new(a, b, c))
			elseif Color3._is(a) then
				return nearest(a)
			end
			fail(2, "BrickColor.new: unsupported arguments")
		end,
		palette = function(i) return byNumber[i] or byName["Medium stone grey"] end,
		random = function() return byName["Bright blue"] end,
		White = function() return byName["White"] end, Gray = function() return byName["Medium stone grey"] end,
		DarkGray = function() return byName["Dark stone grey"] end, Black = function() return byName["Black"] end,
		Red = function() return byName["Bright red"] end, Yellow = function() return byName["Bright yellow"] end,
		Green = function() return byName["Dark green"] end, Blue = function() return byName["Bright blue"] end,
		_nearest = nearest,
	}
end

do -- UDim / UDim2
	local UD = {}
	UD.__type = "UDim"
	local function newUD(s, o) return setmetatable({ Scale = s or 0, Offset = o or 0 }, UD) end
	UD.__index = function(_, k) fail(2, "%s is not a valid member of UDim", tostring(k)) end
	UD.__add = function(a, b) return newUD(a.Scale + b.Scale, a.Offset + b.Offset) end
	UD.__sub = function(a, b) return newUD(a.Scale - b.Scale, a.Offset - b.Offset) end
	UD.__eq = function(a, b) return a.Scale == b.Scale and a.Offset == b.Offset end
	UD.__tostring = function(u) return fmtNum(u.Scale) .. ", " .. fmtNum(u.Offset) end
	UDim = { new = function(s, o) return newUD(s, o) end }

	local U2 = {}
	U2.__type = "UDim2"
	local methods = {}
	local function newU2(x, y) return setmetatable({ X = x, Y = y }, U2) end
	U2.__index = function(u, k)
		local m = methods[k]
		if m then return m end
		if k == "Width" then return u.X elseif k == "Height" then return u.Y end
		fail(2, "%s is not a valid member of UDim2", tostring(k))
	end
	U2.__add = function(a, b) return newU2(a.X + b.X, a.Y + b.Y) end
	U2.__sub = function(a, b) return newU2(a.X - b.X, a.Y - b.Y) end
	U2.__eq = function(a, b) return a.X == b.X and a.Y == b.Y end
	U2.__tostring = function(u) return "{" .. tostring(u.X) .. "}, {" .. tostring(u.Y) .. "}" end
	function methods.Lerp(a, b, t)
		return newU2(newUD(a.X.Scale + (b.X.Scale - a.X.Scale) * t, a.X.Offset + (b.X.Offset - a.X.Offset) * t),
			newUD(a.Y.Scale + (b.Y.Scale - a.Y.Scale) * t, a.Y.Offset + (b.Y.Offset - a.Y.Offset) * t))
	end
	UDim2 = {
		new = function(a, b, c, d)
			if a ~= nil and type(a) == "table" then return newU2(a, b or newUD(0, 0)) end
			return newU2(newUD(a or 0, b or 0), newUD(c or 0, d or 0))
		end,
		fromScale = function(x, y) return newU2(newUD(x or 0, 0), newUD(y or 0, 0)) end,
		fromOffset = function(x, y) return newU2(newUD(0, x or 0), newUD(0, y or 0)) end,
		_is = function(v) return type(v) == "table" and getmetatable(v) == U2 end,
	}
end

do -- NumberRange, NumberSequence, ColorSequence, Rect, TweenInfo, PhysicalProperties, Region3, Ray, Font
	local function simpleType(name, fields)
		local mt = {}
		mt.__type = name
		mt.__index = function(_, k) fail(2, "%s is not a valid member of %s", tostring(k), name) end
		mt.__eq = function(a, b)
			for _, f in ipairs(fields) do
				if a[f] ~= b[f] then return false end
			end
			return true
		end
		mt.__tostring = function(v)
			local parts = {}
			for _, f in ipairs(fields) do parts[#parts + 1] = tostring(v[f]) end
			return table.concat(parts, " ")
		end
		return mt
	end

	local NRmt = simpleType("NumberRange", { "Min", "Max" })
	NumberRange = {
		new = function(a, b)
			if b == nil then b = a end
			if a > b then fail(2, "NumberRange.new: Min must be <= Max") end
			return setmetatable({ Min = a, Max = b }, NRmt)
		end,
	}

	local NSKmt = simpleType("NumberSequenceKeypoint", { "Time", "Value", "Envelope" })
	NumberSequenceKeypoint = {
		new = function(t, v, e) return setmetatable({ Time = t, Value = v, Envelope = e or 0 }, NSKmt) end,
	}
	local NSmt = simpleType("NumberSequence", { "Keypoints" })
	NSmt.__eq = function(a, b)
		if #a.Keypoints ~= #b.Keypoints then return false end
		for i, k in ipairs(a.Keypoints) do
			if k ~= b.Keypoints[i] then return false end
		end
		return true
	end
	NumberSequence = {
		new = function(a, b)
			local kps
			if type(a) == "number" then
				kps = { NumberSequenceKeypoint.new(0, a), NumberSequenceKeypoint.new(1, b or a) }
			else
				kps = a
			end
			return setmetatable({ Keypoints = kps }, NSmt)
		end,
	}

	local CSKmt = simpleType("ColorSequenceKeypoint", { "Time", "Value" })
	ColorSequenceKeypoint = { new = function(t, c) return setmetatable({ Time = t, Value = c }, CSKmt) end }
	local CSmt = simpleType("ColorSequence", { "Keypoints" })
	CSmt.__eq = NSmt.__eq
	ColorSequence = {
		new = function(a, b)
			local kps
			if Color3._is(a) then
				kps = { ColorSequenceKeypoint.new(0, a), ColorSequenceKeypoint.new(1, b or a) }
			else
				kps = a
			end
			return setmetatable({ Keypoints = kps }, CSmt)
		end,
	}

	local Rmt = simpleType("Rect", { "Min", "Max" })
	Rmt.__index = function(r, k)
		if k == "Width" then return r.Max.X - r.Min.X elseif k == "Height" then return r.Max.Y - r.Min.Y end
		fail(2, "%s is not a valid member of Rect", tostring(k))
	end
	Rect = {
		new = function(a, b, c, d)
			if type(a) == "number" then return setmetatable({ Min = Vector2.new(a, b), Max = Vector2.new(c, d) }, Rmt) end
			return setmetatable({ Min = a or Vector2.zero, Max = b or Vector2.zero }, Rmt)
		end,
	}

	local TImt = simpleType("TweenInfo", { "Time", "EasingStyle", "EasingDirection", "RepeatCount", "Reverses", "DelayTime" })
	TweenInfo = {
		new = function(t, style, dir, repeatCount, reverses, delayTime)
			return setmetatable({
				Time = t or 1,
				EasingStyle = style or Enum.EasingStyle.Quad,
				EasingDirection = dir or Enum.EasingDirection.Out,
				RepeatCount = repeatCount or 0,
				Reverses = reverses or false,
				DelayTime = delayTime or 0,
			}, TImt)
		end,
	}

	local PPmt = simpleType("PhysicalProperties", { "Density", "Friction", "Elasticity", "FrictionWeight", "ElasticityWeight" })
	PhysicalProperties = {
		new = function(a, b, c, d, e)
			if type(a) == "table" then -- material enum
				return setmetatable({ Density = 0.7, Friction = 0.3, Elasticity = 0.5, FrictionWeight = 1, ElasticityWeight = 1 }, PPmt)
			end
			return setmetatable({ Density = a or 1, Friction = b or 0.3, Elasticity = c or 0.5, FrictionWeight = d or 1, ElasticityWeight = e or 1 }, PPmt)
		end,
	}

	local R3mt = simpleType("Region3", { "CFrame", "Size" })
	local r3methods = {
		ExpandToGrid = function(r, res)
			local lo = (r.CFrame.Position - r.Size / 2)
			local hi = (r.CFrame.Position + r.Size / 2)
			lo = Vector3.new(math.floor(lo.X / res) * res, math.floor(lo.Y / res) * res, math.floor(lo.Z / res) * res)
			hi = Vector3.new(math.ceil(hi.X / res) * res, math.ceil(hi.Y / res) * res, math.ceil(hi.Z / res) * res)
			return Region3.new(lo, hi)
		end,
	}
	R3mt.__index = function(_, k)
		if r3methods[k] then return r3methods[k] end
		fail(2, "%s is not a valid member of Region3", tostring(k))
	end
	Region3 = {
		new = function(lo, hi)
			return setmetatable({ CFrame = CFrame.new((lo + hi) / 2), Size = hi - lo }, R3mt)
		end,
	}

	local RayMT = simpleType("Ray", { "Origin", "Direction" })
	local rayMethods = {}
	RayMT.__index = function(r, k)
		if rayMethods[k] then return rayMethods[k] end
		if k == "Unit" then return Ray.new(r.Origin, r.Direction.Unit) end
		fail(2, "%s is not a valid member of Ray", tostring(k))
	end
	function rayMethods.ClosestPoint(r, point)
		local dir = r.Direction.Unit
		local t = math.max(0, (point - r.Origin):Dot(dir))
		return r.Origin + dir * t
	end
	function rayMethods.Distance(r, point)
		return (rayMethods.ClosestPoint(r, point) - point).Magnitude
	end
	Ray = { new = function(o, d) return setmetatable({ Origin = o, Direction = d }, RayMT) end }

	local FontMT = simpleType("Font", { "Family", "Weight", "Style" })
	Font = {
		new = function(family, weight, style)
			return setmetatable({ Family = family, Weight = weight or Enum.FontWeight.Regular, Style = style or Enum.FontStyle.Normal }, FontMT)
		end,
		fromEnum = function(fontEnum)
			return setmetatable({ Family = "rbxasset://fonts/families/" .. tostring(fontEnum.Name) .. ".json", Weight = Enum.FontWeight.Regular, Style = Enum.FontStyle.Normal }, FontMT)
		end,
		fromName = function(name, weight, style)
			return setmetatable({ Family = "rbxasset://fonts/families/" .. tostring(name) .. ".json", Weight = weight or Enum.FontWeight.Regular, Style = style or Enum.FontStyle.Normal }, FontMT)
		end,
		fromId = function(id, weight, style)
			return setmetatable({ Family = "rbxassetid://" .. tostring(id), Weight = weight or Enum.FontWeight.Regular, Style = style or Enum.FontStyle.Normal }, FontMT)
		end,
	}
end

do -- Random: deterministic xorshift-style generator
	local RND = {}
	RND.__type = "Random"
	RND.__index = RND
	local seedCounter = 12345
	local function nextU32(self)
		-- xorshift32 on the state, then mix (deterministic, decent for tests)
		local x = self._state
		x = bit32.bxor(x, bit32.lshift(x, 13))
		x = bit32.bxor(x, bit32.rshift(x, 17))
		x = bit32.bxor(x, bit32.lshift(x, 5))
		self._state = x
		return x
	end
	local function nextFloat(self) -- [0, 1)
		return nextU32(self) / 4294967296
	end
	function RND:NextNumber(a, b)
		local f = nextFloat(self)
		if a == nil then return f end
		b = b or 0
		return a + (b - a) * f
	end
	function RND:NextInteger(a, b)
		if a > b then fail(2, "Random:NextInteger: min must be <= max") end
		local span = b - a + 1
		return a + nextU32(self) % span
	end
	function RND:NextUnitVector()
		local z = self:NextNumber(-1, 1)
		local t = self:NextNumber(0, 2 * math.pi)
		local r = math.sqrt(1 - z * z)
		return Vector3.new(r * math.cos(t), r * math.sin(t), z)
	end
	function RND:Shuffle(tbl)
		for i = #tbl, 2, -1 do
			local j = self:NextInteger(1, i)
			tbl[i], tbl[j] = tbl[j], tbl[i]
		end
	end
	function RND:Clone()
		return setmetatable({ _state = self._state, _seed = self._seed }, RND)
	end
	RND.__tostring = function(r) return "Random(seed=" .. tostring(r._seed) .. ")" end
	Random = {
		new = function(seed)
			if seed == nil then
				seedCounter += 7919
				seed = seedCounter
			end
			local s = math.floor(math.abs(seed)) % 4294967296
			if s == 0 then s = 0x9E3779B9 end
			local obj = setmetatable({ _state = s, _seed = seed }, RND)
			for _ = 1, 4 do nextU32(obj) end -- warm up
			return obj
		end,
	}
	shim._random = Random.new(42)
end

do -- Content (asset references; typeof == "Content")
	-- SourceType resolves lazily (Enum is built in section 5, after this block).
	local CMT = { __type = "Content" }
	CMT.__index = function(c, k)
		if k == "SourceType" then return Enum and Enum.ContentSourceType[rawget(c, "_sourceType")] or nil end
		return nil
	end
	CMT.__tostring = function(c) return "Content(" .. tostring(rawget(c, "Uri") or (rawget(c, "Object") and "Object") or "none") .. ")" end
	CMT.__eq = function(a, b) return rawget(a, "Uri") == rawget(b, "Uri") and rawget(a, "Object") == rawget(b, "Object") and rawget(a, "AssetId") == rawget(b, "AssetId") end
	local function makeContent(uri, object, assetId, sourceType)
		return setmetatable({ Uri = uri, Object = object, AssetId = assetId, _sourceType = sourceType }, CMT)
	end
	Content = {
		none = makeContent(nil, nil, nil, "None"),
		fromUri = function(uri)
			if type(uri) ~= "string" then fail(2, "Content.fromUri expects a string, got %s", nativeTypeof(uri)) end
			return makeContent(uri, nil, tonumber(string.match(uri, "(%d+)%s*$")), "Uri")
		end,
		fromAssetId = function(id)
			if type(id) ~= "number" then fail(2, "Content.fromAssetId expects a number, got %s", nativeTypeof(id)) end
			return makeContent("rbxassetid://" .. tostring(math.floor(id)), nil, math.floor(id), "Uri")
		end,
		fromObject = function(object)
			return makeContent(nil, object, nil, "Object")
		end,
	}
end

do -- RaycastParams / OverlapParams (mutable)
	local RPmt = { __type = "RaycastParams" }
	local rpMethods = {
		AddToFilter = function(self, v)
			if type(v) == "table" and getmetatable(v) == nil then
				for _, i in ipairs(v) do table.insert(self.FilterDescendantsInstances, i) end
			else
				table.insert(self.FilterDescendantsInstances, v)
			end
		end,
	}
	RPmt.__index = function(_, k) return rpMethods[k] end
	RPmt.__tostring = function() return "RaycastParams" end
	RaycastParams = {
		new = function()
			return setmetatable({
				FilterDescendantsInstances = {}, FilterType = Enum.RaycastFilterType.Exclude,
				IgnoreWater = false, CollisionGroup = "Default", RespectCanCollide = false, BruteForceAllSlow = false,
			}, RPmt)
		end,
	}
	local OPmt = { __type = "OverlapParams", __index = function(_, k) return rpMethods[k] end, __tostring = function() return "OverlapParams" end }
	OverlapParams = {
		new = function()
			return setmetatable({
				FilterDescendantsInstances = {}, FilterType = Enum.RaycastFilterType.Exclude,
				MaxParts = 0, CollisionGroup = "Default", RespectCanCollide = false, BruteForceAllSlow = false,
			}, OPmt)
		end,
	}
end

do -- DateTime (reads the virtual clock)
	local DT = {}
	DT.__type = "DateTime"
	local methods = {}
	local function epochNow()
		return shim.epochStart + (shim.clock - shim.clockStart)
	end
	local function fromMillis(ms)
		return setmetatable({ UnixTimestamp = math.floor(ms / 1000), UnixTimestampMillis = math.floor(ms) }, DT)
	end
	DT.__index = function(_, k)
		local m = methods[k]
		if m then return m end
		fail(2, "%s is not a valid member of DateTime", tostring(k))
	end
	DT.__eq = function(a, b) return a.UnixTimestampMillis == b.UnixTimestampMillis end
	DT.__lt = function(a, b) return a.UnixTimestampMillis < b.UnixTimestampMillis end
	DT.__le = function(a, b) return a.UnixTimestampMillis <= b.UnixTimestampMillis end
	DT.__tostring = function(d) return methods.ToIsoDate(d) end
	local function tableOf(d, utc)
		local t = os.date(utc and "!*t" or "*t", d.UnixTimestamp)
		return { Year = t.year, Month = t.month, Day = t.day, Hour = t.hour, Minute = t.min, Second = t.sec, Millisecond = d.UnixTimestampMillis % 1000 }
	end
	function methods.ToUniversalTime(d) return tableOf(d, true) end
	function methods.ToLocalTime(d) return tableOf(d, false) end
	function methods.ToIsoDate(d) return os.date("!%Y-%m-%dT%H:%M:%SZ", d.UnixTimestamp) end
	local function convertFormat(fmt)
		-- subset of Roblox's Unicode date patterns -> os.date
		local map = { YYYY = "%Y", YY = "%y", MMMM = "%B", MMM = "%b", MM = "%m", DD = "%d", HH = "%H", hh = "%I", mm = "%M", ss = "%S", A = "%p", dddd = "%A", ddd = "%a", ZZ = "+0000", Z = "+00:00" }
		return (fmt:gsub("(%a+)", function(tok) return map[tok] or tok end))
	end
	function methods.FormatUniversalTime(d, fmt) return os.date("!" .. convertFormat(fmt), d.UnixTimestamp) end
	function methods.FormatLocalTime(d, fmt) return os.date(convertFormat(fmt), d.UnixTimestamp) end
	DateTime = {
		now = function() return fromMillis(epochNow() * 1000) end,
		fromUnixTimestamp = function(s) return fromMillis(s * 1000) end,
		fromUnixTimestampMillis = function(ms) return fromMillis(ms) end,
		fromUniversalTime = function(y, mo, d, h, mi, s, ms)
			local t = os.time({ year = y or 1970, month = mo or 1, day = d or 1, hour = h or 0, min = mi or 0, sec = s or 0 })
			-- os.time interprets as local; correct to UTC using the offset at that instant
			local utcT = os.time(os.date("!*t", t))
			local offset = utcT - t
			return fromMillis((t - offset) * 1000 + (ms or 0))
		end,
		fromLocalTime = function(y, mo, d, h, mi, s, ms)
			local t = os.time({ year = y or 1970, month = mo or 1, day = d or 1, hour = h or 0, min = mi or 0, sec = s or 0 })
			return fromMillis(t * 1000 + (ms or 0))
		end,
		fromIsoDate = function(iso)
			local y, mo, d, h, mi, s = tostring(iso):match("^(%d+)%-(%d+)%-(%d+)T(%d+):(%d+):(%d+)")
			if not y then return nil end
			return DateTime.fromUniversalTime(tonumber(y), tonumber(mo), tonumber(d), tonumber(h), tonumber(mi), tonumber(s))
		end,
		_epochNow = epochNow,
	}
end

---- SECTION 5: Enum -----------------------------------------------------------------------

do
	-- Predefined item lists (value = index-1 unless given as {name, value}).  Unknown enums and
	-- unknown items are created on demand unless shim.strictEnums is true.
	local defs = {
		PartType = { "Ball", "Block", "Cylinder", "Wedge", "CornerWedge" },
		Material = {
			{ "Plastic", 256 }, { "Wood", 512 }, { "Slate", 800 }, { "Concrete", 816 }, { "CorrodedMetal", 1040 },
			{ "DiamondPlate", 1056 }, { "Foil", 1072 }, { "Grass", 1280 }, { "Ice", 1536 }, { "Marble", 784 },
			{ "Granite", 832 }, { "Brick", 848 }, { "Pebble", 864 }, { "Sand", 1296 }, { "Fabric", 1312 },
			{ "SmoothPlastic", 272 }, { "Metal", 1088 }, { "WoodPlanks", 528 }, { "Cobblestone", 880 }, { "Air", 1792 },
			{ "Water", 2048 }, { "Rock", 896 }, { "Glacier", 1552 }, { "Snow", 1600 }, { "Sandstone", 912 },
			{ "Mud", 1344 }, { "Basalt", 788 }, { "Ground", 1360 }, { "CrackedLava", 1372 }, { "Neon", 288 },
			{ "Glass", 1568 }, { "Asphalt", 1376 }, { "LeafyGrass", 1284 }, { "Salt", 1392 }, { "Limestone", 820 },
			{ "Pavement", 836 }, { "ForceField", 1584 }, { "Cardboard", 2304 }, { "Carpet", 2305 }, { "CeramicTiles", 2306 },
			{ "ClayRoofTiles", 2307 }, { "RoofShingles", 2308 }, { "Leather", 2309 }, { "Plaster", 2310 }, { "Rubber", 2311 },
		},
		NormalId = { "Right", "Top", "Back", "Left", "Bottom", "Front" },
		Axis = { "X", "Y", "Z" },
		EasingStyle = { "Linear", "Sine", "Back", "Quad", "Quart", "Quint", "Bounce", "Elastic", "Exponential", "Circular", "Cubic" },
		EasingDirection = { "In", "Out", "InOut" },
		PlaybackState = { "Begin", "Delayed", "Playing", "Paused", "Completed", "Cancelled" },
		TweenStatus = { "Canceled", "Completed" },
		RaycastFilterType = { { "Exclude", 0 }, { "Include", 1 }, { "Blacklist", 0 }, { "Whitelist", 1 } },
		CameraType = { "Fixed", "Watch", "Attach", "Track", "Follow", "Custom", "Scriptable", "Orbital" },
		HumanoidStateType = { { "FallingDown", 0 }, { "Ragdoll", 1 }, { "GettingUp", 2 }, { "Jumping", 3 }, { "Swimming", 4 }, { "Freefall", 5 }, { "Flying", 6 }, { "Landed", 7 }, { "Running", 8 }, { "RunningNoPhysics", 10 }, { "StrafingNoPhysics", 11 }, { "Climbing", 12 }, { "Seated", 13 }, { "PlatformStanding", 14 }, { "Dead", 15 }, { "Physics", 16 }, { "None", 18 } },
		HumanoidRigType = { "R6", "R15" },
		HumanoidDisplayDistanceType = { "Viewer", "Subject", "None" },
		NameOcclusion = { "OccludeAll", "EnemyOcclusion", "NoOcclusion" },
		UserInputType = { "MouseButton1", "MouseButton2", "MouseButton3", "MouseWheel", "MouseMovement", "Touch", "Keyboard", "Focus", "Accelerometer", "Gyro", "Gamepad1", "Gamepad2", "Gamepad3", "Gamepad4", "Gamepad5", "Gamepad6", "Gamepad7", "Gamepad8", "TextInput", "InputMethod", { "None", 21 } },
		UserInputState = { "Begin", "Change", "End", "Cancel", "None" },
		ContextActionPriority = { { "Low", 1000 }, { "Medium", 2000 }, { "Default", 2000 }, { "High", 3000 } },
		ContextActionResult = { { "Pass", 1 }, { "Sink", 0 } },
		KeyCode = {
			{ "Unknown", 0 }, { "Backspace", 8 }, { "Tab", 9 }, { "Clear", 12 }, { "Return", 13 }, { "Pause", 19 }, { "Escape", 27 }, { "Space", 32 },
			{ "QuotedDouble", 34 }, { "Hash", 35 }, { "Dollar", 36 }, { "Percent", 37 }, { "Ampersand", 38 }, { "Quote", 39 }, { "LeftParenthesis", 40 }, { "RightParenthesis", 41 },
			{ "Asterisk", 42 }, { "Plus", 43 }, { "Comma", 44 }, { "Minus", 45 }, { "Period", 46 }, { "Slash", 47 },
			{ "Zero", 48 }, { "One", 49 }, { "Two", 50 }, { "Three", 51 }, { "Four", 52 }, { "Five", 53 }, { "Six", 54 }, { "Seven", 55 }, { "Eight", 56 }, { "Nine", 57 },
			{ "Colon", 58 }, { "Semicolon", 59 }, { "LessThan", 60 }, { "Equals", 61 }, { "GreaterThan", 62 }, { "Question", 63 }, { "At", 64 },
			{ "LeftBracket", 91 }, { "BackSlash", 92 }, { "RightBracket", 93 }, { "Caret", 94 }, { "Underscore", 95 }, { "Backquote", 96 },
			{ "A", 97 }, { "B", 98 }, { "C", 99 }, { "D", 100 }, { "E", 101 }, { "F", 102 }, { "G", 103 }, { "H", 104 }, { "I", 105 }, { "J", 106 }, { "K", 107 }, { "L", 108 }, { "M", 109 },
			{ "N", 110 }, { "O", 111 }, { "P", 112 }, { "Q", 113 }, { "R", 114 }, { "S", 115 }, { "T", 116 }, { "U", 117 }, { "V", 118 }, { "W", 119 }, { "X", 120 }, { "Y", 121 }, { "Z", 122 },
			{ "LeftCurly", 123 }, { "Pipe", 124 }, { "RightCurly", 125 }, { "Tilde", 126 }, { "Delete", 127 },
			{ "KeypadZero", 256 }, { "KeypadOne", 257 }, { "KeypadTwo", 258 }, { "KeypadThree", 259 }, { "KeypadFour", 260 }, { "KeypadFive", 261 }, { "KeypadSix", 262 }, { "KeypadSeven", 263 }, { "KeypadEight", 264 }, { "KeypadNine", 265 },
			{ "KeypadPeriod", 266 }, { "KeypadDivide", 267 }, { "KeypadMultiply", 268 }, { "KeypadMinus", 269 }, { "KeypadPlus", 270 }, { "KeypadEnter", 271 }, { "KeypadEquals", 272 },
			{ "Up", 273 }, { "Down", 274 }, { "Right", 275 }, { "Left", 276 }, { "Insert", 277 }, { "Home", 278 }, { "End", 279 }, { "PageUp", 280 }, { "PageDown", 281 },
			{ "F1", 282 }, { "F2", 283 }, { "F3", 284 }, { "F4", 285 }, { "F5", 286 }, { "F6", 287 }, { "F7", 288 }, { "F8", 289 }, { "F9", 290 }, { "F10", 291 }, { "F11", 292 }, { "F12", 293 },
			{ "NumLock", 300 }, { "CapsLock", 301 }, { "ScrollLock", 302 }, { "RightShift", 303 }, { "LeftShift", 304 }, { "RightControl", 305 }, { "LeftControl", 306 }, { "RightAlt", 307 }, { "LeftAlt", 308 },
			{ "RightMeta", 309 }, { "LeftMeta", 310 }, { "LeftSuper", 311 }, { "RightSuper", 312 }, { "Mode", 313 }, { "Compose", 314 }, { "Help", 315 }, { "Print", 316 }, { "SysReq", 317 }, { "Break", 318 }, { "Menu", 319 }, { "Power", 320 }, { "Euro", 321 }, { "Undo", 322 },
			{ "World0", 160 }, { "World1", 161 }, { "World2", 162 }, { "World3", 163 },
			{ "ButtonX", 1000 }, { "ButtonY", 1001 }, { "ButtonA", 1002 }, { "ButtonB", 1003 }, { "ButtonR1", 1004 }, { "ButtonL1", 1005 }, { "ButtonR2", 1006 }, { "ButtonL2", 1007 },
			{ "ButtonR3", 1008 }, { "ButtonL3", 1009 }, { "ButtonStart", 1010 }, { "ButtonSelect", 1011 }, { "DPadLeft", 1012 }, { "DPadRight", 1013 }, { "DPadUp", 1014 }, { "DPadDown", 1015 },
			{ "Thumbstick1", 1016 }, { "Thumbstick2", 1017 },
		},
		ModelStreamingMode = { "Default", "Atomic", "Persistent", "PersistentPerPlayer", "Nonatomic" },
		VelocityConstraintMode = { "Line", "Plane", "Vector" },
		OrientationAlignmentMode = { "OneAttachment", "TwoAttachment" },
		PositionAlignmentMode = { "OneAttachment", "TwoAttachment" },
		ActuatorRelativeTo = { "Attachment0", "Attachment1", "World" },
		Font = { "Legacy", "Arial", "ArialBold", "SourceSans", "SourceSansBold", "SourceSansSemibold", "SourceSansLight", "SourceSansItalic", "Bodoni", "Garamond", "Cartoon", "Code", "Highway", "SciFi", "Arcade", "Fantasy", "Antique", "Gotham", "GothamMedium", "GothamBold", "GothamBlack", "AmaticSC", "Bangers", "Creepster", "DenkOne", "Fondamento", "FredokaOne", "GrenzeGotisch", "IndieFlower", "JosefinSans", "Jura", "Kalam", "LuckiestGuy", "Merriweather", "Michroma", "Nunito", "Oswald", "PatrickHand", "PermanentMarker", "Roboto", "RobotoCondensed", "RobotoMono", "Sarpanch", "SpecialElite", "TitilliumWeb", "Ubuntu", "BuilderSans", "BuilderSansMedium", "BuilderSansBold", "BuilderSansExtraBold", { "Unknown", 100 } },
		FontWeight = { { "Thin", 100 }, { "ExtraLight", 200 }, { "Light", 300 }, { "Regular", 400 }, { "Medium", 500 }, { "SemiBold", 600 }, { "Bold", 700 }, { "ExtraBold", 800 }, { "Heavy", 900 } },
		FontStyle = { "Normal", "Italic" },
		TextXAlignment = { "Left", "Right", "Center" },
		TextYAlignment = { "Top", "Center", "Bottom" },
		TextTruncate = { "None", "AtEnd", "SplitWord" },
		ScreenInsets = { "None", "DeviceSafeInsets", "CoreUISafeInsets", "TopbarSafeInsets" },
		ZIndexBehavior = { "Global", "Sibling" },
		SizeConstraint = { "RelativeXY", "RelativeXX", "RelativeYY" },
		AutomaticSize = { "None", "X", "Y", "XY" },
		FillDirection = { "Horizontal", "Vertical" },
		HorizontalAlignment = { "Center", "Left", "Right" },
		VerticalAlignment = { "Center", "Top", "Bottom" },
		SortOrder = { "Name", "Custom", "LayoutOrder" },
		ScaleType = { "Stretch", "Slice", "Tile", "Fit", "Crop" },
		ApplyStrokeMode = { "Contextual", "Border" },
		LineJoinMode = { "Round", "Bevel", "Miter" },
		CoreGuiType = { "PlayerList", "Health", "Backpack", "Chat", "All", "EmotesMenu", "SelfView", "Captures" },
		SelectionBehavior = { "Escape", "Stop" },
		ScrollingDirection = { { "X", 1 }, { "Y", 2 }, { "XY", 4 } },
		ElasticBehavior = { "WhenScrollable", "Always", "Never" },
		ScrollBarInset = { "None", "ScrollBar", "Always" },
		CollisionFidelity = { "Default", "Hull", "Box", "PreciseConvexDecomposition" },
		FluidFidelity = { "Automatic", "UseCollisionGeometry", "UsePreciseGeometry" },
		RenderFidelity = { "Automatic", "Precise", "Performance" },
		ParticleOrientation = { "FacingCamera", "FacingCameraWorldUp", "VelocityParallel", "VelocityPerpendicular" },
		ParticleEmitterShape = { "Box", "Sphere", "Cylinder", "Disc" },
		RollOffMode = { "Inverse", "Linear", "LinearSquare", "InverseTapered" },
		DeviceType = { "Unknown", "Desktop", "Tablet", "Phone" },
		Platform = { "Windows", "OSX", "IOS", "Android", "XBoxOne", "PS4", "PS3", "XBox360", "WiiU", "NX", "Ouya", "AndroidTV", "Chromecast", "Linux", "SteamOS", "WebOS", "DOS", "BeOS", "UWP", "PS5", { "None", 20 } },
		MembershipType = { "None", "BuildersClub", "TurboBuildersClub", "OutrageousBuildersClub", "Premium" },
		ProductPurchaseDecision = { "NotProcessedYet", "PurchaseGranted" },
		InfoType = { "Asset", "Product", "GamePass", "Subscription", "Bundle" },
		DataStoreRequestType = { "GetAsync", "SetIncrementAsync", "UpdateAsync", "GetSortedAsync", "SetIncrementSortedAsync", "OnUpdate", "GetVersionAsync", "ListAsync", "RemoveVersionAsync" },
		PathStatus = { "Success", "ClosestNoPath", "ClosestOutOfRange", "FailStartNotEmpty", "FailFinishNotEmpty", "NoPath" },
		PathWaypointAction = { "Walk", "Jump", "Custom" },
		MouseBehavior = { "Default", "LockCenter", "LockCurrentPosition" },
		CurrencyType = { "Default", "Robux", "Tix" },
		Technology = { "Legacy", "Voxel", "Compatibility", "ShadowMap", "Future", "Unified" },
		AnimationPriority = { "Idle", "Movement", "Action", "Action2", "Action3", "Action4", { "Core", 1000 } },
		RotationOrder = { "XYZ", "XZY", "YZX", "YXZ", "ZXY", "ZYX" },
		SurfaceType = { "Smooth", "Glue", "Weld", "Studs", "Inlet", "Universal", "Hinge", "Motor", "SteppingMotor", "SmoothNoOutlines" },
		TextChatMessageStatus = { "Unknown", "Success", "Sending", "TextFilterFailed", "Floodchecked", "InvalidPrivacySettings", "InvalidTextChannelPermissions", "MessageTooLong" },
		ChatVersion = { "LegacyChatService", "TextChatService" },
		ThumbnailType = { "HeadShot", "AvatarBust", "AvatarThumbnail" },
		ThumbnailSize = { "Size48x48", "Size180x180", "Size420x420", "Size60x60", "Size100x100", "Size150x150", "Size352x352" },
		Limb = { "Head", "Torso", "LeftArm", "RightArm", "LeftLeg", "RightLeg", "Unknown" },
		SignalBehavior = { "Default", "Immediate", "Deferred", "AncestryDeferred" },
		StreamingIntegrityMode = { "Default", "Disabled", "MinimumRadiusPause", "PauseOutsideLoadedArea" },
		InputType = { "NoInput", "Constant", "Sin" },
		AlignType = { "PrimaryAxisParallel", "PrimaryAxisPerpendicular", "PrimaryAxisLookAt", "AllAxes", "Parallel", "Perpendicular" },
		TextFilterContext = { "PublicChat", "PrivateChat" },
		HttpContentType = { "ApplicationJson", "ApplicationXml", "ApplicationUrlEncoded", "TextPlain", "TextXml" },
		AdornCullingMode = { "Automatic", "Never" },
		HighlightDepthMode = { "AlwaysOnTop", "Occluded" },
		ResamplerMode = { "Default", "Pixelated" },
		ButtonStyle = { "Custom", "RobloxButtonDefault", "RobloxButton", "RobloxRoundButton", "RobloxRoundDefaultButton", "RobloxRoundDropdownButton" },
		FrameStyle = { "Custom", "ChatBlue", "RobloxSquare", "RobloxRound", "ChatGreen", "ChatRed", "DropShadow" },
		TableMajorAxis = { "RowMajor", "ColumnMajor" },
		StartCorner = { "TopLeft", "TopRight", "BottomLeft", "BottomRight" },
		DialogPurpose = { "Quest", "Help", "Shop" },
		DialogTone = { "Neutral", "Friendly", "Enemy" },
		ExplosionType = { "NoCraters", "Craters" },
		LoadCharacterLayeredClothing = { "Default", "Disabled", "Enabled" },
		DeveloperMemoryTag = { "Internal", "HttpCache", "Instances", "Signals", "LuaHeap", "Script", "PhysicsCollision", "PhysicsParts", "GraphicsSolidModels", "GraphicsMeshParts", "GraphicsParticles", "GraphicsParts", "GraphicsSpatialHash", "GraphicsTerrain", "GraphicsTexture", "GraphicsTextureCharacter", "Sounds", "StreamingSounds", "TerrainVoxels", "Gui", "Animation", "Navigation" },
		DragDetectorDragStyle = { "TranslateLine", "TranslatePlane", "TranslateLineOrPlane", "TranslateViewPlane", "RotateAxis", "RotateTrackball", "Scriptable", "BestForDevice" },
		TriStateBoolean = { "Unknown", "True", "False" },
		SpecialKey = { "Insert", "Home", "End", "PageUp", "PageDown", "ChatHotkey" },
		NetworkOwnership = { "Automatic", "Manual" },
		ReverbType = { "NoReverb", "GenericReverb", "PaddedCell", "Room", "Bathroom", "LivingRoom", "StoneRoom", "Auditorium", "ConcertHall", "Cave", "Arena", "Hangar", "CarpettedHallway", "Hallway", "StoneCorridor", "Alley", "Forest", "City", "Mountains", "Quarry", "Plain", "ParkingLot", "SewerPipe", "UnderWater" },
		ListenerType = { "Camera", "CFrame", "ObjectPosition", "ObjectCFrame" },
		Style = { "AlternatingSupports", "BridgeStyleSupports", "NoSupports" },
		RunContext = { "Legacy", "Server", "Client", "Plugin" },
		SensorMode = { "Floor", "Ladder" },
	}

	local EnumItemMT = {}
	EnumItemMT.__type = "EnumItem"
	EnumItemMT.__index = function(item, k)
		if k == "IsA" then return function(_, t) return t == "EnumItem" end end
		fail(2, "%s is not a valid member of EnumItem", tostring(k))
	end
	EnumItemMT.__newindex = function() fail(2, "EnumItem is read-only") end
	EnumItemMT.__tostring = function(item) return "Enum." .. item.EnumType.Name .. "." .. item.Name end
	EnumItemMT.__lt = function(a, b) return a.Value < b.Value end
	EnumItemMT.__le = function(a, b) return a.Value <= b.Value end

	local EnumTypeMT = {}
	EnumTypeMT.__type = "Enum"
	local enumTypes = {}

	local function makeItem(enumType, name, value)
		local item = table.freeze(setmetatable({ Name = name, Value = value, EnumType = enumType }, EnumItemMT))
		local st = rawget(enumType, "_state")
		st.items[name] = item
		table.insert(st.list, item)
		st.byValue[value] = st.byValue[value] or item
		return item
	end

	local typeMethods = {
		GetEnumItems = function(enumType)
			return tcopy(rawget(enumType, "_state").list)
		end,
		FromName = function(enumType, name)
			return rawget(enumType, "_state").items[name]
		end,
		FromValue = function(enumType, value)
			return rawget(enumType, "_state").byValue[value]
		end,
	}
	EnumTypeMT.__index = function(enumType, k)
		local st = rawget(enumType, "_state")
		local item = st.items[k]
		if item then return item end
		local m = typeMethods[k]
		if m then return m end
		if k == "Name" then return st.name end
		if type(k) ~= "string" then fail(2, "Enum.%s: invalid key %s", st.name, tostring(k)) end
		if st.predefined and shim.strictEnums then
			fail(2, "%s is not a valid EnumItem of Enum.%s", k, st.name)
		end
		st.nextValue += 1
		return makeItem(enumType, k, st.nextValue)
	end
	EnumTypeMT.__newindex = function() fail(2, "Enum types are read-only") end
	EnumTypeMT.__tostring = function(enumType) return "Enum." .. rawget(enumType, "_state").name end

	local function getEnumType(name)
		local et = enumTypes[name]
		if et then return et end
		local def = defs[name]
		if not def and shim.strictEnums then fail(3, "%s is not a valid Enum", tostring(name)) end
		local st = { name = name, items = {}, list = {}, byValue = {}, nextValue = 999, predefined = def ~= nil }
		et = setmetatable({ _state = st, Name = name }, EnumTypeMT)
		enumTypes[name] = et
		if def then
			for i, entry in ipairs(def) do
				if type(entry) == "table" then makeItem(et, entry[1], entry[2]) else makeItem(et, entry, i - 1) end
			end
		end
		return et
	end

	Enum = setmetatable({}, {
		__type = "Enums",
		__index = function(_, name)
			if name == "GetEnums" then
				return function()
					local list = {}
					for n in pairs(defs) do list[#list + 1] = getEnumType(n) end
					table.sort(list, function(a, b) return rawget(a, "_state").name < rawget(b, "_state").name end)
					return list
				end
			end
			return getEnumType(name)
		end,
		__newindex = function() fail(2, "Enum is read-only") end,
		__tostring = function() return "Enums" end,
	})
	shim.strictEnums = false
	shim._isEnumItem = function(v) return type(v) == "table" and getmetatable(v) == EnumItemMT end
end

---- SECTION 6: Instance system ------------------------------------------------------------

local Inst = {}
shim._inst = Inst

local priv = setmetatable({}, { __mode = "k" }) -- instance -> internal state
Inst.priv = priv

local classes = {}       -- className -> { super, defaults, methods, getters, setters, events, isService }
local resolved = {}      -- className -> flattened lookup tables
local allMethodNames = {}
local eventNames = {}    -- union of all known event names

local function defclass(name, super, spec)
	spec = spec or {}
	spec.super = super
	spec.name = name
	spec.defaults = spec.defaults or {}
	spec.methods = spec.methods or {}
	spec.getters = spec.getters or {}
	spec.setters = spec.setters or {}
	spec.events = spec.events or {}
	classes[name] = spec
	resolved[name] = nil
	for m in pairs(spec.methods) do allMethodNames[m] = true end
	for _, e in ipairs(spec.events) do eventNames[e] = true end
	return spec
end
Inst.defclass = defclass

local function resolve(name)
	local r = resolved[name]
	if r then return r end
	local chain = {}
	local cur = name
	local unknown = false
	while cur do
		local c = classes[cur]
		if not c then
			unknown = true
			cur = "Instance"
			if not classes[cur] then break end
			c = classes[cur]
		end
		table.insert(chain, 1, c)
		cur = c.super
	end
	r = { name = name, methods = {}, getters = {}, setters = {}, defaults = {}, defaultOrder = {}, isA = {}, chain = chain, unknown = unknown, events = {} }
	for _, c in ipairs(chain) do
		r.isA[c.name] = true
		for k, v in pairs(c.methods) do r.methods[k] = v end
		for k, v in pairs(c.getters) do r.getters[k] = v end
		for k, v in pairs(c.setters) do r.setters[k] = v end
		for k, v in pairs(c.defaults) do
			if r.defaults[k] == nil then table.insert(r.defaultOrder, k) end
			r.defaults[k] = v
		end
		for _, e in ipairs(c.events) do r.events[e] = true end
		if c.onCreate then r.onCreate = r.onCreate or {} table.insert(r.onCreate, c.onCreate) end
	end
	r.isA[name] = true
	resolved[name] = r
	return r
end
Inst.resolve = resolve

local function isInstance(v)
	return type(v) == "table" and priv[v] ~= nil
end
Inst.isInstance = isInstance
instanceCheck = isInstance

local function st(inst, what)
	local s = priv[inst]
	if not s then fail(3, "%s expected an Instance, got %s", what or "argument", nativeTypeof(inst)) end
	return s
end

local function getFullName(inst)
	local s = priv[inst]
	local parts = {}
	while s do
		table.insert(parts, 1, s.name)
		s = s.parent and priv[s.parent] or nil
	end
	if parts[1] == "game" and #parts > 1 then table.remove(parts, 1) end
	return table.concat(parts, ".")
end

local NIL = {} -- sentinel for "property exists but is nil"

local function getEvent(s, name)
	local sig = s.events[name]
	if not sig then
		sig = Signal.new(s.className .. "." .. name)
		s.events[name] = sig
	end
	return sig
end
Inst.getEvent = getEvent

local function firePropertyChanged(inst, s, key, value)
	local sig = s.propSignals[key]
	if sig then sig:Fire() end
	local changed = s.events.Changed
	if changed then
		if s.cls.isA.ValueBase and key == "Value" then changed:Fire(value) else changed:Fire(key) end
	end
end
Inst.firePropertyChanged = firePropertyChanged

local function findChildByName(s, name)
	for _, child in ipairs(s.children) do
		if priv[child].name == name then return child end
	end
	return nil
end

local InstanceMT = {}
InstanceMT.__type = "Instance"
InstanceMT.__metatable = "The metatable is locked"

InstanceMT.__index = function(inst, key)
	local s = priv[inst]
	local cls = s.cls
	local m = cls.methods[key]
	if m ~= nil then return m end
	local g = cls.getters[key]
	if g ~= nil then return g(inst, s) end
	local v = s.props[key]
	if v ~= nil then
		if v == NIL then return nil end
		return v
	end
	if key == "Parent" then return s.parent end
	if key == "Name" then return s.name end
	if key == "ClassName" then return s.className end
	if cls.events[key] or eventNames[key] then return getEvent(s, key) end
	if cls.defaults[key] ~= nil then return nil end
	if type(key) == "string" then
		local child = findChildByName(s, key)
		if child then return child end
		if allMethodNames[key] then
			fail(2, "%s is not a valid member of %s \"%s\"", key, s.className, getFullName(inst))
		end
	end
	return nil
end

local setParent -- forward

InstanceMT.__newindex = function(inst, key, value)
	local s = priv[inst]
	if key == "Parent" then
		setParent(inst, value)
		return
	elseif key == "Name" then
		if type(value) ~= "string" then value = tostring(value) end
		if s.name ~= value then
			s.name = value
			firePropertyChanged(inst, s, "Name", value)
		end
		return
	elseif key == "ClassName" then
		fail(2, "Unable to assign property ClassName. Property is read only")
	end
	local setter = s.cls.setters[key]
	if setter then
		setter(inst, s, value)
		return
	end
	local old = s.props[key]
	if old == NIL then old = nil end
	local stored = value
	if value == nil then stored = NIL end
	if old ~= value or (type(value) == "number" and value ~= value) then
		s.props[key] = stored
		firePropertyChanged(inst, s, key, value)
	end
end

InstanceMT.__tostring = function(inst)
	return priv[inst].name
end

local function setProp(inst, key, value)
	-- raw property write that still fires change signals (used by internal logic)
	local s = priv[inst]
	local old = s.props[key]
	if old == NIL then old = nil end
	s.props[key] = value == nil and NIL or value
	if old ~= value then firePropertyChanged(inst, s, key, value) end
end
Inst.setProp = setProp

local function rawProp(inst, key)
	local v = priv[inst].props[key]
	if v == NIL then return nil end
	return v
end
Inst.rawProp = rawProp

local game -- the current DataModel (set in section 7)

local function isInDataModel(inst)
	local s = priv[inst]
	while s do
		if s.isDataModel then return true end
		s = s.parent and priv[s.parent] or nil
	end
	return false
end
Inst.isInDataModel = isInDataModel

local function collectDescendants(inst, list)
	for _, child in ipairs(priv[inst].children) do
		table.insert(list, child)
		collectDescendants(child, list)
	end
	return list
end

local function fireAncestryHooks(inst, newParent) -- tags / collection service hooks are installed from section 7
	for _, hook in ipairs(Inst.ancestryHooks) do hook(inst, newParent) end
end
Inst.ancestryHooks = {}

setParent = function(inst, newParent)
	local s = priv[inst]
	if newParent ~= nil and not isInstance(newParent) then
		fail(3, "Parent must be an Instance or nil, got %s", nativeTypeof(newParent))
	end
	if s.destroyed then
		fail(3, "The Parent property of %s is locked, current parent: NULL, new parent %s", s.name, newParent and priv[newParent].name or "NULL")
	end
	if newParent == inst then fail(3, "Attempt to set %s as its own parent", s.name) end
	if newParent ~= nil then
		local p = priv[newParent]
		while p do
			if p == s then fail(3, "Attempt to set parent of %s to %s would result in circular reference", s.name, priv[newParent].name) end
			p = p.parent and priv[p.parent] or nil
		end
	end
	local old = s.parent
	if old == newParent then return end
	local wasInDM = isInDataModel(inst)
	local subtree = collectDescendants(inst, { inst })

	if old then
		local os_ = priv[old]
		-- DescendantRemoving fires on every old ancestor before removal
		local anc = old
		while anc do
			local as = priv[anc]
			local sig = as.events.DescendantRemoving
			if sig then
				for _, d in ipairs(subtree) do sig:Fire(d) end
			end
			anc = as.parent
		end
		for i, c in ipairs(os_.children) do
			if c == inst then table.remove(os_.children, i) break end
		end
	end
	s.parent = newParent
	if newParent then table.insert(priv[newParent].children, inst) end

	if old then
		local sig = priv[old].events.ChildRemoved
		if sig then sig:Fire(inst) end
	end
	if newParent then
		local ps = priv[newParent]
		local sig = ps.events.ChildAdded
		if sig then sig:Fire(inst) end
		local anc = newParent
		while anc do
			local as = priv[anc]
			local dsig = as.events.DescendantAdded
			if dsig then
				for _, d in ipairs(subtree) do dsig:Fire(d) end
			end
			anc = as.parent
		end
		-- WaitForChild waiters
		if ps.waiters and #ps.waiters > 0 then
			for i = #ps.waiters, 1, -1 do
				local w = ps.waiters[i]
				if w.name == s.name then
					table.remove(ps.waiters, i)
					w.done = true
					schedule(now(), "resume", w.thread, { inst }, 1)
				end
			end
		end
	end
	for _, d in ipairs(subtree) do
		local ds = priv[d]
		local asig = ds.events.AncestryChanged
		if asig then asig:Fire(d, priv[d].parent) end
	end
	firePropertyChanged(inst, s, "Parent", newParent)
	local nowInDM = isInDataModel(inst)
	if wasInDM ~= nowInDM then
		for _, d in ipairs(subtree) do fireAncestryHooks(d, nowInDM) end
	end
end
Inst.setParent = setParent

local function applyDefaults(inst, cls)
	local s = priv[inst]
	for _, k in ipairs(cls.defaultOrder) do
		local v = cls.defaults[k]
		if type(v) == "function" then v = v(inst) end
		if v == nil then v = NIL end
		s.props[k] = v
	end
end

local function new(className, parent, opts)
	if type(className) ~= "string" then fail(3, "Instance.new expects a class name string, got %s", nativeTypeof(className)) end
	local cls = resolve(className)
	if cls.unknown then shim.unknownClasses[className] = true end
	local inst = setmetatable({}, InstanceMT)
	local s = {
		className = className, name = className, parent = nil, children = {}, props = {}, attrs = {},
		tags = {}, events = {}, propSignals = {}, attrSignals = {}, cls = cls, destroyed = false,
	}
	priv[inst] = s
	applyDefaults(inst, cls)
	if cls.onCreate then
		for _, fn in ipairs(cls.onCreate) do fn(inst, s, opts) end
	end
	if parent ~= nil then setParent(inst, parent) end
	return inst
end
Inst.new = new

local Instance = {
	new = function(className, parent) return new(className, parent) end,
	fromExisting = function(inst)
		local c = inst:Clone()
		return c
	end,
}

-- generic Instance class -------------------------------------------------------------------
local function matchClass(child, className, whichIsA)
	local cs = priv[child]
	if whichIsA then return cs.cls.isA[className] == true end
	return cs.className == className
end

local function destroyInstance(inst)
	local s = priv[inst]
	if s.destroyed then return end
	local sig = s.events.Destroying
	if sig then sig:Fire() end
	if s.parent then setParent(inst, nil) end
	s.destroyed = true
	local children = tcopy(s.children)
	for _, c in ipairs(children) do destroyInstance(c) end
	for _, hook in ipairs(Inst.destroyHooks) do hook(inst, s) end
	for _, ev in pairs(s.events) do ev:DisconnectAll() end
	for _, ev in pairs(s.propSignals) do ev:DisconnectAll() end
	for _, ev in pairs(s.attrSignals) do ev:DisconnectAll() end
end
Inst.destroyHooks = {}
Inst.destroy = destroyInstance

local function cloneInstance(inst, parentOfClone)
	-- Deep copy. Instance-valued properties (PrimaryPart, Part0/Part1, ObjectValue.Value, Adornee,
	-- Attachment0/1, ...) that point inside the cloned subtree are remapped to the copies, like the engine.
	local map = {}
	local function cloneRec(src)
		local s = priv[src]
		if s.props.Archivable == false then return nil end
		local copy = new(s.className)
		map[src] = copy
		local cs = priv[copy]
		cs.name = s.name
		for k, v in pairs(s.props) do cs.props[k] = v end
		for k, v in pairs(s.attrs) do cs.attrs[k] = v end
		for k, v in pairs(s.tags) do cs.tags[k] = v end
		for _, hook in ipairs(Inst.cloneHooks) do hook(src, copy) end
		for _, child in ipairs(s.children) do
			local cc = cloneRec(child)
			if cc then setParent(cc, copy) end
		end
		return copy
	end
	local copy = cloneRec(inst)
	if not copy then return nil end
	for _, cp in pairs(map) do
		local props = priv[cp].props
		for k, v in pairs(props) do
			if v ~= NIL and type(v) == "table" and priv[v] and map[v] then props[k] = map[v] end
		end
	end
	if parentOfClone then setParent(copy, parentOfClone) end
	return copy
end
Inst.cloneHooks = {}
Inst.clone = cloneInstance

defclass("Instance", nil, {
	defaults = { Archivable = true },
	events = { "Changed", "ChildAdded", "ChildRemoved", "DescendantAdded", "DescendantRemoving", "AncestryChanged", "Destroying", "AttributeChanged" },
	methods = {
		FindFirstChild = function(self, name, recursive)
			local s = st(self, "FindFirstChild")
			if type(name) ~= "string" then fail(2, "FindFirstChild expects a string name, got %s", nativeTypeof(name)) end
			local c = findChildByName(s, name)
			if c or not recursive then return c end
			for _, d in ipairs(collectDescendants(self, {})) do
				if priv[d].name == name then return d end
			end
			return nil
		end,
		FindFirstChildOfClass = function(self, className)
			for _, c in ipairs(st(self).children) do
				if matchClass(c, className, false) then return c end
			end
			return nil
		end,
		FindFirstChildWhichIsA = function(self, className, recursive)
			for _, c in ipairs(st(self).children) do
				if matchClass(c, className, true) then return c end
			end
			if recursive then
				for _, d in ipairs(collectDescendants(self, {})) do
					if matchClass(d, className, true) then return d end
				end
			end
			return nil
		end,
		FindFirstDescendant = function(self, name)
			for _, d in ipairs(collectDescendants(self, {})) do
				if priv[d].name == name then return d end
			end
			return nil
		end,
		FindFirstAncestor = function(self, name)
			local p = st(self).parent
			while p do
				if priv[p].name == name then return p end
				p = priv[p].parent
			end
			return nil
		end,
		FindFirstAncestorOfClass = function(self, className)
			local p = st(self).parent
			while p do
				if priv[p].className == className then return p end
				p = priv[p].parent
			end
			return nil
		end,
		FindFirstAncestorWhichIsA = function(self, className)
			local p = st(self).parent
			while p do
				if priv[p].cls.isA[className] then return p end
				p = priv[p].parent
			end
			return nil
		end,
		WaitForChild = function(self, name, timeout)
			local s = st(self, "WaitForChild")
			if type(name) ~= "string" then fail(2, "WaitForChild expects a string name, got %s", nativeTypeof(name)) end
			local c = findChildByName(s, name)
			if c then return c end
			local co = coroutine.running()
			if co == mainThread then
				fail(2, "WaitForChild(\"%s\") on %s would yield the main test thread: the child does not exist. Create it first or call from task.spawn/it()", name, getFullName(self))
			end
			s.waiters = s.waiters or {}
			local waiter = { name = name, thread = co, done = false }
			table.insert(s.waiters, waiter)
			if timeout then
				task.delay(timeout, function()
					if waiter.done then return end
					waiter.done = true
					for i, w in ipairs(s.waiters) do
						if w == waiter then table.remove(s.waiters, i) break end
					end
					if coroutine.status(co) == "suspended" then resumeThread(co, nil) end
				end)
			end
			return coroutine.yield()
		end,
		GetChildren = function(self) return tcopy(st(self).children) end,
		GetDescendants = function(self) return collectDescendants(self, {}) end,
		IsA = function(self, className) return st(self).cls.isA[className] == true end,
		IsDescendantOf = function(self, other)
			local p = st(self).parent
			while p do
				if p == other then return true end
				p = priv[p].parent
			end
			return false
		end,
		IsAncestorOf = function(self, other)
			if not isInstance(other) then return false end
			local p = priv[other].parent
			while p do
				if p == self then return true end
				p = priv[p].parent
			end
			return false
		end,
		GetFullName = function(self) return getFullName(self) end,
		Destroy = function(self) destroyInstance(self) end,
		Remove = function(self) setParent(self, nil) end,
		Clone = function(self) return cloneInstance(self) end,
		ClearAllChildren = function(self)
			for _, c in ipairs(tcopy(st(self).children)) do destroyInstance(c) end
		end,
		GetAttribute = function(self, name) return st(self).attrs[name] end,
		SetAttribute = function(self, name, value)
			local s = st(self)
			if type(name) ~= "string" then fail(2, "SetAttribute expects a string name") end
			if type(value) == "function" or type(value) == "thread" or isInstance(value) then
				fail(2, "SetAttribute: %s is not a supported attribute type", nativeTypeof(value))
			end
			if type(value) == "table" and not (getmetatable(value) and rawget(getmetatable(value), "__type")) then
				fail(2, "SetAttribute: tables are not supported attribute values")
			end
			local old = s.attrs[name]
			if old == value then return end
			s.attrs[name] = value
			local sig = s.attrSignals[name]
			if sig then sig:Fire() end
			local ac = s.events.AttributeChanged
			if ac then ac:Fire(name) end
		end,
		GetAttributes = function(self) return tcopy(st(self).attrs) end,
		GetAttributeChangedSignal = function(self, name)
			local s = st(self)
			local sig = s.attrSignals[name]
			if not sig then
				sig = Signal.new(s.className .. ".Attribute." .. tostring(name))
				s.attrSignals[name] = sig
			end
			return sig
		end,
		GetPropertyChangedSignal = function(self, prop)
			local s = st(self)
			if type(prop) ~= "string" then fail(2, "GetPropertyChangedSignal expects a string") end
			local sig = s.propSignals[prop]
			if not sig then
				sig = Signal.new(s.className .. "." .. prop .. "Changed")
				s.propSignals[prop] = sig
			end
			return sig
		end,
		AddTag = function(self, tag) Inst.addTag(self, tag) end,
		RemoveTag = function(self, tag) Inst.removeTag(self, tag) end,
		HasTag = function(self, tag) return st(self).tags[tag] == true end,
		GetTags = function(self)
			local list = {}
			for t in pairs(st(self).tags) do list[#list + 1] = t end
			table.sort(list)
			return list
		end,
		GetDebugId = function(self) return tostring(self):sub(1, 8) end,
		IsPropertyModified = function() return false end,
		SetModifiedProperties = function() end,
		GetActor = function() return nil end,
		getChildren = function(self) return tcopy(st(self).children) end,
		findFirstChild = function(self, name, recursive) return self:FindFirstChild(name, recursive) end,
		isA = function(self, className) return st(self).cls.isA[className] == true end,
	},
})

-- tags ---------------------------------------------------------------------------------------
local tagRegistry = { byTag = {}, addedSignals = {}, removedSignals = {} }
Inst.tagRegistry = tagRegistry

local function tagSet(tag)
	local set = tagRegistry.byTag[tag]
	if not set then
		set = { list = {}, index = {} }
		tagRegistry.byTag[tag] = set
	end
	return set
end

function Inst.addTag(inst, tag)
	local s = st(inst, "AddTag")
	if type(tag) ~= "string" then fail(3, "AddTag expects a string tag") end
	if s.tags[tag] then return end
	s.tags[tag] = true
	local set = tagSet(tag)
	if not set.index[inst] then
		set.index[inst] = true
		table.insert(set.list, inst)
	end
	if isInDataModel(inst) then
		local sig = tagRegistry.addedSignals[tag]
		if sig then sig:Fire(inst) end
	end
end

function Inst.removeTag(inst, tag)
	local s = st(inst, "RemoveTag")
	if not s.tags[tag] then return end
	s.tags[tag] = nil
	local set = tagSet(tag)
	set.index[inst] = nil
	for i, v in ipairs(set.list) do
		if v == inst then table.remove(set.list, i) break end
	end
	if isInDataModel(inst) then
		local sig = tagRegistry.removedSignals[tag]
		if sig then sig:Fire(inst) end
	end
end

-- A clone keeps the source's tags (copied in cloneRec) and, like the engine, is reported by
-- CollectionService:GetTagged once it is in the DataModel: register it in the tag sets.
table.insert(Inst.cloneHooks, function(src, copy)
	local cs = priv[copy]
	for tag in pairs(cs.tags) do
		local set = tagSet(tag)
		if not set.index[copy] then
			set.index[copy] = true
			table.insert(set.list, copy)
		end
	end
end)

table.insert(Inst.ancestryHooks, function(inst, nowInDM)
	local s = priv[inst]
	for tag in pairs(s.tags) do
		local sig = nowInDM and tagRegistry.addedSignals[tag] or tagRegistry.removedSignals[tag]
		if sig then sig:Fire(inst) end
	end
end)

table.insert(Inst.destroyHooks, function(inst, s)
	for tag in pairs(s.tags) do
		local set = tagSet(tag)
		set.index[inst] = nil
		for i, v in ipairs(set.list) do
			if v == inst then table.remove(set.list, i) break end
		end
	end
end)

-- helpers shared by classes -----------------------------------------------------------------
local function degOrientation(cf)
	local rx, ry, rz = cf:ToOrientation()
	return Vector3.new(math.deg(rx), math.deg(ry), math.deg(rz))
end

local function partCorners(cf, size)
	local h = size / 2
	local corners = {}
	for _, sx in ipairs({ -1, 1 }) do
		for _, sy in ipairs({ -1, 1 }) do
			for _, sz in ipairs({ -1, 1 }) do
				corners[#corners + 1] = cf:PointToWorldSpace(Vector3.new(h.X * sx, h.Y * sy, h.Z * sz))
			end
		end
	end
	return corners
end

local function descendantParts(inst)
	local parts = {}
	for _, d in ipairs(collectDescendants(inst, {})) do
		if priv[d].cls.isA.BasePart then parts[#parts + 1] = d end
	end
	return parts
end
Inst.descendantParts = descendantParts

local function boundingBox(parts)
	if #parts == 0 then return CFrame.identity, Vector3.zero end
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for _, p in ipairs(parts) do
		for _, c in ipairs(partCorners(rawProp(p, "CFrame"), rawProp(p, "Size"))) do
			minX, minY, minZ = math.min(minX, c.X), math.min(minY, c.Y), math.min(minZ, c.Z)
			maxX, maxY, maxZ = math.max(maxX, c.X), math.max(maxY, c.Y), math.max(maxZ, c.Z)
		end
	end
	local center = Vector3.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
	return CFrame.new(center), Vector3.new(maxX - minX, maxY - minY, maxZ - minZ)
end
Inst.boundingBox = boundingBox

local function materialDensity(mat)
	local name = mat and mat.Name or "Plastic"
	local densities = { Plastic = 0.7, SmoothPlastic = 0.7, Neon = 0.7, Wood = 0.35, WoodPlanks = 0.35, Metal = 7.85, DiamondPlate = 7.85, CorrodedMetal = 7.85, Foil = 2.7, Concrete = 2.4, Brick = 1.92, Granite = 2.69, Marble = 2.56, Slate = 2.69, Cobblestone = 2.69, Pebble = 2.4, Sand = 1.6, Fabric = 0.7, Grass = 0.9, Ice = 0.92, Glass = 2.4, ForceField = 2.4, Asphalt = 2.36, Basalt = 2.69, CrackedLava = 2.69, Ground = 0.9, LeafyGrass = 0.9, Limestone = 2.69, Mud = 0.9, Pavement = 2.36, Rock = 2.69, Salt = 2.16, Sandstone = 2.69, Snow = 0.9, Glacier = 0.92, Air = 0.01, Water = 1, Cardboard = 0.7, Carpet = 1.1, CeramicTiles = 2.4, ClayRoofTiles = 2, RoofShingles = 2.36, Leather = 0.86, Plaster = 0.75, Rubber = 1.3 }
	return densities[name] or 0.7
end

local function partMass(inst)
	local size = rawProp(inst, "Size") or Vector3.zero
	local cpp = rawProp(inst, "CustomPhysicalProperties")
	local density = cpp and cpp.Density or materialDensity(rawProp(inst, "Material"))
	local volume = size.X * size.Y * size.Z
	local shape = rawProp(inst, "Shape")
	if shape and shape.Name == "Ball" then volume = volume * math.pi / 6 elseif shape and shape.Name == "Cylinder" then volume = volume * math.pi / 4 end
	return volume * density
end

local function partVolume(inst)
	local size = rawProp(inst, "Size") or Vector3.zero
	return size.X * size.Y * size.Z
end

-- PVInstance / Model / BasePart ----------------------------------------------------------------
defclass("PVInstance", "Instance", {
	methods = {
		GetPivot = function(self)
			local s = st(self)
			if s.cls.isA.BasePart then return rawProp(self, "CFrame") * (rawProp(self, "PivotOffset") or CFrame.identity) end
			local pp = rawProp(self, "PrimaryPart")
			if pp and priv[pp] and not priv[pp].destroyed then return rawProp(pp, "CFrame") * (rawProp(pp, "PivotOffset") or CFrame.identity) end
			local wp = rawProp(self, "WorldPivot")
			if wp then return wp end
			local cf = boundingBox(descendantParts(self))
			return cf
		end,
		PivotTo = function(self, target)
			local s = st(self)
			if not CFrame._is(target) then fail(2, "PivotTo expects a CFrame, got %s", nativeTypeof(target)) end
			if s.cls.isA.BasePart then
				setProp(self, "CFrame", target * (rawProp(self, "PivotOffset") or CFrame.identity):Inverse())
				return
			end
			local current = self:GetPivot()
			local delta = target * current:Inverse()
			for _, part in ipairs(descendantParts(self)) do
				setProp(part, "CFrame", delta * rawProp(part, "CFrame"))
			end
			setProp(self, "WorldPivot", target)
		end,
	},
})

defclass("Model", "PVInstance", {
	defaults = { PrimaryPart = NIL, WorldPivot = NIL, ModelStreamingMode = function() return Enum.ModelStreamingMode.Default end, LevelOfDetail = function() return Enum.ModelLevelOfDetail.Automatic end },
	setters = {
		PrimaryPart = function(self, s, value)
			if value ~= nil and not (isInstance(value) and priv[value].cls.isA.BasePart) then fail(3, "PrimaryPart must be a BasePart or nil") end
			setProp(self, "PrimaryPart", value)
		end,
	},
	methods = {
		SetPrimaryPartCFrame = function(self, cf)
			local pp = rawProp(self, "PrimaryPart")
			if not pp then fail(2, "SetPrimaryPartCFrame: Model '%s' has no PrimaryPart", priv[self].name) end
			local delta = cf * rawProp(pp, "CFrame"):Inverse()
			for _, part in ipairs(descendantParts(self)) do
				setProp(part, "CFrame", delta * rawProp(part, "CFrame"))
			end
		end,
		GetPrimaryPartCFrame = function(self)
			local pp = rawProp(self, "PrimaryPart")
			if not pp then fail(2, "GetPrimaryPartCFrame: Model '%s' has no PrimaryPart", priv[self].name) end
			return rawProp(pp, "CFrame")
		end,
		GetModelCFrame = function(self) return self:GetPivot() end,
		GetBoundingBox = function(self) return boundingBox(descendantParts(self)) end,
		GetExtentsSize = function(self)
			local _, size = boundingBox(descendantParts(self))
			return size
		end,
		MoveTo = function(self, position)
			local pivot = self:GetPivot()
			self:PivotTo(CFrame._withPosition(pivot, position))
		end,
		TranslateBy = function(self, delta)
			local pivot = self:GetPivot()
			self:PivotTo(pivot + delta)
		end,
		BreakJoints = function(self)
			for _, d in ipairs(collectDescendants(self, {})) do
				if priv[d].cls.isA.JointInstance then destroyInstance(d) end
			end
		end,
		MakeJoints = function() end,
		GetScale = function(self) return rawProp(self, "_scale") or 1 end,
		ScaleTo = function(self, scale)
			local pivot = self:GetPivot()
			local old = rawProp(self, "_scale") or 1
			local f = scale / old
			for _, part in ipairs(descendantParts(self)) do
				local rel = pivot:ToObjectSpace(rawProp(part, "CFrame"))
				setProp(part, "Size", rawProp(part, "Size") * f)
				setProp(part, "CFrame", pivot * CFrame._withPosition(rel, rel.Position * f))
			end
			setProp(self, "_scale", scale)
		end,
		AddPersistentPlayer = function(self, player)
			local list = rawProp(self, "_persistent") or {}
			list[player] = true
			priv[self].props._persistent = list
		end,
		RemovePersistentPlayer = function(self, player)
			local list = rawProp(self, "_persistent")
			if list then list[player] = nil end
		end,
		GetPersistentPlayers = function(self)
			local out = {}
			for p in pairs(rawProp(self, "_persistent") or {}) do out[#out + 1] = p end
			return out
		end,
	},
})

defclass("BasePart", "PVInstance", {
	defaults = {
		Size = function() return Vector3.new(4, 1, 2) end,
		CFrame = function() return CFrame.identity end,
		Anchored = false, CanCollide = true, CanQuery = true, CanTouch = true, Transparency = 0, Reflectance = 0,
		Color = function() return Color3.fromRGB(163, 162, 165) end,
		Material = function() return Enum.Material.Plastic end,
		Massless = false, Locked = false, CastShadow = true,
		AssemblyLinearVelocity = function() return Vector3.zero end,
		AssemblyAngularVelocity = function() return Vector3.zero end,
		CollisionGroup = "Default", CustomPhysicalProperties = NIL, PivotOffset = function() return CFrame.identity end,
		RootPriority = 0, EnableFluidForces = true,
		TopSurface = function() return Enum.SurfaceType.Smooth end, BottomSurface = function() return Enum.SurfaceType.Smooth end,
		LeftSurface = function() return Enum.SurfaceType.Smooth end, RightSurface = function() return Enum.SurfaceType.Smooth end,
		FrontSurface = function() return Enum.SurfaceType.Smooth end, BackSurface = function() return Enum.SurfaceType.Smooth end,
		_networkOwner = NIL, _networkAuto = true,
	},
	events = { "Touched", "TouchEnded" },
	getters = {
		Position = function(self) return rawProp(self, "CFrame").Position end,
		Orientation = function(self) return degOrientation(rawProp(self, "CFrame")) end,
		Rotation = function(self)
			local rx, ry, rz = rawProp(self, "CFrame"):ToEulerAnglesXYZ()
			return Vector3.new(math.deg(rx), math.deg(ry), math.deg(rz))
		end,
		Mass = function(self) return partMass(self) end,
		AssemblyMass = function(self)
			if rawProp(self, "Massless") then return 0 end
			return partMass(self)
		end,
		AssemblyCenterOfMass = function(self) return rawProp(self, "CFrame").Position end,
		AssemblyRootPart = function(self) return self end,
		ExtentsSize = function(self) return rawProp(self, "Size") end,
		Velocity = function(self) return rawProp(self, "AssemblyLinearVelocity") end,
		RotVelocity = function(self) return rawProp(self, "AssemblyAngularVelocity") end,
		BrickColor = function(self)
			local bc = rawProp(self, "_brickColor")
			if bc then return bc end
			return BrickColor._nearest(rawProp(self, "Color"))
		end,
		CurrentPhysicalProperties = function(self)
			return rawProp(self, "CustomPhysicalProperties") or PhysicalProperties.new(materialDensity(rawProp(self, "Material")), 0.3, 0.5)
		end,
		ReceiveAge = function() return 0 end,
	},
	setters = {
		Position = function(self, s, v)
			if not Vector3._is(v) then fail(3, "Position must be a Vector3") end
			local old = rawProp(self, "CFrame")
			if old.Position == v then return end
			s.props.CFrame = CFrame._withPosition(old, v)
			firePropertyChanged(self, s, "CFrame", s.props.CFrame)
			firePropertyChanged(self, s, "Position", v)
		end,
		Orientation = function(self, s, v)
			local cf = rawProp(self, "CFrame")
			local rot = CFrame.fromOrientation(math.rad(v.X), math.rad(v.Y), math.rad(v.Z))
			setProp(self, "CFrame", CFrame._withPosition(rot, cf.Position))
			firePropertyChanged(self, s, "Orientation", v)
		end,
		Rotation = function(self, s, v)
			local cf = rawProp(self, "CFrame")
			local rot = CFrame.Angles(math.rad(v.X), math.rad(v.Y), math.rad(v.Z))
			setProp(self, "CFrame", CFrame._withPosition(rot, cf.Position))
			firePropertyChanged(self, s, "Rotation", v)
		end,
		CFrame = function(self, s, v)
			if not CFrame._is(v) then fail(3, "CFrame must be a CFrame, got %s", nativeTypeof(v)) end
			local old = rawProp(self, "CFrame")
			if old == v then return end
			s.props.CFrame = v
			firePropertyChanged(self, s, "CFrame", v)
			if old.Position ~= v.Position then firePropertyChanged(self, s, "Position", v.Position) end
		end,
		Size = function(self, s, v)
			if not Vector3._is(v) then fail(3, "Size must be a Vector3, got %s", nativeTypeof(v)) end
			setProp(self, "Size", v)
		end,
		Velocity = function(self, _, v) setProp(self, "AssemblyLinearVelocity", v) end,
		RotVelocity = function(self, _, v) setProp(self, "AssemblyAngularVelocity", v) end,
		BrickColor = function(self, s, v)
			s.props._brickColor = v
			setProp(self, "Color", v.Color)
			firePropertyChanged(self, s, "BrickColor", v)
		end,
		Color = function(self, s, v)
			s.props._brickColor = nil
			setProp(self, "Color", v)
		end,
	},
	methods = {
		SetNetworkOwner = function(self, player)
			if player ~= nil and not (isInstance(player) and priv[player].className == "Player") then fail(2, "SetNetworkOwner expects a Player or nil") end
			if rawProp(self, "Anchored") then fail(2, "Can only call SetNetworkOwner on unanchored parts (%s)", getFullName(self)) end
			priv[self].props._networkOwner = player == nil and NIL or player
			priv[self].props._networkAuto = false
		end,
		GetNetworkOwner = function(self) return rawProp(self, "_networkOwner") end,
		SetNetworkOwnershipAuto = function(self)
			priv[self].props._networkOwner = NIL
			priv[self].props._networkAuto = true
		end,
		GetNetworkOwnershipAuto = function(self) return rawProp(self, "_networkAuto") ~= false end,
		CanSetNetworkOwnership = function(self)
			if rawProp(self, "Anchored") then return false, "Part is anchored" end
			return true, nil
		end,
		ApplyImpulse = function() end,
		ApplyAngularImpulse = function() end,
		ApplyImpulseAtPosition = function() end,
		GetMass = function(self) return partMass(self) end,
		GetVelocityAtPosition = function(self) return rawProp(self, "AssemblyLinearVelocity") end,
		BreakJoints = function(self)
			for _, c in ipairs(tcopy(priv[self].children)) do
				if priv[c].cls.isA.JointInstance then destroyInstance(c) end
			end
		end,
		MakeJoints = function() end,
		GetConnectedParts = function(self) return { self } end,
		GetJoints = function(self)
			local list = {}
			for _, c in ipairs(priv[self].children) do
				if priv[c].cls.isA.JointInstance then list[#list + 1] = c end
			end
			return list
		end,
		GetTouchingParts = function() return {} end,
		GetRootPart = function(self) return self end,
		CanCollideWith = function(self, other)
			return Inst.collisionGroupsCollidable(rawProp(self, "CollisionGroup"), rawProp(other, "CollisionGroup"))
		end,
		IsGrounded = function(self) return rawProp(self, "Anchored") == true end,
		Resize = function(self, normalId, delta)
			local axis = Vector3.FromNormalId(normalId)
			local size = rawProp(self, "Size")
			setProp(self, "Size", size + axis:Abs() * delta)
			setProp(self, "CFrame", rawProp(self, "CFrame") + rawProp(self, "CFrame"):VectorToWorldSpace(axis) * (delta / 2))
			return true
		end,
		GetClosestPointOnSurface = function(self, point)
			local cf, size = rawProp(self, "CFrame"), rawProp(self, "Size")
			local lp = cf:PointToObjectSpace(point)
			local h = size / 2
			local c = Vector3.new(clamp(lp.X, -h.X, h.X), clamp(lp.Y, -h.Y, h.Y), clamp(lp.Z, -h.Z, h.Z))
			return cf:PointToWorldSpace(c)
		end,
		GetNoCollisionConstraints = function() return {} end,
		SetNetworkOwnerAuto = function(self) self:SetNetworkOwnershipAuto() end,
	},
})

defclass("Part", "BasePart", { defaults = { Shape = function() return Enum.PartType.Block end } })
defclass("FormFactorPart", "BasePart")
-- MeshPart:ApplyMesh(source) copies MeshContent / TextureContent (and MeshId / TextureID, the
-- fidelities and MeshSize) from another MeshPart, like the engine; shim.assetService.applyMeshUnavailable
-- makes it throw (older clients), and every call is recorded in shim.assetService.calls.
defclass("MeshPart", "BasePart", { defaults = { MeshId = "", TextureID = "", MeshContent = NIL, TextureContent = NIL, DoubleSided = false, MeshSize = function() return Vector3.new(1, 1, 1) end, CollisionFidelity = function() return Enum.CollisionFidelity.Default end, RenderFidelity = function() return Enum.RenderFidelity.Automatic end, FluidFidelity = function() return Enum.FluidFidelity.Automatic end }, methods = {
	ApplyMesh = function(self, source)
		local a = shim.assetService
		if a and a.applyMeshUnavailable then fail(2, "ApplyMesh is not a valid member of MeshPart") end
		if not isInstance(source) or not priv[source].cls.isA.MeshPart then fail(2, "MeshPart:ApplyMesh expects a MeshPart, got %s", nativeTypeof(source)) end
		if a then table.insert(a.calls, { method = "ApplyMesh", source = source, target = self }) end
		for _, key in ipairs({ "MeshContent", "TextureContent", "MeshId", "TextureID", "CollisionFidelity", "RenderFidelity", "FluidFidelity", "MeshSize" }) do
			local value = priv[source].props[key]
			if value ~= nil then priv[self].props[key] = value end
		end
	end,
} })
defclass("WedgePart", "BasePart")
defclass("CornerWedgePart", "BasePart")
defclass("TrussPart", "BasePart", { defaults = { Size = function() return Vector3.new(2, 2, 2) end } })
defclass("UnionOperation", "BasePart")
defclass("SpawnLocation", "Part", { defaults = { Size = function() return Vector3.new(6, 1, 6) end, Enabled = true, Neutral = true, AllowTeamChangeOnTouch = false, Duration = 0 } })
defclass("Seat", "Part", {
	defaults = { Occupant = NIL, Disabled = false, Size = function() return Vector3.new(2, 0.4, 2) end },
	setters = { Occupant = function() fail(3, "Occupant is read-only; use Seat:Sit(humanoid) or humanoid.Sit = false") end },
})
defclass("VehicleSeat", "BasePart", {
	defaults = { Occupant = NIL, Disabled = false, ThrottleFloat = 0, SteerFloat = 0, Throttle = 0, Steer = 0, MaxSpeed = 25, Torque = 10, TurnSpeed = 1, HeadsUpDisplay = true, Size = function() return Vector3.new(2, 0.4, 2) end },
	setters = { Occupant = function() fail(3, "Occupant is read-only; use VehicleSeat:Sit(humanoid) or humanoid.Sit = false") end },
})
defclass("Terrain", "BasePart", {
	defaults = { WaterColor = function() return Color3.fromRGB(12, 84, 92) end, WaterTransparency = 0.3, WaterWaveSize = 0.15, WaterWaveSpeed = 10, WaterReflectance = 1, Decoration = false, Anchored = true },
	methods = {
		FillBlock = function(self, cf, size, material) table.insert(priv[self].props._fills, { "Block", cf, size, material }) end,
		FillBall = function(self, center, radius, material) table.insert(priv[self].props._fills, { "Ball", center, radius, material }) end,
		FillCylinder = function(self, cf, height, radius, material) table.insert(priv[self].props._fills, { "Cylinder", cf, height, radius, material }) end,
		FillWedge = function(self, cf, size, material) table.insert(priv[self].props._fills, { "Wedge", cf, size, material }) end,
		FillRegion = function(self, region, resolution, material) table.insert(priv[self].props._fills, { "Region", region, resolution, material }) end,
		Clear = function(self) priv[self].props._fills = {} end,
		WriteVoxels = function() end,
		ReadVoxels = function(_, region, res)
			local size = region.Size / res
			local nx, ny, nz = math.max(1, math.floor(size.X)), math.max(1, math.floor(size.Y)), math.max(1, math.floor(size.Z))
			local mats, occ = {}, {}
			for x = 1, nx do
				mats[x], occ[x] = {}, {}
				for y = 1, ny do
					mats[x][y], occ[x][y] = {}, {}
					for z = 1, nz do mats[x][y][z] = Enum.Material.Air occ[x][y][z] = 0 end
				end
			end
			mats.Size = Vector3.new(nx, ny, nz)
			occ.Size = mats.Size
			return mats, occ
		end,
		SetMaterialColor = function(self, mat, color) priv[self].props._matColors[mat] = color end,
		GetMaterialColor = function(self, mat) return priv[self].props._matColors[mat] or Color3.fromRGB(106, 127, 63) end,
		PasteRegion = function() end,
		CopyRegion = function() return {} end,
		CellCenterToWorld = function(_, x, y, z) return Vector3.new(x * 4 + 2, y * 4 + 2, z * 4 + 2) end,
		WorldToCell = function(_, pos) return Vector3.new(math.floor(pos.X / 4), math.floor(pos.Y / 4), math.floor(pos.Z / 4)) end,
	},
	onCreate = function(inst, s)
		s.name = "Terrain"
		s.props._fills = {}
		s.props._matColors = {}
	end,
})

-- Attachment / joints / constraints -------------------------------------------------------------
local function parentPartCFrame(inst)
	local p = priv[inst].parent
	if p and priv[p].cls.isA.BasePart then return rawProp(p, "CFrame") end
	if p and priv[p].cls.isA.Attachment then return p.WorldCFrame end
	return CFrame.identity
end

defclass("Attachment", "Instance", {
	defaults = { CFrame = function() return CFrame.identity end, Visible = false },
	getters = {
		Position = function(self) return rawProp(self, "CFrame").Position end,
		Orientation = function(self) return degOrientation(rawProp(self, "CFrame")) end,
		Axis = function(self) return rawProp(self, "CFrame").XVector end,
		SecondaryAxis = function(self) return rawProp(self, "CFrame").YVector end,
		WorldCFrame = function(self) return parentPartCFrame(self) * rawProp(self, "CFrame") end,
		WorldPosition = function(self) return (parentPartCFrame(self) * rawProp(self, "CFrame")).Position end,
		WorldOrientation = function(self) return degOrientation(parentPartCFrame(self) * rawProp(self, "CFrame")) end,
		WorldAxis = function(self) return (parentPartCFrame(self) * rawProp(self, "CFrame")).XVector end,
		WorldSecondaryAxis = function(self) return (parentPartCFrame(self) * rawProp(self, "CFrame")).YVector end,
	},
	setters = {
		Position = function(self, s, v)
			local old = rawProp(self, "CFrame")
			if old.Position == v then return end
			setProp(self, "CFrame", CFrame._withPosition(old, v))
			firePropertyChanged(self, s, "Position", v)
		end,
		Orientation = function(self, s, v)
			local rot = CFrame.fromOrientation(math.rad(v.X), math.rad(v.Y), math.rad(v.Z))
			setProp(self, "CFrame", CFrame._withPosition(rot, rawProp(self, "CFrame").Position))
		end,
		WorldCFrame = function(self, s, v) setProp(self, "CFrame", parentPartCFrame(self):ToObjectSpace(v)) end,
		WorldPosition = function(self, s, v)
			local local_ = parentPartCFrame(self):PointToObjectSpace(v)
			setProp(self, "CFrame", CFrame._withPosition(rawProp(self, "CFrame"), local_))
		end,
		Axis = function() end, SecondaryAxis = function() end, WorldAxis = function() end, WorldSecondaryAxis = function() end,
	},
	methods = {
		GetAxis = function(self) return self.Axis end,
		GetSecondaryAxis = function(self) return self.SecondaryAxis end,
		SetAxis = function() end,
		SetSecondaryAxis = function() end,
	},
})
defclass("Bone", "Attachment", { defaults = { Transform = function() return CFrame.identity end }, getters = { TransformedCFrame = function(self) return rawProp(self, "CFrame") * rawProp(self, "Transform") end, TransformedWorldCFrame = function(self) return self.WorldCFrame * rawProp(self, "Transform") end } })

defclass("JointInstance", "Instance", {
	defaults = { Part0 = NIL, Part1 = NIL, C0 = function() return CFrame.identity end, C1 = function() return CFrame.identity end, Enabled = true, Active = false },
})
defclass("Weld", "JointInstance")
defclass("ManualWeld", "JointInstance")
defclass("Snap", "JointInstance")
defclass("Glue", "JointInstance")
defclass("DynamicRotate", "JointInstance")
defclass("Rotate", "DynamicRotate")
defclass("Motor", "JointInstance", { defaults = { CurrentAngle = 0, DesiredAngle = 0, MaxVelocity = 0 }, methods = { SetDesiredAngle = function(self, a) setProp(self, "DesiredAngle", a) end } })
defclass("Motor6D", "Motor", { defaults = { Transform = function() return CFrame.identity end } })
defclass("VelocityMotor", "JointInstance")
defclass("WeldConstraint", "Instance", { defaults = { Part0 = NIL, Part1 = NIL, Enabled = true, Active = false } })
defclass("NoCollisionConstraint", "Instance", { defaults = { Part0 = NIL, Part1 = NIL, Enabled = true } })
defclass("Constraint", "Instance", { defaults = { Attachment0 = NIL, Attachment1 = NIL, Enabled = true, Visible = false, Color = function() return BrickColor.new("Bright red") end, Active = false } })
for _, name in ipairs({ "AlignOrientation", "AlignPosition", "LinearVelocity", "AngularVelocity", "VectorForce", "Torque", "LineForce", "BallSocketConstraint", "HingeConstraint", "PrismaticConstraint", "RopeConstraint", "RodConstraint", "SpringConstraint", "CylindricalConstraint", "UniversalConstraint", "Plane", "RigidConstraint", "SlidingBallConstraint", "AnimationConstraint", "TorsionSpringConstraint" }) do
	defclass(name, "Constraint")
end
classes.AlignOrientation.defaults = { Mode = function() return Enum.OrientationAlignmentMode.TwoAttachment end, CFrame = function() return CFrame.identity end, RigidityEnabled = false, MaxTorque = 10000, Responsiveness = 10, MaxAngularVelocity = math.huge, ReactionTorqueEnabled = false, PrimaryAxisOnly = false, AlignType = function() return Enum.AlignType.AllAxes end }
classes.AlignPosition.defaults = { Mode = function() return Enum.PositionAlignmentMode.TwoAttachment end, Position = function() return Vector3.zero end, RigidityEnabled = false, MaxForce = 10000, Responsiveness = 10, MaxVelocity = math.huge, ApplyAtCenterOfMass = false, ReactionForceEnabled = false }
classes.LinearVelocity.defaults = { VelocityConstraintMode = function() return Enum.VelocityConstraintMode.Vector end, VectorVelocity = function() return Vector3.zero end, LineVelocity = 0, LineDirection = function() return Vector3.xAxis end, PlaneVelocity = function() return Vector2.zero end, MaxForce = 1000, MaxAxesForce = function() return Vector3.new(1000, 1000, 1000) end, MaxPlanarAxesForce = function() return Vector2.new(1000, 1000) end, RelativeTo = function() return Enum.ActuatorRelativeTo.World end, ForceLimitsEnabled = true, ForceLimitMode = function() return Enum.ForceLimitMode.Magnitude end }
classes.AngularVelocity.defaults = { AngularVelocity = function() return Vector3.zero end, MaxTorque = 1000, RelativeTo = function() return Enum.ActuatorRelativeTo.World end, ReactionTorqueEnabled = false }
classes.VectorForce.defaults = { Force = function() return Vector3.zero end, RelativeTo = function() return Enum.ActuatorRelativeTo.Attachment0 end, ApplyAtCenterOfMass = false }
resolved = {}

defclass("BodyMover", "Instance")
defclass("BodyVelocity", "BodyMover", { defaults = { Velocity = function() return Vector3.zero end, MaxForce = function() return Vector3.new(4000, 4000, 4000) end, P = 1250 } })
defclass("BodyGyro", "BodyMover", { defaults = { CFrame = function() return CFrame.identity end, MaxTorque = function() return Vector3.new(400000, 0, 400000) end, P = 3000, D = 500 } })
defclass("BodyPosition", "BodyMover", { defaults = { Position = function() return Vector3.zero end, MaxForce = function() return Vector3.new(4000, 4000, 4000) end, P = 10000, D = 1250 } })
defclass("BodyForce", "BodyMover", { defaults = { Force = function() return Vector3.zero end } })
defclass("BodyAngularVelocity", "BodyMover", { defaults = { AngularVelocity = function() return Vector3.zero end, MaxTorque = function() return Vector3.new(4000, 4000, 4000) end } })
defclass("BodyThrust", "BodyMover")

-- Humanoid and seating ----------------------------------------------------------------------
local function unseat(humanoid)
	local hs = priv[humanoid]
	local seat = rawProp(humanoid, "SeatPart")
	hs.props.SeatPart = NIL
	hs.props.Sit = false
	if seat and priv[seat] then
		local ss = priv[seat]
		if rawProp(seat, "Occupant") == humanoid then
			ss.props.Occupant = NIL
			firePropertyChanged(seat, ss, "Occupant", nil)
		end
		local weld = findChildByName(ss, "SeatWeld")
		if weld and not priv[weld].destroyed then
			priv[weld].props._unseating = true
			destroyInstance(weld)
		end
	end
	firePropertyChanged(humanoid, hs, "SeatPart", nil)
	firePropertyChanged(humanoid, hs, "Sit", false)
	if seat then
		local seated = hs.events.Seated
		if seated then seated:Fire(false, nil) end
	end
end
Inst.unseat = unseat

local function humanoidChangeState(humanoid, state)
	local hs = priv[humanoid]
	local old = rawProp(humanoid, "_state")
	if state.Name == "Jumping" then
		hs.props.Jump = true
		if rawProp(humanoid, "SeatPart") then unseat(humanoid) end
	end
	hs.props._state = state
	if old ~= state then
		local sig = hs.events.StateChanged
		if sig then sig:Fire(old, state) end
		local ev = hs.events[state.Name]
		if ev and state.Name ~= "Seated" then ev:Fire() end
	end
end

local function seatSit(seat, humanoid)
	local ss = st(seat, "Sit")
	if not (isInstance(humanoid) and priv[humanoid].className == "Humanoid") then fail(3, "Seat:Sit expects a Humanoid") end
	if rawProp(humanoid, "Health") <= 0 then return end
	local current = rawProp(seat, "Occupant")
	if current == humanoid then return end
	if current then unseat(current) end
	if rawProp(humanoid, "SeatPart") then unseat(humanoid) end
	local hs = priv[humanoid]
	local root = humanoid.RootPart
	local weld = new("Weld")
	priv[weld].name = "SeatWeld"
	setProp(weld, "Part0", seat)
	setProp(weld, "Part1", root)
	setProp(weld, "C0", CFrame.new(0, rawProp(seat, "Size").Y / 2, 0) * CFrame.Angles(-math.pi / 2, 0, 0))
	setProp(weld, "C1", CFrame.new(0, -1.5, 0) * CFrame.Angles(-math.pi / 2, 0, 0))
	setParent(weld, seat)
	if root then
		-- place the character on the seat like the engine does (approximately)
		local target = rawProp(seat, "CFrame") * CFrame.new(0, rawProp(seat, "Size").Y / 2 + 1.5, 0)
		local model = priv[humanoid].parent
		if model and priv[model].cls.isA.Model and rawProp(model, "PrimaryPart") then
			model:PivotTo(CFrame._withPosition(target, target.Position))
		else
			setProp(root, "CFrame", target)
		end
	end
	ss.props.Occupant = humanoid
	hs.props.SeatPart = seat
	hs.props.Sit = true
	weld.Destroying:Connect(function()
		if priv[weld].props._unseating then return end
		if rawProp(seat, "Occupant") == humanoid then unseat(humanoid) end
	end)
	firePropertyChanged(seat, ss, "Occupant", humanoid)
	firePropertyChanged(humanoid, hs, "SeatPart", seat)
	firePropertyChanged(humanoid, hs, "Sit", true)
	humanoidChangeState(humanoid, Enum.HumanoidStateType.Seated)
	local seated = hs.events.Seated
	if seated then seated:Fire(true, seat) end
end
classes.Seat.methods.Sit = seatSit
classes.VehicleSeat.methods.Sit = seatSit
allMethodNames.Sit = true

defclass("Humanoid", "Instance", {
	defaults = {
		Health = 100, MaxHealth = 100, Sit = false, Jump = false, SeatPart = NIL, WalkSpeed = 16, JumpPower = 50, JumpHeight = 7.2,
		PlatformStand = false, AutoRotate = true, HipHeight = 2, RigType = function() return Enum.HumanoidRigType.R15 end,
		DisplayName = "", HealthDisplayDistance = 100, NameDisplayDistance = 100, DisplayDistanceType = function() return Enum.HumanoidDisplayDistanceType.Viewer end,
		MoveDirection = function() return Vector3.zero end, WalkToPoint = function() return Vector3.zero end, WalkToPart = NIL,
		UseJumpPower = true, BreakJointsOnDeath = true, RequiresNeck = true, AutoJumpEnabled = true, AutomaticScalingEnabled = true,
		FloorMaterial = function() return Enum.Material.Grass end, CameraOffset = function() return Vector3.zero end,
		EvaluateStateMachine = true, MaxSlopeAngle = 89, _state = function() return Enum.HumanoidStateType.Running end, _stateEnabled = function() return {} end,
	},
	events = { "Died", "StateChanged", "Seated", "Running", "Jumping", "FreeFalling", "Climbing", "Swimming", "Touched", "MoveToFinished", "HealthChanged", "PlatformStanding", "FallingDown", "GettingUp", "Ragdoll", "StateEnabledChanged", "AnimationPlayed" },
	getters = {
		RootPart = function(self)
			local p = priv[self].parent
			if not p then return nil end
			return findChildByName(priv[p], "HumanoidRootPart")
		end,
		Torso = function(self)
			local p = priv[self].parent
			if not p then return nil end
			return findChildByName(priv[p], "UpperTorso") or findChildByName(priv[p], "Torso")
		end,
		Animator = function(self) return findChildByName(priv[self], "Animator") end,
	},
	setters = {
		Health = function(self, s, v)
			local old = rawProp(self, "Health")
			v = clamp(v, 0, rawProp(self, "MaxHealth"))
			if v == old then return end
			s.props.Health = v
			firePropertyChanged(self, s, "Health", v)
			local hc = s.events.HealthChanged
			if hc then hc:Fire(v) end
			if v <= 0 and old > 0 then
				if rawProp(self, "SeatPart") then unseat(self) end
				humanoidChangeState(self, Enum.HumanoidStateType.Dead)
				local died = s.events.Died
				if died then died:Fire() end
			end
		end,
		Sit = function(self, s, v)
			if v == false and rawProp(self, "SeatPart") then
				unseat(self)
				humanoidChangeState(self, Enum.HumanoidStateType.Running)
				return
			end
			setProp(self, "Sit", v)
		end,
		Jump = function(self, s, v)
			if v and rawProp(self, "SeatPart") then
				humanoidChangeState(self, Enum.HumanoidStateType.Jumping)
				return
			end
			setProp(self, "Jump", v)
		end,
		SeatPart = function() fail(3, "SeatPart is read-only") end,
		RootPart = function() fail(3, "RootPart is read-only") end,
	},
	methods = {
		ChangeState = function(self, state)
			if not shim._isEnumItem(state) then fail(2, "ChangeState expects a HumanoidStateType") end
			humanoidChangeState(self, state)
		end,
		GetState = function(self) return rawProp(self, "_state") end,
		GetStateEnabled = function(self, state) return rawProp(self, "_stateEnabled")[state] ~= false end,
		SetStateEnabled = function(self, state, enabled)
			rawProp(self, "_stateEnabled")[state] = enabled
			local sig = priv[self].events.StateEnabledChanged
			if sig then sig:Fire(state, enabled) end
		end,
		MoveTo = function(self, position, part)
			setProp(self, "WalkToPoint", position)
			setProp(self, "WalkToPart", part)
			local s = priv[self]
			task.defer(function()
				local root = self.RootPart
				if root and shim.humanoidMoveToTeleports then
					root.CFrame = CFrame._withPosition(root.CFrame, position + Vector3.new(0, rawProp(self, "HipHeight") + 1, 0))
				end
				local sig = s.events.MoveToFinished
				if sig then sig:Fire(true) end
			end)
		end,
		Move = function(self, dir) setProp(self, "MoveDirection", dir) end,
		TakeDamage = function(self, amount) self.Health = rawProp(self, "Health") - amount end,
		LoadAnimation = function(self, animation)
			local animator = findChildByName(priv[self], "Animator") or new("Animator", self)
			return animator:LoadAnimation(animation)
		end,
		GetPlayingAnimationTracks = function(self)
			local animator = findChildByName(priv[self], "Animator")
			return animator and animator:GetPlayingAnimationTracks() or {}
		end,
		EquipTool = function(self, tool)
			local model = priv[self].parent
			if model and tool then setParent(tool, model) end
		end,
		UnequipTools = function(self)
			local model = priv[self].parent
			if not model then return end
			for _, c in ipairs(tcopy(priv[model].children)) do
				if priv[c].className == "Tool" then
					local player = Inst.playerFromCharacter and Inst.playerFromCharacter(model)
					local backpack = player and findChildByName(priv[player], "Backpack")
					setParent(c, backpack)
				end
			end
		end,
		GetAccessories = function(self)
			local model = priv[self].parent
			local list = {}
			if model then
				for _, c in ipairs(priv[model].children) do
					if priv[c].className == "Accessory" then list[#list + 1] = c end
				end
			end
			return list
		end,
		AddAccessory = function(self, acc) setParent(acc, priv[self].parent) end,
		RemoveAccessories = function(self)
			for _, acc in ipairs(self:GetAccessories()) do destroyInstance(acc) end
		end,
		ApplyDescription = function(self, desc) priv[self].props._description = desc end,
		ApplyDescriptionReset = function(self, desc) priv[self].props._description = desc end,
		GetAppliedDescription = function(self) return rawProp(self, "_description") or new("HumanoidDescription") end,
		GetMoveVelocity = function() return Vector3.zero end,
		SetClickToWalkEnabled = function() end,
		GetLimb = function() return Enum.Limb.Unknown end,
		GetBodyPartR15 = function() return Enum.BodyPartR15.Unknown end,
	},
	onCreate = function(inst)
		new("Animator", inst)
	end,
})
defclass("HumanoidDescription", "Instance")

defclass("AnimationTrack", "Instance", {
	defaults = { IsPlaying = false, Length = 1, Looped = false, Priority = function() return Enum.AnimationPriority.Core end, Speed = 1, TimePosition = 0, WeightCurrent = 1, WeightTarget = 1, Animation = NIL },
	events = { "Stopped", "KeyframeReached", "DidLoop", "Ended" },
	methods = {
		Play = function(self, fade, weight, speed)
			setProp(self, "IsPlaying", true)
			if speed then setProp(self, "Speed", speed) end
			if weight then setProp(self, "WeightTarget", weight) end
		end,
		Stop = function(self)
			if rawProp(self, "IsPlaying") then
				setProp(self, "IsPlaying", false)
				priv[self].events.Stopped = priv[self].events.Stopped or Signal.new("Stopped")
				priv[self].events.Stopped:Fire()
			end
		end,
		Pause = function(self) setProp(self, "IsPlaying", false) end,
		AdjustSpeed = function(self, speed) setProp(self, "Speed", speed or 1) end,
		AdjustWeight = function(self, weight) setProp(self, "WeightTarget", weight or 1) end,
		GetMarkerReachedSignal = function(self, name) return getEvent(priv[self], "Marker_" .. tostring(name)) end,
		GetTimeOfKeyframe = function() return 0 end,
	},
})
defclass("Animator", "Instance", {
	methods = {
		LoadAnimation = function(self, animation)
			local track = new("AnimationTrack")
			setProp(track, "Animation", animation)
			local list = rawProp(self, "_tracks") or {}
			list[#list + 1] = track
			priv[self].props._tracks = list
			return track
		end,
		GetPlayingAnimationTracks = function(self)
			local out = {}
			for _, t in ipairs(rawProp(self, "_tracks") or {}) do
				if rawProp(t, "IsPlaying") then out[#out + 1] = t end
			end
			return out
		end,
		ApplyJointVelocities = function() end,
	},
})
defclass("AnimationController", "Instance", { methods = { LoadAnimation = classes.Humanoid.methods.LoadAnimation, GetPlayingAnimationTracks = classes.Humanoid.methods.GetPlayingAnimationTracks } })
defclass("Animation", "Instance", { defaults = { AnimationId = "" } })

-- Camera ---------------------------------------------------------------------------------------
defclass("Camera", "Instance", {
	defaults = {
		CFrame = function() return CFrame.new(Vector3.new(0, 10, 20), Vector3.zero) end,
		Focus = function() return CFrame.identity end, FieldOfView = 70, CameraType = function() return Enum.CameraType.Custom end,
		CameraSubject = NIL, ViewportSize = function() return Vector2.new(1280, 720) end, HeadLocked = true, HeadScale = 1, NearPlaneZ = -0.1,
		MaxAxisFieldOfView = 70, DiagonalFieldOfView = 88, FieldOfViewMode = function() return Enum.FieldOfViewMode.Vertical end,
	},
	events = { "InterpolationFinished" },
	methods = {
		GetRenderCFrame = function(self) return rawProp(self, "CFrame") end,
		WorldToViewportPoint = function(self, pos)
			local cf = rawProp(self, "CFrame")
			local vp = rawProp(self, "ViewportSize")
			local rel = cf:PointToObjectSpace(pos)
			local depth = -rel.Z
			local fov = math.rad(rawProp(self, "FieldOfView"))
			local halfH = math.tan(fov / 2)
			local aspect = vp.X / vp.Y
			local safeDepth = depth ~= 0 and depth or 1e-6
			local nx = rel.X / (safeDepth * halfH * aspect)
			local ny = rel.Y / (safeDepth * halfH)
			local sx = (nx + 1) / 2 * vp.X
			local sy = (1 - ny) / 2 * vp.Y
			local onScreen = depth > 0 and nx >= -1 and nx <= 1 and ny >= -1 and ny <= 1
			return Vector3.new(sx, sy, depth), onScreen
		end,
		WorldToScreenPoint = function(self, pos)
			local v, on = self:WorldToViewportPoint(pos)
			return Vector3.new(v.X, v.Y - 36, v.Z), on
		end,
		ViewportPointToRay = function(self, x, y, depth)
			local cf = rawProp(self, "CFrame")
			local vp = rawProp(self, "ViewportSize")
			local fov = math.rad(rawProp(self, "FieldOfView"))
			local halfH = math.tan(fov / 2)
			local aspect = vp.X / vp.Y
			local nx = (x / vp.X) * 2 - 1
			local ny = 1 - (y / vp.Y) * 2
			local dir = cf:VectorToWorldSpace(Vector3.new(nx * halfH * aspect, ny * halfH, -1)).Unit
			return Ray.new(cf.Position + dir * (depth or 0), dir)
		end,
		ScreenPointToRay = function(self, x, y, depth) return self:ViewportPointToRay(x, y + 36, depth) end,
		GetPartsObscuringTarget = function() return {} end,
		ZoomToExtents = function() end,
		GetRoll = function() return 0 end,
		SetRoll = function() end,
		Interpolate = function(self, cf, focus)
			setProp(self, "CFrame", cf)
			setProp(self, "Focus", focus)
		end,
	},
})

-- GUI ----------------------------------------------------------------------------------------
local function guiParentAbs(inst)
	local p = priv[inst].parent
	while p do
		local ps = priv[p]
		if ps.cls.isA.GuiObject then return p.AbsolutePosition, p.AbsoluteSize end
		if ps.cls.isA.LayerCollector then return p.AbsolutePosition, p.AbsoluteSize end
		if ps.cls.isA.GuiBase2d then return p.AbsolutePosition, p.AbsoluteSize end
		p = ps.parent
	end
	return Vector2.zero, Vector2.new(1280, 720)
end

local function viewportSize()
	local cam = game and game:GetService("Workspace").CurrentCamera
	return cam and rawProp(cam, "ViewportSize") or Vector2.new(1280, 720)
end

defclass("GuiBase", "Instance")
defclass("GuiBase2d", "GuiBase", {
	defaults = { AutoLocalize = true, RootLocalizationTable = NIL, SelectionBehaviorUp = function() return Enum.SelectionBehavior.Escape end, SelectionBehaviorDown = function() return Enum.SelectionBehavior.Escape end, SelectionBehaviorLeft = function() return Enum.SelectionBehavior.Escape end, SelectionBehaviorRight = function() return Enum.SelectionBehavior.Escape end, SelectionGroup = false },
	events = { "SelectionChanged" },
	getters = {
		AbsolutePosition = function() return Vector2.zero end,
		AbsoluteSize = function() return viewportSize() end,
		AbsoluteRotation = function() return 0 end,
	},
})
defclass("LayerCollector", "GuiBase2d", {
	defaults = { Enabled = true, ResetOnSpawn = true, ZIndexBehavior = function() return Enum.ZIndexBehavior.Sibling end },
})
defclass("ScreenGui", "LayerCollector", {
	defaults = { DisplayOrder = 0, IgnoreGuiInset = false, ScreenInsets = function() return Enum.ScreenInsets.CoreUISafeInsets end, ClipToDeviceSafeArea = true, SafeAreaCompatibility = function() return Enum.SafeAreaCompatibility.FullscreenExtension end },
	getters = {
		AbsolutePosition = function(self)
			if rawProp(self, "IgnoreGuiInset") or rawProp(self, "ScreenInsets").Name == "None" then return Vector2.zero end
			return Vector2.new(0, 36)
		end,
		AbsoluteSize = function(self)
			local vp = viewportSize()
			if rawProp(self, "IgnoreGuiInset") or rawProp(self, "ScreenInsets").Name == "None" then return vp end
			return Vector2.new(vp.X, vp.Y - 36)
		end,
	},
})
defclass("SurfaceGuiBase", "LayerCollector", { defaults = { Active = true, Adornee = NIL, Face = function() return Enum.NormalId.Front end } })
defclass("SurfaceGui", "SurfaceGuiBase", { defaults = { CanvasSize = function() return Vector2.new(800, 600) end, AlwaysOnTop = false, LightInfluence = 1, PixelsPerStud = 50, SizingMode = function() return Enum.SurfaceGuiSizingMode.FixedSize end, ZOffset = 0 }, getters = { AbsoluteSize = function(self) return rawProp(self, "CanvasSize") end } })
defclass("BillboardGui", "LayerCollector", {
	defaults = { Adornee = NIL, Active = false, AlwaysOnTop = false, Size = function() return UDim2.new(0, 200, 0, 50) end, StudsOffset = function() return Vector3.zero end, StudsOffsetWorldSpace = function() return Vector3.zero end, ExtentsOffset = function() return Vector3.zero end, ExtentsOffsetWorldSpace = function() return Vector3.zero end, MaxDistance = math.huge, LightInfluence = 1, SizeOffset = function() return Vector2.zero end, ClipsDescendants = false, Brightness = 1, DistanceLowerLimit = 0, DistanceUpperLimit = -1, DistanceStep = 0, PlayerToHideFrom = NIL },
	getters = {
		AbsoluteSize = function(self)
			local size = rawProp(self, "Size")
			return Vector2.new(size.X.Offset + size.X.Scale * 100, size.Y.Offset + size.Y.Scale * 100)
		end,
	},
})

local function guiAbs(inst)
	local parentPos, parentSize = guiParentAbs(inst)
	local size = rawProp(inst, "Size") or UDim2.new()
	local pos = rawProp(inst, "Position") or UDim2.new()
	local anchor = rawProp(inst, "AnchorPoint") or Vector2.zero
	local w = size.X.Scale * parentSize.X + size.X.Offset
	local h = size.Y.Scale * parentSize.Y + size.Y.Offset
	local sc = rawProp(inst, "SizeConstraint")
	if sc and sc.Name == "RelativeXX" then h = size.Y.Scale * parentSize.X + size.Y.Offset
	elseif sc and sc.Name == "RelativeYY" then w = size.X.Scale * parentSize.Y + size.X.Offset end
	local x = parentPos.X + pos.X.Scale * parentSize.X + pos.X.Offset - anchor.X * w
	local y = parentPos.Y + pos.Y.Scale * parentSize.Y + pos.Y.Offset - anchor.Y * h
	return Vector2.new(x, y), Vector2.new(w, h)
end

local function estimateTextSize(text, textSize, maxWidth)
	text = tostring(text or "")
	textSize = textSize or 14
	local charW = textSize * 0.55
	local longest, lines = 0, 1
	for line in (text .. "\n"):gmatch("(.-)\n") do
		local w = #line * charW
		if maxWidth and maxWidth > 0 and w > maxWidth then
			lines += math.ceil(w / maxWidth) - 1
			w = maxWidth
		end
		if w > longest then longest = w end
		if line ~= "" or true then lines += 1 end
	end
	lines -= 1
	return Vector2.new(math.ceil(longest), math.ceil(math.max(1, lines) * textSize))
end
Inst.estimateTextSize = estimateTextSize

defclass("GuiObject", "GuiBase2d", {
	defaults = {
		Active = false, AnchorPoint = function() return Vector2.zero end, AutomaticSize = function() return Enum.AutomaticSize.None end,
		BackgroundColor3 = function() return Color3.fromRGB(163, 162, 165) end, BackgroundTransparency = 0, BorderColor3 = function() return Color3.fromRGB(27, 42, 53) end,
		BorderMode = function() return Enum.BorderMode.Outline end, BorderSizePixel = 1, ClipsDescendants = false, Interactable = true, LayoutOrder = 0,
		NextSelectionDown = NIL, NextSelectionLeft = NIL, NextSelectionRight = NIL, NextSelectionUp = NIL,
		Position = function() return UDim2.new() end, Rotation = 0, Selectable = false, SelectionImageObject = NIL, SelectionOrder = 0,
		Size = function() return UDim2.new(0, 100, 0, 100) end, SizeConstraint = function() return Enum.SizeConstraint.RelativeXY end,
		Visible = true, ZIndex = 1, Transparency = 0,
	},
	events = { "InputBegan", "InputChanged", "InputEnded", "MouseEnter", "MouseLeave", "MouseMoved", "MouseWheelForward", "MouseWheelBackward", "TouchTap", "TouchLongPress", "TouchPan", "TouchPinch", "TouchRotate", "TouchSwipe", "SelectionGained", "SelectionLost" },
	getters = {
		AbsolutePosition = function(self) local p = guiAbs(self) return p end,
		AbsoluteSize = function(self) local _, s = guiAbs(self) return s end,
		AbsoluteRotation = function(self) return rawProp(self, "Rotation") or 0 end,
		GuiState = function() return Enum.GuiState.Idle end,
	},
	methods = {
		TweenPosition = function(self, pos, dir, style, time, override, callback)
			local tween = game:GetService("TweenService"):Create(self, TweenInfo.new(time or 1, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), { Position = pos })
			if callback then tween.Completed:Connect(function() callback(Enum.TweenStatus.Completed) end) end
			tween:Play()
			return true
		end,
		TweenSize = function(self, size, dir, style, time, override, callback)
			local tween = game:GetService("TweenService"):Create(self, TweenInfo.new(time or 1, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), { Size = size })
			if callback then tween.Completed:Connect(function() callback(Enum.TweenStatus.Completed) end) end
			tween:Play()
			return true
		end,
		TweenSizeAndPosition = function(self, size, pos, dir, style, time, override, callback)
			local tween = game:GetService("TweenService"):Create(self, TweenInfo.new(time or 1, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), { Size = size, Position = pos })
			if callback then tween.Completed:Connect(function() callback(Enum.TweenStatus.Completed) end) end
			tween:Play()
			return true
		end,
	},
})
defclass("Frame", "GuiObject", { defaults = { Style = function() return Enum.FrameStyle.Custom end } })
defclass("CanvasGroup", "GuiObject", { defaults = { GroupColor3 = function() return Color3.new(1, 1, 1) end, GroupTransparency = 0 } })
defclass("ScrollingFrame", "GuiObject", {
	defaults = { CanvasPosition = function() return Vector2.zero end, CanvasSize = function() return UDim2.new(0, 0, 2, 0) end, AutomaticCanvasSize = function() return Enum.AutomaticSize.None end, ScrollBarThickness = 12, ScrollingDirection = function() return Enum.ScrollingDirection.XY end, ScrollingEnabled = true, ElasticBehavior = function() return Enum.ElasticBehavior.WhenScrollable end, VerticalScrollBarInset = function() return Enum.ScrollBarInset.None end, HorizontalScrollBarInset = function() return Enum.ScrollBarInset.None end, VerticalScrollBarPosition = function() return Enum.VerticalScrollBarPosition.Right end, ScrollBarImageColor3 = function() return Color3.new(0, 0, 0) end, ScrollBarImageTransparency = 0, TopImage = "", BottomImage = "", MidImage = "" },
	getters = {
		AbsoluteCanvasSize = function(self)
			local cs = rawProp(self, "CanvasSize")
			local _, abs = guiAbs(self)
			return Vector2.new(cs.X.Scale * abs.X + cs.X.Offset, cs.Y.Scale * abs.Y + cs.Y.Offset)
		end,
		AbsoluteWindowSize = function(self) local _, s = guiAbs(self) return s end,
	},
	methods = { ScrollToTop = function(self) setProp(self, "CanvasPosition", Vector2.zero) end },
})
defclass("GuiButton", "GuiObject", {
	defaults = { AutoButtonColor = true, Modal = false, Selected = false, Style = function() return Enum.ButtonStyle.Custom end, Active = true, Selectable = true },
	events = { "Activated", "MouseButton1Click", "MouseButton1Down", "MouseButton1Up", "MouseButton2Click", "MouseButton2Down", "MouseButton2Up" },
})
local textDefaults = {
	Text = "Label", TextColor3 = function() return Color3.fromRGB(27, 42, 53) end, TextSize = 14, TextScaled = false, TextWrapped = false,
	TextXAlignment = function() return Enum.TextXAlignment.Center end, TextYAlignment = function() return Enum.TextYAlignment.Center end,
	Font = function() return Enum.Font.SourceSans end, FontFace = function() return Font.fromEnum(Enum.Font.SourceSans) end,
	TextTransparency = 0, TextStrokeTransparency = 1, TextStrokeColor3 = function() return Color3.new(0, 0, 0) end, RichText = false,
	TextTruncate = function() return Enum.TextTruncate.None end, LineHeight = 1, MaxVisibleGraphemes = -1, TextDirection = function() return Enum.TextDirection.Auto end,
}
local textGetters = {
	TextBounds = function(self)
		local _, abs = guiAbs(self)
		return estimateTextSize(rawProp(self, "Text"), rawProp(self, "TextSize"), rawProp(self, "TextWrapped") and abs.X or nil)
	end,
	TextFits = function(self)
		local _, abs = guiAbs(self)
		local b = estimateTextSize(rawProp(self, "Text"), rawProp(self, "TextSize"), rawProp(self, "TextWrapped") and abs.X or nil)
		return b.X <= abs.X and b.Y <= abs.Y
	end,
	ContentText = function(self) return (tostring(rawProp(self, "Text")):gsub("<[^>]->", "")) end,
}
defclass("TextLabel", "GuiObject", { defaults = tcopy(textDefaults), getters = tcopy(textGetters) })
defclass("TextButton", "GuiButton", { defaults = tcopy(textDefaults), getters = tcopy(textGetters) })
local tbDefaults = tcopy(textDefaults)
tbDefaults.Text = ""
tbDefaults.PlaceholderText = ""
tbDefaults.PlaceholderColor3 = function() return Color3.fromRGB(178, 178, 178) end
tbDefaults.ClearTextOnFocus = true
tbDefaults.MultiLine = false
tbDefaults.TextEditable = true
tbDefaults.CursorPosition = -1
tbDefaults.SelectionStart = -1
tbDefaults.ShowNativeInput = true
tbDefaults.Active = true
tbDefaults.Selectable = true
defclass("TextBox", "GuiObject", {
	defaults = tbDefaults, getters = tcopy(textGetters),
	events = { "Focused", "FocusLost", "ReturnPressedFromOnScreenKeyboard" },
	methods = {
		CaptureFocus = function(self)
			priv[self].props._focused = true
			local sig = priv[self].events.Focused
			if sig then sig:Fire() end
		end,
		ReleaseFocus = function(self, submitted)
			if not rawProp(self, "_focused") then return end
			priv[self].props._focused = false
			local sig = priv[self].events.FocusLost
			if sig then sig:Fire(submitted == true, nil) end
		end,
		IsFocused = function(self) return rawProp(self, "_focused") == true end,
	},
})
local imageDefaults = { Image = "", ImageColor3 = function() return Color3.new(1, 1, 1) end, ImageTransparency = 0, ImageRectOffset = function() return Vector2.zero end, ImageRectSize = function() return Vector2.zero end, ScaleType = function() return Enum.ScaleType.Stretch end, SliceCenter = function() return Rect.new(0, 0, 0, 0) end, SliceScale = 1, TileSize = function() return UDim2.new(1, 0, 1, 0) end, ResampleMode = function() return Enum.ResamplerMode.Default end, IsLoaded = true }
defclass("ImageLabel", "GuiObject", { defaults = tcopy(imageDefaults) })
defclass("ImageButton", "GuiButton", { defaults = (function() local d = tcopy(imageDefaults) d.HoverImage = "" d.PressedImage = "" return d end)() })
defclass("ViewportFrame", "GuiObject", { defaults = { CurrentCamera = NIL, Ambient = function() return Color3.new(1, 1, 1) end, LightColor = function() return Color3.new(1, 1, 1) end, LightDirection = function() return Vector3.new(-1, -1, -1) end, ImageColor3 = function() return Color3.new(1, 1, 1) end, ImageTransparency = 0 } })
defclass("VideoFrame", "GuiObject", { defaults = { Video = "", Playing = false, Looped = false, Volume = 1 }, methods = { Play = function(self) setProp(self, "Playing", true) end, Pause = function(self) setProp(self, "Playing", false) end } })

defclass("UIBase", "Instance")
defclass("UIComponent", "UIBase")
defclass("UIConstraint", "UIComponent")
defclass("UIAspectRatioConstraint", "UIConstraint", { defaults = { AspectRatio = 1, AspectType = function() return Enum.AspectType.FitWithinMaxSize end, DominantAxis = function() return Enum.DominantAxis.Width end } })
defclass("UISizeConstraint", "UIConstraint", { defaults = { MaxSize = function() return Vector2.new(math.huge, math.huge) end, MinSize = function() return Vector2.zero end } })
defclass("UITextSizeConstraint", "UIConstraint", { defaults = { MaxTextSize = 100, MinTextSize = 1 } })
defclass("UILayout", "UIComponent")
defclass("UIGridStyleLayout", "UILayout", {
	defaults = { FillDirection = function() return Enum.FillDirection.Vertical end, HorizontalAlignment = function() return Enum.HorizontalAlignment.Left end, VerticalAlignment = function() return Enum.VerticalAlignment.Top end, SortOrder = function() return Enum.SortOrder.LayoutOrder end },
	getters = {
		AbsoluteContentSize = function(self)
			local p = priv[self].parent
			if not p then return Vector2.zero end
			local w, h = 0, 0
			local vertical = (rawProp(self, "FillDirection") or Enum.FillDirection.Vertical).Name == "Vertical"
			local pad = rawProp(self, "Padding")
			local padPx = 0
			if pad then
				local _, parentAbs = guiAbs(p)
				padPx = pad.Offset + pad.Scale * (vertical and parentAbs.Y or parentAbs.X)
			end
			local n = 0
			for _, c in ipairs(priv[p].children) do
				if priv[c].cls.isA.GuiObject and rawProp(c, "Visible") ~= false then
					local _, s = guiAbs(c)
					n += 1
					if vertical then w = math.max(w, s.X) h += s.Y else h = math.max(h, s.Y) w += s.X end
				end
			end
			if n > 1 then
				if vertical then h += padPx * (n - 1) else w += padPx * (n - 1) end
			end
			return Vector2.new(w, h)
		end,
	},
	methods = { ApplyLayout = function() end },
})
defclass("UIListLayout", "UIGridStyleLayout", { defaults = { Padding = function() return UDim.new(0, 0) end, Wraps = false, HorizontalFlex = function() return Enum.UIFlexAlignment.None end, VerticalFlex = function() return Enum.UIFlexAlignment.None end, ItemLineAlignment = function() return Enum.ItemLineAlignment.Automatic end } })
defclass("UIGridLayout", "UIGridStyleLayout", { defaults = { CellPadding = function() return UDim2.new(0, 5, 0, 5) end, CellSize = function() return UDim2.new(0, 100, 0, 100) end, FillDirectionMaxCells = 0, StartCorner = function() return Enum.StartCorner.TopLeft end } })
defclass("UITableLayout", "UIGridStyleLayout")
defclass("UIPageLayout", "UIGridStyleLayout", { defaults = { CurrentPage = NIL, Animated = true, Circular = false, EasingDirection = function() return Enum.EasingDirection.Out end, EasingStyle = function() return Enum.EasingStyle.Back end, Padding = function() return UDim.new(0, 0) end, TweenTime = 1, GamepadInputEnabled = true, ScrollWheelInputEnabled = true, TouchInputEnabled = true }, methods = { JumpTo = function(self, page) setProp(self, "CurrentPage", page) end, JumpToIndex = function() end, Next = function() end, Previous = function() end } })
defclass("UICorner", "UIComponent", { defaults = { CornerRadius = function() return UDim.new(0, 8) end } })
defclass("UIStroke", "UIComponent", { defaults = { ApplyStrokeMode = function() return Enum.ApplyStrokeMode.Contextual end, Color = function() return Color3.new(0, 0, 0) end, LineJoinMode = function() return Enum.LineJoinMode.Round end, Thickness = 1, Transparency = 0, Enabled = true } })
defclass("UIPadding", "UIComponent", { defaults = { PaddingBottom = function() return UDim.new() end, PaddingLeft = function() return UDim.new() end, PaddingRight = function() return UDim.new() end, PaddingTop = function() return UDim.new() end } })
defclass("UIScale", "UIComponent", { defaults = { Scale = 1 } })
defclass("UIGradient", "UIComponent", { defaults = { Color = function() return ColorSequence.new(Color3.new(1, 1, 1)) end, Enabled = true, Offset = function() return Vector2.zero end, Rotation = 0, Transparency = function() return NumberSequence.new(0) end } })
defclass("UIFlexItem", "UIComponent", { defaults = { FlexMode = function() return Enum.UIFlexMode.None end, GrowRatio = 0, ShrinkRatio = 0, ItemLineAlignment = function() return Enum.ItemLineAlignment.Automatic end } })
defclass("UIDragDetector", "UIComponent")

defclass("ProximityPrompt", "Instance", {
	defaults = { ActionText = "Interact", ObjectText = "", KeyboardKeyCode = function() return Enum.KeyCode.E end, GamepadKeyCode = function() return Enum.KeyCode.ButtonX end, HoldDuration = 0, MaxActivationDistance = 10, RequiresLineOfSight = true, Enabled = true, Exclusivity = function() return Enum.ProximityPromptExclusivity.OnePerButton end, Style = function() return Enum.ProximityPromptStyle.Default end, UIOffset = function() return Vector2.zero end, ClickablePrompt = true, AutoLocalize = true },
	events = { "Triggered", "TriggerEnded", "PromptShown", "PromptHidden", "PromptButtonHoldBegan", "PromptButtonHoldEnded" },
	methods = {
		InputHoldBegin = function(self) local sig = priv[self].events.PromptButtonHoldBegan if sig then sig:Fire() end end,
		InputHoldEnd = function(self) local sig = priv[self].events.PromptButtonHoldEnded if sig then sig:Fire() end end,
	},
})
defclass("ClickDetector", "Instance", { defaults = { MaxActivationDistance = 32, CursorIcon = "" }, events = { "MouseClick", "RightMouseClick", "MouseHoverEnter", "MouseHoverLeave" } })
defclass("DragDetector", "ClickDetector")

-- effects / sound ----------------------------------------------------------------------------
defclass("Sound", "Instance", {
	defaults = { SoundId = "", Volume = 0.5, PlaybackSpeed = 1, Looped = false, Playing = false, IsPlaying = false, IsPaused = false, IsLoaded = true, TimeLength = 0, TimePosition = 0, PlaybackLoudness = 0, RollOffMaxDistance = 10000, RollOffMinDistance = 10, RollOffMode = function() return Enum.RollOffMode.InverseTapered end, SoundGroup = NIL, PlayOnRemove = false, ChannelCount = 2 },
	events = { "Ended", "Played", "Stopped", "Paused", "Resumed", "Loaded", "DidLoop" },
	methods = {
		Play = function(self)
			setProp(self, "Playing", true)
			setProp(self, "IsPlaying", true)
			setProp(self, "IsPaused", false)
			local sig = priv[self].events.Played
			if sig then sig:Fire(rawProp(self, "SoundId")) end
		end,
		Stop = function(self)
			setProp(self, "Playing", false)
			setProp(self, "IsPlaying", false)
			setProp(self, "TimePosition", 0)
			local sig = priv[self].events.Stopped
			if sig then sig:Fire(rawProp(self, "SoundId")) end
		end,
		Pause = function(self)
			setProp(self, "Playing", false)
			setProp(self, "IsPlaying", false)
			setProp(self, "IsPaused", true)
			local sig = priv[self].events.Paused
			if sig then sig:Fire(rawProp(self, "SoundId")) end
		end,
		Resume = function(self)
			setProp(self, "Playing", true)
			setProp(self, "IsPlaying", true)
			setProp(self, "IsPaused", false)
			local sig = priv[self].events.Resumed
			if sig then sig:Fire(rawProp(self, "SoundId")) end
		end,
	},
	setters = { Playing = function(self, _, v) if v then self:Play() else self:Stop() end end },
})
defclass("SoundGroup", "Instance", { defaults = { Volume = 0.5 } })
defclass("SoundEffect", "Instance", { defaults = { Enabled = true, Priority = 0 } })
for _, n in ipairs({ "ReverbSoundEffect", "EqualizerSoundEffect", "PitchShiftSoundEffect", "DistortionSoundEffect", "CompressorSoundEffect", "EchoSoundEffect", "ChorusSoundEffect", "FlangeSoundEffect", "TremoloSoundEffect" }) do defclass(n, "SoundEffect") end
defclass("ParticleEmitter", "Instance", {
	defaults = { Enabled = true, Rate = 20, Lifetime = function() return NumberRange.new(5, 10) end, Speed = function() return NumberRange.new(5) end, Color = function() return ColorSequence.new(Color3.new(1, 1, 1)) end, Size = function() return NumberSequence.new(1) end, Transparency = function() return NumberSequence.new(0) end, Texture = "", Acceleration = function() return Vector3.zero end, Drag = 0, EmissionDirection = function() return Enum.NormalId.Top end, SpreadAngle = function() return Vector2.zero end, Rotation = function() return NumberRange.new(0) end, RotSpeed = function() return NumberRange.new(0) end, LightEmission = 0, LightInfluence = 1, Orientation = function() return Enum.ParticleOrientation.FacingCamera end, Shape = function() return Enum.ParticleEmitterShape.Box end, Squash = function() return NumberSequence.new(0) end, ZOffset = 0, Brightness = 1, TimeScale = 1, VelocityInheritance = 0, LockedToPart = false, _emitted = 0 },
	methods = {
		Emit = function(self, n) priv[self].props._emitted = (rawProp(self, "_emitted") or 0) + (n or 16) end,
		Clear = function(self) end,
		FastForward = function() end,
	},
})
defclass("Beam", "Instance", { defaults = { Attachment0 = NIL, Attachment1 = NIL, Enabled = true, Color = function() return ColorSequence.new(Color3.new(1, 1, 1)) end, Transparency = function() return NumberSequence.new(0.5) end, Width0 = 1, Width1 = 1, Segments = 10, CurveSize0 = 0, CurveSize1 = 0, FaceCamera = false, LightEmission = 0, LightInfluence = 0, Texture = "", TextureLength = 1, TextureSpeed = 1, ZOffset = 0, Brightness = 1 }, methods = { SetTextureOffset = function() end } })
defclass("Trail", "Instance", { defaults = { Attachment0 = NIL, Attachment1 = NIL, Enabled = true, Color = function() return ColorSequence.new(Color3.new(1, 1, 1)) end, Transparency = function() return NumberSequence.new(0.5) end, Lifetime = 2, MinLength = 0.1, MaxLength = 0, WidthScale = function() return NumberSequence.new(1) end, FaceCamera = false, LightEmission = 0, LightInfluence = 0, Texture = "", TextureLength = 1, TextureMode = function() return Enum.TextureMode.Stretch end, Brightness = 1 }, methods = { Clear = function() end } })
defclass("Highlight", "Instance", { defaults = { Adornee = NIL, Enabled = true, FillColor = function() return Color3.fromRGB(255, 0, 0) end, FillTransparency = 0.5, OutlineColor = function() return Color3.new(1, 1, 1) end, OutlineTransparency = 0, DepthMode = function() return Enum.HighlightDepthMode.AlwaysOnTop end } })
defclass("Light", "Instance", { defaults = { Brightness = 1, Color = function() return Color3.new(1, 1, 1) end, Enabled = true, Shadows = false } })
defclass("PointLight", "Light", { defaults = { Range = 8 } })
defclass("SpotLight", "Light", { defaults = { Range = 16, Angle = 90, Face = function() return Enum.NormalId.Front end } })
defclass("SurfaceLight", "Light", { defaults = { Range = 16, Angle = 90, Face = function() return Enum.NormalId.Front end } })
defclass("Smoke", "Instance", { defaults = { Enabled = true, Color = function() return Color3.new(1, 1, 1) end, Opacity = 0.5, RiseVelocity = 1, Size = 1 } })
defclass("Fire", "Instance", { defaults = { Enabled = true, Color = function() return Color3.fromRGB(236, 139, 70) end, SecondaryColor = function() return Color3.fromRGB(139, 80, 55) end, Heat = 9, Size = 5 } })
defclass("Sparkles", "Instance", { defaults = { Enabled = true, SparkleColor = function() return Color3.new(0.56, 0.34, 1) end } })
defclass("Explosion", "Instance", { defaults = { BlastPressure = 500000, BlastRadius = 4, DestroyJointRadiusPercent = 1, ExplosionType = function() return Enum.ExplosionType.Craters end, Position = function() return Vector3.zero end, Visible = true }, events = { "Hit" } })
defclass("FaceInstance", "Instance", { defaults = { Face = function() return Enum.NormalId.Front end } })
defclass("Decal", "FaceInstance", { defaults = { Texture = "", Color3 = function() return Color3.new(1, 1, 1) end, Transparency = 0, ZIndex = 1 } })
defclass("Texture", "Decal", { defaults = { StudsPerTileU = 2, StudsPerTileV = 2, OffsetStudsU = 0, OffsetStudsV = 0 } })
defclass("SurfaceAppearance", "Instance", { defaults = { ColorMap = "", MetalnessMap = "", NormalMap = "", RoughnessMap = "", AlphaMode = function() return Enum.AlphaMode.Overlay end } })
defclass("DataModelMesh", "Instance", { defaults = { Offset = function() return Vector3.zero end, Scale = function() return Vector3.one end, VertexColor = function() return Vector3.one end } })
defclass("SpecialMesh", "DataModelMesh", { defaults = { MeshId = "", TextureId = "", MeshType = function() return Enum.MeshType.Head end } })
defclass("BlockMesh", "DataModelMesh")
defclass("CylinderMesh", "DataModelMesh")
defclass("FileMesh", "DataModelMesh", { defaults = { MeshId = "", TextureId = "" } })
defclass("Sky", "Instance", { defaults = { SkyboxBk = "", SkyboxDn = "", SkyboxFt = "", SkyboxLf = "", SkyboxRt = "", SkyboxUp = "", CelestialBodiesShown = true, StarCount = 3000, SunAngularSize = 21, MoonAngularSize = 11, SunTextureId = "", MoonTextureId = "" } })
defclass("Atmosphere", "Instance", { defaults = { Density = 0.395, Offset = 0, Color = function() return Color3.fromRGB(199, 170, 107) end, Decay = function() return Color3.fromRGB(106, 112, 125) end, Glare = 0, Haze = 0 } })
defclass("Clouds", "Instance", { defaults = { Cover = 0.5, Density = 0.7, Color = function() return Color3.new(1, 1, 1) end, Enabled = true } })
defclass("PostEffect", "Instance", { defaults = { Enabled = true } })
for _, n in ipairs({ "BloomEffect", "BlurEffect", "ColorCorrectionEffect", "SunRaysEffect", "DepthOfFieldEffect", "ColorGradingEffect" }) do defclass(n, "PostEffect") end
classes.ColorCorrectionEffect.defaults = { Enabled = true, Brightness = 0, Contrast = 0, Saturation = 0, TintColor = function() return Color3.new(1, 1, 1) end }
classes.BlurEffect.defaults = { Enabled = true, Size = 24 }
classes.BloomEffect.defaults = { Enabled = true, Intensity = 0.4, Size = 24, Threshold = 0.95 }
resolved = {}

-- values -------------------------------------------------------------------------------------
defclass("ValueBase", "Instance")
defclass("IntValue", "ValueBase", { defaults = { Value = 0 }, setters = { Value = function(self, _, v) setProp(self, "Value", math.floor(tonumber(v) or 0)) end } })
defclass("NumberValue", "ValueBase", { defaults = { Value = 0 } })
defclass("StringValue", "ValueBase", { defaults = { Value = "" } })
defclass("BoolValue", "ValueBase", { defaults = { Value = false } })
defclass("ObjectValue", "ValueBase", { defaults = { Value = NIL } })
defclass("CFrameValue", "ValueBase", { defaults = { Value = function() return CFrame.identity end } })
defclass("Vector3Value", "ValueBase", { defaults = { Value = function() return Vector3.zero end } })
defclass("Color3Value", "ValueBase", { defaults = { Value = function() return Color3.new(0, 0, 0) end } })
defclass("BrickColorValue", "ValueBase", { defaults = { Value = function() return BrickColor.new("Medium stone grey") end } })
defclass("RayValue", "ValueBase", { defaults = { Value = function() return Ray.new(Vector3.zero, Vector3.zero) end } })
defclass("IntConstrainedValue", "ValueBase", { defaults = { Value = 0, MinValue = 0, MaxValue = 10 } })
defclass("DoubleConstrainedValue", "ValueBase", { defaults = { Value = 0, MinValue = 0, MaxValue = 1 } })

-- scripts / containers -----------------------------------------------------------------------
defclass("LuaSourceContainer", "Instance")
defclass("BaseScript", "LuaSourceContainer", { defaults = { Disabled = false, Enabled = true, RunContext = function() return Enum.RunContext.Legacy end } })
defclass("Script", "BaseScript")
defclass("LocalScript", "BaseScript")
defclass("ModuleScript", "LuaSourceContainer")
defclass("Folder", "Instance")
defclass("Configuration", "Instance")
defclass("Actor", "Model")
defclass("WorldRoot", "Model")
defclass("Accoutrement", "Instance", { defaults = { AttachmentPoint = function() return CFrame.identity end } })
defclass("Accessory", "Accoutrement", { defaults = { AccessoryType = function() return Enum.AccessoryType.Unknown end } })
defclass("Hat", "Accoutrement")
defclass("BackpackItem", "Model", { defaults = { TextureId = "" } })
defclass("Tool", "BackpackItem", {
	defaults = { CanBeDropped = true, Enabled = true, Grip = function() return CFrame.identity end, ManualActivationOnly = false, RequiresHandle = true, ToolTip = "" },
	events = { "Activated", "Deactivated", "Equipped", "Unequipped" },
	methods = { Activate = function(self) local e = priv[self].events.Activated if e then e:Fire() end end },
})
defclass("HopperBin", "BackpackItem")
defclass("Backpack", "Instance")
defclass("StarterGear", "Instance")
defclass("StarterPack", "Instance")
defclass("BasePlayerGui", "Instance", { methods = { GetGuiObjectsAtPosition = function() return {} end } })
defclass("PlayerGui", "BasePlayerGui", { defaults = { ScreenOrientation = function() return Enum.ScreenOrientation.LandscapeSensor end, CurrentScreenOrientation = function() return Enum.ScreenOrientation.LandscapeLeft end, SelectionImageObject = NIL }, events = { "TopbarTransparencyChangedSignal" } })
defclass("PlayerScripts", "Instance", { methods = { ClearComputerCameraMovementModes = function() end, ClearComputerMovementModes = function() end, ClearTouchCameraMovementModes = function() end, ClearTouchMovementModes = function() end, RegisterComputerCameraMovementMode = function() end, RegisterComputerMovementMode = function() end, RegisterTouchCameraMovementMode = function() end, RegisterTouchMovementMode = function() end } })
defclass("StarterPlayerScripts", "Instance")
defclass("StarterCharacterScripts", "Instance")
defclass("Team", "Instance", { defaults = { TeamColor = function() return BrickColor.new("Bright blue") end, AutoAssignable = true, ChildOrder = 0 }, events = { "PlayerAdded", "PlayerRemoved" }, methods = { GetPlayers = function(self)
	local out = {}
	for _, p in ipairs(game:GetService("Players"):GetPlayers()) do
		if rawProp(p, "Team") == self then out[#out + 1] = p end
	end
	return out
end } })
defclass("Message", "Instance", { defaults = { Text = "" } })
defclass("Hint", "Message")
defclass("Dialog", "Instance", { defaults = { InitialPrompt = "", GoodbyeDialog = "", ConversationDistance = 25, Purpose = function() return Enum.DialogPurpose.Help end, Tone = function() return Enum.DialogTone.Neutral end, InUse = false }, events = { "DialogChoiceSelected" } })
defclass("DialogChoice", "Instance", { defaults = { UserDialog = "", ResponseDialog = "", GoodbyeDialog = "" } })
defclass("Handles", "Instance")
defclass("SelectionBox", "Instance", { defaults = { Adornee = NIL, Color3 = function() return Color3.new(0, 1, 1) end, LineThickness = 0.15, SurfaceTransparency = 1, Visible = true } })
defclass("BoxHandleAdornment", "Instance", { defaults = { Adornee = NIL, Size = function() return Vector3.one end, Color3 = function() return Color3.new(0, 1, 1) end, Transparency = 0, AlwaysOnTop = false, ZIndex = -1, Visible = true, CFrame = function() return CFrame.identity end } })
defclass("SphereHandleAdornment", "BoxHandleAdornment", { defaults = { Radius = 1 } })
defclass("CylinderHandleAdornment", "BoxHandleAdornment", { defaults = { Radius = 1, Height = 1 } })
defclass("ConeHandleAdornment", "BoxHandleAdornment")
defclass("LineHandleAdornment", "BoxHandleAdornment", { defaults = { Length = 5, Thickness = 1 } })
defclass("WireframeHandleAdornment", "BoxHandleAdornment", { methods = { AddLine = function() end, AddLines = function() end, AddPath = function() end, Clear = function() end } })
defclass("InputObject", "Instance", { defaults = { KeyCode = function() return Enum.KeyCode.Unknown end, UserInputType = function() return Enum.UserInputType.None end, UserInputState = function() return Enum.UserInputState.Begin end, Position = function() return Vector3.zero end, Delta = function() return Vector3.zero end }, methods = { IsModifierKeyDown = function() return false end } })
defclass("Mouse", "Instance", {
	defaults = { Hit = function() return CFrame.identity end, Target = NIL, TargetSurface = function() return Enum.NormalId.Top end, X = 640, Y = 360, ViewSizeX = 1280, ViewSizeY = 720, Icon = "", TargetFilter = NIL, UnitRay = function() return Ray.new(Vector3.zero, Vector3.new(0, 0, -1)) end, Origin = function() return CFrame.identity end },
	events = { "Button1Down", "Button1Up", "Button2Down", "Button2Up", "Move", "WheelForward", "WheelBackward", "Idle", "KeyDown", "KeyUp" },
})
defclass("Path", "Instance", {
	defaults = { Status = function() return Enum.PathStatus.NoPath end, _waypoints = function() return {} end },
	events = { "Blocked", "Unblocked" },
	methods = {
		ComputeAsync = function(self, from, to)
			local wps = {}
			local n = math.max(2, math.ceil((to - from).Magnitude / 4))
			for i = 0, n do
				local p = from:Lerp(to, i / n)
				wps[#wps + 1] = { Position = p, Action = Enum.PathWaypointAction.Walk, Label = "" }
			end
			priv[self].props._waypoints = wps
			setProp(self, "Status", Enum.PathStatus.Success)
		end,
		GetWaypoints = function(self) return tcopy(rawProp(self, "_waypoints")) end,
		CheckOcclusionAsync = function() return -1 end,
	},
})
defclass("Tween", "Instance") -- behaviour filled by TweenService
defclass("TweenBase", "Tween")
defclass("RemoteEvent", "Instance", { events = { "OnServerEvent", "OnClientEvent" } })
defclass("UnreliableRemoteEvent", "RemoteEvent")
defclass("RemoteFunction", "Instance", { defaults = { OnServerInvoke = NIL, OnClientInvoke = NIL } })
defclass("BindableEvent", "Instance", { events = { "Event" } })
defclass("BindableFunction", "Instance", { defaults = { OnInvoke = NIL } })
defclass("TextChannel", "Instance", { events = { "MessageReceived" }, defaults = { Name = "RBXGeneral" } })
defclass("TextSource", "Instance")
defclass("TextChatMessage", "Instance")
defclass("TextChatCommand", "Instance", { defaults = { PrimaryAlias = "", SecondaryAlias = "", Enabled = true, AutocompleteVisible = true }, events = { "Triggered" } })
defclass("ChatInputBarConfiguration", "Instance", { defaults = { Enabled = true } })
defclass("ChatWindowConfiguration", "Instance", { defaults = { Enabled = true } })
defclass("BubbleChatConfiguration", "Instance", { defaults = { Enabled = true } })
defclass("Player", "Instance", {
	defaults = {
		UserId = 0, DisplayName = "", Character = NIL, Team = NIL, TeamColor = function() return BrickColor.new("White") end, Neutral = true, AccountAge = 100,
		MembershipType = function() return Enum.MembershipType.None end, CharacterAppearanceId = 0, CanLoadCharacterAppearance = true, CameraMode = function() return Enum.CameraMode.Classic end,
		CameraMaxZoomDistance = 400, CameraMinZoomDistance = 0.5, DevCameraOcclusionMode = function() return Enum.DevCameraOcclusionMode.Zoom end,
		DevComputerCameraMode = function() return Enum.DevComputerCameraMovementMode.UserChoice end, DevComputerMovementMode = function() return Enum.DevComputerMovementMode.UserChoice end,
		DevTouchCameraMode = function() return Enum.DevTouchCameraMovementMode.UserChoice end, DevTouchMovementMode = function() return Enum.DevTouchMovementMode.UserChoice end,
		DevEnableMouseLock = true, HealthDisplayDistance = 100, NameDisplayDistance = 100, RespawnLocation = NIL, ReplicationFocus = NIL, AutoJumpEnabled = true,
		LocaleId = "en-us", FollowUserId = 0, GameplayPaused = false, HasVerifiedBadge = false, _kicked = NIL,
	},
	events = { "CharacterAdded", "CharacterRemoving", "CharacterAppearanceLoaded", "Chatted", "Idled", "OnTeleport" },
	methods = {
		Kick = function(self, message)
			priv[self].props._kicked = message or ""
			task.defer(function() if shim.removePlayer then shim.removePlayer(self) end end)
		end,
		LoadCharacter = function(self) shim.spawnCharacter(self) end,
		LoadCharacterWithHumanoidDescription = function(self) shim.spawnCharacter(self) end,
		GetMouse = function(self)
			local m = rawProp(self, "_mouse")
			if not m then
				m = new("Mouse")
				priv[self].props._mouse = m
			end
			return m
		end,
		IsFriendsWith = function() return false end,
		GetFriendsOnline = function() return {} end,
		DistanceFromCharacter = function(self, point)
			local char = rawProp(self, "Character")
			local head = char and findChildByName(priv[char], "Head")
			if not head then return 0 end
			return (rawProp(head, "CFrame").Position - point).Magnitude
		end,
		GetRankInGroup = function() return 0 end,
		GetRoleInGroup = function() return "Guest" end,
		IsInGroup = function() return false end,
		GetJoinData = function() return { SourceGameId = 0, SourcePlaceId = 0, Members = {}, TeleportData = nil, LaunchData = "" } end,
		HasAppearanceLoaded = function() return true end,
		RequestStreamAroundAsync = function() end,
		GetNetworkPing = function() return 0.05 end,
		SetSuperSafeChat = function() end,
		Move = function(self, dir)
			local char = rawProp(self, "Character")
			local hum = char and findChildByName(priv[char], "Humanoid")
			if hum then hum:Move(dir) end
		end,
		ClearCharacterAppearance = function() end,
		GetUnder13 = function() return false end,
	},
})
defclass("Explorer", "Instance")

---- SECTION 7: services and DataModel ----------------------------------------------------

local services = {}        -- name -> instance (current DataModel)
local collisionGroups = {} -- name -> { [other] = false } (false = not collidable)
local activeTweens = {}
local renderBindings = {}
local actionBindings = {}  -- ContextActionService: name -> binding
local actionOrder = {}
shim.datastore = { data = {}, failNextCalls = 0, latency = 0, calls = {} }
shim.marketplace = { prompts = {}, ownedPasses = {}, productInfo = {} }
shim.input = {}
shim.remoteLog = {}
shim.remoteCopy = true
shim.humanoidMoveToTeleports = false

function Inst.collisionGroupsCollidable(a, b)
	a = a or "Default"
	b = b or "Default"
	local row = collisionGroups[a]
	if row and row[b] == false then return false end
	local row2 = collisionGroups[b]
	if row2 and row2[a] == false then return false end
	return true
end

local function getService(name)
	local s = services[name]
	if s then return s end
	if type(name) ~= "string" then fail(3, "GetService expects a string, got %s", nativeTypeof(name)) end
	s = new(name)
	priv[s].isService = true
	services[name] = s
	setParent(s, game)
	return s
end
shim.getService = function(name) return getService(name) end

local function requireGame()
	if not game then fail(3, "The DataModel has not been built yet (call shim.reset())") end
	return game
end

-- DataModel ------------------------------------------------------------------------------------
defclass("ServiceProvider", "Instance", {
	methods = {
		GetService = function(self, name) return getService(name) end,
		FindService = function(self, name) return services[name] end,
		service = function(self, name) return getService(name) end,
	},
	events = { "Close", "ServiceAdded", "ServiceRemoving" },
})
defclass("DataModel", "ServiceProvider", {
	defaults = { JobId = "test-job", PlaceId = 0, PlaceVersion = 0, PrivateServerId = "", PrivateServerOwnerId = 0, CreatorId = 0, CreatorType = function() return Enum.CreatorType.User end, GameId = 0, Genre = function() return Enum.Genre.All end, GearGenreSetting = function() return Enum.GearGenreSetting.AllGenres end, VIPServerId = "", VIPServerOwnerId = 0, MatchmakingType = NIL },
	events = { "Loaded", "GraphicsQualityChangeRequest" },
	methods = {
		BindToClose = function(self, fn)
			if not isCallable(fn) then fail(2, "BindToClose expects a function") end
			table.insert(shim.boundToClose, fn)
		end,
		IsLoaded = function() return true end,
		GetJobsInfo = function() return {} end,
		SetPlaceId = function(self, id) setProp(self, "PlaceId", id) end,
		SetUniverseId = function(self, id) setProp(self, "GameId", id) end,
		Shutdown = function() end,
		HttpGet = function() fail(2, "HttpGet is not available in the offline harness") end,
		HttpPost = function() fail(2, "HttpPost is not available in the offline harness") end,
		GetObjects = function() return {} end,
		DefineFastFlag = function() return false end,
		GetFastFlag = function() return false end,
		GetEngineFeature = function() return false end,
		IsContentLoaded = function() return true end,
	},
	getters = {
		Workspace = function() return getService("Workspace") end,
		workspace = function() return getService("Workspace") end,
		Lighting = function() return getService("Lighting") end,
		Players = function() return getService("Players") end,
		ReplicatedStorage = function() return getService("ReplicatedStorage") end,
		ServerStorage = function() return getService("ServerStorage") end,
		ServerScriptService = function() return getService("ServerScriptService") end,
		StarterGui = function() return getService("StarterGui") end,
		StarterPlayer = function() return getService("StarterPlayer") end,
		StarterPack = function() return getService("StarterPack") end,
		SoundService = function() return getService("SoundService") end,
		ReplicatedFirst = function() return getService("ReplicatedFirst") end,
		Teams = function() return getService("Teams") end,
		Chat = function() return getService("Chat") end,
		TextChatService = function() return getService("TextChatService") end,
		Debris = function() return getService("Debris") end,
		MaterialService = function() return getService("MaterialService") end,
		LocalizationService = function() return getService("LocalizationService") end,
		VoiceChatService = function() return getService("VoiceChatService") end,
		TestService = function() return getService("TestService") end,
	},
})

-- Workspace ------------------------------------------------------------------------------------
local raycastOverride = nil
function shim.setRaycast(fn) raycastOverride = fn end

local function filterAllows(params, inst)
	if not params then return true end
	local list = params.FilterDescendantsInstances or {}
	local include = params.FilterType and params.FilterType.Value == 1
	local listed = false
	for _, f in ipairs(list) do
		if f == inst or (isInstance(f) and isInstance(inst) and inst:IsDescendantOf(f)) then listed = true break end
	end
	if include then return listed end
	return not listed
end
shim.raycastFilterAllows = filterAllows

local function defaultRaycast(origin, direction, params)
	if direction.Y >= 0 then return nil end
	if origin.Y < 0 then return nil end
	local t = origin.Y / -direction.Y
	if t > 1 then return nil end
	local terrain = getService("Workspace").Terrain
	if not filterAllows(params, terrain) then return nil end
	local pos = origin + direction * t
	return {
		Position = Vector3.new(pos.X, 0, pos.Z), Normal = Vector3.new(0, 1, 0), Material = Enum.Material.Grass,
		Instance = terrain, Distance = direction.Magnitude * t,
	}
end
shim.defaultRaycast = defaultRaycast

local function doRaycast(origin, direction, params)
	if not Vector3._is(origin) or not Vector3._is(direction) then fail(3, "Raycast expects (Vector3 origin, Vector3 direction, RaycastParams?)") end
	if raycastOverride then return raycastOverride(origin, direction, params) end
	return defaultRaycast(origin, direction, params)
end

local function partsInWorkspace()
	return descendantParts(getService("Workspace"))
end

defclass("Workspace", "WorldRoot", {
	defaults = {
		Gravity = 196.2, StreamingEnabled = false, StreamingMinRadius = 64, StreamingTargetRadius = 1024, FallenPartsDestroyHeight = -500,
		AirDensity = 0.0012, GlobalWind = function() return Vector3.zero end, StreamingIntegrityMode = function() return Enum.StreamingIntegrityMode.Default end,
		SignalBehavior = function() return Enum.SignalBehavior.Default end, ClientAnimatorThrottling = NIL, InterpolationThrottling = NIL, PhysicsSteppingMethod = NIL,
		CurrentCamera = NIL,
	},
	methods = {
		Raycast = function(self, origin, direction, params) return doRaycast(origin, direction, params) end,
		Blockcast = function(self, cf, size, direction, params) return doRaycast(cf.Position, direction, params) end,
		Spherecast = function(self, origin, radius, direction, params) return doRaycast(origin, direction, params) end,
		Shapecast = function(self, part, direction, params) return doRaycast(rawProp(part, "CFrame").Position, direction, params) end,
		FindPartOnRay = function(self, ray)
			local r = doRaycast(ray.Origin, ray.Direction, nil)
			if r then return r.Instance, r.Position, r.Normal, r.Material end
			return nil, ray.Origin + ray.Direction, Vector3.zero, Enum.Material.Air
		end,
		FindPartOnRayWithIgnoreList = function(self, ray, ignore)
			local params = RaycastParams.new()
			params.FilterDescendantsInstances = ignore or {}
			local r = doRaycast(ray.Origin, ray.Direction, params)
			if r then return r.Instance, r.Position, r.Normal, r.Material end
			return nil, ray.Origin + ray.Direction, Vector3.zero, Enum.Material.Air
		end,
		GetPartBoundsInRadius = function(self, position, radius, params)
			local out = {}
			for _, p in ipairs(partsInWorkspace()) do
				if filterAllows(params, p) and (rawProp(p, "CanQuery") ~= false) then
					local size = rawProp(p, "Size")
					local cf = rawProp(p, "CFrame")
					local lp = cf:PointToObjectSpace(position)
					local h = size / 2
					local dx = math.max(0, math.abs(lp.X) - h.X)
					local dy = math.max(0, math.abs(lp.Y) - h.Y)
					local dz = math.max(0, math.abs(lp.Z) - h.Z)
					if dx * dx + dy * dy + dz * dz <= radius * radius then out[#out + 1] = p end
				end
			end
			return out
		end,
		GetPartBoundsInBox = function(self, cf, size, params)
			local out = {}
			local h = size / 2
			for _, p in ipairs(partsInWorkspace()) do
				if filterAllows(params, p) and (rawProp(p, "CanQuery") ~= false) then
					local lp = cf:PointToObjectSpace(rawProp(p, "CFrame").Position)
					local ps = rawProp(p, "Size") / 2
					local r = math.max(ps.X, ps.Y, ps.Z)
					if math.abs(lp.X) <= h.X + r and math.abs(lp.Y) <= h.Y + r and math.abs(lp.Z) <= h.Z + r then out[#out + 1] = p end
				end
			end
			return out
		end,
		GetPartsInPart = function(self, part, params)
			local cf, size = rawProp(part, "CFrame"), rawProp(part, "Size")
			local out = {}
			for _, p in ipairs(self:GetPartBoundsInBox(cf, size, params)) do
				if p ~= part then out[#out + 1] = p end
			end
			return out
		end,
		ArePartsTouchingOthers = function() return false end,
		GetServerTimeNow = function() return DateTime._epochNow() end,
		GetRealPhysicsFPS = function() return 60 end,
		GetPhysicsThrottling = function() return 100 end,
		SetPhysicsThrottleEnabled = function() end,
		BulkMoveTo = function(self, parts, cframes)
			for i, p in ipairs(parts) do setProp(p, "CFrame", cframes[i]) end
		end,
		JoinToOutsiders = function() end,
		UnjoinFromOutsiders = function() end,
		PGSIsEnabled = function() return true end,
	},
	getters = {
		DistributedGameTime = function() return shim.clock - shim.clockStart end,
		Terrain = function(self) return findChildByName(priv[self], "Terrain") end,
	},
	onCreate = function(inst, s)
		s.name = "Workspace"
		local terrain = new("Terrain")
		setParent(terrain, inst)
		local cam = new("Camera")
		priv[cam].name = "Camera"
		setParent(cam, inst)
		s.props.CurrentCamera = cam
	end,
})

-- Players ----------------------------------------------------------------------------------
local function playerFromCharacter(character)
	if not isInstance(character) then return nil end
	for _, p in ipairs(priv[getService("Players")].children) do
		if priv[p].className == "Player" and rawProp(p, "Character") == character then return p end
	end
	return nil
end
Inst.playerFromCharacter = playerFromCharacter

defclass("Players", "Instance", {
	defaults = { LocalPlayer = NIL, MaxPlayers = 8, PreferredPlayers = 8, CharacterAutoLoads = true, RespawnTime = 5, BubbleChat = false, ClassicChat = true, UseStrafingAnimations = false },
	events = { "PlayerAdded", "PlayerRemoving", "PlayerChatted", "PlayerMembershipChanged" },
	methods = {
		GetPlayers = function(self)
			local out = {}
			for _, p in ipairs(priv[self].children) do
				if priv[p].className == "Player" then out[#out + 1] = p end
			end
			return out
		end,
		GetPlayerFromCharacter = function(self, character) return playerFromCharacter(character) end,
		GetPlayerByUserId = function(self, userId)
			for _, p in ipairs(self:GetPlayers()) do
				if rawProp(p, "UserId") == userId then return p end
			end
			return nil
		end,
		GetNameFromUserIdAsync = function(self, userId)
			local p = self:GetPlayerByUserId(userId)
			return p and priv[p].name or ("User" .. tostring(userId))
		end,
		GetUserIdFromNameAsync = function(self, name)
			for _, p in ipairs(self:GetPlayers()) do
				if priv[p].name == name then return rawProp(p, "UserId") end
			end
			return 0
		end,
		GetUserThumbnailAsync = function() return "rbxassetid://0", true end,
		GetHumanoidDescriptionFromUserId = function() return new("HumanoidDescription") end,
		GetHumanoidDescriptionFromOutfitId = function() return new("HumanoidDescription") end,
		CreateHumanoidModelFromUserId = function() return new("Model") end,
		CreateHumanoidModelFromDescription = function() return new("Model") end,
		BanAsync = function() end,
		UnbanAsync = function() end,
		GetBanHistoryAsync = function() return {} end,
		Chat = function() end,
		SetChatStyle = function() end,
		TeamChat = function() end,
		GetFriendsAsync = function() return { GetCurrentPage = function() return {} end, IsFinished = true, AdvanceToNextPageAsync = function() end } end,
		GetCharacterAppearanceInfoAsync = function() return {} end,
	},
})

local function buildCharacter(name)
	local model = new("Model")
	priv[model].name = name
	local function part(partName, size, offset)
		local p = new("Part")
		priv[p].name = partName
		setProp(p, "Size", size)
		setProp(p, "CFrame", CFrame.new(offset))
		setProp(p, "CanCollide", partName == "HumanoidRootPart" or partName == "Head" or partName == "UpperTorso" or partName == "LowerTorso")
		setProp(p, "Color", Color3.fromRGB(204, 142, 105))
		setProp(p, "CollisionGroup", "Players")
		setParent(p, model)
		return p
	end
	local root = part("HumanoidRootPart", Vector3.new(2, 2, 1), Vector3.new(0, 3, 0))
	setProp(root, "Transparency", 1)
	local head = part("Head", Vector3.new(1.2, 1.2, 1.2), Vector3.new(0, 4.5, 0))
	local upper = part("UpperTorso", Vector3.new(2, 1.6, 1), Vector3.new(0, 3.2, 0))
	local lower = part("LowerTorso", Vector3.new(2, 0.4, 1), Vector3.new(0, 2.2, 0))
	local parts = {
		{ "LeftUpperArm", Vector3.new(1, 1.2, 1), Vector3.new(-1.5, 3.5, 0) }, { "RightUpperArm", Vector3.new(1, 1.2, 1), Vector3.new(1.5, 3.5, 0) },
		{ "LeftLowerArm", Vector3.new(1, 1.2, 1), Vector3.new(-1.5, 2.3, 0) }, { "RightLowerArm", Vector3.new(1, 1.2, 1), Vector3.new(1.5, 2.3, 0) },
		{ "LeftHand", Vector3.new(1, 0.3, 1), Vector3.new(-1.5, 1.5, 0) }, { "RightHand", Vector3.new(1, 0.3, 1), Vector3.new(1.5, 1.5, 0) },
		{ "LeftUpperLeg", Vector3.new(1, 1.2, 1), Vector3.new(-0.5, 1.4, 0) }, { "RightUpperLeg", Vector3.new(1, 1.2, 1), Vector3.new(0.5, 1.4, 0) },
		{ "LeftLowerLeg", Vector3.new(1, 1.2, 1), Vector3.new(-0.5, 0.6, 0) }, { "RightLowerLeg", Vector3.new(1, 1.2, 1), Vector3.new(0.5, 0.6, 0) },
		{ "LeftFoot", Vector3.new(1, 0.3, 1), Vector3.new(-0.5, 0.15, 0) }, { "RightFoot", Vector3.new(1, 0.3, 1), Vector3.new(0.5, 0.15, 0) },
	}
	for _, p in ipairs(parts) do part(p[1], p[2], p[3]) end
	local function motor(partName, parentPart, p0, p1)
		local m = new("Motor6D")
		priv[m].name = partName
		setProp(m, "Part0", p0)
		setProp(m, "Part1", p1)
		setParent(m, parentPart)
	end
	motor("RootJoint", lower, root, lower)
	motor("Waist", upper, lower, upper)
	motor("Neck", head, upper, head)
	local humanoid = new("Humanoid")
	setParent(humanoid, model)
	setProp(humanoid, "DisplayName", name)
	setProp(model, "PrimaryPart", root)
	return model
end
shim.buildCharacter = buildCharacter

function shim.addPlayer(name, userId, opts)
	opts = opts or {}
	local players = getService("Players")
	name = name or ("Player" .. tostring(#players:GetPlayers() + 1))
	userId = userId or (1000 + #players:GetPlayers() + 1)
	local p = new("Player")
	local ps = priv[p]
	ps.name = name
	ps.props.UserId = userId
	ps.props.DisplayName = opts.displayName or name
	for _, childClass in ipairs({ "PlayerGui", "Backpack", "PlayerScripts", "StarterGear" }) do
		local c = new(childClass)
		setParent(c, p)
	end
	setParent(p, players)
	local sig = priv[players].events.PlayerAdded
	if sig then sig:Fire(p) end
	if opts.character then shim.spawnCharacter(p) end
	return p
end

function shim.spawnCharacter(player, cframe)
	local ps = st(player, "spawnCharacter")
	local old = rawProp(player, "Character")
	if old and not priv[old].destroyed then
		local sig = ps.events.CharacterRemoving
		if sig then sig:Fire(old) end
		destroyInstance(old)
	end
	local model = buildCharacter(ps.name)
	if cframe then model:PivotTo(cframe) end
	ps.props.Character = model
	firePropertyChanged(player, ps, "Character", model)
	setParent(model, getService("Workspace"))
	local sig = ps.events.CharacterAdded
	if sig then sig:Fire(model) end
	local appear = ps.events.CharacterAppearanceLoaded
	if appear then appear:Fire(model) end
	return model
end

function shim.removePlayer(player)
	local ps = st(player, "removePlayer")
	if ps.destroyed then return end
	local players = getService("Players")
	local sig = priv[players].events.PlayerRemoving
	if sig then sig:Fire(player) end
	local char = rawProp(player, "Character")
	if char and not priv[char].destroyed then
		local cr = ps.events.CharacterRemoving
		if cr then cr:Fire(char) end
		destroyInstance(char)
		ps.props.Character = NIL
	end
	destroyInstance(player)
end

function shim.setLocalPlayer(player)
	setProp(getService("Players"), "LocalPlayer", player)
end

-- RunService -------------------------------------------------------------------------------
defclass("RunService", "Instance", {
	events = { "Heartbeat", "Stepped", "RenderStepped", "PreRender", "PreAnimation", "PreSimulation", "PostSimulation" },
	methods = {
		IsServer = function() return shim.context == "server" end,
		IsClient = function() return shim.context == "client" end,
		IsStudio = function() return shim.isStudio == true end,
		IsRunning = function() return true end,
		IsRunMode = function() return false end,
		IsEdit = function() return false end,
		BindToRenderStep = function(self, name, priority, fn)
			if not isCallable(fn) then fail(2, "BindToRenderStep expects a function") end
			for i, b in ipairs(renderBindings) do
				if b.name == name then table.remove(renderBindings, i) break end
			end
			table.insert(renderBindings, { name = name, priority = priority, fn = fn })
			table.sort(renderBindings, function(a, b) return a.priority < b.priority end)
		end,
		UnbindFromRenderStep = function(self, name)
			for i, b in ipairs(renderBindings) do
				if b.name == name then table.remove(renderBindings, i) return end
			end
		end,
		Pause = function() end, Run = function() end, Stop = function() end,
		Set3dRenderingEnabled = function() end,
	},
})

local function runServiceStep(dt)
	local rs = services.RunService
	local evs = rs and priv[rs].events
	local gameTime = shim.clock - shim.clockStart
	if shim.context == "client" then
		for _, b in ipairs(tcopy(renderBindings)) do
			local ok, err = pcall(b.fn, dt)
			if not ok then recordThreadError("BindToRenderStep '" .. tostring(b.name) .. "': " .. tostring(err)) end
		end
		if evs then
			if evs.PreRender then evs.PreRender:Fire(dt) end
			if evs.RenderStepped then evs.RenderStepped:Fire(dt) end
		end
	end
	if evs then
		if evs.PreAnimation then evs.PreAnimation:Fire(dt) end
		if evs.PreSimulation then evs.PreSimulation:Fire(dt) end
		if evs.Stepped then evs.Stepped:Fire(gameTime, dt) end
		if evs.PostSimulation then evs.PostSimulation:Fire(dt) end
		if evs.Heartbeat then evs.Heartbeat:Fire(dt) end
	end
end

-- TweenService -------------------------------------------------------------------------------
local function ease(alpha, style, direction)
	local s = style and style.Name or "Linear"
	local d = direction and direction.Name or "Out"
	local function easeIn(t)
		if s == "Linear" then return t
		elseif s == "Quad" then return t * t
		elseif s == "Cubic" then return t * t * t
		elseif s == "Quart" then return t * t * t * t
		elseif s == "Quint" then return t * t * t * t * t
		elseif s == "Sine" then return 1 - math.cos(t * math.pi / 2)
		elseif s == "Exponential" then return t == 0 and 0 or 2 ^ (10 * (t - 1))
		elseif s == "Circular" then return 1 - math.sqrt(1 - t * t)
		elseif s == "Back" then local c = 1.70158 return t * t * ((c + 1) * t - c)
		elseif s == "Elastic" then
			if t == 0 or t == 1 then return t end
			return -(2 ^ (10 * (t - 1))) * math.sin((t - 1.075) * (2 * math.pi) / 0.3)
		elseif s == "Bounce" then
			t = 1 - t
			local r
			if t < 1 / 2.75 then r = 7.5625 * t * t
			elseif t < 2 / 2.75 then t -= 1.5 / 2.75 r = 7.5625 * t * t + 0.75
			elseif t < 2.5 / 2.75 then t -= 2.25 / 2.75 r = 7.5625 * t * t + 0.9375
			else t -= 2.625 / 2.75 r = 7.5625 * t * t + 0.984375 end
			return 1 - r
		end
		return t
	end
	if d == "In" then return easeIn(alpha)
	elseif d == "Out" then return 1 - easeIn(1 - alpha)
	else
		if alpha < 0.5 then return easeIn(alpha * 2) / 2 end
		return 1 - easeIn((1 - alpha) * 2) / 2
	end
end

local function lerpValue(a, b, t)
	if type(a) == "number" then return a + (b - a) * t end
	if type(a) == "table" then
		local mt = getmetatable(a)
		local ty = mt and rawget(mt, "__type")
		if ty == "Vector3" or ty == "Vector2" or ty == "CFrame" or ty == "Color3" or ty == "UDim2" then return a:Lerp(b, t) end
		if ty == "UDim" then return UDim.new(a.Scale + (b.Scale - a.Scale) * t, a.Offset + (b.Offset - a.Offset) * t) end
		if ty == "NumberRange" then return NumberRange.new(lerpValue(a.Min, b.Min, t), lerpValue(a.Max, b.Max, t)) end
		if ty == "Rect" then return Rect.new(a.Min:Lerp(b.Min, t), a.Max:Lerp(b.Max, t)) end
	end
	return t >= 1 and b or a
end

local function finishTween(tween, state)
	local ts = priv[tween]
	if ts.props._active then
		ts.props._active = false
		for i, t in ipairs(activeTweens) do
			if t == tween then table.remove(activeTweens, i) break end
		end
	end
	setProp(tween, "PlaybackState", state)
	local sig = ts.events.Completed
	if sig then sig:Fire(state) end
end

local function updateTween(tween)
	local ts = priv[tween]
	local info = rawProp(tween, "TweenInfo")
	local inst = rawProp(tween, "Instance")
	if not inst or priv[inst].destroyed then finishTween(tween, Enum.PlaybackState.Cancelled) return end
	local elapsed = shim.clock - rawProp(tween, "_startClock") - info.DelayTime
	if elapsed < 0 then setProp(tween, "PlaybackState", Enum.PlaybackState.Delayed) return end
	if rawProp(tween, "PlaybackState") ~= Enum.PlaybackState.Playing then setProp(tween, "PlaybackState", Enum.PlaybackState.Playing) end
	local duration = math.max(info.Time, 1e-9)
	local cycleLen = info.Reverses and duration * 2 or duration
	local cycles = math.floor(elapsed / cycleLen)
	local props = rawProp(tween, "_props")
	local starts = rawProp(tween, "_starts")
	if info.RepeatCount >= 0 and cycles > info.RepeatCount then
		for k, target in pairs(props) do inst[k] = info.Reverses and starts[k] or target end
		finishTween(tween, Enum.PlaybackState.Completed)
		return
	end
	local t = elapsed % cycleLen
	local alpha
	if info.Reverses and t > duration then alpha = 1 - (t - duration) / duration else alpha = math.min(t / duration, 1) end
	alpha = ease(alpha, info.EasingStyle, info.EasingDirection)
	for k, target in pairs(props) do inst[k] = lerpValue(starts[k], target, alpha) end
end

local function tweenStep()
	for _, tween in ipairs(tcopy(activeTweens)) do
		if rawProp(tween, "_active") then updateTween(tween) end
	end
end

classes.Tween.defaults = { Instance = NIL, TweenInfo = NIL, PlaybackState = function() return Enum.PlaybackState.Begin end }
classes.Tween.events = { "Completed" }
eventNames.Completed = true
classes.Tween.methods = {
	Play = function(self)
		local ts = priv[self]
		local inst = rawProp(self, "Instance")
		if rawProp(self, "PlaybackState") == Enum.PlaybackState.Paused then
			ts.props._startClock = shim.clock - rawProp(self, "_pausedElapsed")
		else
			local starts = {}
			for k in pairs(rawProp(self, "_props")) do starts[k] = inst[k] end
			ts.props._starts = starts
			ts.props._startClock = shim.clock
		end
		setProp(self, "PlaybackState", Enum.PlaybackState.Playing)
		if shim.tweensInstant then
			for k, target in pairs(rawProp(self, "_props")) do inst[k] = target end
			ts.props._active = false
			task.defer(function()
				if rawProp(self, "PlaybackState") == Enum.PlaybackState.Playing then finishTween(self, Enum.PlaybackState.Completed) end
			end)
			return
		end
		if not rawProp(self, "_active") then
			ts.props._active = true
			table.insert(activeTweens, self)
		end
		updateTween(self)
	end,
	Pause = function(self)
		if rawProp(self, "PlaybackState") ~= Enum.PlaybackState.Playing and rawProp(self, "PlaybackState") ~= Enum.PlaybackState.Delayed then return end
		priv[self].props._pausedElapsed = shim.clock - rawProp(self, "_startClock")
		priv[self].props._active = false
		for i, t in ipairs(activeTweens) do if t == self then table.remove(activeTweens, i) break end end
		setProp(self, "PlaybackState", Enum.PlaybackState.Paused)
	end,
	Cancel = function(self)
		local state = rawProp(self, "PlaybackState")
		if state == Enum.PlaybackState.Completed or state == Enum.PlaybackState.Cancelled or state == Enum.PlaybackState.Begin then
			priv[self].props._active = false
			for i, t in ipairs(activeTweens) do if t == self then table.remove(activeTweens, i) break end end
			return
		end
		finishTween(self, Enum.PlaybackState.Cancelled)
	end,
}
allMethodNames.Play, allMethodNames.Pause, allMethodNames.Cancel = true, true, true
resolved = {}

defclass("TweenService", "Instance", {
	methods = {
		Create = function(self, inst, info, props)
			if not isInstance(inst) then fail(2, "TweenService:Create expects an Instance, got %s", nativeTypeof(inst)) end
			if nativeTypeof(info) ~= "table" or info.Time == nil then fail(2, "TweenService:Create expects a TweenInfo") end
			if type(props) ~= "table" then fail(2, "TweenService:Create expects a property table") end
			local tween = new("Tween")
			local ts = priv[tween]
			ts.props.Instance = inst
			ts.props.TweenInfo = info
			ts.props._props = tcopy(props)
			return tween
		end,
		GetValue = function(self, alpha, style, direction) return ease(alpha, style, direction) end,
		SmoothDamp = function(self, current, target, velocity, smoothTime, maxSpeed, dt)
			local t = math.min(1, (dt or 1 / 60) / math.max(smoothTime, 1e-6))
			return lerpValue(current, target, t), velocity
		end,
	},
})

-- Debris -------------------------------------------------------------------------------------
defclass("Debris", "Instance", {
	defaults = { MaxItems = 1000 },
	methods = {
		AddItem = function(self, inst, lifetime)
			if not isInstance(inst) then fail(2, "Debris:AddItem expects an Instance") end
			task.delay(lifetime or 10, function()
				if not priv[inst].destroyed then destroyInstance(inst) end
			end)
		end,
		SetLegacyMaxItems = function() end,
	},
})

-- DataStoreService ---------------------------------------------------------------------------
local function dsCheckValue(v, path)
	local t = type(v)
	if t == "nil" or t == "boolean" or t == "number" or t == "string" then return end
	if t == "table" then
		local mt = getmetatable(v)
		if mt ~= nil then fail(4, "Cannot store %s in data store (%s)", nativeTypeof(v), path) end
		local isArray = #v > 0
		for k, val in pairs(v) do
			if isArray and type(k) ~= "number" then fail(4, "Cannot store mixed array/dictionary in data store (%s)", path) end
			if type(k) ~= "string" and type(k) ~= "number" then fail(4, "Cannot store key of type %s in data store (%s)", type(k), path) end
			dsCheckValue(val, path .. "." .. tostring(k))
		end
		return
	end
	fail(4, "Cannot store %s in data store (%s)", t, path)
end

local function dsCall(store, method, key)
	local ds = shim.datastore
	table.insert(ds.calls, { store = rawProp(store, "_name"), method = method, key = key, clock = shim.clock })
	if ds.latency and ds.latency > 0 then shim.clock += ds.latency end
	if (ds.failNextCalls or 0) > 0 then
		ds.failNextCalls -= 1
		fail(4, "DataStore request failed (simulated)")
	end
	local data = ds.data[rawProp(store, "_name")]
	if not data then
		data = {}
		ds.data[rawProp(store, "_name")] = data
	end
	return data
end

local function makeKeyInfo(meta)
	meta = meta or {}
	return setmetatable({
		CreatedTime = (meta.created or DateTime._epochNow()) * 1000, UpdatedTime = (meta.updated or DateTime._epochNow()) * 1000, Version = tostring(meta.version or 1),
		GetUserIds = function() return tcopy(meta.userIds or {}) end,
		GetMetadata = function() return tcopy(meta.metadata or {}) end,
	}, { __type = "DataStoreKeyInfo" })
end

local function dsMeta(store, key)
	local metas = rawProp(store, "_meta")
	local m = metas[key]
	if not m then
		m = { created = DateTime._epochNow(), updated = DateTime._epochNow(), version = 0 }
		metas[key] = m
	end
	return m
end

defclass("GlobalDataStore", "Instance", {
	defaults = { _name = "", _meta = function() return {} end },
	events = {},
	methods = {
		GetAsync = function(self, key)
			if type(key) ~= "string" then fail(2, "DataStore key must be a string") end
			local data = dsCall(self, "GetAsync", key)
			local v = data[key]
			if v == nil then return nil end
			return deepCopy(v), makeKeyInfo(dsMeta(self, key))
		end,
		SetAsync = function(self, key, value, userIds, options)
			if type(key) ~= "string" then fail(2, "DataStore key must be a string") end
			dsCheckValue(value, key)
			local data = dsCall(self, "SetAsync", key)
			data[key] = deepCopy(value)
			local m = dsMeta(self, key)
			m.updated = DateTime._epochNow()
			m.version += 1
			m.userIds = userIds
			return tostring(m.version)
		end,
		UpdateAsync = function(self, key, transform)
			if type(key) ~= "string" then fail(2, "DataStore key must be a string") end
			if not isCallable(transform) then fail(2, "UpdateAsync expects a transform function") end
			local data = dsCall(self, "UpdateAsync", key)
			local current = deepCopy(data[key])
			local m = dsMeta(self, key)
			local newValue, userIds, metadata = transform(current, makeKeyInfo(m))
			if newValue == nil then return nil end
			dsCheckValue(newValue, key)
			data[key] = deepCopy(newValue)
			m.updated = DateTime._epochNow()
			m.version += 1
			if userIds then m.userIds = userIds end
			if metadata then m.metadata = metadata end
			return deepCopy(newValue), makeKeyInfo(m)
		end,
		RemoveAsync = function(self, key)
			local data = dsCall(self, "RemoveAsync", key)
			local old = data[key]
			data[key] = nil
			return old and deepCopy(old) or nil, old and makeKeyInfo(dsMeta(self, key)) or nil
		end,
		IncrementAsync = function(self, key, delta)
			local data = dsCall(self, "IncrementAsync", key)
			local cur = data[key]
			if cur ~= nil and type(cur) ~= "number" then fail(2, "IncrementAsync: existing value is not a number") end
			data[key] = (cur or 0) + (delta or 1)
			local m = dsMeta(self, key)
			m.updated = DateTime._epochNow()
			m.version += 1
			return data[key], makeKeyInfo(m)
		end,
		ListKeysAsync = function(self, prefix)
			local data = dsCall(self, "ListKeysAsync", prefix)
			local keys = {}
			for k in pairs(data) do
				if not prefix or k:sub(1, #prefix) == prefix then keys[#keys + 1] = { KeyName = k } end
			end
			table.sort(keys, function(a, b) return a.KeyName < b.KeyName end)
			return { GetCurrentPage = function() return keys end, IsFinished = true, AdvanceToNextPageAsync = function() end }
		end,
		OnUpdate = function() return Signal.new("OnUpdate"):Connect(function() end) end,
	},
})
defclass("DataStore", "GlobalDataStore")
defclass("OrderedDataStore", "GlobalDataStore", {
	methods = {
		GetSortedAsync = function(self, ascending, pageSize, minValue, maxValue)
			local data = dsCall(self, "GetSortedAsync", "")
			local rows = {}
			for k, v in pairs(data) do
				if type(v) == "number" and (not minValue or v >= minValue) and (not maxValue or v <= maxValue) then rows[#rows + 1] = { key = k, value = v } end
			end
			table.sort(rows, function(a, b)
				if a.value == b.value then return a.key < b.key end
				if ascending then return a.value < b.value end
				return a.value > b.value
			end)
			pageSize = pageSize or 50
			local pageIndex = 0
			local pages
			pages = setmetatable({ IsFinished = #rows <= pageSize }, { __type = "DataStorePages", __index = {
				GetCurrentPage = function()
					local out = {}
					for i = pageIndex * pageSize + 1, math.min(#rows, (pageIndex + 1) * pageSize) do out[#out + 1] = rows[i] end
					return out
				end,
				AdvanceToNextPageAsync = function()
					if pages.IsFinished then fail(2, "No more pages") end
					pageIndex += 1
					pages.IsFinished = #rows <= (pageIndex + 1) * pageSize
				end,
			} })
			return pages
		end,
	},
})
local function storeName(name, scope)
	if scope and scope ~= "" and scope ~= "global" then return name .. "/" .. scope end
	return name
end
defclass("DataStoreService", "Instance", {
	defaults = { AutomaticRetry = true, LegacyNamingScheme = false, _stores = function() return {} end },
	methods = {
		GetDataStore = function(self, name, scope)
			if type(name) ~= "string" or name == "" then fail(2, "GetDataStore expects a non-empty name") end
			local full = storeName(name, scope)
			local stores = rawProp(self, "_stores")
			local store = stores["D:" .. full]
			if not store then
				store = new("DataStore")
				priv[store].name = name
				priv[store].props._name = full
				stores["D:" .. full] = store
			end
			return store
		end,
		GetGlobalDataStore = function(self) return self:GetDataStore("__global") end,
		GetOrderedDataStore = function(self, name, scope)
			local full = storeName(name, scope)
			local stores = rawProp(self, "_stores")
			local store = stores["O:" .. full]
			if not store then
				store = new("OrderedDataStore")
				priv[store].name = name
				priv[store].props._name = full
				stores["O:" .. full] = store
			end
			return store
		end,
		GetRequestBudgetForRequestType = function() return 100 end,
		ListDataStoresAsync = function() return { GetCurrentPage = function() return {} end, IsFinished = true, AdvanceToNextPageAsync = function() end } end,
	},
})

-- HttpService (pure-Luau JSON) -----------------------------------------------------------------
local JSON = {}
shim.JSON = JSON
do
	local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
	local function encodeString(s)
		return '"' .. s:gsub('[%c"\\]', function(c) return escapes[c] or string.format("\\u%04x", c:byte()) end) .. '"'
	end
	local function isArray(t)
		local n = 0
		for k in pairs(t) do
			if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then return false end
			n += 1
		end
		return n == #t
	end
	local function encode(v, seen)
		local t = type(v)
		if t == "nil" then return "null"
		elseif t == "boolean" then return v and "true" or "false"
		elseif t == "number" then
			if v ~= v or v == math.huge or v == -math.huge then return "null" end
			if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
			return string.format("%.14g", v)
		elseif t == "string" then return encodeString(v)
		elseif t == "table" then
			if priv[v] then fail(3, "Can't encode an Instance (%s) as JSON", getFullName(v)) end
			if seen[v] then fail(3, "Can't encode cyclic table") end
			seen[v] = true
			local parts = {}
			if isArray(v) then
				for i = 1, #v do parts[i] = encode(v[i], seen) end
				seen[v] = nil
				return "[" .. table.concat(parts, ",") .. "]"
			end
			local keys = {}
			for k in pairs(v) do keys[#keys + 1] = k end
			table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
			for _, k in ipairs(keys) do
				if type(k) ~= "string" and type(k) ~= "number" then fail(3, "Can't encode table with key of type %s", type(k)) end
				parts[#parts + 1] = encodeString(tostring(k)) .. ":" .. encode(v[k], seen)
			end
			seen[v] = nil
			return "{" .. table.concat(parts, ",") .. "}"
		end
		fail(3, "Can't encode value of type %s", t)
	end
	function JSON.encode(v) return encode(v, {}) end

	local function decodeError(str, pos, msg)
		fail(4, "Can't parse JSON at position %d: %s", pos, msg)
	end
	local function skipWs(str, pos)
		local _, e = str:find("^[ \n\r\t]*", pos)
		return e + 1
	end
	local decodeValue
	local function decodeString(str, pos)
		local out = {}
		local i = pos + 1
		while true do
			local c = str:sub(i, i)
			if c == "" then decodeError(str, i, "unterminated string") end
			if c == '"' then return table.concat(out), i + 1 end
			if c == "\\" then
				local n = str:sub(i + 1, i + 1)
				if n == "u" then
					local hex = str:sub(i + 2, i + 5)
					local code = tonumber(hex, 16)
					if not code then decodeError(str, i, "bad unicode escape") end
					i += 6
					if code >= 0xD800 and code <= 0xDBFF and str:sub(i, i + 1) == "\\u" then
						local lo = tonumber(str:sub(i + 2, i + 5), 16)
						if lo and lo >= 0xDC00 and lo <= 0xDFFF then
							code = 0x10000 + (code - 0xD800) * 0x400 + (lo - 0xDC00)
							i += 6
						end
					end
					out[#out + 1] = utf8.char(code)
				else
					local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
					if not map[n] then decodeError(str, i, "bad escape") end
					out[#out + 1] = map[n]
					i += 2
				end
			else
				local j = str:find('["\\]', i)
				if not j then decodeError(str, i, "unterminated string") end
				out[#out + 1] = str:sub(i, j - 1)
				i = j
			end
		end
	end
	decodeValue = function(str, pos)
		pos = skipWs(str, pos)
		local c = str:sub(pos, pos)
		if c == "{" then
			local obj = {}
			pos = skipWs(str, pos + 1)
			if str:sub(pos, pos) == "}" then return obj, pos + 1 end
			while true do
				pos = skipWs(str, pos)
				if str:sub(pos, pos) ~= '"' then decodeError(str, pos, "expected string key") end
				local key
				key, pos = decodeString(str, pos)
				pos = skipWs(str, pos)
				if str:sub(pos, pos) ~= ":" then decodeError(str, pos, "expected ':'") end
				local val
				val, pos = decodeValue(str, pos + 1)
				obj[key] = val
				pos = skipWs(str, pos)
				local d = str:sub(pos, pos)
				if d == "," then pos += 1 elseif d == "}" then return obj, pos + 1 else decodeError(str, pos, "expected ',' or '}'") end
			end
		elseif c == "[" then
			local arr = {}
			pos = skipWs(str, pos + 1)
			if str:sub(pos, pos) == "]" then return arr, pos + 1 end
			local i = 0
			while true do
				local val
				val, pos = decodeValue(str, pos)
				i += 1
				arr[i] = val
				pos = skipWs(str, pos)
				local d = str:sub(pos, pos)
				if d == "," then pos += 1 elseif d == "]" then return arr, pos + 1 else decodeError(str, pos, "expected ',' or ']'") end
			end
		elseif c == '"' then
			return decodeString(str, pos)
		elseif str:sub(pos, pos + 3) == "true" then return true, pos + 4
		elseif str:sub(pos, pos + 4) == "false" then return false, pos + 5
		elseif str:sub(pos, pos + 3) == "null" then return nil, pos + 4
		else
			local numStr = str:match("^-?%d+%.?%d*[eE]?[-+]?%d*", pos)
			if not numStr or numStr == "" then decodeError(str, pos, "unexpected character '" .. c .. "'") end
			local n = tonumber(numStr)
			if not n then decodeError(str, pos, "bad number") end
			return n, pos + #numStr
		end
	end
	function JSON.decode(str)
		if type(str) ~= "string" then fail(3, "JSONDecode expects a string, got %s", nativeTypeof(str)) end
		local v, pos = decodeValue(str, 1)
		pos = skipWs(str, pos)
		if pos <= #str then decodeError(str, pos, "trailing characters") end
		return v
	end
end

local guidCounter = 0
defclass("HttpService", "Instance", {
	defaults = { HttpEnabled = false },
	methods = {
		GenerateGUID = function(self, wrap)
			guidCounter += 1
			local g = string.format("%08X-0000-4000-8000-%012X", guidCounter, guidCounter)
			if wrap == nil or wrap then g = "{" .. g .. "}" end
			return g
		end,
		JSONEncode = function(self, v) return JSON.encode(v) end,
		JSONDecode = function(self, s) return JSON.decode(s) end,
		UrlEncode = function(self, s)
			return (tostring(s):gsub("[^%w%-%_%.%~]", function(c) return string.format("%%%02X", c:byte()) end))
		end,
		GetAsync = function() fail(2, "HttpService:GetAsync is not available in the offline harness") end,
		PostAsync = function() fail(2, "HttpService:PostAsync is not available in the offline harness") end,
		RequestAsync = function() fail(2, "HttpService:RequestAsync is not available in the offline harness") end,
		GetUserAgent = function() return "Roblox/OfflineHarness" end,
		GetHttpEnabled = function() return false end,
		SetHttpEnabled = function() end,
	},
})

-- CollectionService ---------------------------------------------------------------------------
defclass("CollectionService", "Instance", {
	events = { "TagAdded", "TagRemoved" },
	methods = {
		AddTag = function(self, inst, tag) Inst.addTag(inst, tag) end,
		RemoveTag = function(self, inst, tag) Inst.removeTag(inst, tag) end,
		HasTag = function(self, inst, tag) return st(inst).tags[tag] == true end,
		GetTags = function(self, inst) return inst:GetTags() end,
		GetTagged = function(self, tag)
			local out = {}
			local set = tagRegistry.byTag[tag]
			if set then
				for _, inst in ipairs(set.list) do
					if not priv[inst].destroyed and isInDataModel(inst) then out[#out + 1] = inst end
				end
			end
			return out
		end,
		GetInstanceAddedSignal = function(self, tag)
			local sig = tagRegistry.addedSignals[tag]
			if not sig then
				sig = Signal.new("TagAdded:" .. tag)
				tagRegistry.addedSignals[tag] = sig
			end
			return sig
		end,
		GetInstanceRemovedSignal = function(self, tag)
			local sig = tagRegistry.removedSignals[tag]
			if not sig then
				sig = Signal.new("TagRemoved:" .. tag)
				tagRegistry.removedSignals[tag] = sig
			end
			return sig
		end,
		GetAllTags = function()
			local out = {}
			for tag, set in pairs(tagRegistry.byTag) do
				if #set.list > 0 then out[#out + 1] = tag end
			end
			table.sort(out)
			return out
		end,
	},
})

-- PhysicsService -----------------------------------------------------------------------------
defclass("PhysicsService", "Instance", {
	methods = {
		RegisterCollisionGroup = function(self, name)
			if type(name) ~= "string" or name == "" then fail(2, "RegisterCollisionGroup expects a non-empty name") end
			collisionGroups[name] = collisionGroups[name] or {}
		end,
		UnregisterCollisionGroup = function(self, name)
			collisionGroups[name] = nil
			for _, row in pairs(collisionGroups) do row[name] = nil end
		end,
		IsCollisionGroupRegistered = function(self, name) return collisionGroups[name] ~= nil end,
		CollisionGroupSetCollidable = function(self, a, b, collidable)
			if not collisionGroups[a] then fail(2, "Collision group '%s' is not registered", tostring(a)) end
			if not collisionGroups[b] then fail(2, "Collision group '%s' is not registered", tostring(b)) end
			collisionGroups[a][b] = collidable
			collisionGroups[b][a] = collidable
		end,
		CollisionGroupsAreCollidable = function(self, a, b)
			if not collisionGroups[a] then fail(2, "Collision group '%s' is not registered", tostring(a)) end
			if not collisionGroups[b] then fail(2, "Collision group '%s' is not registered", tostring(b)) end
			return Inst.collisionGroupsCollidable(a, b)
		end,
		GetRegisteredCollisionGroups = function()
			local out = {}
			for name in pairs(collisionGroups) do out[#out + 1] = { name = name, mask = 0 } end
			table.sort(out, function(a, b) return a.name < b.name end)
			return out
		end,
		GetMaxCollisionGroups = function() return 32 end,
		RenameCollisionGroup = function(self, from, to)
			collisionGroups[to] = collisionGroups[from]
			collisionGroups[from] = nil
		end,
		-- legacy API
		CreateCollisionGroup = function(self, name) collisionGroups[name] = collisionGroups[name] or {} end,
		CollisionGroupContainsPart = function(self, name, part) return rawProp(part, "CollisionGroup") == name end,
		SetPartCollisionGroup = function(self, part, name) setProp(part, "CollisionGroup", name) end,
	},
})

-- MarketplaceService --------------------------------------------------------------------------
defclass("MarketplaceService", "Instance", {
	defaults = { ProcessReceipt = NIL },
	events = { "PromptProductPurchaseFinished", "PromptPurchaseFinished", "PromptGamePassPurchaseFinished", "PromptBundlePurchaseFinished", "PromptSubscriptionPurchaseFinished", "PromptPremiumPurchaseFinished" },
	methods = {
		PromptProductPurchase = function(self, player, productId) table.insert(shim.marketplace.prompts, { kind = "Product", player = player, id = productId }) end,
		PromptPurchase = function(self, player, assetId) table.insert(shim.marketplace.prompts, { kind = "Asset", player = player, id = assetId }) end,
		PromptGamePassPurchase = function(self, player, passId) table.insert(shim.marketplace.prompts, { kind = "GamePass", player = player, id = passId }) end,
		PromptPremiumPurchase = function(self, player) table.insert(shim.marketplace.prompts, { kind = "Premium", player = player }) end,
		PromptBundlePurchase = function(self, player, id) table.insert(shim.marketplace.prompts, { kind = "Bundle", player = player, id = id }) end,
		PromptSubscriptionPurchase = function(self, player, id) table.insert(shim.marketplace.prompts, { kind = "Subscription", player = player, id = id }) end,
		GetProductInfo = function(self, id, infoType)
			local info = shim.marketplace.productInfo[id]
			if info then return deepCopy(info) end
			return { Name = "Product " .. tostring(id), Description = "", PriceInRobux = 0, ProductId = id, AssetId = id, IsForSale = true, IconImageAssetId = 0, ProductType = "Developer Product", Creator = { Id = 0, Name = "", CreatorType = "User" } }
		end,
		UserOwnsGamePassAsync = function(self, userId, passId)
			local owned = shim.marketplace.ownedPasses[userId]
			return owned ~= nil and owned[passId] == true
		end,
		PlayerOwnsAsset = function() return false end,
		PlayerOwnsBundle = function() return false end,
		GetDeveloperProductsAsync = function() return { GetCurrentPage = function() return {} end, IsFinished = true, AdvanceToNextPageAsync = function() end } end,
		GetSubscriptionProductInfoAsync = function(self, id) return { Name = "Subscription " .. tostring(id), DisplayPrice = "$0", Description = "" } end,
		GetUserSubscriptionStatusAsync = function() return { IsSubscribed = false, IsRenewing = false } end,
	},
})

function shim.marketplace.simulatePurchase(player, productId)
	local ms = getService("MarketplaceService")
	local handler = rawProp(ms, "ProcessReceipt")
	if not handler then return nil end
	local receipt = { PlayerId = rawProp(player, "UserId"), PlaceIdWherePurchased = 0, PurchaseId = "purchase-" .. tostring(#shim.marketplace.prompts + 1), ProductId = productId, CurrencySpent = 0, CurrencyType = Enum.CurrencyType.Robux }
	return handler(receipt)
end

-- UserInputService / ContextActionService ------------------------------------------------------
local function makeInputObject(keyCode, inputType, state, position, delta)
	local io = new("InputObject")
	local s = priv[io]
	s.props.KeyCode = keyCode or Enum.KeyCode.Unknown
	s.props.UserInputType = inputType or Enum.UserInputType.Keyboard
	s.props.UserInputState = state or Enum.UserInputState.Begin
	s.props.Position = position or Vector3.zero
	s.props.Delta = delta or Vector3.zero
	return io
end
shim.input.makeInputObject = makeInputObject
shim.input.lastInputType = nil
shim.input.keysDown = {}

defclass("UserInputService", "Instance", {
	defaults = { TouchEnabled = false, KeyboardEnabled = true, MouseEnabled = true, GamepadEnabled = false, AccelerometerEnabled = false, GyroscopeEnabled = false, VREnabled = false, MouseIconEnabled = true, MouseBehavior = function() return Enum.MouseBehavior.Default end, MouseDeltaSensitivity = 1, ModalEnabled = false, OnScreenKeyboardVisible = false, OnScreenKeyboardPosition = function() return Vector2.zero end, OnScreenKeyboardSize = function() return Vector2.zero end, OverrideMouseIconBehavior = NIL, LegacyInputEventsEnabled = true, PreferredInput = NIL },
	events = { "InputBegan", "InputChanged", "InputEnded", "TouchTap", "TouchStarted", "TouchEnded", "TouchMoved", "TouchLongPress", "TouchPan", "TouchPinch", "TouchRotate", "TouchSwipe", "LastInputTypeChanged", "JumpRequest", "WindowFocused", "WindowFocusReleased", "GamepadConnected", "GamepadDisconnected", "TextBoxFocused", "TextBoxFocusReleased", "DeviceAccelerationChanged", "DeviceGravityChanged", "DeviceRotationChanged", "PointerAction" },
	methods = {
		GetLastInputType = function() return shim.input.lastInputType or Enum.UserInputType.MouseMovement end,
		IsKeyDown = function(self, key) return shim.input.keysDown[key] == true end,
		IsMouseButtonPressed = function(self, button) return shim.input.keysDown[button] == true end,
		IsGamepadButtonDown = function() return false end,
		GetMouseLocation = function() return shim.input.mouseLocation or Vector2.new(640, 360) end,
		GetMouseDelta = function() return Vector2.zero end,
		GetGamepadState = function() return {} end,
		GetConnectedGamepads = function() return {} end,
		GetNavigationGamepads = function() return {} end,
		GetGamepadConnected = function() return false end,
		GamepadSupports = function() return true end,
		GetKeysPressed = function()
			local out = {}
			for k in pairs(shim.input.keysDown) do out[#out + 1] = makeInputObject(k, Enum.UserInputType.Keyboard, Enum.UserInputState.Begin) end
			return out
		end,
		GetMouseButtonsPressed = function() return {} end,
		GetStringForKeyCode = function(self, key) return key.Name end,
		GetImageForKeyCode = function() return "" end,
		GetFocusedTextBox = function() return nil end,
		GetDeviceType = function() return Enum.DeviceType.Desktop end,
		GetPlatform = function() return Enum.Platform.Windows end,
		GetDeviceAcceleration = function() return makeInputObject(nil, Enum.UserInputType.Accelerometer) end,
		GetDeviceGravity = function() return makeInputObject(nil, Enum.UserInputType.Gyro) end,
		GetDeviceRotation = function() return 0, CFrame.identity end,
		SetNavigationGamepad = function() end,
		IsNavigationGamepad = function() return false end,
		RecenterUserHeadCFrame = function() end,
		GetUserCFrame = function() return CFrame.identity end,
	},
})

-- simulate key presses: fires UserInputService.InputBegan/Ended and ContextActionService bindings
local function dispatchAction(binding, state, io)
	local ok, result = pcall(binding.fn, binding.name, state, io)
	if not ok then
		recordThreadError("ContextAction '" .. tostring(binding.name) .. "': " .. tostring(result))
		return Enum.ContextActionResult.Sink
	end
	if result == Enum.ContextActionResult.Pass then return result end
	return Enum.ContextActionResult.Sink
end

local function bindingsForInput(io)
	local list = {}
	for _, name in ipairs(actionOrder) do
		local b = actionBindings[name]
		if b then
			for _, key in ipairs(b.keys) do
				if key == io.KeyCode or key == io.UserInputType then list[#list + 1] = b break end
			end
		end
	end
	-- highest priority first; later bindings first among equals
	table.sort(list, function(a, b)
		if a.priority ~= b.priority then return a.priority > b.priority end
		return a.order > b.order
	end)
	return list
end

local function fireInput(keyCode, inputType, state, gameProcessed)
	local uis = getService("UserInputService")
	inputType = inputType or (keyCode and Enum.UserInputType.Keyboard or Enum.UserInputType.MouseButton1)
	local io = makeInputObject(keyCode, inputType, state)
	if shim.input.lastInputType ~= inputType then
		shim.input.lastInputType = inputType
		local sig = priv[uis].events.LastInputTypeChanged
		if sig then sig:Fire(inputType) end
	end
	local sunk = false
	for _, b in ipairs(bindingsForInput(io)) do
		if dispatchAction(b, state, io) ~= Enum.ContextActionResult.Pass then sunk = true break end
	end
	local evName = state == Enum.UserInputState.Begin and "InputBegan" or state == Enum.UserInputState.Change and "InputChanged" or "InputEnded"
	local sig = priv[uis].events[evName]
	if sig then sig:Fire(io, gameProcessed == true or sunk) end
	return io
end

function shim.input.press(keyCode, inputType)
	shim.input.keysDown[keyCode] = true
	return fireInput(keyCode, inputType, Enum.UserInputState.Begin)
end
function shim.input.release(keyCode, inputType)
	shim.input.keysDown[keyCode] = nil
	return fireInput(keyCode, inputType, Enum.UserInputState.End)
end
function shim.input.tap(keyCode, inputType)
	shim.input.press(keyCode, inputType)
	return shim.input.release(keyCode, inputType)
end

function shim.triggerAction(name, state, io)
	local b = actionBindings[name]
	if not b then fail(2, "shim.triggerAction: no action named '%s' is bound", tostring(name)) end
	state = state or Enum.UserInputState.Begin
	io = io or makeInputObject(b.keys[1], Enum.UserInputType.Keyboard, state)
	return dispatchAction(b, state, io)
end

defclass("ContextActionService", "Instance", {
	events = { "LocalToolEquipped", "LocalToolUnequipped" },
	methods = {
		BindAction = function(self, name, fn, createTouchButton, ...)
			if type(name) ~= "string" then fail(2, "BindAction expects a string action name") end
			if not isCallable(fn) then fail(2, "BindAction expects a function for action '%s'", name) end
			if actionBindings[name] then
				for i, n in ipairs(actionOrder) do if n == name then table.remove(actionOrder, i) break end end
			end
			local keys = { ... }
			local b = { name = name, fn = fn, touch = createTouchButton == true, keys = keys, priority = Enum.ContextActionPriority.Default.Value, order = #actionOrder + 1, button = actionBindings[name] and actionBindings[name].button or nil, title = nil, description = nil, image = nil, position = nil }
			actionBindings[name] = b
			table.insert(actionOrder, name)
		end,
		BindActionAtPriority = function(self, name, fn, createTouchButton, priority, ...)
			self:BindAction(name, fn, createTouchButton, ...)
			actionBindings[name].priority = shim._isEnumItem(priority) and priority.Value or tonumber(priority) or 2000
		end,
		UnbindAction = function(self, name)
			local b = actionBindings[name]
			if b and b.button and not priv[b.button].destroyed then destroyInstance(b.button) end
			actionBindings[name] = nil
			for i, n in ipairs(actionOrder) do if n == name then table.remove(actionOrder, i) break end end
		end,
		UnbindAllActions = function(self)
			for _, name in ipairs(tcopy(actionOrder)) do self:UnbindAction(name) end
		end,
		GetButton = function(self, name)
			local b = actionBindings[name]
			if not b or not b.touch then return nil end
			if not b.button or priv[b.button].destroyed then
				local btn = new("ImageButton")
				priv[btn].name = name .. "Button"
				b.button = btn
			end
			return b.button
		end,
		SetTitle = function(self, name, title) if actionBindings[name] then actionBindings[name].title = title end end,
		SetDescription = function(self, name, desc) if actionBindings[name] then actionBindings[name].description = desc end end,
		SetImage = function(self, name, image) if actionBindings[name] then actionBindings[name].image = image end end,
		SetPosition = function(self, name, pos) if actionBindings[name] then actionBindings[name].position = pos end end,
		GetAllBoundActionInfo = function()
			local out = {}
			for name, b in pairs(actionBindings) do
				out[name] = { title = b.title, description = b.description, image = b.image, position = b.position, inputTypes = tcopy(b.keys), priorityLevel = b.priority, createTouchButton = b.touch, stackOrder = b.order }
			end
			return out
		end,
		GetBoundActionInfo = function(self, name)
			local b = actionBindings[name]
			if not b then return nil end
			return { title = b.title, description = b.description, image = b.image, position = b.position, inputTypes = tcopy(b.keys), priorityLevel = b.priority, createTouchButton = b.touch, stackOrder = b.order }
		end,
		BindActivate = function() end,
		UnbindActivate = function() end,
		GetCurrentLocalToolIcon = function() return nil end,
	},
})
shim._actionBindings = actionBindings

-- misc services --------------------------------------------------------------------------------
defclass("GuiService", "Instance", {
	defaults = { SelectedObject = NIL, SelectedCoreObject = NIL, AutoSelectGuiEnabled = true, CoreGuiNavigationEnabled = true, GuiNavigationEnabled = true, TouchControlsEnabled = true, MenuIsOpen = false, ReducedMotionEnabled = false, PreferredTransparency = 1, PreferredTextSize = function() return Enum.PreferredTextSize.Medium end, TopbarInset = function() return Rect.new(0, 0, 1280, 36) end, ViewportDisplaySize = function() return Enum.ViewportDisplaySize.Medium end },
	events = { "MenuOpened", "MenuClosed", "ErrorMessageChanged", "NativeClose" },
	methods = {
		GetGuiInset = function() return Vector2.new(0, 36), Vector2.new(0, 0) end,
		IsTenFootInterface = function() return false end,
		GetSafeZoneOffsets = function() return { top = 0, bottom = 0, left = 0, right = 0 } end,
		GetScreenResolution = function() return viewportSize() end,
		SetGlobalGuiInset = function() end,
		GetErrorType = function() return Enum.ConnectionError.OK end,
		Select = function() end,
		AddSelectionParent = function() end, AddSelectionTuple = function() end, RemoveSelectionGroup = function() end,
		SetEmotesMenuOpen = function() end, GetEmotesMenuOpen = function() return false end,
		SetInspectMenuEnabled = function() end, GetInspectMenuEnabled = function() return false end,
		InspectPlayerFromHumanoidDescription = function() end, InspectPlayerFromUserId = function() end,
		CloseInspectMenu = function() end,
	},
})
defclass("TextService", "Instance", {
	methods = {
		GetTextSize = function(self, text, fontSize, font, frameSize)
			return estimateTextSize(text, fontSize, frameSize and frameSize.X or nil)
		end,
		GetTextBoundsAsync = function(self, params)
			return estimateTextSize(rawProp(params, "Text"), rawProp(params, "Size"), rawProp(params, "Width"))
		end,
		FilterStringAsync = function(self, text)
			return setmetatable({ GetNonChatStringForBroadcastAsync = function() return text end, GetNonChatStringForUserAsync = function() return text end, GetChatForUserAsync = function() return text end }, { __type = "TextFilterResult" })
		end,
		FilterAndTranslateStringAsync = function(self, text) return self:FilterStringAsync(text) end,
		GetFamilyInfoAsync = function(self, id) return { Name = tostring(id), Faces = {} } end,
		GetFontMemoryData = function() return {} end,
	},
})
defclass("GetTextBoundsParams", "Instance", { defaults = { Text = "", Font = function() return Font.fromEnum(Enum.Font.SourceSans) end, Size = 14, Width = 0, RichText = false } })
defclass("StarterGui", "BasePlayerGui", {
	defaults = { ResetPlayerGuiOnSpawn = true, ShowDevelopmentGui = true, ScreenOrientation = function() return Enum.ScreenOrientation.LandscapeSensor end, VirtualCursorMode = function() return Enum.VirtualCursorMode.Default end, _coreGui = function() return {} end, _cores = function() return {} end },
	events = { "CoreGuiChangedSignal" },
	methods = {
		SetCoreGuiEnabled = function(self, kind, enabled) rawProp(self, "_coreGui")[kind] = enabled end,
		GetCoreGuiEnabled = function(self, kind)
			local v = rawProp(self, "_coreGui")[kind]
			if v == nil then return true end
			return v
		end,
		SetCore = function(self, name, value) rawProp(self, "_cores")[name] = value end,
		GetCore = function(self, name) return rawProp(self, "_cores")[name] end,
		RegisterSetCore = function() end, RegisterGetCore = function() end,
	},
})
defclass("StarterPlayer", "Instance", {
	defaults = { CharacterWalkSpeed = 16, CharacterJumpPower = 50, CharacterJumpHeight = 7.2, CharacterMaxSlopeAngle = 89, CharacterUseJumpPower = true, EnableMouseLockOption = true, LoadCharacterAppearance = true, AutoJumpEnabled = true, CameraMaxZoomDistance = 400, CameraMinZoomDistance = 0.5, CameraMode = function() return Enum.CameraMode.Classic end, DevCameraOcclusionMode = function() return Enum.DevCameraOcclusionMode.Zoom end, DevComputerCameraMovementMode = function() return Enum.DevComputerCameraMovementMode.UserChoice end, DevComputerMovementMode = function() return Enum.DevComputerMovementMode.UserChoice end, DevTouchCameraMovementMode = function() return Enum.DevTouchCameraMovementMode.UserChoice end, DevTouchMovementMode = function() return Enum.DevTouchMovementMode.UserChoice end, HealthDisplayDistance = 100, NameDisplayDistance = 100, HumanoidStateMachineMode = NIL, UserEmotesEnabled = true, EnableDynamicHeads = NIL, LoadCharacterLayeredClothing = function() return Enum.LoadCharacterLayeredClothing.Default end },
	onCreate = function(inst)
		local sps = new("StarterPlayerScripts")
		setParent(sps, inst)
		local scs = new("StarterCharacterScripts")
		setParent(scs, inst)
	end,
})
defclass("Lighting", "Instance", {
	defaults = { Ambient = function() return Color3.fromRGB(70, 70, 70) end, OutdoorAmbient = function() return Color3.fromRGB(70, 70, 70) end, Brightness = 2, ClockTime = 14, TimeOfDay = "14:00:00", GeographicLatitude = 41.733, EnvironmentDiffuseScale = 0, EnvironmentSpecularScale = 0, GlobalShadows = true, ShadowSoftness = 0.2, ColorShift_Top = function() return Color3.new(0, 0, 0) end, ColorShift_Bottom = function() return Color3.new(0, 0, 0) end, FogColor = function() return Color3.fromRGB(192, 192, 192) end, FogEnd = 100000, FogStart = 0, ExposureCompensation = 0, Technology = function() return Enum.Technology.ShadowMap end },
	events = { "LightingChanged" },
	setters = {
		ClockTime = function(self, s, v)
			setProp(self, "ClockTime", v)
			local h = math.floor(v) % 24
			local m = math.floor((v - math.floor(v)) * 60)
			s.props.TimeOfDay = string.format("%02d:%02d:00", h, m)
		end,
		TimeOfDay = function(self, s, v)
			s.props.TimeOfDay = v
			local h, m, sec = tostring(v):match("(%d+):(%d+):?(%d*)")
			setProp(self, "ClockTime", (tonumber(h) or 0) + (tonumber(m) or 0) / 60 + (tonumber(sec) or 0) / 3600)
		end,
	},
	methods = {
		GetMinutesAfterMidnight = function(self) return rawProp(self, "ClockTime") * 60 end,
		SetMinutesAfterMidnight = function(self, minutes) self.ClockTime = (minutes / 60) % 24 end,
		GetSunDirection = function(self)
			local t = rawProp(self, "ClockTime")
			local angle = (t - 6) / 12 * math.pi
			return Vector3.new(math.cos(angle) * 0.3, math.sin(angle), -math.cos(angle)).Unit
		end,
		GetMoonDirection = function(self) return -self:GetSunDirection() end,
		GetMoonPhase = function() return 0.75 end,
	},
})
defclass("SoundService", "Instance", {
	defaults = { RespectFilteringEnabled = false, AmbientReverb = function() return Enum.ReverbType.NoReverb end, DistanceFactor = 3.33, DopplerScale = 1, RolloffScale = 1, VolumetricAudio = NIL, _listener = NIL },
	methods = {
		PlayLocalSound = function(self, sound) sound:Play() end,
		SetListener = function(self, kind, target) priv[self].props._listener = { kind, target } end,
		GetListener = function(self) local l = rawProp(self, "_listener") if l then return l[1], l[2] end return Enum.ListenerType.Camera, nil end,
	},
})
defclass("ReplicatedStorage", "Instance")
defclass("ReplicatedFirst", "Instance", { methods = { RemoveDefaultLoadingScreen = function() end, SetDefaultLoadingGuiRemoved = function() end } })
defclass("ServerStorage", "Instance")
defclass("ServerScriptService", "Instance", { defaults = { LoadStringEnabled = false } })
defclass("Teams", "Instance", { methods = { GetTeams = function(self)
	local out = {}
	for _, c in ipairs(priv[self].children) do if priv[c].className == "Team" then out[#out + 1] = c end end
	return out
end } })
defclass("Chat", "Instance", {
	defaults = { BubbleChatEnabled = false, LoadDefaultChat = true },
	events = { "Chatted" },
	methods = {
		Chat = function(self, part, message, color)
			local sig = priv[self].events.Chatted
			if sig then sig:Fire(part, message, color) end
		end,
		FilterStringAsync = function(self, text) return text end,
		FilterStringForBroadcast = function(self, text) return text end,
		CanUserChatAsync = function() return true end,
		CanUsersChatAsync = function() return true end,
		SetBubbleChatSettings = function() end,
		RegisterChatCallback = function() end,
		InvokeChatCallback = function() return nil end,
	},
})
defclass("TextChatService", "Instance", {
	defaults = { ChatVersion = function() return Enum.ChatVersion.TextChatService end, CreateDefaultTextChannels = true, CreateDefaultCommands = true, OnIncomingMessage = NIL, OnBubbleAdded = NIL, OnChatWindowAdded = NIL },
	events = { "MessageReceived", "SendingMessage" },
	methods = {
		DisplayBubble = function() end,
		CanUserChatAsync = function() return true end,
		CanUsersChatAsync = function() return true end,
	},
	onCreate = function(inst)
		local channels = new("Folder")
		priv[channels].name = "TextChannels"
		setParent(channels, inst)
		local general = new("TextChannel")
		priv[general].name = "RBXGeneral"
		setParent(general, channels)
		for _, n in ipairs({ "ChatInputBarConfiguration", "ChatWindowConfiguration", "BubbleChatConfiguration" }) do setParent(new(n), inst) end
	end,
})
classes.TextChannel.methods = {
	DisplaySystemMessage = function(self, text, metadata)
		local msg = new("TextChatMessage")
		priv[msg].props.Text = text
		priv[msg].props.Metadata = metadata or ""
		priv[msg].props.Status = Enum.TextChatMessageStatus.Success
		local sig = priv[self].events.MessageReceived
		if sig then sig:Fire(msg) end
		return msg
	end,
	SendAsync = function(self, text, metadata)
		local msg = new("TextChatMessage")
		priv[msg].props.Text = text
		priv[msg].props.Metadata = metadata or ""
		priv[msg].props.Status = Enum.TextChatMessageStatus.Success
		local sig = priv[self].events.MessageReceived
		if sig then sig:Fire(msg) end
		return msg
	end,
	AddUserAsync = function() return nil, true end,
	SetDirectChatRequester = function() end,
}
allMethodNames.DisplaySystemMessage, allMethodNames.SendAsync = true, true
defclass("TeleportService", "Instance", {
	defaults = { _settings = function() return {} end, _teleports = function() return {} end },
	events = { "TeleportInitFailed", "LocalPlayerArrivedFromTeleport" },
	methods = {
		Teleport = function(self, placeId, player, data) table.insert(rawProp(self, "_teleports"), { placeId = placeId, players = { player }, data = data }) end,
		TeleportAsync = function(self, placeId, players, options) table.insert(rawProp(self, "_teleports"), { placeId = placeId, players = players, options = options }) return { PrivateServerId = "", ReservedServerAccessCode = "" } end,
		TeleportToPlaceInstance = function(self, placeId, instanceId, player) table.insert(rawProp(self, "_teleports"), { placeId = placeId, instanceId = instanceId, players = { player } }) end,
		TeleportToPrivateServer = function(self, placeId, code, players) table.insert(rawProp(self, "_teleports"), { placeId = placeId, code = code, players = players }) end,
		TeleportPartyAsync = function(self, placeId, players) table.insert(rawProp(self, "_teleports"), { placeId = placeId, players = players }) return "" end,
		ReserveServer = function() return "reserved-code", "reserved-id" end,
		GetLocalPlayerTeleportData = function() return nil end,
		GetTeleportSetting = function(self, key) return rawProp(self, "_settings")[key] end,
		SetTeleportSetting = function(self, key, value) rawProp(self, "_settings")[key] = value end,
		GetPlayerPlaceInstanceAsync = function() return false, "", "" end,
		GetArrivingTeleportGui = function() return nil end,
		SetTeleportGui = function() end,
	},
})
defclass("BadgeService", "Instance", {
	defaults = { _awarded = function() return {} end },
	methods = {
		AwardBadge = function(self, userId, badgeId)
			local a = rawProp(self, "_awarded")
			a[userId] = a[userId] or {}
			a[userId][badgeId] = true
			return true
		end,
		UserHasBadgeAsync = function(self, userId, badgeId)
			local a = rawProp(self, "_awarded")[userId]
			return a ~= nil and a[badgeId] == true
		end,
		GetBadgeInfoAsync = function(self, id) return { Name = "Badge " .. tostring(id), Description = "", IconImageId = 0, IsEnabled = true } end,
		CheckUserBadgesAsync = function() return {} end,
	},
})
defclass("LocalizationService", "Instance", {
	defaults = { RobloxLocaleId = "en-us", SystemLocaleId = "en-us" },
	methods = {
		GetTranslatorForPlayer = function() return setmetatable({ LocaleId = "en-us", FormatByKey = function(_, key) return key end, Translate = function(_, _, text) return text end, RobloxFormatByKey = function(_, key) return key end }, { __type = "Translator" }) end,
		GetTranslatorForPlayerAsync = function(self, p) return self:GetTranslatorForPlayer(p) end,
		GetTranslatorForLocaleAsync = function(self) return self:GetTranslatorForPlayer() end,
		GetCountryRegionForPlayerAsync = function() return "US" end,
	},
})
defclass("GroupService", "Instance", {
	methods = {
		GetGroupInfoAsync = function(self, id) return { Name = "Group " .. tostring(id), Id = id, Owner = { Id = 0, Name = "" }, EmblemUrl = "", Description = "", Roles = {} } end,
		GetGroupsAsync = function() return {} end,
		GetAlliesAsync = function() return { GetCurrentPage = function() return {} end, IsFinished = true, AdvanceToNextPageAsync = function() end } end,
		GetEnemiesAsync = function() return { GetCurrentPage = function() return {} end, IsFinished = true, AdvanceToNextPageAsync = function() end } end,
	},
})
defclass("LogService", "Instance", { events = { "MessageOut", "ServerMessageOut" }, methods = { GetLogHistory = function() return {} end, RequestServerOutput = function() end } })
defclass("VRService", "Instance", { defaults = { VREnabled = false, AutomaticScaling = NIL, AvatarGestures = false, FadeOutViewOnCollision = true, ThirdPersonFollowCamEnabled = false }, events = { "UserCFrameChanged", "UserCFrameEnabled", "NavigationRequested", "TouchpadModeChanged" }, methods = { GetUserCFrame = function() return CFrame.identity end, GetUserCFrameEnabled = function() return false end, RecenterUserHeadCFrame = function() end, RequestNavigation = function() end, GetTouchpadMode = function() return Enum.VRTouchpadMode.Touch end, SetTouchpadMode = function() end } })
defclass("HapticService", "Instance", { methods = { SetMotor = function() end, GetMotor = function() return 0 end, IsVibrationSupported = function() return false end, IsMotorSupported = function() return false end } })
defclass("PolicyService", "Instance", { methods = { GetPolicyInfoForPlayerAsync = function() return { ArePaidRandomItemsRestricted = false, AllowedExternalLinkReferences = {}, IsPaidItemTradingAllowed = false, IsSubjectToChinaPolicies = false, IsEligibleToPurchaseSubscription = true, IsEligibleToPurchaseCommerceProduct = false } end } })
defclass("MessagingService", "Instance", {
	defaults = { _subs = function() return {} end },
	methods = {
		SubscribeAsync = function(self, topic, fn)
			local subs = rawProp(self, "_subs")
			subs[topic] = subs[topic] or Signal.new("Messaging:" .. topic)
			return subs[topic]:Connect(fn)
		end,
		PublishAsync = function(self, topic, message)
			local sig = rawProp(self, "_subs")[topic]
			if sig then
				local payload = { Data = deepCopy(message), Sent = DateTime._epochNow() }
				task.defer(function() sig:Fire(payload) end)
			end
		end,
	},
})
defclass("PathfindingService", "Instance", { methods = { CreatePath = function(self, params) local p = new("Path") priv[p].props._params = params return p end, FindPathAsync = function(self, from, to) local p = new("Path") p:ComputeAsync(from, to) return p end } })
defclass("SocialService", "Instance", { events = { "GameInvitePromptClosed", "PromptInviteRequested" }, methods = { PromptGameInvite = function() end, CanSendGameInviteAsync = function() return false end, CanSendCallInviteAsync = function() return false end, PromptPhoneBook = function() end } })
defclass("AnalyticsService", "Instance", { defaults = { _events = function() return {} end }, methods = { LogCustomEvent = function(self, ...) table.insert(rawProp(self, "_events"), { "Custom", ... }) end, LogEconomyEvent = function(self, ...) table.insert(rawProp(self, "_events"), { "Economy", ... }) end, LogFunnelStepEvent = function(self, ...) table.insert(rawProp(self, "_events"), { "Funnel", ... }) end, LogOnboardingFunnelStepEvent = function(self, ...) table.insert(rawProp(self, "_events"), { "Onboarding", ... }) end, LogProgressionEvent = function(self, ...) table.insert(rawProp(self, "_events"), { "Progression", ... }) end, FireEvent = function() end, FireCustomEvent = function() end, FireInGameEconomyEvent = function() end, FireLogEvent = function() end, FirePlayerProgressionEvent = function() end } })
defclass("Stats", "Instance", { defaults = { ContactsCount = 0, DataReceiveKbps = 0, DataSendKbps = 0, HeartbeatTimeMs = 0, InstanceCount = 0, MovingPrimitivesCount = 0, PhysicsReceiveKbps = 0, PhysicsSendKbps = 0, PhysicsStepTimeMs = 0, PrimitivesCount = 0 }, methods = { GetTotalMemoryUsageMb = function() return 100 end, GetMemoryUsageMbForTag = function() return 1 end } })
defclass("InsertService", "Instance", { methods = { LoadAsset = function() fail(2, "InsertService:LoadAsset is not available in the offline harness") end, LoadAssetVersion = function() fail(2, "InsertService:LoadAssetVersion is not available in the offline harness") end, CreateMeshPartAsync = function() return new("MeshPart") end } })
-- AssetService: CreateMeshPartAsync(content, options) returns a MeshPart whose MeshId comes from the
-- Content (Content.fromAssetId / fromUri), Size (1, 1, 1) and the requested fidelities; every call is
-- recorded in shim.assetService.calls ({ method, content, options, meshId }). The next
-- shim.assetService.failNextCalls calls raise "CreateMeshPartAsync failed (simulated)" instead.
-- shim.assetService.latency = s makes each call yield (task.wait) that long first, like the real
-- async call, so specs can exercise concurrent loads.
-- shim.assetService.editableBudgetExhausted = true makes CreateEditableMesh / CreateEditableImage
-- return nil (the engine's "editable memory budget exhausted" / "Mesh / Image APIs off" result);
-- shim.assetService.cloneDropsObjectContent = true makes Instance:Clone() drop Content.fromObject
-- values from MeshContent / TextureContent (a copy that no longer shows the EditableMesh).
shim.assetService = { calls = {}, failNextCalls = 0, latency = 0 }
local function isObjectContent(v)
	return type(v) == "table" and getmetatable(v) ~= nil and rawget(getmetatable(v), "__type") == "Content" and rawget(v, "Object") ~= nil
end
table.insert(Inst.cloneHooks, function(src, copy)
	local a = shim.assetService
	if not (a and a.cloneDropsObjectContent) then return end
	local props = priv[copy].props
	for _, key in ipairs({ "MeshContent", "TextureContent" }) do
		if isObjectContent(props[key]) then props[key] = NIL end
	end
end)
local function contentAssetId(content)
	if type(content) == "table" then
		if type(content.AssetId) == "number" then return content.AssetId end
		if type(content.Uri) == "string" then
			local n = tonumber(string.match(content.Uri, "(%d+)%s*$"))
			if n then return n end
		end
	elseif type(content) == "string" then
		local n = tonumber(string.match(content, "(%d+)%s*$"))
		if n then return n end
	elseif type(content) == "number" then
		return content
	end
	return nil
end
-- EditableMesh / EditableImage: in-memory recorders. An EditableMesh hands out sequential ids per
-- kind (vertex, normal, UV, face: 1, 2, 3, ...) and keeps what was added; read it back through the
-- real API (GetVertices/GetPosition/GetNormal/GetUV/GetFaces/GetFaceVertices/GetFaceNormals/
-- GetFaceUVs) or shim.editableData(inst) = { vertices, normals, uvs, faces, faceNormals, faceUVs }.
-- An EditableImage records every WritePixelsBuffer call in shim.editableData(image).writes as
-- { position, size, length } (length = buffer.len). AssetService:CreateEditableMesh(options) /
-- CreateEditableImage({ Size }) create them; CreateMeshPartAsync(Content.fromObject(editableMesh))
-- returns a MeshPart with MeshContent = that Content (MeshId ""). Both are plain Instances.
local function editableData(inst)
	local s = priv[inst]
	if not s then fail(3, "shim.editableData expects an EditableMesh or EditableImage instance") end
	if not s.editable then
		s.editable = { vertices = {}, normals = {}, uvs = {}, faces = {}, faceNormals = {}, faceUVs = {}, writes = {} }
	end
	return s.editable
end
shim.editableData = editableData
local function checkId(self, list, id, what)
	if type(id) ~= "number" or list[id] == nil then fail(3, "EditableMesh: invalid %s id %s", what, tostring(id)) end
end
defclass("EditableMesh", "Instance", { defaults = { FixedSize = false, SkinningEnabled = false }, methods = {
	AddVertex = function(self, p)
		if shim.typeof(p) ~= "Vector3" then fail(2, "EditableMesh:AddVertex expects a Vector3, got %s", shim.typeof(p)) end
		local d = editableData(self)
		local id = #d.vertices + 1
		d.vertices[id] = p
		return id
	end,
	AddNormal = function(self, n)
		if n ~= nil and shim.typeof(n) ~= "Vector3" then fail(2, "EditableMesh:AddNormal expects a Vector3, got %s", shim.typeof(n)) end
		local d = editableData(self)
		local id = #d.normals + 1
		d.normals[id] = n or Vector3.new(0, 1, 0)
		return id
	end,
	AddUV = function(self, uv)
		if shim.typeof(uv) ~= "Vector2" then fail(2, "EditableMesh:AddUV expects a Vector2, got %s", shim.typeof(uv)) end
		local d = editableData(self)
		local id = #d.uvs + 1
		d.uvs[id] = uv
		return id
	end,
	AddTriangle = function(self, a, b, c)
		local d = editableData(self)
		checkId(self, d.vertices, a, "vertex") checkId(self, d.vertices, b, "vertex") checkId(self, d.vertices, c, "vertex")
		local id = #d.faces + 1
		d.faces[id] = { a, b, c }
		return id
	end,
	SetFaceNormals = function(self, faceId, ids)
		local d = editableData(self)
		checkId(self, d.faces, faceId, "face")
		if type(ids) ~= "table" or #ids ~= 3 then fail(2, "EditableMesh:SetFaceNormals expects a table of 3 normal ids") end
		for _, id in ipairs(ids) do checkId(self, d.normals, id, "normal") end
		d.faceNormals[faceId] = { ids[1], ids[2], ids[3] }
	end,
	SetFaceUVs = function(self, faceId, ids)
		local d = editableData(self)
		checkId(self, d.faces, faceId, "face")
		if type(ids) ~= "table" or #ids ~= 3 then fail(2, "EditableMesh:SetFaceUVs expects a table of 3 UV ids") end
		for _, id in ipairs(ids) do checkId(self, d.uvs, id, "uv") end
		d.faceUVs[faceId] = { ids[1], ids[2], ids[3] }
	end,
	GetVertices = function(self) local out = {} for id in ipairs(editableData(self).vertices) do out[#out + 1] = id end return out end,
	GetFaces = function(self) local out = {} for id in ipairs(editableData(self).faces) do out[#out + 1] = id end return out end,
	GetPosition = function(self, id) local d = editableData(self) checkId(self, d.vertices, id, "vertex") return d.vertices[id] end,
	GetNormal = function(self, id) local d = editableData(self) checkId(self, d.normals, id, "normal") return d.normals[id] end,
	GetUV = function(self, id) local d = editableData(self) checkId(self, d.uvs, id, "uv") return d.uvs[id] end,
	GetFaceVertices = function(self, id) local d = editableData(self) checkId(self, d.faces, id, "face") return { table.unpack(d.faces[id]) } end,
	GetFaceNormals = function(self, id) local d = editableData(self) checkId(self, d.faces, id, "face") local n = d.faceNormals[id] return n and { table.unpack(n) } or {} end,
	GetFaceUVs = function(self, id) local d = editableData(self) checkId(self, d.faces, id, "face") local u = d.faceUVs[id] return u and { table.unpack(u) } or {} end,
	GetSize = function(self) local d = editableData(self) local lo, hi = nil, nil for _, p in ipairs(d.vertices) do lo = lo and lo:Min(p) or p hi = hi and hi:Max(p) or p end return lo and (hi - lo) or Vector3.zero end,
	RemoveUnused = function() return 0 end,
	Destroy = function(self) priv[self].destroyed = true end,
} })
defclass("EditableImage", "Instance", { defaults = { Size = function() return Vector2.new(1, 1) end }, methods = {
	WritePixelsBuffer = function(self, position, size, buf)
		if shim.typeof(position) ~= "Vector2" or shim.typeof(size) ~= "Vector2" then fail(2, "EditableImage:WritePixelsBuffer expects (Vector2, Vector2, buffer)") end
		if nativeTypeof(buf) ~= "buffer" then fail(2, "EditableImage:WritePixelsBuffer expects a buffer, got %s", nativeTypeof(buf)) end
		local length = buffer.len(buf)
		if length ~= size.X * size.Y * 4 then fail(2, "EditableImage:WritePixelsBuffer: buffer length %d does not match %dx%d RGBA (%d bytes)", length, size.X, size.Y, size.X * size.Y * 4) end
		local own = rawProp(self, "Size")
		if position.X < 0 or position.Y < 0 or position.X + size.X > own.X or position.Y + size.Y > own.Y then fail(2, "EditableImage:WritePixelsBuffer: region outside the image") end
		table.insert(editableData(self).writes, { position = position, size = size, length = length, buffer = buf })
	end,
	ReadPixelsBuffer = function(self, position, size)
		local writes = editableData(self).writes
		local last = writes[#writes]
		if last and last.position == position and last.size == size then return last.buffer end
		return buffer.create(size.X * size.Y * 4)
	end,
	DrawRectangle = function() end, DrawCircle = function() end, DrawLine = function() end, DrawImage = function() end,
	Destroy = function(self) priv[self].destroyed = true end,
} })
defclass("AssetService", "Instance", { methods = {
	CreateEditableMeshAsync = function() return nil end,
	CreateEditableMesh = function(self, options)
		if shim.assetService.editableBudgetExhausted then
			table.insert(shim.assetService.calls, { method = "CreateEditableMesh", options = options, result = nil })
			return nil
		end
		local mesh = new("EditableMesh")
		if type(options) == "table" and options.FixedSize ~= nil then setProp(mesh, "FixedSize", options.FixedSize == true) end
		table.insert(shim.assetService.calls, { method = "CreateEditableMesh", options = options, result = mesh })
		return mesh
	end,
	CreateEditableImage = function(self, options)
		if shim.assetService.editableBudgetExhausted then
			table.insert(shim.assetService.calls, { method = "CreateEditableImage", options = options, result = nil })
			return nil
		end
		local image = new("EditableImage")
		if type(options) == "table" and options.Size ~= nil then
			if shim.typeof(options.Size) ~= "Vector2" then fail(2, "AssetService:CreateEditableImage: Size must be a Vector2") end
			if options.Size.X < 1 or options.Size.Y < 1 or options.Size.X > 1024 or options.Size.Y > 1024 then fail(2, "AssetService:CreateEditableImage: Size must be within 1x1 .. 1024x1024") end
			setProp(image, "Size", options.Size)
		end
		table.insert(shim.assetService.calls, { method = "CreateEditableImage", options = options, result = image })
		return image
	end,
	CreateMeshPartAsync = function(self, content, options)
		local a = shim.assetService
		local assetId = contentAssetId(content)
		table.insert(a.calls, { method = "CreateMeshPartAsync", content = content, options = options, meshId = assetId })
		if (a.latency or 0) > 0 then task.wait(a.latency) end
		if (a.failNextCalls or 0) > 0 then
			a.failNextCalls -= 1
			fail(2, "CreateMeshPartAsync failed (simulated)")
		end
		if type(content) ~= "table" or getmetatable(content) == nil or rawget(getmetatable(content), "__type") ~= "Content" then
			fail(2, "AssetService:CreateMeshPartAsync expects a Content (use Content.fromAssetId), got %s", nativeTypeof(content))
		end
		local part = new("MeshPart")
		setProp(part, "Size", Vector3.new(1, 1, 1))
		setProp(part, "MeshContent", content)
		if assetId then setProp(part, "MeshId", "rbxassetid://" .. tostring(assetId)) elseif type(content.Uri) == "string" then setProp(part, "MeshId", content.Uri)
		elseif rawget(content, "Object") ~= nil then
			local object = rawget(content, "Object")
			if not isInstance(object) or priv[object].className ~= "EditableMesh" then fail(2, "AssetService:CreateMeshPartAsync: Content.fromObject must wrap an EditableMesh") end
			local size = object:GetSize()
			if size.Magnitude > 0 then setProp(part, "Size", size) end
		end
		if type(options) == "table" then
			if options.CollisionFidelity ~= nil then setProp(part, "CollisionFidelity", options.CollisionFidelity) end
			if options.RenderFidelity ~= nil then setProp(part, "RenderFidelity", options.RenderFidelity) end
			if options.FluidFidelity ~= nil then setProp(part, "FluidFidelity", options.FluidFidelity) end
		end
		return part
	end,
	GetGamePlacesAsync = function() return { GetCurrentPage = function() return {} end, IsFinished = true, AdvanceToNextPageAsync = function() end } end,
} })
defclass("ScriptContext", "Instance", { events = { "Error" }, methods = { SetTimeout = function() end } })
defclass("ProximityPromptService", "Instance", { defaults = { Enabled = true, MaxPromptsVisible = 16 }, events = { "PromptTriggered", "PromptTriggerEnded", "PromptShown", "PromptHidden", "PromptButtonHoldBegan", "PromptButtonHoldEnded" } })
defclass("UserGameSettings", "Instance", { defaults = { CameraMode = NIL, ComputerCameraMovementMode = NIL, ComputerMovementMode = NIL, ControlMode = NIL, GamepadCameraSensitivity = 1, MouseSensitivity = 1, RotationType = NIL, SavedQualityLevel = NIL, TouchCameraMovementMode = NIL, TouchMovementMode = NIL, VignetteEnabled = false, Fullscreen = false, HasEverUsedVR = false, MasterVolume = 1, ReducedMotion = false, PreferredTransparency = 1, PreferredTextSize = NIL }, events = { "FullscreenChanged", "StudioThemeChanged" }, methods = { GetCameraYInvertValue = function() return 1 end, InFullScreen = function() return false end, InStudioMode = function() return false end, SetCameraYInvertVisible = function() end, SetGamepadCameraSensitivityVisible = function() end, GetTutorialState = function() return false end, SetTutorialState = function() end } })
defclass("MaterialService", "Instance", { defaults = { Use2022Materials = true }, methods = { GetBaseMaterial = function(self, m) return m end, GetMaterialVariant = function() return nil end, SetBaseMaterialOverride = function() end, GetBaseMaterialOverride = function() return "" end } })
defclass("VoiceChatService", "Instance", { defaults = { EnableDefaultVoice = true, UseAudioApi = NIL }, methods = { IsVoiceEnabledForUserIdAsync = function() return false end } })
defclass("TestService", "Instance", { methods = { Check = function(self, cond, msg) if not cond then robloxWarn("TestService check failed: " .. tostring(msg)) end end, Checkpoint = function() end, Done = function() end, Error = function(self, msg) robloxWarn("TestService error: " .. tostring(msg)) end, Fail = function(self, msg) robloxWarn("TestService fail: " .. tostring(msg)) end, Message = function(self, msg) robloxPrint(msg) end, Warn = function(self, cond, msg) if not cond then robloxWarn(tostring(msg)) end end } })
defclass("ExperienceNotificationService", "Instance", { methods = { PromptOptIn = function() end, CanPromptOptInAsync = function() return false end } })
defclass("AvatarEditorService", "Instance", { methods = { PromptSaveAvatar = function() end, PromptCreateOutfit = function() end } })
defclass("GamePassService", "Instance", { methods = { PlayerHasPass = function() return false end } })
defclass("PointsService", "Instance", { methods = { AwardPoints = function() end } })
defclass("NotificationService", "Instance")
defclass("ContentProvider", "Instance", { defaults = { RequestQueueSize = 0, BaseUrl = "https://www.roblox.com/" }, methods = { PreloadAsync = function(self, list, cb) if cb then for _, item in ipairs(list) do cb(tostring(item), Enum.AssetFetchStatus.Success) end end end, GetAssetFetchStatus = function() return Enum.AssetFetchStatus.Success end, GetAssetFetchStatusChangedSignal = function() return Signal.new("AssetFetch") end, RegisterDefaultSessionKey = function() end, RegisterSessionEncryptedAsset = function() end } })
defclass("KeyframeSequenceProvider", "Instance", { methods = { GetKeyframeSequenceAsync = function() return new("KeyframeSequence") end, RegisterKeyframeSequence = function() return "rbxassetid://0" end } })
defclass("RobloxReplicatedStorage", "Instance")
defclass("CoreGui", "BasePlayerGui")

-- Remotes ----------------------------------------------------------------------------------------
local function remoteArgs(...)
	if not shim.remoteCopy then return ... end
	local n = select("#", ...)
	local out = table.create(n)
	for i = 1, n do out[i] = deepCopy((select(i, ...))) end
	return unpack(out, 1, n)
end

local function localPlayerForRemote(what)
	local lp = rawProp(getService("Players"), "LocalPlayer")
	if not lp then fail(3, "%s requires Players.LocalPlayer to be set (use shim.setLocalPlayer / shim.setContext(\"client\"))", what) end
	return lp
end

classes.RemoteEvent.methods = {
	FireServer = function(self, ...)
		local lp = localPlayerForRemote("RemoteEvent:FireServer")
		table.insert(shim.remoteLog, { kind = "FireServer", remote = self, args = { ... } })
		local sig = priv[self].events.OnServerEvent
		if sig then sig:Fire(lp, remoteArgs(...)) end
	end,
	FireClient = function(self, player, ...)
		if not (isInstance(player) and priv[player].className == "Player") then fail(2, "FireClient expects a Player as the first argument, got %s", nativeTypeof(player)) end
		table.insert(shim.remoteLog, { kind = "FireClient", remote = self, player = player, args = { ... } })
		local lp = rawProp(getService("Players"), "LocalPlayer")
		if lp ~= nil and lp ~= player and not shim.remoteDeliverAll then return end
		local sig = priv[self].events.OnClientEvent
		if sig then sig:Fire(remoteArgs(...)) end
	end,
	FireAllClients = function(self, ...)
		table.insert(shim.remoteLog, { kind = "FireAllClients", remote = self, args = { ... } })
		local sig = priv[self].events.OnClientEvent
		if sig then sig:Fire(remoteArgs(...)) end
	end,
}
classes.RemoteFunction.methods = {
	InvokeServer = function(self, ...)
		local lp = localPlayerForRemote("RemoteFunction:InvokeServer")
		local handler = rawProp(self, "OnServerInvoke")
		if not handler then fail(2, "RemoteFunction '%s': OnServerInvoke is not set (the server side has not been started)", getFullName(self)) end
		table.insert(shim.remoteLog, { kind = "InvokeServer", remote = self, args = { ... } })
		return remoteArgs(handler(lp, remoteArgs(...)))
	end,
	InvokeClient = function(self, player, ...)
		local handler = rawProp(self, "OnClientInvoke")
		if not handler then fail(2, "RemoteFunction '%s': OnClientInvoke is not set", getFullName(self)) end
		table.insert(shim.remoteLog, { kind = "InvokeClient", remote = self, player = player, args = { ... } })
		return remoteArgs(handler(remoteArgs(...)))
	end,
}
classes.BindableEvent.methods = {
	Fire = function(self, ...)
		local sig = priv[self].events.Event
		if sig then sig:Fire(remoteArgs(...)) end
	end,
}
classes.BindableFunction.methods = {
	Invoke = function(self, ...)
		local handler = rawProp(self, "OnInvoke")
		if not handler then fail(2, "BindableFunction '%s': OnInvoke is not set", getFullName(self)) end
		return remoteArgs(handler(remoteArgs(...)))
	end,
}
for _, n in ipairs({ "FireServer", "FireClient", "FireAllClients", "InvokeServer", "InvokeClient", "Fire", "Invoke" }) do allMethodNames[n] = true end
resolved = {}

---- SECTION 8: modules, globals, reset ---------------------------------------------------

local robloxGlobals = setmetatable({}, { __index = NATIVE })
shim.globals = robloxGlobals
local treeDef = nil

local function robloxTypeof(v)
	if type(v) == "table" then
		if priv[v] then return "Instance" end
		local mt = getmetatable(v)
		if type(mt) == "table" then
			local t = rawget(mt, "__type")
			if t then return t end
		end
		return "table"
	end
	return nativeTypeof(v)
end
shim.typeof = robloxTypeof

local function modulePath(inst)
	local s = priv[inst]
	if s.module and s.module.path then return s.module.path end
	return (getFullName(inst):gsub("%.", "/"))
end

local function requireModule(target)
	if type(target) == "number" then fail(3, "require(%s): requiring by asset id is not supported in the offline harness", tostring(target)) end
	if type(target) == "string" then fail(3, "require(\"%s\"): requiring by string is not supported; require the ModuleScript instance (e.g. require(ReplicatedStorage.Shared.Types))", target) end
	if not isInstance(target) then fail(3, "Attempted to call require with invalid argument(s) (got %s)", nativeTypeof(target)) end
	local s = priv[target]
	if s.className ~= "ModuleScript" then fail(3, "Attempted to call require with invalid argument(s): %s is a %s, not a ModuleScript", getFullName(target), s.className) end
	if s.moduleLoaded then return s.moduleResult end
	local path = modulePath(target)
	if s.moduleLoading then fail(3, "Requested module %s was required recursively (require cycle: %s)", path, table.concat(shim._requireStack, " -> ") .. " -> " .. path) end
	local mod = s.module
	if not mod then
		local src = rawProp(target, "Source")
		if type(src) == "string" then mod = { source = src, chunkname = path, path = path } else fail(3, "Module %s has no source: it was not bundled and has no Source property", path) end
	end
	local fn, err = loadstring(mod.source, "=" .. (mod.chunkname or path))
	if not fn then fail(3, "Module %s failed to compile: %s", path, tostring(err)) end
	local env = setmetatable({ script = target }, { __index = robloxGlobals })
	setfenv(fn, env)
	s.moduleLoading = true
	table.insert(shim._requireStack, path)
	local ok, result = xpcall(fn, function(e)
		return { msg = tostring(e), tb = debug.traceback("", 2) }
	end)
	table.remove(shim._requireStack)
	s.moduleLoading = false
	if not ok then
		local msg = type(result) == "table" and result.msg or tostring(result)
		local tb = type(result) == "table" and result.tb or ""
		error(string.format("Requested module %s experienced an error while loading: %s%s", path, msg, tb), 0)
	end
	if result == nil then fail(3, "Module %s did not return a value (Module code did not return exactly one value)", path) end
	s.moduleLoaded = true
	s.moduleResult = result
	return result
end
shim._requireStack = {}
shim.require = requireModule

function shim.getInstance(path)
	if isInstance(path) then return path end
	if type(path) ~= "string" then fail(2, "shim.getInstance expects a path string, got %s", nativeTypeof(path)) end
	local cur = requireGame()
	local first = true
	for seg in path:gmatch("[^/%.]+") do
		if first and seg == "game" then
			-- skip
		elseif first then
			cur = services[seg] or (classes[seg] and getService(seg)) or findChildByName(priv[cur], seg)
			if not cur then fail(2, "No instance at path '%s' (unknown service or child '%s')", path, seg) end
		else
			local nxt = findChildByName(priv[cur], seg)
			if not nxt then fail(2, "No instance at path '%s' (missing child '%s' under %s)", path, seg, getFullName(cur)) end
			cur = nxt
		end
		first = false
	end
	return cur
end

function shim.requirePath(path)
	return requireModule(shim.getInstance(path))
end

function shim.runScript(target, opts)
	if type(target) == "string" then target = shim.getInstance(target) end
	if not isInstance(target) then fail(2, "shim.runScript expects a Script/LocalScript instance or path") end
	local s = priv[target]
	if not s.cls.isA.LuaSourceContainer then fail(2, "shim.runScript: %s is a %s, not a script", getFullName(target), s.className) end
	local path = modulePath(target)
	local mod = s.module
	if not mod then
		local src = rawProp(target, "Source")
		if type(src) == "string" then mod = { source = src, chunkname = path, path = path } else fail(2, "Script %s has no source (not bundled)", path) end
	end
	local fn, err = loadstring(mod.source, "=" .. (mod.chunkname or path))
	if not fn then fail(2, "Script %s failed to compile: %s", path, tostring(err)) end
	local env = setmetatable({ script = target }, { __index = robloxGlobals })
	setfenv(fn, env)
	local co = coroutine.create(fn)
	local ok, e = coroutine.resume(co)
	if not ok then
		error(string.format("Script %s errored: %s\n%s", path, tostring(e), debug.traceback(co, "", 0)), 0)
	end
	if opts and opts.wait and coroutine.status(co) ~= "dead" then shim.runUntilDead(co, opts.wait) end
	return co
end

function shim.listModules()
	local out = {}
	if not game then return out end
	for _, d in ipairs(collectDescendants(game, {})) do
		if priv[d].module then out[#out + 1] = priv[d].module.path end
	end
	table.sort(out)
	return out
end

-- tree building --------------------------------------------------------------------------------
local color3Props = { Ambient = true, OutdoorAmbient = true, ColorShift_Top = true, ColorShift_Bottom = true, FogColor = true, Color = true, Color3 = true, BackgroundColor3 = true, TextColor3 = true, ImageColor3 = true, TintColor = true, WaterColor = true, FillColor = true, OutlineColor = true, BorderColor3 = true, TextStrokeColor3 = true, SparkleColor = true, SecondaryColor = true }

local function convertTreeValue(key, value)
	if type(value) == "table" and getmetatable(value) == nil then
		if #value == 3 and type(value[1]) == "number" then
			if color3Props[key] then return Color3.new(value[1], value[2], value[3]) end
			return Vector3.new(value[1], value[2], value[3])
		elseif #value == 2 and type(value[1]) == "number" then
			return Vector2.new(value[1], value[2])
		elseif value.Enum and type(value.Enum) == "string" then
			local et, item = value.Enum:match("^Enum%.(%w+)%.(%w+)$")
			if et then return Enum[et][item] end
		end
	end
	return value
end

local serviceNames = {}
for name, c in pairs(classes) do
	if c.isService then serviceNames[name] = true end
end

local function buildNode(node, parent, pathPrefix)
	local inst
	local isTop = parent == game
	if isTop then
		inst = getService(node.className or node.name)
		if node.name and node.name ~= priv[inst].name then priv[inst].name = node.name end
	else
		inst = new(node.className or "Folder")
		priv[inst].name = node.name or node.className
	end
	local s = priv[inst]
	local path = pathPrefix .. s.name
	if node.properties then
		for k, v in pairs(node.properties) do
			local setter = s.cls.setters[k]
			local converted = convertTreeValue(k, v)
			if setter then setter(inst, s, converted) else s.props[k] = converted == nil and NIL or converted end
		end
	end
	if node.attributes then
		for k, v in pairs(node.attributes) do s.attrs[k] = convertTreeValue(k, v) end
	end
	if node.source then
		s.module = { source = node.source, chunkname = node.file or path, path = path }
	end
	if node.children then
		for _, child in ipairs(node.children) do buildNode(child, inst, path .. "/") end
	end
	if not isTop then setParent(inst, parent) end
	return inst
end

function shim.defineTree(def)
	treeDef = def
	shim.reset()
end

-- settings() / UserSettings() ---------------------------------------------------------------
local function makeSettings()
	local rendering = setmetatable({ QualityLevel = Enum.QualityLevel.Automatic, EditQualityLevel = Enum.QualityLevel.Automatic, ExportMergeByMaterial = false }, { __type = "RenderSettings" })
	return setmetatable({ Rendering = rendering, Physics = setmetatable({ AllowSleep = true, PhysicsEnvironmentalThrottle = Enum.EnviromentalPhysicsThrottle.DefaultAuto }, { __type = "PhysicsSettings" }), Diagnostics = {}, Network = {}, Studio = {} }, {
		__type = "GlobalSettings",
		__index = { GetService = function(self, name) return self[name] end, GetFFlag = function() return false end },
	})
end

local function makeUserSettings()
	return setmetatable({}, {
		__type = "UserSettings",
		__index = function(self, k)
			if k == "GetService" then
				return function(_, name) return getService(name) end
			elseif k == "GameSettings" then
				return getService("UserGameSettings")
			elseif k == "IsUserFeatureEnabled" then
				return function() return false end
			elseif k == "GetFFlag" or k == "GetFVariable" then
				return function() return false end
			elseif k == "Reset" or k == "SaveState" or k == "Restore" then
				return function() end
			end
			return nil
		end,
	})
end

-- globals ----------------------------------------------------------------------------------------
local robloxOs = setmetatable({
	clock = function() return shim.clock end,
	time = function(t)
		if t then return os.time(t) end
		return math.floor(DateTime._epochNow())
	end,
	date = function(fmt, t)
		if t == nil then t = math.floor(DateTime._epochNow()) end
		return os.date(fmt, t)
	end,
	difftime = function(a, b) return a - (b or 0) end,
}, { __index = os })

local robloxDebug = setmetatable({
	profilebegin = function() end, profileend = function() end,
	setmemorycategory = function() end, resetmemorycategory = function() end,
	traceback = debug.traceback, info = debug.info,
	dumpcodesize = function() end, dumpheap = function() end, dumprefs = function() end, loadmodule = function() return nil end,
}, { __index = debug })

do
	local g = robloxGlobals
	g.typeof = robloxTypeof
	g.print = robloxPrint
	g.warn = robloxWarn
	g.os = robloxOs
	g.debug = robloxDebug
	g.tick = function() return DateTime._epochNow() end
	g.time = function() return shim.clock - shim.clockStart end
	g.elapsedTime = function() return shim.clock - shim.clockStart end
	g.DateTime = DateTime
	g.task = task
	g.wait = legacyWait
	g.spawn = legacySpawn
	g.delay = legacyDelay
	g.require = requireModule
	g.Instance = Instance
	g.Vector3 = Vector3
	g.Vector2 = Vector2
	g.CFrame = CFrame
	g.Color3 = Color3
	g.BrickColor = BrickColor
	g.UDim = UDim
	g.UDim2 = UDim2
	g.NumberRange = NumberRange
	g.NumberSequence = NumberSequence
	g.NumberSequenceKeypoint = NumberSequenceKeypoint
	g.ColorSequence = ColorSequence
	g.ColorSequenceKeypoint = ColorSequenceKeypoint
	g.Rect = Rect
	g.TweenInfo = TweenInfo
	g.PhysicalProperties = PhysicalProperties
	g.RaycastParams = RaycastParams
	g.OverlapParams = OverlapParams
	g.Content = Content
	g.Random = Random
	g.Region3 = Region3
	g.Ray = Ray
	g.Font = Font
	g.Enum = Enum
	g.Axes = { new = function(...) local t = {} for _, a in ipairs({ ... }) do t[a.Name] = true end return setmetatable({ X = t.X or false, Y = t.Y or false, Z = t.Z or false }, { __type = "Axes" }) end }
	g.Faces = { new = function(...) local t = {} for _, a in ipairs({ ... }) do t[a.Name] = true end return setmetatable({ Top = t.Top or false, Bottom = t.Bottom or false, Left = t.Left or false, Right = t.Right or false, Back = t.Back or false, Front = t.Front or false }, { __type = "Faces" }) end }
	g.PathWaypoint = { new = function(pos, action, label) return setmetatable({ Position = pos, Action = action or Enum.PathWaypointAction.Walk, Label = label or "" }, { __type = "PathWaypoint" }) end }
	g.Vector3int16 = { new = function(x, y, z) return Vector3.new(math.floor(x or 0), math.floor(y or 0), math.floor(z or 0)) end }
	g.Vector2int16 = { new = function(x, y) return Vector2.new(math.floor(x or 0), math.floor(y or 0)) end }
	g.Region3int16 = { new = function(lo, hi) return Region3.new(lo, hi) end }
	g.CatalogSearchParams = { new = function() return setmetatable({ SearchKeyword = "", MinPrice = 0, MaxPrice = math.huge }, { __type = "CatalogSearchParams" }) end }
	g.settings = makeSettings
	g.UserSettings = makeUserSettings
	g.version = function() return "0.offline" end
	g.plugin = nil
	g.script = nil
	g.loadstring = nil
	g.collectgarbage = function(opt) if opt == "count" then return NATIVE.collectgarbage("count") end return 0 end
	g.gcinfo = function() return NATIVE.collectgarbage("count") end
	g.shared = {}
	g.ypcall = pcall
	g.PluginManager = nil
	g.DebuggerManager = nil
	g.stats = function() return getService("Stats") end
	g.printidentity = function() robloxPrint("Current identity is 2") end
	g.shim = shim
end

-- context / reset ---------------------------------------------------------------------------------
function shim.setContext(ctx, opts)
	if ctx ~= "server" and ctx ~= "client" then fail(2, "shim.setContext expects \"server\" or \"client\", got %s", tostring(ctx)) end
	shim.context = ctx
	if ctx == "client" then
		local players = getService("Players")
		if not rawProp(players, "LocalPlayer") and not (opts and opts.noLocalPlayer) then
			local p = shim.addPlayer("TestLocalPlayer", 1)
			setProp(players, "LocalPlayer", p)
		end
	end
end

local coreServices = { "Workspace", "Players", "Lighting", "ReplicatedStorage", "ReplicatedFirst", "ServerStorage", "ServerScriptService", "StarterGui", "StarterPlayer", "StarterPack", "SoundService", "RunService", "TweenService", "Debris", "HttpService", "CollectionService", "PhysicsService", "DataStoreService", "MarketplaceService", "UserInputService", "ContextActionService", "GuiService", "TextService", "Teams", "Chat", "TextChatService", "TeleportService", "BadgeService", "LocalizationService", "GroupService", "LogService", "VRService", "HapticService", "PolicyService", "MessagingService", "PathfindingService", "SocialService", "AnalyticsService", "Stats", "InsertService", "AssetService", "ScriptContext", "ProximityPromptService", "UserGameSettings", "MaterialService", "VoiceChatService", "TestService", "ContentProvider", "CoreGui" }
for _, n in ipairs(coreServices) do
	if classes[n] then classes[n].isService = true end
end

function shim.reset()
	-- scheduler and clocks
	sched.queue = {}
	sched.waitingEntry = setmetatable({}, { __mode = "k" })
	sched.seq = 0
	shim.clock = shim.clockStart
	shim.frame = 0
	shim.context = "server"
	shim.tweensInstant = false
	shim.prints = {}
	shim.warnings = {}
	shim.threadErrors = {}
	shim.threadErrorRecords = {}
	shim.boundToClose = {}
	shim.remoteLog = {}
	shim._requireStack = {}
	shim.datastore = { data = {}, failNextCalls = 0, latency = 0, calls = {} }
	shim.assetService = { calls = {}, failNextCalls = 0, latency = 0 }
	local simulate = shim.marketplace.simulatePurchase
	shim.marketplace = { prompts = {}, ownedPasses = {}, productInfo = {}, simulatePurchase = simulate }
	shim.input.lastInputType = nil
	shim.input.keysDown = {}
	shim.input.mouseLocation = nil
	shim._random = Random.new(42)
	guidCounter = 0
	raycastOverride = nil
	-- registries (reassign upvalues; closures see the new tables)
	services = {}
	collisionGroups = { Default = {} }
	activeTweens = {}
	for k in pairs(renderBindings) do renderBindings[k] = nil end
	for k in pairs(actionBindings) do actionBindings[k] = nil end
	for k in pairs(actionOrder) do actionOrder[k] = nil end
	tagRegistry.byTag = {}
	tagRegistry.addedSignals = {}
	tagRegistry.removedSignals = {}
	for k in pairs(stepHooks) do stepHooks[k] = nil end
	table.insert(stepHooks, runServiceStep)
	table.insert(stepHooks, tweenStep)
	-- DataModel
	game = new("DataModel")
	priv[game].isDataModel = true
	priv[game].name = "game"
	shim.game = game
	for _, n in ipairs(coreServices) do getService(n) end
	if treeDef then
		for _, child in ipairs(treeDef.children or {}) do buildNode(child, game, "") end
	end
	robloxGlobals.game = game
	robloxGlobals.Game = game
	robloxGlobals.workspace = getService("Workspace")
	robloxGlobals.Workspace = robloxGlobals.workspace
	shim.G = {}
	robloxGlobals._G = shim.G
	robloxGlobals.shared = {}
	return game
end

-- expose the mock API in the calling thread's global environment (specs use bare `game`, `Vector3`...)
function shim.install(env)
	env = env or getfenv(0)
	setmetatable(env, { __index = robloxGlobals })
	return env
end

-- expose datatypes on the shim table too
shim.Vector3, shim.Vector2, shim.CFrame, shim.Color3, shim.Enum, shim.Instance = Vector3, Vector2, CFrame, Color3, Enum, Instance
shim.isInstance = isInstance
shim.NIL = NIL
shim.mainThread = mainThread
shim.classes = classes

shim.reset()
return shim
