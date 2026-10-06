--!strict
-- Token-bucket rate limiter keyed by an arbitrary key (usually Player or Player..action).

export type RateLimiter = {
	Allow: (self: RateLimiter, key: any, cost: number?) -> boolean,
	Reset: (self: RateLimiter, key: any) -> (),
	Clear: (self: RateLimiter) -> (),
}

local RateLimiter = {}
RateLimiter.__index = RateLimiter

-- ratePerSecond: tokens refilled per second; burst: bucket capacity.
function RateLimiter.new(ratePerSecond: number, burst: number): RateLimiter
	assert(ratePerSecond > 0, "ratePerSecond must be positive")
	assert(burst >= 1, "burst must be >= 1")
	local self = setmetatable({
		_rate = ratePerSecond,
		_burst = burst,
		_buckets = {},
	}, RateLimiter)
	return (self :: any) :: RateLimiter
end

function RateLimiter.Allow(self, key, cost)
	local now = os.clock()
	local spend = cost or 1
	local bucket = self._buckets[key]
	if not bucket then
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

function RateLimiter.Reset(self, key)
	self._buckets[key] = nil
end

function RateLimiter.Clear(self)
	table.clear(self._buckets)
end

return RateLimiter
