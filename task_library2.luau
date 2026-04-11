local RunService = game:GetService("RunService")
local Heartbeat  = RunService.Heartbeat

local _parallelMode = false
local deferQueue = {}

Heartbeat:Connect(function()
	local queue = deferQueue
	deferQueue = {}
	for i = 1, #queue do
		local entry = queue[i]
		local ok, err = coroutine.resume(entry.thread, table.unpack(entry.args or {}))
		if not ok then
			error(tostring(err) .. "\n" .. debug.traceback(entry.thread), 0)
		end
	end
end)

local function resume(thread, ...)
	local ok, err = coroutine.resume(thread, ...)
	if not ok then
		error(tostring(err) .. "\n" .. debug.traceback(thread), 0)
	end
end

local function wrap(functionOrThread, ...)
	if type(functionOrThread) == "thread" then
		return functionOrThread, { ... }
	end
	local args = { ... }
	local thread = coroutine.create(function()
		functionOrThread(table.unpack(args))
	end)
	return thread, {}
end

local function spawn(functionOrThread, ...)
	local thread, args = wrap(functionOrThread, ...)
	resume(thread, table.unpack(args))
	return thread
end

local function defer(functionOrThread, ...)
	local thread, args = wrap(functionOrThread, ...)
	deferQueue[#deferQueue + 1] = { thread = thread, args = args }
	return thread
end

local function delay(duration, functionOrThread, ...)
	duration = math.max(0, tonumber(duration) or 0)
	local thread, args = wrap(functionOrThread, ...)
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
	local thread = coroutine.running()
	assert(thread, "task.wait cannot be called from the main thread")
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

-- task.cancel: closes the coroutine, cancelling any pending resumption
local function cancel(thread)
	assert(type(thread) == "thread", "thread expected")
	local ok, err = coroutine.close(thread)
	if not ok then
		error(tostring(err), 2)
	end
end

-- task.desynchronize: simulates switching to a parallel context
-- NOTE: This cannot run on a real separate OS thread in pure Lua.
-- It correctly errors without an Actor, yields to simulate the context switch,
-- and sets internal parallel mode — but true parallelism requires engine-level access.
local function desynchronize()
	local actor = script:FindFirstAncestorOfClass("Actor")
	if not actor then
		error("task.desynchronize: script is not a descendant of an Actor", 2)
	end
	_parallelMode = true
	local thread = coroutine.running()
	assert(thread, "task.desynchronize cannot be called from the main thread")
	local conn
	conn = Heartbeat:Connect(function()
		conn:Disconnect()
		coroutine.resume(thread)
	end)
	coroutine.yield()
end

-- task.synchronize: simulates returning to the serial main thread context
-- NOTE: Same limitation as desynchronize — behavioral simulation only.
local function synchronize()
	local actor = script:FindFirstAncestorOfClass("Actor")
	if not actor then
		error("task.synchronize: script is not a descendant of an Actor", 2)
	end
	_parallelMode = false
	local thread = coroutine.running()
	assert(thread, "task.synchronize cannot be called from the main thread")
	local conn
	conn = Heartbeat:Connect(function()
		conn:Disconnect()
		coroutine.resume(thread)
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
