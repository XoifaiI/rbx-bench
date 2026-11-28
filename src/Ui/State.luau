--!strict
--!optimize 2

--[=[
	State: the signals every view reads and the actions that call the Studio layer. The UI files use camelCase, as
	Flux does. A run's status changes only through `move`, along NEXT, and views ask `can` rather than compare
	statuses. A run that ends after another bench was picked does not take the view back

	Return type: the State module table
	Example usage:
		local state = State.new(services)
--]=]

local Flux = require("../Packages/Flux")
local RunHistory = require("../Studio/RunHistory")
local Results = require("../Core/Results")
local BenchFolder = require("../Studio/BenchFolder")
local Preferences = require("../Studio/Preferences")
local Services = require("../Studio/Services")
local BenchRunner = require("../Studio/BenchRunner")

export type Question = {
	secondsPerRound: number,
	rounds: number,
}

export type RunStatus = "idle" | "running" | "asking" | "cancelling"

export type Operation = "run" | "cancel" | "answer" | "setRounds" | "clear" | "keepMeasuring"

type Lifecycle =
	{ read status: "idle" }
	| { read status: "running" }
	| {
		read status: "asking",
		read question: Question,
		read asker: thread,
	}
	| { read status: "cancelling" }

export type State = {
	entries: Flux.Node<{ BenchFolder.Entry }>,
	selectedPath: Flux.Node<string?>,
	runs: Flux.Node<{ RunHistory.RunRecord }>,
	runIndex: Flux.Node<number>,
	sizeIndex: Flux.Node<number>,
	selectedCase: Flux.Node<string?>,
	runStatus: Flux.Node<RunStatus>,
	running: Flux.Node<boolean>,
	progress: Flux.Node<number>,
	message: Flux.Node<string>,
	rounds: Flux.Node<number>,
	barsHeight: Flux.Node<number?>,
	editingRounds: Flux.Node<boolean>,
	question: Flux.Node<Question?>,

	selectedRun: Flux.Node<RunHistory.RunRecord?>,
	sizeRecord: Flux.Node<Results.SizeRecord?>,

	can: (operation: Operation) -> boolean,
	refresh: () -> (),
	create: () -> (),
	select: (path: string) -> (),
	open: () -> (),
	run: () -> (),
	cancel: () -> (),
	clear: () -> (),
	showRun: (index: number) -> (),
	showSize: (index: number) -> (),
	showCase: (name: string) -> (),
	setRounds: (wanted: number) -> (),
	setBarsHeight: (height: number?) -> (),
	answer: (rounds: number?) -> (),
}

local NEXT: { [RunStatus]: { RunStatus } } = {
	idle = { "running" },
	running = { "asking", "cancelling", "idle" },
	asking = { "running", "cancelling" },
	cancelling = { "idle" },
}

local ALLOWED_IN: { [Operation]: { RunStatus } } = {
	run = { "idle" },
	cancel = { "running", "asking" },
	answer = { "asking" },
	setRounds = { "idle" },
	clear = { "idle" },
	keepMeasuring = { "running", "asking" },
}

local function sizeOf(run: RunHistory.RunRecord, sizeIndex: number): Results.SizeRecord
	return run.Sizes[sizeIndex] or run.Sizes[1]
end

local State = {}

function State.baselineMedian(run: RunHistory.RunRecord, sizeIndex: number): number
	local record = sizeOf(run, sizeIndex)
	local baseline = Results.CaseNamed(record, record.Baseline)
	return if baseline then baseline.Stats.Median else 0
end

