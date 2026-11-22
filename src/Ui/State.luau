--!strict
--- Where the interface meets the logic: the signals every view reads and the actions that call the Studio layer.

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

export type State = {
	entries: Flux.Node<{ BenchFolder.Entry }>,
	selectedPath: Flux.Node<string?>,
	runs: Flux.Node<{ RunHistory.RunRecord }>,
	runIndex: Flux.Node<number>,
	sizeIndex: Flux.Node<number>,
	selectedCase: Flux.Node<string?>,
	running: Flux.Node<boolean>,
	progress: Flux.Node<number>,
	message: Flux.Node<string>,
	rounds: Flux.Node<number>,
	editingRounds: Flux.Node<boolean>,
	question: Flux.Node<Question?>,

	selectedRun: Flux.Node<RunHistory.RunRecord?>,
	sizeRecord: Flux.Node<Results.SizeRecord?>,

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
	answer: (rounds: number?) -> (),
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
	local running = Flux.signal(false)
	local progress = Flux.signal(0)
	local message = Flux.signal("")
	local rounds = Flux.signal(services.Preferences.Rounds)
	local editingRounds = Flux.signal(false)
	local question = Flux.signal(nil :: Question?)
	local control = { cancelRequested = false, asker = nil :: thread? }

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
		local stored = RunHistory.Get(services.History, path)
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
		if not entry or running:peek() then
			return
		end

		BenchFolder.Ensure(services.BenchSource)
		control.cancelRequested = false
		running(true)
		progress(0)
		message("")

		task.spawn(function()
			local status, detail = BenchRunner.Run(entry, services.History, rounds:peek(), function(fraction: number)
				progress(fraction)
				return not control.cancelRequested
			end, function(secondsPerRound: number, wanted: number): number?
				question({ secondsPerRound = secondsPerRound, rounds = wanted })
				control.asker = coroutine.running()
				return coroutine.yield()
			end)

			running(false)
			if status == "finished" then
				showStored(entry.Path)
			elseif status == "failed" or status == "rejected" then
				message(detail :: string)
			end
		end)
	end

	local function answer(wanted: number?)
		local asker = control.asker
		if not asker then
			return
		end

		control.asker = nil
		question:set(nil)
		task.spawn(asker, if wanted then Preferences.Kept(wanted) else nil)
	end

	local function cancel()
		control.cancelRequested = true
		answer(nil)
	end

	local function clear()
		local entry = selectedEntry()
		if entry then
			RunHistory.Clear(services.History, entry.Path)
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
		rounds(Preferences.SetRounds(services.Preferences, wanted))
	end

	refresh()

	return {
		entries = entries,
		selectedPath = selectedPath,
		runs = runs,
		runIndex = runIndex,
		sizeIndex = sizeIndex,
		selectedCase = selectedCase,
		running = running,
		progress = progress,
		message = message,
		rounds = rounds,
		editingRounds = editingRounds,
		question = question,

		selectedRun = selectedRun,
		sizeRecord = sizeRecord,

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
		answer = answer,
	}
end

return State
