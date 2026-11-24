--!strict
--!optimize 2

--[=[
	CreateInstance: builds one Instance from its class name and a table of properties, typed off the class name so a
	wrong property or value is a type error. Instances lists only the classes this plugin creates

	Return type: the CreateInstance module table
	Example usage:
		local Folder = CreateInstance.Create("Folder", { Name = "Benches", Parent = ServerStorage })
--]=]

type Instances = {
	Folder: Folder,
	ModuleScript: ModuleScript,
	BindableFunction: BindableFunction,
	ImageLabel: ImageLabel,
	StyleSheet: StyleSheet,
	StyleRule: StyleRule,
	StyleLink: StyleLink,
}

type function ExportProperties(Class: type): type
	if not Class:is("singleton") then
		return types.never
	end

	local RobloxClass = Instances:readproperty(Class)
	if not RobloxClass then
		return types.never
	end

	local function IsCallable(Value: type): boolean
		if Value:is("function") then
			return true
		end
		if Value:is("intersection") then
			for _, Part in Value:components() do
				if Part:is("function") then
					return true
				end
			end
		end
		return false
	end

	local Properties: { [type]: { read: type?, write: type? } } = {}

	local Current = RobloxClass
	while Current do
		for Key, Property in Current:properties() do
			local Value = Property.write
			if Value and not IsCallable(Value) then
				if not (Value:is("table") and Value:readproperty(types.singleton("Connect"))) then
					Properties[Key] = { read = types.optional(Value) }
				end
			end
		end
		Current = Current:readparent()
	end

	return types.newtable(Properties)
end

type function ToClass(Class: type): type
	if not Class:is("singleton") then
		return types.never
	end

	return Instances:readproperty(Class) or types.never
end

type ClassNames = keyof<Instances>

local CreateInstance = {}

function CreateInstance.Create<T>(ClassName: ClassNames & T, Properties: ExportProperties<T>?): ToClass<T>
	local Object: Instance = Instance.new(ClassName :: any)

	if Properties then
		for Key, Value in Properties :: { [string]: any } do
			(Object :: any)[Key] = Value
		end
	end

	return Object :: any
end

return CreateInstance
