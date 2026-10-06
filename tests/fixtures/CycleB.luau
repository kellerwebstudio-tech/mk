--!nonstrict
-- Fixture: part of a require cycle (CycleA -> CycleB -> CycleA).
local A = require(script.Parent.CycleA)
return { name = "B", a = A }
