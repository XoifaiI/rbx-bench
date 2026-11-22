--!strict
--- The hover card: follows the pointer and shows what the innermost attached object under it says about itself.
--- `attach` asks the object once when the pointer enters it; `track` asks again every time the pointer moves.
--- The card is kept inside the panel from top to bottom.

local Flux = require("../Packages/Flux")
local Components = require("./Components")
local Layout = require("./Layout")
local Style = require("./Style")

local new = Flux.new
local Text = Components.Text

export type Swatch = {
	series: number,
	position: number,
}

export type Line = {
	label: string,
	value: string,
	swatch: Swatch?,
}

export type Content = {
	title: string,
	lines: { Line },
}

type Hover = {
	object: GuiObject,
	describe: (pointer: Vector2) -> Content?,
	level: number,
}

export type Tooltip = {
	content: Flux.Node<Content?>,
	pointer: Flux.Node<Vector2>,
	hovered: { Hover },
}

local WIDTH = 320
local OFFSET = 18
local PADDING = 14
local SWATCH_SIZE = 12

local Tooltip = {}

function Tooltip.new(): Tooltip
	return {
		content = Flux.signal(nil :: Content?),
		pointer = Flux.signal(Vector2.zero),
		hovered = {},
	}
end

Tooltip.context = Flux.context(Tooltip.new())

local function showTopmost(tooltip: Tooltip)
	local top: Hover? = nil
	for _, hover in tooltip.hovered do
		if not top or hover.level >= top.level then
			top = hover
		end
	end
	tooltip.content:set(if top then top.describe(tooltip.pointer:peek()) else nil)
end

local function forget(tooltip: Tooltip, isGone: (hover: Hover) -> boolean)
	local hovered = tooltip.hovered
	for position = #hovered, 1, -1 do
		if isGone(hovered[position]) then
			table.remove(hovered, position)
		end
	end
end

local function wire(object: GuiObject, level: number, describe: (pointer: Vector2) -> Content?, followsPointer: boolean)
	local tooltip = Tooltip.context:get()

	Flux.edit(object) {
		MouseEnter = function(x: number, y: number)
			forget(tooltip, function(hover: Hover): boolean
				return hover.level == level
			end)
			table.insert(tooltip.hovered, { object = object, describe = describe, level = level })

			tooltip.pointer(Vector2.new(x, y))
			showTopmost(tooltip)
		end,

		MouseMoved = function(x: number, y: number)
			tooltip.pointer(Vector2.new(x, y))
			if followsPointer then
				showTopmost(tooltip)
			end
		end,

		MouseLeave = function()
			forget(tooltip, function(hover: Hover): boolean
				return hover.object == object or hover.object:IsDescendantOf(object)
			end)
			showTopmost(tooltip)
		end,
	}
end

function Tooltip.attach(object: GuiObject, level: number, describe: () -> Content)
	wire(object, level, function(_pointer: Vector2): Content?
		return describe()
	end, false)
end

function Tooltip.track(object: GuiObject, level: number, describeAt: (pointer: Vector2) -> Content?)
	wire(object, level, describeAt, true)
end

function Tooltip.Layer(props: { tooltip: Tooltip, root: GuiObject }): Frame
	local tooltip = props.tooltip
	local isDark = Style.dark:get()
	local bounds = Flux.property(props.root, "AbsoluteSize")

	local function lines(): { Line }
		local content = tooltip.content()
		return if content then content.lines else {}
	end

	local place = Flux.computed(function(): Vector2
		return tooltip.pointer() - props.root.AbsolutePosition
	end)

	local atRight = Flux.computed(function(): boolean
		return place().X + WIDTH + OFFSET > bounds().X
	end)

	local atBottom = Flux.computed(function(): boolean
		return place().Y > bounds().Y / 2
	end)

	local card = new "Frame" {
		Name = "Tooltip",
		ZIndex = 100,
		Interactable = false,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.fromOffset(WIDTH, 0),
		__TAG = { "Card", "Raised" },

		Visible = function()
			return tooltip.content() ~= nil
		end,
		AnchorPoint = function()
			return Vector2.new(if atRight() then 1 else 0, if atBottom() then 1 else 0)
		end,

		Flux.padding(PADDING),
		Flux.list({ gap = Layout.GapSmall }),

		Text({
			text = function()
				local content = tooltip.content()
				return if content then content.title else ""
			end,
			tags = { "TextTitle" },
		}),

		Flux.forIndex(lines, function(_index, line: Flux.Node<Line>)
			return new "Frame" {
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.fromScale(1, 0),

				Flux.list({ direction = "x", gap = Layout.Gap, justify = "between" }),

				new "Frame" {
					Name = "Label",
					AutomaticSize = Enum.AutomaticSize.XY,

					Flux.list({ direction = "x", gap = Layout.GapSmall, align = "center" }),

					new "Frame" {
						Name = "Swatch",
						Size = UDim2.fromOffset(SWATCH_SIZE, SWATCH_SIZE),
						__TAG = { "Ink" },
						Visible = function()
							return line().swatch ~= nil
						end,
						BackgroundColor3 = function()
							local swatch = line().swatch
							return if swatch
								then Style.spanColor(swatch.series, swatch.position, Flux.read(isDark))
								else Color3.new()
						end,
					},

					Text({
						text = function()
							return line().label
						end,
						tags = { "TextDim" },
					}),
				},
				Text({
					text = function()
						return line().value
					end,
					tags = { "TextStrong" },
				}),
			}
		end),
	}

	local cardSize = Flux.property(card, "AbsoluteSize")

	Flux.edit(card) {
		Position = function()
			local at = place()
			local height = cardSize().Y
			local x = at.X + (if atRight() then -OFFSET else OFFSET)
			local y = if atBottom()
				then math.max(at.Y - OFFSET, math.min(height, bounds().Y))
				else math.min(at.Y + OFFSET, math.max(bounds().Y - height, 0))
			return UDim2.fromOffset(x, y)
		end,
	}

	return card
end

return Tooltip
