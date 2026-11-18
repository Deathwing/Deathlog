--[[
Copyright 2026 Deathwing
The Deathlog AddOn is distributed under the terms of the GNU General Public License (or the Lesser GPL).
This file is part of Deathlog.

The Deathlog AddOn is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

The Deathlog AddOn is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with the Deathlog AddOn. If not, see <http://www.gnu.org/licenses/>.
--]]
-- Line format (read by the pipeline's deathlog_archive.py): key~name~guild~source_id~race_id~class_id~level~instance_id~map_id~map_pos~date~played~last_words~extra~other

local floor, format, gsub, concat = math.floor, string.format, string.gsub, table.concat
local min, max, ceil, huge = math.min, math.max, math.ceil, math.huge

local CHUNK_SIZE = 500
local LIVE_CAP_DEFAULT = 50000
local LIVE_CAP_MIN = 10000
local LIVE_CAP_MAX = 50000
local ARCHIVE_CEILING = 150000
local CONSTANT_LIMIT = 262143
local CONSTANTS_PER_RECORD = 4.0
local FULL_WARNING_PERCENT = 90
local GUARD_PERCENT = 85
local GUARD_TARGET_PERCENT = 80
local COUNT_STEP = 5000
local SEARCH_LIMIT = 25000
local SEARCH_SLICE_MS = 3

local FIELDS = { "name", "guild", "source_id", "race_id", "class_id", "level", "instance_id", "map_id", "map_pos", "date", "played", "last_words" }
local NUMERIC = { source_id = true, race_id = true, class_id = true, level = true, instance_id = true, map_id = true, date = true, played = true }
local KNOWN = { extra_data = true }
for _, f in ipairs(FIELDS) do
	KNOWN[f] = true
end
local EXTRA_SLOT = #FIELDS + 2
local OTHER_SLOT = #FIELDS + 3

local ESC = { ["%"] = "%%", ["~"] = "%t", ["\n"] = "%n", ["="] = "%e", ["|"] = "%p" }
local UNESC = { ["%%"] = "%", ["%t"] = "~", ["%n"] = "\n", ["%e"] = "=", ["%p"] = "|", ["%z"] = "" }

local function esc(s)
	if s == "" then return "%z" end
	return (gsub(s, "[%%~\n=|]", ESC))
end

local function unesc(s)
	if not s:find("%", 1, true) then return s end
	return (gsub(s, "%%.", UNESC))
end

-- Exact on every client: integers never go through %.14g, fractions round-trip via %.17g.
local function num(v)
	if v ~= v or v == huge or v == -huge then return nil end
	if v == floor(v) then return format("%.0f", v) end
	return format("%.17g", v)
end

local function scalar(v)
	local t = type(v)
	if t == "string" then return "s" .. esc(v) end
	if t == "number" then
		local n = num(v)
		return n and ("n" .. n)
	end
	if t == "boolean" then return v and "btrue" or "bfalse" end
end

local function encodeKV(t)
	local parts, n = {}, 0
	for k, v in pairs(t) do
		if type(k) ~= "string" then return nil end
		local s = scalar(v)
		if not s then return nil end
		n = n + 1
		parts[n] = esc(k) .. "=" .. s
	end
	if n == 0 then return "|" end
	return concat(parts, "|")
end

local function decodeKV(s, t)
	if s == nil or s == "" then return nil end
	t = t or {}
	for pair in s:gmatch("[^|]+") do
		local k, ty, v = pair:match("^(.-)=(.)(.*)$")
		if k then
			v = unesc(v)
			if ty == "n" then
				v = tonumber(v)
			elseif ty == "b" then
				v = v == "true"
			end
			t[unesc(k)] = v
		end
	end
	return t
end

--- nil when the record holds something the format cannot carry exactly; it then stays live.
---@param key string
---@param entry table
---@return string|nil
local function encode(key, entry)
	if type(key) ~= "string" or type(entry) ~= "table" then return nil end
	local p, other = { esc(key) }, nil
	for i = 1, #FIELDS do
		local f = FIELDS[i]
		local v = entry[f]
		local s = ""
		if v ~= nil then
			if NUMERIC[f] and type(v) == "number" then
				s = num(v)
				if not s then return nil end
			elseif not NUMERIC[f] and type(v) == "string" then
				s = esc(v)
			else
				other = other or {}
				other[f] = v
			end
		end
		p[i + 1] = s
	end
	local extra = entry["extra_data"]
	p[EXTRA_SLOT] = ""
	if type(extra) == "table" then
		p[EXTRA_SLOT] = encodeKV(extra)
		if not p[EXTRA_SLOT] then return nil end
	elseif extra ~= nil then
		other = other or {}
		other["extra_data"] = extra
	end
	for k, v in pairs(entry) do
		if not KNOWN[k] then
			other = other or {}
			other[k] = v
		end
	end
	p[OTHER_SLOT] = ""
	if other then
		p[OTHER_SLOT] = encodeKV(other)
		if not p[OTHER_SLOT] then return nil end
	end
	return concat(p, "~")
end

local LINE = "^" .. string.rep("([^~]*)~", OTHER_SLOT - 1) .. "([^~]*)$"
local line_parts = {}

--- Reuses one table for every well-formed line; valid until the next call.
---@param line string
---@return table
local function split(line)
	local p = line_parts
	p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8], p[9], p[10], p[11], p[12], p[13], p[14], p[15] = line:match(LINE)
	if p[1] then return p end
	local v, n = {}, 0
	for w in (line .. "~"):gmatch("(.-)~") do
		n = n + 1
		v[n] = w
	end
	return v
