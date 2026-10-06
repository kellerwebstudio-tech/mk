--!nonstrict
-- tests/runner.luau — minimal BDD runner for the offline harness.
-- Globals provided: describe, it, xit, fit, beforeEach, afterEach, beforeAll, afterAll, expect.
-- tools/bundle.py loads this before the specs and calls __ddc_runner.run(args) at the end.

local shim = shim
if not shim then error("runner.luau requires the global `shim` (run through tools/bundle.py)") end

local runner = { resetBeforeEach = true, timeout = 120, verbose = true }

local function newNode(name, parent)
	return { name = name, parent = parent, children = {}, tests = {}, beforeEach = {}, afterEach = {}, beforeAll = {}, afterAll = {}, skip = false, focus = false }
end

local root = newNode("", nil)
local current = root
local anyFocused = false
local loadErrors = {}

local function nodePath(node)
	local parts = {}
	while node and node.parent do
		table.insert(parts, 1, node.name)
		node = node.parent
	end
	return table.concat(parts, " > ")
end

-- registration API ----------------------------------------------------------------------------
local function describe(name, fn, opts)
	if type(name) ~= "string" then error("describe expects a name string", 2) end
	if type(fn) ~= "function" then error("describe expects a function body", 2) end
	local node = newNode(name, current)
	node.skip = opts and opts.skip or false
	node.focus = opts and opts.focus or false
	if node.focus then anyFocused = true end
	table.insert(current.children, node)
	local prev = current
	current = node
	local ok, err = xpcall(fn, function(e) return tostring(e) .. "\n" .. debug.traceback("", 2) end)
	current = prev
	if not ok then table.insert(loadErrors, "describe \"" .. nodePath(node) .. "\" failed while registering: " .. tostring(err)) end
end

local function it(name, fn, opts)
	if type(name) ~= "string" then error("it expects a name string", 2) end
	if type(fn) ~= "function" then error("it expects a function body", 2) end
	local test = { name = name, fn = fn, opts = opts or {}, skip = opts and opts.skip or false, focus = opts and opts.focus or false }
	if test.focus then anyFocused = true end
	table.insert(current.tests, test)
end

local api = {}
api.describe = describe
api.it = it
api.xit = function(name, fn) it(name, fn or function() end, { skip = true }) end
api.xdescribe = function(name, fn) describe(name, fn, { skip = true }) end
api.fit = function(name, fn, opts) opts = opts or {} opts.focus = true it(name, fn, opts) end
api.fdescribe = function(name, fn) describe(name, fn, { focus = true }) end
api.beforeEach = function(fn) table.insert(current.beforeEach, fn) end
api.afterEach = function(fn) table.insert(current.afterEach, fn) end
api.beforeAll = function(fn) table.insert(current.beforeAll, fn) end
api.afterAll = function(fn) table.insert(current.afterAll, fn) end
api.test = it
api.context = describe

-- expect ------------------------------------------------------------------------------------------
local ExpectError = {}
ExpectError.__index = ExpectError
ExpectError.__tostring = function(e) return e.message end

