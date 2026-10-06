--!nonstrict
-- Fixture: part of a require cycle (CycleA -> CycleB -> CycleA).
local B = require(script.Parent.CycleB)
return { name = "A", b = B }
