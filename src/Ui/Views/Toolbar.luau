--!strict
--- The top bar: run or cancel, the round count, the selected bench, a button per input size, and the run strip.
--- A compact bar drops when the bench last ran and the strip's bars, so it fits a narrow panel.

local Flux = require("../../Packages/Flux")
local Components = require("../Components")
local Format = require("../../Util/Format")
local RunHistory = require("../../Studio/RunHistory")
local Results = require("../../Core/Results")
local Layout = require("../Layout")
local State = require("../State")

local new = Flux.new
local Text = Components.Text
local Button = Components.Button

local STEP_SIZE = UDim2.fromOffset(26, 26)
local STRIP_GAP = 6
local BARS_HEIGHT = 22
local BAR_WIDTH = 8
local BAR_GAP = 3
local SHORTEST_BAR = 0.15
local ROUNDS_FIELD_WIDTH = 110

local function RunStrip(props: { state: State.State, isCompact: () -> boolean }): Frame
	local state = props.state

	local tallest = Flux.computed(function(): number
		local sizeIndex = state.sizeIndex()
		local most = 0
		for _, run in state.runs() do
			most = math.max(most, State.baselineMedian(run, sizeIndex))
		end
		return most
	end)

	return new "Frame" {
		Name = "RunStrip",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, Layout.ControlHeight),
		Visible = function()
			return #state.runs() > 0
		end,

		Flux.list({ direction = "x", gap = STRIP_GAP, align = "center" }),

		Button({
			text = "<",
			Size = STEP_SIZE,
			onClick = function()
				state.showRun(state.runIndex:peek() - 1)
			end,
		}),

		new "Frame" {
			Name = "Bars",
			AutomaticSize = Enum.AutomaticSize.X,
			Size = UDim2.fromOffset(0, BARS_HEIGHT),
			Visible = function()
				return not props.isCompact()
			end,

			Flux.list({ direction = "x", gap = BAR_GAP, align = "end" }),

			Flux.forIndex(state.runs, function(index, run: Flux.Node<RunHistory.RunRecord>)
				return new "TextButton" {
					Text = "",
					__TAG = {
						"Button",
						function(): string?
							return if state.runIndex() == index then "Accent" else nil
						end,
					},
					Size = function()
						local median = State.baselineMedian(run(), state.sizeIndex())
						local height = if tallest() > 0 then median / tallest() else 0
						return UDim2.new(0, BAR_WIDTH, math.clamp(height, SHORTEST_BAR, 1), 0)
					end,

					Activated = function()
						state.showRun(index)
					end,
				}
			end),
		},

		Button({
			text = ">",
			Size = STEP_SIZE,
			onClick = function()
				state.showRun(state.runIndex:peek() + 1)
			end,
		}),

		Text({
			text = function()
				return if props.isCompact()
					then `{state.runIndex()} / {#state.runs()}`
					else `Run {state.runIndex()} of {#state.runs()}`
			end,
			tags = { "TextDim" },
		}),
	}
end

local function Rounds(props: { state: State.State }): Frame
	local state = props.state
	local editing = state.editingRounds

	local field = new "TextBox" {
		Name = "Field",
		Size = UDim2.fromOffset(ROUNDS_FIELD_WIDTH, Layout.ControlHeight),
		PlaceholderText = "Rounds",
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
		Visible = editing,
		__TAG = { "Field" },

		Flux.padding({ x = Layout.ControlInset }),
	}

	Flux.edit(field) {
		FocusLost = function(enterPressed: boolean)
			local wanted = tonumber(field.Text)
			if enterPressed and wanted then
				state.setRounds(wanted)
			end
			editing(false)
		end,
	}

	Flux.effect(function()
		if not editing() then
			return
		end

		field.Text = tostring(state.rounds:peek())
		task.defer(function()
			if editing:peek() then
				field:CaptureFocus()
				field.SelectionStart = 1
				field.CursorPosition = #field.Text + 1
			end
		end)
	end)

	return new "Frame" {
		Name = "Rounds",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, Layout.ControlHeight),

		Button({
			text = function()
				return `{state.rounds()} rounds`
			end,
			Visible = function()
				return not editing()
			end,
			enabled = function()
				return not state.running()
			end,
			onClick = function()
				editing(true)
			end,
		}),

		field,
	}
end

local function Toolbar(props: { state: State.State, isCompact: () -> boolean }): Frame
	local state = props.state

	local function hasBench(): boolean
		return state.selectedPath() ~= nil
	end

	return new "Frame" {
		Name = "Toolbar",
		Size = UDim2.new(1, 0, 0, Layout.ControlHeight),

		Flux.list({ direction = "x", gap = Layout.Gap, align = "center" }),

		Button({
			text = Flux.pick(state.running, "Cancel", "Run"),
			accent = true,
			enabled = hasBench,
			onClick = function()
				if state.running:peek() then
					state.cancel()
				else
					state.run()
				end
			end,
		}),

		Rounds({ state = state }),

		Text({
			text = function()
				return state.selectedPath() or "No bench selected"
			end,
			tags = { "TextTitle" },
		}),

		Text({
			text = function()
				local run = state.selectedRun()
				return if run then `Ran {Format.Ago(os.time() - run.Finished)}` else "Not run yet"
			end,
			tags = { "TextDim" },
			Visible = function()
				return not props.isCompact()
			end,
		}),

		Button({ text = "Open script", enabled = hasBench, onClick = state.open }),

		Flux.forIndex(function(): { Results.SizeRecord }
			local run = state.selectedRun()
			return if run and #run.Sizes > 1 then run.Sizes else {}
		end, function(index, size: Flux.Node<Results.SizeRecord>)
			return Button({
				text = function()
					return size().Label
				end,
				selected = function()
					return state.sizeIndex() == index
				end,
				onClick = function()
					state.showSize(index)
				end,
			})
		end),

		new "Frame" { Name = "Spacer", Flux.flex() },

		RunStrip({ state = state, isCompact = props.isCompact }),

		Button({
			text = "Clear runs",
			enabled = function()
				return #state.runs() > 0 and not state.running()
			end,
			onClick = state.clear,
		}),
	}
end

return Toolbar
