--!strict
--!optimize 2

--[=[
	Flame: a case's flame graph under its bar, one line per span depth and as wide as the bar, with a legend beside
	it that names the spans too narrow to name inside. Whether a span is named is judged by the bar's final width,
	so names do not flicker while the bar grows

	Return type: the Flame module table
	Example usage:
		Flame.new({ row = row, length = length, barWidth = barWidth, finalWidth = goalBarWidth, opacity = opacity,
			textOpacity = labelOpacity })
--]=]

local Flux = require("../../Packages/Flux")
local CaseRows = require("../CaseRows")
local Components = require("../Components")
local Format = require("../../Util/Format")
local Layout = require("../Layout")
local Motion = require("../Motion")
local Results = require("../../Core/Results")
local Style = require("../Style")
local Tooltip = require("../Tooltip")

local new = Flux.new
local Text = Components.Text

type Row = CaseRows.Row
type Segment = CaseRows.Segment

type FlameProps = {
	row: () -> Row,
	length: () -> number,
	barWidth: () -> number,
	finalWidth: () -> number,
	opacity: () -> number,
	textOpacity: () -> number,
}

local LINE_HEIGHT = 18
local LINE_GAP = 2
local LINE_STEP = LINE_HEIGHT + LINE_GAP
local SEGMENT_LEVEL = 2
local SEGMENT_INSET = 6
local GAP_FROM_WIDTH = 8
local CHARACTER_WIDTH = 6.5
local LEGEND_GAP = 10
local LEGEND_CHIP = 10
local LEGEND_CHIP_GAP = 5

local Flame = {}

function Flame.height(case: Results.CaseRecord): number
	return CaseRows.depth(case) * LINE_STEP
end

local function segmentLabel(shown: Segment, barWidth: number): string
	local width = shown.width * barWidth
	local gap = if width < GAP_FROM_WIDTH then 0 else LINE_GAP
	local room = width - gap - SEGMENT_INSET * 2

	local full = `{shown.name}  {Format.Time(shown.time)}`
	if (utf8.len(full) or #full) * CHARACTER_WIDTH <= room then
		return full
	elseif (utf8.len(shown.name) or #shown.name) * CHARACTER_WIDTH <= room then
		return shown.name
	end
	return ""
end

local function FlameSegment(segment: Flux.Node<Segment>, props: FlameProps): Frame
	local isDark = Style.dark:get()

	local start = Motion.follow(function(): number
		return segment().start
	end, Motion.DATA)

	local share = Motion.follow(function(): number
		return segment().width
	end, Motion.DATA)

	local function gap(): number
		return if share() * props.barWidth() < GAP_FROM_WIDTH then 0 else LINE_GAP
	end

	local frame = new "Frame" {
		Name = "Segment",
		ClipsDescendants = true,
		Position = function()
			return UDim2.new(start(), 0, 0, LINE_GAP + (segment().depth - 1) * LINE_STEP)
		end,
		Size = function()
			return UDim2.new(share(), -gap(), 0, LINE_HEIGHT)
		end,
		BackgroundColor3 = function()
			return Style.spanColor(props.row().colorIndex, segment().position, Flux.read(isDark))
		end,
		BackgroundTransparency = function()
			return 1 - props.opacity()
		end,
		__TAG = { "Ink" },

		Text({
			text = function()
				return segmentLabel(segment(), props.finalWidth())
			end,
			tags = {
				"TextSmall",
				"TextStrong",
				function(): string?
					return Style.spanTextTag(segment().position, Flux.read(isDark))
				end,
			},
			TextTransparency = function()
				return 1 - props.textOpacity()
			end,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, SEGMENT_INSET, 0.5, 0),
		}),
	}

	Tooltip.attach(frame, SEGMENT_LEVEL, function()
		return CaseRows.describeSegment(props.row(), segment:peek())
	end)

	return frame
end

local function LegendEntry(segment: Flux.Node<Segment>, props: FlameProps): Frame
	local isDark = Style.dark:get()

	return new "Frame" {
		Name = "Entry",
		AutomaticSize = Enum.AutomaticSize.XY,

		Flux.list({ direction = "x", gap = LEGEND_CHIP_GAP, align = "center" }),

		new "Frame" {
			Name = "Chip",
			Size = UDim2.fromOffset(LEGEND_CHIP, LEGEND_CHIP),
			BackgroundColor3 = function()
				return Style.spanColor(props.row().colorIndex, segment().position, Flux.read(isDark))
			end,
			BackgroundTransparency = function()
				return 1 - props.textOpacity()
			end,
			__TAG = { "Ink" },
		},

		Text({
			text = function()
				return `{segment().name}  {Format.Time(segment().time)}`
			end,
			tags = { "TextDim", "TextSmall" },
			TextTransparency = function()
				return 1 - props.textOpacity()
			end,
		}),
	}
end

function Flame.new(props: FlameProps): Frame
	local segments = Flux.computed(function(): { Segment }
		return CaseRows.flame(props.row().case)
	end)

	local unnamed = Flux.computed(function(): { Segment }
		local missing: { Segment } = {}
		for _, segment in segments() do
			if segmentLabel(segment, props.finalWidth()) == "" then
				table.insert(missing, segment)
			end
		end
		return missing
	end)

	return new "Frame" {
		Name = "Flame",
		Size = function()
			return UDim2.new(1, 0, 0, Flame.height(props.row().case))
		end,

		new "Frame" {
			Name = "Graph",
			Size = function()
				return UDim2.fromScale(props.length(), 1)
			end,

			Flux.forIndex(segments, function(_index, segment: Flux.Node<Segment>)
				return FlameSegment(segment, props)
			end),
		},

		new "Frame" {
			Name = "Legend",
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, LINE_HEIGHT),
			Position = function()
				return UDim2.new(props.length(), Layout.GapSmall, 0, LINE_GAP)
			end,

			Flux.list({ direction = "x", gap = LEGEND_GAP, align = "center" }),

			Flux.forIndex(unnamed, function(index, segment: Flux.Node<Segment>)
				return Flux.edit(LegendEntry(segment, props)) {
					LayoutOrder = index,
				}
			end),
		},
	}
end

return Flame
