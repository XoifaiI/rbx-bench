--!strict
--!optimize 2

--[=[
	RunHistory: keeps the last KEPT_RUNS runs of each bench and saves them to the plugin's settings, per place, packed
	by RunFormat and compressed. Only the newest run keeps its samples. A save over STORED_BUDGET drops the oldest
	runs from memory too, so memory holds what a restart brings back

	Return type: the RunHistory class
	Example usage:
		local History = RunHistory.New(plugin)
		local Runs = History:Get("sha256")
--]=]

local EncodingService = game:GetService("EncodingService")

local RunFormat = require("../Core/RunFormat")
local Results = require("../Core/Results")

export type RunRecord = RunFormat.RunRecord

type RunHistoryImpl = {
	__index: RunHistoryImpl,
	New: (Plugin: Plugin?) -> RunHistory,
	Get: (self: RunHistory, Key: string) -> { RunRecord },
	Add: (self: RunHistory, Key: string, Sizes: { Results.SizeRecord }) -> RunRecord,
	Clear: (self: RunHistory, Key: string) -> (),
}

type RunHistoryData = {
	Plugin: Plugin?,
	Runs: { [string]: { RunRecord } },
}

export type RunHistory = setmetatable<RunHistoryData, RunHistoryImpl>

local KEPT_RUNS = 30
local STORED_BUDGET = 2 * 2 ^ 20
local COMPRESSION_LEVEL = 3
local SETTING_PREFIX = "runs/"
local UNPUBLISHED_PLACE = "unpublished"

local Zstd = Enum.CompressionAlgorithm.Zstd

local RunHistory = {} :: RunHistoryImpl
RunHistory.__index = RunHistory

local function SettingKey(Key: string): string
	local Place = if game.PlaceId == 0 then UNPUBLISHED_PLACE else tostring(game.PlaceId)
	return `{SETTING_PREFIX}{Place}/{Key}`
end

local function Pack(Runs: { RunRecord }): string
	local Compressed = EncodingService:CompressBuffer(RunFormat.Encode(Runs), Zstd, COMPRESSION_LEVEL)
	return buffer.tostring(EncodingService:Base64Encode(Compressed))
end

local function Unpack(Stored: string): (RunFormat.Outcome, { RunRecord })
	local Compressed = EncodingService:Base64Decode(buffer.fromstring(Stored))
	if EncodingService:GetDecompressedBufferSize(Compressed, Zstd) == nil then
		return "damaged", {}
	end
	return RunFormat.Decode(EncodingService:DecompressBuffer(Compressed, Zstd))
end

local function Restore(Plugin: Plugin, Key: string): { RunRecord }
	local WasRead, Stored = pcall(Plugin.GetSetting, Plugin, SettingKey(Key))
	if not WasRead then
		warn(`[rbx-bench] could not read the saved runs of {Key}, so it starts with none: {Stored}`)
		return {}
	end
	if type(Stored) ~= "string" then
		return {}
	end

	local WasUnpacked, Outcome, Runs = pcall(Unpack, Stored)
	if not WasUnpacked or Outcome == "damaged" then
		warn(`[rbx-bench] the saved runs of {Key} are damaged, so it starts with none and the next run replaces them`)
		return {}
	end
	if Outcome == "unsupported" then
		warn(
			`[rbx-bench] the saved runs of {Key} were made by a newer rbx-bench, so it starts with none and the next `
				.. `run replaces them; update the plugin to keep them`
		)
		return {}
	end
	return Runs
end

local function PackDroppingOldest(Runs: { RunRecord }): string?
	local Stored = Pack(Runs)
	while #Stored > STORED_BUDGET do
		if #Runs == 1 then
			return nil
		end

		local Kept = math.clamp(math.floor(#Runs * STORED_BUDGET / #Stored), 1, #Runs - 1)
		while #Runs > Kept do
			table.remove(Runs, 1)
		end
		Stored = Pack(Runs)
	end
	return Stored
end

local function Store(Plugin: Plugin, Key: string, Runs: { RunRecord })
	local Stored = PackDroppingOldest(Runs)
	if not Stored then
		warn(`[rbx-bench] one run of {Key} is too large to save, so its runs will be gone after a restart`)
	end
	Plugin:SetSetting(SettingKey(Key), Stored)
end

local function DropSamples(Run: RunRecord)
	for _, Size in Run.Sizes do
		for _, Case in Size.Cases do
			Case.Stats.Samples = {}
		end
	end
end

function RunHistory.New(Plugin: Plugin?): RunHistory
	local Data: RunHistoryData = { Plugin = Plugin, Runs = {} }
	return setmetatable(Data, RunHistory) :: RunHistory
end

function RunHistory.Get(self: RunHistory, Key: string): { RunRecord }
	local Runs = self.Runs[Key]
	if Runs then
		return Runs
	end

	local Restored = if self.Plugin then Restore(self.Plugin, Key) else {}
	self.Runs[Key] = Restored
	return Restored
end

function RunHistory.Add(self: RunHistory, Key: string, Sizes: { Results.SizeRecord }): RunRecord
	local Runs = self:Get(Key)
	local Last = Runs[#Runs]

	local Run: RunRecord = {
		Id = if Last then Last.Id + 1 else 1,
		Finished = os.time(),
		Sizes = Sizes,
	}
	table.insert(Runs, Run)
	if Last then
		DropSamples(Last)
	end
	while #Runs > KEPT_RUNS do
		table.remove(Runs, 1)
	end

	local Plugin = self.Plugin
	if Plugin then
		task.delay(0, function()
			if self.Runs[Key] ~= Runs then
				return
			end

			local WasStored, Problem = pcall(Store, Plugin, Key, Runs)
			if not WasStored then
				warn(`[rbx-bench] could not save the runs of {Key}, so they will be gone after a restart: {Problem}`)
			end
		end)
	end

	return Run
end

function RunHistory.Clear(self: RunHistory, Key: string): ()
	self.Runs[Key] = {}
	local Plugin = self.Plugin
	if Plugin then
		local WasCleared, Problem = pcall(Plugin.SetSetting, Plugin, SettingKey(Key), nil)
		if not WasCleared then
			warn(
				`[rbx-bench] could not remove the saved runs of {Key}, so they will be back after a restart: {Problem}`
			)
		end
	end
end

return RunHistory
