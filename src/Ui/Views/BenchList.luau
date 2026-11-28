--!strict
--!optimize 2

--[=[
	BenchList: the bench list: a filter box, a button that creates a bench, and one row per bench with its own run
	button

	Return type: the BenchList component
	Example usage:
		BenchList({ state = state, size = UDim2.new(0, 240, 1, 0) })
--]=]

local Flux = require("../../Packages/Flux")
local Components = require("../Components")
local FuzzySearch = require("../../Util/FuzzySearch")
local BenchFolder = require("../../Studio/BenchFolder")
local Layout = require("../Layout")
local State = require("../State")

local new = Flux.new
local Text = Components.Text
local Button = Components.Button

local ROW_HEIGHT = 40
local ROW_GAP = 2
local ROW_BUTTON = UDim2.fromOffset(32, 32)
local ROW_BUTTON_INSET = 4

local function BenchList(props: { state: State.State, size: Flux.Reactive<UDim2> }): Frame
	local state = props.state
	local filter = Flux.signal("")

	local shown = Flux.computed(function(): { BenchFolder.Entry }
		local entries = state.entries()
		local wanted = filter()
		if wanted == "" then
			return entries
		end

		local paths = table.create(#entries, "")
		for index, entry in entries do
			paths[index] = entry.Path
		end

		local matching: { BenchFolder.Entry } = {}
		for position, index in FuzzySearch.Search(wanted, paths) do
			matching[position] = entries[index]
		end
		return matching
	end)

	return Components.Card({
		Name = "BenchList",
		Size = props.size,

		Flux.list({ gap = Layout.Gap }),

		new "Frame" {
			Name = "Header",
			Size = UDim2.new(1, 0, 0, Layout.ControlHeight),

			Flux.list({ direction = "x", gap = Layout.GapSmall, align = "center" }),

			new "TextBox" {
				Name = "Filter",
				Size = UDim2.fromScale(0, 1),
				PlaceholderText = "Filter benches",
				TextXAlignment = Enum.TextXAlignment.Left,
				Text = Flux.model(filter),
				__TAG = { "Field" },

				Flux.flex(),
				Flux.padding({ x = Layout.ControlInset }),
			},

			Button({ text = "+", accent = true, glyph = true, onClick = state.create }),
		},

		Components.Scroller({
			Name = "Entries",
			Size = UDim2.fromScale(1, 0),

			Flux.flex(),
			Flux.list({ gap = ROW_GAP }),

			Flux.forKey(shown, function(entry: BenchFolder.Entry)
				return entry.Path
			end, function(index, entry: Flux.Node<BenchFolder.Entry>)
				local path = entry:peek().Path
				local function selected(): boolean
					return state.selectedPath() == path
				end

				return new "TextButton" {
					LayoutOrder = index,
					Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
					Text = "",
					__TAG = {
						"Row",
						function(): string?
							return if selected() then "Selected" else nil
						end,
					},

					Activated = function()
						state.select(path)
					end,

					Flux.padding({ left = Layout.Inset, right = ROW_BUTTON_INSET }),
					Flux.list({ direction = "x", gap = Layout.GapSmall, align = "center" }),

					Text({
						text = path,
						tags = { "TextStrong" },
						AutomaticSize = Enum.AutomaticSize.None,
						Size = UDim2.fromScale(0, 1),
						TextTruncate = Enum.TextTruncate.AtEnd,
						Flux.flex(),
					}),

					Button({
						text = "Run",
						Size = ROW_BUTTON,
						enabled = function()
							return state.can("run")
						end,
						onClick = function()
							state.select(path)
							state.run()
						end,
					}),
				}
			end, function()
				return Text({
					text = function()
						return if #state.entries() == 0
							then "No benches yet. Press + to create one."
							else "No bench matches the filter."
					end,
					tags = { "TextDim" },
					AutomaticSize = Enum.AutomaticSize.Y,
					Size = UDim2.fromScale(1, 0),
					TextWrapped = true,
				})
			end),
		}),
	})
end

return BenchList
