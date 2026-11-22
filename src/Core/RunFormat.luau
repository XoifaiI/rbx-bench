--!strict
--!native
--!optimize 2

--[=[
	RunFormat: packs a bench's runs into one buffer and back, for saving. Samples are not kept. Fields are byte-aligned
	columns so zstd compresses them well. Change the layout only together with FORMAT_VERSION. Version 1, which had
	no span depths, is still read, with every span at depth 1

	Return type: the RunFormat module table
	Example usage:
		local Packed = RunFormat.Encode(Runs)
		local Outcome, Restored = RunFormat.Decode(Packed)
--]=]

local Results = require("./Results")
local Stats = require("./Stats")

export type RunRecord = {
	Id: number,
	Finished: number,
	Sizes: { Results.SizeRecord },
}

export type Outcome = "decoded" | "unsupported" | "damaged"

type Counts = {
	Runs: number,
	Sizes: number,
	Cases: number,
	Spans: number,
	Metrics: number,
	Rules: number,
	Reads: number,
	Strings: number,
	TextBytes: number,
	Bins: number,
	PlainBins: number,
}

type Sections = {
	RunLow: number,
	RunHigh: number,
	SizeLow: number,
	SizeHigh: number,
	CaseLow: number,
	CaseHigh: number,
	SpanLow: number,
	SpanHigh: number,
	MetricLow: number,
	MetricHigh: number,

	RunWords: number,
	SizeWords: number,
	CaseWords: number,
	SpanWords: number,
	MetricWords: number,
	RuleWords: number,
	ReadWords: number,
	StringWords: number,

	Bins: number,
	CaseFlags: number,
	RuleFlags: number,
	Text: number,
	PlainBins: number,
	Length: number,
}

local FORMAT_VERSION = 2
local VERSION_BEFORE_DEPTH = 1
local HEADER_BYTES = 48

local RUN_NUMBERS = 2
local SIZE_NUMBERS = 2
local CASE_NUMBERS = 12
local SPAN_NUMBERS = 4
local SPAN_NUMBERS_BEFORE_DEPTH = 3
local METRIC_NUMBERS = 1

local RUN_WORDS = 1
local SIZE_WORDS = 4
local CASE_WORDS = 4
local SPAN_WORDS = 1
local METRIC_WORDS = 1
local RULE_WORDS = 3
local READ_WORDS = 1
local STRING_WORDS = 1

local CASE_FLAGS = 3
local RULE_FLAGS = 1

local BINS_AS_NUMBERS = 0
local BINS_AS_COUNTS = 1
local MOST_COUNTED_SAMPLES = 65535

local KINDS: { Results.Kind } = { "baseline", "faster", "slower", "tie" }
local STATUSES: { Results.RuleStatus } = { "pass", "fail", "error" }

local SPLIT = buffer.create(8)

local RunFormat = {}

local function PutNumber(Target: buffer, Low: number, High: number, Value: number)
	buffer.writef64(SPLIT, 0, Value)
	buffer.writeu32(Target, Low, buffer.readu32(SPLIT, 0))
	buffer.writeu16(Target, Low + 4, buffer.readu16(SPLIT, 4))
	buffer.writeu16(Target, High, buffer.readu16(SPLIT, 6))
end

local function GetNumber(Source: buffer, Low: number, High: number): number
	buffer.writeu32(SPLIT, 0, buffer.readu32(Source, Low))
	buffer.writeu16(SPLIT, 4, buffer.readu16(Source, Low + 4))
	buffer.writeu16(SPLIT, 6, buffer.readu16(Source, High))
	return buffer.readf64(SPLIT, 0)
end

local function KindCode(Kind: Results.Kind): number
	if Kind == "baseline" then
		return 0
	elseif Kind == "faster" then
		return 1
	elseif Kind == "slower" then
		return 2
	elseif Kind == "tie" then
		return 3
	end
	error(`RunFormat cannot save a case whose kind is "{Kind}"; Results only makes baseline, faster, slower and tie`)
end

