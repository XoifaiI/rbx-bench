--!strict
--!optimize 2

--[=[
	Dock: Puts the panel into the plugin's dock widget: its state, the Studio theme, a refresh whenever the widget is shown
	and, in a dev build, the `Debug` BindableFunction that drives the panel from outside. Returns the undock

	Return type: the Dock function
	Example usage:
		local Undock = Dock(Widget, Services.New(plugin, BenchSource), IsDev)
--]=]

local Flux = require("../Packages/Flux")
local App = require("./App")
local CaseRows = require("./CaseRows")
local CreateInstance = require("../Studio/CreateInstance")
local Services = require("../Studio/Services")
local State = require("./State")
local Style = require("./Style")
local Tooltip = require("./Tooltip")

type HoverTarget = {
	name: string?,
	span: string?,
	bin: number?,
	x: number,
	y: number,
}

type Commands = { [string]: (argument: any) -> any }

local function debugCommands(
	state: State.State,
	previewCard: Tooltip.Tooltip,
	preview: (target: Instance) -> number
): Commands
	return {
		preview = preview,

		hover = function(at: HoverTarget?)
			local record = state.sizeRecord:peek()
			if not at or not record then
				previewCard.content:set(nil)
				return false
			end

			local bin = at.bin
			if bin then
				local rows: { CaseRows.Row } = {}
				for position, case in record.Cases do
					if case.Histogram.Bins[bin] > 0 then
						table.insert(rows, { case = case, colorIndex = position })
					end
				end

				previewCard.pointer(Vector2.new(at.x, at.y))
				previewCard.content:set(CaseRows.describeBin(rows, bin))
				return #rows > 0
			end

			for position, case in record.Cases do
				if case.Name == at.name then
					local row: CaseRows.Row = { case = case, colorIndex = position }
					local content = CaseRows.describe(row)
					for _, segment in CaseRows.flame(case) do
						if segment.name == at.span then
							content = CaseRows.describeSegment(row, segment)
						end
					end

					previewCard.pointer(Vector2.new(at.x, at.y))
					previewCard.content:set(content)
					return true
				end
			end
			return false
		end,

		refresh = function()
			state.refresh()
			return #state.entries:peek()
		end,

		create = function()
			state.create()
			return state.selectedPath:peek()
		end,

		select = function(path: string)
			state.select(path)
			return state.selectedPath:peek()
		end,

		run = function()
			state.run()
			return state.running:peek()
		end,

		step = function(index: number)
			state.showRun(index)
			return state.runIndex:peek()
		end,

		size = function(index: number)
			state.showSize(index)
			return state.sizeIndex:peek()
		end,

		bars = function(height: number?)
			state.setBarsHeight(height)
			return state.barsHeight:peek()
		end,

		show = function(name: string)
			state.showCase(name)
			return state.selectedCase:peek()
		end,

		answer = function(wanted: number?)
			state.answer(wanted)
			return state.question:peek() == nil
		end,

		cancel = function()
			state.cancel()
			return state.runStatus:peek()
		end,

		question = function()
			return state.question:peek()
		end,

		clear = function()
			state.clear()
			return #state.runs:peek()
		end,

		rounds = function(wanted: number?)
			if wanted then
				state.setRounds(wanted)
			end
			return state.rounds:peek()
		end,

		edit = function(isOpen: boolean)
			state.editingRounds(isOpen)
			return state.editingRounds:peek()
		end,

		status = function()
			return {
				selected = state.selectedPath:peek(),
				running = state.running:peek(),
				runStatus = state.runStatus:peek(),
				barsHeight = state.barsHeight:peek(),
				progress = state.progress:peek(),
				message = state.message:peek(),
				runs = #state.runs:peek(),
				record = state.selectedRun:peek(),
			}
		end,
	}
end

local function Dock(widget: DockWidgetPluginGui, services: Services.Services, isDev: boolean): () -> ()
	Style.claim()

	local studio = settings().Studio
	local isDark = Flux.signal(studio.Theme.Name == "Dark")
	local state = State.new(services)
	local previewCard = Tooltip.new()
	local unmounts = { App.mount(widget, state, isDark) }

	local connections = {
		widget:GetPropertyChangedSignal("Enabled"):Connect(function()
			if widget.Enabled then
				state.refresh()
			end
		end),

		studio.ThemeChanged:Connect(function()
			isDark(studio.Theme.Name == "Dark")
		end),
	}

	if isDev then
		local commands = debugCommands(state, previewCard, function(target: Instance): number
			table.insert(unmounts, App.mount(target, state, isDark, previewCard))
			return #unmounts
		end)

		local debugHook = CreateInstance.Create("BindableFunction", { Name = "Debug", Parent = widget })
		debugHook.OnInvoke = function(command: string, argument: any): any
			local handler = commands[command]
			assert(handler, `rbx-bench has no debug command "{command}"`)
			return handler(argument)
		end
	end

	return function()
		for _, connection in connections do
			connection:Disconnect()
		end
		for _, unmount in unmounts do
			unmount()
		end
	end
end

return Dock
