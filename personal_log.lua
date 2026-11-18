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
-- Every own death of every character on the account, saved in Deathlog.lua but out of deathlog_data, so sync and broadcasts never carry them.

local SOURCE = DeathNotificationLib.SOURCE

local PERSONAL_CAP = 5000

--- Live reports that the personal copy of the player's broadcast death takes over; any other report only marks it.
local MIRROR_SOURCES = {
	[SOURCE.SELF_DEATH] = true,
	[SOURCE.PEER_BROADCAST] = true,
	[SOURCE.BLIZZARD] = true,
	[SOURCE.UPGRADE] = true,
}

--- Pseudo-realm key the personal log takes in the views handed to the Log tab and the local statistics.
Deathlog_PERSONAL_LOG_KEY = "__personal__"

local personal_count
--- Names with an unmatched kept broadcast death on this realm; nil until needed.
local pending_names

local function countPersonal()
	if not personal_count then
		personal_count = 0
		for _ in pairs(deathlog_personal_data) do
			personal_count = personal_count + 1
		end
	end
	return personal_count
end

local function dropOldest()
	local oldest_key, oldest_date
	for key, entry in pairs(deathlog_personal_data) do
		local d = tonumber(entry["date"]) or 0
		if not oldest_date or d < oldest_date then
			oldest_key, oldest_date = key, d
		end
	end
	if oldest_key then
		deathlog_personal_data[oldest_key] = nil
		personal_count = personal_count - 1
	end
end

--- False when an older DeathNotificationLib without local recording won the handover.
---@return boolean
function Deathlog_isPersonalLogAvailable()
	local source = DeathNotificationLib.SOURCE
	return source ~= nil and source.LOCAL_SELF ~= nil
end

---@return boolean
function Deathlog_isPersonalLogEnabled()
	return deathlog_settings["personal_log"] ~= false
end

--- isUnitRecordedLocally callback for DeathNotificationLib.AttachAddon(); DNL asks it only for deaths no addon tracks.
---@param unit string
---@return boolean
function Deathlog_isUnitRecordedLocally(unit)
	return unit == "player" and Deathlog_isPersonalLogEnabled()
end

---@param entry table|nil
---@return boolean
function Deathlog_isPersonalEntry(entry)
	local extra = entry and entry["extra_data"]
	return type(extra) == "table" and extra["m"] == "n"
end

--- A personal copy of a death that is also in the shared log; merged views skip it so it counts once.
---@param entry table|nil
---@return boolean
function Deathlog_isPersonalMirror(entry)
	local extra = entry and entry["extra_data"]
	return type(extra) == "table" and extra["mirror"] == true
end

--- Entries saved before the realm was stored count as the current realm's.
---@param entry table  a personal entry
---@return string
function Deathlog_personalEntryRealm(entry)
	local extra = entry["extra_data"]
	return type(extra) == "table" and extra["realm"] or GetRealmName()
end

--- Reports of the same character, realm, guild and level dated this close are one death.
local SAME_DEATH_WINDOW = 10
local MARKS = { "mirror", "broadcast" }

---@param entry table
---@return number
local function entryDate(entry)
	return tonumber(entry["date"]) or 0
end

---@param entry table
---@return boolean
local function hasKiller(entry)
	local source = tonumber(entry["source_id"])
	return source ~= nil and source ~= -1
end

--- What the checksum covers, with the level kept when the killer is unknown, plus the realm.
---@param entry table
---@return string
local function deathIdentity(entry)
	return tostring(entry["name"]) .. "\0" .. Deathlog_personalEntryRealm(entry) .. "\0" .. (entry["guild"] or "") .. "\0" .. (tonumber(entry["level"]) or 0)
end

---@param player_data PlayerData  realm already set
---@return string|nil key
local function findSameDeath(player_data)
	local date = entryDate(player_data)
	local identity, best_key, best_diff
	for key, entry in pairs(deathlog_personal_data) do
		local diff = math.abs(entryDate(entry) - date)
		if diff <= SAME_DEATH_WINDOW and (not best_diff or diff < best_diff) then
			identity = identity or deathIdentity(player_data)
			if deathIdentity(entry) == identity then
				best_key, best_diff = key, diff
			end
		end
	end
	return best_key
