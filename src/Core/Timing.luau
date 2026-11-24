--!strict
--!native
--!optimize 2

--[=[
	Timing: times a set of functions against each other in rounds of batched calls. Every round runs them in a newly
	shuffled order, because a function's time depends on what ran just before it. Calibrate sizes the batches and
	says how long one round will take. Samples are nanoseconds per call with call overhead removed. Both yield once
	a frame's worth of work has run, asking Progress first, and return nil when Progress answers false

	Return type: the Timing module table
	Example usage:
		local Calibration = Timing.Calibrate(Plan, Timing.Defaults, Environment, Progress)
		local Measurement = Timing.Measure(Plan, Calibration, Timing.Defaults, Environment, Progress)
--]=]

export type Environment = {
	Clock: () -> number,
	Yield: () -> (),
}

export type Options = {
	Rounds: number,
	BatchSeconds: number,
	WarmSeconds: number,
	FrameSeconds: number,
}

export type Calibration = {
	Calls: { number },
	Outputs: { any },
	RoundSeconds: number,
}

export type Measurement = {
	Samples: { { number } },
	Control: { number },
	Outputs: { any },
	Calls: { number },
}

export type Plan = {
	Runs: { Timed },
	Baseline: number,
	Input: any,
	Fresh: (() -> any)?,
	Before: ((Run: number) -> ())?,
	After: ((Run: number) -> ())?,
}

type Timed = (Input: any) -> any

local LARGEST_BATCH = 2 ^ 22
local FRESH_LARGEST_BATCH = 256
local NO_RUN = 0
local EMPTY_SAMPLES = 30
local SHUFFLE_SEED = 20261122
local SHUFFLE_MULTIPLIER = 48271
local SHUFFLE_MODULUS = 2147483647

local DEFAULTS: Options = {
	Rounds = 300,
	BatchSeconds = 120e-6,
	WarmSeconds = 300e-6,
	FrameSeconds = 16e-3,
}

local Timing = {
	Defaults = DEFAULTS,
}

local function Nothing(_Input: any): any
	return nil
end

local function TimeBatch(Run: Timed, Input: any, Calls: number, Clock: () -> number): number
	local Start = Clock()
	for _ = 1, Calls do
		Run(Input)
	end
	return Clock() - Start
end

local function TimeFresh(Run: Timed, Inputs: { any }, Calls: number, Clock: () -> number): number
	local Start = Clock()
	for Call = 1, Calls do
		Run(Inputs[Call])
	end
	return Clock() - Start
end

local function BatchOf(
	Plan: Plan,
	Run: Timed,
	Owner: number,
	Calls: number,
	Inputs: { any },
	Clock: () -> number
): number
	local Before = Plan.Before
	local After = Plan.After
	local Fresh = Plan.Fresh

	if Before and Owner ~= NO_RUN then
		Before(Owner)
	end

	local Elapsed: number
	if Fresh then
		if Owner ~= NO_RUN then
			for Call = 1, Calls do
				Inputs[Call] = Fresh()
			end
		end
		Elapsed = TimeFresh(Run, Inputs, Calls, Clock)
	else
		Elapsed = TimeBatch(Run, Plan.Input, Calls, Clock)
	end

	if After and Owner ~= NO_RUN then
		After(Owner)
	end
	return Elapsed
end

local function OutputOf(Plan: Plan, Index: number): any
	local Before = Plan.Before
	local After = Plan.After
	local Fresh = Plan.Fresh

	if Before then
		Before(Index)
	end

	local Output: any
	if Fresh then
		Output = Plan.Runs[Index](Fresh())
	else
		Output = Plan.Runs[Index](Plan.Input)
	end

	if After then
		After(Index)
	end
	return Output
end

function Timing.Pass(Plan: Plan, Index: number, Calls: number, Clock: () -> number): number
	return BatchOf(Plan, Plan.Runs[Index], Index, Calls, {}, Clock)
end

local function SlotsOf(Plan: Plan): ({ Timed }, { number })
	local Count = #Plan.Runs
	local Timed = table.clone(Plan.Runs)
	Timed[Count + 1] = Plan.Runs[Plan.Baseline]
	Timed[Count + 2] = Nothing

	local Owners = table.create(Count + 2, NO_RUN)
	for Slot = 1, Count do
		Owners[Slot] = Slot
	end
	Owners[Count + 1] = Plan.Baseline
	return Timed, Owners
end

