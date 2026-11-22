--!strict
--!optimize 2

--[=[
	Preferences: the round count the plugin remembers between sessions, kept between FEWEST_ROUNDS and MOST_ROUNDS

	Return type: the Preferences module table
	Example usage:
		local Kept = Preferences.New(plugin)
		Preferences.SetRounds(Kept, 1000)
--]=]

local Timing = require("../Core/Timing")

export type Preferences = {
	Plugin: Plugin?,
	Rounds: number,
}

local ROUNDS_SETTING = "rounds"
local FEWEST_ROUNDS = 20
local MOST_ROUNDS = 10_000

local Preferences = {}

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
	return { Plugin = Plugin, Rounds = Rounds }
end

function Preferences.SetRounds(self: Preferences, Wanted: number): number
	self.Rounds = Preferences.Kept(Wanted)
	if self.Plugin then
		local WasStored, Problem = pcall(self.Plugin.SetSetting, self.Plugin, ROUNDS_SETTING, self.Rounds)
		if not WasStored then
			warn(
				`[rbx-bench] could not save the round count, so it will be back to the old one after a restart: {Problem}`
			)
		end
	end
	return self.Rounds
end

return Preferences
