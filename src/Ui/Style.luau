--!strict
--!optimize 2

--[=[
	Style: everything the panel looks like, as one Roblox StyleSheet: color tokens, and rules that apply them by tag.
	Views set no color except a case's own, which they ask for here. `claim` must run before anything is created

	Return type: the Style module table
	Example usage:
		Style.claim()
		Style.mount(widget, isDark)
--]=]

local Flux = require("../Packages/Flux")
local CreateInstance = require("../Studio/CreateInstance")

local Oklab = Flux.Color.Oklab

type Token = {
	chroma: number,
	hue: number?,
	dark: number,
	light: number,
}

type Rule = {
	selector: string,
	priority: number,
	properties: { [string]: any },
}

local ROBOTO = "rbxasset://fonts/families/Roboto.json"
local REGULAR = Font.new(ROBOTO, Enum.FontWeight.Regular)
local MEDIUM = Font.new(ROBOTO, Enum.FontWeight.Medium)

local ACCENT_HUE = 255
local GOOD_HUE = 148
local BAD_HUE = 27
local VIVID = 0.22
local TINTED = 0.14
local NEUTRAL = 0.008
local MUTED = 0.018

local SERIES_HUES = { 255, 30, 165, 300, 75, 210, 345, 120 }
local SERIES_CHROMA = 0.26
local SERIES_TONE_DARK = 74
local SERIES_TONE_LIGHT = 46

local SPAN_TONES = { 0, 24, 12, 36, 6, 30, 18, 42 }
local REST_POSITION = 0
local REST_CHROMA = 0.05
local REST_TONE_DARK = 30
local REST_TONE_LIGHT = 84
local PALE_FROM_TONE = 58

local FLUX_PAINTED = { "BackgroundColor3", "BorderColor3", "TextColor3", "Font", "ScrollBarImageColor3" }

local TOKENS: { [string]: Token } = {
	Surface = { chroma = NEUTRAL, dark = 6, light = 98 },
	Card = { chroma = NEUTRAL, dark = 10, light = 96 },
	CardHover = { chroma = NEUTRAL, dark = 14, light = 93 },
	Raised = { chroma = NEUTRAL, dark = 22, light = 90 },
	Control = { chroma = NEUTRAL, dark = 17, light = 92 },
	ControlHover = { chroma = NEUTRAL, dark = 22, light = 88 },
	ControlPress = { chroma = NEUTRAL, dark = 26, light = 85 },
	Accent = { chroma = VIVID, dark = 62, light = 40 },
	AccentHover = { chroma = VIVID, dark = 67, light = 45 },
	AccentPress = { chroma = VIVID, dark = 56, light = 36 },
	OnAccent = { chroma = NEUTRAL, dark = 100, light = 100 },
	Selected = { chroma = TINTED, dark = 38, light = 90 },
	SelectedHover = { chroma = TINTED, dark = 43, light = 86 },
	OnSelected = { chroma = TINTED, dark = 94, light = 10 },
	Text = { chroma = NEUTRAL, dark = 90, light = 10 },
	TextDim = { chroma = MUTED, dark = 78, light = 35 },
	OnInk = { chroma = NEUTRAL, dark = 8, light = 100 },
	Line = { chroma = NEUTRAL, dark = 22, light = 88 },
	InkDeep = { chroma = NEUTRAL, dark = 8, light = 8 },
	InkPale = { chroma = NEUTRAL, dark = 100, light = 100 },
	Good = { chroma = VIVID, hue = GOOD_HUE, dark = 30, light = 90 },
	OnGood = { chroma = VIVID, hue = GOOD_HUE, dark = 90, light = 10 },
	Bad = { chroma = VIVID, hue = BAD_HUE, dark = 30, light = 90 },
	OnBad = { chroma = VIVID, hue = BAD_HUE, dark = 90, light = 10 },
	Slower = { chroma = SERIES_CHROMA, hue = BAD_HUE, dark = 58, light = 50 },
	OnSlower = { chroma = NEUTRAL, dark = 100, light = 100 },
	Faster = { chroma = SERIES_CHROMA, hue = GOOD_HUE, dark = 70, light = 44 },
	OnFaster = { chroma = NEUTRAL, dark = 8, light = 100 },
}

