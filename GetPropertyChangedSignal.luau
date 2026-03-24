local DEBUG = false

local function _log(...)
	if DEBUG then
		print("[GetPropertyChangedSignal]", ...)
	end
end

local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _connections = {} }, Signal)
end

function Signal:Connect(callback)
	assert(type(callback) == "function", "callback must be a function")
	local connection = {
		_callback   = callback,
		_connected  = true,
		_signal     = self,
	}
	function connection:Disconnect()
		self._connected = false
		local conns = self._signal._connections
		for i, c in ipairs(conns) do
			if c == self then
				table.remove(conns, i)
				break
			end
		end
	end
	table.insert(self._connections, connection)
	return connection
end

function Signal:Fire(...)
	for _, conn in ipairs(self._connections) do
		if conn._connected then
			conn._callback(...)
		end
	end
end

function Signal:Wait()
	local thread = coroutine.running()
	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		local ok, err = coroutine.resume(thread, ...)
		if not ok then warn("[Signal:Wait]", err) end
	end)
	return coroutine.yield()
end

function Signal:Once(callback)
	assert(type(callback) == "function", "callback must be a function")
	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		callback(...)
	end)
	return conn
end

local RunService  = game:GetService("RunService")
local Heartbeat   = RunService.Heartbeat

local _registry = {}
setmetatable(_registry, { __mode = "k" })

local function _getEntry(instance, property)
	if not _registry[instance] then
		_registry[instance] = {}
	end
	if not _registry[instance][property] then
		local ok, current = pcall(function() return instance[property] end)
		_registry[instance][property] = {
			signal    = Signal.new(),
			lastValue = ok and current or nil,
		}
	end
	return _registry[instance][property]
end

-- Poll loop
Heartbeat:Connect(function()
	for instance, props in pairs(_registry) do
		for property, entry in pairs(props) do
			local ok, current = pcall(function() return instance[property] end)
			if ok and current ~= entry.lastValue then
				_log(tostring(instance), property, entry.lastValue, "->", current)
				entry.lastValue = current
				entry.signal:Fire()
			end
		end
	end
end)

local function GetPropertyChangedSignal(instance, property)
	assert(typeof(instance) == "Instance", "first argument must be an Instance")
	assert(type(property) == "string" and #property > 0, "property must be a non-empty string")
	assert(pcall(function() return instance[property] end), "property does not exist: " .. property)

	local entry = _getEntry(instance, property)
	_log("Watching", tostring(instance), property)
	return entry.signal
end

local patched = pcall(function()
	local mt = getmetatable(game)
	if mt and mt.__index then
		local old = mt.__index
		mt.__index = function(self, key)
			if key == "GetPropertyChangedSignal" then
				return function(inst, prop)
					return GetPropertyChangedSignal(inst, prop)
				end
			end
			return old(self, key)
		end
	end
end)

if patched then
	_log("Successfully patched onto Instance metatable")
else
	_log("Metatable patch failed, use GetPropertyChangedSignal(instance, property) directly")
end

return GetPropertyChangedSignal
