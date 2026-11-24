--!strict
--!optimize 2

--[=[
	BenchRunner: runs one bench from start to finish: load it, time every size, record its spans, work out the results
	and store the run in History. A run that would take over ASK_FROM_SECONDS first asks Confirm for the round count
	to use, or nil to cancel. It yields, so call it from its own thread. A run that is too noisy or fails a rule is
	rejected and not stored. A failed or rejected run returns the reason as its second value

	Return type: the BenchRunner module table
	Example usage:
		local Status, Problem = BenchRunner.Run(Entry, History, Rounds, Progress, Confirm)
--]=]

local Bench = require("../Bench")
local RunHistory = require("./RunHistory")
local Results = require("../Core/Results")
local BenchFolder = require("./BenchFolder")
local Timing = require("../Core/Timing")

export type Status = "finished" | "cancelled" | "failed" | "rejected"

type Case = Bench.Case<any>
type Progress = (Fraction: number) -> boolean

export type Confirm = (RoundSeconds: number, Rounds: number) -> number?

local SPAN_BATCHES = 3
local ASK_FROM_SECONDS = 20
local SECONDS_BESIDE_TIMING = 1.1

local ENVIRONMENT: Timing.Environment = {
	Clock = os.clock,
	Yield = function()
		task.wait()
	end,
}

local BenchRunner = {}

local function PlanOf(Suite: Bench.Suite<any>, Cases: { Case }, Baseline: number, Size: number): Timing.Plan
	local Runs: { (Input: any) -> any } = {}
	for Index, Case in Cases do
		Runs[Index] = Case.Run
	end

	local Plan: Timing.Plan = {
		Runs = Runs,
		Baseline = Baseline,
		Input = nil,
	}

	if Suite.IsFresh then
		Plan.Fresh = function(): any
			return Suite.Input(Size)
		end
	else
		Plan.Input = Suite.Input(Size)
	end

	local BeforeEach = Suite.Hooks.BeforeEach
	if BeforeEach then
		Plan.Before = function(Run: number)
			BeforeEach(Cases[Run], Size)
		end
	end

	local AfterEach = Suite.Hooks.AfterEach
	if AfterEach then
		Plan.After = function(Run: number)
			AfterEach(Cases[Run], Size)
		end
	end

	return Plan
end

local function RecordSpans(
	Suite: Bench.Suite<any>,
	Plan: Timing.Plan,
	Calls: { number },
	FrameSeconds: number
): { Results.SpanPass }
	local Passes: { Results.SpanPass } = {}

	local LastYield = os.clock()
	for Index in Plan.Runs do
		if os.clock() - LastYield > FrameSeconds then
			task.wait()
			LastYield = os.clock()
		end

		local Total = Calls[Index] * SPAN_BATCHES

		Results.StartPass(Suite.Recorder)
		local Elapsed = Timing.Pass(Plan, Index, Total, os.clock)
		Passes[Index] = Results.StopPass(Suite.Recorder, Total, Elapsed)
	end
	return Passes
end

local function PreviousSize(Runs: { RunHistory.RunRecord }, Size: number): Results.SizeRecord?
	local Last = Runs[#Runs]
	if not Last then
		return nil
	end
	for _, Record in Last.Sizes do
		if Record.Size == Size then
			return Record
		end
	end
	return nil
end

local function Rejections(Sizes: { Results.SizeRecord }): string?
	local Lines: { string } = {}
	for _, Size in Sizes do
		local Noisy = Results.NoiseProblem(Size)
		if Noisy then
			table.insert(Lines, `Run rejected at size {Size.Size}. {Noisy}`)
		end

		for _, Rule in Size.Rules do
			if Rule.Status ~= "pass" then
				local Reason = if Rule.Message == "" then "" else `: {Rule.Message}`
				table.insert(Lines, `Run rejected at size {Size.Size}. {Rule.Name} did not pass{Reason}`)
			end
		end
	end
	return if #Lines > 0 then table.concat(Lines, "\n") else nil
end

local function MeasureSizes(
	Suite: Bench.Suite<any>,
	PreviousRuns: { RunHistory.RunRecord },
	Options: Timing.Options,
	Progress: Progress,
	Confirm: Confirm
): { Results.SizeRecord }?
	local Cases, Baseline = Results.Lineup(Suite)

	local BeforeAll = Suite.Hooks.BeforeAll
	if BeforeAll then
		BeforeAll()
	end

	local function KeepCalibrating(_Fraction: number): boolean
		return Progress(0)
	end

	local Plans: { Timing.Plan } = {}
	local Calibrations: { Timing.Calibration } = {}
	local RoundSeconds = 0
	for Position, Size in Suite.SizeList do
		Plans[Position] = PlanOf(Suite, Cases, Baseline, Size)
		local Calibration = Timing.Calibrate(Plans[Position], Options, ENVIRONMENT, KeepCalibrating)
		if not Calibration then
			return nil
		end
		Calibrations[Position] = Calibration
		RoundSeconds += Calibration.RoundSeconds * SECONDS_BESIDE_TIMING
	end

	if RoundSeconds * Options.Rounds > ASK_FROM_SECONDS then
		local Rounds = Confirm(RoundSeconds, Options.Rounds)
		if not Rounds then
			return nil
		end
		Options.Rounds = Rounds
	end

	local Sizes: { Results.SizeRecord } = {}
	for Position, Size in Suite.SizeList do
		local Plan = Plans[Position]

		local Measurement = Timing.Measure(
			Plan,
			Calibrations[Position],
			Options,
			ENVIRONMENT,
			function(Fraction: number)
				return Progress((Position - 1 + Fraction) / #Suite.SizeList)
			end
		)
		if not Measurement then
			return nil
		end

		local Passes = RecordSpans(Suite, Plan, Measurement.Calls, Options.FrameSeconds)
		table.insert(
			Sizes,
			Results.Judge(Suite, Cases, Baseline, Size, Measurement, Passes, PreviousSize(PreviousRuns, Size))
		)
	end
	return Sizes
end

function BenchRunner.Run(
	Entry: BenchFolder.Entry,
	History: RunHistory.RunHistory,
	Rounds: number,
	Progress: Progress,
	Confirm: Confirm
): (Status, string?)
	local Loaded, Unloadable = BenchFolder.Load(Entry)
	if not Loaded then
		return "failed", Unloadable
	end

	local Options = table.clone(Timing.Defaults)
	Options.Rounds = Rounds

	local Suite = Loaded.Suite
	local Succeeded, Sizes = xpcall(MeasureSizes, function(Problem: any): string
		return debug.traceback(tostring(Problem), 2)
	end, Suite, History:Get(Entry.Path), Options, Progress, Confirm)

	Suite.Recorder.Enabled = false

	local AfterAll = Suite.Hooks.AfterAll
	local Ended, AfterAllProblem = true, nil :: any
	if AfterAll then
		Ended, AfterAllProblem = pcall(AfterAll)
	end
	BenchFolder.Release(Loaded)

	if not Succeeded then
		return "failed", tostring(Sizes)
	end
	if not Ended then
		return "failed", `AfterAll failed: {AfterAllProblem}`
	end
	if not Sizes then
		return "cancelled", nil
	end
	local Rejected = Rejections(Sizes)
	if Rejected then
		return "rejected", Rejected
	end

	History:Add(Entry.Path, Sizes)
	return "finished", nil
end

return BenchRunner
