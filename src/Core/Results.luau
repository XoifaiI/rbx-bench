--!strict
--!optimize 2

--[=[
	Results: turns one size's measurement into its result record: statistics and a verdict per case, span shares,
	metric values and rule results. It also decides when a run is too noisy to keep. A case's spans are listed
	parent before child, in the order each first ran, with Depth 1 for a span that ran inside no other. A case's
	output matches the baseline's when they are equal, both NaN, buffers of the same bytes, or tables whose keys
	and values match in turn; tables that refer back to themselves compare without looping

	Return type: the Results module table
	Example usage:
		local Record = Results.Judge(Suite, Cases, Baseline, Size, Measurement, SpanPasses, Previous)
--]=]

local Bench = require("../Bench")
local Timing = require("./Timing")
local Stats = require("./Stats")

export type Verdict = "baseline" | "faster" | "slower" | "tie"

export type SpanPass = {
	Parents: { number },
	Spans: { number },
	Seconds: { number },
	Counts: { number },
	Calls: number,
	Elapsed: number,
}

export type SpanRecord = {
	Name: string,
	Time: number,
	Count: number,
	Share: number,
	Depth: number,
}

export type MetricRecord = {
	Name: string,
	Value: number,
}

export type CaseRecord = {
	Name: string,
	Verdict: Verdict,
	Ratio: number,
	MatchesBaseline: boolean,
	Stats: Bench.Stats,
	Histogram: Stats.Histogram,
	Spans: { SpanRecord },
	Metrics: { MetricRecord },
}

export type RuleStatus = "pass" | "fail" | "error"

export type RuleRecord = {
	Name: string,
	Status: RuleStatus,
	Message: string,
	Cases: { string },
}

export type SizeRecord = {
	Size: number,
	Label: string,
	Noise: number,
	Baseline: string,
	Cases: { CaseRecord },
	Rules: { RuleRecord },
}

type Case = Bench.Case<any>
type Reads = { [string]: boolean }
type Compared = { [any]: { [any]: boolean } }

local HISTOGRAM_BINS = 120
local TAIL_SHOWN = 0.25
local ROOT_NODE = 1
local NOISE_LIMIT = 0.05

local Results = {}

function Results.NoiseProblem(Record: SizeRecord): string?
	if Record.Noise <= NOISE_LIMIT then
		return nil
	end
	return string.format(
		'Too noisy to trust: the two timings of "%s" taken in each round differ by %.1f%%, and a run is kept only up to %.1f%%. '
			.. "Close other programs, let Studio finish what it is doing and run again. "
			.. "If every run is rejected, the baseline is too quick or too irregular to time.",
		Record.Baseline,
		Record.Noise * 100,
		NOISE_LIMIT * 100
	)
end

function Results.CaseNamed(Record: SizeRecord, Name: string): CaseRecord?
	for _, Case in Record.Cases do
		if Case.Name == Name then
			return Case
		end
	end
	return nil
end

local function SameOutput(First: any, Second: any, Compared: Compared): boolean
	if First == Second then
		return true
	end
	if type(First) ~= type(Second) then
		return false
	end
	if type(First) == "number" then
		return First ~= First and Second ~= Second
	end
	if type(First) == "buffer" then
		return buffer.tostring(First) == buffer.tostring(Second)
	end
	if type(First) ~= "table" then
		return false
	end

	local Against = Compared[First]
	if not Against then
		Against = {}
		Compared[First] = Against
	end
	if Against[Second] then
		return true
	end
	Against[Second] = true

	for Key, Value in First do
		if not SameOutput(Value, Second[Key], Compared) then
			return false
		end
	end
	for Key in Second do
		if First[Key] == nil then
			return false
		end
	end
	return true
end

local function FindCase(Record: SizeRecord, Name: string): CaseRecord
	local Case = Results.CaseNamed(Record, Name)
	if not Case then
		error(`case "{Name}" is not part of this run; a skipped case has no results to read`, 3)
	end
	return Case
end

local function NewRun(Cases: { Case }, Record: SizeRecord, Previous: Bench.Run?, Reads: Reads): Bench.Run
	local function Of(_Self: Bench.Run, Case: Case): Bench.Stats
		Reads[Case.Name] = true
		return FindCase(Record, Case.Name).Stats
	end

	local function Compare(_Self: Bench.Run, First: Case, Second: Case): Bench.Comparison
		Reads[First.Name] = true
		Reads[Second.Name] = true

		local FirstStats = FindCase(Record, First.Name).Stats
		local SecondStats = FindCase(Record, Second.Name).Stats
		if #FirstStats.Samples > 0 and #FirstStats.Samples == #SecondStats.Samples then
			return Stats.Compare(FirstStats.Samples, SecondStats.Samples, Record.Noise)
		end
		return Stats.CompareMedians(FirstStats.Median, SecondStats.Median, Record.Noise)
	end

	local function Span(_Self: Bench.Run, Case: Case, Wanted: Bench.Span): Bench.SpanStats
		Reads[Case.Name] = true

		local Total: Bench.SpanStats = { Time = 0, Count = 0, Share = 0 }
		for _, Recorded in FindCase(Record, Case.Name).Spans do
			if Recorded.Name == Wanted.Name then
				Total.Time += Recorded.Time
				Total.Count += Recorded.Count
				Total.Share += Recorded.Share
			end
		end
		return Total
	end

	return {
		Size = Record.Size,
		Noise = Record.Noise,
		Cases = Cases,
		Previous = Previous,
		Of = Of,
		Compare = Compare,
		Span = Span,
	}
end

