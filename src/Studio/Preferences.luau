--!strict
--!optimize 2

--[=[
	Preferences: what the plugin remembers between sessions: the round count, kept between FEWEST_ROUNDS and
	MOST_ROUNDS, and the height the bar area was dragged to, or nil while the chart sizes it

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
	SetBarsHeight: (self: Preferences, Height: number?) -> (),
}

type PreferencesData = {
	Plugin: Plugin?,
	Rounds: number,
	BarsHeight: number?,
}

export type Preferences = setmetatable<PreferencesData, PreferencesImpl>

local ROUNDS_SETTING = "rounds"
local BARS_HEIGHT_SETTING = "bars height"
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

local function Read(Plugin: Plugin?, Setting: string): number?
	if not Plugin then
		return nil
	end
	local WasRead, Stored = pcall(Plugin.GetSetting, Plugin, Setting)
	if not WasRead or type(Stored) ~= "number" or Stored ~= Stored then
		return nil
	end
	return Stored
end

local function Save(Plugin: Plugin?, Setting: string, Value: number?, Loss: string)
	if not Plugin then
		return
	end
	local WasStored, Problem = pcall(Plugin.SetSetting, Plugin, Setting, Value)
	if not WasStored then
		warn(`[rbx-bench] could not save {Loss} after a restart: {Problem}`)
	end
end

function Preferences.New(Plugin: Plugin?): Preferences
	local StoredRounds = Read(Plugin, ROUNDS_SETTING)
	local StoredHeight = Read(Plugin, BARS_HEIGHT_SETTING)

	local Data: PreferencesData = {
		Plugin = Plugin,
		Rounds = if StoredRounds then Preferences.Kept(StoredRounds) else Timing.Defaults.Rounds,
		BarsHeight = if StoredHeight and StoredHeight > 0 then StoredHeight else nil,
	}
	return setmetatable(Data, Preferences) :: Preferences
end

function Preferences.SetRounds(self: Preferences, Wanted: number): number
	self.Rounds = Preferences.Kept(Wanted)
	Save(self.Plugin, ROUNDS_SETTING, self.Rounds, "the round count, so it will be back to the old one")
	return self.Rounds
end

function Preferences.SetBarsHeight(self: Preferences, Height: number?)
	self.BarsHeight = Height
	Save(self.Plugin, BARS_HEIGHT_SETTING, Height, "the bar area height, so the chart will size it again")
end

return Preferences
