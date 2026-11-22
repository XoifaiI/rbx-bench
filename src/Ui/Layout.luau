--!strict
--!optimize 2

--[=[
	Layout: the spacing and control sizes that more than one view uses, in pixels

	Return type: frozen table of numbers
	Example usage:
		Flux.padding(Layout.Inset)
--]=]

local Layout = table.freeze({
	Inset = 12,
	Gap = 12,
	GapSmall = 8,
	ControlHeight = 34,
	ControlInset = 14,
})

return Layout
