--
--[[
Copyright 2023-2025 Yazpad (Aaron Ma) - original author
Copyright 2023-2026 Deathwing - current author
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
--
--

DeathlogDataCopy = {}
if DeathlogData then
	DeathlogDataCopy.PRECOMPUTED_GENERAL_STATS = DeathlogData.PRECOMPUTED_GENERAL_STATS
	DeathlogDataCopy.PRECOMPUTED_LOG_NORMAL_PARAMS = DeathlogData.PRECOMPUTED_LOG_NORMAL_PARAMS
	DeathlogDataCopy.PRECOMPUTED_LOG_NORMAL_PARAMS_BY_CAUSE = DeathlogData.PRECOMPUTED_LOG_NORMAL_PARAMS_BY_CAUSE
	DeathlogDataCopy.PRECOMPUTED_KAPLAN_MEIER = DeathlogData.PRECOMPUTED_KAPLAN_MEIER
	DeathlogDataCopy.PRECOMPUTED_KAPLAN_MEIER_BY_CAUSE = DeathlogData.PRECOMPUTED_KAPLAN_MEIER_BY_CAUSE
	DeathlogDataCopy.PRECOMPUTED_MOST_DEADLY_BY_ZONE = DeathlogData.PRECOMPUTED_MOST_DEADLY_BY_ZONE
	DeathlogDataCopy.PRECOMPUTED_CAUSE_STATS = DeathlogData.PRECOMPUTED_CAUSE_STATS
	DeathlogDataCopy.PRECOMPUTED_PURGES = DeathlogData.PRECOMPUTED_PURGES
end

DeathNotificationLibDataCopy = {}
if DeathNotificationLibData then
	DeathNotificationLibDataCopy.HEATMAP_INTENSITY = DeathNotificationLibData.HEATMAP_INTENSITY
	DeathNotificationLibDataCopy.HEATMAP_INTENSITY_BY_CAUSE = DeathNotificationLibData.HEATMAP_INTENSITY_BY_CAUSE
	DeathNotificationLibDataCopy.HEATMAP_CREATURE_SUBSET = DeathNotificationLibData.HEATMAP_CREATURE_SUBSET
end

local id_to_npc = DeathNotificationLib.ID_TO_NPC
local instance_to_id = DeathNotificationLib.INSTANCE_TO_ID
local id_to_instance = DeathNotificationLib.ID_TO_INSTANCE
local zone_to_id = DeathNotificationLib.ZONE_TO_ID
local deathlog_environment_damage = DeathNotificationLib.ENVIRONMENT_DAMAGE

local MAX_PLAYER_LEVEL = DeathNotificationLib.MAX_PLAYER_LEVEL

local source_kind = DeathNotificationLib.SOURCE_KIND or {
	ALL = "all",
	NPC = "npc",
	ENVIRONMENT = "environment",
	PVP = "pvp",
	REPORTED = "reported",
	UNKNOWN = "unknown",
}
local default_source_kind = source_kind.ALL

local source_kind_labels = {
	[default_source_kind] = "All Causes",
	[source_kind.NPC] = "NPC",
	[source_kind.ENVIRONMENT] = "Environment",
	[source_kind.PVP] = "PvP",
	[source_kind.REPORTED] = "Reported",
	[source_kind.UNKNOWN] = "Unknown",
}
local source_kind_option_order = {
	default_source_kind,
	source_kind.NPC,
	source_kind.ENVIRONMENT,
	source_kind.PVP,
	source_kind.REPORTED,
}

local source_kind_options = {}
for _, kind in ipairs(source_kind_option_order) do
	source_kind_options[kind] = source_kind_labels[kind]
end

local source_kind_summary_order = {
	source_kind.NPC,
	source_kind.PVP,
	source_kind.ENVIRONMENT,
	source_kind.REPORTED,
	source_kind.UNKNOWN,
}

-- Weak-keyed cache so computed display sources are never saved to SavedVariables.
-- Keys are entry tables; values are { cached = <string>, predicted = <string|nil> }.
local source_cache = setmetatable({}, { __mode = "k" })

Deathlog_ALL_INSTANCES_ID = -2

-- Build set of all valid instance IDs for ALL_INSTANCES aggregation
local all_instance_id_set = {}
for _, instances in pairs(instance_to_id) do
	for _, iid in pairs(instances) do
		all_instance_id_set[iid] = true
	end
end

-- ============================================================
-- Cooperative yielding for heavy precomputation
-- ============================================================
-- The precompute functions below iterate the entire death log. On large logs a
-- single function call exceeds Classic Era 1.15.9's per-frame "script ran too
-- long" limit. To stay under it we run the precompute inside a coroutine and
-- call Deathlog_YieldCheck() from the innermost per-entry loops: every
-- DEATHLOG_YIELD_CHUNK processed entries it yields back to the driver, which
-- resumes the coroutine on the next frame with a fresh script-time budget.
-- When not running inside our coroutine (e.g. the cached path or any synchronous
-- caller), Deathlog_YieldCheck() is a cheap no-op.
local DEATHLOG_YIELD_CHUNK = 300
local deathlog_yield_active = false
local deathlog_yield_counter = 0

function Deathlog_SetYieldActive(active)
	deathlog_yield_active = active and true or false
	deathlog_yield_counter = 0
end

function Deathlog_YieldCheck()
	if not deathlog_yield_active then
		return
	end
	deathlog_yield_counter = deathlog_yield_counter + 1
	-- WoW runs Lua 5.1, which has no coroutine.isyieldable(); use
	-- coroutine.running() (returns the current coroutine, or nil on the main
	-- thread) to confirm we're inside our precompute coroutine before yielding.
	if deathlog_yield_counter >= DEATHLOG_YIELD_CHUNK and coroutine.running() then
		deathlog_yield_counter = 0
		coroutine.yield()
	end
end

-- Instance minimum level requirements (from MapDifficulty game data + manual raid entries)
-- Maps instance_id -> minimum player level required to enter
local instance_min_levels = {
	-- Dungeons (from MapDifficulty)
	[389] = 8,   -- Ragefire Chasm
	[36] = 10,   -- Deadmines
	[43] = 10,   -- Wailing Caverns
	[33] = 11,   -- Shadowfang Keep
	[48] = 15,   -- Blackfathom Deeps
	[34] = 15,   -- Stormwind Stockade
	[90] = 19,   -- Gnomeregan
	[189] = 20,  -- Scarlet Monastery
	[349] = 25,  -- Maraudon
	[47] = 25,   -- Razorfen Kraul
	[70] = 30,   -- Uldaman
	[429] = 31,  -- Dire Maul
	[289] = 33,  -- Scholomance
	[129] = 35,  -- Razorfen Downs
	[329] = 37,  -- Stratholme
	[209] = 39,  -- Zul'Farrak
	[230] = 42,  -- Blackrock Depths
	[109] = 45,  -- Sunken Temple
	[229] = 48,  -- Blackrock Spire (UBRS)
	-- Raids (manual -- no MapDifficulty gate, attunement/practical minimums)
	[249] = 50,  -- Onyxia's Lair (Alliance 50, Horde 55 -- use lower bound)
	[309] = 50,  -- Zul'Gurub
	[469] = 50,  -- Blackwing Lair
	[509] = 50,  -- Ruins of Ahn'Qiraj
	[531] = 50,  -- Ahn'Qiraj Temple
	[409] = 50,  -- Molten Core
	[533] = 60,  -- Naxxramas
	-- PvP
	[30] = 51,   -- Alterac Valley
	[489] = 10,  -- Warsong Gulch
	[529] = 20,  -- Arathi Basin
}

-- TBC instance min levels
if GetExpansionLevel and GetExpansionLevel() >= 1 then
	local tbc_min_levels = {
		[543] = 57,  -- Hellfire Ramparts
		[542] = 58,  -- The Blood Furnace
		[547] = 59,  -- The Slave Pens
		[546] = 60,  -- The Underbog
		[557] = 61,  -- Mana-Tombs
		[558] = 62,  -- Auchenai Crypts
		[560] = 63,  -- The Escape From Durnholde
		[556] = 63,  -- Sethekk Halls
		[540] = 63,  -- The Shattered Halls
		[545] = 65,  -- The Steamvault
		[553] = 65,  -- The Botanica
		[554] = 65,  -- The Mechanar
		[552] = 65,  -- The Arcatraz
		[555] = 65,  -- Shadow Labyrinth
		[585] = 65,  -- Magister's Terrace
		[269] = 65,  -- Opening of the Dark Portal
		[566] = 61,  -- Eye of the Storm
		[559] = 70,  -- Nagrand Arena
		[562] = 70,  -- Blade's Edge Arena
		[572] = 70,  -- Ruins of Lordaeron
		[532] = 70,  -- Karazhan
		[565] = 70,  -- Gruul's Lair
		[544] = 70,  -- Magtheridon's Lair
		[548] = 70,  -- Serpentshrine Cavern
		[550] = 70,  -- Tempest Keep
		[534] = 70,  -- The Battle for Mount Hyjal
		[564] = 70,  -- Black Temple
		[568] = 70,  -- Zul'Aman
		[580] = 70,  -- The Sunwell
	}
	for k, v in pairs(tbc_min_levels) do
		instance_min_levels[k] = v
	end
end

-- Top-level map IDs
Deathlog_AZEROTH_ID = 947
Deathlog_EASTERN_KINGDOMS_ID = 1415
Deathlog_KALIMDOR_ID = 1414

Deathlog_ROOT_MAP_ID = Deathlog_AZEROTH_ID
Deathlog_ROOT_MAP_NAME = "Azeroth"

-- Zones that do not show heatmaps
local no_heatmap_zones = {}

-- Container zones (continents and world-level maps that aggregate child zone stats)
-- Use as a set: container_zone_set[map_id] = true
local container_zone_set = {
	[947] = true,  -- Azeroth
	[1414] = true, -- Kalimdor
	[1415] = true, -- Eastern Kingdoms
}

-- Zone parent mapping: zone_id -> parent_id
-- This defines the zone hierarchy for stats aggregation
local zone_parent_map = {
	-- Azeroth contains continents
	[1414] = 947, -- Kalimdor -> Azeroth
	[1415] = 947, -- Eastern Kingdoms -> Azeroth
	
	-- Eastern Kingdoms zones
	[1416] = 1415, -- Alterac Mountains
	[1417] = 1415, -- Arathi Highlands
	[1418] = 1415, -- Badlands
	[1419] = 1415, -- Blasted Lands
	[1420] = 1415, -- Tirisfal Glades
	[1421] = 1415, -- Silverpine Forest
	[1422] = 1415, -- Western Plaguelands
	[1423] = 1415, -- Eastern Plaguelands
	[1424] = 1415, -- Hillsbrad Foothills
	[1425] = 1415, -- The Hinterlands
	[1426] = 1415, -- Dun Morogh
	[1427] = 1415, -- Searing Gorge
	[1428] = 1415, -- Burning Steppes
	[1429] = 1415, -- Elwynn Forest
	[1430] = 1415, -- Deadwind Pass
	[1431] = 1415, -- Duskwood
	[1432] = 1415, -- Loch Modan
	[1433] = 1415, -- Redridge Mountains
	[1434] = 1415, -- Stranglethorn Vale
	[1435] = 1415, -- Swamp of Sorrows
	[1436] = 1415, -- Westfall
	[1437] = 1415, -- Wetlands
	[1453] = 1415, -- Stormwind City
	[1455] = 1415, -- Ironforge
	[1458] = 1415, -- Undercity
	
	-- Kalimdor zones
	[1411] = 1414, -- Durotar
	[1412] = 1414, -- Mulgore
	[1413] = 1414, -- The Barrens
	[1438] = 1414, -- Teldrassil
	[1439] = 1414, -- Darkshore
	[1440] = 1414, -- Ashenvale
	[1441] = 1414, -- Thousand Needles
	[1442] = 1414, -- Stonetalon Mountains
	[1443] = 1414, -- Desolace
	[1444] = 1414, -- Feralas
	[1445] = 1414, -- Dustwallow Marsh
	[1446] = 1414, -- Tanaris
	[1447] = 1414, -- Azshara
	[1448] = 1414, -- Felwood
	[1449] = 1414, -- Un'Goro Crater
	[1450] = 1414, -- Moonglade
	[1451] = 1414, -- Silithus
	[1452] = 1414, -- Winterspring
	[1454] = 1414, -- Orgrimmar
	[1456] = 1414, -- Thunder Bluff
	[1457] = 1414, -- Darnassus
	
	-- PvP zones in Azeroth
	[1459] = 1415, -- Alterac Valley (in Alterac Mountains area)
	[1460] = 1414, -- Warsong Gulch (in Ashenvale/Barrens area)
	[1461] = 1415, -- Arathi Basin (in Arathi Highlands)
}

-- TBC zones and hierarchy (add if expansion is available)
if GetExpansionLevel and GetExpansionLevel() >= 1 then
	Deathlog_WORLD_MAP_ID = 946
	Deathlog_OUTLAND_ID = 1945

	Deathlog_ROOT_MAP_ID = Deathlog_WORLD_MAP_ID
	Deathlog_ROOT_MAP_NAME = "Cosmos"

	no_heatmap_zones[946] = true  -- Cosmos

	container_zone_set[946] = true  -- Cosmos
	container_zone_set[1945] = true -- Outland

	-- In TBC, Cosmos becomes the top-level, containing both Azeroth and Outland
	zone_parent_map[947] = 946   -- Azeroth -> Cosmos
	zone_parent_map[1945] = 946  -- Outland -> Cosmos
	
	-- TBC starting zones attached to existing continents
	zone_parent_map[1941] = 1415 -- Eversong Woods (attached to EK)
	zone_parent_map[1942] = 1415 -- Ghostlands (attached to EK)
	zone_parent_map[1943] = 1414 -- Azuremyst Isle (attached to Kalimdor)
	zone_parent_map[1950] = 1414 -- Bloodmyst Isle (attached to Kalimdor)
	zone_parent_map[1954] = 1415 -- Silvermoon City (attached to EK)
	zone_parent_map[1947] = 1414 -- The Exodar (attached to Kalimdor)
	
	-- Outland zones parent to Outland
	zone_parent_map[1944] = 1945 -- Hellfire Peninsula
	zone_parent_map[1946] = 1945 -- Zangarmarsh
	zone_parent_map[1948] = 1945 -- Shadowmoon Valley
	zone_parent_map[1949] = 1945 -- Blade's Edge Mountains
	zone_parent_map[1951] = 1945 -- Nagrand
	zone_parent_map[1952] = 1945 -- Terokkar Forest
	zone_parent_map[1953] = 1945 -- Netherstorm
	zone_parent_map[1955] = 1945 -- Shattrath City
	zone_parent_map[1957] = 1945 -- Isle of Quel'Danas
end

-- Get all ancestor zone IDs for a given zone (including the zone itself)
-- Returns a table of zone IDs from the zone up to the Cosmos
function Deathlog_get_zone_ancestors(map_id)
	local ancestors = {}
	local current = map_id
	
	while current ~= nil do
		table.insert(ancestors, current)
		current = zone_parent_map[current]
	end
	
	-- Always include "all" as the top-level aggregator
	table.insert(ancestors, "all")
	
	return ancestors
end

-- Check if a zone is a "container" zone (continent or world-level)
-- These zones aggregate stats from their children
function Deathlog_is_container_zone(map_id)
	return container_zone_set[map_id] == true
end

-- Check if a zone should NOT show a heatmap (only Cosmos)
-- Continents can show aggregated heatmaps from child zones
function Deathlog_should_hide_heatmap(map_id)
	return no_heatmap_zones[map_id] == true
end

-- Normalize a map_id for stats lookup
-- Root Map always shows "all" stats
function Deathlog_normalize_map_id_for_stats(map_id)
	if map_id == nil then
		return "all"
	end
	-- For Root Map, include all data
	if map_id == Deathlog_ROOT_MAP_ID then
		return "all"
	end
	return map_id
end

-- Check if viewing a container zone that should show aggregated stats
function Deathlog_should_show_container_stats(map_id)
	return container_zone_set[map_id] == true
end

Deathlog_class_tbl = {
	["Warrior"] = 1,
	["Paladin"] = 2,
	["Hunter"] = 3,
	["Rogue"] = 4,
	["Priest"] = 5,
	["Shaman"] = 7,
	["Mage"] = 8,
	["Warlock"] = 9,
	["Druid"] = 11,
}

Deathlog_id_to_class_tbl = {
	[1] = "Warrior",
	[2] = "Paladin",
	[3] = "Hunter",
	[4] = "Rogue",
	[5] = "Priest",
	[7] = "Shaman",
	[8] = "Mage",
	[9] = "Warlock",
	[11] = "Druid",
}

Deathlog_race_tbl = {
	["Human"] = 1,
	["Orc"] = 2,
	["Dwarf"] = 3,
	["Night Elf"] = 4,
	["Undead"] = 5,
	["Tauren"] = 6,
	["Gnome"] = 7,
	["Troll"] = 8,
}
if GetExpansionLevel and GetExpansionLevel() >= 1 then
	Deathlog_race_tbl["Blood Elf"] = 10
	Deathlog_race_tbl["Draenei"] = 11
end
-- sort function from stack overflow
local function spairs(t, order)
	local keys = {}
	for k in pairs(t) do
		keys[#keys + 1] = k
	end

	if order then
		table.sort(keys, function(a, b)
			return order(t, a, b)
		end)
	else
		table.sort(keys)
	end

	local i = 0
	return function()
		i = i + 1
		if keys[i] then
			return keys[i], t[keys[i]]
		end
	end
end

function DeathlogShallowCopy(t)
	local t2 = {}
	for k, v in pairs(t) do
		t2[k] = v
	end
	return t2
end

function DeathlogPredictSource(entry)
	local search_radius = (deathlog_settings and deathlog_settings["prediction_radius"]) or 5

	return DeathNotificationLib.PredictSource(entry, search_radius)
end

function DeathlogGetCachedSource(entry)
	if not entry then
		return ""
	end

	local sc = source_cache[entry]
	if not sc then
		sc = {}
		source_cache[entry] = sc
	end

	if sc.cached then
		return sc.cached
	end

	-- clear old predicted_source / cached_source from entry
	if entry.predicted_source then entry.predicted_source = nil end
	if entry.cached_source then entry.cached_source = nil end

	local _pvp_source_name = entry["extra_data"] and entry["extra_data"]["pvp_source_name"]
	local _sid = tonumber(entry["source_id"])
	local _reported = _sid == -1
	local _source = (_sid and not _reported) and Deathlog_GetSourceNameById(_sid, _pvp_source_name) or ""

	if _source == "" then
		if sc.predicted then
			_source = sc.predicted
		else
			local predicted = DeathlogPredictSource(entry)
			if predicted then
				sc.predicted = predicted
				_source = predicted
			elseif _reported then
				_source = Deathlog_GetSourceKindLabel(source_kind.UNKNOWN)
			end
		end
	end

	sc.cached = _source
	return _source
end

function Deathlog_GetSourceKindOptions()
	return source_kind_options
end

function Deathlog_GetSourceKindConstants()
	return source_kind
end

function Deathlog_GetDefaultSourceKind()
	return default_source_kind
end

function Deathlog_GetConfiguredSourceKind(settings_tbl, key)
	if type(settings_tbl) ~= "table" then
		return default_source_kind
	end
	return Deathlog_NormalizeSourceKind(settings_tbl[key or "source_kind"])
end

function Deathlog_GetWidgetSourceKind(widget_name)
	return Deathlog_GetConfiguredSourceKind(deathlog_settings and deathlog_settings[widget_name], "source_kind")
end

function Deathlog_GetSourceKindOptionOrder()
	return source_kind_option_order
end

function Deathlog_GetSourceKindSummaryOrder()
	return source_kind_summary_order
end

function Deathlog_GetSourceKind(entry_or_source_id)
	local source_id = entry_or_source_id
	if type(entry_or_source_id) == "table" then
		source_id = entry_or_source_id["source_id"]
	end
	return DeathNotificationLib.GetSourceKind(source_id)
end

function Deathlog_GetSourceKindLabel(source_id_or_kind)
	local kind = source_id_or_kind
	if source_kind_labels[kind] == nil then
		kind = Deathlog_GetSourceKind(source_id_or_kind)
	end
	return source_kind_labels[kind] or source_kind_labels[source_kind.UNKNOWN]
end

function Deathlog_NormalizeSourceKind(selected_kind)
	if not selected_kind or selected_kind == default_source_kind then
		return default_source_kind
	end
	if source_kind_options[selected_kind] ~= nil or selected_kind == source_kind.UNKNOWN then
		return selected_kind
	end
	return default_source_kind
end

function Deathlog_SourceMatchesKind(entry_or_source_id, selected_kind)
	selected_kind = Deathlog_NormalizeSourceKind(selected_kind)
	if selected_kind == default_source_kind then
		return true
	end
	return Deathlog_GetSourceKind(entry_or_source_id) == selected_kind
end

function Deathlog_GetHeatmapIntensityForSourceKind(selected_kind)
	selected_kind = Deathlog_NormalizeSourceKind(selected_kind)
	if selected_kind ~= default_source_kind then
		local by_cause = DeathNotificationLibDataCopy and DeathNotificationLibDataCopy.HEATMAP_INTENSITY_BY_CAUSE
		if by_cause then
			return by_cause[selected_kind]
		end
		return nil
	end

	return DeathNotificationLibDataCopy and DeathNotificationLibDataCopy.HEATMAP_INTENSITY
end

local function getPrecomputedTableForSourceKind(base_table, by_cause_table, selected_kind)
	selected_kind = Deathlog_NormalizeSourceKind(selected_kind)
	if selected_kind ~= default_source_kind and by_cause_table and by_cause_table[selected_kind] then
		return by_cause_table[selected_kind]
	end
	return base_table
end

function Deathlog_GetLogNormalParamsForSourceKind(selected_kind)
	return getPrecomputedTableForSourceKind(
		DeathlogDataCopy and DeathlogDataCopy.PRECOMPUTED_LOG_NORMAL_PARAMS,
		DeathlogDataCopy and DeathlogDataCopy.PRECOMPUTED_LOG_NORMAL_PARAMS_BY_CAUSE,
		selected_kind
	)
end

function Deathlog_GetKaplanMeierForSourceKind(selected_kind)
	return getPrecomputedTableForSourceKind(
		DeathlogDataCopy and DeathlogDataCopy.PRECOMPUTED_KAPLAN_MEIER,
		DeathlogDataCopy and DeathlogDataCopy.PRECOMPUTED_KAPLAN_MEIER_BY_CAUSE,
		selected_kind
	)
end

--- Aggregate class stats for a selected source kind, shared by all class-stat MenuElements.
--- Returns nil when there is no data for the given kind.
function Deathlog_getFilteredClassEntry(class_stats, selected_source_kind)
	if class_stats == nil then
		return nil
	end
	if selected_source_kind == Deathlog_GetDefaultSourceKind() then
		return class_stats["all"]
	end

	local filtered_entry = {
		num_entries = 0,
		sum_lvl = 0,
		avg_lvl = 0,
	}
	for source_id, stat_entry in pairs(class_stats) do
		if source_id ~= "all" and type(stat_entry) == "table" and Deathlog_SourceMatchesKind(source_id, selected_source_kind) then
			filtered_entry.num_entries = filtered_entry.num_entries + (stat_entry["num_entries"] or 0)
			filtered_entry.sum_lvl = filtered_entry.sum_lvl + (stat_entry["sum_lvl"] or 0)
		end
	end
	if filtered_entry.num_entries <= 0 then
		return nil
	end
	filtered_entry.avg_lvl = filtered_entry.sum_lvl / filtered_entry.num_entries
	return filtered_entry
end

function Deathlog_GetSourceNameById(source_id, pvp_source_name)
	local source_id_num = tonumber(source_id)
	if not source_id_num then
		return ""
	end

	if id_to_npc[source_id_num] then
		return id_to_npc[source_id_num]
	end

	if deathlog_environment_damage[source_id_num] then
		return deathlog_environment_damage[source_id_num]
	end

	local pvp_source = DeathNotificationLib.DecodePvPSource(source_id_num, pvp_source_name)
	if pvp_source and pvp_source ~= "" then
		return pvp_source
	end

	-- if source_id_num == -1 then
	-- 	return Deathlog_GetSourceKindLabel(source_kind.REPORTED)
	-- end

	return ""
end

-- Tue Apr 18 21:36:54 2023
function DeathlogConvertStringDateUnix(s)
	if tonumber(s) then
		return s
	end
	local p = "%a+ (%a+) (%d+) (%d+):(%d+):(%d+) (%d+)"
	local month, day, hour, minute, sec, year = s:match(p)
	if month == nil or day == nil or hour == nil or minute == nil or sec == nil or year == nil then
		p = "%a+ (%a+)  (%d+) (%d+):(%d+):(%d+) (%d+)"
		month, day, hour, minute, sec, year = s:match(p)
	end
	if month == nil or day == nil or hour == nil or minute == nil or sec == nil or year == nil then
		return nil
	end
	local MON = {
		Jan = 1,
		Feb = 2,
		Mar = 3,
		Apr = 4,
		May = 5,
		Jun = 6,
		Jul = 7,
		Aug = 8,
		Sep = 9,
		Oct = 10,
		Nov = 11,
		Dec = 12,
	}
	month = MON[month]
---@diagnostic disable-next-line: param-type-mismatch
	local offset = time() - time(date("!*t"))
	return time({ day = day, month = month, year = year, hour = hour, minute = minute, sec = sec }) + offset
end

--- Parse a map_pos value that may be a string "x,y" or a table {x=, y=}.
--- Returns x, y as numbers, or nil if invalid.
function Deathlog_parseMapPos(mp)
	if not mp then return nil end
	if type(mp) == "table" then
		return mp.x, mp.y
	end
	return strsplit(",", mp, 2)
end

function Deathlog_fletcher16(name, guild, level, source)
	local data = name .. (guild or "") .. level .. source
	local sum1 = 0
	local sum2 = 0
	for index = 1, #data do
		sum1 = (sum1 + string.byte(string.sub(data, index, index))) % 255
		sum2 = (sum2 + sum1) % 255
	end
	return name .. "-" .. bit.bor(bit.lshift(sum2, 8), sum1)
end

local function generate_player_metadata(metadata_list)
	local metadata = {
		["num_entries"] = 0,
		["sum_lvl"] = 0,
		["avg_lvl"] = 0,
	}
	metadata_list[#metadata_list + 1] = metadata
	return metadata
end

--- Returns true if the entry should be visible given the current settings.
--- Addonless entries (no class_id, no race_id) are hidden when addonless_logging
--- is disabled, preventing synced low-quality entries from cluttering the view.
function Deathlog_shouldShowEntry(entry)
	if entry == nil then
		return false
	end
	if deathlog_hidden_names and deathlog_hidden_names[entry["name"]] then
		return false
	end
	-- Filter entries with level exceeding the max player level (e.g. GM test chars)
	if entry["level"] and entry["level"] > MAX_PLAYER_LEVEL then
		return false
	end
	-- Filter entries below instance minimum level
	local iid = entry["instance_id"]
	if iid and entry["level"] then
		local min_lvl = instance_min_levels[iid]
		if min_lvl and entry["level"] < min_lvl then
			return false
		end
	end
	-- If addonless_logging is enabled, show everything
	if deathlog_settings and deathlog_settings["addonless_logging"] then
		return true
	end
	-- Addonless gate: entries with neither class nor race are Blizzard-sourced
	-- deaths from players not running the addon.
	if not entry["class_id"] and not entry["race_id"] then
		return false
	end
	return true
end

function DeathlogFilter(_deathlog_data, filter)
	local filtered_death_log = {}
	for server_name, entry_tbl in pairs(_deathlog_data) do
		filtered_death_log[server_name] = {}
		for checksum, entry in pairs(entry_tbl) do
			-- A single full-dataset filter can overrun one frame on large logs.
			-- No-op unless running inside the precompute coroutine.
			Deathlog_YieldCheck()
			if Deathlog_shouldShowEntry(entry) and filter(server_name, entry) then
				filtered_death_log[server_name][checksum] = entry
			end
		end
	end

	return filtered_death_log
end

function DeathlogOrderBy(_deathlog, order_function)
	local unordered_list = {}
	local ordered = {}
	for server_name, entry_tbl in pairs(_deathlog) do
		for _, v in pairs(entry_tbl) do
			unordered_list[#unordered_list + 1] = v
		end
	end
	for i, v in spairs(unordered_list, order_function) do
		table.insert(ordered, v)
	end
	return ordered
end

-- Only limits at or below this use the linear insertion-based top-N pick. That
-- pass is O(n * limit), so it is only cheaper than a full sort for SMALL limits
-- (e.g. the minilog's ~20 rows). For large limits (e.g. the log menu's cap of a
-- few thousand) the insertion pass becomes pathological and can trip the
-- client's "script ran too long" limit, so those fall through to a single
-- O(n log n) table.sort and are truncated afterwards.
local DEATHLOG_TOPN_LINEAR_LIMIT = 200

-- Sorts by date descending. `limit` is optional:
--   * small limit  -> newest `limit` entries picked in a linear insertion pass
--     (no table.sort at all), ideal for the minilog.
--   * large / no limit -> bucket entries by date and sort only the (much
--     smaller) set of DISTINCT dates.
--
-- Why not table.sort(list, comparator)? On very large logs that threw
-- "sort ran for too long": table.sort has its own time watchdog, and a Lua
-- closure comparator makes every one of the ~n*log(n) comparisons a slow
-- Lua->C->Lua call. Sorting the distinct dates instead keeps the sorted set
-- tiny AND uses table.sort's DEFAULT (C-level) numeric comparator with no Lua
-- callback, so the watchdog is never hit even for the whole database.
function DeathlogOrderByFast(_deathlog, limit)
	local list = {}
	local dates = {}
	local n = 0
	for _, entry_tbl in pairs(_deathlog) do
		for _, v in pairs(entry_tbl) do
			if Deathlog_shouldShowEntry(v) then
				n = n + 1
				list[n] = v
				dates[n] = tonumber(v.date) or 0
			end
		end
	end

	if limit and limit > 0 and limit < n and limit <= DEATHLOG_TOPN_LINEAR_LIMIT then
		-- Keep a small list of the newest entries, held sorted descending by insertion.
		local top = {}
		local top_dates = {}
		local count = 0
		for i = 1, n do
			local date = dates[i]
			local insert = false
			if count < limit then
				count = count + 1
				insert = true
			elseif date > top_dates[count] then
				insert = true
			end
			if insert then
				local pos = count
				while pos > 1 and top_dates[pos - 1] < date do
					top[pos] = top[pos - 1]
					top_dates[pos] = top_dates[pos - 1]
					pos = pos - 1
				end
				top[pos] = list[i]
				top_dates[pos] = date
			end
		end
		return top
	end

	-- Bucket entries by date, then sort only the distinct dates.
	local buckets = {}
	local distinct = {}
	local distinct_n = 0
	for i = 1, n do
		local date = dates[i]
		local bucket = buckets[date]
		if bucket == nil then
			bucket = {}
			buckets[date] = bucket
			distinct_n = distinct_n + 1
			distinct[distinct_n] = date
		end
		bucket[#bucket + 1] = list[i]
	end

	-- Default comparator => C-level numeric sort, no Lua callback per comparison.
	table.sort(distinct)

	-- Emit entries newest-first by walking the sorted distinct dates in reverse.
	local ordered = {}
	local k = 0
	local cap = (limit and limit > 0 and limit < n) and limit or n
	for di = distinct_n, 1, -1 do
		local bucket = buckets[distinct[di]]
		for j = 1, #bucket do
			k = k + 1
			ordered[k] = bucket[j]
			if k >= cap then
				return ordered
			end
		end
	end

	return ordered
end

local function calculateCDF(ln_mean, ln_std_dev)
	local function logNormal(x, mean, sigma)
		return (1 / (x * sigma * sqrt(2 * 3.14)))
			* exp((-1 / 2) * ((math.log(x) - mean) / sigma) * ((math.log(x) - mean) / sigma))
	end
	local cdf = {}
	cdf[1] = logNormal(1, ln_mean, sqrt(ln_std_dev))
	for i = 2, MAX_PLAYER_LEVEL do
		cdf[i] = cdf[i - 1] + logNormal(i, ln_mean, sqrt(ln_std_dev))
	end
	return cdf
end

function Deathlog_CalculateCDF(ln_mean, ln_std_dev)
	return calculateCDF(ln_mean, ln_std_dev)
end

function Deathlog_CalculateCDF2(ln_mean, ln_sig)
	local a1 = 0.278393
	local a2 = 0.230389
	local a3 = 0.000972
	local a4 = 0.078108

	local function erf(x)
		local negative = 1
		if x < 0 then
			x = -x
			negative = -1
		end
		local denom = (1 + a1 * x + a2 * x * x + a3 * x * x * x + a4 * x * x * x * x)
		local denom = denom * denom * denom * denom
		return negative * (1 - 1 / denom)
	end

	local cdf = {}

	for i = 1, MAX_PLAYER_LEVEL do
		local err_term = erf((math.log(i) - ln_mean) / (sqrt(2) * ln_sig))
		cdf[i] = (1 / 2) * (1 + err_term)
	end
	return cdf
end

-- Example input stats, {"all", "all", "all", nil} to get most deadly mob
function DeathlogGetOrderedNormalized(stats, parameters, ln_mean, ln_std_dev)
	local function normalizeFunc(kills, pr)
		return kills / pr
	end
	local function calculateNormalizedValue(kills, avg_lvl, cdf)
		if kills < 10 then
			return 0
		end
		local idx = ceil(avg_lvl)
		if idx > #cdf then idx = #cdf end
		local pr = 1 - cdf[idx]
		return normalizeFunc(kills, pr)
	end
	local cdf = calculateCDF(ln_mean, ln_std_dev)
	local unordered_list = {}
	local ordered = {}
	local prefix_stats = stats
	local post_parameters = {}
	local active = false
	for _, v in ipairs(parameters) do
		if active then
			post_parameters[#post_parameters + 1] = v
		else
			if v == nil then
				active = true
			else
				if prefix_stats[v] == nil then
					return nil
				end
				prefix_stats = prefix_stats[v]
			end
		end
	end

	for k, entry in pairs(prefix_stats) do
		if k ~= "all" then
			local postfix_stats = entry
			for _, p in ipairs(post_parameters) do
				postfix_stats = postfix_stats[p]
			end
			table.insert(unordered_list, { k, postfix_stats["num_entries"], postfix_stats["avg_lvl"] })
		end
	end
	for i, item in
		spairs(unordered_list, function(t, a, b)
			return calculateNormalizedValue(t[b][2], t[b][3], cdf) < calculateNormalizedValue(t[a][2], t[a][3], cdf)
		end)
	do
		table.insert(ordered, { item[1], calculateNormalizedValue(item[2], item[3], cdf) })
	end
	return ordered
end

-- Example input stats, {"all", "all", "all", nil} to get most deadly mob
function DeathlogGetOrdered(stats, parameters)
	local unordered_list = {}
	local ordered = {}
	local prefix_stats = stats
	local post_parameters = {}
	local active = false
	for _, param in ipairs(parameters) do
		if active then
			post_parameters[#post_parameters + 1] = param
		else
			if param == nil then
				active = true
			else
				if prefix_stats[param] == nil then
					return nil
				end
				prefix_stats = prefix_stats[param]
			end
		end
	end

	for k, entry in pairs(prefix_stats) do
		if k ~= "all" then
			local postfix_stats = entry
			for _, p in ipairs(post_parameters) do
				postfix_stats = postfix_stats[p]
			end
			if k ~= -1 then
				table.insert(unordered_list, { k, postfix_stats["num_entries"] })
			end
		end
	end
	for _, item in
		spairs(unordered_list, function(t, a, b)
			return t[b][2] < t[a][2]
		end)
	do
		table.insert(ordered, item)
	end
	return ordered
end

local function updateEntry(stats_leaf, entry)
	stats_leaf["num_entries"] = stats_leaf["num_entries"] + 1
	stats_leaf["sum_lvl"] = stats_leaf["sum_lvl"] + entry["level"]
end

local function updateStats(stats, server_name, entry)
	local entry_map_id = entry["map_id"] or entry["instance_id"] or "all"
	local source_id = tonumber(entry["source_id"]) or "all"
	
	-- Get all zones this entry should contribute to (zone + all ancestors)
	local zones_to_update = Deathlog_get_zone_ancestors(entry_map_id)
	
	-- Always update "all" stats
	updateEntry(stats["all"]["all"]["all"]["all"], entry)
	updateEntry(stats[server_name]["all"]["all"]["all"], entry)
	updateEntry(stats["all"]["all"][entry["class_id"]]["all"], entry)
	updateEntry(stats["all"]["all"]["all"][source_id], entry)
	updateEntry(stats["all"]["all"][entry["class_id"]][source_id], entry)
	
	-- Update stats for each zone in the hierarchy
	for _, zone_id in ipairs(zones_to_update) do
		if zone_id ~= "all" then -- "all" already updated above
			updateEntry(stats["all"][zone_id]["all"]["all"], entry)
			updateEntry(stats[server_name][zone_id]["all"]["all"], entry)
			updateEntry(stats["all"][zone_id][entry["class_id"]]["all"], entry)
			updateEntry(stats["all"][zone_id][entry["class_id"]][source_id], entry)
			updateEntry(stats["all"][zone_id]["all"][source_id], entry)
			updateEntry(stats[server_name][zone_id][entry["class_id"]][source_id], entry)
		end
	end

	-- Aggregate into "all instances" bucket if this is an instance death
	local iid = entry["instance_id"]
	if iid and all_instance_id_set[iid] then
		local aid = Deathlog_ALL_INSTANCES_ID
		updateEntry(stats["all"][aid]["all"]["all"], entry)
		updateEntry(stats["all"][aid][entry["class_id"]]["all"], entry)
		updateEntry(stats["all"][aid][entry["class_id"]][source_id], entry)
		updateEntry(stats["all"][aid]["all"][source_id], entry)
	end
end

local function instantiateIfMissing(_stats, server_name, entry, _metadata_list)
	local entry_map_id = entry["map_id"] or entry["instance_id"] or "all"
	local class_id = entry["class_id"] or "all"
	local source_id = tonumber(entry["source_id"]) or "all"
	
	-- Get all zones this entry should contribute to
	local zones_to_update = Deathlog_get_zone_ancestors(entry_map_id)

	if _stats[server_name] == nil then
		_stats[server_name] = {
			["all"] = {
				["all"] = {
					["all"] = generate_player_metadata(_metadata_list),
				},
			},
		}
	end

	-- Ensure stats structures exist for all zones in hierarchy
	for _, zone_id in ipairs(zones_to_update) do
		if zone_id ~= "all" then
			if _stats["all"][zone_id] == nil then
				_stats["all"][zone_id] = {
					["all"] = {
						["all"] = generate_player_metadata(_metadata_list),
					},
				}
			end

			if _stats[server_name][zone_id] == nil then
				_stats[server_name][zone_id] = {
					["all"] = {
						["all"] = generate_player_metadata(_metadata_list),
					},
				}
			end

			if _stats["all"][zone_id][class_id] == nil then
				_stats["all"][zone_id][class_id] = {
					["all"] = generate_player_metadata(_metadata_list),
				}
			end

			if _stats[server_name][zone_id][class_id] == nil then
				_stats[server_name][zone_id][class_id] = {
					["all"] = generate_player_metadata(_metadata_list),
				}
			end

			if _stats["all"][zone_id][class_id][source_id] == nil then
				_stats["all"][zone_id][class_id][source_id] = generate_player_metadata(_metadata_list)
			end
			if _stats["all"][zone_id]["all"][source_id] == nil then
				_stats["all"][zone_id]["all"][source_id] = generate_player_metadata(_metadata_list)
			end
			if _stats[server_name][zone_id][class_id][source_id] == nil then
				_stats[server_name][zone_id][class_id][source_id] = generate_player_metadata(_metadata_list)
			end
		end
	end

	-- Ensure "all instances" aggregation bucket exists for instance deaths
	local iid = entry["instance_id"]
	if iid and all_instance_id_set[iid] then
		local aid = Deathlog_ALL_INSTANCES_ID
		if _stats["all"][aid] == nil then
			_stats["all"][aid] = {
				["all"] = {
					["all"] = generate_player_metadata(_metadata_list),
				},
			}
		end
		if _stats["all"][aid][class_id] == nil then
			_stats["all"][aid][class_id] = {
				["all"] = generate_player_metadata(_metadata_list),
			}
		end
		if _stats["all"][aid][class_id][source_id] == nil then
			_stats["all"][aid][class_id][source_id] = generate_player_metadata(_metadata_list)
		end
		if _stats["all"][aid]["all"][source_id] == nil then
			_stats["all"][aid]["all"][source_id] = generate_player_metadata(_metadata_list)
		end
	end

	-- Always ensure "all" level structures exist
	if _stats["all"]["all"][class_id] == nil then
		_stats["all"]["all"][class_id] = {
			["all"] = generate_player_metadata(_metadata_list),
		}
	end

	if _stats["all"]["all"]["all"][source_id] == nil then
		_stats["all"]["all"]["all"][source_id] = generate_player_metadata(_metadata_list)
	end
	if _stats["all"]["all"][class_id][source_id] == nil then
		_stats["all"]["all"][class_id][source_id] = generate_player_metadata(_metadata_list)
	end
end

-- [server][map_id][class_id][source_id] = {num_entries, sum_lvl, avg_level}
function Deathlog_calculate_statistics(_deathlog_data)
	local metadata_list = {}
	local stats = {
		["all"] = {
			["all"] = {
				["all"] = {
					["all"] = generate_player_metadata(metadata_list),
				},
			},
		},
	}

	-- First pass
	for server_name, entry_tbl in pairs(_deathlog_data) do
		for checksum, entry in pairs(entry_tbl) do
			if Deathlog_shouldShowEntry(entry) and entry["class_id"] then
				instantiateIfMissing(stats, server_name, entry, metadata_list)

				local map_id = entry["map_id"] or entry["instance_id"] or "all"
				updateStats(stats, server_name, entry)
				Deathlog_YieldCheck()
			end
		end
	end

	for k, v in ipairs(metadata_list) do
		if v["num_entries"] > 0 then
			v["avg_lvl"] = v["sum_lvl"] / v["num_entries"]
		else
			v["avg_lvl"] = 0
		end
	end

	-- local ordered = DeathlogGetOrdered(stats, {"all", "all", "all", nil})
	-- for i,v in ipairs(ordered) do
	--   if i < 25 then
	--     print(i, id_to_npc[v[1]], v[2])
	--   end
	-- end

	return stats
end

function Deathlog_serializeTable(val, name, skipnewlines, depth)
	skipnewlines = skipnewlines or false
	depth = depth or 0

	local tmp = string.rep(" ", depth)

	if name then
		if type(name) == "string" then
			tmp = tmp .. "['" .. name .. "']" .. " = "
		else
			tmp = tmp .. "[" .. name .. "]" .. " = "
		end
	end

	if type(val) == "table" then
		tmp = tmp .. "{" .. (not skipnewlines and "\n" or "")

		for k, v in pairs(val) do
			tmp = tmp
				.. Deathlog_serializeTable(v, k, skipnewlines, depth + 1)
				.. ","
				.. (not skipnewlines and "\n" or "")
		end

		tmp = tmp .. string.rep(" ", depth) .. "}"
	elseif type(val) == "number" then
		tmp = tmp .. tostring(val)
	elseif type(val) == "string" then
		tmp = tmp .. string.format("%q", val)
	elseif type(val) == "boolean" then
		tmp = tmp .. (val and "true" or "false")
	else
		tmp = tmp .. '"[inserializeable datatype:' .. type(val) .. ']"'
	end

	return tmp
end

-- Single-pass computation of per-zone, per-class level distributions.
--
-- The previous implementation called a per-map helper for EVERY zone and EVERY
-- instance, and each call scanned the entire death log (O(maps * entries)). On a
-- large log that is minutes of work even when spread across frames. This version
-- makes a single pass over the log, bucketing each entry's level into every map
-- it contributes to (its zone + all container ancestors + the "all" aggregate,
-- plus the "all instances" bucket for instance deaths) — exactly mirroring the
-- targeting used by Deathlog_calculate_statistics — then computes the log-normal
-- parameters once per (map, class). Complexity is O(entries * ancestors), the
-- same as the statistics pass. Maps with no matching deaths are simply absent
-- from the result (nil); all consumers already null-guard these lookups.
function Deathlog_calculateLogNormalParameters(_deathlog_data)
	-- levels_by_map[map_id][class_id] = { level, level, ... }
	local levels_by_map = {}

	local function bucketLevel(map_id, class_id, level)
		local by_class = levels_by_map[map_id]
		if by_class == nil then
			by_class = {}
			levels_by_map[map_id] = by_class
		end
		local levels = by_class[class_id]
		if levels == nil then
			levels = {}
			by_class[class_id] = levels
		end
		levels[#levels + 1] = level
	end

	for _, entry_tbl in pairs(_deathlog_data) do
		for _, entry in pairs(entry_tbl) do
			if Deathlog_shouldShowEntry(entry) then
				local class_id = entry["class_id"]
				local level = entry["level"]
				if class_id and level and level > 0 then
					-- "all" aggregate across every zone.
					bucketLevel("all", class_id, level)

					-- The entry's own zone and all its container ancestors.
					local entry_map_id = entry["map_id"] or entry["instance_id"]
					if entry_map_id then
						local ancestors = Deathlog_get_zone_ancestors(entry_map_id)
						for _, zone_id in ipairs(ancestors) do
							if zone_id ~= "all" then
								bucketLevel(zone_id, class_id, level)
							end
						end
					end

					-- "all instances" aggregate bucket for instance deaths.
					local iid = entry["instance_id"]
					if iid and all_instance_id_set[iid] then
						bucketLevel(Deathlog_ALL_INSTANCES_ID, class_id, level)
					end
				end
			end
			Deathlog_YieldCheck()
		end
	end

	-- Compute log-normal params per (map, class): result[class_id] = {ln_mean, ln_std_dev, total}
	local log_normal_params = {}
	for map_id, by_class in pairs(levels_by_map) do
		local result = {}
		for class_id, levels in pairs(by_class) do
			local total = #levels
			if total > 0 then
				local ln_mean = 0
				for _, lvl in ipairs(levels) do
					ln_mean = ln_mean + math.log(lvl)
					Deathlog_YieldCheck()
				end
				ln_mean = ln_mean / total

				local ln_std_dev = 0
				for _, lvl in ipairs(levels) do
					local diff = math.log(lvl) - ln_mean
					ln_std_dev = ln_std_dev + diff * diff
					Deathlog_YieldCheck()
				end
				ln_std_dev = ln_std_dev / total
				if ln_std_dev < 0.01 then ln_std_dev = 0.01 end

				result[class_id] = { ln_mean, ln_std_dev, total }
			end
		end
		log_normal_params[map_id] = result
		Deathlog_YieldCheck()
	end

	return log_normal_params
end

local function filterDeathlogDataBySourceKind(_deathlog_data, selected_source_kind)
	return DeathlogFilter(_deathlog_data, function(_, entry)
		return Deathlog_SourceMatchesKind(entry, selected_source_kind)
	end)
end

function Deathlog_calculateLogNormalParametersByCause(_deathlog_data)
	local log_normal_params_by_cause = {}
	log_normal_params_by_cause[default_source_kind] = Deathlog_calculateLogNormalParameters(_deathlog_data)

	for _, kind in ipairs(source_kind_summary_order) do
		log_normal_params_by_cause[kind] =
			Deathlog_calculateLogNormalParameters(filterDeathlogDataBySourceKind(_deathlog_data, kind))
	end

	return log_normal_params_by_cause
end

-- Kaplan-Meier computation is disabled (requires statistical library not available in Lua).
-- The Python preprocessor also has this commented out; the precomputed data ships as {}.
function Deathlog_calculateKaplanMeier(_deathlog_data)
	return {}
end

function Deathlog_calculateKaplanMeierByCause(_deathlog_data)
	-- Kaplan-Meier is disabled (stub returns {}), so skip the expensive
	-- filterDeathlogDataBySourceKind work and just return an empty table.
	return {}
end

-- Count deaths per creature per zone, then rank top 10 per zone.
-- Structure: result[zone_id][creature_id] = rank (1-10)
function Deathlog_calculateMostDeadlyByZone(_deathlog_data)
	local creature_deaths_by_zone = { ["all"] = {} }

	for _, entry_tbl in pairs(_deathlog_data) do
		for _, v in pairs(entry_tbl) do
			Deathlog_YieldCheck()
			local source_id = tonumber(v["source_id"])
			if source_id then
				-- Count for "all" zones
				creature_deaths_by_zone["all"][source_id] = (creature_deaths_by_zone["all"][source_id] or 0) + 1

				-- Count for specific zone and all parent zones
				local map_id = v["map_id"]
				if map_id then
					local ancestors = Deathlog_get_zone_ancestors(map_id)
					for _, zone_id in ipairs(ancestors) do
						if zone_id ~= "all" then -- already counted above
							if creature_deaths_by_zone[zone_id] == nil then
								creature_deaths_by_zone[zone_id] = {}
							end
							creature_deaths_by_zone[zone_id][source_id] = (creature_deaths_by_zone[zone_id][source_id] or 0) + 1
						end
					end
				end

				-- Aggregate into "all instances" bucket
				local instance_id = v["instance_id"]
				if instance_id and all_instance_id_set[instance_id] then
					if creature_deaths_by_zone[Deathlog_ALL_INSTANCES_ID] == nil then
						creature_deaths_by_zone[Deathlog_ALL_INSTANCES_ID] = {}
					end
					creature_deaths_by_zone[Deathlog_ALL_INSTANCES_ID][source_id] = (creature_deaths_by_zone[Deathlog_ALL_INSTANCES_ID][source_id] or 0) + 1
				end
			end
		end
	end

	-- Rank top 10 creatures per zone
	local most_deadly_by_zone = {}
	for zone_id, creatures in pairs(creature_deaths_by_zone) do
		-- Collect into sortable list
		local sorted = {}
		for creature_id, count in pairs(creatures) do
			sorted[#sorted + 1] = { creature_id, count }
		end
		table.sort(sorted, function(a, b) return a[2] > b[2] end)

		most_deadly_by_zone[zone_id] = {}
		for rank = 1, math.min(10, #sorted) do
			most_deadly_by_zone[zone_id][sorted[rank][1]] = rank
		end
	end

	return most_deadly_by_zone
end

local function createCauseStatsEntry()
	return {
		total = 0,
		[source_kind.NPC] = 0,
		[source_kind.ENVIRONMENT] = 0,
		[source_kind.PVP] = 0,
		[source_kind.REPORTED] = 0,
		[source_kind.UNKNOWN] = 0,
		top_sources = {},
		source_counts = {
			[source_kind.NPC] = {},
			[source_kind.ENVIRONMENT] = {},
			[source_kind.PVP] = {},
			[source_kind.REPORTED] = {},
			[source_kind.UNKNOWN] = {},
		},
	}
end

local function ensureCauseStatsEntry(cause_stats, map_id)
	if cause_stats[map_id] == nil then
		cause_stats[map_id] = createCauseStatsEntry()
	end
	return cause_stats[map_id]
end

local function updateCauseStatsEntry(cause_stats_entry, source_id, kind)
	kind = kind or source_kind.UNKNOWN
	cause_stats_entry.total = cause_stats_entry.total + 1
	cause_stats_entry[kind] = (cause_stats_entry[kind] or 0) + 1

	if source_id == nil then
		return
	end

	local source_counts = cause_stats_entry.source_counts[kind]
	if source_counts == nil then
		source_counts = {}
		cause_stats_entry.source_counts[kind] = source_counts
	end

	source_counts[source_id] = (source_counts[source_id] or 0) + 1
	local top_source_id = cause_stats_entry.top_sources[kind]
	if top_source_id == nil or source_counts[source_id] > (source_counts[top_source_id] or 0) then
		cause_stats_entry.top_sources[kind] = source_id
	end
end

function Deathlog_calculateCauseStats(_deathlog_data)
	local cause_stats = {}

	for _, entry_tbl in pairs(_deathlog_data) do
		for _, entry in pairs(entry_tbl) do
			if Deathlog_shouldShowEntry(entry) then
				Deathlog_YieldCheck()
				local source_id = tonumber(entry["source_id"])
				local kind = Deathlog_GetSourceKind(source_id)
				local entry_map_id = entry["map_id"] or entry["instance_id"] or "all"
				local zones_to_update = Deathlog_get_zone_ancestors(entry_map_id)

				for _, zone_id in ipairs(zones_to_update) do
					local cause_stats_entry = ensureCauseStatsEntry(cause_stats, zone_id)
					updateCauseStatsEntry(cause_stats_entry, source_id, kind)
				end

				local instance_id = entry["instance_id"]
				if instance_id and all_instance_id_set[instance_id] then
					local all_instances_entry = ensureCauseStatsEntry(cause_stats, Deathlog_ALL_INSTANCES_ID)
					updateCauseStatsEntry(all_instances_entry, source_id, kind)
				end
			end
		end
	end

	for _, cause_stats_entry in pairs(cause_stats) do
		cause_stats_entry.source_counts = nil
	end

	return cause_stats
end

-- Return the local purge list. The Python preprocessor aggregates purges from
-- all contributors; at runtime we only have the local deathlog_purged SavedVariable.
function Deathlog_calculatePurges(_deathlog_data)
	return deathlog_purged or {}
end

-- ============================================================
-- Entry origin + sender ignore list
-- ============================================================
-- Records who transmitted an entry to us. The sender name comes from WoW's
-- CHAT_MSG_CHANNEL sender argument, which the server provides and a client
-- cannot spoof — so it reliably identifies the transmitting account.
--
-- It is only recorded for LIVE broadcasts. Sync entries arrive from an
-- arbitrary relayer many hops from whoever fabricated the data, so recording
-- that sender would blame innocent players.

--- Live broadcast sources: the sender is accountable for transmitting.
--- Built lazily; DNL is a separate addon and may load after this file.
local ATTRIBUTABLE_SOURCES = nil
local function isAttributableSource(source)
	if not ATTRIBUTABLE_SOURCES then
		if not (DeathNotificationLib and DeathNotificationLib.SOURCE) then return false end
		ATTRIBUTABLE_SOURCES = {
			[DeathNotificationLib.SOURCE.SELF_DEATH] = true,
			[DeathNotificationLib.SOURCE.PEER_BROADCAST] = true,
		}
	end
	return ATTRIBUTABLE_SOURCES[source] == true
end

-- Session-only: stored key -> checksum DNL recorded the origin under. Merges
-- store the row under a different key than DNL's, and the chat line ID for
-- "Report message" lives only in DNL's session registry under DNL's checksum.
local dnl_checksum_by_stored_key = {}

--- Persist the transmitting player for an entry, if it came in live.
---@param realmName string
---@param stored_checksum string  Key under which the entry is stored
---@param dnl_checksum string|nil Checksum DNL used (pre-merge; may differ)
---@param source string|nil       DNL_Source constant
function Deathlog_recordEntryOrigin(realmName, stored_checksum, dnl_checksum, source)
	if not isAttributableSource(source) then return end
	if not (DeathNotificationLib and DeathNotificationLib.GetEntryOrigin) then return end

	local sender, _, guid = DeathNotificationLib.GetEntryOrigin(dnl_checksum or stored_checksum)
	if not sender then return end

	dnl_checksum_by_stored_key[stored_checksum] = dnl_checksum or stored_checksum

	deathlog_entry_origin[realmName] = deathlog_entry_origin[realmName] or {}
	-- Stored as a table so the unforgeable sender GUID rides along with the name.
	deathlog_entry_origin[realmName][stored_checksum] = { name = sender, guid = guid }
end

--- Who transmitted this entry to us, or nil when it arrived via sync.
---@param realmName string
---@param checksum string
---@return string|nil sender
---@return string|nil guid
function Deathlog_getEntrySender(realmName, checksum)
	local realm_origins = deathlog_entry_origin and deathlog_entry_origin[realmName]
	local origin = realm_origins and realm_origins[checksum]
	if not origin then return nil, nil end
	return origin.name, origin.guid
end

--- Drop the origin record for a checksum that is leaving the database.
---@param realmName string
---@param checksum string|nil
function Deathlog_forgetEntryOrigin(realmName, checksum)
	if not checksum then return end
	local realm_origins = deathlog_entry_origin and deathlog_entry_origin[realmName]
	if realm_origins then realm_origins[checksum] = nil end
end

--- Drop origin records whose entry is no longer in the database. Origins are
--- only useful while the row they describe exists, but purges and merges delete
--- rows without going through Deathlog_forgetEntryOrigin, so this sweeps the
--- remainder on login to keep the SavedVariable from growing without bound.
function Deathlog_pruneEntryOrigins()
	local realmName = GetRealmName()
	local realm_origins = deathlog_entry_origin and deathlog_entry_origin[realmName]
	if not realm_origins then return end

	local db = deathlog_data and deathlog_data[realmName] or {}
	for cs, _ in pairs(realm_origins) do
		if not db[cs] then realm_origins[cs] = nil end
	end
end

--- Sender lookup straight from an entry.
--- Recomputing the Fletcher16 is only a fast path: merging a lower-quality
--- arrival into a stored entry rewrites its fields but keeps the original key,
--- so a merged row no longer hashes to the key it lives under. Fall back to
--- matching the stored table by identity, which stays correct across merges.
---@param player_data PlayerData|nil
---@return string|nil sender
---@return string|nil guid
function Deathlog_getEntrySenderForData(player_data)
	if not player_data or not player_data["name"] then return nil end
	if not (DeathNotificationLib and DeathNotificationLib.Fletcher16) then return nil end

	local realmName = GetRealmName()
	local sender, guid = Deathlog_getEntrySender(realmName, DeathNotificationLib.Fletcher16(player_data))
	if sender then return sender, guid end

	-- Only live entries are ever recorded, so this table is far smaller than the db.
	local realm_origins = deathlog_entry_origin and deathlog_entry_origin[realmName]
	if not realm_origins then return nil end
	local db = deathlog_data and deathlog_data[realmName]
	if not db then return nil end

	for cs, origin in pairs(realm_origins) do
		if db[cs] == player_data then return origin.name, origin.guid end
	end
	return nil
end

--- True when we know who transmitted the entry, i.e. "report sender" applies.
---@param realmName string
---@param checksum string
---@return boolean
function Deathlog_canReportSender(realmName, checksum)
	return Deathlog_getEntrySender(realmName, checksum) ~= nil
end

-- Senders are ignored by their unforgeable chat GUID so a rename or a spoofed
-- name cannot slip past. The name is kept only as a display label. Keyed by GUID
-- when we have one, otherwise by name (self-reports/older rows without a GUID).
---@param sender string       Display name of the sender
---@param guid string|nil     Server-stamped chat GUID, if known
function Deathlog_ignoreSender(sender, guid)
	local key = guid or sender
	if type(key) ~= "string" or key == "" then return end
	deathlog_ignored_senders[key] = sender ~= "" and sender or true
end

---@param sender string       Display name of the sender
---@param guid string|nil     Server-stamped chat GUID, if known
function Deathlog_unignoreSender(sender, guid)
	local key = guid or sender
	if type(key) ~= "string" then return end
	deathlog_ignored_senders[key] = nil
end

---@param sender string|nil   Display name of the sender
---@param guid string|nil     Server-stamped chat GUID, if known
---@return boolean
function Deathlog_isSenderIgnored(sender, guid)
	if type(guid) == "string" and guid ~= "" and deathlog_ignored_senders[guid] then
		return true
	end
	if type(sender) ~= "string" or sender == "" then return false end
	return deathlog_ignored_senders[sender] ~= nil
end

-- ============================================================
-- Hidden names (local moderation)
-- ============================================================
-- Suppresses a character name that our validator considers well-formed but the
-- user finds offensive. Hiding drops the name from the log, the alert popup and
-- our sync responses. It stays purely local: one player's judgement must not
-- delete data from anyone else's database.
--
-- The hidden list is its own permanent gate, deliberately kept OUT of
-- deathlog_purged. Sharing that set would mean unhiding has to guess which
-- checksums it may release, and it would wrongly free rows the feign-death
-- pass purged for unrelated reasons.

local function dropHiddenNameEntries(player_name)
	local realmName = GetRealmName()
	local db = deathlog_data and deathlog_data[realmName]
	if not db then return end

	for cs, entry in pairs(db) do
		if entry["name"] == player_name then
			db[cs] = nil
			Deathlog_forgetEntryOrigin(realmName, cs)
		end
	end

	if deathlog_data_map[realmName] then
		deathlog_data_map[realmName][player_name] = nil
	end
end

---@param player_name string
function Deathlog_hideName(player_name)
	if type(player_name) ~= "string" or player_name == "" then return end
	deathlog_hidden_names[player_name] = true
	dropHiddenNameEntries(player_name)
	Deathlog_refreshAfterModeration()
end

--- Stops suppression. Already-dropped rows return only if a peer re-syncs them.
---@param player_name string
function Deathlog_unhideName(player_name)
	if type(player_name) ~= "string" then return end
	deathlog_hidden_names[player_name] = nil
	Deathlog_refreshAfterModeration()
end

---@return string[] sorted player names
function Deathlog_getHiddenNames()
	local names = {}
	for name, hidden in pairs(deathlog_hidden_names or {}) do
		if hidden then names[#names + 1] = name end
	end
	table.sort(names)
	return names
end

---@param player_name string|nil
---@return boolean
function Deathlog_isNameHidden(player_name)
	if type(player_name) ~= "string" or player_name == "" then return false end
	return deathlog_hidden_names[player_name] == true
end

-- Never reassign StaticPopupDialogs: replacing the global taints the table and
-- breaks Blizzard's own popups (logout countdown). Only insert our key.
if StaticPopupDialogs then
	StaticPopupDialogs["DEATHLOG_CONFIRM_HIDE_NAME"] = {
		text = "Hide all Deathlog entries for |cffff4040%s|r?\n\nThis removes them from your log and stops your client from sharing them. It only affects you \226\128\148 undo with /dl unhide.",
		button1 = YES,
		button2 = NO,
		OnAccept = function(self, player_name)
			Deathlog_hideName(player_name)
		end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,
	}
end

---@param player_name string
function Deathlog_confirmHideName(player_name)
	if type(player_name) ~= "string" or player_name == "" then return end
	if StaticPopupDialogs and StaticPopupDialogs["DEATHLOG_CONFIRM_HIDE_NAME"] and StaticPopup_Show then
		local popup = StaticPopup_Show("DEATHLOG_CONFIRM_HIDE_NAME", player_name, nil, player_name)
		-- The main window sits at FULLSCREEN_DIALOG, above the popup's default
		-- DIALOG strata, so raise the popup above it or it opens hidden behind.
		if popup then
			popup:SetFrameStrata("FULLSCREEN_DIALOG")
			popup:SetToplevel(true)
			popup:Raise()
		end
	else
		Deathlog_hideName(player_name)
	end
end

--- Repaint both logs so a moderation action takes effect without a reload.
function Deathlog_refreshAfterModeration()
	if Deathlog_minilog_refreshEntries then
		Deathlog_minilog_refreshEntries()
	end
	if Deathlog_menuRefreshSearchResults then
		Deathlog_menuRefreshSearchResults()
	end
end

--- What the user can report for an entry.
--- The dead player's name is always reportable — an offensive character name
--- stands on its own regardless of how the record reached us. The sender is
--- only reportable for live broadcasts, otherwise we would accuse a relayer.
---@param player_data PlayerData
---@return { name: string|nil, sender: string|nil, sender_guid: string|nil, name_profane: boolean }
function Deathlog_getReportTargets(player_data)
	local targets = { name_profane = false }
	if not player_data then return targets end

	targets.name = player_data["name"]
	local containsProfanity = DeathNotificationLib.ContainsProfanity
	if containsProfanity then
		targets.name_profane = containsProfanity(player_data["name"])
			or containsProfanity(player_data["guild"])
	end
	targets.sender, targets.sender_guid = Deathlog_getEntrySenderForData(player_data)
	return targets
end

--- The sender to DISPLAY as "reported by". A self-report (sender == the dead
--- player) is not a third-party report, so it is shown as nothing.
---@param player_data PlayerData|nil
---@return string|nil sender
function Deathlog_getDisplaySender(player_data)
	if not player_data then return nil end
	local sender = Deathlog_getEntrySenderForData(player_data)
	if sender and sender == player_data["name"] then return nil end
	return sender
end

-- The Deathlog windows sit at FULLSCREEN_DIALOG, above ReportFrame's native
-- DIALOG strata, so the report dialog would open hidden behind them. Raising
-- ReportFrame instead breaks its reason dropdown: the dropdown's menu is
-- layered relative to the dialog by Blizzard code we cannot adjust, so it ends
-- up behind the raised dialog. Leave ReportFrame fully native and temporarily
-- demote our windows below it while it is shown.
local report_demote_frames = {}
local report_demoted_strata = {}
local report_frame_hooked = false

--- Register a window to be lowered while Blizzard's report dialog is open.
function Deathlog_registerReportDemoteFrame(frame)
	if frame then
		report_demote_frames[frame] = true
	end
end

-- Only frames on these strata can cover ReportFrame (DIALOG); anything lower
-- must be left alone or we'd RAISE it above its own children (minilog skull).
local STRATA_ABOVE_REPORT = {
	["FULLSCREEN"] = true,
	["FULLSCREEN_DIALOG"] = true,
	["TOOLTIP"] = true,
}

local function lowerDeathlogWindowsForReport()
	if not (ReportFrame and ReportFrame:IsShown()) then return end
	for frame in pairs(report_demote_frames) do
		if report_demoted_strata[frame] == nil and STRATA_ABOVE_REPORT[frame:GetFrameStrata()] then
			report_demoted_strata[frame] = frame:GetFrameStrata()
			frame:SetFrameStrata("HIGH")
		end
	end
	if not report_frame_hooked then
		report_frame_hooked = true
		ReportFrame:HookScript("OnHide", function()
			for frame, strata in pairs(report_demoted_strata) do
				frame:SetFrameStrata(strata)
				report_demoted_strata[frame] = nil
			end
		end)
	end
end

--- Open Blizzard's report dialog for a player name.
--- The dialog lets the user pick the category (InappropriateName etc.),
--- so we only need to supply the name.
---@param player_name string
---@return boolean opened
function Deathlog_reportPlayer(player_name)
	if type(player_name) ~= "string" or player_name == "" then return false end
	if not (ReportInfo and ReportInfo.CreateReportInfoFromType) then return false end
	if not (ReportFrame and ReportFrame.InitiateReport) then return false end
	if not (Enum and Enum.ReportType and Enum.ReportType.InWorld) then return false end

	local reportInfo = ReportInfo:CreateReportInfoFromType(Enum.ReportType.InWorld)
	if not reportInfo then return false end

	ReportFrame:InitiateReport(reportInfo, player_name)
	lowerDeathlogWindowsForReport()
	return true
end

--- Live-session chat line ID for the broadcast that carried this entry, if we
--- still hold it. Kept only in DNL's session-local origin registry (never
--- persisted), so a reloaded row returns nil.
---@param player_data PlayerData|nil
---@return number|nil line_id
---@return string|nil sender
function Deathlog_getEntryReportLine(player_data)
	if not player_data or not player_data["name"] then return nil end
	if not (DeathNotificationLib and DeathNotificationLib.Fletcher16 and DeathNotificationLib.GetEntryOrigin) then
		return nil
	end

	-- A merged row is stored under a key that no longer matches DNL's checksum,
	-- so map the stored key back to the checksum DNL recorded the line ID under.
	local cs = DeathNotificationLib.Fletcher16(player_data)
	local dnl_cs = dnl_checksum_by_stored_key[cs]
	if not dnl_cs then
		-- Merges rewrite fields but keep the original key, so the recomputed
		-- checksum can also miss; fall back to identity-matching the stored row.
		local db = deathlog_data and deathlog_data[GetRealmName()]
		if db then
			for stored_cs, mapped_cs in pairs(dnl_checksum_by_stored_key) do
				if db[stored_cs] == player_data then
					dnl_cs = mapped_cs
					break
				end
			end
		end
	end

	local sender, _, _, line_id = DeathNotificationLib.GetEntryOrigin(dnl_cs or cs)
	if line_id then return line_id, sender end
	return nil
end

--- Open Blizzard's report dialog for a specific chat MESSAGE (spam/chat), so the
--- offending broadcast text is attached and attributed to the sender. Needs the
--- live chat line ID, which only exists during the session the death arrived in.
---@param sender string      The account that broadcast the message
---@param line_id number     Chat line ID captured at receive time
---@return boolean opened
function Deathlog_reportPlayerMessage(sender, line_id)
	if type(sender) ~= "string" or sender == "" then return false end
	if type(line_id) ~= "number" then return false end
	if not (ReportInfo and ReportInfo.CreateReportInfoFromType) then return false end
	if not (ReportFrame and ReportFrame.InitiateReport) then return false end
	if not (Enum and Enum.ReportType and Enum.ReportType.Chat) then return false end
	if not (PlayerLocation and PlayerLocation.CreateFromChatLineID) then return false end

	local reportInfo = ReportInfo:CreateReportInfoFromType(Enum.ReportType.Chat)
	if not reportInfo then return false end

	local location = PlayerLocation:CreateFromChatLineID(line_id)
	ReportFrame:InitiateReport(reportInfo, sender, location)
	lowerDeathlogWindowsForReport()
	return true
end

--- Append the report / ignore entries shared by the minilog and the main log
--- context menus. `player_data` is the death entry that was right-clicked.
---@param player_data PlayerData|nil
function Deathlog_addContextMenuReportItems(player_data)
	if not player_data then return end

	local targets = Deathlog_getReportTargets(player_data)
	-- A self-report's sender is the victim, so it names no third party to act on.
	local sender = targets.sender
	local sender_guid = targets.sender_guid
	local reported_by_third_party = sender ~= nil and sender ~= targets.name

	local function addButton(text, func)
		local info = UIDropDownMenu_CreateInfo()
		info.text = text
		info.hasArrow = false
		info.func = func
		UIDropDownMenu_AddButton(info)
	end

	-- The dead player's own name is only worth reporting when nobody else was
	-- named as the reporter — a third-party report points at the sender instead.
	if targets.name and not reported_by_third_party then
		addButton(
			targets.name_profane and "|cffff4040Report name|r" or "Report player",
			function() Deathlog_reportPlayer(targets.name) end
		)
	end

	if targets.name then
		local hidden = Deathlog_isNameHidden(targets.name)
		addButton(
			hidden and "Unhide name" or "Hide name",
			function()
				if hidden then
					Deathlog_unhideName(targets.name)
				else
					Deathlog_confirmHideName(targets.name)
				end
			end
		)
	end

	-- Sender actions only make sense when a third party reported the death: a
	-- synced entry has no attributable sender and a self-report names the victim.
	if reported_by_third_party then
		-- Reporting the sender is always ABOUT what they transmitted, so prefer
		-- a Chat report with the broadcast text attached (the only type offering
		-- the Inappropriate Communication / Spam categories). The line ID only
		-- lives for the session the death arrived in; for older rows fall back
		-- to a plain in-world report against the sender.
		local line_id, line_sender = Deathlog_getEntryReportLine(player_data)
		if line_id and line_sender == sender then
			addButton(
				"Report sender: " .. sender,
				function() Deathlog_reportPlayerMessage(sender, line_id) end
			)
		else
			addButton(
				"Report sender: " .. sender,
				function() Deathlog_reportPlayer(sender) end
			)
		end

		local ignored = Deathlog_isSenderIgnored(sender, sender_guid)
		addButton(
			ignored and ("Unignore sender: " .. sender) or ("Ignore sender: " .. sender),
			function()
				if ignored then
					Deathlog_unignoreSender(sender, sender_guid)
				else
					Deathlog_ignoreSender(sender, sender_guid)
				end
			end
		)
	end
end

-- Cache: map bounds (rect on parent) and parent chain per map_id.
-- Computed once per session from C_Map API, reused across all deaths.
local map_bounds_cache = {} -- [child_map_id] = {parent, x1, y1, x2, y2} or false
local parent_chain_cache = {} -- [map_id] = {parent1, parent2, ...} (excludes Cosmos 946)

local function getMapBounds(child_map_id)
	local cached = map_bounds_cache[child_map_id]
	if cached ~= nil then return cached end -- false means "no valid parent"
	local mapInfo = C_Map.GetMapInfo(child_map_id)
	if not mapInfo or not mapInfo.parentMapID or mapInfo.parentMapID <= 0 then
		map_bounds_cache[child_map_id] = false
		return false
	end
	local parentId = mapInfo.parentMapID
	local cid, wp1 = C_Map.GetWorldPosFromMapPos(child_map_id, CreateVector2D(0, 0))
	local _, wp2 = C_Map.GetWorldPosFromMapPos(child_map_id, CreateVector2D(1, 1))
	if not wp1 or not wp2 then
		map_bounds_cache[child_map_id] = false
		return false
	end
	local _, pp1 = C_Map.GetMapPosFromWorldPos(cid, wp1, parentId)
	local _, pp2 = C_Map.GetMapPosFromWorldPos(cid, wp2, parentId)
	if not pp1 or not pp2 then
		map_bounds_cache[child_map_id] = false
		return false
	end
	local x1, y1 = pp1:GetXY()
	local x2, y2 = pp2:GetXY()
	local bounds = { parent = parentId, x1 = x1, y1 = y1, x2 = x2, y2 = y2 }
	map_bounds_cache[child_map_id] = bounds
	return bounds
end

local function getParentChain(map_id)
	local cached = parent_chain_cache[map_id]
	if cached then return cached end
	local chain = {}
	local current = map_id
	while true do
		local bounds = getMapBounds(current)
		if not bounds then break end
		local pid = bounds.parent
		if pid == 946 then break end -- Cosmos
		chain[#chain + 1] = current -- store child so we can look up its bounds
		current = pid
	end
	parent_chain_cache[map_id] = chain
	return chain
end

-- Transform a single point through the cached bounds: child (0-1000) → parent (0-1000)
local function transformPoint(bounds, sx, sy)
	local cx = sx / 1000 -- normalise to 0-1
	local cy = sy / 1000
	local px = bounds.x1 + cx * (bounds.x2 - bounds.x1)
	local py = bounds.y1 + cy * (bounds.y2 - bounds.y1)
	px = math.max(0, math.min(1, px)) * 1000
	py = math.max(0, math.min(1, py)) * 1000
	return px, py
end

-- Build skull_locs from death database and aggregate to parent zones via cached map bounds.
function Deathlog_calculateSkullLocs(_deathlog_data)
	local skull_locs = {}
	for _, entry_tbl in pairs(_deathlog_data) do
		for _, v in pairs(entry_tbl) do
			Deathlog_YieldCheck()
			if v["map_id"] and v["map_pos"] then
				local mid = v["map_id"]
				if not skull_locs[mid] then skull_locs[mid] = {} end
				local x, y = Deathlog_parseMapPos(v["map_pos"])
				if x and y then
					skull_locs[mid][#skull_locs[mid] + 1] = { x * 1000, y * 1000, tonumber(v["source_id"]) }
				end
			end
		end
	end
	-- Aggregate death points to parent zones using cached bounds
	for mapid in pairs(skull_locs) do
		local chain = getParentChain(mapid)
		if #chain > 0 then
			local current_deaths = skull_locs[mapid]
			for ci = 1, #chain do
				local child_id = chain[ci]
				local bounds = map_bounds_cache[child_id] -- already populated by getParentChain
				if not bounds then break end
				local parent_id = bounds.parent
				local transformed = {}
				for di = 1, #current_deaths do
					local d = current_deaths[di]
					local px, py = transformPoint(bounds, d[1], d[2])
					transformed[#transformed + 1] = { px, py, d[3] }
					Deathlog_YieldCheck()
				end
				if #transformed == 0 then break end
				if not skull_locs[parent_id] then skull_locs[parent_id] = {} end
				local parent_tbl = skull_locs[parent_id]
				for ti = 1, #transformed do
					parent_tbl[#parent_tbl + 1] = transformed[ti]
					Deathlog_YieldCheck()
				end
				current_deaths = transformed
			end
		end
	end
	return skull_locs
end

function Deathlog_calculateHeatmapIntensity(skull_locs)
	local ceil = math.ceil
	local iv = {
		[0] = { [0] = 0.025, [1] = 0.045, [2] = 0.025 },
		[1] = { [0] = 0.045, [1] = 0.1,   [2] = 0.045 },
		[2] = { [0] = 0.025, [1] = 0.045, [2] = 0.025 },
	}
	local heatmap = {}
	for mapid, d in pairs(skull_locs) do
		heatmap[mapid] = {}
		local max_intensity = 0
		for _, t in ipairs(d) do
			Deathlog_YieldCheck()
			local _x = ceil(t[1] / 10)
			local _y = ceil(t[2] / 10)
			for xi = 0, 2 do
				for yj = 0, 2 do
					local x_in_map = _x - 1 + xi
					local y_in_map = _y - 1 + yj
					if x_in_map >= 1 and x_in_map <= 100 and y_in_map >= 1 and y_in_map <= 100 then
						if not heatmap[mapid][x_in_map] then heatmap[mapid][x_in_map] = {} end
						heatmap[mapid][x_in_map][y_in_map] = (heatmap[mapid][x_in_map][y_in_map] or 0) + iv[xi][yj]
						if heatmap[mapid][x_in_map][y_in_map] > max_intensity then
							max_intensity = heatmap[mapid][x_in_map][y_in_map]
						end
					end
				end
			end
		end
		if max_intensity > 0 then
			for x, ys in pairs(heatmap[mapid]) do
				for y, val in pairs(ys) do
					heatmap[mapid][x][y] = val / max_intensity
					if heatmap[mapid][x][y] < 0.02 then
						heatmap[mapid][x][y] = nil
					end
				end
				if not next(heatmap[mapid][x]) then
					heatmap[mapid][x] = nil
				end
			end
		end
	end
	return heatmap
end

function Deathlog_calculateHeatmapIntensityByCause(skull_locs)
	local skull_locs_by_cause = {}

	for mapid, deaths in pairs(skull_locs) do
		for _, death in ipairs(deaths) do
			Deathlog_YieldCheck()
			local kind = Deathlog_GetSourceKind(death[3])
			if skull_locs_by_cause[kind] == nil then
				skull_locs_by_cause[kind] = {}
			end
			if skull_locs_by_cause[kind][mapid] == nil then
				skull_locs_by_cause[kind][mapid] = {}
			end
			skull_locs_by_cause[kind][mapid][#skull_locs_by_cause[kind][mapid] + 1] = death
		end
	end

	local intensity_by_cause = {}
	for kind, skulls in pairs(skull_locs_by_cause) do
		intensity_by_cause[kind] = Deathlog_calculateHeatmapIntensity(skulls)
	end

	return intensity_by_cause
end

function Deathlog_calculateHeatmapCreatureSubset(skull_locs)
	local ceil = math.ceil
	local creature_subset = {}
	for mapid, deaths in pairs(skull_locs) do
		creature_subset[mapid] = {}
		for _, death in ipairs(deaths) do
			Deathlog_YieldCheck()
			local x = ceil(death[1] / 10)
			local y = ceil(death[2] / 10)
			local source_id = death[3]
			if source_id then
				if not creature_subset[mapid][source_id] then
					creature_subset[mapid][source_id] = {}
				end
				if not creature_subset[mapid][source_id][x] then
					creature_subset[mapid][source_id][x] = {}
				end
				creature_subset[mapid][source_id][x][y] = true
			end
		end
	end
	return creature_subset
end

function Deathlog_setTooltipFromEntry(_entry)
	if _entry == nil then
		return
	end
	local _name = _entry["name"]
	local _level = _entry["level"]
	local _guild = _entry["guild"] or ""
	local _race = nil
	local _class = nil
	local _source = DeathlogGetCachedSource(_entry)
	local _zone = nil
	local _loc = _entry["map_pos"]
	local _date = nil
	if _entry["date"] then
		if deathlog_settings and deathlog_settings["european_date_format"] then
			_date = date("%d/%m/%y", _entry["date"])
	else
			_date = date("%m/%d/%y", _entry["date"])
	end
	end
	local _playtime = DeathNotificationLib.FormatPlaytime(_entry["played"])
	local _last_words = nil
	if _entry["last_words"] ~= nil and not _entry["last_words"]:match("^%s*$") then
		_last_words = _entry["last_words"]
	end
	local _reported_by = Deathlog_getDisplaySender(_entry)

	if _entry["race_id"] ~= nil then
		local race_info = C_CreatureInfo.GetRaceInfo(_entry["race_id"])
		if race_info then
			_race = race_info.raceName
		end
	end

	if _entry["class_id"] ~= nil then
		local class_str = GetClassInfo(_entry["class_id"])
		if class_str then
			local color = DeathNotificationLib.CLASS_ID_TO_COLOR[_entry["class_id"]]
			if color then
				_class = "|c" .. color.colorStr .. class_str .. "|r"
			else
				_class = class_str
			end
		end
	end

	if _entry["map_id"] then
		local map_info = C_Map.GetMapInfo(_entry["map_id"])
		if map_info then
			_zone = map_info.name
		end
	elseif _entry["instance_id"] then
		_zone = (id_to_instance[_entry["instance_id"]] or _entry["instance_id"])
	end
	Deathlog_setTooltip(_name, _level, _guild, _race, _class, _source, _zone, _date, _playtime, _last_words, _reported_by)
end

function Deathlog_setTooltip(_name, _lvl, _guild, _race, _class, _source, _zone, _date, _playtime, _last_words, _reported_by)
	if _name == nil or _lvl == nil then
		return
	end

	local _deathlog_watchlist_icon = ""
	if
		deathlog_watchlist_entries
		and deathlog_watchlist_entries[_name]
		and deathlog_watchlist_entries[_name]["Icon"]
	then
		_deathlog_watchlist_icon = deathlog_watchlist_entries[_name]["Icon"] .. " "
	end
	if string.sub(_name, #_name) == "s" then
		GameTooltip:AddDoubleLine(
			_deathlog_watchlist_icon .. _name .. "' " .. Deathlog_L.death_word,
			(_lvl and _lvl ~= "" and ("Lvl. " .. _lvl) or ""),
			1,
			1,
			1,
			0.5,
			0.5,
			0.5
		)
	else
		GameTooltip:AddDoubleLine(
			_deathlog_watchlist_icon .. _name .. "'s " .. Deathlog_L.death_word,
			(_lvl and _lvl ~= "" and ("Lvl. " .. _lvl) or ""),
			1,
			1,
			1,
			0.5,
			0.5,
			0.5
		)
	end

	local ml = deathlog_settings["minilog"]
	if ml == nil then return end

	if ml["tooltip_name"] and _name then
		GameTooltip:AddLine(Deathlog_L.name_word .. ": " .. _name, 1, 1, 1)
	end
	if ml["tooltip_guild"] and _guild and _guild ~= "" then
		GameTooltip:AddLine(Deathlog_L.guild_word .. ": " .. _guild, 1, 1, 1)
	end

	if ml["tooltip_race"] and _race and _race ~= "" then
		GameTooltip:AddLine(Deathlog_L.race_word .. ": " .. _race, 1, 1, 1)
	end

	if ml["tooltip_class"] and _class and _class ~= "" then
		GameTooltip:AddLine(Deathlog_L.class_word .. ": " .. _class, 1, 1, 1)
	end
	if deathlog_settings["colored_tooltips"] == nil or deathlog_settings["colored_tooltips"] == false then
		if ml["tooltip_killedby"] and _source then
			GameTooltip:AddLine(Deathlog_L.killed_by_word .. ": " .. _source, 1, 1, 1)
		end
		if ml["tooltip_zone"] and _zone then
			GameTooltip:AddLine(Deathlog_L.zone_instance_word .. ": " .. _zone, 1, 1, 1)
		end
	else
		if ml["tooltip_killedby"] and _source then
			GameTooltip:AddLine(Deathlog_L.killed_by_word .. ": |cfffda172" .. _source .. "|r", 1, 1, 1)
		end
		if ml["tooltip_zone"] and _zone then
			GameTooltip:AddLine(Deathlog_L.zone_instance_word .. ": |cff9fe2bf" .. _zone .. "|r", 1, 1, 1)
		end
	end

	if ml["tooltip_date"] and _date then
		GameTooltip:AddLine(Deathlog_L.date_word .. ": " .. _date, 1, 1, 1)
	end

	if ml["tooltip_playtime"] then
		if _playtime and _playtime ~= "" then
			GameTooltip:AddLine(Deathlog_L.playtime_word .. ": " .. _playtime, 1, 1, 1)
		end
	end

	if ml["tooltip_lastwords"] then
		if _last_words and _last_words ~= "" then
			GameTooltip:AddLine(Deathlog_L.last_words_word .. ": " .. _last_words, 1, 1, 0, true)
		end
	end

	if ml["tooltip_reportedby"] then
		if _reported_by and _reported_by ~= "" then
			GameTooltip:AddLine(Deathlog_L.reported_by_word .. ": " .. _reported_by, 1, 1, 1)
		end
	end
end

local record_econ_handler = nil
local record_econ_timer = nil
local record_econ_start_time = GetServerTime()
local logged_already = {}

local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded

-- Only enable recording if guild opts in, e.g. :M:Hardcore:
local function registerRecorders()
	local guild_info_text = GetGuildInfoText()
	if guild_info_text then
		local _, g, k = string.split(":", guild_info_text)
		if g and g == "M" and k then
			record_econ_handler = CreateFrame("Frame")
			local start_gold = GetMoney()
			local _v = isLoaded(k)
			if _v == false then
				deathlog_record_econ_stats[GetServerTime() .. "general"] = UnitName("player")
					.. ": Logged without "
					.. k
					.. "."
				record_econ_handler:RegisterEvent("MAIL_SHOW") -- Using mailbox
				record_econ_handler:RegisterEvent("MAIL_INBOX_UPDATE") -- Using mailbox
				record_econ_handler:RegisterEvent("CHAT_MSG_LOOT") -- Using mailbox
				record_econ_handler:RegisterEvent("TRADE_SHOW") -- Trade opened
				record_econ_handler:RegisterEvent("AUCTION_BIDDER_LIST_UPDATE") -- Using Auction house

				TradeFrameTradeButton:SetScript("OnClick", function()
					local _item_name, _, _, _, _enchantment_name, _ = GetTradePlayerItemInfo(7)
					if _item_name and _enchantment_name then
						local _target_trader = TradeFrameRecipientNameText:GetText()
						deathlog_record_econ_stats[GetServerTime() .. "Ench"] = UnitName("player")
							.. ": Received enchantment for "
							.. _item_name
							.. ","
							.. _enchantment_name
							.. ", from: "
							.. (_target_trader or "unknown")
					end
					AcceptTrade()
				end)

				record_econ_handler:SetScript("OnEvent", function(self, event, arg)
					if event == "MAIL_SHOW" then
						deathlog_record_econ_stats[GetServerTime() .. "mail"] = UnitName("player") .. ": Opened mail"
					elseif event == "MAIL_INBOX_UPDATE" then
						for _mail_idx = 1, 8 do
							local _, _, _sender_name, _desc = GetInboxHeaderInfo(_mail_idx)
							if _sender_name and _desc then
								if
									_sender_name == "Alliance Auction House"
									or _sender_name == "Horde Auction House"
								then
									if logged_already[_sender_name .. _desc] == nil then
										logged_already[_sender_name .. _desc] = 1
										deathlog_record_econ_stats[GetServerTime() .. _sender_name .. _mail_idx] = UnitName(
											"player"
										) .. ": Inbox has " .. _desc
									end
								end
							end
						end
					elseif event == "CHAT_MSG_LOOT" then
						deathlog_record_econ_stats[GetServerTime() .. "gained"] = UnitName("player") .. ": " .. arg
					elseif event == "TRADE_SHOW" then
						deathlog_record_econ_stats[GetServerTime() .. "trade"] = UnitName("player") .. ": Traded"
					elseif event == "AUCTION_BIDDER_LIST_UPDATE" then
						deathlog_record_econ_stats[GetServerTime() .. "AH"] = UnitName("player") .. ": Used AH"
					end
				end)

				C_Timer.NewTicker(5, function()
					deathlog_record_econ_stats[record_econ_start_time .. "session_stats"] = UnitName("player")
						.. ": Duration: "
						.. (GetServerTime() - record_econ_start_time)
						.. "s. Gold Difference: "
						.. (GetMoney() - start_gold)
						.. "c"
				end)
			end
		end
	end
end

local attempts = 0
C_Timer.NewTicker(1, function(self)
	local guild_info_text = GetGuildInfoText()
	if guild_info_text ~= nil and guild_info_text ~= "" then
		registerRecorders()
		self:Cancel()
	end
	attempts = attempts + 1
	if attempts > 10 then
		self:Cancel()
	end
end)

local deathlog_copy_popup = nil

--- Show a small popup with an EditBox for easy copying.
---@param text string
function Deathlog_ShowCopyPopup(text)
	if not deathlog_copy_popup then
		local popup = CreateFrame("Frame", "DeathlogCopyPopupFrame", UIParent, "BackdropTemplate")
		popup:SetSize(320, 120)
		popup:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
		popup:SetFrameStrata("TOOLTIP")
		popup:SetToplevel(true)
		popup:EnableMouse(true)
		popup:SetMovable(true)
		popup:RegisterForDrag("LeftButton")
		popup:SetScript("OnDragStart", popup.StartMoving)
		popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
		popup:SetBackdrop({
			bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
			edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
			tile = true,
			tileSize = 32,
			edgeSize = 32,
			insets = { left = 8, right = 8, top = 8, bottom = 8 },
		})

		local title = popup:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		title:SetPoint("TOP", popup, "TOP", 0, -16)
		title:SetText("Press Ctrl+C to copy")

		local close = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
		close:SetPoint("TOPRIGHT", popup, "TOPRIGHT", -4, -4)

		local editBox = CreateFrame("EditBox", nil, popup, "InputBoxTemplate")
		editBox:SetAutoFocus(true)
		editBox:SetSize(220, 30)
		editBox:SetPoint("CENTER", popup, "CENTER", 0, -6)
		editBox:SetScript("OnEscapePressed", function(self)
			self:ClearFocus()
			popup:Hide()
		end)
		popup.editBox = editBox

		local hint = popup:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		hint:SetPoint("BOTTOM", popup, "BOTTOM", 0, 12)
		hint:SetText("Esc to close")

		popup:Hide()
		deathlog_copy_popup = popup
	end

	local value = text or ""
	deathlog_copy_popup.editBox:SetText(value)
	deathlog_copy_popup.editBox:HighlightText()
	deathlog_copy_popup:Show()
	deathlog_copy_popup:Raise()
	deathlog_copy_popup.editBox:SetFocus()
end
