--!nonstrict
-- Fixture: has a syntax error on purpose; the harness must only fail when it is required.
local x = = 1
return x
