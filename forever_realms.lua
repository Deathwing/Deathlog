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
-- Realm-less WoW Forever: the logs saved under the old "CAMWOW US1 Realm 2 PvP" realms, or under "" after the hotfix, move to the region key.

if not Deathlog_IS_FOREVER then return end

local CHUNK_SIZE = 500
local REALM_TABLES = { "deathlog_data", "deathlog_data_map", "deathlog_entry_counts", "deathlog_purged", "deathlog_entry_origin" }

---@param key string
---@return string|nil region  "US", or "?" for an unknown region; nil for a Classic realm
local function regionOf(key)
	local old = key:match("^CAMWOW (%u%u)%d")
	if old then return old end
	local region, rest = key:match("^CAMWOW (%S+)(.*)$")
	if region and (rest == "" or rest == " HC") and (region == "?" or region:match("^%u%u$")) then
		return region
	end
end

--- The region key a saved key belongs to: an old realm goes to its region, "" to `blank`; nil for a Classic realm.
---@param key string
---@param blank string
---@return string|nil
function Deathlog_foreverKeyOf(key, blank)
	if key == "" then return blank end
	if type(key) ~= "string" then return nil end
	local old = key:match("^CAMWOW (%u%u)%d")
	if old then return "CAMWOW " .. old end
	if regionOf(key) then return key end
end

---@param visit fun(key: string)
local function eachSavedKey(visit)
	for _, name in ipairs(REALM_TABLES) do
		local t = _G[name]
		if type(t) == "table" then
			for key in pairs(t) do visit(key) end
		end
	end
	local a = deathlog_archive
	if type(a) == "table" then
		for _, t in ipairs({ a.realms, a.newest }) do
			if type(t) == "table" then
				for key in pairs(t) do visit(key) end
			end
		end
	end
	for _, entry in pairs(deathlog_personal_data or {}) do
		local extra = type(entry) == "table" and entry["extra_data"]
		if type(extra) == "table" and type(extra["realm"]) == "string" then visit(extra["realm"]) end
	end
end

--- Where "" goes: the current key while every Forever key saved names the current region, else "CAMWOW ?".
---@param current string
---@return string
function Deathlog_foreverBlankTarget(current)
	local own = regionOf(current)
	local mixed = false
	eachSavedKey(function(key)
		local region = type(key) == "string" and regionOf(key)
		if region and region ~= "?" and region ~= own then mixed = true end
	end)
	return mixed and "CAMWOW ?" or current
end

--- The Search tab and Minilog list only Forever keys and the personal deaths filed under one, like the statistics.
---@param data table  realm -> entries, the personal log included
---@return table
function Deathlog_foreverLogView(data)
	local view = {}
	for realm, entries in pairs(data) do
		if realm == Deathlog_PERSONAL_LOG_KEY then
			local kept = {}
			for key, entry in pairs(entries) do
				if Deathlog_foreverKeyOf(Deathlog_personalEntryRealm(entry), "") then kept[key] = entry end
			end
			view[realm] = kept
		elseif Deathlog_foreverKeyOf(realm, "") then
			view[realm] = entries
		end
	end
	return view
end

---@return table
local function archive()
	if type(deathlog_archive) ~= "table" then deathlog_archive = {} end
	local a = deathlog_archive
	a.v = a.v or 1
	a.serial = tonumber(a.serial) or 0
	if type(a.realms) ~= "table" then a.realms = {} end
	if type(a.newest) ~= "table" then a.newest = {} end
	return a
end