end

---@param v table  split() result
---@param entry table  empty
---@param extra table|nil  empty table to reuse for extra_data
---@return table entry
local function decodeParts(v, entry, extra)
	for i = 1, #FIELDS do
		local s = v[i + 1]
		if s and s ~= "" then
			local f = FIELDS[i]
			if NUMERIC[f] then
				entry[f] = tonumber(s)
			else
				entry[f] = unesc(s)
			end
		end
	end
	extra = decodeKV(v[EXTRA_SLOT], extra)
	if extra then entry["extra_data"] = extra end
	decodeKV(v[OTHER_SLOT], entry)
	return entry
end

---@param line string
---@return string key
---@return table entry
local function decode(line)
	local v = split(line)
	return unesc(v[1]), decodeParts(v, {}, nil)
end

Deathlog_archiveEncode = encode
Deathlog_archiveDecode = decode

local paused = false
local live_count = nil
local archived_keys = {}
local archived_newest = {}
local keys_ready = false
local rollover_queued = false
local warned_full = false
local drops_reported = false
local precomputed_key, precomputed_count = nil, 0
local cached_percent, cached_live, cached_archived = nil, 0, 0
local exact_constants, exact_records = nil, 0
local guard_cap = nil
local guard_reported = false

local function archiveRoot()
	if type(deathlog_archive) ~= "table" then
		deathlog_archive = {}
	end
	local a = deathlog_archive
	a.v = a.v or 1
	a.serial = tonumber(a.serial) or 0
	if type(a.realms) ~= "table" then
		a.realms = {}
	end
	return a
end

local function liveCap()
	local cap = tonumber(deathlog_settings["archive_live_cap"]) or LIVE_CAP_DEFAULT
	return min(max(cap, LIVE_CAP_MIN), LIVE_CAP_MAX)
end

--- The setting, lowered for this session while the size guard has archived more.
local function effectiveCap()
	local cap = liveCap()
	return guard_cap and min(cap, guard_cap) or cap
end

local function countLive()
	local n = 0
	for _, db in pairs(deathlog_data) do
		if type(db) == "table" then
			for _ in pairs(db) do
				n = n + 1
			end
		end
	end
	live_count = n
	return n
end

--- The personal log is saved in the same file but never archived.
local function countPersonal()
	return Deathlog_personalLogCount and Deathlog_personalLogCount() or 0
