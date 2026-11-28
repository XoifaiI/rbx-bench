--!strict
--!optimize 2

--[=[
	Plot: the chart's plot area, drawn by PlotPixels into EditableImage tiles. One progress spring moves every
	trace from start to target, and traces are keyed by CaseRows.keyOf, so a new bench replaces its curves rather
	than morphing them. Pixel buffers match the image, not the plot, because WritePixelsBuffer takes exactly
	the size it writes; images grow in IMAGE_HEIGHT_STEP steps, so a height change alone allocates nothing

	Return type: the Plot component
	Example usage:
		Plot({ rows = shownRows, top = top, bench = bench })
--]=]

local AssetService = game:GetService("AssetService")

local Flux = require("../../Packages/Flux")
local CreateInstance = require("../../Studio/CreateInstance")
local PlotPixels = require("../../Util/PlotPixels")
local CaseRows = require("../CaseRows")
local Motion = require("../Motion")
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

type Trace = {
	key: string,
	isLeaving: boolean,
	start: PlotPixels.Curve,
	target: PlotPixels.Curve,
	frame: PlotPixels.Curve,
}

type Canvas = {
	width: number,
	height: number,
	imageHeight: number,
	pixels: buffer,
	tiles: { Tile },
	rows: { Row },
	top: number,
	bench: string?,
	traces: { Trace },
	frames: { PlotPixels.Curve },
	edges: { number },
	paint: PlotPixels.Paint?,
}

type Hit = {
	row: Row,
	distance: number,
}

local LONGEST_SIDE = 1024
local IMAGE_HEIGHT_STEP = 128
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

local function makeTiles(canvas: Canvas, holder: Frame, count: number, imageHeight: number)
	clearTiles(canvas)
	canvas.imageHeight = imageHeight
	for _ = 1, count do
		local image = AssetService:CreateEditableImage({ Size = Vector2.new(LONGEST_SIDE, imageHeight) })
		if not image then
			warn("[rbx-bench] Studio is out of memory for editable images, so part of the chart is left blank")
			continue
		end

		local label = CreateInstance.Create("ImageLabel", {
			BorderSizePixel = 0,
			ResampleMode = Enum.ResamplerMode.Pixelated,
			ImageContent = Content.fromObject(image),
			Parent = holder,
		})
		table.insert(canvas.tiles, { x = 0, width = 0, pixels = canvas.pixels, image = image, label = label })
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
			table.insert(hits, { row = row, distance = math.abs(canvas.traces[index].target.Tops[bin] - y) })
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

