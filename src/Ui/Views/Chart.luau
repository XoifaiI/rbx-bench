--!strict
--- The chart card: the distribution plot and, under it, one bar per case as long as its median. A bar starts from
--- zero, with the slowest case reaching LONGEST_REACH of the width, so the bars are not on the plot's time axis,
--- which starts at the fastest sample. A case that ran spans has their flame graph under its bar, one line per
--- depth, as wide as the bar; a span too narrow for its name is listed beside the flame graph with a chip of its
--- color. Picking a bar shows that case's curve alone.

local Flux = require("../../Packages/Flux")
local Components = require("../Components")
local Format = require("../../Util/Format")
local Results = require("../../Core/Results")
local Layout = require("../Layout")
local Plot = require("./Plot")
local CaseRows = require("../CaseRows")
local State = require("../State")
local Style = require("../Style")
local Tooltip = require("../Tooltip")

local new = Flux.new
local Text = Components.Text

type Row = CaseRows.Row

type ChartProps = {
	state: State.State,
	rows: Flux.Node<{ Row }>,
	size: Flux.Reactive<UDim2>,
}

type Axis = {
	low: () -> number,
	high: () -> number,
}

type Segment = CaseRows.Segment

type Placement = "inside" | "after"

local TICKS = 6
local TICKS_HEIGHT = 20
local Y_TICKS = 5
local Y_STEP = 0.16
local Y_AXIS_WIDTH = 52
local STACK_GAP = 6
local BAR_HEIGHT = 26
local BAR_GAP = 6
local FLAME_HEIGHT = 18
local FLAME_GAP = 2
local FLAME_STEP = FLAME_HEIGHT + FLAME_GAP
local MEDIANS_TALLEST = 250
local REST_BELOW = 44
local ROW_LEVEL = 1
local SEGMENT_LEVEL = 2
local LABEL_INSIDE_FROM = 0.3
local LABEL_GAP = 10
local LABEL_INSET = 6
local SEGMENT_INSET = 6
local LEGEND_CHIP = 10
local LEGEND_CHIP_GAP = 5
local GAP_FROM_WIDTH = 8
local CHARACTER_WIDTH = 6.5
local SHORTEST_REACH = 0.004
local LONGEST_REACH = 0.8
local NARROWEST_RANGE = 1e-9

local TONE: { [Results.Kind]: Components.Tone } = {
	baseline = "Accent",
	faster = "Good",
	slower = "Bad",
	tie = "Neutral",
}

local function Ticks(axis: Axis): Frame
	local labels = {}
	for tick = 0, TICKS - 1 do
		local fraction = tick / (TICKS - 1)
		table.insert(
			labels,
			Text({
				text = function()
					return Format.Time(axis.low() + (axis.high() - axis.low()) * fraction)
				end,
				tags = { "TextDim", "TextSmall" },
				AnchorPoint = Vector2.new(fraction, 0),
				Position = UDim2.fromScale(fraction, 0),
			})
		)
	end

	return new "Frame" {
		Name = "Ticks",
		Size = UDim2.new(1, 0, 0, TICKS_HEIGHT),
		labels,
	}
end

