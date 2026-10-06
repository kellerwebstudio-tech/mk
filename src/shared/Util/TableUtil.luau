--!strict
-- Table helpers: deep copy, reconcile with defaults, merge, counting, array utilities.

local TableUtil = {}

function TableUtil.deepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, inner in pairs(value :: any) do
		copy[key] = TableUtil.deepCopy(inner)
	end
	return (copy :: any) :: T
end

-- Fills missing keys in target from template (recursively for tables). Existing keys keep their value.
-- Returns target. Arrays (keys 1..n) in the template are copied only when the target lacks the key.
function TableUtil.reconcile(target: { [any]: any }, template: { [any]: any }): { [any]: any }
	for key, templateValue in pairs(template) do
		local existing = target[key]
		if existing == nil then
			target[key] = TableUtil.deepCopy(templateValue)
		elseif type(existing) == "table" and type(templateValue) == "table" and #templateValue == 0 then
			TableUtil.reconcile(existing, templateValue)
		end
	end
	return target
end

function TableUtil.merge(base: { [any]: any }, overrides: { [any]: any }?): { [any]: any }
	local result = TableUtil.deepCopy(base)
	if overrides then
		for key, value in pairs(overrides) do
			result[key] = TableUtil.deepCopy(value)
		end
	end
	return result
end

function TableUtil.count(tbl: { [any]: any }): number
	local n = 0
	for _ in pairs(tbl) do
		n += 1
	end
	return n
end

function TableUtil.keys(tbl: { [any]: any }): { any }
	local result = {}
	for key in pairs(tbl) do
		table.insert(result, key)
	end
	return result
end

function TableUtil.values<T>(tbl: { [any]: T }): { T }
	local result = {}
	for _, value in pairs(tbl) do
		table.insert(result, value)
	end
	return result
end

function TableUtil.contains(array: { any }, value: any): boolean
	for _, item in ipairs(array) do
		if item == value then
			return true
		end
	end
	return false
end

function TableUtil.indexOf(array: { any }, value: any): number?
	for index, item in ipairs(array) do
		if item == value then
			return index
		end
	end
	return nil
end

function TableUtil.filter<T>(array: { T }, predicate: (T, number) -> boolean): { T }
	local result = {}
	for index, item in ipairs(array) do
		if predicate(item, index) then
			table.insert(result, item)
		end
	end
	return result
end

function TableUtil.map<T, U>(array: { T }, mapper: (T, number) -> U): { U }
	local result = {}
	for index, item in ipairs(array) do
		result[index] = mapper(item, index)
	end
	return result
end

function TableUtil.removeValue(array: { any }, value: any): boolean
	local index = TableUtil.indexOf(array, value)
	if index then
		table.remove(array, index)
		return true
	end
	return false
end

function TableUtil.shuffle<T>(array: { T }, random: Random?): { T }
	local rng = random or Random.new()
	for i = #array, 2, -1 do
		local j = rng:NextInteger(1, i)
		array[i], array[j] = array[j], array[i]
	end
	return array
end

function TableUtil.deepEquals(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in pairs(a) do
		if not TableUtil.deepEquals(value, b[key]) then
			return false
		end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end
	return true
end

-- Returns true when the value is a finite number.
function TableUtil.isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

return TableUtil
