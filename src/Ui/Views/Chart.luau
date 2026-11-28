--!strict
--!optimize 2

--[=[
	Chart: the chart card: the distribution plot, its axes and a MedianBar per case. Bars start at zero, so they are
	not on the plot's time axis. The listing keeps a leaving bar until it has faded away. The bar area keeps the
	height of the tallest run of the size on show, so stepping through runs never moves the plot, and the handle
	above it trades plot height for bar room. The height is saved when a drag ends, and a double click hands it back

	Return type: the Chart component
	Example usage:
		Chart({ state = state, rows = rows, size = UDim2.fromScale(1, 1) })
--]=]

local Flux = require("../../Packages/Flux")
local CaseRows = require("../CaseRows")
local Components = require("../Components")
local Format = require("../../Util/Format")
local Layout = require("../Layout")
local MedianBar = require("./MedianBar")
local Motion = require("../Motion")
local Plot = require("./Plot")
local Results = require("../../Core/Results")
local State = require("../State")

local new = Flux.new
local Text = Components.Text

type Row = CaseRows.Row
type Listing = MedianBar.Listing

local TICKS = 6
local TICKS_HEIGHT = 20
local TICK_WIDTH = 96
local Y_TICKS = 5
local Y_STEP = 0.16
local Y_AXIS_WIDTH = 52
local STACK_GAP = 6
local MEDIANS_TALLEST = 250
local MEDIANS_SHORTEST = 56
local PLOT_SHORTEST = 96
local REST_BELOW = 44
local SPLITTER_HEIGHT = 10
local GRIP_WIDTH = 36
local GRIP_HEIGHT = 4
local GRIP_IDLE = 0.4
local CAPTURE_SIZE = 4000
local SPLITTER_LAYER = 5
local DOUBLE_CLICK_SECONDS = 0.35

local function stackHeight(cases: { Results.CaseRecord }): number
	local total = 0
	for _, case in cases do
		total += MedianBar.slotHeight(case)
	end
	return total
end

local function Ticks(low: Flux.Spring<number>, high: Flux.Spring<number>): Frame
	local labels = {}
	for tick = 0, TICKS - 1 do
		local fraction = tick / (TICKS - 1)
		table.insert(
			labels,
			Text({
				text = function()
					return Format.Time(low() + (high() - low()) * fraction)
				end,
				tags = { "TextDim", "TextSmall" },
				AutomaticSize = Enum.AutomaticSize.None,
				Size = UDim2.fromOffset(TICK_WIDTH, TICKS_HEIGHT),
				TextXAlignment = if fraction == 0
					then Enum.TextXAlignment.Left
					elseif fraction == 1 then Enum.TextXAlignment.Right
					else Enum.TextXAlignment.Center,
				TextYAlignment = Enum.TextYAlignment.Top,
				AnchorPoint = Vector2.new(fraction, 0),
				Position = UDim2.fromScale(fraction, 0),
			})
		)
	end

	return new "Frame" {
		Name = "Ticks",
		Size = UDim2.new(1, 0, 0, TICKS_HEIGHT),
		labels,
	}
end

local function Shares(top: Flux.Spring<number>): Frame
	local labels = {}
	for step = 0, Y_TICKS - 1 do
		local fraction = step / (Y_TICKS - 1)
		table.insert(
			labels,
			Text({
				text = function()
					return string.format("%d%%", math.round(top() * fraction * fraction * 100))
				end,
				tags = { "TextDim", "TextSmall" },
				AnchorPoint = Vector2.new(1, 1 - fraction),
				Position = UDim2.new(1, -Layout.GapSmall, 1 - fraction, 0),
			})
		)
	end

	return new "Frame" {
		Name = "Shares",
		Size = UDim2.new(0, Y_AXIS_WIDTH, 1, 0),
		labels,
	}
end

