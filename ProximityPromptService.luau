local DEBUG = false

assert(game:GetService("RunService"):IsClient(), "[ProximityPromptService] Must be required from Client")

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local function _log(...)
	if DEBUG then
		print("[ProximityPromptService]", ...)
	end
end

local function _warn(...)
	warn("[ProximityPromptService]", ...)
	if DEBUG then
		print("[ProximityPromptService]", ...)
	end
end

local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _connections = {} }, Signal)
end

function Signal:Connect(callback)
	assert(type(callback) == "function", "callback must be a function")
	local conn = { _callback = callback, _connected = true, _signal = self }
	function conn:Disconnect()
		self._connected = false
		for i, c in ipairs(self._signal._connections) do
			if c == self then table.remove(self._signal._connections, i) break end
		end
	end
	table.insert(self._connections, conn)
	return conn
end

function Signal:Fire(...)
	for _, conn in ipairs(self._connections) do
		if conn._connected then
			local ok, err = pcall(conn._callback, ...)
			if not ok then _warn("Signal error:", err) end
		end
	end
end

function Signal:Wait()
	local thread = coroutine.running()
	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		coroutine.resume(thread, ...)
	end)
	return coroutine.yield()
end

function Signal:Once(callback)
	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		callback(...)
	end)
	return conn
end

local ProximityPromptService = {}

-- Properties
ProximityPromptService.Enabled           = true
ProximityPromptService.MaxPromptsVisible = 10
ProximityPromptService.MaxIndicatorsVisible = 10

-- Events
ProximityPromptService.PromptTriggered       = Signal.new()
ProximityPromptService.PromptTriggerEnded    = Signal.new()
ProximityPromptService.PromptButtonHoldBegan = Signal.new()
ProximityPromptService.PromptButtonHoldEnded = Signal.new()
ProximityPromptService.PromptShown           = Signal.new()
ProximityPromptService.PromptHidden          = Signal.new()
ProximityPromptService.IndicatorShown        = Signal.new()
ProximityPromptService.IndicatorHidden       = Signal.new()

local _prompts = {}
local _holdState = {}
local _visiblePrompts = {}
local _indicators = {} 

local function _isPrompt(obj)
	return typeof(obj) == "Instance" and obj.ClassName == "ProximityPrompt"
end

local function _getDistance(player, prompt)
	local char = player.Character
	if not char then return math.huge end
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then return math.huge end
	local part = prompt.Parent
	if not part or not part:IsA("BasePart") then return math.huge end
	return (root.Position - part.Position).Magnitude
end

local function _isVisible(prompt)
	if not ProximityPromptService.Enabled then return false end
	if not prompt.Enabled then return false end
	local part = prompt.Parent
	return part and part:IsA("BasePart")
end

local function _registerPrompt(prompt)
	if _prompts[prompt] then return end
	_prompts[prompt] = true
	_holdState[prompt] = {}
	_log("Registered prompt:", prompt:GetFullName())

	prompt.Triggered:Connect(function(player)
		if not ProximityPromptService.Enabled then return end
		_log("PromptTriggered:", prompt:GetFullName(), player.Name)
		ProximityPromptService.PromptTriggered:Fire(prompt, player)
	end)

	prompt.PromptButtonHoldBegan:Connect(function(player)
		if not ProximityPromptService.Enabled then return end
		_holdState[prompt][player] = true
		_log("PromptButtonHoldBegan:", prompt:GetFullName(), player.Name)
		ProximityPromptService.PromptButtonHoldBegan:Fire(prompt, player)
	end)

	prompt.PromptButtonHoldEnded:Connect(function(player)
		if not ProximityPromptService.Enabled then return end
		_holdState[prompt][player] = nil
		_log("PromptButtonHoldEnded:", prompt:GetFullName(), player.Name)
		ProximityPromptService.PromptButtonHoldEnded:Fire(prompt, player)
	end)

	prompt.TriggerEnded:Connect(function(player)
		if not ProximityPromptService.Enabled then return end
		_log("PromptTriggerEnded:", prompt:GetFullName(), player.Name)
		ProximityPromptService.PromptTriggerEnded:Fire(prompt, player)
	end)

	prompt.AncestryChanged:Connect(function()
		if not prompt:IsDescendantOf(game) then
			_prompts[prompt] = nil
			_holdState[prompt] = nil
			if _visiblePrompts[prompt] then
				_visiblePrompts[prompt] = nil
				ProximityPromptService.PromptHidden:Fire(prompt)
				ProximityPromptService.IndicatorHidden:Fire(prompt)
			end
			_log("Unregistered prompt:", tostring(prompt))
		end
	end)
end

local function _scanDescendants(root)
	for _, obj in ipairs(root:GetDescendants()) do
		if _isPrompt(obj) then
			_registerPrompt(obj)
		end
	end
end

_scanDescendants(game)

game.DescendantAdded:Connect(function(obj)
	if _isPrompt(obj) then
		_registerPrompt(obj)
	end
end)

RunService.Heartbeat:Connect(function()
	if not ProximityPromptService.Enabled then
		for prompt in pairs(_visiblePrompts) do
			_visiblePrompts[prompt] = nil
			ProximityPromptService.PromptHidden:Fire(prompt)
			ProximityPromptService.IndicatorHidden:Fire(prompt)
		end
		return
	end

	local players = Players:GetPlayers()
	local visibleCount = 0

	for prompt in pairs(_prompts) do
		if not _isVisible(prompt) then
			if _visiblePrompts[prompt] then
				_visiblePrompts[prompt] = nil
				ProximityPromptService.PromptHidden:Fire(prompt)
				ProximityPromptService.IndicatorHidden:Fire(prompt)
				_log("PromptHidden:", prompt:GetFullName())
			end
			continue
		end

		local inRange = false
		for _, player in ipairs(players) do
			if _getDistance(player, prompt) <= prompt.MaxActivationDistance then
				inRange = true
				break
			end
		end

		if inRange and visibleCount < ProximityPromptService.MaxPromptsVisible then
			if not _visiblePrompts[prompt] then
				_visiblePrompts[prompt] = true
				visibleCount = visibleCount + 1
				ProximityPromptService.PromptShown:Fire(prompt, Enum.ProximityPromptInputType.Keyboard)
				ProximityPromptService.IndicatorShown:Fire(prompt)
				_log("PromptShown:", prompt:GetFullName())
			else
				visibleCount = visibleCount + 1
			end
		else
			if _visiblePrompts[prompt] then
				_visiblePrompts[prompt] = nil
				ProximityPromptService.PromptHidden:Fire(prompt)
				ProximityPromptService.IndicatorHidden:Fire(prompt)
				_log("PromptHidden (out of range):", prompt:GetFullName())
			end
		end
	end
end)


function ProximityPromptService:GetPrompts()
	local result = {}
	for prompt in pairs(_prompts) do
		table.insert(result, prompt)
	end
	return result
end

return ProximityPromptService