local RULES: { Rule } = {
	{
		selector = "Frame, TextLabel, TextButton, TextBox, ScrollingFrame, ImageLabel",
		priority = 0,
		properties = { BackgroundTransparency = 1 },
	},
	{
		selector = "ScrollingFrame",
		priority = 0,
		properties = { ScrollBarThickness = 0 },
	},

	{ selector = ".Panel", priority = 1, properties = { BackgroundTransparency = 0, BackgroundColor3 = "$Surface" } },
	{ selector = ".Card", priority = 1, properties = { BackgroundTransparency = 0, BackgroundColor3 = "$Card" } },
	{ selector = ".Card::UICorner", priority = 1, properties = { CornerRadius = UDim.new(0, 12) } },
	{ selector = ".Raised", priority = 2, properties = { BackgroundColor3 = "$Raised" } },

	{ selector = ".Text", priority = 1, properties = { TextColor3 = "$Text", FontFace = REGULAR, TextSize = 16 } },
	{ selector = ".TextDim", priority = 2, properties = { TextColor3 = "$TextDim" } },
	{ selector = ".TextOnInk", priority = 2, properties = { TextColor3 = "$OnInk" } },
	{ selector = ".TextSmall", priority = 2, properties = { TextSize = 14 } },
	{ selector = ".TextStrong", priority = 2, properties = { FontFace = MEDIUM } },
	{ selector = ".TextTitle", priority = 2, properties = { FontFace = MEDIUM, TextSize = 18 } },

	{
		selector = ".Button, .Field",
		priority = 1,
		properties = {
			BackgroundTransparency = 0,
			BackgroundColor3 = "$Control",
			TextColor3 = "$Text",
			FontFace = MEDIUM,
			TextSize = 16,
		},
	},
	{ selector = ".Button::UICorner, .Field::UICorner", priority = 1, properties = { CornerRadius = UDim.new(0, 10) } },
	{ selector = ".Glyph", priority = 2, properties = { TextSize = 28 } },
	{ selector = ".Button:Hover", priority = 2, properties = { BackgroundColor3 = "$ControlHover" } },
	{ selector = ".Button:Press", priority = 3, properties = { BackgroundColor3 = "$ControlPress" } },
	{ selector = ".Field", priority = 2, properties = { FontFace = REGULAR, PlaceholderColor3 = "$TextDim" } },

	{ selector = ".Accent", priority = 4, properties = { BackgroundColor3 = "$Accent", TextColor3 = "$OnAccent" } },
	{ selector = ".Accent:Hover", priority = 5, properties = { BackgroundColor3 = "$AccentHover" } },
	{ selector = ".Accent:Press", priority = 6, properties = { BackgroundColor3 = "$AccentPress" } },

	{
		selector = ".Selected",
		priority = 4,
		properties = { BackgroundColor3 = "$Selected", TextColor3 = "$OnSelected" },
	},
	{ selector = ".Selected:Hover", priority = 5, properties = { BackgroundColor3 = "$SelectedHover" } },

	{ selector = ".Row", priority = 1, properties = { BackgroundTransparency = 0, BackgroundColor3 = "$Card" } },
	{ selector = ".Row:Hover", priority = 2, properties = { BackgroundColor3 = "$CardHover" } },
	{ selector = ".Row::UICorner", priority = 1, properties = { CornerRadius = UDim.new(0, 10) } },

	{ selector = ".Disabled", priority = 7, properties = { BackgroundTransparency = 0.6, TextTransparency = 0.6 } },

	{
		selector = ".Badge",
		priority = 3,
		properties = { BackgroundTransparency = 0, FontFace = MEDIUM, TextSize = 14 },
	},
	{ selector = ".Badge::UICorner", priority = 1, properties = { CornerRadius = UDim.new(0, 8) } },
	{
		selector = ".BadgeAccent",
		priority = 4,
		properties = { BackgroundColor3 = "$Accent", TextColor3 = "$OnAccent" },
	},
	{ selector = ".BadgeGood", priority = 4, properties = { BackgroundColor3 = "$Faster", TextColor3 = "$OnFaster" } },
	{ selector = ".BadgeBad", priority = 4, properties = { BackgroundColor3 = "$Slower", TextColor3 = "$OnSlower" } },
	{
		selector = ".BadgeNeutral",
		priority = 4,
		properties = { BackgroundColor3 = "$Raised", TextColor3 = "$TextDim" },
	},

	{ selector = ".Message", priority = 2, properties = { BackgroundTransparency = 0, BackgroundColor3 = "$Bad" } },
	{ selector = ".TextOnBad", priority = 3, properties = { TextColor3 = "$OnBad" } },

	{ selector = ".Progress", priority = 1, properties = { BackgroundTransparency = 0, BackgroundColor3 = "$Accent" } },
	{ selector = ".Ink", priority = 1, properties = { BackgroundTransparency = 0 } },
	{ selector = ".Wash", priority = 1, properties = { BackgroundTransparency = 0.85 } },
	{ selector = ".Marker", priority = 1, properties = { BackgroundTransparency = 0.35 } },
	{ selector = ".Ink::UICorner", priority = 1, properties = { CornerRadius = UDim.new(0, 4) } },

	{ selector = ".TextOnPale", priority = 2, properties = { TextColor3 = "$InkDeep" } },
	{ selector = ".TextOnDeep", priority = 2, properties = { TextColor3 = "$InkPale" } },
	{
		selector = ".Scrim",
		priority = 1,
		properties = { BackgroundTransparency = 0.35, BackgroundColor3 = "$Surface" },
	},
}

