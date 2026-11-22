--!strict
--!native
--!optimize 2

--[=[
	PlotPixels: draws the chart's plot into a pixel buffer: background, gridlines, each curve's shaded area, median
	markers and step lines. Call Order again when the curves or the height change

	Return type: the PlotPixels module table
	Example usage:
		PlotPixels.Draw(Pixels, Edges, Curves, PlotPixels.Order(Curves, Count, Height), Width, Height, Paint)
--]=]

export type Curve = {
	Red: number,
	Green: number,
	Blue: number,
	Color: number,
	MarkerColor: number,
	MarkerColumn: number,
	MarkerTop: number,
	Tops: { number },
}

export type Paint = {
	Card: number,
	Grid: number,
	Line: number,
	Shade: number,
	Columns: number,
	Levels: number,
}

local OPAQUE = 0xFF000000

local PlotPixels = {}

local function Background(Pixels: buffer, Width: number, Height: number, Color: number)
	for X = 0, Width - 1 do
		buffer.writeu32(Pixels, X * 4, Color)
	end

	local RowBytes = Width * 4
	for Y = 1, Height - 1 do
		buffer.copy(Pixels, Y * RowBytes, Pixels, 0, RowBytes)
	end
end

local function Fill(Pixels: buffer, Width: number, X0: number, Y0: number, X1: number, Y1: number, Color: number)
	if X1 <= X0 or Y1 <= Y0 then
		return
	end

	local RowBytes = (X1 - X0) * 4
	if RowBytes < 32 then
		local Stride = Width * 4
		local Rows = Y1 - Y0
		local WholeRows = Rows - Rows % 8
		for X = X0, X1 - 1 do
			local Top = (Y0 * Width + X) * 4
			for At = Top, Top + (WholeRows - 8) * Stride, Stride * 8 do
				buffer.writeu32(Pixels, At + Stride * 7, Color)
				buffer.writeu32(Pixels, At + Stride * 6, Color)
				buffer.writeu32(Pixels, At + Stride * 5, Color)
				buffer.writeu32(Pixels, At + Stride * 4, Color)
				buffer.writeu32(Pixels, At + Stride * 3, Color)
				buffer.writeu32(Pixels, At + Stride * 2, Color)
				buffer.writeu32(Pixels, At + Stride, Color)
				buffer.writeu32(Pixels, At, Color)
			end
			for At = Top + WholeRows * Stride, Top + (Rows - 1) * Stride, Stride do
				buffer.writeu32(Pixels, At, Color)
			end
		end
		return
	end

	for Y = Y0, Y1 - 1 do
		local First = (Y * Width + X0) * 4
		local Last = First + RowBytes - 32
		for At = First, Last - 4, 32 do
			buffer.writeu32(Pixels, At + 28, Color)
			buffer.writeu32(Pixels, At + 24, Color)
			buffer.writeu32(Pixels, At + 20, Color)
			buffer.writeu32(Pixels, At + 16, Color)
			buffer.writeu32(Pixels, At + 12, Color)
			buffer.writeu32(Pixels, At + 8, Color)
			buffer.writeu32(Pixels, At + 4, Color)
			buffer.writeu32(Pixels, At, Color)
		end
		buffer.writeu32(Pixels, Last + 28, Color)
		buffer.writeu32(Pixels, Last + 24, Color)
		buffer.writeu32(Pixels, Last + 20, Color)
		buffer.writeu32(Pixels, Last + 16, Color)
		buffer.writeu32(Pixels, Last + 12, Color)
		buffer.writeu32(Pixels, Last + 8, Color)
		buffer.writeu32(Pixels, Last + 4, Color)
		buffer.writeu32(Pixels, Last, Color)
	end
end

local function Solid(
	Pixels: buffer,
	Width: number,
	Height: number,
	X0: number,
	Y0: number,
	X1: number,
	Y1: number,
	Color: number
)
	X0 = math.max(X0, 0)
	Y0 = math.max(Y0, 0)
	X1 = math.min(X1, Width)
	Y1 = math.min(Y1, Height)
	Fill(Pixels, Width, X0, Y0, X1, Y1, Color)
end

function PlotPixels.Pack(Red: number, Green: number, Blue: number): number
	return Red + Green * 256 + Blue * 65536 + OPAQUE
end

