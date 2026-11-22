--!strict
--!optimize 2

--[=[
	Services: what the panel needs from the plugin: the saved runs, the remembered round count, the Bench module to
	install into a place, and a way to open a script in the editor

	Return type: the Services module table
	Example usage:
		local PluginServices = Services.New(plugin, script.Bench)
--]=]

local Preferences = require("./Preferences")
local RunHistory = require("./RunHistory")

export type Services = {
	History: RunHistory.RunHistory,
	Preferences: Preferences.Preferences,
	BenchSource: ModuleScript,
	OpenScript: (Module: ModuleScript) -> (),
}

local Services = {}

function Services.New(Plugin: Plugin, BenchSource: ModuleScript): Services
	return {
		History = RunHistory.New(Plugin),
		Preferences = Preferences.New(Plugin),
		BenchSource = BenchSource,
		OpenScript = function(Module: ModuleScript)
			Plugin:OpenScript(Module)
		end,
	}
end

return Services
