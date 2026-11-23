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

local SegmentHeads: { number } = {}
local SegmentNexts: { number } = {}
local SegmentLefts: { number } = {}
local SegmentRights: { number } = {}
local SegmentColors: { number } = {}
local CurveReds: { number } = {}
local CurveGreens: { number } = {}
local CurveBlues: { number } = {}
local CurveTops: { { number } } = {}
local ColumnOffsets: { number } = {}
local MarkOffsets: { number } = {}
local MarkTops: { number } = {}
local MarkColors: { number } = {}

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
	local Grid = Paint.Grid
	local Line = Paint.Line
	local Shade = Paint.Shade
	local Keep = 1 - Shade
	local RowBytes = Width * 4

	local Heads, Nexts, Lefts, Rights, Colors = SegmentHeads, SegmentNexts, SegmentLefts, SegmentRights, SegmentColors
	for Row = 1, Height do
		Heads[Row] = 0
	end

	local CurveCount = #Curves
	local Reds, Greens, Blues, TopLists = CurveReds, CurveGreens, CurveBlues, CurveTops
	for Index = 1, CurveCount do
		local Curve = Curves[Index]
		Reds[Index] = Curve.Red * Shade
		Greens[Index] = Curve.Green * Shade
		Blues[Index] = Curve.Blue * Shade
		TopLists[Index] = Curve.Tops
	end

	local CardRed = bit32.band(Card, 255)
	local CardGreen = bit32.band(bit32.rshift(Card, 8), 255)
	local CardBlue = bit32.band(bit32.rshift(Card, 16), 255)

	local Segments = 0
	for Bin = 1, Count do
		local Reaching = Order[Bin]
		local Reached = #Reaching
		local X0: number, X1: number = Edges[Bin], Edges[Bin + 1]
		if Reached > 0 and X1 > X0 then
			local Red, Green, Blue = CardRed, CardGreen, CardBlue
			local Left = X0 * 4
			local Right = X1 * 4 - 4
			local Index = Reaching[1]
			local Y0: number = TopLists[Index][Bin]
			for Position = 1, Reached do
				Red = Red * Keep + Reds[Index]
				Green = Green * Keep + Greens[Index]
				Blue = Blue * Keep + Blues[Index]

				local Y1: number = Height
				if Position < Reached then
					Index = Reaching[Position + 1]
					Y1 = TopLists[Index][Bin]
				end

				if Y1 > Y0 then
					Segments += 1
					Lefts[Segments] = Left
					Rights[Segments] = Right
					Colors[Segments] = math.floor(Red + 0.5)
						+ math.floor(Green + 0.5) * 256
						+ math.floor(Blue + 0.5) * 65536
						+ OPAQUE
					Nexts[Segments] = Heads[Y0 + 1]
					Heads[Y0 + 1] = Segments
				end
				Y0 = Y1
			end
		end
	end

	local GridOffsets = ColumnOffsets
	local GridColumns = Paint.Columns
	for Column = 0, GridColumns - 1 do
		GridOffsets[Column + 1] = math.floor(Column / (GridColumns - 1) * (Width - 1)) * 4
	end

	local Markers = 0
	local MarkerOffsets, MarkerTops, MarkerColors = MarkOffsets, MarkTops, MarkColors
	for Index = 1, CurveCount do
		local Curve = Curves[Index]
		local Column = Curve.MarkerColumn
		if Column >= 0 and Column < Width then
			Markers += 1
			MarkerOffsets[Markers] = Column * 4
			MarkerTops[Markers] = Curve.MarkerTop
			MarkerColors[Markers] = Curve.MarkerColor
		end
	end

	Fill(Pixels, Width, 0, 0, Width, 1, Card)
	for Y = 0, Height - 1 do
		local Row = Y * RowBytes
		if Y > 0 then
			buffer.copy(Pixels, Row, Pixels, Row - RowBytes, RowBytes)
		end
		local Segment = Heads[Y + 1]
		while Segment ~= 0 do
			local Color = Colors[Segment]
			for At = Row + Lefts[Segment], Row + Rights[Segment], 4 do
				buffer.writeu32(Pixels, At, Color)
			end
			Segment = Nexts[Segment]
		end
		for Column = 1, GridColumns do
			buffer.writeu32(Pixels, Row + GridOffsets[Column], Grid)
		end
		for Marker = 1, Markers do
			if Y >= MarkerTops[Marker] then
				buffer.writeu32(Pixels, Row + MarkerOffsets[Marker], MarkerColors[Marker])
			end
		end
	end

	for Level = 0, Paint.Levels - 1 do
		local Y = math.floor((1 - Level / (Paint.Levels - 1)) * (Height - 1))
		Solid(Pixels, Width, Height, 0, Y, Width, Y + 1, Grid)
		if Y >= 0 and Y < Height then
			local Row = Y * RowBytes
			for Marker = 1, Markers do
				if Y >= MarkerTops[Marker] then
					buffer.writeu32(Pixels, Row + MarkerOffsets[Marker], MarkerColors[Marker])
				end
			end
		end
	end

	for Index = 1, CurveCount do
		local Curve = Curves[Index]
		local Tops = Curve.Tops
		local Color = Curve.Color
		local Previous = Height
		local Bin = 1
		while Bin <= Count do
			local Y: number = Tops[Bin]
			local Left = math.max(Edges[Bin], 0) * 4
			if Y ~= Previous then
				local Right = math.min(Edges[Bin] + Line, Width) * 4 - 4
				local Upper = math.max(math.min(Y, Previous), 0)
				local Lower = math.min(math.max(Y, Previous) + Line, Height)
				if Right - Left == 4 then
					for At = Upper * RowBytes + Left, (Lower - 1) * RowBytes + Left, RowBytes do
						buffer.writeu32(Pixels, At, Color)
						buffer.writeu32(Pixels, At + 4, Color)
					end
				else
					for Row = Upper * RowBytes, (Lower - 1) * RowBytes, RowBytes do
						for At = Row + Left, Row + Right, 4 do
							buffer.writeu32(Pixels, At, Color)
						end
					end
				end
			end
			if Y < Height then
				while Bin < Count and Tops[Bin + 1] == Y do
					Bin += 1
				end
				local Right = math.min(Edges[Bin + 1] + Line, Width) * 4 - 4
				local First = math.max(Y, 0)
				local Rows = math.min(Y + Line, Height) - First
				if Rows == 2 then
					for At = First * RowBytes + Left, First * RowBytes + Right, 4 do
						buffer.writeu32(Pixels, At, Color)
						buffer.writeu32(Pixels, At + RowBytes, Color)
					end
				else
					for Row = First * RowBytes, (First + Rows - 1) * RowBytes, RowBytes do
						for At = Row + Left, Row + Right, 4 do
							buffer.writeu32(Pixels, At, Color)
						end
					end
				end
			end
			Previous = Y
			Bin += 1
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