end

--- Two reports of one death: a known killer wins, otherwise `replace` picks the newer one; the other's mirror and broadcast marks carry over.
---@param stored table
---@param report table
---@param replace boolean
---@return table kept
local function mergeDeath(stored, report, replace)
	local kept, other = report, stored
	if hasKiller(stored) ~= hasKiller(report) then
		if hasKiller(stored) then kept, other = stored, report end
	elseif not replace then
		kept, other = stored, report
	end
	local extra = other["extra_data"]
	if type(extra) == "table" then
		for _, mark in ipairs(MARKS) do
			if extra[mark] then
				kept["extra_data"][mark] = true
			end
		end
	end
	return kept
end

--- Each death gets its own key, so repeated deaths at the same level never overwrite each other; a second report of one death updates its entry.
---@param player_data PlayerData
---@param checksum string|nil
---@param key string|nil  replace this entry instead of deriving a key
---@return string key
function Deathlog_addPersonalEntry(player_data, checksum, key)
	local date = tonumber(player_data["date"]) or GetServerTime()
	player_data["date"] = date
	player_data["extra_data"] = player_data["extra_data"] or {}
	player_data["extra_data"]["m"] = "n"
	player_data["extra_data"]["realm"] = GetRealmName()
	local own_key = (checksum or DeathNotificationLib.Fletcher16(player_data)) .. ":" .. date
	countPersonal()
	pending_names = nil
	local replace = key ~= nil and deathlog_personal_data[key] ~= nil
	if not replace then
		key = findSameDeath(player_data) or own_key
	end
	local existing = deathlog_personal_data[key]
	if not existing then
		personal_count = personal_count + 1
		deathlog_personal_data[key] = player_data
	else
		local kept = mergeDeath(existing, player_data, replace)
		if kept ~= existing and not replace then
			deathlog_personal_data[key] = nil
			key = own_key
		end
		deathlog_personal_data[key] = kept
	end
	while personal_count > PERSONAL_CAP do
		dropOldest()
	end
	return key
end