local function Splitter(props: {
	isShown: Flux.Node<boolean>,
	onStart: () -> (),
	onDrag: (moved: number) -> (),
	onRelease: () -> (),
	onReset: () -> (),
}): TextButton
	local isHovered = Flux.signal(false)
	local isDragging = Flux.signal(false)
	local startY = 0
	local lastPressAt: number? = nil

	local grip = Motion.follow(function(): number
		return if isHovered() or isDragging() then 1 else GRIP_IDLE
	end, Motion.CHROME)

	local function release()
		if isDragging:peek() then
			isDragging(false)
			props.onRelease()
		end
	end

	return new "TextButton" {
		Name = "Splitter",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, SPLITTER_HEIGHT),
		ZIndex = SPLITTER_LAYER,
		Visible = props.isShown,

		MouseEnter = function()
			isHovered(true)
		end,
		MouseLeave = function()
			isHovered(false)
		end,
		MouseButton1Down = function(_x: number, y: number)
			local now = os.clock()
			if lastPressAt and now - lastPressAt < DOUBLE_CLICK_SECONDS then
				lastPressAt = nil
				props.onReset()
				return
			end

			lastPressAt = now
			startY = y
			props.onStart()
			isDragging(true)
		end,

		new "Frame" {
			Name = "Grip",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(GRIP_WIDTH, GRIP_HEIGHT),
			BackgroundTransparency = function()
				return 1 - grip()
			end,
			__TAG = { "Grip" },
		},

		new "TextButton" {
			Name = "Capture",
			Text = "",
			AutoButtonColor = false,
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(CAPTURE_SIZE, CAPTURE_SIZE),
			Visible = isDragging,

			MouseMoved = function(_x: number, y: number)
				props.onDrag(y - startY)
			end,
			MouseButton1Up = release,
			MouseLeave = release,
		},
	}
end