function State.new(services: Services.Services): State
	local entries = Flux.signal(BenchFolder.List())
	local selectedPath = Flux.signal(nil :: string?)
	local runs = Flux.signal({} :: { RunHistory.RunRecord })
	local runIndex = Flux.signal(0)
	local sizeIndex = Flux.signal(1)
	local selectedCase = Flux.signal(nil :: string?)
	local lifecycle = Flux.signal({ status = "idle" } :: Lifecycle)
	local progress = Flux.signal(0)
	local message = Flux.signal("")
	local rounds = Flux.signal(services.Preferences.Rounds)
	local barsHeight = Flux.signal(services.Preferences.BarsHeight :: number?)
	local editingRounds = Flux.signal(false)

	local runStatus = Flux.computed(function(): RunStatus
		return lifecycle().status
	end)

	local running = Flux.computed(function(): boolean
		return runStatus() ~= "idle"
	end)

	local question = Flux.computed(function(): Question?
		local current = lifecycle()
		return if current.status == "asking" then current.question else nil
	end)

	local function can(operation: Operation): boolean
		return table.find(ALLOWED_IN[operation], runStatus()) ~= nil
	end

	local function move(to: Lifecycle)
		local from = lifecycle:peek().status
		if not table.find(NEXT[from], to.status) then
			error(`rbx-bench cannot move a run from {from} to {to.status}; NEXT does not allow it`)
		end
		lifecycle(to)
	end

	local selectedRun = Flux.computed(function(): RunHistory.RunRecord?
		return runs()[runIndex()]
	end)

	local sizeRecord = Flux.computed(function(): Results.SizeRecord?
		local run = selectedRun()
		if not run then
			return nil
		end
		return sizeOf(run, sizeIndex())
	end)

	local function selectedEntry(): BenchFolder.Entry?
		local path = selectedPath:peek()
		for _, entry in entries:peek() do
			if entry.Path == path then
				return entry
			end
		end
		return nil
	end

	local function showStored(path: string)
		local stored = services.History:Get(path)
		runs(table.clone(stored))
		runIndex(#stored)
	end

	local function select(path: string)
		selectedPath(path)
		sizeIndex(1)
		selectedCase:set(nil)
		message("")
		showStored(path)
	end

	local function refresh()
		local listed = BenchFolder.List()
		entries(listed)
		if not selectedEntry() and listed[1] then
			select(listed[1].Path)
		end
	end

	local function create()
		local entry = BenchFolder.Create(services.BenchSource)
		entries(BenchFolder.List())
		select(entry.Path)
		services.OpenScript(entry.Module)
	end

	local function open()
		local entry = selectedEntry()
		if entry then
			services.OpenScript(entry.Module)
		end
	end

	local function run()
		local entry = selectedEntry()
		if not entry or not can("run") then
			return
		end

		BenchFolder.Ensure(services.BenchSource)
		progress(0)
		message("")
		move({ status = "running" })

		task.spawn(function()
			local status, problem = BenchRunner.Run(entry, services.History, rounds:peek(), function(fraction: number)
				progress(fraction)
				return can("keepMeasuring")
			end, function(secondsPerRound: number, wanted: number): number?
				move({
					status = "asking",
					question = { secondsPerRound = secondsPerRound, rounds = wanted },
					asker = coroutine.running(),
				})
				return coroutine.yield()
			end)

			move({ status = "idle" })
			if selectedPath:peek() ~= entry.Path then
				return
			end
			if status == "finished" then
				showStored(entry.Path)
			elseif problem then
				message(problem)
			end
		end)
	end

	local function answer(wanted: number?)
		local current = lifecycle:peek()
		if not can("answer") or current.status ~= "asking" then
			return
		end

		local after: Lifecycle = if wanted then { status = "running" } else { status = "cancelling" }
		move(after)
		task.spawn(current.asker, if wanted then Preferences.Kept(wanted) else nil)
	end

	local function cancel()
		if not can("cancel") then
			return
		end
		if can("answer") then
			answer(nil)
		else
			move({ status = "cancelling" })
		end
	end

	local function clear()
		if not can("clear") then
			return
		end
		local entry = selectedEntry()
		if entry then
			services.History:Clear(entry.Path)
			showStored(entry.Path)
		end
	end

	local function showRun(index: number)
		runIndex(math.clamp(index, math.min(1, #runs:peek()), #runs:peek()))
	end

	local function showSize(index: number)
		sizeIndex(index)
	end

	local function showCase(name: string)
		if selectedCase:peek() == name then
			selectedCase:set(nil)
		else
			selectedCase(name)
		end
	end

	local function setRounds(wanted: number)
		if can("setRounds") then
			rounds(services.Preferences:SetRounds(wanted))
		end
	end

	local function setBarsHeight(height: number?)
		services.Preferences:SetBarsHeight(height)
		barsHeight:set(height)
	end

	refresh()

	return {
		entries = entries,
		selectedPath = selectedPath,
		runs = runs,
		runIndex = runIndex,
		sizeIndex = sizeIndex,
		selectedCase = selectedCase,
		runStatus = runStatus,
		running = running,
		progress = progress,
		message = message,
		rounds = rounds,
		barsHeight = barsHeight,
		editingRounds = editingRounds,
		question = question,

		selectedRun = selectedRun,
		sizeRecord = sizeRecord,

		can = can,
		refresh = refresh,
		create = create,
		select = select,
		open = open,
		run = run,
		cancel = cancel,
		clear = clear,
		showRun = showRun,
		showSize = showSize,
		showCase = showCase,
		setRounds = setRounds,
		setBarsHeight = setBarsHeight,
		answer = answer,
	}
end

return State