local function StatusCode(Status: Results.RuleStatus): number
	if Status == "pass" then
		return 0
	elseif Status == "fail" then
		return 1
	elseif Status == "error" then
		return 2
	end
	error(`RunFormat cannot save a rule whose status is "{Status}"; Results only makes pass, fail and error`)
end

local function SumsOf(SampleCount: number): buffer
	local Sums = buffer.create((SampleCount + 1) * 8)
	local Weight = 1 / SampleCount
	local Sum = 0
	for Count = 1, SampleCount do
		Sum += Weight
		buffer.writef64(Sums, Count * 8, Sum)
	end
	return Sums
end

local function SectionsOf(Counts: Counts, NumbersPerSpan: number): Sections
	local RunNumbers = Counts.Runs * RUN_NUMBERS
	local SizeNumbers = Counts.Sizes * SIZE_NUMBERS
	local CaseNumbers = Counts.Cases * CASE_NUMBERS
	local SpanNumbers = Counts.Spans * NumbersPerSpan
	local Numbers = RunNumbers + SizeNumbers + CaseNumbers + SpanNumbers + Counts.Metrics * METRIC_NUMBERS

	local RunLow = HEADER_BYTES
	local SizeLow = RunLow + RunNumbers * 6
	local CaseLow = SizeLow + SizeNumbers * 6
	local SpanLow = CaseLow + CaseNumbers * 6
	local MetricLow = SpanLow + SpanNumbers * 6

	local RunHigh = RunLow + Numbers * 6
	local SizeHigh = RunHigh + RunNumbers * 2
	local CaseHigh = SizeHigh + SizeNumbers * 2
	local SpanHigh = CaseHigh + CaseNumbers * 2
	local MetricHigh = SpanHigh + SpanNumbers * 2

	local RunWords = RunHigh + Numbers * 2
	local SizeWords = RunWords + Counts.Runs * RUN_WORDS * 4
	local CaseWords = SizeWords + Counts.Sizes * SIZE_WORDS * 4
	local SpanWords = CaseWords + Counts.Cases * CASE_WORDS * 4
	local MetricWords = SpanWords + Counts.Spans * SPAN_WORDS * 4
	local RuleWords = MetricWords + Counts.Metrics * METRIC_WORDS * 4
	local ReadWords = RuleWords + Counts.Rules * RULE_WORDS * 4
	local StringWords = ReadWords + Counts.Reads * READ_WORDS * 4

	local Bins = StringWords + Counts.Strings * STRING_WORDS * 4
	local CaseFlags = Bins + Counts.Bins * 2
	local RuleFlags = CaseFlags + Counts.Cases * CASE_FLAGS
	local Text = RuleFlags + Counts.Rules * RULE_FLAGS
	local PlainBins = Text + Counts.TextBytes

	return {
		RunLow = RunLow,
		RunHigh = RunHigh,
		SizeLow = SizeLow,
		SizeHigh = SizeHigh,
		CaseLow = CaseLow,
		CaseHigh = CaseHigh,
		SpanLow = SpanLow,
		SpanHigh = SpanHigh,
		MetricLow = MetricLow,
		MetricHigh = MetricHigh,

		RunWords = RunWords,
		SizeWords = SizeWords,
		CaseWords = CaseWords,
		SpanWords = SpanWords,
		MetricWords = MetricWords,
		RuleWords = RuleWords,
		ReadWords = ReadWords,
		StringWords = StringWords,

		Bins = Bins,
		CaseFlags = CaseFlags,
		RuleFlags = RuleFlags,
		Text = Text,
		PlainBins = PlainBins,
		Length = PlainBins + Counts.PlainBins * 8,
	}
end

local function Intern(Ids: { [string]: number }, Strings: { string }, Value: string)
	if Ids[Value] == nil then
		Ids[Value] = #Strings
		table.insert(Strings, Value)
	end
end

