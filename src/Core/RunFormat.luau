--!strict
--!native
--!optimize 2

--[=[
	RunFormat: packs a bench's runs into one buffer and back, for saving. Samples are not kept. Fields are
	byte-aligned columns so zstd compresses them well: after a header of counts come every record's numbers (the low
	six bytes of each, then the high two), its u32 words, histogram bins as u16 sample counts, u8 flags, the text of
	every string, and last the bins of any histogram that is not whole counts, as f64. Column C of record I in a
	section is at the section's start plus (C * the section's record count + I) * the column's width

	Each record type is written and read in one pass over all records of that type, children before parents on the
	way in, so a case takes its spans as a slice of the spans already read

	Change the layout only together with FORMAT_VERSION and LAYOUTS. Older versions are still read: version 1 had no
	span depths and reads every span at depth 1, and version 2's bytes per call column is skipped. A verdict or a
	rule status is saved as its place in VERDICTS or STATUSES, so those lists only ever grow at the end

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

type Layout = {
	CaseNumbers: number,
	HistogramAt: number,
	SpanNumbers: number,
	HasDepth: boolean,
}

type NumberColumns = {
	Low: number,
	High: number,
	Count: number,
}

type Columns = {
	At: number,
	Count: number,
}

type Sections = {
	RunNumbers: NumberColumns,
	SizeNumbers: NumberColumns,
	CaseNumbers: NumberColumns,
	SpanNumbers: NumberColumns,
	MetricNumbers: NumberColumns,

	RunWords: Columns,
	SizeWords: Columns,
	CaseWords: Columns,
	SpanWords: Columns,
	MetricWords: Columns,
	RuleWords: Columns,
	ReadWords: Columns,
	StringWords: Columns,

	Bins: number,
	CaseFlags: Columns,
	RuleFlags: Columns,
	Text: number,
	PlainBins: number,
	Length: number,
}

type Contents = {
	Counts: Counts,
	Ids: { [string]: number },
	Strings: { string },
	Sizes: { Results.SizeRecord },
	Cases: { Results.CaseRecord },
	Spans: { Results.SpanRecord },
	Metrics: { Results.MetricRecord },
	Rules: { Results.RuleRecord },
}

type Writer = {
	Target: buffer,
	Sections: Sections,
	Ids: { [string]: number },
}

type Reader = {
	Source: buffer,
	Sections: Sections,
	Counts: Counts,
	Layout: Layout,
	Strings: { string },
}

type SumsCache = {
	SampleCount: number?,
	Sums: buffer,
}

local FORMAT_VERSION = 3
local HEADER_BYTES = 48

local LAYOUTS: { [number]: Layout } = {
	[1] = { CaseNumbers = 12, HistogramAt = 9, SpanNumbers = 3, HasDepth = false },
	[2] = { CaseNumbers = 12, HistogramAt = 9, SpanNumbers = 4, HasDepth = true },
	[3] = { CaseNumbers = 11, HistogramAt = 8, SpanNumbers = 4, HasDepth = true },
}
local CURRENT = LAYOUTS[FORMAT_VERSION]

local RUN_NUMBERS = 2
local RUN_NUMBER = { Id = 0, Finished = 1 }
local RUN_WORDS = 1
local RUN_WORD = { SizeCount = 0 }

local SIZE_NUMBERS = 2
local SIZE_NUMBER = { Size = 0, Noise = 1 }
local SIZE_WORDS = 4
local SIZE_WORD = { Label = 0, Baseline = 1, CaseCount = 2, RuleCount = 3 }

local CASE_NUMBER = { Ratio = 0, Min = 1, Median = 2, Mean = 3, P90 = 4, Low = 5, High = 6, Spread = 7 }
local HISTOGRAM_NUMBER = { Low = 0, High = 1, SampleCount = 2 }
local CASE_WORDS = 4
local CASE_WORD = { Name = 0, SpanCount = 1, MetricCount = 2, BinCount = 3 }
local CASE_FLAGS = 3
local CASE_FLAG = { Verdict = 0, MatchesBaseline = 1, BinsStoredAs = 2 }

local SPAN_NUMBER = { Time = 0, Count = 1, Share = 2, Depth = 3 }
local SPAN_WORDS = 1

local METRIC_NUMBERS = 1
local METRIC_WORDS = 1

local RULE_WORDS = 3
local RULE_WORD = { Name = 0, Message = 1, ReadCount = 2 }
local RULE_FLAGS = 1

local READ_WORDS = 1
local STRING_WORDS = 1

local BINS_AS_NUMBERS = 0
local BINS_AS_COUNTS = 1
local MOST_COUNTED_SAMPLES = 65535

