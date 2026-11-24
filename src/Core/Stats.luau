--!strict
--!native
--!optimize 2

--[=[
	Stats: statistics over timing samples, which are nanoseconds per call: summaries, paired comparison, noise and
	histograms. RunFormat relies on a histogram bin being 1 / SampleCount added once per sample

	Return type: the Stats module table
	Example usage:
		local Summary = Stats.Summarize(Samples)
--]=]

local Bench = require("../Bench")

type Stats = Bench.Stats
type Comparison = Bench.Comparison

export type Histogram = {
	Low: number,
	High: number,
	SampleCount: number,
	Bins: { number },
}

local MEDIAN_RANK_FACTOR = 0.98
local NARROWEST_RANGE = 1e-9

local Stats = {}

local function Sorted(Values: { number }): { number }
	local Copy = table.clone(Values)
	table.sort(Copy)
	return Copy
end

local function AtFraction(Ordered: { number }, Fraction: number): number
	return Ordered[math.clamp(math.ceil(#Ordered * Fraction), 1, #Ordered)]
end

local function MedianBounds(Ordered: { number }): (number, number)
	local Count = #Ordered
	local HalfWidth = MEDIAN_RANK_FACTOR * math.sqrt(Count)
	local LowRank = math.clamp(math.floor(Count / 2 - HalfWidth), 1, Count)
	local HighRank = math.clamp(math.ceil(Count / 2 + HalfWidth) + 1, 1, Count)
	return Ordered[LowRank], Ordered[HighRank]
end

function Stats.Summarize(Samples: { number }): Stats
	assert(#Samples > 0, "Stats.Summarize needs at least one sample; the runner returned none for this case")

	local Ordered = Sorted(Samples)
	local Total = 0
	for _, Sample in Ordered do
		Total += Sample
	end

	local Median = AtFraction(Ordered, 0.5)
	local P90 = AtFraction(Ordered, 0.9)
	local Low, High = MedianBounds(Ordered)

	return {
		Min = Ordered[1],
		Median = Median,
		Mean = Total / #Ordered,
		P90 = P90,
		Low = Low,
		High = High,
		Spread = if Median > 0 then (P90 - Ordered[1]) / Median else 0,
		Samples = Samples,
	}
end

function Stats.Compare(First: { number }, Second: { number }, Noise: number): Comparison
	assert(#First == #Second and #First > 0, "Stats.Compare needs the same number of rounds for both cases")

	local Ratios = table.create(#First, 0)
	for Round = 1, #First do
		local Sample: number, Other: number = First[Round], Second[Round]
		Ratios[Round] = if Other > 0 then Sample / Other else 1
	end

	table.sort(Ratios)
	local Ratio = AtFraction(Ratios, 0.5)
	local Low, High = MedianBounds(Ratios)

	return {
		Ratio = Ratio,
		Low = Low,
		High = High,
		Significant = (Low > 1 or High < 1) and math.abs(Ratio - 1) > Noise,
	}
end

function Stats.CompareMedians(First: number, Second: number, Noise: number): Comparison
	local Ratio = if Second > 0 then First / Second else 1
	return {
		Ratio = Ratio,
		Low = Ratio * (1 - Noise),
		High = Ratio * (1 + Noise),
		Significant = math.abs(Ratio - 1) > Noise,
	}
end

function Stats.Noise(Baseline: { number }, Control: { number }): number
	local Comparison = Stats.Compare(Control, Baseline, 0)
	return math.max(math.abs(Comparison.Low - 1), math.abs(Comparison.High - 1))
end

function Stats.Histogram(Samples: { number }, Low: number, High: number, Count: number): Histogram
	local Width = math.max(High - Low, NARROWEST_RANGE) / Count
	local Weight = 1 / #Samples

	local Bins = table.create(Count, 0)
	for _, Sample in Samples do
		if Sample >= Low and Sample <= High then
			local Bin = math.clamp(math.floor((Sample - Low) / Width) + 1, 1, Count)
			Bins[Bin] += Weight
		end
	end
	return { Low = Low, High = High, SampleCount = #Samples, Bins = Bins }
end

return Stats
