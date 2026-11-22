--!strict
--!optimize 2

--[=[
	Bench: what a bench file requires. It describes a suite (cases, sizes, spans, rules, metrics, hooks) and the Bench
	plugin measures it. Times are nanoseconds per call. Import and Modules only work while the plugin runs the bench

	Return type: the Bench module table
	Example usage:
		local Suite = Bench.Suite("sum", function(Size: number)
			return table.create(Size, 1)
		end)
		Suite:Case("loop", Sum):Baseline()
		return Suite
--]=]

local FORMAT_VERSION = 1

export type Stats = {
	Min: number,
	Median: number,
	Mean: number,
	P90: number,
	Low: number,
	High: number,
	Spread: number,
	Samples: { number },
	Bytes: number,
}

export type Comparison = {
	Ratio: number,
	Low: number,
	High: number,
	Significant: boolean,
}

export type SpanStats = {
	Time: number,
	Count: number,
	Share: number,
}

export type Recorder = {
	Enabled: boolean,
	Current: number,
	Parents: { number },
	Spans: { number },
	Seconds: { number },
	Counts: { number },
	Children: { { [number]: number } },
}

export type Span = {
	Name: string,
	Index: number,
	Recorder: Recorder,
	Start: (self: Span) -> number,
	Stop: (self: Span, Mark: number) -> (),
}

export type Case<Input> = {
	Name: string,
	Run: (Input: Input) -> any,
	IsBaseline: boolean,
	IsSkipped: boolean,
	Baseline: (self: Case<Input>) -> Case<Input>,
	Skip: (self: Case<Input>) -> Case<Input>,
}

export type Run = {
	Size: number,
	Noise: number,
	Cases: { Case<any> },
	Previous: Run?,
	Of: (self: Run, Case: Case<any>) -> Stats,
	Compare: (self: Run, First: Case<any>, Second: Case<any>) -> Comparison,
	Span: (self: Run, Case: Case<any>, Span: Span) -> SpanStats,
}

export type Rule = {
	Name: string,
	Check: (Run: Run) -> (boolean, ...string),
}

export type Metric = {
	Name: string,
	Compute: (Run: Run, Case: Case<any>) -> number,
}

export type Hooks<Input> = {
	BeforeAll: (() -> ())?,
	AfterAll: (() -> ())?,
	BeforeEach: ((Case: Case<Input>, Size: number) -> ())?,
	AfterEach: ((Case: Case<Input>, Size: number) -> ())?,
}

export type Module = {
	Name: string,
	Value: any,
}

export type Host = {
	Import: (Module: unknown) -> any,
	Modules: (Parent: unknown) -> { Module },
}

export type Suite<Input> = {
	Kind: "BenchSuite",
	FormatVersion: number,
	Name: string,
	Input: (Size: number) -> Input,
	SizeList: { number },
	SizeLabel: ((Size: number) -> string)?,
	IsFresh: boolean,
	Hooks: Hooks<Input>,
	Cases: { Case<Input> },
	Spans: { Span },
	Rules: { Rule },
	Metrics: { Metric },
	Recorder: Recorder,

	Sizes: (self: Suite<Input>, Sizes: { number }) -> Suite<Input>,
	Label: (self: Suite<Input>, Describe: (Size: number) -> string) -> Suite<Input>,
	Fresh: (self: Suite<Input>) -> Suite<Input>,
	BeforeAll: (self: Suite<Input>, Hook: () -> ()) -> Suite<Input>,
	AfterAll: (self: Suite<Input>, Hook: () -> ()) -> Suite<Input>,
	BeforeEach: (self: Suite<Input>, Hook: (Case: Case<Input>, Size: number) -> ()) -> Suite<Input>,
	AfterEach: (self: Suite<Input>, Hook: (Case: Case<Input>, Size: number) -> ()) -> Suite<Input>,
	Case: (self: Suite<Input>, Name: string, Run: (Input: Input) -> any) -> Case<Input>,
	Span: (self: Suite<Input>, Name: string) -> Span,
	Rule: (self: Suite<Input>, Name: string, Check: (Run: Run) -> (boolean, ...string)) -> (),
	Metric: (self: Suite<Input>, Name: string, Compute: (Run: Run, Case: Case<any>) -> number) -> (),
}

local Clock = os.clock

local function AddNode(Recorder: Recorder, SpanIndex: number): number
	local Node = #Recorder.Parents + 1
	Recorder.Parents[Node] = Recorder.Current
	Recorder.Spans[Node] = SpanIndex
	Recorder.Seconds[Node] = 0
	Recorder.Counts[Node] = 0
	Recorder.Children[Node] = {}
	Recorder.Children[Recorder.Current][SpanIndex] = Node
	return Node
end

local function StartSpan(self: Span): number
	local Recorder = self.Recorder
	if not Recorder.Enabled then
		return 0
	end

	Recorder.Current = Recorder.Children[Recorder.Current][self.Index] or AddNode(Recorder, self.Index)
	return Clock()
end

