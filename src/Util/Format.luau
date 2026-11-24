--!strict
--!optimize 2

--[=[
	Format: words numbers for the panel: times, percentages, how long ago, and the verdict against the baseline

	Return type: the Format module table
	Example usage:
		local Text = Format.Time(1250)
--]=]

local Results = require("../Core/Results")

local Format = {}

local function Grouped(Value: number): string
	local Whole = math.round(Value)
	return if Whole >= 1000 then string.format("%d,%03d", Whole // 1000, Whole % 1000) else tostring(Whole)
end

function Format.Count(Value: number): string
	return Grouped(Value)
end

function Format.Duration(Seconds: number): string
	local Whole = math.max(math.round(Seconds), 1)
	if Whole < 60 then
		return `{Whole} s`
	elseif Whole < 3600 then
		return `{Whole // 60} min {Whole % 60} s`
	end
	return `{Whole // 3600} h {Whole % 3600 // 60} min`
end

function Format.Time(Nanoseconds: number): string
	if Nanoseconds >= 1e6 then
		return string.format("%.2f ms", Nanoseconds / 1e6)
	elseif Nanoseconds >= 1e4 then
		return string.format("%.1f µs", Nanoseconds / 1e3)
	elseif Nanoseconds >= 100 then
		return `{Grouped(Nanoseconds)} ns`
	end
	return string.format("%.1f ns", Nanoseconds)
end

function Format.Percent(Fraction: number): string
	return string.format("%.1f%%", Fraction * 100)
end

function Format.Ago(Seconds: number): string
	if Seconds < 60 then
		return "just now"
	elseif Seconds < 3600 then
		return `{Seconds // 60} min ago`
	elseif Seconds < 86400 then
		return `{Seconds // 3600} h ago`
	end
	return `{Seconds // 86400} d ago`
end

function Format.Verdict(Verdict: Results.Verdict, Ratio: number): string
	if Verdict == "baseline" or Verdict == "tie" then
		return Verdict
	elseif Verdict == "faster" then
		return `{Format.Percent(1 - Ratio)} faster`
	elseif Ratio >= 2 then
		return string.format("%.2fx slower", Ratio)
	end
	return `{Format.Percent(Ratio - 1)} slower`
end

return Format