--- Archives a dead realm's rows the live log cannot hold beside a newer death with the same checksum, as displaced lines that leave `newest` alone.
---@param target string
---@param rows table[]  { line, date }
local function appendArchived(target, rows)
	if #rows == 0 then return end
	local a = archive()
	local r = a.realms[target]
	if type(r) ~= "table" or type(r.chunks) ~= "table" then
		r = { count = 0, chunks = {} }
		a.realms[target] = r
	end
	for i = 1, #rows, CHUNK_SIZE do
		local stop = math.min(i + CHUNK_SIZE - 1, #rows)
		local lines, newest = {}, 0
		for j = i, stop do
			lines[#lines + 1] = rows[j].line
			newest = math.max(newest, rows[j].date)
		end
		a.serial = a.serial + #lines
		r.chunks[#r.chunks + 1] = { n = #lines, newest = newest, upto = a.serial, data = table.concat(lines, "\n"), displaced = true }
		r.count = (tonumber(r.count) or 0) + #lines
	end
end

local function surname(row)
	local extra = row["extra_data"]
	return type(extra) == "table" and extra["sn"] or nil
end

local function differ(a, b)
	return a ~= nil and b ~= nil and a ~= b
end

--- Same checksum within the dedup window is one death, merged as newEntry does, unless surname, class or race differ; otherwise the newer stays live and the older is archived.
---@return table|nil left  rows that could not move
---@return boolean changed
local function mergeData(key, target, replaced)
	local src = deathlog_data[key]
	if type(src) ~= "table" then return src, false end
	local dst = deathlog_data[target]
	if type(dst) ~= "table" then
		dst = {}
		deathlog_data[target] = dst
	end
	local put, archived, left = {}, {}, nil
	for cs, row in pairs(src) do
		local have = dst[cs]
		if type(row) ~= "table" then
			left = left or {}
			left[cs] = row
		elseif type(have) ~= "table" then
			put[cs] = row
			replaced[cs] = true
		else
			local level = math.max(tonumber(row["level"]) or 0, tonumber(have["level"]) or 0)
			local d_row, d_have = tonumber(row["date"]) or 0, tonumber(have["date"]) or 0
			local other = differ(surname(row), surname(have)) or differ(row["class_id"], have["class_id"]) or differ(row["race_id"], have["race_id"])
			if not other and math.abs(d_row - d_have) <= DeathNotificationLib.GetDedupWindow(level) then
				if DeathNotificationLib.EntryQuality(row) > DeathNotificationLib.EntryQuality(have) then
					put[cs] = DeathNotificationLib.MergeEntries(row, have)
				else
					put[cs] = DeathNotificationLib.MergeEntries(have, row)
				end
			else
				local older, newer = row, have
				if d_row > d_have then older, newer = have, row end
				local line = Deathlog_archiveEncode(cs, older)
				if line then
					archived[#archived + 1] = { line = line, date = math.min(d_row, d_have) }
				else
					left = left or {}
					left[cs] = older
				end
				put[cs] = newer
				if newer == row then replaced[cs] = true end
			end
		end
	end
	local changed = #archived > 0
	for cs, row in pairs(put) do
		changed = changed or dst[cs] ~= row
	end
	-- Cleared before rows move in, so a run cut short still reruns the duplicate pass.
	local deduped = changed and deathlog_settings and deathlog_settings["forever_dedup_version"]
	if type(deduped) == "table" then deduped[target] = nil end
	-- Archived first, so an interrupted run can only repeat an archived line.
	appendArchived(target, archived)
	for cs, row in pairs(put) do
		dst[cs] = row
	end
	return left, changed
end

local function mergeMap(src, dst, data)
	local changed = false
	for name, cs in pairs(src) do
		local have = dst[name]
		if have == nil then
			dst[name] = cs
			changed = true
		elseif have ~= cs then
			local a, b = data and data[have], data and data[cs]
			if type(b) == "table" and (type(a) ~= "table" or (tonumber(b["date"]) or 0) > (tonumber(a["date"]) or 0)) then
				dst[name] = cs
				changed = true
			end
		end
	end
	return changed
end

-- Every sum is taken before the first write, so an error while reading leaves dst unchanged.
local function mergeCounts(src, dst)
	local sums = {}
	for k, v in pairs(src) do
		if type(v) == "number" then
			sums[k] = (tonumber(dst[k]) or 0) + v
		elseif dst[k] == nil then
			sums[k] = v
		end
	end
	local changed = false
	for k, v in pairs(sums) do
		changed = changed or dst[k] ~= v
		dst[k] = v
	end
	return changed
end

local function mergePurged(src, dst)
	local changed = false
	for k, v in pairs(src) do
		if k == "_cleanse_version" then
			local version = math.max(tonumber(dst[k]) or 0, tonumber(v) or 0)
			changed = changed or dst[k] ~= version
			dst[k] = version
		elseif dst[k] == nil then
			dst[k] = v
			changed = true
		end
	end
	return changed
end

local function mergeOrigins(src, dst, replaced)
	local changed = false
	for cs, origin in pairs(src) do
		if dst[cs] == nil or replaced[cs] then
			changed = changed or dst[cs] ~= origin
			dst[cs] = origin
		end
	end
	return changed
end

local function mergeArchive(key, target)
	local a = deathlog_archive
	if type(a) ~= "table" then return false end
	local moved = false
	local realms, newest = a.realms, a.newest
	if type(realms) == "table" and realms[key] ~= nil then
		local src = realms[key]
		if type(src) == "table" and type(src.chunks) == "table" and #src.chunks > 0 then
			local dst = realms[target]
			if type(dst) ~= "table" or type(dst.chunks) ~= "table" then
				dst = { count = 0, chunks = {} }
				realms[target] = dst
			end
			for _, c in ipairs(src.chunks) do
				dst.chunks[#dst.chunks + 1] = c
			end
			dst.count = (tonumber(dst.count) or 0) + (tonumber(src.count) or 0)
		end
		realms[key] = nil
		moved = true
	end
	if type(newest) == "table" and newest[key] ~= nil then
		newest[target] = math.max(tonumber(newest[target]) or 0, tonumber(newest[key]) or 0)
		newest[key] = nil
		moved = true
	end
	return moved
end

--- One-time and idempotent: every table saved under an old Forever realm, or under "" when `current` is given, moves to its region key; nothing is dropped, Classic realms stay.
---@param current string|nil  this session's settled Deathlog_realmKey(); nil leaves "" in place
---@return number moved  saved keys moved
---@return boolean rewritten  a personal death changed realm
function Deathlog_migrateForeverRealms(current)
	local blank = current and Deathlog_foreverBlankTarget(current)
	local seen, keys = {}, {}
	eachSavedKey(function(key)
		local target = not seen[key] and Deathlog_foreverKeyOf(key, blank)
		seen[key] = true
		if target and target ~= key then keys[#keys + 1] = key end
	end)
	table.sort(keys)

	local moved = 0
	for _, key in ipairs(keys) do
		local target = Deathlog_foreverKeyOf(key, blank)
		local replaced, touched = {}, false
		-- Only the per-row merge calls can raise, and they run before any table is written.
		if type(deathlog_data) == "table" and deathlog_data[key] ~= nil then
			local left, changed = mergeData(key, target, replaced)
			deathlog_data[key] = left
			touched = changed or left == nil
		end
		for _, step in ipairs({
			{ "deathlog_data_map", function(src, dst) return mergeMap(src, dst, deathlog_data[target]) end },
			{ "deathlog_entry_counts", mergeCounts },
			{ "deathlog_purged", mergePurged },
			{ "deathlog_entry_origin", function(src, dst) return mergeOrigins(src, dst, replaced) end },
		}) do
			local t = _G[step[1]]
			local src = type(t) == "table" and t[key]
			if type(src) == "table" then
				if type(t[target]) ~= "table" then t[target] = {} end
				if step[2](src, t[target]) then touched = true end
				t[key] = nil
			end
		end
		if mergeArchive(key, target) then touched = true end
		if touched then
			moved = moved + 1
			local deduped = deathlog_settings and deathlog_settings["forever_dedup_version"]
			if type(deduped) == "table" then deduped[target] = nil end
		end
	end

	local rewritten = false
	for _, entry in pairs(deathlog_personal_data or {}) do
		local extra = type(entry) == "table" and entry["extra_data"]
		local realm = type(extra) == "table" and extra["realm"]
		local target = type(realm) == "string" and Deathlog_foreverKeyOf(realm, blank)
		if target and target ~= realm then
			extra["realm"] = target
			rewritten = true
		end
	end

	if moved > 0 or rewritten then
		if type(deathlog_precomputed) == "table" then
			deathlog_precomputed.DD_VERSION = nil
			deathlog_precomputed.DNLD_VERSION = nil
		end
	end
	return moved, rewritten
end
