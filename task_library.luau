local RunService = game:GetService("RunService")
local Heartbeat  = RunService.Heartbeat

local function wrap(functionOrThread, ...)
	if type(functionOrThread) == "thread" then
		return functionOrThread, ...
	end

	local args = { ... }
	return coroutine.create(function()
		functionOrThread(table.unpack(args))
	end)
end

local function resume(thread, ...)
	local ok, err = coroutine.resume(thread, ...)
	if not ok then
		error(tostring(err) .. "\n" .. debug.traceback(thread))
	end
end

local function spawn(functionOrThread, ...)
	local thread = wrap(functionOrThread, ...)
	resume(thread)
	return thread
end

local function defer(functionOrThread, ...)
	local thread = wrap(functionOrThread, ...)
	local conn
	conn = Heartbeat:Connect(function()
		conn:Disconnect()
		resume(thread)
	end)
	return thread
end

local function delay(duration, functionOrThread, ...)
	duration = math.max(0, tonumber(duration) or 0)
	local thread   = wrap(functionOrThread, ...)
	local elapsed  = 0
	local conn
	conn = Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= duration then
			conn:Disconnect()
			resume(thread)
		end
	end)
	return thread
end

local function wait(duration)
	duration = math.max(0, tonumber(duration) or 0)
	local thread  = coroutine.running()
	local elapsed = 0
	local conn
	conn = Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= duration then
			conn:Disconnect()
			resume(thread, elapsed)
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
	local actor = script:FindFirstAncestorOfClass("Actor")
	if not actor then
		error("task.desynchronize: script is not a descendant of an Actor", 2)
	end
	local thread = coroutine.running()
	local conn
	conn = Heartbeat:Connect(function()
		conn:Disconnect()
		resume(thread)
	end)
	coroutine.yield()
end

local function synchronize()
	local actor = script:FindFirstAncestorOfClass("Actor")
	if not actor then
		error("task.synchronize: script is not a descendant of an Actor", 2)
	end
	local thread = coroutine.running()
	local conn
	conn = Heartbeat:Connect(function()
		conn:Disconnect()
		resume(thread)
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
