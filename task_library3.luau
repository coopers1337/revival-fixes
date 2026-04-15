local RunService = game:GetService("RunService")
local Heartbeat  = RunService.Heartbeat

local function resume(thread, ...)
	local ok, err = coroutine.resume(thread, ...)
	if not ok then
		local tb = debug.traceback(thread, tostring(err), 0)
		task.defer(error, tb)
	end
end

local function wrap(functionOrThread, ...)
	if type(functionOrThread) == "thread" then
		return functionOrThread
	end
	local args = { ... }
	return coroutine.create(function()
		functionOrThread(table.unpack(args))
	end)
end

local function spawn(functionOrThread, ...)
	if type(functionOrThread) == "thread" then
		resume(functionOrThread, ...)
		return functionOrThread
	end
	local thread = wrap(functionOrThread)
	resume(thread, ...)
	return thread
end

local function defer(functionOrThread, ...)
	local args = { ... }
	local thread = (type(functionOrThread) == "thread")
		and functionOrThread
		or wrap(functionOrThread)

	local conn
	conn = Heartbeat:Connect(function()
		conn:Disconnect()
		resume(thread, table.unpack(args))
	end)
	return thread
end

local function delay(duration, functionOrThread, ...)
	duration = math.max(0, tonumber(duration) or 0)
	local args = { ... }
	local thread = (type(functionOrThread) == "thread")
		and functionOrThread
		or wrap(functionOrThread)

	local elapsed = 0
	local conn
	conn = Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= duration then
			conn:Disconnect()
			resume(thread, table.unpack(args))
		end
	end)
	return thread
end

local function wait(duration)
	duration = math.max(0, tonumber(duration) or 0)
	local thread  = coroutine.running()
	assert(thread, "task.wait cannot be called from the main thread")
	local elapsed = 0
	local conn
	conn = Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= duration then
			conn:Disconnect()
			local ok, err = coroutine.resume(thread, elapsed)
			if not ok then
				error(err, 0)
			end
		end
	end)
	return coroutine.yield()
end

local function cancel(thread)
	local ok, err = coroutine.close(thread)
	if not ok then
		error(err, 2)
	end
end

local function desynchronize()
	local thread = coroutine.running()
	assert(thread, "task.desynchronize cannot be called from the main thread")
	local conn
	conn = Heartbeat:Connect(function()
		conn:Disconnect()
		local ok, err = coroutine.resume(thread)
		if not ok then error(err, 0) end
	end)
	coroutine.yield()
end

local function synchronize()
	local thread = coroutine.running()
	assert(thread, "task.synchronize cannot be called from the main thread")
	local conn
	conn = Heartbeat:Connect(function()
		conn:Disconnect()
		local ok, err = coroutine.resume(thread)
		if not ok then error(err, 0) end
	end)
	coroutine.yield()
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