local Style = {}

Style.dark = Flux.context(true :: Flux.Reactive<boolean>)

local function lightnessOf(tone: number): number
	local luminance = if tone > 8 then ((tone + 16) / 116) ^ 3 else tone / 903.3
	return luminance ^ (1 / 3)
end

local function colorAt(hue: number, chroma: number, tone: number): Color3
	local angle = math.rad(hue)
	return Oklab.toRGB(Vector3.new(lightnessOf(tone), chroma * math.cos(angle), chroma * math.sin(angle)))
end

local function tokenColor(token: Token, isDark: boolean): Color3
	local tone = if isDark then token.dark else token.light
	local fadeToWhite = 0.9 * (1 - lightnessOf(tone)) + 0.05
	return colorAt(token.hue or ACCENT_HUE, math.min(token.chroma, fadeToWhite), tone)
end

local function seriesColor(index: number, isDark: boolean): Color3
	local hue = SERIES_HUES[(index - 1) % #SERIES_HUES + 1]
	return colorAt(hue, SERIES_CHROMA, if isDark then SERIES_TONE_DARK else SERIES_TONE_LIGHT)
end

local function spanTone(position: number, isDark: boolean): number
	if position == REST_POSITION then
		return if isDark then REST_TONE_DARK else REST_TONE_LIGHT
	end

	local step = SPAN_TONES[(position - 1) % #SPAN_TONES + 1]
	return if isDark then SERIES_TONE_DARK - step else SERIES_TONE_LIGHT + step
end

function Style.claim()
	for _, defaults in Flux.Defaults :: { [string]: { [string]: any } } do
		for _, property in FLUX_PAINTED do
			defaults[property] = nil
		end
	end
end

function Style.mount(layer: Instance, isDark: Flux.Reactive<boolean>)
	local sheet = CreateInstance.Create("StyleSheet", { Name = "BenchStyle" })

	for _, rule in RULES do
		CreateInstance.Create("StyleRule", {
			Selector = rule.selector,
			Priority = rule.priority,
			Parent = sheet,
		}):SetProperties(rule.properties)
	end

	local function paint(dark: boolean)
		for name, token in TOKENS do
			sheet:SetAttribute(name, tokenColor(token, dark))
		end
	end

	paint(Flux.raw(isDark))
	Flux.effect(function()
		paint(Flux.read(isDark))
	end)

	sheet.Parent = layer
	local link = CreateInstance.Create("StyleLink", { StyleSheet = sheet, Parent = layer })

	Flux.cleanup({ sheet, link })
end

function Style.tokenAt(name: string, isDark: boolean): Color3
	return tokenColor(TOKENS[name], isDark)
end

function Style.seriesAt(index: number, isDark: boolean): Color3
	return seriesColor(index, isDark)
end

function Style.spanColor(index: number, position: number, isDark: boolean): Color3
	local tone = spanTone(position, isDark)
	local lightness = lightnessOf(tone)
	local chroma = if position == REST_POSITION then REST_CHROMA else SERIES_CHROMA
	local inGamut = math.min(chroma, lightness * 0.5, 0.9 * (1 - lightness) + 0.05)
	return colorAt(SERIES_HUES[(index - 1) % #SERIES_HUES + 1], inGamut, tone)
end

function Style.spanTextTag(position: number, isDark: boolean): string
	return if spanTone(position, isDark) >= PALE_FROM_TONE then "TextOnPale" else "TextOnDeep"
end

return Style
