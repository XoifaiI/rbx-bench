--!strict
--!optimize 2

--[=[
	Motion: how the panel moves. Every spring is critically damped, so nothing overshoots, and a new target drops
	the old speed, so a move starts at once from where things are. A value that follows within a scope jumps when
	the scope changes, and with Studio's Reduced Motion on every value jumps

	Return type: the Motion module table
	Example usage:
		local Reach = Motion.follow(Share, Motion.DATA)
		local Dialog = Motion.fade(Question)
--]=]

local GuiService = game:GetService("GuiService")

local Flux = require("../Packages/Flux")

export type Fade<T> = {
	shown: Flux.Spring<number>,
	last: Flux.Node<T?>,
}

local DAMPING = 1
local VISIBLE_ABOVE = 0.001

local Motion = {
	DATA = 3,
	CHROME = 6,
	FADE = 10,
	STAGGER = 0.03,
	LONGEST_STAGGER = 0.24,
}

local function readReducedMotion(): boolean
	local isRead, value = pcall(function(): unknown
		return (GuiService :: any).ReducedMotionEnabled
	end)
	return isRead and value == true
end

local isReduced = Flux.signal(readReducedMotion())
pcall(function()
	GuiService:GetPropertyChangedSignal("ReducedMotionEnabled"):Connect(function()
		isReduced(readReducedMotion())
	end)
end)

local function retarget(spring: Flux.Spring<number>, target: () -> number, scope: (() -> unknown)?)
	local lastScope: unknown = if scope then scope() else nil
	Flux.effect(function()
		local value = target()
		local currentScope: unknown = if scope then scope() else nil
		if isReduced() or currentScope ~= lastScope then
			spring:snap(value)
		else
			spring:setVelocity(0)
		end
		lastScope = currentScope
	end)
end

function Motion.spring(initial: number, tempo: number): Flux.Spring<number>
	return Flux.spring(initial, tempo, DAMPING)
end

function Motion.restart(progress: Flux.Spring<number>)
	if isReduced:peek() then
		progress:snap(1)
		return
	end
	progress:snap(0)
	progress:set(1)
end

function Motion.follow(target: () -> number, tempo: number): Flux.Spring<number>
	local spring = Flux.spring(target, tempo, DAMPING)
	retarget(spring, target, nil)
	return spring
end

function Motion.followWithin(scope: () -> unknown, target: () -> number, tempo: number): Flux.Spring<number>
	local spring = Flux.spring(target, tempo, DAMPING)
	retarget(spring, target, scope)
	return spring
end

function Motion.enter(target: () -> number, tempo: number, delay: number): Flux.Spring<number>
	local hasStarted = Flux.signal(delay <= 0)
	local spring = Flux.spring(0, tempo, DAMPING)

	Flux.effect(function()
		local value = if hasStarted() then target() else 0
		if isReduced() then
			spring:snap(value)
		else
			spring:setVelocity(0)
			spring:set(value)
		end
	end)

	if delay > 0 then
		local starting = task.delay(delay, function()
			hasStarted(true)
		end)
		Flux.cleanup(function()
			if coroutine.status(starting) ~= "dead" then
				task.cancel(starting)
			end
		end)
	end
	return spring
end

function Motion.fade<T>(current: () -> T?): Fade<T>
	local last = Flux.signal(current())
	Flux.effect(function()
		local value = current()
		if value ~= nil then
			last(value)
		end
	end)

	local shown = Motion.follow(function(): number
		return if current() ~= nil then 1 else 0
	end, Motion.CHROME)

	return { shown = shown, last = last }
end

function Motion.isVisible(shown: Flux.Spring<number>): boolean
	return shown() > VISIBLE_ABOVE
end

return Motion