function Timing.Calibrate(
	Plan: Plan,
	Options: Options,
	Environment: Environment,
	Progress: (Fraction: number) -> boolean
): Calibration?
	local Clock = Environment.Clock
	local Count = #Plan.Runs
	local EmptySlot = Count + 2
	local Largest = if Plan.Fresh then FRESH_LARGEST_BATCH else LARGEST_BATCH
	local Timed, Owners = SlotsOf(Plan)
	local Inputs: { any } = {}

	local Calls = table.create(EmptySlot, 0)
	local Outputs: { any } = {}
	local RoundSeconds = 0
	local LastYield = Clock()
	for Slot = 1, EmptySlot do
		if Clock() - LastYield > Options.FrameSeconds then
			if not Progress((Slot - 1) / EmptySlot) then
				return nil
			end
			Environment.Yield()
			LastYield = Clock()
		end

		if Slot <= Count then
			Outputs[Slot] = OutputOf(Plan, Slot)
		end

		local Trial = 1
		local Elapsed = BatchOf(Plan, Timed[Slot], Owners[Slot], Trial, Inputs, Clock)
		while Elapsed < Options.BatchSeconds / 4 and Trial < Largest do
			Trial *= 2
			Elapsed = BatchOf(Plan, Timed[Slot], Owners[Slot], Trial, Inputs, Clock)
		end
		Calls[Slot] = math.clamp(math.round(Trial * Options.BatchSeconds / Elapsed), 1, Largest)

		if Slot < EmptySlot then
			RoundSeconds += Calls[Slot] * Elapsed / Trial
		end
	end

	return { Calls = Calls, Outputs = Outputs, RoundSeconds = RoundSeconds }
end

function Timing.Measure(
	Plan: Plan,
	Calibration: Calibration,
	Options: Options,
	Environment: Environment,
	Progress: (Fraction: number) -> boolean
): Measurement?
	local Clock = Environment.Clock
	local Baseline = Plan.Baseline
	local Count = #Plan.Runs
	local ControlSlot = Count + 1
	local EmptySlot = Count + 2
	local Timed, Owners = SlotsOf(Plan)
	local Inputs: { any } = {}

	local function Batch(Slot: number, BatchCalls: number): number
		return BatchOf(Plan, Timed[Slot], Owners[Slot], BatchCalls, Inputs, Clock)
	end

	local Calls = table.clone(Calibration.Calls)
	local Outputs = Calibration.Outputs

	local Samples: { { number } } = {}
	for Slot = 1, ControlSlot do
		Samples[Slot] = table.create(Options.Rounds, 0)
	end

	local EmptyEvery = math.max(Options.Rounds // EMPTY_SAMPLES, 1)
	local Overhead: number? = nil

	local Order = table.create(ControlSlot, 0)
	for Slot = 1, ControlSlot do
		Order[Slot] = Slot
	end
	local Seed = SHUFFLE_SEED

	local LastYield = Clock()
	for Round = 1, Options.Rounds do
		for Last = ControlSlot, 2, -1 do
			Seed = Seed * SHUFFLE_MULTIPLIER % SHUFFLE_MODULUS
			local Other = Seed % Last + 1
			Order[Last], Order[Other] = Order[Other], Order[Last]
		end

		for Position = 1, ControlSlot do
			if Clock() - LastYield > Options.FrameSeconds then
				if not Progress((Round - 1) / Options.Rounds) then
					return nil
				end
				Environment.Yield()

				local Resumed = Clock()
				while Clock() - Resumed < Options.WarmSeconds do
					Batch(Baseline, Calls[Baseline])
				end
				LastYield = Clock()
			end

			local Slot = Order[Position]
			Samples[Slot][Round] = Batch(Slot, Calls[Slot]) / Calls[Slot] * 1e9
		end

		if Round % EmptyEvery == 0 then
			local Empty = Batch(EmptySlot, Calls[EmptySlot]) / Calls[EmptySlot] * 1e9
			Overhead = if Overhead then math.min(Overhead, Empty) else Empty
		end
	end

	local Removed = Overhead or 0
	for Slot = 1, ControlSlot do
		for Round, Sample in Samples[Slot] do
			Samples[Slot][Round] = math.max(Sample - Removed, 0)
		end
	end

	local Control = Samples[ControlSlot]
	Samples[ControlSlot] = nil
	Calls[ControlSlot] = nil
	Calls[EmptySlot] = nil

	return {
		Samples = Samples,
		Control = Control,
		Outputs = Outputs,
		Calls = Calls,
	}
end

return Timing