local VERDICTS: { Results.Verdict } = { "baseline", "faster", "slower", "tie" }
local STATUSES: { Results.RuleStatus } = { "pass", "fail", "error" }

local SPLIT = buffer.create(8)

local function CodesOf<Name>(Names: { Name }): { [Name]: number }
	local Codes: { [Name]: number } = {}
	for Index, Value in Names do
		Codes[Value] = Index - 1
	end
	return Codes
end

local VERDICT_CODES = CodesOf(VERDICTS)
local STATUS_CODES = CodesOf(STATUSES)

local RunFormat = {}

local function PutNumber(Target: buffer, Low: number, High: number, Records: number, Column: number, Value: number)
	buffer.writef64(SPLIT, 0, Value)
	buffer.writeu32(Target, Low + Column * 6 * Records, buffer.readu32(SPLIT, 0))
	buffer.writeu16(Target, Low + Column * 6 * Records + 4, buffer.readu16(SPLIT, 4))
	buffer.writeu16(Target, High + Column * 2 * Records, buffer.readu16(SPLIT, 6))
end

local function GetNumber(Source: buffer, Low: number, High: number, Records: number, Column: number): number
	buffer.writeu32(SPLIT, 0, buffer.readu32(Source, Low + Column * 6 * Records))
	buffer.writeu16(SPLIT, 4, buffer.readu16(Source, Low + Column * 6 * Records + 4))
	buffer.writeu16(SPLIT, 6, buffer.readu16(Source, High + Column * 2 * Records))
	return buffer.readf64(SPLIT, 0)
end

local function PutWord(Target: buffer, At: number, Records: number, Column: number, Value: number)
	buffer.writeu32(Target, At + Column * 4 * Records, Value)
end

local function GetWord(Source: buffer, At: number, Records: number, Column: number): number
	return buffer.readu32(Source, At + Column * 4 * Records)
end

local function PutFlag(Target: buffer, At: number, Records: number, Column: number, Value: number)
	buffer.writeu8(Target, At + Column * Records, Value)
end

local function GetFlag(Source: buffer, At: number, Records: number, Column: number): number
	return buffer.readu8(Source, At + Column * Records)
end

local function SectionsOf(Counts: Counts, Layout: Layout): Sections
	local NumberSlots = Counts.Runs * RUN_NUMBERS
		+ Counts.Sizes * SIZE_NUMBERS
		+ Counts.Cases * Layout.CaseNumbers
		+ Counts.Spans * Layout.SpanNumbers
		+ Counts.Metrics * METRIC_NUMBERS

	local LowAt = HEADER_BYTES
	local HighAt = LowAt + NumberSlots * 6
	local At = HighAt + NumberSlots * 2

	local function Numbers(Count: number, PerRecord: number): NumberColumns
		local Section: NumberColumns = { Low = LowAt, High = HighAt, Count = Count }
		LowAt += Count * PerRecord * 6
		HighAt += Count * PerRecord * 2
		return Section
	end

	local function Fixed(Count: number, PerRecord: number, Width: number): Columns
		local Section: Columns = { At = At, Count = Count }
		At += Count * PerRecord * Width
		return Section
	end

	local function Bytes(Length: number): number
		local Start = At
		At += Length
		return Start
	end

	local RunNumbers = Numbers(Counts.Runs, RUN_NUMBERS)
	local SizeNumbers = Numbers(Counts.Sizes, SIZE_NUMBERS)
	local CaseNumbers = Numbers(Counts.Cases, Layout.CaseNumbers)
	local SpanNumbers = Numbers(Counts.Spans, Layout.SpanNumbers)
	local MetricNumbers = Numbers(Counts.Metrics, METRIC_NUMBERS)

	local RunWords = Fixed(Counts.Runs, RUN_WORDS, 4)
	local SizeWords = Fixed(Counts.Sizes, SIZE_WORDS, 4)
	local CaseWords = Fixed(Counts.Cases, CASE_WORDS, 4)
	local SpanWords = Fixed(Counts.Spans, SPAN_WORDS, 4)
	local MetricWords = Fixed(Counts.Metrics, METRIC_WORDS, 4)
	local RuleWords = Fixed(Counts.Rules, RULE_WORDS, 4)
	local ReadWords = Fixed(Counts.Reads, READ_WORDS, 4)
	local StringWords = Fixed(Counts.Strings, STRING_WORDS, 4)

	local Bins = Bytes(Counts.Bins * 2)
	local CaseFlags = Fixed(Counts.Cases, CASE_FLAGS, 1)
	local RuleFlags = Fixed(Counts.Rules, RULE_FLAGS, 1)
	local Text = Bytes(Counts.TextBytes)
	local PlainBins = Bytes(Counts.PlainBins * 8)

	return {
		RunNumbers = RunNumbers,
		SizeNumbers = SizeNumbers,
		CaseNumbers = CaseNumbers,
		SpanNumbers = SpanNumbers,
		MetricNumbers = MetricNumbers,

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
		Length = At,
	}
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