local function segmentLabel(shown: Segment, barWidth: number): string
	local width = shown.width * barWidth
	local gap = if width < GAP_FROM_WIDTH then 0 else FLAME_GAP
	local room = width - gap - SEGMENT_INSET * 2

	local full = `{shown.name}  {Format.Time(shown.time)}`
	if (utf8.len(full) or #full) * CHARACTER_WIDTH <= room then
		return full
	elseif (utf8.len(shown.name) or #shown.name) * CHARACTER_WIDTH <= room then
		return shown.name
	end
	return ""
end

local function LegendEntry(props: { segment: Flux.Node<Segment>, colorIndex: () -> number }): Frame
	local segment = props.segment
	local isDark = Style.dark:get()

	return new "Frame" {
		Name = "Entry",
		AutomaticSize = Enum.AutomaticSize.XY,

		Flux.list({ direction = "x", gap = LEGEND_CHIP_GAP, align = "center" }),

		new "Frame" {
			Name = "Chip",
			Size = UDim2.fromOffset(LEGEND_CHIP, LEGEND_CHIP),
			BackgroundColor3 = function()
				return Style.spanColor(props.colorIndex(), segment().position, Flux.read(isDark))
			end,
			__TAG = { "Ink" },
		},

		Text({
			text = function()
				return `{segment().name}  {Format.Time(segment().time)}`
			end,
			tags = { "TextDim", "TextSmall" },
		}),
	}
end

local function FlameSegment(props: {
	segment: Flux.Node<Segment>,
	colorIndex: () -> number,
	barWidth: () -> number,
	describe: (segment: Segment) -> Tooltip.Content,
}): Frame
	local segment = props.segment
	local isDark = Style.dark:get()

	local function width(): number
		return segment().width * props.barWidth()
	end

	local function gap(): number
		return if width() < GAP_FROM_WIDTH then 0 else FLAME_GAP
	end

	local function label(): string
		return segmentLabel(segment(), props.barWidth())
	end

	local frame = new "Frame" {
		Name = "Segment",
		ClipsDescendants = true,
		Position = function()
			local shown = segment()
			return UDim2.new(shown.start, 0, 0, (shown.depth - 1) * FLAME_STEP)
		end,
		Size = function()
			return UDim2.new(segment().width, -gap(), 0, FLAME_HEIGHT)
		end,
		BackgroundColor3 = function()
			return Style.spanColor(props.colorIndex(), segment().position, Flux.read(isDark))
		end,
		__TAG = { "Ink" },

		Text({
			text = label,
			tags = {
				"TextSmall",
				"TextStrong",
				function(): string?
					return Style.spanTextTag(segment().position, Flux.read(isDark))
				end,
			},
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, SEGMENT_INSET, 0.5, 0),
		}),
	}

	Tooltip.attach(frame, SEGMENT_LEVEL, function()
		return props.describe(segment:peek())
	end)

	return frame
end

local function MedianBar(props: {
	row: Flux.Node<Row>,
	slowest: Flux.Node<number>,
	onPick: (name: string) -> (),
}): TextButton
	local row = props.row
	local isDark = Style.dark:get()

	local bar = new "TextButton" {
		Name = "MedianBar",
		Text = "",

		Activated = function()
			props.onPick(row:peek().case.Name)
		end,
	}

	local trackSize = Flux.property(bar, "AbsoluteSize")

	local flame = Flux.computed(function(): { Segment }
		return CaseRows.flame(row().case)
	end)

	local function reach(): number
		local share = row().case.Stats.Median / math.max(props.slowest(), NARROWEST_RANGE)
		return math.clamp(share * LONGEST_REACH, SHORTEST_REACH, 1)
	end

	local function barWidth(): number
		return reach() * trackSize().X
	end

	local function colorIndex(): number
		return row().colorIndex
	end

	local function placement(): Placement
		return if reach() >= LABEL_INSIDE_FROM then "inside" else "after"
	end

	local unnamed = Flux.computed(function(): { Segment }
		local missing: { Segment } = {}
		for _, segment in flame() do
			if segmentLabel(segment, barWidth()) == "" then
				table.insert(missing, segment)
			end
		end
		return missing
	end)

	Flux.edit(bar) {
		Size = function()
			return UDim2.new(1, 0, 0, BAR_HEIGHT + CaseRows.depth(row().case) * FLAME_STEP)
		end,

		new "Frame" {
			Name = "Bar",
			Size = function()
				return UDim2.new(reach(), 0, 0, BAR_HEIGHT)
			end,
			BackgroundColor3 = function()
				return Style.spanColor(colorIndex(), 1, Flux.read(isDark))
			end,
			__TAG = { "Ink" },
		},

		new "Frame" {
			Name = "Flame",
			Position = UDim2.fromOffset(0, BAR_HEIGHT + FLAME_GAP),
			Size = function()
				return UDim2.new(reach(), 0, 0, CaseRows.depth(row().case) * FLAME_STEP)
			end,

			Flux.forIndex(flame, function(_index, segment: Flux.Node<Segment>)
				return FlameSegment({
					segment = segment,
					colorIndex = colorIndex,
					barWidth = barWidth,
					describe = function(shown: Segment): Tooltip.Content
						return CaseRows.describeSegment(row:peek(), shown)
					end,
				})
			end),
		},

		new "Frame" {
			Name = "Legend",
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, FLAME_HEIGHT),
			Position = function()
				return UDim2.new(reach(), Layout.GapSmall, 0, BAR_HEIGHT + FLAME_GAP)
			end,

			Flux.list({ direction = "x", gap = LABEL_GAP, align = "center" }),

			Flux.forIndex(unnamed, function(index, segment: Flux.Node<Segment>)
				return Flux.edit(LegendEntry({ segment = segment, colorIndex = colorIndex })) {
					LayoutOrder = index,
				}
			end),
		},

		new "Frame" {
			Name = "Label",
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, BAR_HEIGHT),
			ZIndex = 2,
			Position = function()
				return if placement() == "inside"
					then UDim2.fromOffset(Layout.GapSmall - LABEL_INSET, 0)
					else UDim2.new(reach(), Layout.GapSmall - LABEL_INSET, 0, 0)
			end,

			Flux.padding({ x = LABEL_INSET }),
			Flux.list({ direction = "x", gap = LABEL_GAP, align = "center" }),

			Text({
				text = function()
					local case = row().case
					return `{case.Name}   {Format.Time(case.Stats.Median)}`
				end,
				tags = {
					"TextStrong",
					function(): string?
						return if placement() == "inside" then "TextOnInk" else nil
					end,
				},
			}),

			Components.Badge({
				text = function()
					return Format.Verdict(row().case.Kind, row().case.Ratio)
				end,
				tone = function()
					return TONE[row().case.Kind]
				end,
			}),
		},
	}

	Tooltip.attach(bar, ROW_LEVEL, function()
		return CaseRows.describe(row:peek())
	end)

	return bar
