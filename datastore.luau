local DEBUG = false

assert(game:GetService("RunService"):IsServer(), "[DataStoreService] Can only be used on the server")

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local function _log(...)
	if DEBUG then
		print("[DataStore]", ...)
	end
end

local function _warn(...)
	warn("[DataStore]", ...)
	if DEBUG then
		print("[DataStore]", ...)
	end
end

------------------------------------------------------------------------
-- Rate limiter
-- Tracks per-requestType budgets and enforces throttling.
-- Budget refills every minute based on baseLimit + perPlayerLimit * players.
-- formula: budget = baseLimit + (perPlayerLimit * numPlayers)
------------------------------------------------------------------------

local _rateLimits = {}       -- [requestType] = { baseLimit, perPlayerLimit }
local _requestCounts = {}    -- [requestType] = count this minute
local _lastRefill = os.clock()

local DEFAULT_LIMITS = {
	GetAsync              = { base = 60,    perPlayer = 40  },
	SetIncrementAsync     = { base = 60,    perPlayer = 40  },
	UpdateAsync           = { base = 60,    perPlayer = 40  },
	GetSortedAsync        = { base = 5,     perPlayer = 2   },
	SetIncrementSortedAsync = { base = 30,  perPlayer = 5   },
	OnUpdate              = { base = 30,    perPlayer = 5   },
	ListAsync             = { base = 5,     perPlayer = 2   },
	GetVersionAsync       = { base = 5,     perPlayer = 2   },
	RemoveVersionAsync    = { base = 5,     perPlayer = 2   },
	StandardRead          = { base = 10000, perPlayer = 200 },
	StandardWrite         = { base = 10000, perPlayer = 200 },
	StandardList          = { base = 10000, perPlayer = 200 },
	StandardRemove        = { base = 10000, perPlayer = 200 },
	OrderedRead           = { base = 10000, perPlayer = 200 },
	OrderedWrite          = { base = 10000, perPlayer = 200 },
	OrderedList           = { base = 10000, perPlayer = 200 },
	OrderedRemove         = { base = 10000, perPlayer = 200 },
}

local function _getPlayerCount()
	local ok, Players = pcall(function() return game:GetService("Players") end)
	if ok and Players then
		return #Players:GetPlayers()
	end
	return 0
end

local function _refillIfNeeded()
	local now = os.clock()
	if now - _lastRefill >= 60 then
		_requestCounts = {}
		_lastRefill = now
		_log("Rate limit buckets refilled")
	end
end

local function _getBudget(requestType)
	_refillIfNeeded()
	local name = tostring(requestType)
	local limits = _rateLimits[name] or DEFAULT_LIMITS[name]
	if not limits then return 1000 end
	local max = limits.base + (limits.perPlayer * _getPlayerCount())
	local used = _requestCounts[name] or 0
	return math.max(0, max - used)
end

local function _consumeBudget(requestType)
	_refillIfNeeded()
	local name = tostring(requestType)
	_requestCounts[name] = (_requestCounts[name] or 0) + 1
	local budget = _getBudget(requestType)
	if budget <= 0 then
		_warn("Rate limit exceeded for request type:", name)
		return false
	end
	return true
end

local function _setRateLimit(requestType, baseLimit, perPlayerLimit)
	local name = tostring(requestType)
	assert(
		name ~= "UpdateAsync" and name ~= "OnUpdate",
		"SetRateLimitForRequestType cannot configure UpdateAsync or OnUpdate"
	)
	local defaults = DEFAULT_LIMITS[name]
	assert(defaults, "Unknown requestType: " .. name)
	assert(
		baseLimit >= 0 and baseLimit <= defaults.base * 2,
		"baseLimit out of range for " .. name
	)
	assert(
		perPlayerLimit >= 0 and perPlayerLimit <= defaults.perPlayer * 2,
		"perPlayerLimit out of range for " .. name
	)
	_rateLimits[name] = { base = baseLimit, perPlayer = perPlayerLimit }
	_log("SetRateLimitForRequestType", name, baseLimit, perPlayerLimit)
end

------------------------------------------------------------------------
-- Storage backend
------------------------------------------------------------------------

local _memory = {}