local function StopSpan(self: Span, Mark: number)
	local Recorder = self.Recorder
	if not Recorder.Enabled then
		return
	end

	local Elapsed = Clock() - Mark
	local Node = Recorder.Current
	Recorder.Seconds[Node] += Elapsed
	Recorder.Counts[Node] += 1
	Recorder.Current = Recorder.Parents[Node]
end

local function MarkBaseline(self: Case<any>): Case<any>
	self.IsBaseline = true
	return self
end

local function MarkSkipped(self: Case<any>): Case<any>
	self.IsSkipped = true
	return self
end

local function SetSizes(self: Suite<any>, Sizes: { number }): Suite<any>
	assert(#Sizes > 0, "Suite:Sizes needs at least one size; leave the call out to run once with size 1")
	self.SizeList = table.clone(Sizes)
	return self
end

local function SetLabel(self: Suite<any>, Describe: (Size: number) -> string): Suite<any>
	self.SizeLabel = Describe
	return self
end

local function SetFresh(self: Suite<any>): Suite<any>
	self.IsFresh = true
	return self
end

local function SetBeforeAll(self: Suite<any>, Hook: () -> ()): Suite<any>
	assert(not self.Hooks.BeforeAll, `suite "{self.Name}" already has a BeforeAll; put both in one function`)
	self.Hooks.BeforeAll = Hook
	return self
end

local function SetAfterAll(self: Suite<any>, Hook: () -> ()): Suite<any>
	assert(not self.Hooks.AfterAll, `suite "{self.Name}" already has an AfterAll; put both in one function`)
	self.Hooks.AfterAll = Hook
	return self
end

local function SetBeforeEach(self: Suite<any>, Hook: (Case: Case<any>, Size: number) -> ()): Suite<any>
	assert(not self.Hooks.BeforeEach, `suite "{self.Name}" already has a BeforeEach; put both in one function`)
	self.Hooks.BeforeEach = Hook
	return self
end

local function SetAfterEach(self: Suite<any>, Hook: (Case: Case<any>, Size: number) -> ()): Suite<any>
	assert(not self.Hooks.AfterEach, `suite "{self.Name}" already has an AfterEach; put both in one function`)
	self.Hooks.AfterEach = Hook
	return self
end

local function AddCase(self: Suite<any>, Name: string, Run: (Input: any) -> any): Case<any>
	for _, Existing in self.Cases do
		assert(
			Existing.Name ~= Name,
			`suite "{self.Name}" already has a case named "{Name}"; give each case its own name`
		)
	end

	local Case: Case<any> = {
		Name = Name,
		Run = Run,
		IsBaseline = false,
		IsSkipped = false,
		Baseline = MarkBaseline,
		Skip = MarkSkipped,
	}
	table.insert(self.Cases, Case)
	return Case
end

local function AddSpan(self: Suite<any>, Name: string): Span
	local Span: Span = {
		Name = Name,
		Index = #self.Spans + 1,
		Recorder = self.Recorder,
		Start = StartSpan,
		Stop = StopSpan,
	}
	table.insert(self.Spans, Span)
	return Span
end

local function AddRule(self: Suite<any>, Name: string, Check: (Run: Run) -> (boolean, ...string))
	table.insert(self.Rules, { Name = Name, Check = Check })
end

local function AddMetric(self: Suite<any>, Name: string, Compute: (Run: Run, Case: Case<any>) -> number)
	table.insert(self.Metrics, { Name = Name, Compute = Compute })
end

local Bench = {
	FormatVersion = FORMAT_VERSION,
	Host = nil :: Host?,
}

local function HostFor(Call: string): Host
	local Host = Bench.Host
	if not Host then
		error(`Bench.{Call} only works while the rbx-bench plugin is running the bench`, 3)
	end
	return Host
end

function Bench.Import(Module: unknown): any
	return HostFor("Import").Import(Module)
end

function Bench.Modules(Parent: unknown): { Module }
	return HostFor("Modules").Modules(Parent)
end

function Bench.Suite<Input>(Name: string, Input: (Size: number) -> Input): Suite<Input>
	local Suite: Suite<Input> = {
		Kind = "BenchSuite",
		FormatVersion = FORMAT_VERSION,
		Name = Name,
		Input = Input,
		SizeList = { 1 },
		SizeLabel = nil,
		IsFresh = false,
		Hooks = {},
		Cases = {},
		Spans = {},
		Rules = {},
		Metrics = {},
		Recorder = {
			Enabled = false,
			Current = 1,
			Parents = { 1 },
			Spans = { 0 },
			Seconds = { 0 },
			Counts = { 0 },
			Children = { {} },
		},

		Sizes = SetSizes,
		Label = SetLabel,
		Fresh = SetFresh,
		BeforeAll = SetBeforeAll,
		AfterAll = SetAfterAll,
		BeforeEach = SetBeforeEach,
		AfterEach = SetAfterEach,
		Case = AddCase,
		Span = AddSpan,
		Rule = AddRule,
		Metric = AddMetric,
	}
	return Suite
end

return Bench
