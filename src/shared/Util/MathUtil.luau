--!strict
-- Small math helpers shared by client and server.

local MathUtil = {}

function MathUtil.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

function MathUtil.clamp01(value: number): number
	return math.clamp(value, 0, 1)
end

-- Frame-rate independent exponential smoothing. `speed` ~ how quickly the value chases the target.
function MathUtil.damp(current: number, target: number, speed: number, dt: number): number
	local t = 1 - math.exp(-speed * dt)
	return current + (target - current) * t
end

function MathUtil.dampVector(current: Vector3, target: Vector3, speed: number, dt: number): Vector3
	local t = 1 - math.exp(-speed * dt)
	return current:Lerp(target, t)
end

function MathUtil.dampCFrame(current: CFrame, target: CFrame, speed: number, dt: number): CFrame
	local t = 1 - math.exp(-speed * dt)
	return current:Lerp(target, t)
end

-- Moves current toward target by at most maxDelta.
function MathUtil.moveToward(current: number, target: number, maxDelta: number): number
	if math.abs(target - current) <= maxDelta then
		return target
	end
	return current + math.sign(target - current) * maxDelta
end

function MathUtil.sign(value: number): number
	if value > 0 then
		return 1
	elseif value < 0 then
		return -1
	end
	return 0
end

-- Wraps an angle into [-pi, pi].
function MathUtil.wrapAngle(angle: number): number
	local wrapped = (angle + math.pi) % (2 * math.pi) - math.pi
	return wrapped
end

-- Smallest signed difference from angle a to angle b.
function MathUtil.angleDelta(a: number, b: number): number
	return MathUtil.wrapAngle(b - a)
end

-- Heading (radians, around +Y) for a horizontal direction. Heading 0 looks toward -Z.
function MathUtil.headingFromDirection(direction: Vector3): number
	return math.atan2(-direction.X, -direction.Z)
end

function MathUtil.directionFromHeading(heading: number): Vector3
	return Vector3.new(-math.sin(heading), 0, -math.cos(heading))
end

function MathUtil.flatten(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

function MathUtil.horizontalDistance(a: Vector3, b: Vector3): number
	local dx = a.X - b.X
	local dz = a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

function MathUtil.round(value: number, step: number?): number
	local s = step or 1
	return math.floor(value / s + 0.5) * s
end

function MathUtil.formatCash(amount: number): string
	local rounded = math.floor(amount + 0.5)
	local text = tostring(math.abs(rounded))
	local formatted = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	if formatted:sub(1, 1) == "," then
		formatted = formatted:sub(2)
	end
	return (rounded < 0 and "-$" or "$") .. formatted
end

function MathUtil.formatTime(seconds: number): string
	local total = math.max(0, math.floor(seconds + 0.5))
	local minutes = math.floor(total / 60)
	local secs = total % 60
	return string.format("%d:%02d", minutes, secs)
end

function MathUtil.formatDistance(studs: number): string
	if studs >= 1000 then
		return string.format("%.1fk", studs / 1000)
	end
	return tostring(math.floor(studs + 0.5))
end

return MathUtil