--- Merges the deaths that earlier builds stored twice, keeping the better report; one pass at load.
---@return number removed
function Deathlog_collapsePersonalDuplicates()
	local first, groups = {}, {}
	for key, entry in pairs(deathlog_personal_data) do
		local identity = deathIdentity(entry)
		local prev = first[identity]
		if not prev then
			first[identity] = key
		else
			local group = groups[identity]
			if not group then
				group = { prev }
				groups[identity] = group
			end
			group[#group + 1] = key
		end
	end
	local removed = 0
	for _, keys in pairs(groups) do
		table.sort(keys, function(a, b)
			local da, db = entryDate(deathlog_personal_data[a]), entryDate(deathlog_personal_data[b])
			return da < db or (da == db and a < b)
		end)
		local kept_key = keys[1]
		for i = 2, #keys do
			local key = keys[i]
			local stored, entry = deathlog_personal_data[kept_key], deathlog_personal_data[key]
			if entryDate(entry) - entryDate(stored) <= SAME_DEATH_WINDOW then
				if mergeDeath(stored, entry, false) == stored then
					deathlog_personal_data[key] = nil
				else
					deathlog_personal_data[kept_key] = nil
					kept_key = key
				end
				removed = removed + 1
			else
				kept_key = key
			end
		end
	end
	if removed > 0 then
		personal_count = nil
		pending_names = nil
	end
	return removed
end

local own_death

---@param player_data PlayerData
---@param flag string|nil  extra_data key set on the copy
---@return PlayerData
local function copyEntry(player_data, flag)
	local copy, extra = {}, {}
	for k, v in pairs(player_data) do
		copy[k] = v
	end
	if type(player_data["extra_data"]) == "table" then
		for k, v in pairs(player_data["extra_data"]) do
			extra[k] = v
		end
	end
	if flag then
		extra[flag] = true
	end
	copy["extra_data"] = extra
	return copy
end

--- HookOnSelfDeath callback: keeps the player's broadcast death at once, so it stays even if the shared log never gets it.
---@param player_data PlayerData  DNL broadcasts this table, so it is left untouched
function Deathlog_noteOwnDeath(player_data)
	own_death = { date = tonumber(player_data["date"]) or GetServerTime(), level = tonumber(player_data["level"]) or 0 }
	if not (Deathlog_isPersonalLogAvailable() and Deathlog_isPersonalLogEnabled()) then return end
	-- DNL's dev self-tests fire the hook on a living player.
	if not UnitIsDeadOrGhost("player") then return end
	local shared, checksum = Deathlog_findSharedDeath(UnitName("player"), own_death.date, own_death.level)
	if shared then
		own_death.key = Deathlog_addPersonalEntry(copyEntry(shared, "mirror"), checksum)
	else
		own_death.key = Deathlog_addPersonalEntry(copyEntry(player_data, "broadcast"))
	end
end

--- Marks the broadcast death kept by Deathlog_noteOwnDeath() that a later report (sync, another session) matches.
---@param player_data PlayerData
local function markBroadcastDeath(player_data)
	local level = tonumber(player_data["level"]) or 0
	local date = tonumber(player_data["date"]) or GetServerTime()
	local realm = GetRealmName()
	local best, best_diff
	for _, entry in pairs(deathlog_personal_data) do
		local extra = entry["extra_data"]
		if type(extra) == "table" and extra["broadcast"] and not extra["mirror"] and entry["name"] == player_data["name"]
			and Deathlog_personalEntryRealm(entry) == realm
		then
			local diff = math.abs(date - (tonumber(entry["date"]) or 0))
			if diff <= DeathNotificationLib.GetDedupWindow(math.max(level, tonumber(entry["level"]) or 0)) and (not best_diff or diff < best_diff) then
				best, best_diff = entry, diff
			end
		end
	end
	if best then
		best["extra_data"]["mirror"] = true
		pending_names = nil
	end
end

---@return table<string, boolean>
local function pendingNames()
	if not pending_names then
		pending_names = {}
		local realm = GetRealmName()
		for _, entry in pairs(deathlog_personal_data) do
			local extra = entry["extra_data"]
			if type(extra) == "table" and extra["broadcast"] and not extra["mirror"] and entry["name"] and Deathlog_personalEntryRealm(entry) == realm then
				pending_names[entry["name"]] = true
			end
		end
	end
	return pending_names
end

--- Called for every report the shared log stores: a kept broadcast death it matches, of any character on the account, becomes a mirror; every live report of the player's own death shares one key.
---@param player_data PlayerData  the shared-log entry, left untouched
---@param checksum string|nil
---@param source DNL_Source|nil
function Deathlog_mirrorOwnDeath(player_data, checksum, source)
	if source == SOURCE.DEBUG then return end
	local name = player_data["name"]
	local level = tonumber(player_data["level"]) or 0
	local date = tonumber(player_data["date"]) or GetServerTime()
	if own_death and name == UnitName("player") and MIRROR_SOURCES[source] and Deathlog_isPersonalLogAvailable() and Deathlog_isPersonalLogEnabled()
		and math.abs(date - own_death.date) <= DeathNotificationLib.GetDedupWindow(math.max(level, own_death.level))
	then
		own_death.key = Deathlog_addPersonalEntry(copyEntry(player_data, "mirror"), checksum, own_death.key)
	elseif name and pendingNames()[name] then
		markBroadcastDeath(player_data)
	end
end

---@return number
function Deathlog_personalLogCount()
	return countPersonal()
end

function Deathlog_clearPersonalLog()
	wipe(deathlog_personal_data)
	personal_count = 0
	pending_names = nil
end

--- deathlog_data plus the personal log under Deathlog_PERSONAL_LOG_KEY; deathlog_data itself is never touched.
---@param data table
---@param with_mirrors boolean|nil  keep the copies of shared-log deaths, which the shared log already holds
---@return table
function Deathlog_withPersonalLog(data, with_mirrors)
	local view = {}
	for realm, entries in pairs(data) do
		view[realm] = entries
	end
	local personal = deathlog_personal_data
	if not with_mirrors then
		personal = {}
		for key, entry in pairs(deathlog_personal_data) do
			if not Deathlog_isPersonalMirror(entry) then
				personal[key] = entry
			end
		end
	end
	view[Deathlog_PERSONAL_LOG_KEY] = personal
	return view
end