local function IsCountable(SampleCount: number): boolean
	return SampleCount >= 1 and SampleCount <= MOST_COUNTED_SAMPLES and SampleCount % 1 == 0
end

local function SumsOf(Cache: SumsCache, SampleCount: number): buffer
	if Cache.SampleCount == SampleCount then
		return Cache.Sums
	end

	local Sums = buffer.create((SampleCount + 1) * 8)
	local Weight = 1 / SampleCount
	local Sum = 0
	for Count = 1, SampleCount do
		Sum += Weight
		buffer.writef64(Sums, Count * 8, Sum)
	end

	Cache.SampleCount = SampleCount
	Cache.Sums = Sums
	return Sums
end

local function ContentsOf(Runs: { RunRecord }): Contents
	local Ids: { [string]: number } = {}
	local Strings: { string } = {}
	local Sizes: { Results.SizeRecord } = {}
	local Cases: { Results.CaseRecord } = {}
	local Spans: { Results.SpanRecord } = {}
	local Metrics: { Results.MetricRecord } = {}
	local Rules: { Results.RuleRecord } = {}
	local Reads = 0
	local Bins = 0
	local TextBytes = 0

	local function Intern(Value: string)
		if Ids[Value] == nil then
			Ids[Value] = #Strings
			table.insert(Strings, Value)
			TextBytes += #Value
		end
	end

	for _, Run in Runs do
		for _, Size in Run.Sizes do
			table.insert(Sizes, Size)
			Intern(Size.Label)
			Intern(Size.Baseline)

			for _, Case in Size.Cases do
				table.insert(Cases, Case)
				Intern(Case.Name)
				Bins += #Case.Histogram.Bins

				for _, Span in Case.Spans do
					table.insert(Spans, Span)
					Intern(Span.Name)
				end
				for _, Metric in Case.Metrics do
					table.insert(Metrics, Metric)
					Intern(Metric.Name)
				end
			end

			for _, Rule in Size.Rules do
				table.insert(Rules, Rule)
				Intern(Rule.Name)
				Intern(Rule.Message)

				Reads += #Rule.Cases
				for _, Name in Rule.Cases do
					Intern(Name)
				end
			end
		end
	end

	local Counts: Counts = {
		Runs = #Runs,
		Sizes = #Sizes,
		Cases = #Cases,
		Spans = #Spans,
		Metrics = #Metrics,
		Rules = #Rules,
		Reads = Reads,
		Strings = #Strings,
		TextBytes = TextBytes,
		Bins = Bins,
		PlainBins = 0,
	}
	return {
		Counts = Counts,
		Ids = Ids,
		Strings = Strings,
		Sizes = Sizes,
		Cases = Cases,
		Spans = Spans,
		Metrics = Metrics,
		Rules = Rules,
	}
end

