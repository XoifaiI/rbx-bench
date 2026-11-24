--!strict
--!optimize 2

--[=[
	BenchFolder: the `rbx-bench` folder in ServerStorage, its bench files, and the copy a run uses. A bench runs from an
	unparented copy of the folder so every run requires fresh code, and Release destroys the copy. A module is found
	in a copy by the names on its path, so siblings that share a name cannot be told apart. Names ending in
	`.disabled` are left out

	Return type: the BenchFolder module table
	Example usage:
		local Entries = BenchFolder.List()
		local Loaded, Problem = BenchFolder.Load(Entries[1])
--]=]

local Bench = require("../Bench")
local CreateInstance = require("./CreateInstance")

local ServerStorage = game:GetService("ServerStorage")

export type Entry = {
	Path: string,
	Module: ModuleScript,
}

export type Loaded = {
	Suite: Bench.Suite<any>,
	Copy: Instance,
}

local FOLDER_NAME = "rbx-bench"
local BENCHES_NAME = "Benches"
local MODULE_NAME = "Bench"
local IMPORTS_NAME = "Imports"
local DISABLED_SUFFIX = ".disabled"

local BENCH_FILES =
	`> [Name = "{FOLDER_NAME}"] > [Name = "{BENCHES_NAME}"] >> ModuleScript:not(ModuleScript >> ModuleScript)`
local CHILD_MODULES = "> ModuleScript"
local PATH_START = #`{ServerStorage.Name}.{FOLDER_NAME}.{BENCHES_NAME}.` + 1

local TEMPLATE = [[
--!strict
local Bench = require("../Bench")

local Suite = Bench.Suite("%s", function(Size: number)
	return Size
end)

Suite:Case("first", function(Input)
	return Input
end)

return Suite
]]

local Create = CreateInstance.Create

local BenchFolder = {}

local function IsDisabled(Path: string): boolean
	return string.find(`{Path}.`, `{DISABLED_SUFFIX}.`, 1, true) ~= nil
end

local function FindInCopy(Module: Instance, Root: Instance, RootCopy: Instance): Instance?
	if Module == Root then
		return RootCopy
	end

	local Steps: { string } = {}
	local Current = Module
	while Current ~= Root do
		table.insert(Steps, 1, `> [Name = "{Current.Name}"]`)
		Current = Current.Parent :: Instance
	end

	local IsValid, Matches = pcall(RootCopy.QueryDescendants, RootCopy, table.concat(Steps, " "))
	return if IsValid and #Matches == 1 then Matches[1] else nil
end

local function PackageOf(Module: Instance): Instance
	local Parent = Module.Parent
	return if Parent and Parent ~= game and Parent.Parent ~= game then PackageOf(Parent) else Module
end

local function NewHost(Copy: Instance, Problems: { string }): Bench.Host
	local Imports = Create("Folder", { Name = IMPORTS_NAME, Parent = Copy })
	local Copies: { [Instance]: Instance } = {}

	local function Refuse(Problem: string): never
		table.insert(Problems, Problem)
		error(Problem, 0)
	end

	local function Import(Module: unknown): any
		if typeof(Module) ~= "Instance" or not Module:IsA("ModuleScript") then
			return Refuse(`Bench.Import needs a ModuleScript, but was given {typeof(Module)}`)
		end
		if Module:IsDescendantOf(Copy) then
			return (require :: any)(Module)
		end

		local Package = PackageOf(Module)
		local PackageCopy = Copies[Package]
		if not PackageCopy then
			PackageCopy = Package:Clone()
			if not PackageCopy then
				return Refuse(`Bench.Import cannot copy {Package:GetFullName()} because it is not Archivable`)
			end
			PackageCopy.Parent = Imports
			Copies[Package] = PackageCopy
		end

		local InCopy = FindInCopy(Module, Package, PackageCopy)
		if not InCopy then
			return Refuse(
				`Bench.Import cannot find {Module:GetFullName()} in its copy; it or a parent is not Archivable, shares `
					.. `its name with a sibling, or has a quote in its name`
			)
		end
		return (require :: any)(InCopy)
	end

	local function Modules(Parent: unknown): { Bench.Module }
		if typeof(Parent) ~= "Instance" then
			return Refuse(`Bench.Modules needs an Instance to look inside, but was given {typeof(Parent)}`)
		end

		local Found: { Bench.Module } = {}
		for _, Child in Parent:QueryDescendants(CHILD_MODULES) do
			if IsDisabled(Child.Name) then
				continue
			end

			local IsRequired, Value = pcall(Import, Child)
			if not IsRequired then
				return Refuse(`the module "{Child.Name}" could not be required; the Output window has its error`)
			end
			table.insert(Found, { Name = Child.Name, Value = Value })
		end
		table.sort(Found, function(First: Bench.Module, Second: Bench.Module): boolean
			return First.Name < Second.Name
		end)
		return Found
	end

	return { Import = Import, Modules = Modules }
