--!strict
--!optimize 2

--[=[
	MedianBar: one case's bar in the chart, as long as its median against the slowest case, with its flame graph
	under it and its label. The label sits inside or after the bar, judged by the bar's final length, changes only
	through LABEL_NEXT and shows only while the bar sits in its row, hiding at once when it starts to move, so
	labels never jump or pile up as bars swap rows. A bar grows in and leaves by fading where it was, under the rest

	Return type: the MedianBar module table
	Example usage:
		MedianBar.new({ listing = item, isDimmed = isDimmed, onPick = state.showCase, onGone = forget })
--]=]

local Flux = require("../../Packages/Flux")
local CaseRows = require("../CaseRows")
local Components = require("../Components")
local Flame = require("./Flame")
local Format = require("../../Util/Format")
local Layout = require("../Layout")
local Motion = require("../Motion")
local Results = require("../../Core/Results")
local Style = require("../Style")
local Tooltip = require("../Tooltip")

local new = Flux.new
local Text = Components.Text

type Row = CaseRows.Row

export type Listing = {
	key: string,
	path: string?,
	row: Row,
	top: number,
	slowest: number,
	isLeaving: boolean,
	delay: number,
}

type Placement = "inside" | "after"

type LabelState = "hidden" | "shown" | "hiding"

type LabelLayout = {
	caption: string,
	verdict: string,
	tone: Components.Tone,
	placement: Placement,
	showsBadge: boolean,
}

local BAR_HEIGHT = 26
local BAR_GAP = 6
local ROW_LEVEL = 1
local LABEL_GAP = 10
local LABEL_INSET = 6
local BADGE_CHARACTER_WIDTH = 7
local BADGE_INSETS = 18
local SHORTEST_REACH = 0.004
local LONGEST_REACH = 0.8
local NARROWEST_RANGE = 1e-9
local DIMMED_OPACITY = 0.35
local GONE_BELOW = 0.002
local LEAVING_LAYER = 1
local STAYING_LAYER = 2
local HIDDEN_BELOW = 0.02
local IN_ROW_WITHIN = 4

local LABEL_NEXT: { [LabelState]: { LabelState } } = {
	hidden = { "shown" },
	shown = { "hiding" },
	hiding = { "hidden" },
}

local TONE: { [Results.Verdict]: Components.Tone } = {
	baseline = "Accent",
	faster = "Good",
	slower = "Bad",
	tie = "Neutral",
}

local MedianBar = {}

local function heightOf(case: Results.CaseRecord): number
	return BAR_HEIGHT + Flame.height(case)
end

function MedianBar.slotHeight(case: Results.CaseRecord): number
	return heightOf(case) + BAR_GAP
end

local function placeLabel(bare: number, full: number, inside: number, after: number): (Placement, boolean)
	if full <= inside then
		return "inside", true
	end
	if full <= after then
		return "after", true
	end
	if bare <= inside then
		return "inside", false
	end
	if bare <= after then
		return "after", false
	end

	local roomier: Placement = if inside >= after then "inside" else "after"
	return roomier, false
end

local function isSameLayout(first: LabelLayout, second: LabelLayout): boolean
	return first.caption == second.caption
		and first.verdict == second.verdict
		and first.tone == second.tone
		and first.placement == second.placement
		and first.showsBadge == second.showsBadge
end