function PlotPixels.Order(Curves: { Curve }, Count: number, Height: number): { { number } }
	local Order: { { number } } = {}
	for Bin = 1, Count do
		Order[Bin] = {}
	end
	for Index, Curve in Curves do
		local Tops = Curve.Tops
		for Bin = 1, Count do
			if Tops[Bin] < Height then
				table.insert(Order[Bin], Index)
			end
		end
	end

	local SortedBin = 1
	local function IsHigher(First: number, Second: number): boolean
		return Curves[First].Tops[SortedBin] < Curves[Second].Tops[SortedBin]
	end
	for Bin = 1, Count do
		if #Order[Bin] > 1 then
			SortedBin = Bin
			table.sort(Order[Bin], IsHigher)
		end
	end
	return Order
end

function PlotPixels.Draw(
	Pixels: buffer,
	Edges: { number },
	Curves: { Curve },
	Order: { { number } },
	Width: number,
	Height: number,
	Paint: Paint
)
	local Count = #Edges - 1
	local Card = Paint.Card
	local Line = Paint.Line
	local Shade = Paint.Shade
	local Keep = 1 - Shade

	Background(Pixels, Width, Height, Card)

	local CardRed = bit32.band(Card, 255)
	local CardGreen = bit32.band(bit32.rshift(Card, 8), 255)
	local CardBlue = bit32.band(bit32.rshift(Card, 16), 255)

	for Bin = 1, Count do
		local Reaching = Order[Bin]
		local Reached = #Reaching
		local X0: number, X1: number = Edges[Bin], Edges[Bin + 1]
		if Reached > 0 and X1 > X0 then
			local Red, Green, Blue = CardRed, CardGreen, CardBlue
			for Position = 1, Reached do
				local Curve = Curves[Reaching[Position]]
				Red = Red * Keep + Curve.Red * Shade
				Green = Green * Keep + Curve.Green * Shade
				Blue = Blue * Keep + Curve.Blue * Shade

				local Y0: number = Curve.Tops[Bin]
				local Y1: number = Height
				if Position < Reached then
					local Below = Curves[Reaching[Position + 1]]
					Y1 = Below.Tops[Bin]
				end

				if Y1 > Y0 then
					local Color = math.floor(Red + 0.5)
						+ math.floor(Green + 0.5) * 256
						+ math.floor(Blue + 0.5) * 65536
						+ OPAQUE
					Fill(Pixels, Width, X0, Y0, X1, Y1, Color)
				end
			end
		end
	end

	for Column = 0, Paint.Columns - 1 do
		local X = math.floor(Column / (Paint.Columns - 1) * (Width - 1))
		Solid(Pixels, Width, Height, X, 0, X + 1, Height, Paint.Grid)
	end
	for Level = 0, Paint.Levels - 1 do
		local Y = math.floor((1 - Level / (Paint.Levels - 1)) * (Height - 1))
		Solid(Pixels, Width, Height, 0, Y, Width, Y + 1, Paint.Grid)
	end

	for _, Curve in Curves do
		Solid(
			Pixels,
			Width,
			Height,
			Curve.MarkerColumn,
			Curve.MarkerTop,
			Curve.MarkerColumn + 1,
			Height,
			Curve.MarkerColor
		)
	end

	for _, Curve in Curves do
		local Tops = Curve.Tops
		local Color = Curve.Color
		local Previous = Height
		for Bin = 1, Count do
			local Y: number = Tops[Bin]
			local X0: number = Edges[Bin]
			if Y < Height then
				Solid(Pixels, Width, Height, X0, Y, Edges[Bin + 1] + Line, Y + Line, Color)
			end
			if Y ~= Previous then
				local Upper = math.min(Y, Previous)
				local Lower = math.min(math.max(Y, Previous) + Line, Height)
				Solid(Pixels, Width, Height, X0, Upper, X0 + Line, Lower, Color)
			end
			Previous = Y
		end
	end
end

function PlotPixels.Split(Tile: buffer, Pixels: buffer, Width: number, Height: number, X0: number, TileWidth: number)
	local TileBytes = TileWidth * 4
	for Y = 0, Height - 1 do
		buffer.copy(Tile, Y * TileBytes, Pixels, (Y * Width + X0) * 4, TileBytes)
	end
end

return PlotPixels