local function Chart(props: { state: State.State, rows: Flux.Node<{ Row }>, size: Flux.Reactive<UDim2> }): Frame
	local state = props.state
	local rows = props.rows

	local function bench(): string?
		return state.selectedPath()
	end

	local listing = Flux.signal({} :: { Listing })

	Flux.effect(function()
		local current = rows()
		local path = state.selectedPath()
		local previous = listing:peek()

		local isFresh = true
		for _, item in previous do
			if item.path == path and not item.isLeaving then
				isFresh = false
				break
			end
		end

		local slowest = 0
		for _, row in current do
			slowest = math.max(slowest, row.case.Stats.Median)
		end

		local listed: { Listing } = {}
		local isPresent: { [string]: boolean } = {}
		local top = 0
		for rank, row in current do
			local key = CaseRows.keyOf(path, row)
			isPresent[key] = true
			table.insert(listed, {
				key = key,
				path = path,
				row = row,
				top = top,
				slowest = slowest,
				isLeaving = false,
				delay = if isFresh then math.min((rank - 1) * Motion.STAGGER, Motion.LONGEST_STAGGER) else 0,
			})
			top += MedianBar.slotHeight(row.case)
		end

		for _, item in previous do
			if not isPresent[item.key] then
				table.insert(listed, {
					key = item.key,
					path = item.path,
					row = item.row,
					top = item.top,
					slowest = item.slowest,
					isLeaving = true,
					delay = 0,
				})
			end
		end
		listing(listed)
	end)

	local function forget(key: string)
		local kept: { Listing } = {}
		for _, item in listing:peek() do
			if item.key ~= key or not item.isLeaving then
				table.insert(kept, item)
			end
		end
		listing(kept)
	end

	local hasContent = Flux.computed(function(): boolean
		return #listing() > 0
	end)

	local shownRows = Flux.computed(function(): { Row }
		local ranked = rows()
		local picked = state.selectedCase()
		for _, row in ranked do
			if row.case.Name == picked then
				return { row }
			end
		end
		return ranked
	end)

	local reservedHeight = Flux.computed(function(): number
		local sizeIndex = state.sizeIndex()
		local tallest = 0
		for _, run in state.runs() do
			local size = run.Sizes[sizeIndex] or run.Sizes[1]
			if size then
				tallest = math.max(tallest, stackHeight(size.Cases))
			end
		end

		local cases: { Results.CaseRecord } = {}
		for index, row in rows() do
			cases[index] = row.case
		end
		return REST_BELOW + math.max(tallest, stackHeight(cases))
	end)

	local shownReserved = Motion.followWithin(bench, function(): number
		return reservedHeight()
	end, Motion.CHROME)

	local cardHeight = Flux.signal(0)
	local draggedHeight = Flux.signal(nil :: number?)
	local dragStartHeight = 0

	local function mostRoom(): number
		local beside = Layout.Inset * 2 + TICKS_HEIGHT + SPLITTER_HEIGHT + STACK_GAP * 3 + PLOT_SHORTEST
		return math.max(cardHeight() - beside, MEDIANS_SHORTEST)
	end

	local function barsRoom(): number
		local chosen = draggedHeight() or state.barsHeight()
		if chosen then
			return math.clamp(chosen, MEDIANS_SHORTEST, mostRoom())
		end
		return math.min(mostRoom(), MEDIANS_TALLEST)
	end

	local function barsHeight(): number
		return math.min(shownReserved(), barsRoom())
	end

	local low = Motion.followWithin(bench, function(): number
		local first = rows()[1]
		return if first then first.case.Histogram.Low else 0
	end, Motion.DATA)

	local high = Motion.followWithin(bench, function(): number
		local first = rows()[1]
		return if first then first.case.Histogram.High else 0
	end, Motion.DATA)

	local top = Flux.computed(function(): number
		local peak = 0
		for _, row in rows() do
			for _, share in row.case.Histogram.Bins do
				peak = math.max(peak, share)
			end
		end
		return math.clamp(math.ceil(peak / Y_STEP) * Y_STEP, Y_STEP, 1)
	end)

	local shownTop = Motion.followWithin(bench, function(): number
		return top()
	end, Motion.DATA)

	local hint = Motion.follow(function(): number
		return if hasContent() then 0 else 1
	end, Motion.CHROME)

	local card = Components.Card({
		Name = "Chart",
		Size = props.size,

		new "Frame" {
			Name = "Stack",
			Size = UDim2.fromScale(1, 1),

			Flux.list({ gap = STACK_GAP }),

			Text({
				text = function()
					return if state.selectedPath()
						then "Press Run to measure this bench."
						else "Create a bench with + to begin."
				end,
				tags = { "TextDim" },
				Visible = function()
					return not hasContent()
				end,
				TextTransparency = function()
					return 1 - hint()
				end,
			}),

			new "Frame" {
				Name = "Graph",
				Size = UDim2.fromScale(1, 0),
				Visible = hasContent,

				Flux.flex(),
				Flux.list({ direction = "x" }),

				Shares(shownTop),
				Plot({ rows = shownRows, top = top, bench = bench }),
			},

			new "Frame" {
				Name = "Times",
				Size = UDim2.new(1, 0, 0, TICKS_HEIGHT),
				Visible = hasContent,

				Flux.padding({ left = Y_AXIS_WIDTH }),
				Ticks(low, high),
			},

			Splitter({
				isShown = hasContent,
				onStart = function()
					dragStartHeight = barsHeight()
				end,
				onDrag = function(moved: number)
					draggedHeight(dragStartHeight - moved)
				end,
				onRelease = function()
					local dragged = draggedHeight:peek()
					draggedHeight:set(nil)
					if dragged then
						state.setBarsHeight(math.clamp(dragged, MEDIANS_SHORTEST, mostRoom()))
					end
				end,
				onReset = function()
					state.setBarsHeight(nil)
				end,
			}),

			Components.Scroller({
				Name = "Medians",
				AutomaticCanvasSize = Enum.AutomaticSize.None,
				CanvasSize = function()
					return UDim2.fromOffset(0, reservedHeight())
				end,
				Size = function()
					return UDim2.new(1, 0, 0, barsHeight())
				end,

				Flux.padding({ left = Y_AXIS_WIDTH }),

				Flux.forKey(listing, function(item: Listing)
					return item.key
				end, function(_index, item: Flux.Node<Listing>)
					return MedianBar.new({
						listing = item,
						isDimmed = function(): boolean
							local picked = state.selectedCase()
							return picked ~= nil and picked ~= item().row.case.Name
						end,
						onPick = state.showCase,
						onGone = forget,
					})
				end),
			}),
		},
	})

	local cardSize = Flux.property(card, "AbsoluteSize")
	Flux.effect(function()
		cardHeight(cardSize().Y)
	end)

	return card
end

return Chart