local function Census(Runs: { RunRecord }): (Counts, { [string]: number }, { string })
	local Ids: { [string]: number } = {}
	local Strings: { string } = {}

	local Sizes, Cases, Spans, Metrics, Rules, Reads, Bins = 0, 0, 0, 0, 0, 0, 0
	for _, Run in Runs do
		Sizes += #Run.Sizes
		for _, Size in Run.Sizes do
			Intern(Ids, Strings, Size.Label)
			Intern(Ids, Strings, Size.Baseline)

			Cases += #Size.Cases
			for _, Case in Size.Cases do
				Intern(Ids, Strings, Case.Name)
				Bins += #Case.Histogram.Bins

				Spans += #Case.Spans
				for _, Span in Case.Spans do
					Intern(Ids, Strings, Span.Name)
				end

				Metrics += #Case.Metrics
				for _, Metric in Case.Metrics do
					Intern(Ids, Strings, Metric.Name)
				end
			end

			Rules += #Size.Rules
			for _, Rule in Size.Rules do
				Intern(Ids, Strings, Rule.Name)
				Intern(Ids, Strings, Rule.Message)

				Reads += #Rule.Cases
				for _, Name in Rule.Cases do
					Intern(Ids, Strings, Name)
				end
			end
		end
	end

	local TextBytes = 0
	for _, Value in Strings do
		TextBytes += #Value
	end

	local Counts: Counts = {
		Runs = #Runs,
		Sizes = Sizes,
		Cases = Cases,
		Spans = Spans,
		Metrics = Metrics,
		Rules = Rules,
		Reads = Reads,
		Strings = #Strings,
		TextBytes = TextBytes,
		Bins = Bins,
		PlainBins = 0,
	}
	return Counts, Ids, Strings
end

local function WriteHeader(Target: buffer, Counts: Counts)
	buffer.writeu32(Target, 0, FORMAT_VERSION)
	buffer.writeu32(Target, 4, Counts.Runs)
	buffer.writeu32(Target, 8, Counts.Sizes)
	buffer.writeu32(Target, 12, Counts.Cases)
	buffer.writeu32(Target, 16, Counts.Spans)
	buffer.writeu32(Target, 20, Counts.Metrics)
	buffer.writeu32(Target, 24, Counts.Rules)
	buffer.writeu32(Target, 28, Counts.Reads)
	buffer.writeu32(Target, 32, Counts.Strings)
	buffer.writeu32(Target, 36, Counts.TextBytes)
	buffer.writeu32(Target, 40, Counts.Bins)
	buffer.writeu32(Target, 44, Counts.PlainBins)
end

local function ReadHeader(Source: buffer): Counts
	return {
		Runs = buffer.readu32(Source, 4),
		Sizes = buffer.readu32(Source, 8),
		Cases = buffer.readu32(Source, 12),
		Spans = buffer.readu32(Source, 16),
		Metrics = buffer.readu32(Source, 20),
		Rules = buffer.readu32(Source, 24),
		Reads = buffer.readu32(Source, 28),
		Strings = buffer.readu32(Source, 32),
		TextBytes = buffer.readu32(Source, 36),
		Bins = buffer.readu32(Source, 40),
		PlainBins = buffer.readu32(Source, 44),
	}
end

local function WriteBins(Target: buffer, At: number, Bins: { number }, SampleCount: number, Sums: buffer): boolean
	local BinCount = #Bins
	local Index = 1
	while Index + 3 <= BinCount do
		local First: number, Second: number = Bins[Index], Bins[Index + 1]
		local Third: number, Fourth: number = Bins[Index + 2], Bins[Index + 3]
		if math.abs(First) + math.abs(Second) + math.abs(Third) + math.abs(Fourth) ~= 0 then
			for Inner = Index, Index + 3 do
				local Share: number = Bins[Inner]
				local Count = math.floor(Share * SampleCount + 0.5)
				if not (Count >= 0 and Count <= SampleCount) or buffer.readf64(Sums, Count * 8) ~= Share then
					return false
				end
				buffer.writeu16(Target, At + Inner * 2 - 2, Count)
			end
		end
		Index += 4
	end
	for Inner = Index, BinCount do
		local Share: number = Bins[Inner]
		local Count = math.floor(Share * SampleCount + 0.5)
		if not (Count >= 0 and Count <= SampleCount) or buffer.readf64(Sums, Count * 8) ~= Share then
			return false
		end
		buffer.writeu16(Target, At + Inner * 2 - 2, Count)
	end
	return true
