--!strict
--!optimize 2

--[=[
	Preferences: the round count the plugin remembers between sessions, kept between FEWEST_ROUNDS and MOST_ROUNDS

	Return type: the Preferences class
	Example usage:
		local Kept = Preferences.New(plugin)
		Kept:SetRounds(1000)
--]=]

local Timing = require("../Core/Timing")

type PreferencesImpl = {
	__index: PreferencesImpl,
	Kept: (Wanted: number) -> number,
	New: (Plugin: Plugin?) -> Preferences,
	SetRounds: (self: Preferences, Wanted: number) -> number,
}

type PreferencesData = {
	Plugin: Plugin?,
	Rounds: number,
}

export type Preferences = setmetatable<PreferencesData, PreferencesImpl>

local ROUNDS_SETTING = "rounds"
local FEWEST_ROUNDS = 20
local MOST_ROUNDS = 10_000

local Preferences = {} :: PreferencesImpl
Preferences.__index = Preferences

function Preferences.Kept(Wanted: number): number
	if Wanted ~= Wanted then
		return Timing.Defaults.Rounds
	end
	return math.clamp(math.round(Wanted), FEWEST_ROUNDS, MOST_ROUNDS)
end

function Preferences.New(Plugin: Plugin?): Preferences
	local Rounds = Timing.Defaults.Rounds
	if Plugin then
		local WasRead, Stored = pcall(Plugin.GetSetting, Plugin, ROUNDS_SETTING)
		if WasRead and type(Stored) == "number" then
			Rounds = Preferences.Kept(Stored)
		end
	end

	local Data: PreferencesData = { Plugin = Plugin, Rounds = Rounds }
	return setmetatable(Data, Preferences) :: Preferences
end

function Preferences.SetRounds(self: Preferences, Wanted: number): number
	self.Rounds = Preferences.Kept(Wanted)

	local Plugin = self.Plugin
	if Plugin then
		local WasStored, Problem = pcall(Plugin.SetSetting, Plugin, ROUNDS_SETTING, self.Rounds)
		if not WasStored then
			warn(
				`[rbx-bench] could not save the round count, so it will be back to the old one after a restart: {Problem}`
			)
		end
	end
	return self.Rounds
end

return Preferences
