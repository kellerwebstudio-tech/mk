--!strict
-- Sound configuration. Sound ids are strings; "" means "no sound" and the AudioController skips it.
-- The rbxasset:// entries are sounds shipped with the Roblox client and are used as placeholders.
-- They are NOT verified in this build; replace them with your own uploaded assets (rbxassetid://...)
-- and keep the keys the same. See docs/README.md section "Audio".

local AudioConfig = {
	masterVolume = 0.8,

	sounds = {
		-- UI / feedback
		UIClick = { id = "rbxasset://sounds/button.wav", volume = 0.5 },
		OrderAccepted = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.6 },
		Pickup = { id = "rbxasset://sounds/snap.mp3", volume = 0.7 },
		Doorbell = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.8, pitch = 0.8 },
		Payment = { id = "rbxasset://sounds/victory.wav", volume = 0.6 },
		NewRecord = { id = "rbxasset://sounds/victory.wav", volume = 0.7, pitch = 1.2 },
		Error = { id = "rbxasset://sounds/bass.wav", volume = 0.5 },
		Purchase = { id = "rbxasset://sounds/clickfast.wav", volume = 0.6 },
		Notify = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.4, pitch = 1.1 },

		-- Vehicles (loops): replace with real engine loops; empty = silent
		BicycleChain = { id = "", volume = 0.35, loop = true },
		BicycleTires = { id = "", volume = 0.3, loop = true },
		ScooterEngine = { id = "", volume = 0.45, loop = true },
		VanEngine = { id = "", volume = 0.5, loop = true },
		Brake = { id = "rbxasset://sounds/swoosh.wav", volume = 0.35 },
		Bell = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.6, pitch = 1.5 },
		Horn = { id = "rbxasset://sounds/bass.wav", volume = 0.6, pitch = 1.4 },
		Bump = { id = "rbxasset://sounds/collide.wav", volume = 0.4 },
		Mount = { id = "rbxasset://sounds/action_get_up.mp3", volume = 0.4 },

		-- Ambience (loops)
		CityAmbience = { id = "", volume = 0.25, loop = true },
		RestaurantAmbience = { id = "", volume = 0.3, loop = true },
		ParkAmbience = { id = "", volume = 0.25, loop = true },
		IndustrialAmbience = { id = "", volume = 0.25, loop = true },
	},

	-- Engine pitch range by speed fraction
	enginePitchMin = 0.8,
	enginePitchMax = 1.6,
}

return AudioConfig