end

local function Chart(props: ChartProps): Frame
	local state = props.state
	local rows = props.rows

	local hasRows = Flux.computed(function(): boolean
		return #rows() > 0
	end)

	local shownRows = Flux.computed(function(): { Row }
		local ranked = rows()
		local picked = state.selectedCase()
		for _, row in ranked do
			if row.case.Name == picked then
				return { row }
			end
		end
		return ranked
	end)

	local slowest = Flux.computed(function(): number
		local most = 0
		for _, row in rows() do
			most = math.max(most, row.case.Stats.Median)
		end
		return most
	end)

	local barsHeight = Flux.computed(function(): number
		local total = REST_BELOW
		for _, row in rows() do
			total += BAR_HEIGHT + CaseRows.depth(row.case) * FLAME_STEP + BAR_GAP
		end
		return total
	end)

	local axis: Axis = {
		low = function(): number
			local first = rows()[1]
			return if first then first.case.Histogram.Low else 0
		end,
		high = function(): number
			local first = rows()[1]
			return if first then first.case.Histogram.High else 0
		end,
	}

	local top = Flux.computed(function(): number
		local peak = 0
		for _, row in rows() do
			for _, share in row.case.Histogram.Bins do
				peak = math.max(peak, share)
			end
		end
		return math.clamp(math.ceil(peak / Y_STEP) * Y_STEP, Y_STEP, 1)
	end)

	local shares = {}
	for step = 0, Y_TICKS - 1 do
		local fraction = step / (Y_TICKS - 1)
		table.insert(
			shares,
			Text({
				text = function()
					return string.format("%d%%", math.round(top() * fraction * fraction * 100))
				end,
				tags = { "TextDim", "TextSmall" },
				AnchorPoint = Vector2.new(1, 1 - fraction),
				Position = UDim2.new(1, -Layout.GapSmall, 1 - fraction, 0),
			})
		)
	end

	return Components.Card({
		Name = "Chart",
		Size = props.size,

		new "Frame" {
			Name = "Stack",
			Size = UDim2.fromScale(1, 1),

			Flux.list({ gap = STACK_GAP }),

			Text({
				text = function()
					return if state.selectedPath()
						then "Press Run to measure this bench."
						else "Create a bench with + to begin."
				end,
				tags = { "TextDim" },
				Visible = function()
					return not hasRows()
				end,
			}),

			new "Frame" {
				Name = "Graph",
				Size = UDim2.fromScale(1, 0),
				Visible = hasRows,

				Flux.flex(),
				Flux.list({ direction = "x" }),

				new "Frame" {
					Name = "Shares",
					Size = UDim2.new(0, Y_AXIS_WIDTH, 1, 0),
					shares,
				},

				Plot({ rows = shownRows, top = top }),
			},

			new "Frame" {
				Name = "Times",
				Size = UDim2.new(1, 0, 0, TICKS_HEIGHT),
				Visible = hasRows,

				Flux.padding({ left = Y_AXIS_WIDTH }),
				Ticks(axis),
			},

			Components.Scroller({
				Name = "Medians",
				Size = function()
					return UDim2.new(1, 0, 0, math.min(barsHeight(), MEDIANS_TALLEST))
				end,

				Flux.padding({ left = Y_AXIS_WIDTH, bottom = REST_BELOW }),
				Flux.list({ gap = BAR_GAP }),

				Flux.forKey(rows, function(row: Row)
					return row.case.Name
				end, function(index, row: Flux.Node<Row>)
					return Flux.edit(MedianBar({ row = row, slowest = slowest, onPick = state.showCase })) {
						LayoutOrder = index,
					}
				end),
			}),
		},
	})
end

return Chart