local function _read(fullKey)   return _memory[fullKey] end
local function _write(fullKey, value) _memory[fullKey] = value end
local function _delete(fullKey) _memory[fullKey] = nil end

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function _encode(value)  return HttpService:JSONEncode(value) end
local function _decode(str)    return HttpService:JSONDecode(str) end
local function _fullKey(scope, key) return scope .. "/" .. key end

local function _checkKey(key)
	assert(type(key) == "string", "key must be a string")
	assert(#key <= 50, "key exceeds 50 character limit")
end

local function _checkValue(value)
	local encoded = _encode(value)
	assert(#encoded <= 4194304, "value exceeds 4MB limit")
end

local function _makePager(results, pageSize)
	local page = 1
	local pager = {}
	pager.IsFinished = #results <= pageSize
	function pager:GetCurrentPage()
		local s = (page - 1) * pageSize + 1
		local f = math.min(page * pageSize, #results)
		local slice = {}
		for i = s, f do table.insert(slice, results[i]) end
		return slice
	end
	function pager:AdvanceToNextPageAsync()
		assert(not self.IsFinished, "no more pages")
		page = page + 1
		self.IsFinished = page * pageSize >= #results
	end
	return pager
end

------------------------------------------------------------------------
-- DataStore
------------------------------------------------------------------------

local DataStore = {}
DataStore.__index = DataStore

function DataStore.new(name, scope)
	return setmetatable({ _name = name, _scope = scope or "global" }, DataStore)
end

function DataStore:GetAsync(key)
	_checkKey(key)
	_consumeBudget("GetAsync")
	local raw = _read(_fullKey(self._scope, key))
	if raw == nil then return nil end
	local ok, value = pcall(_decode, raw)
	if not ok then _warn("GetAsync decode failed:", key) return nil end
	_log("GetAsync", key, "->", value)
	return value
end

function DataStore:SetAsync(key, value, userIds, options)
	_checkKey(key)
	_checkValue(value)
	_consumeBudget("SetIncrementAsync")
	local ok, encoded = pcall(_encode, value)
	if not ok then _warn("SetAsync encode failed:", key) return end
	_write(_fullKey(self._scope, key), encoded)
	_log("SetAsync", key, "=", value)
end

function DataStore:UpdateAsync(key, transformFunction)
	_checkKey(key)
	assert(type(transformFunction) == "function", "transformFunction must be a function")
	_consumeBudget("UpdateAsync")
	local fk = _fullKey(self._scope, key)
	local current
	local raw = _read(fk)
	if raw ~= nil then
		local ok, decoded = pcall(_decode, raw)
		if ok then current = decoded end
	end
	local new = transformFunction(current)
	if new == nil then _log("UpdateAsync aborted:", key) return nil end
	_checkValue(new)
	local ok, encoded = pcall(_encode, new)
	if not ok then _warn("UpdateAsync encode failed:", key) return nil end
	_write(fk, encoded)
	_log("UpdateAsync", key, "->", new)
	return new
end

function DataStore:IncrementAsync(key, delta, userIds, options)
	_checkKey(key)
	delta = tonumber(delta) or 1
	_consumeBudget("SetIncrementAsync")
	return self:UpdateAsync(key, function(current)
		return (tonumber(current) or 0) + delta
	end)
end

function DataStore:RemoveAsync(key)
	_checkKey(key)
	_consumeBudget("StandardRemove")
	local fk = _fullKey(self._scope, key)
	local raw = _read(fk)
	local current
	if raw ~= nil then
		local ok, decoded = pcall(_decode, raw)
		if ok then current = decoded end
	end
	_delete(fk)
	_log("RemoveAsync", key)
	return current
end

function DataStore:GetVersionAsync(key, version)
	_checkKey(key)
	_consumeBudget("GetVersionAsync")
	_warn("GetVersionAsync: versioning not supported, returning current value")
	return self:GetAsync(key)
end

function DataStore:RemoveVersionAsync(key, version)
	_checkKey(key)
	_consumeBudget("RemoveVersionAsync")
	_warn("RemoveVersionAsync: versioning not supported, removing current value")
	return self:RemoveAsync(key)
end

function DataStore:ListKeysAsync(prefix, pageSize, cursor, excludeDeleted)
	prefix = prefix or ""
	pageSize = pageSize or 32
	_consumeBudget("ListAsync")
	local scope = self._scope .. "/"
	local results = {}
	for fk in pairs(_memory) do
		if fk:sub(1, #scope) == scope then
			local key = fk:sub(#scope + 1)
			if key:sub(1, #prefix) == prefix then
				table.insert(results, { KeyName = key })
			end
		end
	end
	return _makePager(results, pageSize)
end

function DataStore:ListVersionsAsync(key, sortDirection, minDate, maxDate, pageSize)
	_warn("ListVersionsAsync: versioning not supported")
	return _makePager({}, pageSize or 32)
end

function DataStore:OnUpdate(key, callback)
	_checkKey(key)
	_warn("OnUpdate: not supported on revival engines")
	return { Disconnect = function() end }
end

------------------------------------------------------------------------
-- OrderedDataStore
------------------------------------------------------------------------

local OrderedDataStore = setmetatable({}, { __index = DataStore })
OrderedDataStore.__index = OrderedDataStore

function OrderedDataStore.new(name, scope)
	return setmetatable(DataStore.new(name, scope), OrderedDataStore)
end

function OrderedDataStore:SetAsync(key, value)
	assert(type(value) == "number", "OrderedDataStore only supports number values")
	_consumeBudget("OrderedWrite")
	DataStore.SetAsync(self, key, value)
end

function OrderedDataStore:IncrementAsync(key, delta)
	_consumeBudget("OrderedWrite")
	return DataStore.IncrementAsync(self, key, delta)
end

function OrderedDataStore:GetSortedAsync(ascending, pageSize, minValue, maxValue)
	pageSize = pageSize or 50
	_consumeBudget("OrderedRead")
	local scope = self._scope .. "/"
	local entries = {}
	for fk, raw in pairs(_memory) do
		if fk:sub(1, #scope) == scope then
			local key = fk:sub(#scope + 1)
			local ok, value = pcall(_decode, raw)
			if ok and type(value) == "number" then
				if (minValue == nil or value >= minValue) and (maxValue == nil or value <= maxValue) then
					table.insert(entries, { key = key, value = value })
				end
			end
		end
	end
	table.sort(entries, function(a, b)
		return ascending and a.value < b.value or a.value > b.value
	end)
	return _makePager(entries, pageSize)
end

------------------------------------------------------------------------
-- DataStoreService
------------------------------------------------------------------------

local _stores = {}
local _orderedStores = {}
local _globalStore = nil

local DataStoreServiceModule = {}

function DataStoreServiceModule:GetDataStore(name, scope, options)
	assert(type(name) == "string" and #name > 0, "name must be a non-empty string")
	scope = scope or "global"
	local id = name .. "|" .. scope
	if not _stores[id] then
		_stores[id] = DataStore.new(name, scope)
		_log("GetDataStore", name, scope)
	end
	return _stores[id]
end

function DataStoreServiceModule:GetGlobalDataStore()
	if not _globalStore then
		_globalStore = DataStore.new("_global", "u")
		_log("GetGlobalDataStore")
	end
	return _globalStore
end

function DataStoreServiceModule:GetOrderedDataStore(name, scope)
	assert(type(name) == "string" and #name > 0, "name must be a non-empty string")
	scope = scope or "global"
	local id = name .. "|" .. scope
	if not _orderedStores[id] then
		_orderedStores[id] = OrderedDataStore.new(name, scope)
		_log("GetOrderedDataStore", name, scope)
	end
	return _orderedStores[id]
end

function DataStoreServiceModule:GetRequestBudgetForRequestType(requestType)
	return _getBudget(tostring(requestType))
end

function DataStoreServiceModule:ListDataStoresAsync(prefix, pageSize, cursor)
	prefix = prefix or ""
	pageSize = pageSize or 32
	_consumeBudget("StandardList")
	local seen = {}
	local results = {}
	for fk in pairs(_memory) do
		local slash = fk:find("/")
		if slash then
			local scope = fk:sub(1, slash - 1)
			if not seen[scope] and scope:sub(1, #prefix) == prefix then
				seen[scope] = true
				table.insert(results, { Name = scope, CreatedTime = 0, UpdatedTime = 0 })
			end
		end
	end
	return _makePager(results, pageSize)
end

function DataStoreServiceModule:SetRateLimitForRequestType(requestType, baseLimit, perPlayerLimit)
	_setRateLimit(requestType, baseLimit, perPlayerLimit)
end

return DataStoreServiceModule
