--!strict
-- Token-bucket rate limiter keyed by an arbitrary key (usually Player or Player..action).

export type RateLimiter = {
	Allow: (self: RateLimiter, key: any, cost: number?) -> boolean,
	Reset: (self: RateLimiter, key: any) -> (),
	Clear: (self: RateLimiter) -> (),
	Sweep: (self: RateLimiter, maxIdle: number?) -> number,
	Count: (self: RateLimiter) -> number,
}

type Bucket = { tokens: number, last: number }
type Impl = { _rate: number, _burst: number, _buckets: { [any]: Bucket }, _inserts: number }

local RateLimiter = {}
RateLimiter.__index = RateLimiter

-- Every SWEEP_EVERY new keys, Allow drops buckets idle for longer than their full refill time
-- (burst / rate): such a bucket reads exactly like a missing one, so dropping it never changes a
-- result. Keys built from client data (per-order ids) would otherwise accumulate for the life of
-- the server.
RateLimiter.SWEEP_EVERY = 256

-- ratePerSecond: tokens refilled per second; burst: bucket capacity.
function RateLimiter.new(ratePerSecond: number, burst: number): RateLimiter
	assert(ratePerSecond > 0, "ratePerSecond must be positive")
	assert(burst >= 1, "burst must be >= 1")
	local self = setmetatable({
		_rate = ratePerSecond,
		_burst = burst,
		_buckets = {},
		_inserts = 0,
	}, RateLimiter)
	return (self :: any) :: RateLimiter
end

-- Removes buckets whose last call is older than maxIdle seconds (default: the full refill time).
-- Returns the number of buckets removed.
function RateLimiter.Sweep(self: Impl, maxIdle: number?): number
	local now = os.clock()
	local idle = maxIdle or (self._burst / self._rate)
	local removed = 0
	for key, bucket in pairs(self._buckets) do
		if now - bucket.last >= idle then
			self._buckets[key] = nil
			removed += 1
		end
	end
	return removed
end

function RateLimiter.Count(self: Impl): number
	local count = 0
	for _ in pairs(self._buckets) do
		count += 1
	end
	return count
end

function RateLimiter.Allow(self: Impl, key: any, cost: number?): boolean
	local now = os.clock()
	local spend = cost or 1
	local bucket = self._buckets[key]
	if not bucket then
		self._inserts += 1
		if self._inserts >= RateLimiter.SWEEP_EVERY then
			self._inserts = 0
			RateLimiter.Sweep(self)
		end
		bucket = { tokens = self._burst, last = now }
		self._buckets[key] = bucket
	end
	local elapsed = now - bucket.last
	bucket.last = now
	bucket.tokens = math.min(self._burst, bucket.tokens + elapsed * self._rate)
	if bucket.tokens >= spend then
		bucket.tokens -= spend
		return true
	end
	return false
end

function RateLimiter.Reset(self: Impl, key: any)
	self._buckets[key] = nil
end

function RateLimiter.Clear(self: Impl)
	table.clear(self._buckets)
end

return RateLimiter
