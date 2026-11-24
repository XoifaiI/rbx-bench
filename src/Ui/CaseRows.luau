--!strict
--!optimize 2

--[=[
	CaseRows: the cases of the size on show, fastest first, the flame graph of a case's spans, and what the hover card
	says about a case, one span or one time bin. A span starts where the span before it at its depth ended, and its
	first child starts where it does, so the order is the order they first ran and the gaps are time outside any span

	Return type: the CaseRows module table
	Example usage:
		local rows = CaseRows.ranked(state)
--]=]

local Flux = require("../Packages/Flux")
local Format = require("../Util/Format")
local Results = require("../Core/Results")
local State = require("./State")
local Tooltip = require("./Tooltip")

export type Row = {
	case: Results.CaseRecord,
	colorIndex: number,
}

export type Segment = {
	name: string,
	time: number,
	count: number,
	share: number,
	start: number,
	width: number,
	depth: number,
	position: number,
}

local BIN_LINES = 8
local LEGEND_INDENT = "      "

local CaseRows = {}

function CaseRows.ranked(state: State.State): Flux.Node<{ Row }>
	return Flux.computed(function(): { Row }
		local record = state.sizeRecord()
		if not record then
			return {}
		end

		local built: { Row } = {}
		for position, case in record.Cases do
			built[position] = { case = case, colorIndex = position }
		end
		table.sort(built, function(first: Row, second: Row): boolean
			return first.case.Stats.Median < second.case.Stats.Median
		end)
		return built
	end)
end

function CaseRows.depth(case: Results.CaseRecord): number
	local deepest = 0
	for _, span in case.Spans do
		deepest = math.max(deepest, span.Depth)
	end
	return deepest
end

function CaseRows.flame(case: Results.CaseRecord): { Segment }
	local segments: { Segment } = {}
	local nextStart: { number } = {}
	for _, span in case.Spans do
		local start = nextStart[span.Depth] or 0
		local width = math.clamp(span.Share, 0, 1 - start)
		nextStart[span.Depth] = start + width
		nextStart[span.Depth + 1] = start

		local segment: Segment = {
			name = span.Name,
			time = span.Time,
			count = span.Count,
			share = span.Share,
			start = start,
			width = width,
			depth = span.Depth,
			position = 1,
		}
		table.insert(segments, segment)
	end

	for _, segment in segments do
		for _, other in segments do
			if other.share > segment.share then
				segment.position += 1
			end
		end
	end
	return segments
end

function CaseRows.describe(row: Row): Tooltip.Content
	local case = row.case
	local stats = case.Stats
	local lines: { Tooltip.Line } = {
		{ label = "Median per call", value = Format.Time(stats.Median) },
		{ label = "Against baseline", value = Format.Verdict(case.Verdict, case.Ratio) },
		{ label = "Fastest", value = Format.Time(stats.Min) },
		{ label = "90th percentile", value = Format.Time(stats.P90) },
		{ label = "Spread", value = Format.Percent(stats.Spread) },
	}
	for _, segment in CaseRows.flame(case) do
		local line: Tooltip.Line = {
			label = string.rep(LEGEND_INDENT, segment.depth - 1) .. segment.name,
			value = `{Format.Percent(segment.share)}   {Format.Time(segment.time)}`,
			swatch = { series = row.colorIndex, position = segment.position },
		}
		table.insert(lines, line)
	end
	for _, metric in case.Metrics do
		table.insert(lines, { label = metric.Name, value = string.format("%.4g", metric.Value) })
	end
	if not case.MatchesBaseline then
		table.insert(lines, { label = "Output", value = "differs from the baseline" })
	end
	return { title = case.Name, lines = lines }
end

function CaseRows.describeSegment(row: Row, segment: Segment): Tooltip.Content
	local case = row.case
	return {
		title = segment.name,
		lines = {
			{
				label = case.Name,
				value = Format.Time(case.Stats.Median),
				swatch = { series = row.colorIndex, position = segment.position },
			},
			{ label = "Time per call", value = Format.Time(segment.time) },
			{ label = "Share of the case", value = Format.Percent(segment.share) },
			{ label = "Runs per call", value = string.format("%.4g", segment.count) },
		},
	}
end

function CaseRows.describeBin(rows: { Row }, bin: number): Tooltip.Content?
	local first = rows[1]
	if not first then
		return nil
	end

	local histogram = first.case.Histogram
	local width = (histogram.High - histogram.Low) / #histogram.Bins
	local low = histogram.Low + (bin - 1) * width

	local lines: { Tooltip.Line } = {}
	for position, row in rows do
		if position > BIN_LINES then
			table.insert(lines, { label = `and {#rows - BIN_LINES} more`, value = "" })
			break
		end

		local share = row.case.Histogram.Bins[bin]
		local line: Tooltip.Line = {
			label = row.case.Name,
			value = `{Format.Percent(share)}   {math.round(share * row.case.Histogram.SampleCount)} samples`,
			swatch = { series = row.colorIndex, position = 1 },
		}
		table.insert(lines, line)
	end
	return { title = `{Format.Time(low)} to {Format.Time(low + width)}`, lines = lines }
end

return CaseRows