end

function BenchFolder.Ensure(Source: ModuleScript): Instance
	local Folder = ServerStorage:FindFirstChild(FOLDER_NAME)
		or Create("Folder", { Name = FOLDER_NAME, Parent = ServerStorage })

	local Installed = Folder:FindFirstChild(MODULE_NAME)
	if not Installed then
		local Copy = Source:Clone()
		Copy.Name = MODULE_NAME
		Copy.Parent = Folder
	elseif Installed:IsA("ModuleScript") and Installed.Source ~= Source.Source then
		Installed.Source = Source.Source
	end

	return Folder:FindFirstChild(BENCHES_NAME) or Create("Folder", { Name = BENCHES_NAME, Parent = Folder })
end

function BenchFolder.List(): { Entry }
	local Entries: { Entry } = {}
	for _, Module in ServerStorage:QueryDescendants(BENCH_FILES) do
		local Path = string.sub(Module:GetFullName(), PATH_START)
		if Module:IsA("ModuleScript") and not IsDisabled(Path) then
			table.insert(Entries, { Path = Path, Module = Module })
		end
	end

	table.sort(Entries, function(First: Entry, Second: Entry): boolean
		return First.Path < Second.Path
	end)
	return Entries
end

function BenchFolder.Create(Source: ModuleScript): Entry
	local Benches = BenchFolder.Ensure(Source)

	local Name = "bench"
	local Suffix = 1
	while Benches:FindFirstChild(Name) do
		Suffix += 1
		Name = `bench{Suffix}`
	end

	local Module = Create("ModuleScript", {
		Name = Name,
		Source = string.format(TEMPLATE, Name),
		Parent = Benches,
	})
	return { Path = Name, Module = Module }
end

function BenchFolder.Load(Entry: Entry): (Loaded?, string?)
	local Folder = ServerStorage:FindFirstChild(FOLDER_NAME)
	if not Folder or not Entry.Module:IsDescendantOf(Folder) then
		return nil, `{Entry.Path} is no longer inside ServerStorage.{FOLDER_NAME}; refresh the list and pick it again`
	end

	local Copy = Folder:Clone()
	local Module = FindInCopy(Entry.Module, Folder, Copy)
	if not Module then
		Copy:Destroy()
		return nil,
			`{Entry.Path} cannot be found in the copy a run uses; it or a parent is not Archivable, shares its name `
				.. `with a sibling, or has a quote in its name`
	end

	local Problems: { string } = {}
	local Installed = Copy:FindFirstChild(MODULE_NAME)
	if Installed and Installed:IsA("ModuleScript") then
		local IsRequired, Installation = pcall(require, Installed)
		if IsRequired and type(Installation) == "table" then
			Installation.Host = NewHost(Copy, Problems)
		end
	end

	local Succeeded, Result = pcall(require, Module)
	if not Succeeded then
		Copy:Destroy()
		local Reason = if #Problems > 0 then table.concat(Problems, "\n") else tostring(Result)
		return nil, `{Entry.Path} could not be required: {Reason}`
	end

	if type(Result) ~= "table" or Result.Kind ~= "BenchSuite" then
		Copy:Destroy()
		return nil, `{Entry.Path} must return the suite made by Bench.Suite, but returned {typeof(Result)}`
	end

	if Result.FormatVersion > Bench.FormatVersion then
		Copy:Destroy()
		return nil,
			`{Entry.Path} was written for a newer Bench module ({Result.FormatVersion}); update the plugin to run it`
	end

	return { Suite = Result, Copy = Copy }, nil
end

function BenchFolder.Release(Loaded: Loaded): ()
	Loaded.Copy:Destroy()
end

return BenchFolder