end

local function archivedCount()
	local n = 0
	for _, r in pairs(archiveRoot().realms) do
		n = n + (r.count or 0)
	end
	return n
end

local function countNested(t)
	local n = 0
	for _, sub in pairs(t or {}) do
		if type(sub) == "table" then
			for _ in pairs(sub) do
				n = n + 1
			end
		end
	end
	return n
end

local function chunkKeys(realm, chunk, value)
	local keys = archived_keys[realm]
	if not keys then
		keys = {}
		archived_keys[realm] = keys
	end
	if value then
		archived_newest[realm] = max(archived_newest[realm] or 0, chunk.newest or 0)
	end
	for line in chunk.data:gmatch("[^\n]+") do
		keys[unesc(line:match("^[^~]*"))] = value
	end
end

local queue, current, pumping = {}, nil, false

local function inCombat()
	return InCombatLockdown() or UnitAffectingCombat("player")
end

local function pump()
	pumping = false
	if not current then
		local fn = table.remove(queue, 1)
		if not fn then return end
		current = coroutine.create(fn)
	end
	if inCombat() then
		pumping = true
		C_Timer.After(1, pump)
		return
	end
	local ok, err = coroutine.resume(current)
	if not ok then
		current = nil
		geterrorhandler()(err)
	elseif coroutine.status(current) == "dead" then
		current = nil
	end
	if current or queue[1] then
		pumping = true
		C_Timer.After(0, pump)
	end
end

