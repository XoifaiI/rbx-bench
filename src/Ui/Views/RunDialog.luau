--!strict
--!optimize 2

--[=[
	RunDialog: the dialog that asks before a long run: how long it will take at the round count typed into its field,
	with a button to cancel and one to continue with that count. The count applies to this run only

	Return type: the RunDialog component
	Example usage:
		RunDialog({ state = state })
--]=]

local Flux = require("../../Packages/Flux")
local Components = require("../Components")
local Format = require("../../Util/Format")
local Layout = require("../Layout")
local Motion = require("../Motion")
local Preferences = require("../../Studio/Preferences")
local State = require("../State")

local new = Flux.new
local Text = Components.Text
local Button = Components.Button

local WIDTH = 440
local INSET = 20
local FIELD_WIDTH = 140
local LAYER = 50
local SCRIM_OPACITY = 0.65
local ENTRY_SCALE = 0.96

local function RunDialog(props: { state: State.State }): TextButton
	local state = props.state
	local typed = Flux.signal("")

	local fade = Motion.fade(function(): State.Question?
		return state.question()
	end)

	local wanted = Flux.computed(function(): number?
		local count = tonumber(typed())
		return if count then Preferences.Kept(count) else nil
	end)

	local field = new "TextBox" {
		Name = "Rounds",
		Size = UDim2.fromOffset(FIELD_WIDTH, Layout.ControlHeight),
		PlaceholderText = "Rounds",
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = Flux.model(typed),
		__TAG = { "Field" },

		Flux.padding({ x = Layout.ControlInset }),
	}

	local function proceed()
		local count = wanted:peek()
		if count then
			state.answer(count)
		end
	end

	Flux.edit(field) {
		FocusLost = function(enterPressed: boolean)
			if enterPressed then
				proceed()
			end
		end,
	}

	Flux.effect(function()
		local question = state.question()
		if not question then
			return
		end

		typed(tostring(question.rounds))
		task.defer(function()
			if state.question:peek() then
				field:CaptureFocus()
				field.SelectionStart = 1
				field.CursorPosition = #field.Text + 1
			end
		end)
	end)

	return new "TextButton" {
		Name = "RunDialog",
		Size = UDim2.fromScale(1, 1),
		ZIndex = LAYER,
		Text = "",
		AutoButtonColor = false,
		__TAG = { "Scrim" },
		BackgroundTransparency = function()
			return 1 - fade.shown() * SCRIM_OPACITY
		end,

		Visible = function()
			return Motion.isVisible(fade.shown)
		end,
		Interactable = function()
			return state.question() ~= nil
		end,

		new "CanvasGroup" {
			Name = "Card",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			AutomaticSize = Enum.AutomaticSize.Y,
			Size = UDim2.fromOffset(WIDTH, 0),
			GroupTransparency = function()
				return 1 - fade.shown()
			end,
			__TAG = { "Card", "Raised" },

			new "UIScale" {
				Scale = function()
					return ENTRY_SCALE + (1 - ENTRY_SCALE) * fade.shown()
				end,
			},
			Flux.padding(INSET),
			Flux.list({ gap = Layout.Gap }),

			Text({ text = "This run will take a while", tags = { "TextTitle" } }),

			Text({
				text = function()
					local question = fade.last()
					local count = wanted()
					if not question then
						return ""
					elseif not count then
						return "Type how many rounds to run."
					end
					return `About {Format.Duration(question.secondsPerRound * count)} at {Format.Count(count)} rounds.`
				end,
				tags = { "TextDim" },
			}),

			new "Frame" {
				Name = "Choice",
				AutomaticSize = Enum.AutomaticSize.Y,
				Size = UDim2.fromScale(1, 0),

				Flux.list({ direction = "x", gap = Layout.GapSmall, align = "center" }),

				field,
				new "Frame" { Name = "Spacer", Flux.flex() },
				Button({ text = "Cancel", onClick = state.cancel }),
				Button({
					text = "Continue",
					accent = true,
					enabled = function()
						return wanted() ~= nil
					end,
					onClick = proceed,
				}),
			},
		},
	}
end

return RunDialog
