--!strict
--!optimize 2

--[=[
	rbx-bench: the plugin's entry. It makes the toolbar button and the dock widget, then hands the widget to the panel. It
	does nothing while the game is running. A build with the `dev` attribute lets the panel add its `Debug` hook

	Return type: none, this is the plugin's script
	Example usage:
		rojo build dev.project.json -o Bench.rbxm
--]=]

local RunService = game:GetService("RunService")

if RunService:IsRunning() then
	return
end

local Dock = require("@self/Ui/Dock")
local Services = require("@self/Studio/Services")

local WIDGET_INFO = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Bottom, false, false, 900, 320, 480, 280)

local Toolbar = plugin:CreateToolbar("rbx-bench")
local Toggle = Toolbar:CreateButton("rbx-bench", "Show or hide the benchmark panel", "")
Toggle.ClickableWhenViewportHidden = true

local Widget = plugin:CreateDockWidgetPluginGuiAsync("BenchPanel", WIDGET_INFO)
Widget.Name = "rbx-bench"
Widget.Title = "rbx-bench"
Widget.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

local BenchSource = script:FindFirstChild("Bench") :: ModuleScript
local Undock = Dock(Widget, Services.New(plugin, BenchSource), script:GetAttribute("dev") == true)

local Connections = {
	Toggle.Click:Connect(function()
		Widget.Enabled = not Widget.Enabled
	end),

	Widget:GetPropertyChangedSignal("Enabled"):Connect(function()
		Toggle:SetActive(Widget.Enabled)
	end),
}

Toggle:SetActive(Widget.Enabled)

plugin.Unloading:Connect(function()
	for _, Connection in Connections do
		Connection:Disconnect()
	end
	Undock()
end)