local function enqueue(fn)
	queue[#queue + 1] = fn
	if not pumping then
		pumping = true
		C_Timer.After(0, pump)
	end
end

local function buildKeys()
	if keys_ready then return end
	local todo = {}
	for realm, r in pairs(archiveRoot().realms) do
		for _, c in ipairs(r.chunks) do
			todo[#todo + 1] = realm
			todo[#todo + 1] = c
		end
	end
	for i = 1, #todo, 2 do
		chunkKeys(todo[i], todo[i + 1], true)
		if i % 8 == 7 then coroutine.yield() end
	end
	keys_ready = true
end

local function appendLines(realm, batch)
	local a = archiveRoot()
	local r = a.realms[realm]
	if not r then
		r = { count = 0, chunks = {} }
		a.realms[realm] = r
	end
	local lines, total, pos = batch.lines, #batch.lines, 1
	while pos <= total do
		local c = r.chunks[#r.chunks]
		if not c or c.n >= CHUNK_SIZE then
			c = { n = 0, newest = 0, upto = 0 }
			r.chunks[#r.chunks + 1] = c
		end
		local stop = min(pos + CHUNK_SIZE - c.n - 1, total)
		local part = concat(lines, "\n", pos, stop)
		c.data = c.data and (c.data .. "\n" .. part) or part
		local added = stop - pos + 1
		c.n = c.n + added
		c.newest = max(c.newest or 0, batch.newest)
		r.count = (r.count or 0) + added
		a.serial = a.serial + added
		c.upto = a.serial
		pos = stop + 1
	end
	local keys = archived_keys[realm]
	if not keys then
		keys = {}
		archived_keys[realm] = keys
	end
	for i = 1, total do
		keys[batch.keys[i]] = true
	end
	archived_newest[realm] = max(archived_newest[realm] or 0, batch.newest)
end

local function removeLive(realm, cs, entry)
	deathlog_data[realm][cs] = nil
	local map = deathlog_data_map[realm]
	local name = entry["name"]
	if map and name and map[name] == cs then
		map[name] = nil
	end
	Deathlog_forgetEntryOrigin(realm, cs)
	if Deathlog_forgetNameIndex then
		Deathlog_forgetNameIndex(realm, name, cs)
	end
end

local function enforceCeiling()
	local a = archiveRoot()
	local total, dropped = archivedCount(), 0
	while total > ARCHIVE_CEILING do
		local oldest_realm, oldest_i, oldest_t
		for realm, r in pairs(a.realms) do
			for i, c in ipairs(r.chunks) do
				if not oldest_t or (c.newest or 0) < oldest_t then
					oldest_realm, oldest_i, oldest_t = realm, i, c.newest or 0
				end
			end
		end
		if not oldest_realm then break end
		local r = a.realms[oldest_realm]
		local c = table.remove(r.chunks, oldest_i)
		chunkKeys(oldest_realm, c, nil)
		r.count = r.count - c.n
		total = total - c.n
		dropped = dropped + c.n
		if #r.chunks == 0 then
			a.realms[oldest_realm] = nil
		end
		coroutine.yield()
	end
	if dropped > 0 then
		a.dropped = (a.dropped or 0) + dropped
		a.unreported_drops = (tonumber(a.unreported_drops) or 0) + dropped
	end
	-- Once per session; later drops are reported at the next login.
	if not drops_reported and (tonumber(a.unreported_drops) or 0) > 0 then
		drops_reported = true
		DEFAULT_CHAT_FRAME:AddMessage(format(Deathlog_L.archive_dropped, a.unreported_drops))
		a.unreported_drops = nil
	end
end

local function checkFull()
	local _, _, percent = Deathlog_archiveStats()
	if not warned_full and percent >= FULL_WARNING_PERCENT then
		warned_full = true
		DEFAULT_CHAT_FRAME:AddMessage(format(Deathlog_L.db_size_warning, percent))
	end
end

---@return number moved
local function rollover()
	buildKeys()
	local excess = countLive() - effectiveCap()
	coroutine.yield()

	local moved = 0
	if excess > 0 then
		local realms = {}
		for realm in pairs(deathlog_data) do
			realms[#realms + 1] = realm
		end

		-- Hour buckets instead of a full sort: table.sort cannot yield and is too slow for one frame.
		local buckets, hours = {}, {}
		for _, realm in ipairs(realms) do
			local db = deathlog_data[realm]
			if type(db) == "table" then
				for cs, entry in pairs(db) do
					if type(entry) == "table" then
						local h = floor((tonumber(entry["date"]) or 0) / 3600)
						local b = buckets[h]
						if not b then
							b = {}
							buckets[h] = b
							hours[#hours + 1] = h
						end
						b[#b + 1] = realm
						b[#b + 1] = cs
					end
				end
			end
			coroutine.yield()
		end
		table.sort(hours)

		local victims, wanted = {}, excess * 2
		for _, h in ipairs(hours) do
			local b = buckets[h]
			for i = 1, #b do
				victims[#victims + 1] = b[i]
			end
			if #victims >= wanted then break end
		end
		buckets = nil
		wanted = min(wanted, #victims)

		-- Append before deleting, so an interrupted slice can only duplicate a record.
		for i = 1, wanted, CHUNK_SIZE * 2 do
			local batches = {}
			for j = i, min(i + CHUNK_SIZE * 2 - 1, wanted), 2 do
				local realm, cs = victims[j], victims[j + 1]
				local db = deathlog_data[realm]
				local entry = db and db[cs]
				local line = entry and encode(cs, entry)
				if line then
					local batch = batches[realm]
					if not batch then
						batch = { lines = {}, keys = {}, entries = {}, newest = 0 }
						batches[realm] = batch
					end
					local n = #batch.lines + 1
					batch.lines[n] = line
					batch.keys[n] = cs
					batch.entries[n] = entry
					batch.newest = max(batch.newest, tonumber(entry["date"]) or 0)
				end
			end
			for realm, batch in pairs(batches) do
				appendLines(realm, batch)
				for n = 1, #batch.keys do
					removeLive(realm, batch.keys[n], batch.entries[n])
				end
				moved = moved + #batch.keys
			end
			coroutine.yield()
		end
		live_count = (live_count or 0) - moved
	end

	enforceCeiling()
	return moved
end

local SAVED_VARIABLES = {
	"deathlog_settings", "deathlog_data", "deathlog_data_map", "deathlog_watchlist_entries", "deathlog_record_econ_stats", "deathlog_entry_counts",
	"deathlog_purged", "deathlog_precomputed", "deathlog_entry_origin", "deathlog_ignored_senders", "deathlog_hidden_names", "deathlog_archive",
	"deathlog_personal_data",
}

--- Distinct strings and numbers WoW writes into Deathlog.lua, the constants its loader limits to 262,143.
---@return number
local function countConstants()
	local seen, stack, top, n, visited = {}, {}, 0, 0, 0
	local function add(v)
		local tv = type(v)
		if (tv == "string" or (tv == "number" and v == v)) and not seen[v] then
			seen[v] = true
			n = n + 1
		end
	end
	local function walk(t, depth)
		-- Bounds a reference cycle.
		if depth > 32 then return end
		-- The realm tables are the big ones; their copy gets a frame of its own.
		if depth <= 2 and visited > 0 then
			visited = 0
			coroutine.yield()
		end
		local base = top
		-- Copied first: other jobs change these tables between yields.
		for k in pairs(t) do
			top = top + 1
			stack[top] = k
		end
		local stop = top
		visited = visited + stop - base
		for i = base + 1, stop do
			local k = stack[i]
			local v = t[k]
			if v ~= nil then
				-- WoW saves a function value as key = nil, so its key still counts.
				add(k)
				if type(v) == "table" then
					walk(v, depth + 1)
				else
					add(v)
				end
			end
			visited = visited + 1
			if visited >= COUNT_STEP then
				visited = 0
				coroutine.yield()
			end
		end
		top = base
	end
	for _, name in ipairs(SAVED_VARIABLES) do
		add(name)
		local v = _G[name]
		if type(v) == "table" then
			walk(v, 1)
		else
			add(v)
		end
	end
	return n
end

--- Counts the file exactly; past GUARD_PERCENT, lowers this session's cap and archives until it is back near GUARD_TARGET_PERCENT.
local function checkSize()
	if paused then return end
	local before, moved = nil, 0
	while true do
		local live = countLive()
		local records = live + countPersonal()
		local n = countConstants()
		exact_constants, exact_records = n, records
		if n <= CONSTANT_LIMIT * GUARD_PERCENT / 100 then break end
		local cap = max(LIVE_CAP_MIN, live - ceil((n - CONSTANT_LIMIT * GUARD_TARGET_PERCENT / 100) / CONSTANTS_PER_RECORD))
		cap = min(cap, guard_cap or cap)
		if cap >= live then break end
		guard_cap = cap
		before = before or n
		local m = rollover()
		moved = moved + m
		if m == 0 then break end
	end
	if moved > 0 and not guard_reported then
		guard_reported = true
		DEFAULT_CHAT_FRAME:AddMessage(format(Deathlog_L.archive_guard_moved, floor(before / CONSTANT_LIMIT * 100 + 0.5), moved))
	end
	checkFull()
end

local function rolloverJob()
	rollover_queued = false
	if paused then return end
	rollover()
	checkSize()
end

---@param load_failed boolean  the account file did not load; leave everything untouched this session
function Deathlog_archiveOnLoad(load_failed)
	paused = load_failed and true or false
	local a = archiveRoot()
	-- Newest date ever archived per realm; kept after chunks are dropped so sync never reaches back past it.
	if type(a.newest) ~= "table" then
		a.newest = {}
	end
	archived_newest = a.newest
	local chunks = 0
	for realm, r in pairs(a.realms) do
		if type(r) ~= "table" or type(r.chunks) ~= "table" then
			a.realms[realm] = nil
		else
			for _, c in ipairs(r.chunks) do
				archived_newest[realm] = max(tonumber(archived_newest[realm]) or 0, tonumber(c.newest) or 0)
				chunks = chunks + 1
			end
		end
	end
	keys_ready = chunks == 0
end

--- Builds the archived-key filter without waiting for the first rollover.
function Deathlog_archiveBuildKeys()
	if not keys_ready then
		enqueue(buildKeys)
	end
end

---@return boolean
function Deathlog_archiveKeysReady()
	return keys_ready
end

--- DNL syncWindowDays callback: keeps the sync window inside the live span, after the newest archived date.
---@param days number configured window (-1 = all)
---@return number
function Deathlog_archiveSyncWindow(days)
	local newest = tonumber(archived_newest[GetRealmName()])
	if not newest or newest <= 0 then
		return days
	end
	local span = max(1, floor((GetServerTime() - newest) / 86400))
	if days == -1 or days > span then
		return min(span, 30)
	end
	return days
end

---@return number
function Deathlog_archiveLiveCap()
	return liveCap()
end

function Deathlog_startArchiveRollover()
	if paused or rollover_queued then return end
	rollover_queued = true
	enqueue(rolloverJob)
end

--- Called for every record newEntry stores; rolls over once a chunk's worth is over the cap.
function Deathlog_archiveNoteEntry()
	if not live_count then return end
	live_count = live_count + 1
	if live_count > effectiveCap() + CHUNK_SIZE then
		Deathlog_startArchiveRollover()
	end
end

--- Only deaths dated within the archived range match, so a new death sharing an old checksum is kept.
---@param realm string
---@param checksum string
---@param date number|nil
---@return boolean
function Deathlog_isArchived(realm, checksum, date)
	local keys = archived_keys[realm]
	date = tonumber(date)
	return keys ~= nil and keys[checksum] == true and date ~= nil and date <= (archived_newest[realm] or 0)
end

---@return number records in deathlog_data plus the archive
function Deathlog_archiveTotal()
	return countLive() + archivedCount()
end

local search_co = nil

local function newestFirst(a, b)
	return a.newest > b.newest
end

local function searchJob(snap, filter)
	local matches, n = {}, 0
	local entry, extra = {}, {}
	local forget = Deathlog_forgetCachedSource
	local start, tick = debugprofilestop(), 0
	for _, c in ipairs(snap) do
		local realm = c.realm
		local found = matches[realm]
		if not found then
			found = {}
			matches[realm] = found
		end
		for line in c.data:gmatch("[^\n]+") do
			local v = split(line)
			local key = unesc(v[1])
			local db = deathlog_data[realm]
			-- An interrupted rollover can leave a record both live and archived.
			if not (db and db[key]) and not found[key] then
				for k in pairs(entry) do
					entry[k] = nil
				end
				for k in pairs(extra) do
					extra[k] = nil
				end
				decodeParts(v, entry, extra)
				if Deathlog_shouldShowEntry(entry) and filter(realm, entry) then
					local _, e = decode(line)
					found[key] = e
					n = n + 1
					if n >= SEARCH_LIMIT then
						return matches, n
					end
				end
				if forget then forget(entry) end
			end
			tick = tick + 1
			if tick >= 16 then
				tick = 0
				if debugprofilestop() - start >= SEARCH_SLICE_MS then
					coroutine.yield()
					start = debugprofilestop()
				end
			end
		end
	end
	return matches, n
end

local function searchStep(co, on_done)
	if search_co ~= co then return end
	local ok, result, n = coroutine.resume(co)
	if not ok then
		search_co = nil
		geterrorhandler()(result)
	elseif coroutine.status(co) == "dead" then
		search_co = nil
		on_done(result, n)
	else
		C_Timer.After(0, function() searchStep(co, on_done) end)
	end
end

--- Scans archived deaths a few ms per frame for those Deathlog_shouldShowEntry() shows and filter accepts. Starting a search cancels the last one.
---@param filter fun(realm: string, entry: table): boolean
---@param on_done fun(matches: table<string, table<string, table>>, count: number)  realm -> checksum -> entry, newest chunks first up to SEARCH_LIMIT; never stored
---@param realm string|nil  only this realm's archive
---@return boolean started  false when there is nothing to scan; on_done is then never called
function Deathlog_archiveSearch(filter, on_done, realm)
	search_co = nil
	if paused then return false end
	-- Strings are immutable, so jobs that edit the chunk lists cannot disturb the scan.
	local snap = {}
	for r, rec in pairs(archiveRoot().realms) do
		if not realm or r == realm then
			for _, c in ipairs(rec.chunks) do
				if type(c.data) == "string" then
					snap[#snap + 1] = { realm = r, data = c.data, newest = tonumber(c.newest) or 0 }
				end
			end
		end
	end
	if #snap == 0 then return false end
	table.sort(snap, newestFirst)
	local co = coroutine.create(function()
		return searchJob(snap, filter)
	end)
	search_co = co
	C_Timer.After(0, function() searchStep(co, on_done) end)
	return true
end

--- The running Deathlog_archiveSearch() stops and never calls its on_done.
function Deathlog_archiveSearchCancel()
	search_co = nil
end

--- Changes whenever lines are added to or removed from the archive.
---@return string
function Deathlog_archiveSearchStamp()
	return archiveRoot().serial .. ":" .. archivedCount()
end

--- Distinct numbers in deathlog_precomputed (locally computed stats and heatmaps); recounted only when a table is replaced.
---@return number
local function precomputedConstants()
	local tables, parts = {}, {}
	for k, v in pairs(deathlog_precomputed or {}) do
		if type(v) == "table" then
			tables[#tables + 1] = v
			parts[#parts + 1] = tostring(k) .. tostring(v)
		end
	end
	table.sort(parts)
	local key = concat(parts, ",")
	if key == precomputed_key then return precomputed_count end
	local seen, n, visited = {}, 0, 0
	local yields = current ~= nil and coroutine.running() == current
	local function walk(t)
		for k, v in pairs(t) do
			if type(k) == "number" and not seen[k] then
				seen[k] = true
				n = n + 1
			end
			if type(v) == "table" then
				walk(v)
			elseif type(v) == "number" and not seen[v] then
				seen[v] = true
				n = n + 1
			end
			visited = visited + 1
			if yields and visited % 20000 == 0 then coroutine.yield() end
		end
	end
	for i = 1, #tables do
		walk(tables[i])
	end
	precomputed_key, precomputed_count = key, n
	return n
end

---@return number live
---@return number archived
---@return number percent  share of the 262,143-constant limit
---@return boolean exact  percent comes from the last exact count, plus deaths added since
function Deathlog_archiveStats()
	local live = countLive()
	local archived, chunks = 0, 0
	for _, r in pairs(archiveRoot().realms) do
		archived = archived + (r.count or 0)
		chunks = chunks + #r.chunks
	end
	local records = live + countPersonal()
	local constants
	if exact_constants then
		constants = exact_constants + (records - exact_records) * CONSTANTS_PER_RECORD
	else
		constants = records * CONSTANTS_PER_RECORD + countNested(deathlog_purged) + countNested(deathlog_entry_origin) + chunks + precomputedConstants()
	end
	local percent = floor(constants / CONSTANT_LIMIT * 100 + 0.5)
	cached_percent, cached_live, cached_archived = percent, live, archived
	return live, archived, percent, exact_constants ~= nil
end

--- Cached result of the last Deathlog_archiveStats() call, without counting the live log again.
---@return number|nil percent  nil until the first rollover or stats call
---@return number live
---@return number archived
function Deathlog_archiveFullPercent()
	return cached_percent, cached_live, cached_archived
end

---@return string
function Deathlog_archiveSizeText()
	local live, archived, percent, exact = Deathlog_archiveStats()
	local text = format("Database file: about %d%% full%s.\nLive log: %d deaths. Archive: %d deaths.", percent, exact and "" or " (estimate)", live, archived)
	local personal = countPersonal()
	if personal > 0 then
		text = text .. format(" Personal log: %d deaths.", personal)
	end
	if percent >= FULL_WARNING_PERCENT then
		text = text .. "\n|cffff5555Warning: when the file is full, WoW cannot load it and Deathlog starts empty. Lower the live log size below so WoW can still load it.|r"
	end
	return text
end
