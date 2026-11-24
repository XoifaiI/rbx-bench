--!strict
--!optimize 2

--[=[
	App: the panel: toolbar, bench list, chart, progress line, failure message and hover card. `mount` puts it into a
	ScreenGui or plugin widget and returns the unmount

	Return type: the App module table
	Example usage:
		local unmount = App.mount(widget, state, isDark)
--]=]

local Flux = require("../Packages/Flux")
local BenchList = require("./Views/BenchList")
local Chart = require("./Views/Chart")
local Components = require("./Components")
local Layout = require("./Layout")
local RunDialog = require("./Views/RunDialog")
local CaseRows = require("./CaseRows")
local State = require("./State")
local Style = require("./Style")
local Toolbar = require("./Views/Toolbar")
local Tooltip = require("./Tooltip")

local new = Flux.new
local Text = Components.Text

local WIDE_FROM = 760
local ROOMY_FROM = 1040
local LIST_WIDTH = 240
local LIST_HEIGHT_WHEN_NARROW = 190
local SHORTEST_WIDE = 280
local NARROWEST = 480
local SHORTEST_STACKED = 600
local PROGRESS_HEIGHT = 3

local App = {}

local function Panel(state: State.State, tooltip: Tooltip.Tooltip): Frame
	return Tooltip.context:provide(tooltip, function()
		local root = new "Frame" {
			Name = "Bench",
			Size = UDim2.fromScale(1, 1),
			__TAG = { "Panel" },
		}

		local size = Flux.property(root, "AbsoluteSize")
		local wide = Flux.computed(function(): boolean
			return size().X >= WIDE_FROM
		end)

		local tooSmall = Flux.computed(function(): boolean
			if wide() then
				return size().Y < SHORTEST_WIDE
			end
			return size().X < NARROWEST or size().Y < SHORTEST_STACKED
		end)

		local rows = CaseRows.ranked(state)

		return Flux.edit(root) {
			new "Frame" {
				Name = "Content",
				Size = UDim2.fromScale(1, 1),
				Visible = function()
					return not tooSmall()
				end,

				Flux.padding(Layout.Inset),
				Flux.list({ gap = Layout.Gap }),

				Toolbar({
					state = state,
					isCompact = function()
						return size().X < ROOMY_FROM
					end,
				}),

				new "Frame" {
					Name = "Body",
					Size = UDim2.fromScale(1, 0),

					Flux.flex(),
					Flux.list({
						direction = function()
							return if wide() then "x" else "y"
						end,
						gap = Layout.Gap,
					}),

					BenchList({
						state = state,
						size = Flux.pick(
							wide,
							UDim2.new(0, LIST_WIDTH, 1, 0),
							UDim2.new(1, 0, 0, LIST_HEIGHT_WHEN_NARROW)
						),
					}),

					Flux.edit(Chart({
						state = state,
						rows = rows,
						size = Flux.pick(wide, UDim2.fromScale(0, 1), UDim2.fromScale(1, 0)),
					})) {
						Flux.flex(),
					},
				},

				Components.Card({
					Name = "Message",
					AutomaticSize = Enum.AutomaticSize.Y,
					Size = UDim2.fromScale(1, 0),
					__TAG = { "Message" },
					Visible = function()
						return state.message() ~= ""
					end,

					Text({
						text = state.message,
						tags = { "TextOnBad" },
						AutomaticSize = Enum.AutomaticSize.Y,
						Size = UDim2.fromScale(1, 0),
						TextWrapped = true,
					}),
				}),
			},

			new "Frame" {
				Name = "Progress",
				__TAG = { "Progress" },
				Size = function()
					return UDim2.new(if state.running() then state.progress() else 0, 0, 0, PROGRESS_HEIGHT)
				end,
			},

			Text({
				text = `Panel too small. Make it at least {WIDE_FROM} by {SHORTEST_WIDE}, or {NARROWEST} by {SHORTEST_STACKED}.`,
				tags = { "TextDim" },
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Visible = tooSmall,
			}),

			RunDialog({ state = state }),
			Tooltip.Layer({ tooltip = tooltip, root = root }),
		}
	end)
end

function App.mount(
	layer: Instance,
	state: State.State,
	isDark: Flux.Reactive<boolean>,
	tooltip: Tooltip.Tooltip?
): () -> ()
	return Flux.mount(function()
		Style.mount(layer, isDark)
		return Style.dark:provide(isDark, function()
			return Panel(state, tooltip or Tooltip.new())
		end)
	end, layer)
end

return App