local function SpanRecords(Suite: Bench.Suite<any>, Pass: SpanPass, Median: number): { SpanRecord }
	local Inside: { { number } } = {}
	for Node = ROOT_NODE, #Pass.Spans do
		Inside[Node] = {}
	end
	for Node = ROOT_NODE + 1, #Pass.Spans do
		table.insert(Inside[Pass.Parents[Node]], Node)
	end

	local Records: { SpanRecord } = {}
	local function Visit(Parent: number, Depth: number)
		for _, Node in Inside[Parent] do
			local Share = if Pass.Elapsed > 0 then Pass.Seconds[Node] / Pass.Elapsed else 0
			table.insert(Records, {
				Name = Suite.Spans[Pass.Spans[Node]].Name,
				Time = Share * Median,
				Count = Pass.Counts[Node] / Pass.Calls,
				Share = Share,
				Depth = Depth,
			})
			Visit(Node, Depth + 1)
		end
	end
	Visit(ROOT_NODE, 1)
	return Records
end

local function ReadNames(Reads: Reads): { string }
	local Names: { string } = {}
	for Name in Reads do
		table.insert(Names, Name)
	end
	table.sort(Names)
	return Names
end

function Results.StartPass(Recorder: Bench.Recorder)
	Recorder.Current = ROOT_NODE
	Recorder.Parents = { ROOT_NODE }
	Recorder.Spans = { 0 }
	Recorder.Seconds = { 0 }
	Recorder.Counts = { 0 }
	Recorder.Children = { {} }
	Recorder.Enabled = true
end

function Results.StopPass(Recorder: Bench.Recorder, Calls: number, Elapsed: number): SpanPass
	Recorder.Enabled = false
	return {
		Parents = Recorder.Parents,
		Spans = Recorder.Spans,
		Seconds = Recorder.Seconds,
		Counts = Recorder.Counts,
		Calls = Calls,
		Elapsed = Elapsed,
	}
end

function Results.Lineup(Suite: Bench.Suite<any>): ({ Case }, number)
	local Cases: { Case } = {}
	local Baseline = 1
	for _, Case in Suite.Cases do
		if Case.IsSkipped then
			continue
		end
		table.insert(Cases, Case)
		if Case.IsBaseline then
			Baseline = #Cases
		end
	end

	assert(#Cases > 0, `suite "{Suite.Name}" has no cases to run; add one with Suite:Case or remove a Skip`)
	return Cases, Baseline
end

function Results.Judge(
	Suite: Bench.Suite<any>,
	Cases: { Case },
	Baseline: number,
	Size: number,
	Measurement: Timing.Measurement,
	SpanPasses: { SpanPass },
	Previous: SizeRecord?
): SizeRecord
	local Noise = Stats.Noise(Measurement.Samples[Baseline], Measurement.Control)

	local Record: SizeRecord = {
		Size = Size,
		Label = if Suite.SizeLabel then Suite.SizeLabel(Size) else tostring(Size),
		Noise = Noise,
		Baseline = Cases[Baseline].Name,
		Cases = {},
		Rules = {},
	}

	local Summaries: { Bench.Stats } = {}
	local Fastest: number? = nil
	local SlowestShown = 0
	for Index in Cases do
		local Summary = Stats.Summarize(Measurement.Samples[Index])
		Summaries[Index] = Summary
		Fastest = if Fastest then math.min(Fastest, Summary.Min) else Summary.Min
		SlowestShown = math.max(SlowestShown, Summary.P90 + (Summary.P90 - Summary.Min) * TAIL_SHOWN)
	end

	for Index, Case in Cases do
		local Samples = Measurement.Samples[Index]
		local Summary = Summaries[Index]

		local Verdict: Verdict = "baseline"
		local Ratio = 1
		if Index ~= Baseline then
			local Comparison = Stats.Compare(Samples, Measurement.Samples[Baseline], Noise)
			Ratio = Comparison.Ratio
			Verdict = if not Comparison.Significant then "tie" elseif Ratio < 1 then "faster" else "slower"
		end

		Record.Cases[Index] = {
			Name = Case.Name,
			Verdict = Verdict,
			Ratio = Ratio,
			MatchesBaseline = SameOutput(Measurement.Outputs[Index], Measurement.Outputs[Baseline], {}),
			Stats = Summary,
			Histogram = Stats.Histogram(Samples, Fastest or 0, SlowestShown, HISTOGRAM_BINS),
			Spans = SpanRecords(Suite, SpanPasses[Index], Summary.Median),
			Metrics = {},
		}
	end

	local PreviousRun = if Previous then NewRun(Cases, Previous, nil, {}) else nil

	local MetricRun = NewRun(Cases, Record, PreviousRun, {})
	for _, Metric in Suite.Metrics do
		for Index, Case in Cases do
			local Succeeded, Value = pcall(Metric.Compute, MetricRun, Case)
			if Succeeded and type(Value) == "number" then
				table.insert(Record.Cases[Index].Metrics, { Name = Metric.Name, Value = Value })
			else
				local Failed: RuleRecord = {
					Name = `metric "{Metric.Name}"`,
					Status = "error",
					Message = if Succeeded then `returned {type(Value)}, expected a number` else tostring(Value),
					Cases = { Case.Name },
				}
				table.insert(Record.Rules, Failed)
			end
		end
	end

	for _, Rule in Suite.Rules do
		local Reads: Reads = {}
		local Succeeded, Passed, Message = pcall(Rule.Check, NewRun(Cases, Record, PreviousRun, Reads))

		local Status: RuleStatus = "error"
		local Text = tostring(Passed)
		if Succeeded then
			Status = if Passed then "pass" else "fail"
			Text = if Message == nil then "" else tostring(Message)
		end

		local Result: RuleRecord = {
			Name = Rule.Name,
			Status = Status,
			Message = Text,
			Cases = ReadNames(Reads),
		}
		table.insert(Record.Rules, Result)
	end

	return Record
end

return Results