local function WriteRuns(Writer: Writer, Runs: { RunRecord })
	local Target = Writer.Target
	local Numbers = Writer.Sections.RunNumbers
	local Records = Numbers.Count
	local Low = Numbers.Low
	local High = Numbers.High
	local WordAt = Writer.Sections.RunWords.At

	for _, Run in Runs do
		PutNumber(Target, Low, High, Records, RUN_NUMBER.Id, Run.Id)
		PutNumber(Target, Low, High, Records, RUN_NUMBER.Finished, Run.Finished)
		PutWord(Target, WordAt, Records, RUN_WORD.SizeCount, #Run.Sizes)

		Low += 6
		High += 2
		WordAt += 4
	end
end

local function WriteSizes(Writer: Writer, Sizes: { Results.SizeRecord })
	local Target = Writer.Target
	local Ids = Writer.Ids
	local Numbers = Writer.Sections.SizeNumbers
	local Records = Numbers.Count
	local Low = Numbers.Low
	local High = Numbers.High
	local WordAt = Writer.Sections.SizeWords.At

	for _, Size in Sizes do
		PutNumber(Target, Low, High, Records, SIZE_NUMBER.Size, Size.Size)
		PutNumber(Target, Low, High, Records, SIZE_NUMBER.Noise, Size.Noise)
		PutWord(Target, WordAt, Records, SIZE_WORD.Label, Ids[Size.Label])
		PutWord(Target, WordAt, Records, SIZE_WORD.Baseline, Ids[Size.Baseline])
		PutWord(Target, WordAt, Records, SIZE_WORD.CaseCount, #Size.Cases)
		PutWord(Target, WordAt, Records, SIZE_WORD.RuleCount, #Size.Rules)

		Low += 6
		High += 2
		WordAt += 4
	end
end

local function WriteCounts(Target: buffer, At: number, Histogram: Stats.Histogram, Sums: buffer): boolean
	local SampleCount = Histogram.SampleCount
	for Bin, Share in Histogram.Bins do
		if Share == 0 then
			continue
		end

		local Count = math.floor(Share * SampleCount + 0.5)
		if not (Count >= 0 and Count <= SampleCount) or buffer.readf64(Sums, Count * 8) ~= Share then
			return false
		end
		buffer.writeu16(Target, At + Bin * 2 - 2, Count)
	end
	return true
end

local function WriteCases(Writer: Writer, Cases: { Results.CaseRecord }): { Stats.Histogram }
	local Target = Writer.Target
	local Ids = Writer.Ids
	local Numbers = Writer.Sections.CaseNumbers
	local Records = Numbers.Count
	local Low = Numbers.Low
	local High = Numbers.High
	local WordAt = Writer.Sections.CaseWords.At
	local FlagAt = Writer.Sections.CaseFlags.At
	local BinAt = Writer.Sections.Bins
	local HistogramAt = CURRENT.HistogramAt

	local Plain: { Stats.Histogram } = {}
	local Cache: SumsCache = { SampleCount = nil, Sums = buffer.create(0) }

	for _, Case in Cases do
		local CaseStats = Case.Stats
		local Histogram = Case.Histogram
		local Bins = Histogram.Bins

		PutNumber(Target, Low, High, Records, CASE_NUMBER.Ratio, Case.Ratio)
		PutNumber(Target, Low, High, Records, CASE_NUMBER.Min, CaseStats.Min)
		PutNumber(Target, Low, High, Records, CASE_NUMBER.Median, CaseStats.Median)
		PutNumber(Target, Low, High, Records, CASE_NUMBER.Mean, CaseStats.Mean)
		PutNumber(Target, Low, High, Records, CASE_NUMBER.P90, CaseStats.P90)
		PutNumber(Target, Low, High, Records, CASE_NUMBER.Low, CaseStats.Low)
		PutNumber(Target, Low, High, Records, CASE_NUMBER.High, CaseStats.High)
		PutNumber(Target, Low, High, Records, CASE_NUMBER.Spread, CaseStats.Spread)
		PutNumber(Target, Low, High, Records, HistogramAt + HISTOGRAM_NUMBER.Low, Histogram.Low)
		PutNumber(Target, Low, High, Records, HistogramAt + HISTOGRAM_NUMBER.High, Histogram.High)
		PutNumber(Target, Low, High, Records, HistogramAt + HISTOGRAM_NUMBER.SampleCount, Histogram.SampleCount)

		PutWord(Target, WordAt, Records, CASE_WORD.Name, Ids[Case.Name])
		PutWord(Target, WordAt, Records, CASE_WORD.SpanCount, #Case.Spans)
		PutWord(Target, WordAt, Records, CASE_WORD.MetricCount, #Case.Metrics)
		PutWord(Target, WordAt, Records, CASE_WORD.BinCount, #Bins)

		local StoredAs = BINS_AS_COUNTS
		local SampleCount = Histogram.SampleCount
		if not IsCountable(SampleCount) or not WriteCounts(Target, BinAt, Histogram, SumsOf(Cache, SampleCount)) then
			StoredAs = BINS_AS_NUMBERS
			buffer.fill(Target, BinAt, 0, #Bins * 2)
			table.insert(Plain, Histogram)
		end

		PutFlag(Target, FlagAt, Records, CASE_FLAG.Verdict, VERDICT_CODES[Case.Verdict])
		PutFlag(Target, FlagAt, Records, CASE_FLAG.MatchesBaseline, if Case.MatchesBaseline then 1 else 0)
		PutFlag(Target, FlagAt, Records, CASE_FLAG.BinsStoredAs, StoredAs)

		Low += 6
		High += 2
		WordAt += 4
		FlagAt += 1
		BinAt += #Bins * 2
	end
	return Plain
end

local function WriteSpans(Writer: Writer, Spans: { Results.SpanRecord })
	local Target = Writer.Target
	local Ids = Writer.Ids
	local Numbers = Writer.Sections.SpanNumbers
	local Records = Numbers.Count
	local Low = Numbers.Low
	local High = Numbers.High
	local NameAt = Writer.Sections.SpanWords.At

	for _, Span in Spans do
		PutNumber(Target, Low, High, Records, SPAN_NUMBER.Time, Span.Time)
		PutNumber(Target, Low, High, Records, SPAN_NUMBER.Count, Span.Count)
		PutNumber(Target, Low, High, Records, SPAN_NUMBER.Share, Span.Share)
		PutNumber(Target, Low, High, Records, SPAN_NUMBER.Depth, Span.Depth)
		buffer.writeu32(Target, NameAt, Ids[Span.Name])

		Low += 6
		High += 2
		NameAt += 4
	end
end

local function WriteMetrics(Writer: Writer, Metrics: { Results.MetricRecord })
	local Target = Writer.Target
	local Ids = Writer.Ids
	local Numbers = Writer.Sections.MetricNumbers
	local Records = Numbers.Count
	local Low = Numbers.Low
	local High = Numbers.High
	local NameAt = Writer.Sections.MetricWords.At

	for _, Metric in Metrics do
		PutNumber(Target, Low, High, Records, 0, Metric.Value)
		buffer.writeu32(Target, NameAt, Ids[Metric.Name])

		Low += 6
		High += 2
		NameAt += 4
	end
end

local function WriteRules(Writer: Writer, Rules: { Results.RuleRecord })
	local Target = Writer.Target
	local Ids = Writer.Ids
	local Words = Writer.Sections.RuleWords
	local Records = Words.Count
	local WordAt = Words.At
	local StatusAt = Writer.Sections.RuleFlags.At
	local ReadAt = Writer.Sections.ReadWords.At

	for _, Rule in Rules do
		PutWord(Target, WordAt, Records, RULE_WORD.Name, Ids[Rule.Name])
		PutWord(Target, WordAt, Records, RULE_WORD.Message, Ids[Rule.Message])
		PutWord(Target, WordAt, Records, RULE_WORD.ReadCount, #Rule.Cases)
		buffer.writeu8(Target, StatusAt, STATUS_CODES[Rule.Status])

		for _, Name in Rule.Cases do
			buffer.writeu32(Target, ReadAt, Ids[Name])
			ReadAt += 4
		end

		WordAt += 4
		StatusAt += 1
	end
end

local function WriteStrings(Writer: Writer, Strings: { string })
	local Target = Writer.Target
	local LengthAt = Writer.Sections.StringWords.At
	local TextAt = Writer.Sections.Text

	for _, Value in Strings do
		buffer.writeu32(Target, LengthAt, #Value)
		buffer.writestring(Target, TextAt, Value)
		LengthAt += 4
		TextAt += #Value
	end
end

local function WithPlainBins(Packed: buffer, Sections: Sections, Counts: Counts, Plain: { Stats.Histogram }): buffer
	local Grown = table.clone(Counts)
	for _, Histogram in Plain do
		Grown.PlainBins += #Histogram.Bins
	end

	local Target = buffer.create(Sections.Length + Grown.PlainBins * 8)
	buffer.copy(Target, 0, Packed, 0, Sections.Length)
	WriteHeader(Target, Grown)

	local At = Sections.PlainBins
	for _, Histogram in Plain do
		for _, Share in Histogram.Bins do
			buffer.writef64(Target, At, Share)
			At += 8
		end
	end
	return Target
end

function RunFormat.Encode(Runs: { RunRecord }): buffer
	local Contents = ContentsOf(Runs)
	local Counts = Contents.Counts
	local Sections = SectionsOf(Counts, CURRENT)

	local Target = buffer.create(Sections.Length)
	WriteHeader(Target, Counts)

	local Writer: Writer = { Target = Target, Sections = Sections, Ids = Contents.Ids }
	WriteRuns(Writer, Runs)
	WriteSizes(Writer, Contents.Sizes)
	local Plain = WriteCases(Writer, Contents.Cases)
	WriteSpans(Writer, Contents.Spans)
	WriteMetrics(Writer, Contents.Metrics)
	WriteRules(Writer, Contents.Rules)
	WriteStrings(Writer, Contents.Strings)

	if #Plain > 0 then
		return WithPlainBins(Target, Sections, Counts, Plain)
	end
	return Target
end

local function ReadStrings(Source: buffer, Sections: Sections, Counts: Counts): { string }?
	local LengthAt = Sections.StringWords.At
	local TextAt = Sections.Text
	local TextEnd = TextAt + Counts.TextBytes

	local Strings: { string } = table.create(Counts.Strings, "")
	for Index = 1, Counts.Strings do
		local Length = buffer.readu32(Source, LengthAt)
		if TextAt + Length > TextEnd then
			return nil
		end
		Strings[Index] = buffer.readstring(Source, TextAt, Length)
		LengthAt += 4
		TextAt += Length
	end
	return if TextAt == TextEnd then Strings else nil
end

local function ReadSpans(Reader: Reader): { Results.SpanRecord }?
	local Source = Reader.Source
	local Strings = Reader.Strings
	local HasDepth = Reader.Layout.HasDepth
	local Numbers = Reader.Sections.SpanNumbers
	local Records = Numbers.Count
	local Low = Numbers.Low
	local High = Numbers.High
	local NameAt = Reader.Sections.SpanWords.At

	local Spans = table.create(Records) :: { Results.SpanRecord }
	for Index = 1, Records do
		local Name = Strings[buffer.readu32(Source, NameAt) + 1]
		if not Name then
			return nil
		end

		Spans[Index] = {
			Name = Name,
			Time = GetNumber(Source, Low, High, Records, SPAN_NUMBER.Time),
			Count = GetNumber(Source, Low, High, Records, SPAN_NUMBER.Count),
			Share = GetNumber(Source, Low, High, Records, SPAN_NUMBER.Share),
			Depth = if HasDepth then GetNumber(Source, Low, High, Records, SPAN_NUMBER.Depth) else 1,
		}

		Low += 6
		High += 2
		NameAt += 4
	end
	return Spans
end

local function ReadMetrics(Reader: Reader): { Results.MetricRecord }?
	local Source = Reader.Source
	local Strings = Reader.Strings
	local Numbers = Reader.Sections.MetricNumbers
	local Records = Numbers.Count
	local Low = Numbers.Low
	local High = Numbers.High
	local NameAt = Reader.Sections.MetricWords.At

	local Metrics = table.create(Records) :: { Results.MetricRecord }
	for Index = 1, Records do
		local Name = Strings[buffer.readu32(Source, NameAt) + 1]
		if not Name then
			return nil
		end

		Metrics[Index] = { Name = Name, Value = GetNumber(Source, Low, High, Records, 0) }

		Low += 6
		High += 2
		NameAt += 4
	end
	return Metrics
end

local function ReadRules(Reader: Reader): { Results.RuleRecord }?
	local Source = Reader.Source
	local Strings = Reader.Strings
	local Words = Reader.Sections.RuleWords
	local Records = Words.Count
	local WordAt = Words.At
	local StatusAt = Reader.Sections.RuleFlags.At
	local ReadAt = Reader.Sections.ReadWords.At
	local ReadsLeft = Reader.Counts.Reads

	local Rules = table.create(Records) :: { Results.RuleRecord }
	for Index = 1, Records do
		local Name = Strings[GetWord(Source, WordAt, Records, RULE_WORD.Name) + 1]
		local Message = Strings[GetWord(Source, WordAt, Records, RULE_WORD.Message) + 1]
		local ReadCount = GetWord(Source, WordAt, Records, RULE_WORD.ReadCount)
		local Status = STATUSES[buffer.readu8(Source, StatusAt) + 1]
		if not Name or not Message or not Status or ReadCount > ReadsLeft then
			return nil
		end
		ReadsLeft -= ReadCount

		local CaseNames: { string } = {}
		for Position = 1, ReadCount do
			local CaseName = Strings[buffer.readu32(Source, ReadAt) + 1]
			if not CaseName then
				return nil
			end
			CaseNames[Position] = CaseName
			ReadAt += 4
		end
		Rules[Index] = { Name = Name, Status = Status, Message = Message, Cases = CaseNames }

		WordAt += 4
		StatusAt += 1
	end
	return if ReadsLeft == 0 then Rules else nil
end

local function ReadCounts(
	Source: buffer,
	At: number,
	BinCount: number,
	SampleCount: number,
	Cache: SumsCache
): { number }?
	if not IsCountable(SampleCount) then
		return nil
	end

	local Sums = SumsOf(Cache, SampleCount)
	local Bins = table.create(BinCount, 0)
	local Bin = 1
	while Bin <= BinCount do
		local Offset = At + Bin * 2 - 2
		if Bin + 3 <= BinCount and buffer.readu32(Source, Offset) == 0 and buffer.readu32(Source, Offset + 4) == 0 then
			Bin += 4
			continue
		end

		local Count = buffer.readu16(Source, Offset)
		if Count > SampleCount then
			return nil
		end
		if Count ~= 0 then
			Bins[Bin] = buffer.readf64(Sums, Count * 8)
		end
		Bin += 1
	end
	return Bins
end

local function ReadPlain(Source: buffer, At: number, BinCount: number): { number }
	local Bins = table.create(BinCount, 0)
	for Bin = 1, BinCount do
		Bins[Bin] = buffer.readf64(Source, At + Bin * 8 - 8)
	end
	return Bins
end

local function Slice<Item>(Items: { Item }, Taken: number, Count: number): { Item }
	return table.move(Items, Taken + 1, Taken + Count, 1, table.create(Count))
end

local function ReadCases(
	Reader: Reader,
	Spans: { Results.SpanRecord },
	Metrics: { Results.MetricRecord }
): { Results.CaseRecord }?
	local Source = Reader.Source
	local Strings = Reader.Strings
	local Counts = Reader.Counts
	local Sections = Reader.Sections
	local Numbers = Sections.CaseNumbers
	local Records = Numbers.Count
	local Low = Numbers.Low
	local High = Numbers.High
	local WordAt = Sections.CaseWords.At
	local FlagAt = Sections.CaseFlags.At
	local BinAt = Sections.Bins
	local PlainAt = Sections.PlainBins
	local HistogramAt = Reader.Layout.HistogramAt

	local SpansTaken = 0
	local MetricsTaken = 0
	local BinsTaken = 0
	local PlainTaken = 0
	local Cache: SumsCache = { SampleCount = nil, Sums = buffer.create(0) }

	local Cases = table.create(Records) :: { Results.CaseRecord }
	for Index = 1, Records do
		local Name = Strings[GetWord(Source, WordAt, Records, CASE_WORD.Name) + 1]
		local SpanCount = GetWord(Source, WordAt, Records, CASE_WORD.SpanCount)
		local MetricCount = GetWord(Source, WordAt, Records, CASE_WORD.MetricCount)
		local BinCount = GetWord(Source, WordAt, Records, CASE_WORD.BinCount)
		local Verdict = VERDICTS[GetFlag(Source, FlagAt, Records, CASE_FLAG.Verdict) + 1]
		local Matches = GetFlag(Source, FlagAt, Records, CASE_FLAG.MatchesBaseline)
		if
			not Name
			or not Verdict
			or Matches > 1
			or SpansTaken + SpanCount > Counts.Spans
			or MetricsTaken + MetricCount > Counts.Metrics
			or BinsTaken + BinCount > Counts.Bins
		then
			return nil
		end

		local SampleCount = GetNumber(Source, Low, High, Records, HistogramAt + HISTOGRAM_NUMBER.SampleCount)
		local StoredAs = GetFlag(Source, FlagAt, Records, CASE_FLAG.BinsStoredAs)
		local Bins: { number }? = nil
		if StoredAs == BINS_AS_COUNTS then
			Bins = ReadCounts(Source, BinAt, BinCount, SampleCount, Cache)
		elseif StoredAs == BINS_AS_NUMBERS and PlainTaken + BinCount <= Counts.PlainBins then
			Bins = ReadPlain(Source, PlainAt, BinCount)
			PlainTaken += BinCount
			PlainAt += BinCount * 8
		end
		if not Bins then
			return nil
		end

		Cases[Index] = {
			Name = Name,
			Verdict = Verdict,
			Ratio = GetNumber(Source, Low, High, Records, CASE_NUMBER.Ratio),
			MatchesBaseline = Matches == 1,
			Stats = {
				Min = GetNumber(Source, Low, High, Records, CASE_NUMBER.Min),
				Median = GetNumber(Source, Low, High, Records, CASE_NUMBER.Median),
				Mean = GetNumber(Source, Low, High, Records, CASE_NUMBER.Mean),
				P90 = GetNumber(Source, Low, High, Records, CASE_NUMBER.P90),
				Low = GetNumber(Source, Low, High, Records, CASE_NUMBER.Low),
				High = GetNumber(Source, Low, High, Records, CASE_NUMBER.High),
				Spread = GetNumber(Source, Low, High, Records, CASE_NUMBER.Spread),
				Samples = {},
			},
			Histogram = {
				Low = GetNumber(Source, Low, High, Records, HistogramAt + HISTOGRAM_NUMBER.Low),
				High = GetNumber(Source, Low, High, Records, HistogramAt + HISTOGRAM_NUMBER.High),
				SampleCount = SampleCount,
				Bins = Bins,
			},
			Spans = Slice(Spans, SpansTaken, SpanCount),
			Metrics = Slice(Metrics, MetricsTaken, MetricCount),
		}

		SpansTaken += SpanCount
		MetricsTaken += MetricCount
		BinsTaken += BinCount
		Low += 6
		High += 2
		WordAt += 4
		FlagAt += 1
		BinAt += BinCount * 2
	end

	local IsAllTaken = SpansTaken == Counts.Spans
		and MetricsTaken == Counts.Metrics
		and BinsTaken == Counts.Bins
		and PlainTaken == Counts.PlainBins
	return if IsAllTaken then Cases else nil
end

local function ReadSizes(
	Reader: Reader,
	Cases: { Results.CaseRecord },
	Rules: { Results.RuleRecord }
): { Results.SizeRecord }?
	local Source = Reader.Source
	local Strings = Reader.Strings
	local Numbers = Reader.Sections.SizeNumbers
	local Records = Numbers.Count
	local Low = Numbers.Low
	local High = Numbers.High
	local WordAt = Reader.Sections.SizeWords.At

	local CasesTaken = 0
	local RulesTaken = 0

	local Sizes = table.create(Records) :: { Results.SizeRecord }
	for Index = 1, Records do
		local Label = Strings[GetWord(Source, WordAt, Records, SIZE_WORD.Label) + 1]
		local Baseline = Strings[GetWord(Source, WordAt, Records, SIZE_WORD.Baseline) + 1]
		local CaseCount = GetWord(Source, WordAt, Records, SIZE_WORD.CaseCount)
		local RuleCount = GetWord(Source, WordAt, Records, SIZE_WORD.RuleCount)
		if not Label or not Baseline or CasesTaken + CaseCount > #Cases or RulesTaken + RuleCount > #Rules then
			return nil
		end

		Sizes[Index] = {
			Size = GetNumber(Source, Low, High, Records, SIZE_NUMBER.Size),
			Label = Label,
			Noise = GetNumber(Source, Low, High, Records, SIZE_NUMBER.Noise),
			Baseline = Baseline,
			Cases = Slice(Cases, CasesTaken, CaseCount),
			Rules = Slice(Rules, RulesTaken, RuleCount),
		}

		CasesTaken += CaseCount
		RulesTaken += RuleCount
		Low += 6
		High += 2
		WordAt += 4
	end
	return if CasesTaken == #Cases and RulesTaken == #Rules then Sizes else nil
end

local function ReadRuns(Reader: Reader, Sizes: { Results.SizeRecord }): { RunRecord }?
	local Source = Reader.Source
	local Numbers = Reader.Sections.RunNumbers
	local Records = Numbers.Count
	local Low = Numbers.Low
	local High = Numbers.High
	local WordAt = Reader.Sections.RunWords.At

	local SizesTaken = 0

	local Runs = table.create(Records) :: { RunRecord }
	for Index = 1, Records do
		local SizeCount = GetWord(Source, WordAt, Records, RUN_WORD.SizeCount)
		if SizesTaken + SizeCount > #Sizes then
			return nil
		end

		Runs[Index] = {
			Id = GetNumber(Source, Low, High, Records, RUN_NUMBER.Id),
			Finished = GetNumber(Source, Low, High, Records, RUN_NUMBER.Finished),
			Sizes = Slice(Sizes, SizesTaken, SizeCount),
		}

		SizesTaken += SizeCount
		Low += 6
		High += 2
		WordAt += 4
	end
	return if SizesTaken == #Sizes then Runs else nil
end

function RunFormat.Decode(Encoded: buffer): (Outcome, { RunRecord })
	local Length = buffer.len(Encoded)
	if Length < 4 then
		return "damaged", {}
	end
	local Layout = LAYOUTS[buffer.readu32(Encoded, 0)]
	if not Layout then
		return "unsupported", {}
	end
	if Length < HEADER_BYTES then
		return "damaged", {}
	end

	local Counts = ReadHeader(Encoded)
	local Sections = SectionsOf(Counts, Layout)
	if Sections.Length ~= Length then
		return "damaged", {}
	end

	local Strings = ReadStrings(Encoded, Sections, Counts)
	if not Strings then
		return "damaged", {}
	end

	local Reader: Reader = {
		Source = Encoded,
		Sections = Sections,
		Counts = Counts,
		Layout = Layout,
		Strings = Strings,
	}

	local Spans = ReadSpans(Reader)
	local Metrics = ReadMetrics(Reader)
	local Rules = ReadRules(Reader)
	if not Spans or not Metrics or not Rules then
		return "damaged", {}
	end

	local Cases = ReadCases(Reader, Spans, Metrics)
	if not Cases then
		return "damaged", {}
	end

	local Sizes = ReadSizes(Reader, Cases, Rules)
	if not Sizes then
		return "damaged", {}
	end

	local Runs = ReadRuns(Reader, Sizes)
	if not Runs then
		return "damaged", {}
	end
	return "decoded", Runs
end

return RunFormat