local function flatCurve(source: PlotPixels.Curve, height: number): PlotPixels.Curve
	local flat = table.clone(source)
	flat.Tops = table.create(#source.Tops, height)
	flat.MarkerTop = height
	return flat
end

local function rescaledY(y: number, fromHeight: number, toHeight: number): number
	if y >= fromHeight then
		return toHeight
	end
	return math.floor(y * (toHeight - LINE) / (fromHeight - LINE) + 0.5)
end

local function rescaled(
	curve: PlotPixels.Curve,
	fromWidth: number,
	fromHeight: number,
	toWidth: number,
	toHeight: number
): PlotPixels.Curve
	if fromWidth == toWidth and fromHeight == toHeight then
		return curve
	end

	local scaled = table.clone(curve)
	scaled.Tops = table.create(#curve.Tops, toHeight)
	for bin, y in curve.Tops do
		scaled.Tops[bin] = rescaledY(y, fromHeight, toHeight)
	end
	scaled.MarkerColumn = math.floor(curve.MarkerColumn * (toWidth - 1) / math.max(fromWidth - 1, 1) + 0.5)
	scaled.MarkerTop = rescaledY(curve.MarkerTop, fromHeight, toHeight)
	return scaled
end

local function frameOf(target: PlotPixels.Curve, height: number): PlotPixels.Curve
	local frame = table.clone(target)
	frame.Tops = table.create(#target.Tops, height)
	return frame
end

local function isSameShape(first: PlotPixels.Curve, second: PlotPixels.Curve): boolean
	if first.MarkerColumn ~= second.MarkerColumn or first.MarkerTop ~= second.MarkerTop then
		return false
	end
	if #first.Tops ~= #second.Tops then
		return false
	end
	for bin, top in first.Tops do
		if second.Tops[bin] ~= top then
			return false
		end
	end
	return true
end

@native
local function blend(
	start: PlotPixels.Curve,
	target: PlotPixels.Curve,
	into: PlotPixels.Curve,
	progress: number,
	height: number
)
	local startTops = start.Tops
	local intoTops = into.Tops
	for bin, goal in target.Tops do
		local was: number = startTops[bin] or height
		intoTops[bin] = math.floor(was + (goal - was) * progress + 0.5)
	end
	into.MarkerColumn = math.floor(start.MarkerColumn + (target.MarkerColumn - start.MarkerColumn) * progress + 0.5)
	into.MarkerTop = math.floor(start.MarkerTop + (target.MarkerTop - start.MarkerTop) * progress + 0.5)
end

local function edgesOf(traces: { Trace }, width: number): { number }
	local first = traces[1]
	local count = if first then math.max(#first.target.Tops, #first.start.Tops) else 0
	local edges = table.create(count + 1, 0)
	for bin = 0, count do
		edges[bin + 1] = math.floor(bin / math.max(count, 1) * width)
	end
	return edges
end

local function setTraces(canvas: Canvas, traces: { Trace })
	local frames: { PlotPixels.Curve } = {}
	for index, trace in traces do
		frames[index] = trace.frame
	end
	canvas.traces = traces
	canvas.frames = frames
	canvas.edges = edgesOf(traces, canvas.width)
end

local function fit(canvas: Canvas, holder: Frame, width: number, height: number)
	if width == canvas.width and height == canvas.height then
		return
	end
	local fromWidth = canvas.width
	local fromHeight = canvas.height
	canvas.width = width
	canvas.height = height

	local count = math.ceil(width / LONGEST_SIDE)
	local needsImages = count ~= #canvas.tiles or height > canvas.imageHeight
	if needsImages then
		local imageHeight = math.min(math.ceil(height / IMAGE_HEIGHT_STEP) * IMAGE_HEIGHT_STEP, LONGEST_SIDE)
		makeTiles(canvas, holder, count, imageHeight)
	end

	local needsBuffers = needsImages or width ~= fromWidth
	if needsBuffers then
		canvas.pixels = buffer.create(width * canvas.imageHeight * 4)
	end

	local widest = math.ceil(width / count)
	for index, tile in canvas.tiles do
		local x = (index - 1) * widest
		local tileWidth = math.min(widest, width - x)
		tile.x = x
		tile.width = tileWidth
		if needsBuffers then
			tile.pixels = if count == 1 then canvas.pixels else buffer.create(tileWidth * canvas.imageHeight * 4)
		end
		tile.label.Position = UDim2.fromOffset(x, 0)
		tile.label.Size = UDim2.new(0, tileWidth, 1, 0)
		tile.label.ImageRectOffset = Vector2.zero
		tile.label.ImageRectSize = Vector2.new(tileWidth, height)
	end

	for _, trace in canvas.traces do
		trace.start = rescaled(trace.start, fromWidth, fromHeight, width, height)
		trace.frame = rescaled(trace.frame, fromWidth, fromHeight, width, height)
	end
	setTraces(canvas, canvas.traces)
end

local function paintOf(isDark: boolean): PlotPixels.Paint
	return {
		Card = packed(Style.tokenAt("Card", isDark)),
		Grid = packed(Style.tokenAt("Line", isDark)),
		Line = LINE,
		Shade = SHADE,
		Columns = COLUMNS,
		Levels = LEVELS,
	}
end

local function retarget(canvas: Canvas, rows: { Row }, top: number, bench: string?, isDark: boolean): boolean
	local width = canvas.width
	local height = canvas.height

	local onScreen: { [string]: PlotPixels.Curve } = {}
	for _, trace in canvas.traces do
		onScreen[trace.key] = trace.frame
	end

	local card = Style.tokenAt("Card", isDark)
	local traces: { Trace } = {}
	local isMoving = false
	for index, row in rows do
		local key = CaseRows.keyOf(bench, row)
		local target = curveOf(row, top, width, height, card, isDark)
		local shown = onScreen[key]
		local start = if shown then shown else flatCurve(target, height)
		isMoving = isMoving or not shown or not isSameShape(shown, target)

		traces[index] =
			{ key = key, isLeaving = false, start = start, target = target, frame = frameOf(target, height) }
		onScreen[key] = nil
	end

	for _, trace in canvas.traces do
		local shown = onScreen[trace.key]
		if shown then
			local target = flatCurve(shown, height)
			table.insert(traces, {
				key = trace.key,
				isLeaving = true,
				start = shown,
				target = target,
				frame = frameOf(target, height),
			})
			isMoving = true
		end
	end

	canvas.rows = rows
	canvas.top = top
	canvas.bench = bench
	canvas.paint = paintOf(isDark)
	setTraces(canvas, traces)
	return isMoving
end

local function refreshTargets(canvas: Canvas, isDark: boolean)
	local card = Style.tokenAt("Card", isDark)
	for index, trace in canvas.traces do
		if trace.isLeaving then
			trace.target = flatCurve(trace.target, canvas.height)
		else
			trace.target = curveOf(canvas.rows[index], canvas.top, canvas.width, canvas.height, card, isDark)
		end
		trace.frame = frameOf(trace.target, canvas.height)
	end
	canvas.paint = paintOf(isDark)
	setTraces(canvas, canvas.traces)
end

local function dropLeaving(canvas: Canvas)
	local staying: { Trace } = {}
	for _, trace in canvas.traces do
		if not trace.isLeaving then
			table.insert(staying, trace)
		end
	end
	if #staying ~= #canvas.traces then
		setTraces(canvas, staying)
	end
end

local function draw(canvas: Canvas, progress: number)
	local paint = canvas.paint
	if not paint or #canvas.traces == 0 then
		return
	end

	local width = canvas.width
	local height = canvas.height
	local reached = math.min(progress, 1)
	for _, trace in canvas.traces do
		blend(trace.start, trace.target, trace.frame, reached, height)
	end

	local frames = canvas.frames
	local count = #canvas.edges - 1
	PlotPixels.Draw(canvas.pixels, canvas.edges, frames, PlotPixels.Order(frames, count, height), width, height, paint)

	for _, tile in canvas.tiles do
		if tile.pixels ~= canvas.pixels then
			PlotPixels.Split(tile.pixels, canvas.pixels, width, height, tile.x, tile.width)
		end
		tile.image:WritePixelsBuffer(Vector2.zero, Vector2.new(tile.width, canvas.imageHeight), tile.pixels)
	end
end

local function Plot(props: { rows: Flux.Node<{ Row }>, top: Flux.Node<number>, bench: () -> string? }): Frame
	local isDark = Style.dark:get()

	local holder = new "Frame" {
		Name = "Plot",
		Size = UDim2.fromScale(0, 1),
		ClipsDescendants = true,
		Flux.flex(),
	}

	local size = Flux.property(holder, "AbsoluteSize")
	local progress = Motion.spring(1, Motion.DATA)
	local canvas: Canvas = {
		width = 0,
		height = 0,
		imageHeight = 0,
		pixels = buffer.create(0),
		tiles = {},
		rows = {},
		top = 0,
		bench = nil,
		traces = {},
		frames = {},
		edges = {},
		paint = nil,
	}

	Tooltip.track(holder, HOVER_LEVEL, function(pointer: Vector2)
		return describeAt(canvas, holder, pointer)
	end)

	Flux.cleanup(function()
		clearTiles(canvas)
	end)

	Flux.effect(function()
		local rows = props.rows()
		local top = props.top()
		local bench = props.bench()
		local dark = Flux.read(isDark)
		local width = math.floor(size().X)
		local height = math.min(math.floor(size().Y), LONGEST_SIDE)
		if width < 1 or height <= LINE then
			return
		end

		fit(canvas, holder, width, height)
		if rows == canvas.rows and top == canvas.top and bench == canvas.bench then
			refreshTargets(canvas, dark)
		elseif retarget(canvas, rows, top, bench, dark) then
			Motion.restart(progress)
		else
			progress:snap(1)
		end
		draw(canvas, progress:peek())
	end)

	Flux.effect(function()
		local reached = progress()
		if reached >= 1 then
			dropLeaving(canvas)
		end
		draw(canvas, reached)
	end)

	return holder
end

return Plot
