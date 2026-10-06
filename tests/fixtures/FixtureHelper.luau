--!strict
-- Fixture used by harness.spec.luau to prove sibling requires work.
local Helper = {}
Helper.value = 42
function Helper.double(x: number): number
	return x * 2
end
return Helper