function MedianBar.new(props: {
	listing: Flux.Node<Listing>,
	isDimmed: () -> boolean,
	onPick: (name: string) -> (),
	onGone: (key: string) -> (),
}): TextButton
	local listing = props.listing
	local isDark = Style.dark:get()

	local function row(): Row
		return listing().row
	end

	local function goalReach(): number
		local item = listing()
		local share = item.row.case.Stats.Median / math.max(item.slowest, NARROWEST_RANGE)
		return math.clamp(share * LONGEST_REACH, SHORTEST_REACH, 1)
	end

	local growth = Motion.enter(function(): number
		return 1
	end, Motion.DATA, listing:peek().delay)

	local presence = Motion.follow(function(): number
		return if listing().isLeaving then 0 else 1
	end, Motion.FADE)

	local reach = Motion.follow(goalReach, Motion.DATA)

	local shownTop = Motion.follow(function(): number
		return listing().top
	end, Motion.CHROME)

	local function isInRow(): boolean
		return math.abs(shownTop() - listing().top) <= IN_ROW_WITHIN
	end

	local dim = Motion.follow(function(): number
		return if props.isDimmed() then DIMMED_OPACITY else 1
	end, Motion.CHROME)

	local function opacity(): number
		return growth() * presence() * dim()
	end

	local function length(): number
		return reach() * growth()
	end

	local isGone = false
	Flux.effect(function()
		if not listing().isLeaving then
			isGone = false
			return
		end
		if not isGone and presence() <= GONE_BELOW then
			isGone = true
			task.defer(props.onGone, listing:peek().key)
		end
	end)

	local bar = new "TextButton" {
		Name = "MedianBar",
		Text = "",
		Position = function()
			return UDim2.fromOffset(0, shownTop())
		end,
		ZIndex = function()
			return if listing().isLeaving then LEAVING_LAYER else STAYING_LAYER
		end,

		Activated = function()
			if not listing:peek().isLeaving then
				props.onPick(row().case.Name)
			end
		end,
	}

	local trackSize = Flux.property(bar, "AbsoluteSize")

	local function barWidth(): number
		return length() * trackSize().X
	end

	local function goalBarWidth(): number
		return goalReach() * trackSize().X
	end

	local function colorIndex(): number
		return row().colorIndex
	end

	local function captionText(): string
		return `{row().case.Name}   {Format.Time(row().case.Stats.Median)}`
	end

	local measure = Text({
		text = captionText,
		tags = { "TextStrong" },
		TextTransparency = 1,
	})
	local captionBounds = Flux.property(measure, "TextBounds")

	local function layoutNow(): LabelLayout
		local case = row().case
		local verdict = Format.Verdict(case.Verdict, case.Ratio)
		local bare = LABEL_INSET * 2 + captionBounds().X + Layout.GapSmall
		local full = bare + LABEL_GAP + (utf8.len(verdict) or #verdict) * BADGE_CHARACTER_WIDTH + BADGE_INSETS
		local inside = goalBarWidth()
		local placement, showsBadge = placeLabel(bare, full, inside, trackSize().X - inside)

		return {
			caption = captionText(),
			verdict = verdict,
			tone = TONE[case.Verdict],
			placement = placement,
			showsBadge = showsBadge,
		}
	end

	local labelState = Flux.signal("hidden" :: LabelState)
	local shownLayout = Flux.signal(layoutNow())

	local function moveLabel(to: LabelState)
		local from = labelState:peek()
		if not table.find(LABEL_NEXT[from], to) then
			error(`rbx-bench cannot move a bar label from {from} to {to}; LABEL_NEXT does not allow it`)
		end
		labelState(to)
	end

	local labelShown = Motion.follow(function(): number
		return if labelState() == "shown" then 1 else 0
	end, Motion.FADE)

	local function labelOpacity(): number
		return dim() * labelShown()
	end

	Flux.effect(function()
		local state = labelState()
		if state == "hidden" then
			if not listing().isLeaving and isInRow() then
				shownLayout(layoutNow())
				moveLabel("shown")
			end
		elseif state == "shown" then
			if not isInRow() then
				moveLabel("hiding")
				labelShown:snap(0)
			elseif listing().isLeaving or not isSameLayout(layoutNow(), shownLayout:peek()) then
				moveLabel("hiding")
			end
		elseif labelShown() <= HIDDEN_BELOW then
			moveLabel("hidden")
		end
	end)

	local function isInside(): boolean
		return shownLayout().placement == "inside"
	end

	Flux.edit(bar) {
		Size = function()
			return UDim2.new(1, 0, 0, heightOf(row().case))
		end,

		measure,

		new "Frame" {
			Name = "Bar",
			Size = function()
				return UDim2.new(length(), 0, 0, BAR_HEIGHT)
			end,
			BackgroundColor3 = function()
				return Style.spanColor(colorIndex(), 1, Flux.read(isDark))
			end,
			BackgroundTransparency = function()
				return 1 - opacity()
			end,
			__TAG = { "Ink" },
		},

		Flux.edit(Flame.new({
			row = row,
			length = length,
			barWidth = barWidth,
			finalWidth = goalBarWidth,
			opacity = opacity,
			textOpacity = labelOpacity,
		})) {
			Position = UDim2.fromOffset(0, BAR_HEIGHT),
		},

		new "Frame" {
			Name = "LabelClip",
			ClipsDescendants = true,
			ZIndex = 2,
			Size = function()
				return UDim2.fromOffset(if isInside() then barWidth() else trackSize().X, BAR_HEIGHT)
			end,

			new "Frame" {
				Name = "Label",
				AutomaticSize = Enum.AutomaticSize.X,
				Size = UDim2.fromOffset(0, BAR_HEIGHT),
				Position = function()
					local x = if isInside() then 0 else barWidth()
					return UDim2.fromOffset(x + Layout.GapSmall - LABEL_INSET, 0)
				end,

				Flux.padding({ x = LABEL_INSET }),
				Flux.list({ direction = "x", gap = LABEL_GAP, align = "center" }),

				Text({
					text = function()
						return shownLayout().caption
					end,
					tags = {
						"TextStrong",
						function(): string?
							return if isInside() then "TextOnInk" else nil
						end,
					},
					TextTransparency = function()
						return 1 - labelOpacity()
					end,
				}),

				Flux.edit(Components.Badge({
					text = function()
						return shownLayout().verdict
					end,
					tone = function()
						return shownLayout().tone
					end,
				})) {
					Visible = function()
						return shownLayout().showsBadge
					end,
					BackgroundTransparency = function()
						return 1 - labelOpacity()
					end,
					TextTransparency = function()
						return 1 - labelOpacity()
					end,
				},
			},
		},
	}

	Tooltip.attach(bar, ROW_LEVEL, function()
		return CaseRows.describe(listing:peek().row)
	end)

	return bar
end

return MedianBar