end

local function Write(
	Target: buffer,
	Sections: Sections,
	Counts: Counts,
	Runs: { RunRecord },
	Ids: { [string]: number },
	Strings: { string }
): { Stats.Histogram }
	local RunCount, SizeCount, CaseCount = Counts.Runs, Counts.Sizes, Counts.Cases
	local SpanCount, RuleCount = Counts.Spans, Counts.Rules

	local RunLow, RunHigh = Sections.RunLow, Sections.RunHigh
	local SizeLow, SizeHigh = Sections.SizeLow, Sections.SizeHigh
	local CaseLow, CaseHigh = Sections.CaseLow, Sections.CaseHigh
	local SpanLow, SpanHigh = Sections.SpanLow, Sections.SpanHigh
	local MetricLow, MetricHigh = Sections.MetricLow, Sections.MetricHigh

	local RunWords, SizeWords, CaseWords = Sections.RunWords, Sections.SizeWords, Sections.CaseWords
	local SpanWords, MetricWords = Sections.SpanWords, Sections.MetricWords
	local RuleWords, ReadWords, StringWords = Sections.RuleWords, Sections.ReadWords, Sections.StringWords

	local BinsAt = Sections.Bins
	local CaseFlags, RuleFlags = Sections.CaseFlags, Sections.RuleFlags

	local Plain: { Stats.Histogram } = {}
	local Sums = buffer.create(0)
	local SumsFor: number? = nil

	for _, Run in Runs do
		PutNumber(Target, RunLow, RunHigh, Run.Id)
		PutNumber(Target, RunLow + RunCount * 6, RunHigh + RunCount * 2, Run.Finished)
		buffer.writeu32(Target, RunWords, #Run.Sizes)
		RunLow += 6
		RunHigh += 2
		RunWords += 4

		for _, Size in Run.Sizes do
			PutNumber(Target, SizeLow, SizeHigh, Size.Size)
			PutNumber(Target, SizeLow + SizeCount * 6, SizeHigh + SizeCount * 2, Size.Noise)
			buffer.writeu32(Target, SizeWords, Ids[Size.Label])
			buffer.writeu32(Target, SizeWords + SizeCount * 4, Ids[Size.Baseline])
			buffer.writeu32(Target, SizeWords + SizeCount * 8, #Size.Cases)
			buffer.writeu32(Target, SizeWords + SizeCount * 12, #Size.Rules)
			SizeLow += 6
			SizeHigh += 2
			SizeWords += 4

			for _, Case in Size.Cases do
				local CaseStats = Case.Stats
				local Histogram = Case.Histogram
				local Bins = Histogram.Bins
				local SampleCount = Histogram.SampleCount

				local LowStep, HighStep = CaseCount * 6, CaseCount * 2
				PutNumber(Target, CaseLow, CaseHigh, Case.Ratio)
				PutNumber(Target, CaseLow + LowStep, CaseHigh + HighStep, CaseStats.Min)
				PutNumber(Target, CaseLow + LowStep * 2, CaseHigh + HighStep * 2, CaseStats.Median)
				PutNumber(Target, CaseLow + LowStep * 3, CaseHigh + HighStep * 3, CaseStats.Mean)
				PutNumber(Target, CaseLow + LowStep * 4, CaseHigh + HighStep * 4, CaseStats.P90)
				PutNumber(Target, CaseLow + LowStep * 5, CaseHigh + HighStep * 5, CaseStats.Low)
				PutNumber(Target, CaseLow + LowStep * 6, CaseHigh + HighStep * 6, CaseStats.High)
				PutNumber(Target, CaseLow + LowStep * 7, CaseHigh + HighStep * 7, CaseStats.Spread)
				PutNumber(Target, CaseLow + LowStep * 8, CaseHigh + HighStep * 8, CaseStats.Bytes)
				PutNumber(Target, CaseLow + LowStep * 9, CaseHigh + HighStep * 9, Histogram.Low)
				PutNumber(Target, CaseLow + LowStep * 10, CaseHigh + HighStep * 10, Histogram.High)
				PutNumber(Target, CaseLow + LowStep * 11, CaseHigh + HighStep * 11, SampleCount)
				CaseLow += 6
				CaseHigh += 2

				buffer.writeu32(Target, CaseWords, Ids[Case.Name])
				buffer.writeu32(Target, CaseWords + CaseCount * 4, #Case.Spans)
				buffer.writeu32(Target, CaseWords + CaseCount * 8, #Case.Metrics)
				buffer.writeu32(Target, CaseWords + CaseCount * 12, #Bins)
				CaseWords += 4

				local BinsKind = BINS_AS_NUMBERS
				if SampleCount >= 1 and SampleCount <= MOST_COUNTED_SAMPLES and SampleCount % 1 == 0 then
					if SampleCount ~= SumsFor then
						Sums = SumsOf(SampleCount)
						SumsFor = SampleCount
					end
					if WriteBins(Target, BinsAt, Bins, SampleCount, Sums) then
						BinsKind = BINS_AS_COUNTS
					end
				end
				if BinsKind == BINS_AS_NUMBERS then
					buffer.fill(Target, BinsAt, 0, #Bins * 2)
					table.insert(Plain, Histogram)
				end
				BinsAt += #Bins * 2

				buffer.writeu8(Target, CaseFlags, KindCode(Case.Kind))
				buffer.writeu8(Target, CaseFlags + CaseCount, if Case.MatchesBaseline then 1 else 0)
				buffer.writeu8(Target, CaseFlags + CaseCount * 2, BinsKind)
				CaseFlags += 1

				for _, Span in Case.Spans do
					PutNumber(Target, SpanLow, SpanHigh, Span.Time)
					PutNumber(Target, SpanLow + SpanCount * 6, SpanHigh + SpanCount * 2, Span.Count)
					PutNumber(Target, SpanLow + SpanCount * 12, SpanHigh + SpanCount * 4, Span.Share)
					PutNumber(Target, SpanLow + SpanCount * 18, SpanHigh + SpanCount * 6, Span.Depth)
					buffer.writeu32(Target, SpanWords, Ids[Span.Name])
					SpanLow += 6
					SpanHigh += 2
					SpanWords += 4
				end

				for _, Metric in Case.Metrics do
					PutNumber(Target, MetricLow, MetricHigh, Metric.Value)
					buffer.writeu32(Target, MetricWords, Ids[Metric.Name])
					MetricLow += 6
					MetricHigh += 2
					MetricWords += 4
				end
			end

			for _, Rule in Size.Rules do
				buffer.writeu32(Target, RuleWords, Ids[Rule.Name])
				buffer.writeu32(Target, RuleWords + RuleCount * 4, Ids[Rule.Message])
				buffer.writeu32(Target, RuleWords + RuleCount * 8, #Rule.Cases)
				buffer.writeu8(Target, RuleFlags, StatusCode(Rule.Status))
				RuleWords += 4
				RuleFlags += 1

				for _, Name in Rule.Cases do
					buffer.writeu32(Target, ReadWords, Ids[Name])
					ReadWords += 4
				end
			end
		end
	end

	local TextAt = Sections.Text
	for _, Value in Strings do
		buffer.writeu32(Target, StringWords, #Value)
		buffer.writestring(Target, TextAt, Value)
		StringWords += 4
		TextAt += #Value
	end

	return Plain
end

local function WithPlainBins(Packed: buffer, Sections: Sections, Counts: Counts, Plain: { Stats.Histogram }): buffer
	for _, Histogram in Plain do
		Counts.PlainBins += #Histogram.Bins
	end

	local Target = buffer.create(Sections.Length + Counts.PlainBins * 8)
	buffer.copy(Target, 0, Packed, 0, Sections.Length)
	WriteHeader(Target, Counts)

	local At = Sections.PlainBins
	for _, Histogram in Plain do
		for _, Share in Histogram.Bins do
			buffer.writef64(Target, At, Share)
			At += 8
		end
	end
	return Target
end

local function ReadStrings(Source: buffer, Sections: Sections, Counts: Counts): { string }?
	local WordsAt = Sections.StringWords
	local TextAt = Sections.Text
	local TextEnd = TextAt + Counts.TextBytes

	local Strings: { string } = table.create(Counts.Strings, "")
	for Index = 1, Counts.Strings do
		local Length = buffer.readu32(Source, WordsAt)
		if TextAt + Length > TextEnd then
			return nil
		end
		Strings[Index] = buffer.readstring(Source, TextAt, Length)
		WordsAt += 4
		TextAt += Length
	end
	return if TextAt == TextEnd then Strings else nil
end

local function Read(
	Source: buffer,
	Sections: Sections,
	Counts: Counts,
	Strings: { string },
	HasDepth: boolean
): { RunRecord }?
	local RunCount, SizeCount, CaseCount = Counts.Runs, Counts.Sizes, Counts.Cases
	local SpanCount, RuleCount = Counts.Spans, Counts.Rules

	local RunLow, RunHigh = Sections.RunLow, Sections.RunHigh
	local SizeLow, SizeHigh = Sections.SizeLow, Sections.SizeHigh
	local CaseLow, CaseHigh = Sections.CaseLow, Sections.CaseHigh
	local SpanLow, SpanHigh = Sections.SpanLow, Sections.SpanHigh
	local MetricLow, MetricHigh = Sections.MetricLow, Sections.MetricHigh

	local RunWords, SizeWords, CaseWords = Sections.RunWords, Sections.SizeWords, Sections.CaseWords
	local SpanWords, MetricWords = Sections.SpanWords, Sections.MetricWords
	local RuleWords, ReadWords = Sections.RuleWords, Sections.ReadWords

	local BinsAt = Sections.Bins
	local PlainAt = Sections.PlainBins
	local CaseFlags, RuleFlags = Sections.CaseFlags, Sections.RuleFlags

	local SizesLeft, CasesLeft, SpansLeft, MetricsLeft = SizeCount, CaseCount, SpanCount, Counts.Metrics
	local RulesLeft, ReadsLeft, BinsLeft, PlainLeft = RuleCount, Counts.Reads, Counts.Bins, Counts.PlainBins

	local Sums = buffer.create(0)
	local SumsFor: number? = nil

	local Runs: { RunRecord } = {}
	for RunIndex = 1, RunCount do
		local SizesHere = buffer.readu32(Source, RunWords)
		if SizesHere > SizesLeft then
			return nil
		end
		SizesLeft -= SizesHere

		local Sizes: { Results.SizeRecord } = {}
		Runs[RunIndex] = {
			Id = GetNumber(Source, RunLow, RunHigh),
			Finished = GetNumber(Source, RunLow + RunCount * 6, RunHigh + RunCount * 2),
			Sizes = Sizes,
		}
		RunLow += 6
		RunHigh += 2
		RunWords += 4

		for SizeIndex = 1, SizesHere do
			local Label = Strings[buffer.readu32(Source, SizeWords) + 1]
			local Baseline = Strings[buffer.readu32(Source, SizeWords + SizeCount * 4) + 1]
			local CasesHere = buffer.readu32(Source, SizeWords + SizeCount * 8)
			local RulesHere = buffer.readu32(Source, SizeWords + SizeCount * 12)
			if not Label or not Baseline or CasesHere > CasesLeft or RulesHere > RulesLeft then
				return nil
			end
			CasesLeft -= CasesHere
			RulesLeft -= RulesHere

			local Cases = table.create(CasesHere) :: { Results.CaseRecord }
			local Rules: { Results.RuleRecord } = {}
			Sizes[SizeIndex] = {
				Size = GetNumber(Source, SizeLow, SizeHigh),
				Label = Label,
				Noise = GetNumber(Source, SizeLow + SizeCount * 6, SizeHigh + SizeCount * 2),
				Baseline = Baseline,
				Cases = Cases,
				Rules = Rules,
			}
			SizeLow += 6
			SizeHigh += 2
			SizeWords += 4

			for CaseIndex = 1, CasesHere do
				local Name = Strings[buffer.readu32(Source, CaseWords) + 1]
				local SpansHere = buffer.readu32(Source, CaseWords + CaseCount * 4)
				local MetricsHere = buffer.readu32(Source, CaseWords + CaseCount * 8)
				local BinsHere = buffer.readu32(Source, CaseWords + CaseCount * 12)
				CaseWords += 4

				local Kind = KINDS[buffer.readu8(Source, CaseFlags) + 1]
				local Matches = buffer.readu8(Source, CaseFlags + CaseCount)
				local BinsKind = buffer.readu8(Source, CaseFlags + CaseCount * 2)
				CaseFlags += 1

				if
					not Name
					or not Kind
					or Matches > 1
					or SpansHere > SpansLeft
					or MetricsHere > MetricsLeft
					or BinsHere > BinsLeft
				then
					return nil
				end
				SpansLeft -= SpansHere
				MetricsLeft -= MetricsHere
				BinsLeft -= BinsHere

				local LowStep, HighStep = CaseCount * 6, CaseCount * 2
				local SampleCount = GetNumber(Source, CaseLow + LowStep * 11, CaseHigh + HighStep * 11)

				local Bins = table.create(BinsHere, 0)
				if BinsKind == BINS_AS_COUNTS then
					if not (SampleCount >= 1 and SampleCount <= MOST_COUNTED_SAMPLES and SampleCount % 1 == 0) then
						return nil
					end
					if SampleCount ~= SumsFor then
						Sums = SumsOf(SampleCount)
						SumsFor = SampleCount
					end
					local Bin = 1
					while Bin + 3 <= BinsHere do
						local At = BinsAt + Bin * 2 - 2
						if buffer.readu32(Source, At + 4) + buffer.readu32(Source, At) ~= 0 then
							for Inner = Bin, Bin + 3 do
								local Count = buffer.readu16(Source, BinsAt + Inner * 2 - 2)
								if Count > SampleCount then
									return nil
								end
								Bins[Inner] = buffer.readf64(Sums, Count * 8)
							end
						end
						Bin += 4
					end
					for Inner = Bin, BinsHere do
						local Count = buffer.readu16(Source, BinsAt + Inner * 2 - 2)
						if Count > SampleCount then
							return nil
						end
						Bins[Inner] = buffer.readf64(Sums, Count * 8)
					end
				elseif BinsKind == BINS_AS_NUMBERS then
					if BinsHere > PlainLeft then
						return nil
					end
					PlainLeft -= BinsHere
					for Bin = 1, BinsHere do
						Bins[Bin] = buffer.readf64(Source, PlainAt)
						PlainAt += 8
					end
				else
					return nil
				end
				BinsAt += BinsHere * 2

				local Spans = table.create(SpansHere) :: { Results.SpanRecord }
				for SpanIndex = 1, SpansHere do
					local SpanName = Strings[buffer.readu32(Source, SpanWords) + 1]
					if not SpanName then
						return nil
					end
					Spans[SpanIndex] = {
						Name = SpanName,
						Time = GetNumber(Source, SpanLow, SpanHigh),
						Count = GetNumber(Source, SpanLow + SpanCount * 6, SpanHigh + SpanCount * 2),
						Share = GetNumber(Source, SpanLow + SpanCount * 12, SpanHigh + SpanCount * 4),
						Depth = if HasDepth
							then GetNumber(Source, SpanLow + SpanCount * 18, SpanHigh + SpanCount * 6)
							else 1,
					}
					SpanLow += 6
					SpanHigh += 2
					SpanWords += 4
				end

				local Metrics = table.create(MetricsHere) :: { Results.MetricRecord }
				for MetricIndex = 1, MetricsHere do
					local MetricName = Strings[buffer.readu32(Source, MetricWords) + 1]
					if not MetricName then
						return nil
					end
					Metrics[MetricIndex] = { Name = MetricName, Value = GetNumber(Source, MetricLow, MetricHigh) }
					MetricLow += 6
					MetricHigh += 2
					MetricWords += 4
				end

				Cases[CaseIndex] = {
					Name = Name,
					Kind = Kind,
					Ratio = GetNumber(Source, CaseLow, CaseHigh),
					MatchesBaseline = Matches == 1,
					Stats = {
						Min = GetNumber(Source, CaseLow + LowStep, CaseHigh + HighStep),
						Median = GetNumber(Source, CaseLow + LowStep * 2, CaseHigh + HighStep * 2),
						Mean = GetNumber(Source, CaseLow + LowStep * 3, CaseHigh + HighStep * 3),
						P90 = GetNumber(Source, CaseLow + LowStep * 4, CaseHigh + HighStep * 4),
						Low = GetNumber(Source, CaseLow + LowStep * 5, CaseHigh + HighStep * 5),
						High = GetNumber(Source, CaseLow + LowStep * 6, CaseHigh + HighStep * 6),
						Spread = GetNumber(Source, CaseLow + LowStep * 7, CaseHigh + HighStep * 7),
						Samples = {},
						Bytes = GetNumber(Source, CaseLow + LowStep * 8, CaseHigh + HighStep * 8),
					},
					Histogram = {
						Low = GetNumber(Source, CaseLow + LowStep * 9, CaseHigh + HighStep * 9),
						High = GetNumber(Source, CaseLow + LowStep * 10, CaseHigh + HighStep * 10),
						SampleCount = SampleCount,
						Bins = Bins,
					},
					Spans = Spans,
					Metrics = Metrics,
				}
				CaseLow += 6
				CaseHigh += 2
			end

			for RuleIndex = 1, RulesHere do
				local RuleName = Strings[buffer.readu32(Source, RuleWords) + 1]
				local Message = Strings[buffer.readu32(Source, RuleWords + RuleCount * 4) + 1]
				local ReadsHere = buffer.readu32(Source, RuleWords + RuleCount * 8)
				local Status = STATUSES[buffer.readu8(Source, RuleFlags) + 1]
				if not RuleName or not Message or not Status or ReadsHere > ReadsLeft then
					return nil
				end
				ReadsLeft -= ReadsHere
				RuleWords += 4
				RuleFlags += 1

				local ReadCases: { string } = {}
				for ReadIndex = 1, ReadsHere do
					local ReadName = Strings[buffer.readu32(Source, ReadWords) + 1]
					if not ReadName then
						return nil
					end
					ReadCases[ReadIndex] = ReadName
					ReadWords += 4
				end
				Rules[RuleIndex] = { Name = RuleName, Status = Status, Message = Message, Cases = ReadCases }
			end
		end
	end

	local Unread = SizesLeft + CasesLeft + SpansLeft + MetricsLeft + RulesLeft + ReadsLeft + BinsLeft + PlainLeft
	return if Unread == 0 then Runs else nil
end

function RunFormat.Encode(Runs: { RunRecord }): buffer
	local Counts, Ids, Strings = Census(Runs)
	local Sections = SectionsOf(Counts, SPAN_NUMBERS)

	local Target = buffer.create(Sections.Length)
	WriteHeader(Target, Counts)

	local Plain = Write(Target, Sections, Counts, Runs, Ids, Strings)
	if #Plain > 0 then
		return WithPlainBins(Target, Sections, Counts, Plain)
	end
	return Target
end

function RunFormat.Decode(Encoded: buffer): (Outcome, { RunRecord })
	local Length = buffer.len(Encoded)
	if Length < 4 then
		return "damaged", {}
	end
	local Version = buffer.readu32(Encoded, 0)
	if Version ~= FORMAT_VERSION and Version ~= VERSION_BEFORE_DEPTH then
		return "unsupported", {}
	end
	if Length < HEADER_BYTES then
		return "damaged", {}
	end

	local HasDepth = Version ~= VERSION_BEFORE_DEPTH
	local Counts = ReadHeader(Encoded)
	local Sections = SectionsOf(Counts, if HasDepth then SPAN_NUMBERS else SPAN_NUMBERS_BEFORE_DEPTH)
	if Sections.Length ~= Length then
		return "damaged", {}
	end

	local Strings = ReadStrings(Encoded, Sections, Counts)
	if not Strings then
		return "damaged", {}
	end

	local Runs = Read(Encoded, Sections, Counts, Strings, HasDepth)
	if not Runs then
		return "damaged", {}
	end
	return "decoded", Runs
end

return RunFormat
