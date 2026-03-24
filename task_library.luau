local DEBUG = false

local RunService = game:GetService("RunService")
local Heartbeat = RunService.Heartbeat

local _cancelled = {}
local _parallel = {}

local function _safeResume(thread, ...)
	if _cancelled[thread] then
		_cancelled[thread] = nil
		return
	end
	local ok, err = coroutine.resume(thread, ...)
	if not ok then
		if DEBUG then
			warn("[task] " .. tostring(err))
		end
	end
end

local function _toThread(f, ...)
	if type(f) == "thread" then
		return f, ...
	end
	local args = { ... }
	return coroutine.create(function()
		f(table.unpack(args))
	end)
end

local function _yieldUntilNextHeartbeat()
	local thread = coroutine.running()
	local conn
	conn = Heartbeat:Connect(function()
		conn:Disconnect()
		_safeResume(thread)
	end)
	coroutine.yield()
end

local function spawn(functionOrThread, ...)
	local thread, a, b, c, d, e = _toThread(functionOrThread, ...)
	_safeResume(thread, a, b, c, d, e)
	return thread
end

local function defer(functionOrThread, ...)
	local thread, a, b, c, d, e = _toThread(functionOrThread, ...)
	local conn
	conn = Heartbeat:Connect(function()
		conn:Disconnect()
		_safeResume(thread, a, b, c, d, e)
	end)
	return thread
end

local function delay(duration, functionOrThread, ...)
	duration = tonumber(duration) or 0
	local thread, a, b, c, d, e = _toThread(functionOrThread, ...)
	local elapsed = 0
	local conn
	conn = Heartbeat:Connect(function(dt)
		elapsed = elapsed + dt
		if elapsed >= duration then
			conn:Disconnect()
			_safeResume(thread, a, b, c, d, e)
		end
	end)
	return thread
end

local function wait(duration)
	duration = tonumber(duration) or 0
	local thread = coroutine.running()
	local elapsed = 0
	local conn
	conn = Heartbeat:Connect(function(dt)
		elapsed = elapsed + dt
		if elapsed >= duration then
			conn:Disconnect()
			_safeResume(thread, elapsed)
		end
	end)
	return coroutine.yield()
end

local function cancel(thread)
	if coroutine.close then
		pcall(coroutine.close, thread)
	else
		_cancelled[thread] = true
	end
end

local function desynchronize()
	local thread = coroutine.running()
	if not thread or _parallel[thread] then return end
	_parallel[thread] = true
	_yieldUntilNextHeartbeat()
end

local function synchronize()
	local thread = coroutine.running()
	if not thread or not _parallel[thread] then return end
	_parallel[thread] = nil
	_yieldUntilNextHeartbeat()
end

return {
	spawn         = spawn,
	defer         = defer,
	delay         = delay,
	wait          = wait,
	cancel        = cancel,
	desynchronize = desynchronize,
	synchronize   = synchronize,
}
