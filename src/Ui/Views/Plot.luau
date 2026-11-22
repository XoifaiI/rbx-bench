--!strict
--- The plot area of the chart, drawn as pixels by PlotPixels and shown through EditableImage tiles of at most 1024
--- pixels a side. Hovering it names the cases with samples in the time bin under the pointer, the curve nearest the
--- pointer first.

local AssetService = game:GetService("AssetService")

local Flux = require("../../Packages/Flux")
local CreateInstance = require("../../Studio/CreateInstance")
local PlotPixels = require("../../Util/PlotPixels")
local CaseRows = require("../CaseRows")
local Style = require("../Style")
local Tooltip = require("../Tooltip")

local new = Flux.new

type Row = CaseRows.Row

type Tile = {
	x: number,
	width: number,
	pixels: buffer,
	image: EditableImage,
	label: ImageLabel,
}

type Canvas = {
	width: number,
	height: number,
	pixels: buffer,
	tiles: { Tile },
	rows: { Row },
	curves: { PlotPixels.Curve },
}

type Hit = {
	row: Row,
	distance: number,
}

local LONGEST_SIDE = 1024
local LINE = 3
local SHADE = 0.12
local MARKER_FADE = 0.55
local COLUMNS = 6
local LEVELS = 5
local HOVER_LEVEL = 1

local function packed(color: Color3): number
	return PlotPixels.Pack(math.round(color.R * 255), math.round(color.G * 255), math.round(color.B * 255))
end

local function clearTiles(canvas: Canvas)
	for _, tile in canvas.tiles do
		tile.label:Destroy()
		tile.image:Destroy()
	end
	table.clear(canvas.tiles)
end

local function resize(canvas: Canvas, holder: Frame, width: number, height: number)
	clearTiles(canvas)
	canvas.width = width
	canvas.height = height
	canvas.pixels = buffer.create(width * height * 4)

	local count = math.ceil(width / LONGEST_SIDE)
	local widest = math.ceil(width / count)
	for index = 1, count do
		local x = (index - 1) * widest
		local tileWidth = math.min(widest, width - x)
		local image = AssetService:CreateEditableImage({ Size = Vector2.new(tileWidth, height) })
		if not image then
			warn("[rbx-bench] Studio is out of memory for editable images, so part of the chart is left blank")
			continue
		end

		local label = CreateInstance.Create("ImageLabel", {
			BorderSizePixel = 0,
			ResampleMode = Enum.ResamplerMode.Pixelated,
			Position = UDim2.fromOffset(x, 0),
			Size = UDim2.new(0, tileWidth, 1, 0),
			ImageContent = Content.fromObject(image),
			Parent = holder,
		})

		table.insert(canvas.tiles, {
			x = x,
			width = tileWidth,
			pixels = buffer.create(tileWidth * height * 4),
			image = image,
			label = label,
		})
	end
end

local function curveOf(
	row: Row,
	top: number,
	width: number,
	height: number,
	card: Color3,
	isDark: boolean
): PlotPixels.Curve
	local histogram = row.case.Histogram
	local color = Style.seriesAt(row.colorIndex, isDark)

	local tops = table.create(#histogram.Bins, height)
	for bin, share in histogram.Bins do
		if share > 0 then
			tops[bin] = math.floor((1 - math.sqrt(share / top)) * (height - LINE))
		end
	end

	local range = math.max(histogram.High - histogram.Low, 1e-9)
	local reach = math.clamp((row.case.Stats.Median - histogram.Low) / range, 0, 1)
	local medianBin = math.clamp(math.floor(reach * #histogram.Bins) + 1, 1, #histogram.Bins)

	return {
		Red = math.round(color.R * 255),
		Green = math.round(color.G * 255),
		Blue = math.round(color.B * 255),
		Color = packed(color),
		MarkerColor = packed(color:Lerp(card, MARKER_FADE)),
		MarkerColumn = math.floor(reach * (width - 1)),
		MarkerTop = tops[medianBin],
		Tops = tops,
	}
end

local function describeAt(canvas: Canvas, holder: Frame, pointer: Vector2): Tooltip.Content?
	local first = canvas.rows[1]
	if not first or canvas.width < 1 then
		return nil
	end

	local count = #first.case.Histogram.Bins
	local at = pointer - holder.AbsolutePosition
	local bin = math.clamp(math.floor(at.X / canvas.width * count) + 1, 1, count)
	local y = at.Y * canvas.height / math.max(holder.AbsoluteSize.Y, 1)

	local hits: { Hit } = {}
	for index, row in canvas.rows do
		if row.case.Histogram.Bins[bin] > 0 then
			table.insert(hits, { row = row, distance = math.abs(canvas.curves[index].Tops[bin] - y) })
		end
	end
	table.sort(hits, function(nearer: Hit, further: Hit): boolean
		return nearer.distance < further.distance
	end)

	local nearest: { Row } = {}
	for position, hit in hits do
		nearest[position] = hit.row
	end
	return CaseRows.describeBin(nearest, bin)
end

local function Plot(props: { rows: Flux.Node<{ Row }>, top: Flux.Node<number> }): Frame
	local isDark = Style.dark:get()

	local holder = new "Frame" {
		Name = "Plot",
		Size = UDim2.fromScale(0, 1),
		ClipsDescendants = true,
		Flux.flex(),
	}

	local size = Flux.property(holder, "AbsoluteSize")
	local canvas: Canvas = { width = 0, height = 0, pixels = buffer.create(0), tiles = {}, rows = {}, curves = {} }

	Tooltip.track(holder, HOVER_LEVEL, function(pointer: Vector2)
		return describeAt(canvas, holder, pointer)
	end)

	Flux.cleanup(function()
		clearTiles(canvas)
	end)

	Flux.effect(function()
		local rows = props.rows()
		local top = props.top()
		local dark = Flux.read(isDark)
		local width = math.floor(size().X)
		local height = math.min(math.floor(size().Y), LONGEST_SIDE)
		if width < 1 or height <= LINE or #rows == 0 then
			canvas.rows = {}
			return
		end

		if width ~= canvas.width or height ~= canvas.height then
			resize(canvas, holder, width, height)
		end

		local card = Style.tokenAt("Card", dark)
		local curves: { PlotPixels.Curve } = {}
		for index, row in rows do
			curves[index] = curveOf(row, top, width, height, card, dark)
		end

		canvas.rows = rows
		canvas.curves = curves

		local count = #rows[1].case.Histogram.Bins
		local edges = table.create(count + 1, 0)
		for bin = 0, count do
			edges[bin + 1] = math.floor(bin / count * width)
		end

		PlotPixels.Draw(canvas.pixels, edges, curves, PlotPixels.Order(curves, count, height), width, height, {
			Card = packed(card),
			Grid = packed(Style.tokenAt("Line", dark)),
			Line = LINE,
			Shade = SHADE,
			Columns = COLUMNS,
			Levels = LEVELS,
		})

		for _, tile in canvas.tiles do
			PlotPixels.Split(tile.pixels, canvas.pixels, width, height, tile.x, tile.width)
			tile.image:WritePixelsBuffer(Vector2.zero, Vector2.new(tile.width, height), tile.pixels)
		end
	end)

	return holder
end

return Plot