local function fmt(v)
	local t = typeof(v)
	if t == "string" then return string.format("%q", v) end
	if t == "table" then
		local parts = {}
		local n = 0
		for k, val in pairs(v) do
			n += 1
			if n > 12 then parts[#parts + 1] = "..." break end
			parts[#parts + 1] = tostring(k) .. " = " .. (type(val) == "table" and (typeof(val) == "table" and "{...}" or tostring(val)) or fmt(val))
		end
		return "{ " .. table.concat(parts, ", ") .. " }"
	end
	if t == "Instance" then return t .. "<" .. v.ClassName .. " " .. v:GetFullName() .. ">" end
	if t ~= "number" and t ~= "boolean" and t ~= "nil" then return t .. "<" .. tostring(v) .. ">" end
	return tostring(v)
end

local function deepEqual(a, b, seen)
	if a == b then return true end
	if type(a) ~= "table" or type(b) ~= "table" then
		if type(a) == "number" and type(b) == "number" then return a ~= a and b ~= b end
		return false
	end
	if typeof(a) ~= "table" or typeof(b) ~= "table" then return false end -- datatypes/instances compare by ==
	seen = seen or {}
	if seen[a] == b then return true end
	seen[a] = b
	for k, v in pairs(a) do
		if not deepEqual(v, b[k], seen) then return false end
	end
	for k in pairs(b) do
		if a[k] == nil then return false end
	end
	return true
end
runner.deepEqual = deepEqual

local function raise(message)
	error(setmetatable({ message = message }, ExpectError), 0)
end

local function makeExpectation(value, negated)
	local obj = {}
	local function check(cond, positiveMsg, negativeMsg)
		if negated then
			if cond then raise("Expected " .. negativeMsg) end
		else
			if not cond then raise("Expected " .. positiveMsg) end
		end
		return obj
	end
	local function matcher(fn)
		return function(a, ...)
			if a == obj then return fn(...) end
			return fn(a, ...)
		end
	end
	obj.toBe = matcher(function(expected)
		return check(value == expected, fmt(value) .. " to be " .. fmt(expected), fmt(value) .. " not to be " .. fmt(expected))
	end)
	obj.toEqual = matcher(function(expected)
		return check(deepEqual(value, expected), fmt(value) .. " to deep-equal " .. fmt(expected), fmt(value) .. " not to deep-equal " .. fmt(expected))
	end)
	obj.toBeTruthy = matcher(function() return check(value and true or false, fmt(value) .. " to be truthy", fmt(value) .. " to be falsy") end)
	obj.toBeFalsy = matcher(function() return check(not value, fmt(value) .. " to be falsy", fmt(value) .. " to be truthy") end)
	obj.toBeNil = matcher(function() return check(value == nil, fmt(value) .. " to be nil", "value not to be nil") end)
	obj.toBeDefined = matcher(function() return check(value ~= nil, "value to be defined (not nil)", fmt(value) .. " to be nil") end)
	obj.toBeNaN = matcher(function() return check(type(value) == "number" and value ~= value, fmt(value) .. " to be NaN", fmt(value) .. " not to be NaN") end)
	obj.toBeCloseTo = matcher(function(expected, eps)
		eps = eps or 1e-5
		local ok = false
		if typeof(value) == "number" and typeof(expected) == "number" then
			ok = math.abs(value - expected) <= eps
		elseif typeof(value) == "Vector3" or typeof(value) == "Vector2" or typeof(value) == "CFrame" then
			ok = typeof(expected) == typeof(value) and value:FuzzyEq(expected, eps)
		elseif typeof(value) == "Color3" and typeof(expected) == "Color3" then
			ok = math.abs(value.R - expected.R) <= eps and math.abs(value.G - expected.G) <= eps and math.abs(value.B - expected.B) <= eps
		end
		return check(ok, fmt(value) .. " to be within " .. tostring(eps) .. " of " .. fmt(expected), fmt(value) .. " not to be within " .. tostring(eps) .. " of " .. fmt(expected))
	end)
	obj.toBeGreaterThan = matcher(function(x) return check(type(value) == "number" and value > x, fmt(value) .. " to be > " .. fmt(x), fmt(value) .. " not to be > " .. fmt(x)) end)
	obj.toBeLessThan = matcher(function(x) return check(type(value) == "number" and value < x, fmt(value) .. " to be < " .. fmt(x), fmt(value) .. " not to be < " .. fmt(x)) end)
	obj.toBeGreaterThanOrEqual = matcher(function(x) return check(type(value) == "number" and value >= x, fmt(value) .. " to be >= " .. fmt(x), fmt(value) .. " not to be >= " .. fmt(x)) end)
	obj.toBeLessThanOrEqual = matcher(function(x) return check(type(value) == "number" and value <= x, fmt(value) .. " to be <= " .. fmt(x), fmt(value) .. " not to be <= " .. fmt(x)) end)
	obj.toContain = matcher(function(x)
		local found = false
		if type(value) == "string" then
			found = string.find(value, tostring(x), 1, true) ~= nil
		elseif type(value) == "table" then
			for _, v in pairs(value) do
				if v == x or deepEqual(v, x) then found = true break end
			end
		end
		return check(found, fmt(value) .. " to contain " .. fmt(x), fmt(value) .. " not to contain " .. fmt(x))
	end)
	obj.toHaveLength = matcher(function(n)
		local len = type(value) == "string" and #value or (type(value) == "table" and #value or -1)
		return check(len == n, fmt(value) .. " to have length " .. tostring(n) .. " (got " .. tostring(len) .. ")", fmt(value) .. " not to have length " .. tostring(n))
	end)
	obj.toBeA = matcher(function(typeName)
		local actual = typeof(value)
		local ok = actual == typeName or (actual == "Instance" and value:IsA(typeName))
		return check(ok, fmt(value) .. " to be a " .. tostring(typeName) .. " (got " .. actual .. ")", fmt(value) .. " not to be a " .. tostring(typeName))
	end)
	obj.toMatch = matcher(function(pattern)
		return check(type(value) == "string" and string.find(value, pattern) ~= nil, fmt(value) .. " to match pattern " .. fmt(pattern), fmt(value) .. " not to match pattern " .. fmt(pattern))
	end)
	obj.toThrow = matcher(function(pattern)
		if type(value) ~= "function" then raise("expect(...).toThrow needs a function, got " .. typeof(value)) end
		local ok, err = pcall(value)
		local msg = ok and "" or (type(err) == "table" and err.message and err.message or tostring(err))
		local threw = not ok
		if threw and pattern ~= nil then threw = string.find(msg, pattern, 1, true) ~= nil or string.find(msg, pattern) ~= nil end
		local what = pattern ~= nil and ("to throw an error containing " .. fmt(pattern)) or "to throw"
		if not ok then what = what .. " (threw: " .. msg .. ")" end
		return check(threw, "function " .. what, "function not " .. what)
	end)
	if not negated then
		obj.never = makeExpectation(value, true)
	end
	return obj
end

api.expect = function(value)
	return makeExpectation(value, false)
end

-- running -----------------------------------------------------------------------------------------
local results = { passed = 0, failed = 0, skipped = 0, failures = {} }

local function cleanTraceback(tb)
	local lines = {}
	for line in tostring(tb):gmatch("[^\n]+") do
		if not line:find("tests/runner.luau", 1, true) and line:match("%S") then lines[#lines + 1] = line end
	end
	return table.concat(lines, "\n")
end

local function errToString(e, co)
	if type(e) == "table" and getmetatable(e) == ExpectError then return e.message end
	local msg = tostring(e)
	if co then
		local tb = cleanTraceback(debug.traceback(co, "", 0))
		if tb ~= "" then msg = msg .. "\n" .. tb end
	end
	return msg
end

local function runInThread(fn, budget)
	-- runs fn in a coroutine driven by the virtual scheduler; returns ok, errorMessage
	local co = coroutine.create(fn)
	local ok, err = coroutine.resume(co)
	if not ok then return false, errToString(err, co) end
	if coroutine.status(co) ~= "dead" then
		local errorsBefore = #shim.threadErrorRecords
		local finished = shim.runUntilDead(co, budget)
		for i = errorsBefore + 1, #shim.threadErrorRecords do
			local rec = shim.threadErrorRecords[i]
			if rec.thread == co then
				table.remove(shim.threadErrorRecords, i)
				table.remove(shim.threadErrors, i)
				return false, rec.message
			end
		end
		if not finished then
			return false, string.format("test yielded and did not finish within %s virtual seconds (deadlock or infinite wait; pending scheduler entries: %d)", tostring(budget), shim.pendingThreads())
		end
	end
	return true, nil
end

local function collectHooks(node, key, outerFirst)
	local list = {}
	local n = node
	while n do
		local hooks = n[key]
		if outerFirst then
			for i = #hooks, 1, -1 do table.insert(list, 1, hooks[i]) end
		else
			for _, h in ipairs(hooks) do table.insert(list, h) end
		end
		n = n.parent
	end
	return list
end

local function shouldRun(node, test)
	if test.skip then return false end
	local n = node
	while n do
		if n.skip then return false end
		n = n.parent
	end
	if anyFocused then
		if test.focus then return true end
		n = node
		while n do
			if n.focus then return true end
			n = n.parent
		end
		return false
	end
	return true
end

local function runTest(node, test, filter)
	local fullName = nodePath(node) .. " > " .. test.name
	if filter and not string.find(fullName, filter) then return end
	if not shouldRun(node, test) then
		results.skipped += 1
		if runner.verbose then print("  [SKIP] " .. test.name) end
		return
	end
	if runner.resetBeforeEach then shim.reset() end
	local befores = collectHooks(node, "beforeEach", true)
	local afters = collectHooks(node, "afterEach", false)
	local ok, err = runInThread(function()
		for _, h in ipairs(befores) do h() end
		test.fn()
	end, test.opts.timeout or runner.timeout)
	for _, h in ipairs(afters) do
		local aok, aerr = runInThread(h, runner.timeout)
		if not aok and ok then ok, err = false, "afterEach failed: " .. tostring(aerr) end
	end
	if ok and #shim.threadErrorRecords > 0 then
		ok = false
		local msgs = {}
		for _, rec in ipairs(shim.threadErrorRecords) do msgs[#msgs + 1] = rec.message end
		err = "background thread error(s) during the test:\n" .. table.concat(msgs, "\n")
	end
	if ok then
		results.passed += 1
		if runner.verbose then print("  [PASS] " .. test.name) end
	else
		results.failed += 1
		table.insert(results.failures, { name = fullName, message = err })
		print("  [FAIL] " .. test.name)
		for line in tostring(err):gmatch("[^\n]+") do print("         " .. line) end
	end
end

local function runNode(node, filter)
	if node.parent and runner.verbose then print(string.rep("  ", 0) .. nodePath(node)) end
	for _, h in ipairs(node.beforeAll) do
		local ok, err = pcall(h)
		if not ok then
			results.failed += 1
			table.insert(results.failures, { name = nodePath(node) .. " (beforeAll)", message = errToString(err) })
		end
	end
	for _, test in ipairs(node.tests) do runTest(node, test, filter) end
	for _, child in ipairs(node.children) do runNode(child, filter) end
	for _, h in ipairs(node.afterAll) do
		local ok, err = pcall(h)
		if not ok then
			results.failed += 1
			table.insert(results.failures, { name = nodePath(node) .. " (afterAll)", message = errToString(err) })
		end
	end
end

function runner.run(args)
	args = args or {}
	local filter = args[1]
	if filter == "" then filter = nil end
	if args[2] == "quiet" or args[1] == "quiet" then runner.verbose = false if args[1] == "quiet" then filter = nil end end
	for _, e in ipairs(loadErrors) do
		results.failed += 1
		table.insert(results.failures, { name = "(load)", message = e })
		print("[FAIL] " .. e)
	end
	runNode(root, filter)
	print("")
	if #results.failures > 0 then
		print("Failures:")
		for i, f in ipairs(results.failures) do
			print(string.format("  %d) %s", i, f.name))
			for line in tostring(f.message):gmatch("[^\n]+") do print("       " .. line) end
		end
		print("")
	end
	print(string.format("%d passed, %d failed, %d skipped", results.passed, results.failed, results.skipped))
	if results.failed > 0 then
		error(string.format("%d test(s) failed", results.failed), 0)
	end
	return results
end

runner.api = api
runner.results = results

-- install globals in the calling thread's environment
local env = getfenv(0)
for k, v in pairs(api) do env[k] = v end
env.__ddc_runner = runner
return runner
