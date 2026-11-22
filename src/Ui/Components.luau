--!strict
--- The panel's building blocks. They set size and layout and name themselves to the style sheet with tags.

local Flux = require("../Packages/Flux")
local Layout = require("./Layout")

local new = Flux.new

export type Tone = "Accent" | "Good" | "Bad" | "Neutral"

local BADGE_HEIGHT = 24
local BADGE_INSET = 8

local TEXT_OWN = {
	text = Flux.prop() :: Flux.Reactive<string>,
	tags = Flux.prop() :: { Flux.Reactive<string?> }?,
}

type TextProps = Flux.Props<"TextLabel", typeof(TEXT_OWN)>

local function Text(props: TextProps): TextLabel
	local own, rest = Flux.split(props, TEXT_OWN)

	local tags: { Flux.Reactive<string?> } = { "Text" }
	if own.tags then
		table.move(own.tags, 1, #own.tags, 2, tags)
	end

	return Flux.edit(new "TextLabel" {
		AutomaticSize = Enum.AutomaticSize.XY,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = own.text,
		__TAG = tags,
	})(rest)
end

local BUTTON_OWN = {
	text = Flux.prop() :: Flux.Reactive<string>,
	accent = Flux.prop() :: boolean?,
	glyph = Flux.prop() :: boolean?,
	selected = Flux.prop() :: (() -> boolean)?,
	enabled = Flux.prop() :: Flux.Reactive<boolean>?,
	onClick = Flux.prop() :: (() -> ())?,
}

type ButtonProps = Flux.Props<"TextButton", typeof(BUTTON_OWN)>

local function Button(props: ButtonProps): TextButton
	local own, rest = Flux.split(props, BUTTON_OWN)
	local enabled = Flux.fallback(own.enabled, true)

	return Flux.edit(new "TextButton" {
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(Layout.ControlHeight, Layout.ControlHeight),
		Text = own.text,

		__TAG = {
			"Button",
			function(): string?
				return if own.accent then "Accent" else nil
			end,
			function(): string?
				return if own.glyph then "Glyph" else nil
			end,
			function(): string?
				return if own.selected and own.selected() then "Selected" else nil
			end,
			function(): string?
				return if enabled() then nil else "Disabled"
			end,
		},

		Activated = function()
			if enabled() and own.onClick then
				own.onClick()
			end
		end,

		Flux.padding({ x = Layout.ControlInset }),
	})(rest)
end

local function Badge(props: { text: Flux.Reactive<string>, tone: () -> Tone }): TextLabel
	return new "TextLabel" {
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, BADGE_HEIGHT),
		Text = props.text,

		__TAG = {
			"Badge",
			function(): string?
				return `Badge{props.tone()}`
			end,
		},

		Flux.padding({ x = BADGE_INSET }),
	}
end

local function Card(props: Flux.Props<"Frame">): Frame
	return Flux.edit(new "Frame" {
		__TAG = { "Card" },
		Flux.padding(Layout.Inset),
	})(props)
end

local function Scroller(props: Flux.Props<"ScrollingFrame">): ScrollingFrame
	return Flux.edit(new "ScrollingFrame" {
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
	})(props)
end

return {
	Text = Text,
	Button = Button,
	Badge = Badge,
	Card = Card,
	Scroller = Scroller,
}
