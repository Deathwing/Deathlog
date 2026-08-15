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
local addonName, addon = ...

-- API compatibility: Classic Era uses GetAddOnMetadata, TBC Anniversary uses C_AddOns.GetAddOnMetadata
local GetAddOnMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata

local SOURCE = DeathNotificationLib.SOURCE

local function initVariables()
	---@diagnostic disable: lowercase-global
	deathlog_settings = deathlog_settings or {}
	deathlog_data = deathlog_data or {}
	deathlog_data_map = deathlog_data_map or {}
	deathlog_watchlist_entries = deathlog_watchlist_entries or {}
	-- Prune stale blank/whitespace-only watch list keys that could be
	-- created by older versions; these rendered an empty, unremovable row.
	for _key, _val in pairs(deathlog_watchlist_entries) do
		local _trimmed = type(_key) == "string" and _key:gsub("%s+", "") or ""
		if type(_key) ~= "string" or _trimmed == "" then
			deathlog_watchlist_entries[_key] = nil
		end
	end
	deathlog_record_econ_stats = deathlog_record_econ_stats or {}
	deathlog_entry_counts = deathlog_entry_counts or {}
	deathlog_purged = deathlog_purged or {}
	deathlog_entry_origin = deathlog_entry_origin or {}
	deathlog_ignored_senders = deathlog_ignored_senders or {}
	deathlog_hidden_names = deathlog_hidden_names or {}
	deathlog_precomputed = deathlog_precomputed or {}
	deathlog_dev_data = deathlog_dev_data or {}
	deathlog_char_data = deathlog_char_data or {}
	---@diagnostic enable: lowercase-global
end
initVariables()

local sync_options -- forward declaration; populated after options table
local deathlog_sync_options_registered = false
local deathlog_minimap_button_stub = nil

local function setMiniLogShown(show)
	if Deathlog_minilog_setShown == nil then
		return nil
	end

	local is_shown = Deathlog_minilog_setShown(show)
	return is_shown
end

local function toggleMiniLog()
	if Deathlog_minilog_toggle == nil then
		return nil
	end

	local is_shown = Deathlog_minilog_toggle()
	return is_shown
end

local function handleMiniLogCommand(arg)
	local action = string.match(string.lower(arg or ""), "^%s*(%S*)") or ""
	if action == "show" or action == "on" then
		setMiniLogShown(true)
	elseif action == "hide" or action == "off" then
		setMiniLogShown(false)
	else
		toggleMiniLog()
	end
end

--- Hidden names are only reachable from the log's context menu while an entry
--- is visible, and hiding removes the entry — so unhiding needs a command.
local function handleHiddenCommand(command, name)
	if command == "unhide" then
		if name == "" then
			DEFAULT_CHAT_FRAME:AddMessage("|cffffd200Deathlog:|r usage: |cffffffff/dl unhide <name>|r")
			return
		end
		if not Deathlog_isNameHidden(name) then
			DEFAULT_CHAT_FRAME:AddMessage("|cffffd200Deathlog:|r |cffffffff" .. name .. "|r is not hidden.")
			return
		end
		Deathlog_unhideName(name)
		DEFAULT_CHAT_FRAME:AddMessage("|cffffd200Deathlog:|r unhid |cffffffff" .. name
			.. "|r. Past entries return only if a peer re-syncs them.")
		return
	end

	local names = Deathlog_getHiddenNames()
	if #names == 0 then
		DEFAULT_CHAT_FRAME:AddMessage("|cffffd200Deathlog:|r no hidden names.")
		return
	end
	DEFAULT_CHAT_FRAME:AddMessage("|cffffd200Deathlog hidden names|r (|cffffffff/dl unhide <name>|r)")
	for _, n in ipairs(names) do
		DEFAULT_CHAT_FRAME:AddMessage("  |cffff4040" .. n .. "|r")
	end
end

local deathlog_minimap_button = LibStub("LibDataBroker-1.1"):NewDataObject(addonName, {
	type = "data source",
	text = addonName,
	icon = "Interface\\TARGETINGFRAME\\UI-TargetingFrame-Skull",
	OnClick = function(self, btn)
		if btn == "LeftButton" then
			if IsControlKeyDown() then
				toggleMiniLog()
			elseif IsShiftKeyDown() then
				DeathlogResetMenuPosition()
			else
				DeathlogToggleMenu(deathlog_data, DeathlogDataCopy.PRECOMPUTED_GENERAL_STATS, DeathlogDataCopy.PRECOMPUTED_LOG_NORMAL_PARAMS)
			end
		else
			Deathlog_OpenSettings()
		end
	end,
	OnTooltipShow = function(tooltip)
		tooltip:AddLine(addonName)
		tooltip:AddLine(Deathlog_L.minimap_btn_left_click)
		tooltip:AddLine(Deathlog_L.minimap_btn_ctrl_click)
		tooltip:AddLine(Deathlog_L.minimap_btn_shift_click)
		tooltip:AddLine(Deathlog_L.minimap_btn_right_click .. GAMEOPTIONS_MENU)
	end,
})
local function initMinimapButton()
	deathlog_minimap_button_stub = LibStub("LibDBIcon-1.0", true)
	if deathlog_minimap_button_stub:IsRegistered(addonName) then
		return
	end
	if deathlog_settings.minimap == nil then
		deathlog_settings.minimap = {}
	end
	deathlog_minimap_button_stub:Register(addonName, deathlog_minimap_button, deathlog_settings.minimap)

	if deathlog_settings["show_minimap"] ~= nil and deathlog_settings["show_minimap"] == false then
		deathlog_minimap_button_stub:Hide(addonName)
	end
end

local function loadWidgets()
	-- Each widget's applySettings registers its own Blizzard settings subcategory
	-- (the "foldout" panels under Deathlog). Run each in its own pcall so a single
	-- widget erroring on a player's saved settings (bad font/theme/sound value)
	-- can't abort the whole chain and leave the remaining foldouts unregistered.
	local steps = {
		function() Deathlog_minilog_applySettings(true) end,
		Deathlog_CRTWidget_applySettings,
		Deathlog_CTTWidget_applySettings,
		Deathlog_HIWidget_applySettings,
		Deathlog_HWMWidget_applySettings,
		DeathNotificationLib.UpdateDeathAlert,
		Deathlog_ReportWidget_ApplySettings,
	}
	for _, step in ipairs(steps) do
		if type(step) == "function" then
			local ok, err = pcall(step)
			if not ok then
				print("|cffff5555Deathlog|r: a settings panel failed to load: " .. tostring(err))
			end
		end
	end
end

--- Initialize entry counters from existing data on first load.
--- Classifies legacy entries by inspecting available fields:
---   - Has both class_id and race_id → "self_death" (older clients only had addon-reported deaths with full data)
---   - Missing class_id or race_id → "blizzard" (Blizzard's HARDCORE_DEATHS channel reports lack these fields)
local function initEntryCounters()
	if deathlog_entry_counts["initialized"] then
		return
	end

	local total = 0
	local self_death = 0
	local blizzard = 0
	for _, entries in pairs(deathlog_data) do
		if type(entries) == "table" then
			for _, entry in pairs(entries) do
				total = total + 1
				if entry["class_id"] and entry["race_id"] then
					self_death = self_death + 1
				else
					blizzard = blizzard + 1
				end
			end
		end
	end

	deathlog_entry_counts[SOURCE.SELF_DEATH] = self_death
	deathlog_entry_counts[SOURCE.BLIZZARD] = blizzard
	deathlog_entry_counts["total"] = total
	deathlog_entry_counts["initialized"] = true
end

function Deathlog_LoadFromHardcore()
	if Hardcore_Settings and Hardcore_Settings["death_log_entries"] then
		print("Retrieving deathlog entries...")
		local c = 0
		local new_entries = 0
		if deathlog_data == nil or deathlog_data["legacy"] == nil then
			deathlog_data["legacy"] = {}
		end
		local local_deathlog_fletcher16 = Deathlog_fletcher16
		for _, v in ipairs(Hardcore_Settings["death_log_entries"]) do
			c = c + 1
			local checksum = local_deathlog_fletcher16(v["name"], v["guild"], v["level"], v["source_id"])
			local converted_date = DeathlogConvertStringDateUnix(v["date"])
			if converted_date then
				if deathlog_data["legacy"][checksum] == nil then
					new_entries = new_entries + 1
				end
				deathlog_data["legacy"][checksum] = {
					["class_id"] = v["class_id"],
					["guild"] = v["guild"],
					["date"] = converted_date,
					["map_pos"] = v["map_pos"],
					["source_id"] = v["source_id"],
					["name"] = v["name"],
					["race_id"] = v["race_id"],
					["level"] = v["level"],
					["map_id"] = v["map_id"],
					["instance_id"] = v["instance_id"],
					["played"] = v["played"],
					["last_words"] = v["last_words"],
				}
			else
				print("failed")
			end
		end
		print("Complete. New entries: " .. new_entries .. ". Scanned: " .. c)
	end
end

-- sync_options registered in handleEvent after loadWidgets() so it appears last in the sidebar

-- In-memory index: name_index[realmName][player_name] = { [checksum] = true, ... }
-- Allows efficient lookup of ALL existing entries for a player name (not just the latest).
-- Built lazily on first access per realm, maintained on insert/remove.
local name_index = {}

local function ensureNameIndex(realmName)
	if name_index[realmName] then return end
	name_index[realmName] = {}
	for checksum, entry in pairs(deathlog_data[realmName] or {}) do
		local n = entry["name"]
		if n then
			if not name_index[realmName][n] then
				name_index[realmName][n] = {}
			end
			name_index[realmName][n][checksum] = true
		end
	end
end

--- Returns true if player_data represents a known-fake (i.e. hunter feign-death bug) or purged death and should be suppressed.
--- Checks static and runtime purge lists, plus identical map_pos against all stored entries for the same player (a reliable fabrication signal).
local function deathlog_isFilteredEntry(player_data)
	local realm = GetRealmName()
	local cs = DeathNotificationLib.Fletcher16(player_data)

	if deathlog_hidden_names[player_data["name"]] then
		return true
	end

	if deathlog_purged[realm] and deathlog_purged[realm][cs] then
		return true
	end

	if DeathlogDataCopy.PRECOMPUTED_PURGES[realm] and DeathlogDataCopy.PRECOMPUTED_PURGES[realm][cs] then
		return true
	end

	local new_pos = player_data["map_pos"]
	local pname = player_data["name"]
	if new_pos and pname and name_index[realm] and name_index[realm][pname] then
		for existing_cs, _ in pairs(name_index[realm][pname]) do
			local stored = deathlog_data[realm] and deathlog_data[realm][existing_cs]
			if stored and stored["map_pos"] == new_pos then
				return true
			end
		end
	end

	return false
end

local deathAlertWhitelist = setmetatable({}, { __mode = "k" })

local function newEntry(_player_data, _checksum, num_peer_checks, in_guild, source)
	local realmName = GetRealmName()

	if deathlog_data[realmName] == nil then
		deathlog_data[realmName] = {}
	end

	if deathlog_data_map[realmName] == nil then
		deathlog_data_map[realmName] = {}
	end

	ensureNameIndex(realmName)

	local player_name = _player_data["name"]
	local current_time = _player_data["date"] or GetServerTime()

	-- Reject entries that should be filtered
	if deathlog_isFilteredEntry(_player_data) then return end

	-- Drop live broadcasts from senders the user muted. Sync entries have no
	-- trustworthy sender, so they are never matched against this list. Match on
	-- the unforgeable chat GUID first, falling back to name.
	if _checksum and DeathNotificationLib.GetEntryOrigin then
		local origin_sender, _, origin_guid = DeathNotificationLib.GetEntryOrigin(_checksum)
		if Deathlog_isSenderIgnored(origin_sender, origin_guid) then
			return
		end
	end

	local alert_player_data = _player_data

	-- Whitelist alert-eligible entries BEFORE the dedup early-returns below.
	-- If this live death already reached the DB through an alert-ineligible
	-- path (sync backfill, watchlist query), the dedup branches merge and
	-- return early; without the whitelist, the alertFilter would then
	-- suppress the alert via the map_pos identity check (the incoming data
	-- was just merged into the stored entry). Duplicate popups are prevented
	-- by DNL's own per-name alert cache.
	if source == SOURCE.SELF_DEATH or source == SOURCE.PEER_BROADCAST or source == SOURCE.BLIZZARD then
		deathAlertWhitelist[alert_player_data] = true
	end

	-- Check ALL existing entries for this player name for near-duplicate deaths.
	-- The old approach only checked the single latest entry via deathlog_data_map,
	-- which missed duplicates when the latest entry was a different (newer) death.
	local existing_checksums = name_index[realmName][player_name]
	if existing_checksums then
		for cs, _ in pairs(existing_checksums) do
			local entry = deathlog_data[realmName][cs]
			if entry then
				local effective_level = math.max(tonumber(_player_data["level"]) or 0, tonumber(entry["level"]) or 0)
				local time_diff = math.abs(current_time - (entry["date"] or 0))
				if time_diff <= DeathNotificationLib.GetDedupWindow(effective_level) then
					local existing_quality = DeathNotificationLib.EntryQuality(entry)
					local new_quality = DeathNotificationLib.EntryQuality(_player_data)

					if new_quality > existing_quality then
						-- New entry has more data - merge and replace
						_player_data = DeathNotificationLib.MergeEntries(_player_data, entry)
						deathlog_data[realmName][cs] = nil
						existing_checksums[cs] = nil
						Deathlog_forgetEntryOrigin(realmName, cs)
						break
					elseif new_quality < existing_quality then
						-- Existing is better - merge new data into existing, skip
						local merged = DeathNotificationLib.MergeEntries(entry, _player_data)
						deathlog_data[realmName][cs] = merged
						-- Merged rows keep the original key, so attribute the live
						-- sender to that key rather than the incoming checksum.
						Deathlog_recordEntryOrigin(realmName, cs, _checksum, source)
						return
					else
						-- Equal quality - merge into existing, skip
						local merged = DeathNotificationLib.MergeEntries(entry, _player_data)
						deathlog_data[realmName][cs] = merged
						Deathlog_recordEntryOrigin(realmName, cs, _checksum, source)
						return
					end
				end
			else
				-- Stale index entry, clean up
				existing_checksums[cs] = nil
			end
		end
	end

	local modified_checksum = DeathNotificationLib.Fletcher16(_player_data)

	deathlog_data[realmName][modified_checksum] = _player_data

	-- Maintain name index
	if not name_index[realmName][player_name] then
		name_index[realmName][player_name] = {}
	end
	name_index[realmName][player_name][modified_checksum] = true

	Deathlog_recordEntryOrigin(realmName, modified_checksum, _checksum, source)

	-- Only create widgets for self-reported deaths, peer broadcasts, and Blizzard notifications.
	-- Death alert is now handled internally by DNL (~DeathAlert.lua) via createEntry().
	if source == SOURCE.SELF_DEATH or source == SOURCE.PEER_BROADCAST or source == SOURCE.BLIZZARD then
		Deathlog_widget_minilog_createEntry(_player_data)
	end

	deathlog_data_map[realmName][player_name] = modified_checksum

	source = source or SOURCE.UNKNOWN
	if deathlog_entry_counts then
		deathlog_entry_counts[source] = (deathlog_entry_counts[source] or 0) + 1
		deathlog_entry_counts["total"] = (deathlog_entry_counts["total"] or 0) + 1
	end
end

--- One-time cleanup: scan existing deathlog_data for near-duplicate entries
--- (same player name, same level, date within getDedupWindow(level)) and merge
--- them, keeping the highest-quality entry.  Runs synchronously on login.
--- Marks completion in deathlog_settings so it only runs once.
local DEDUP_CLEANUP_VERSION = 1  -- bump to re-run cleanup after future fixes

local function deathlog_runDedupCleanup()
	if deathlog_settings["dedup_cleanup_version"] and deathlog_settings["dedup_cleanup_version"] >= DEDUP_CLEANUP_VERSION then
		return
	end

	local total_removed = 0

	for realmName, entries in pairs(deathlog_data) do
		if type(entries) == "table" then
			-- Build a local name → [{checksum, date, level, quality}] index
			local by_name = {}
			for cs, entry in pairs(entries) do
				local n = entry["name"]
				if n then
					if not by_name[n] then by_name[n] = {} end
					by_name[n][#by_name[n] + 1] = {
						cs = cs,
						date = entry["date"] or 0,
						level = entry["level"] or 0,
						quality = DeathNotificationLib.EntryQuality(entry),
					}
				end
			end

			-- For each name, detect and merge near-duplicates
			for player_name, entry_list in pairs(by_name) do
				if #entry_list > 1 then
					-- Sort by date ascending
					table.sort(entry_list, function(a, b) return a.date < b.date end)

					local i = 1
					while i <= #entry_list do
						local j = i + 1
						while j <= #entry_list do
							local effective_level = math.max(entry_list[i].level, entry_list[j].level)
							local time_diff = math.abs(entry_list[j].date - entry_list[i].date)
							if time_diff <= DeathNotificationLib.GetDedupWindow(effective_level) then
								-- Near-duplicate: keep the higher quality entry, merge data
								local keep = entry_list[i]
								local remove = entry_list[j]
								if remove.quality > keep.quality then
									keep, remove = remove, keep
									entry_list[i] = keep
								end

								local keep_entry = entries[keep.cs]
								local remove_entry = entries[remove.cs]
								if keep_entry and remove_entry then
									local merged = DeathNotificationLib.MergeEntries(keep_entry, remove_entry)
									entries[keep.cs] = merged
									entries[remove.cs] = nil
									-- Update name_index if it exists
									if name_index[realmName] and name_index[realmName][player_name] then
										name_index[realmName][player_name][remove.cs] = nil
									end
									total_removed = total_removed + 1
								end
								table.remove(entry_list, j)
							else
								j = j + 1
							end
						end
						i = i + 1
					end
				end
			end
		end
	end

	deathlog_settings["dedup_cleanup_version"] = DEDUP_CLEANUP_VERSION

	if total_removed > 0 then
		print("|cFF00FF00[Deathlog]|r Database cleanup: removed " .. total_removed .. " duplicate entries.")
	end
end

local deathlog_initialized = false

local function deathlog_watchlistIconProvider(playerName)
	if type(playerName) ~= "string" then return nil end
	if type(deathlog_watchlist_entries) ~= "table" then return nil end
	local watch = deathlog_watchlist_entries[playerName]
	if type(watch) ~= "table" then return nil end
	if type(watch.Icon) ~= "string" or watch.Icon == "" then return nil end
	return watch.Icon
end

local function handleEvent(self, event, ...)
	if event == "ADDON_LOADED" then
		local loaded_addon = ...
		if loaded_addon == addonName then
			initVariables()
			self:UnregisterEvent("ADDON_LOADED")
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		if deathlog_initialized then return end
		deathlog_initialized = true
		initMinimapButton()

		-- Write project id into settings
		deathlog_settings["wow_project_id"] = WOW_PROJECT_ID

		deathlog_settings["DeathAlert"] = deathlog_settings["DeathAlert"] or {}
		deathlog_settings["DeathAlert"]["death_alert_options_parent"] = "Deathlog"
		deathlog_settings["DeathAlert"]["alertFilter"] = function(player_data)
			if deathAlertWhitelist[player_data] then
				deathAlertWhitelist[player_data] = nil
				return false
			end

			return deathlog_isFilteredEntry(player_data)
		end

		-- Ensure realm sub-tables exist so AttachAddon receives valid table
		-- references (not nil) that remain in sync with newEntry.
		local realmName = GetRealmName()
		if deathlog_data[realmName] == nil then
			deathlog_data[realmName] = {}
		end
		if deathlog_data_map[realmName] == nil then
			deathlog_data_map[realmName] = {}
		end
		if deathlog_purged[realmName] == nil then
			deathlog_purged[realmName] = {}
		end

		-- One-time dedup cleanup of existing data (runs before stats/widgets)
		deathlog_runDedupCleanup()

		local version = GetAddOnMetadata("Deathlog", "Version")
		DeathNotificationLib.AttachAddon({
			name             = "Deathlog",
			tag              = "DLG",
			isUnitTracked    = Deathlog_isUnitTracked,
			watchlistIconProvider = deathlog_watchlistIconProvider,
			settings         = deathlog_settings,
			db               = deathlog_data[realmName],
			db_map           = deathlog_data_map[realmName],
			dev_data         = deathlog_dev_data,
			addon_version    = version,
		})
		DeathNotificationLib.HookOnNewAddonEntry("Deathlog", newEntry)

		-- Precomputation of statistics/heatmaps is heavy and, on large datasets,
		-- exceeds the client's per-frame script limit ("script ran too long")
		-- when run all at once. The results are cached in deathlog_precomputed,
		-- so this only runs on a first login or after a version change; but that
		-- first run must be spread across frames. We collect the individual
		-- heavy computations into `precompute_steps` (each does one function's
		-- worth of work), run them one per frame, then finalize (copy results
		-- into the *DataCopy tables and load widgets). When nothing needs
		-- computing (normal reload), `precompute_steps` is empty and the
		-- finalizer runs immediately in this frame, preserving fast behavior.
		local precompute_steps = {}

		if DeathlogDataCopy.PRECOMPUTED_GENERAL_STATS and DeathlogDataCopy.PRECOMPUTED_LOG_NORMAL_PARAMS and DeathlogDataCopy.PRECOMPUTED_LOG_NORMAL_PARAMS_BY_CAUSE and DeathlogDataCopy.PRECOMPUTED_KAPLAN_MEIER and DeathlogDataCopy.PRECOMPUTED_KAPLAN_MEIER_BY_CAUSE and DeathlogDataCopy.PRECOMPUTED_MOST_DEADLY_BY_ZONE and DeathlogDataCopy.PRECOMPUTED_CAUSE_STATS and DeathlogDataCopy.PRECOMPUTED_PURGES then
			deathlog_precomputed.PRECOMPUTED_GENERAL_STATS = nil
			deathlog_precomputed.PRECOMPUTED_LOG_NORMAL_PARAMS = nil
			deathlog_precomputed.PRECOMPUTED_LOG_NORMAL_PARAMS_BY_CAUSE = nil
			deathlog_precomputed.PRECOMPUTED_KAPLAN_MEIER = nil
			deathlog_precomputed.PRECOMPUTED_KAPLAN_MEIER_BY_CAUSE = nil
			deathlog_precomputed.PRECOMPUTED_MOST_DEADLY_BY_ZONE = nil
			deathlog_precomputed.PRECOMPUTED_CAUSE_STATS = nil
			deathlog_precomputed.PRECOMPUTED_PURGES = nil
		else
			if not (version == deathlog_precomputed.DD_VERSION and deathlog_precomputed.PRECOMPUTED_GENERAL_STATS and deathlog_precomputed.PRECOMPUTED_LOG_NORMAL_PARAMS and deathlog_precomputed.PRECOMPUTED_LOG_NORMAL_PARAMS_BY_CAUSE and deathlog_precomputed.PRECOMPUTED_KAPLAN_MEIER and deathlog_precomputed.PRECOMPUTED_KAPLAN_MEIER_BY_CAUSE and deathlog_precomputed.PRECOMPUTED_MOST_DEADLY_BY_ZONE and deathlog_precomputed.PRECOMPUTED_CAUSE_STATS and deathlog_precomputed.PRECOMPUTED_PURGES) then
				deathlog_precomputed.DD_VERSION = version
				precompute_steps[#precompute_steps + 1] = function() deathlog_precomputed.PRECOMPUTED_GENERAL_STATS = Deathlog_calculate_statistics(deathlog_data) end
				precompute_steps[#precompute_steps + 1] = function() deathlog_precomputed.PRECOMPUTED_LOG_NORMAL_PARAMS = Deathlog_calculateLogNormalParameters(deathlog_data) end
				precompute_steps[#precompute_steps + 1] = function() deathlog_precomputed.PRECOMPUTED_LOG_NORMAL_PARAMS_BY_CAUSE = Deathlog_calculateLogNormalParametersByCause(deathlog_data) end
				precompute_steps[#precompute_steps + 1] = function() deathlog_precomputed.PRECOMPUTED_KAPLAN_MEIER = Deathlog_calculateKaplanMeier(deathlog_data) end
				precompute_steps[#precompute_steps + 1] = function() deathlog_precomputed.PRECOMPUTED_KAPLAN_MEIER_BY_CAUSE = Deathlog_calculateKaplanMeierByCause(deathlog_data) end
				precompute_steps[#precompute_steps + 1] = function() deathlog_precomputed.PRECOMPUTED_MOST_DEADLY_BY_ZONE = Deathlog_calculateMostDeadlyByZone(deathlog_data) end
				precompute_steps[#precompute_steps + 1] = function() deathlog_precomputed.PRECOMPUTED_CAUSE_STATS = Deathlog_calculateCauseStats(deathlog_data) end
				precompute_steps[#precompute_steps + 1] = function() deathlog_precomputed.PRECOMPUTED_PURGES = Deathlog_calculatePurges(deathlog_data) end
			end

			precompute_steps[#precompute_steps + 1] = function()
				DeathlogDataCopy.PRECOMPUTED_GENERAL_STATS = deathlog_precomputed.PRECOMPUTED_GENERAL_STATS
				DeathlogDataCopy.PRECOMPUTED_LOG_NORMAL_PARAMS = deathlog_precomputed.PRECOMPUTED_LOG_NORMAL_PARAMS
				DeathlogDataCopy.PRECOMPUTED_LOG_NORMAL_PARAMS_BY_CAUSE = deathlog_precomputed.PRECOMPUTED_LOG_NORMAL_PARAMS_BY_CAUSE
				DeathlogDataCopy.PRECOMPUTED_KAPLAN_MEIER = deathlog_precomputed.PRECOMPUTED_KAPLAN_MEIER
				DeathlogDataCopy.PRECOMPUTED_KAPLAN_MEIER_BY_CAUSE = deathlog_precomputed.PRECOMPUTED_KAPLAN_MEIER_BY_CAUSE
				DeathlogDataCopy.PRECOMPUTED_MOST_DEADLY_BY_ZONE = deathlog_precomputed.PRECOMPUTED_MOST_DEADLY_BY_ZONE
				DeathlogDataCopy.PRECOMPUTED_CAUSE_STATS = deathlog_precomputed.PRECOMPUTED_CAUSE_STATS
				DeathlogDataCopy.PRECOMPUTED_PURGES = deathlog_precomputed.PRECOMPUTED_PURGES
			end
		end

		if DeathNotificationLibDataCopy.HEATMAP_INTENSITY and DeathNotificationLibDataCopy.HEATMAP_INTENSITY_BY_CAUSE and DeathNotificationLibDataCopy.HEATMAP_CREATURE_SUBSET then
			deathlog_precomputed.HEATMAP_INTENSITY = nil
			deathlog_precomputed.HEATMAP_INTENSITY_BY_CAUSE = nil
			deathlog_precomputed.HEATMAP_CREATURE_SUBSET = nil
		else
			if not (version == deathlog_precomputed.DNLD_VERSION and deathlog_precomputed.HEATMAP_INTENSITY and deathlog_precomputed.HEATMAP_INTENSITY_BY_CAUSE and deathlog_precomputed.HEATMAP_CREATURE_SUBSET) then
				-- skull_locs is derived once and shared by the three heatmap
				-- steps; hold it in an upvalue populated by the first step.
				local heatmap_skull_locs
				precompute_steps[#precompute_steps + 1] = function()
					heatmap_skull_locs = Deathlog_calculateSkullLocs(deathlog_data)
					deathlog_precomputed.DNLD_VERSION = version
				end
				precompute_steps[#precompute_steps + 1] = function() deathlog_precomputed.HEATMAP_INTENSITY = Deathlog_calculateHeatmapIntensity(heatmap_skull_locs) end
				precompute_steps[#precompute_steps + 1] = function() deathlog_precomputed.HEATMAP_INTENSITY_BY_CAUSE = Deathlog_calculateHeatmapIntensityByCause(heatmap_skull_locs) end
				precompute_steps[#precompute_steps + 1] = function() deathlog_precomputed.HEATMAP_CREATURE_SUBSET = Deathlog_calculateHeatmapCreatureSubset(heatmap_skull_locs) end
			end

			precompute_steps[#precompute_steps + 1] = function()
				DeathNotificationLibDataCopy.HEATMAP_INTENSITY = deathlog_precomputed.HEATMAP_INTENSITY
				DeathNotificationLibDataCopy.HEATMAP_INTENSITY_BY_CAUSE = deathlog_precomputed.HEATMAP_INTENSITY_BY_CAUSE
				DeathNotificationLibDataCopy.HEATMAP_CREATURE_SUBSET = deathlog_precomputed.HEATMAP_CREATURE_SUBSET
			end
		end

		local function finalizePrecompute()
			loadWidgets()

			-- Check if we should show changelog popup (version upgrade)
			if Deathlog_CheckShowChangelog then
				Deathlog_CheckShowChangelog()
			end

			initEntryCounters()
			C_Timer.After(2.5, function()
				Deathlog_CheckCTA()
				Deathlog_startInvalidEntryCleanse()
				Deathlog_startHunterCleanup()
				DeathNotificationLib.UpdateDeathAlert()
			end)

			if not deathlog_sync_options_registered then
				deathlog_sync_options_registered = true
				LibStub("AceConfig-3.0"):RegisterOptionsTable("DeathlogSync", sync_options)
				LibStub("AceConfigDialog-3.0"):AddToBlizOptions("DeathlogSync", "Database Sync", "Deathlog")
			end
		end

		if #precompute_steps == 0 then
			-- Cache is valid: run synchronously, no visible startup delay.
			finalizePrecompute()
		else
			-- Run the heavy steps inside a coroutine. Each step's inner loops call
			-- Deathlog_YieldCheck(), which yields the coroutine every N processed
			-- entries. The driver resumes the coroutine once per frame via
			-- C_Timer.After(0, ...), so every chunk of work runs with a fresh
			-- per-frame script-time budget and no single frame trips the
			-- "script ran too long" limit — even for a single heavy function.
			local co = coroutine.create(function()
				for i = 1, #precompute_steps do
					precompute_steps[i]()
				end
			end)

			local function resumePrecompute()
				if Deathlog_SetYieldActive then Deathlog_SetYieldActive(true) end
				local ok, err = coroutine.resume(co)
				if Deathlog_SetYieldActive then Deathlog_SetYieldActive(false) end

				if not ok then
					-- A step errored; stop the async run and surface the error, but
					-- still finalize so widgets/counters initialize (they degrade
					-- gracefully when a precomputed table is missing). Finalize on a
					-- fresh frame so widget creation gets a full script budget.
					geterrorhandler()(err)
					C_Timer.After(0, finalizePrecompute)
					return
				end

				if coroutine.status(co) == "dead" then
					-- Run finalize (loadWidgets etc.) on its OWN frame rather than
					-- inline: the frame that just resumed the coroutine already spent
					-- part of its script budget on the final compute chunk, and
					-- building the minilog widgets in that same frame could still
					-- trip the "script ran too long" limit.
					C_Timer.After(0, finalizePrecompute)
				else
					C_Timer.After(0, resumePrecompute)
				end
			end

			resumePrecompute()
		end
	end
end

--- Print the versions of Deathlog and its bundled sub-addons/libraries to chat,
--- noting if a newer Deathlog version has been detected from other players.
local function printVersions()
	local function metaVersion(name)
		return GetAddOnMetadata(name, "Version")
	end
	local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded

	-- Print a separately-shipped companion AddOn line. GetAddOnMetadata reads the
	-- on-disk TOC, so it returns a version even when the AddOn is installed but
	-- DISABLED (unchecked in the AddOns list) — which is misleading because a
	-- disabled companion contributes nothing at runtime. So report the loaded
	-- state: skip when not installed, and mark it (disabled) when installed but
	-- not loaded.
	local function printCompanion(label, name)
		local version = metaVersion(name)
		if not version then return end -- not installed
		if isLoaded and isLoaded(name) then
			DEFAULT_CHAT_FRAME:AddMessage("  " .. label .. ": |cffffffff" .. version .. "|r")
		else
			DEFAULT_CHAT_FRAME:AddMessage("  " .. label .. ": |cffffffff" .. version .. "|r |cff999999(installed, disabled)|r")
		end
	end

	DEFAULT_CHAT_FRAME:AddMessage("|cffffd200Deathlog versions|r")

	local mainVersion = metaVersion("Deathlog") or "unknown"
	DEFAULT_CHAT_FRAME:AddMessage("  Deathlog: |cffffffff" .. mainVersion .. "|r")

	-- DeathNotificationLib is a hard runtime dependency (always active via the
	-- global), so its runtime value is the real one. Prefer its separately-shipped
	-- TOC version; fall back to the embed revision (embedded dev structure).
	local dnlVersion = metaVersion("DeathNotificationLib")
		or (DeathNotificationLib and DeathNotificationLib.VERSION)
	DEFAULT_CHAT_FRAME:AddMessage("  DeathNotificationLib: |cffffffff" .. tostring(dnlVersion or "unknown") .. "|r")

	-- Optional data companions: only report as active when actually loaded.
	printCompanion("DeathlogData", "DeathlogData")
	printCompanion("DeathNotificationLibData", "DeathNotificationLibData")

	-- Note a known newer version, if one has been detected from other players.
	local detected = deathlog_settings and deathlog_settings["newest_detected_update_version"]
	if detected and Deathlog_IsVersionNewer and Deathlog_IsVersionNewer(detected, mainVersion) then
		DEFAULT_CHAT_FRAME:AddMessage("|cffff5555Update available:|r Deathlog |cffffffff" .. tostring(detected)
			.. "|r has been seen from other players. Type |cffffffff/dl update|r for download sources.")
	else
		DEFAULT_CHAT_FRAME:AddMessage("|cff55ff55You're up to date|r as far as Deathlog can tell.")
	end
end
Deathlog_PrintVersions = printVersions

local function SlashHandler(msg, editbox)
	local command, arg = string.match(string.lower(msg or ""), "^%s*(%S*)%s*(.-)%s*$")
	command = command or ""
	arg = arg or ""
	-- Character names are case-sensitive, so keep the untouched argument too.
	local raw_arg = string.match(msg or "", "^%s*%S*%s*(.-)%s*$") or ""

	if command == "version" or command == "versions" then
		printVersions()
	elseif command == "option" or command == "options" then
		Deathlog_OpenSettings()
	elseif command == "alert" then
		DeathNotificationLib.TestDeathAlert()
	elseif command == "sync" then
		DeathNotificationLib.SyncStatus()
	elseif command == "changelog" then
		if Deathlog_ShowChangelog then
			Deathlog_ShowChangelog()
		end
	elseif command == "update" or command == "updates" then
		Deathlog_ShowUpdateSources()
	elseif command == "hidden" or command == "unhide" then
		handleHiddenCommand(command, raw_arg)
	elseif command == "minilog" or command == "mini" or command == "mini-log" or command == "ml" then
		handleMiniLogCommand(arg)
	else
		DeathlogShowMenu(deathlog_data, DeathlogDataCopy.PRECOMPUTED_GENERAL_STATS, DeathlogDataCopy.PRECOMPUTED_LOG_NORMAL_PARAMS)
	end
end

SLASH_DEATHLOG1, SLASH_DEATHLOG2 = "/deathlog", "/dl"
SlashCmdList["DEATHLOG"] = SlashHandler

local deathlog_event_handler = CreateFrame("Frame", "deathlog", nil, "BackdropTemplate")
deathlog_event_handler:RegisterEvent("ADDON_LOADED")
deathlog_event_handler:RegisterEvent("PLAYER_ENTERING_WORLD")

deathlog_event_handler:SetScript("OnEvent", handleEvent)

-- reset leaked SetWhoToUi on chat shift-click
hooksecurefunc("SetItemRef", function(link)
	if IsShiftKeyDown() and type(link) == "string" and string.sub(link, 1, 6) == "player" then
		C_FriendList.SetWhoToUi(false)
	end
end)

local LSM30 = LibStub("LibSharedMedia-3.0", true)
local options = {
	name = addonName,
	handler = Hardcore,
	type = "group",
	args = {
		load_from_hc = {
			type = "execute",
			name = "Import deathlog from hardcore",
			desc = "Import deathlog from hardcore. This will append entries.",
			width = 1.3,
			order = 1,
			func = function()
				Deathlog_LoadFromHardcore()
			end,
		},
		clear_cache_button = {
			type = "execute",
			name = "Clear cache",
			desc = "WARNING: This will remove deathlog data.  Do this if your log is getting too long.  The data is stored at _classic_era_/WTF/Account/<your_account_name>/SavedVariables/Deathlog.lua.  Reload after doing this.",
			width = 1.3,
			order = 2,
			func = function()
				wipe(deathlog_data)
				wipe(deathlog_data_map)
			end,
		},
		peer_reporting = {
			type = "toggle",
			name = "Allow peer-reported deaths",
			desc = "When enabled, deaths reported by party/raid members and tarnished soul detections from other players are accepted. When disabled, only self-reported deaths and Blizzard's hardcore death channel notifications are shown.",
			width = 1.3,
			order = 10,
			get = function()
				if deathlog_settings["peer_reporting"] == nil then
					deathlog_settings["peer_reporting"] = true
				end
				return deathlog_settings["peer_reporting"]
			end,
			set = function()
				deathlog_settings["peer_reporting"] = not deathlog_settings["peer_reporting"]
			end,
		},
		accept_legacy_messages = {
			type = "toggle",
			name = "Accept legacy protocol messages",
			desc = "When enabled, death messages from older addon versions (v0–v2 protocol) are accepted. When disabled, only current (v3) protocol messages are processed.",
			width = 1.5,
			order = 20,
			get = function()
				if deathlog_settings["legacy_messages"] == nil then
					deathlog_settings["legacy_messages"] = true
				end
				return deathlog_settings["legacy_messages"]
			end,
			set = function()
				deathlog_settings["legacy_messages"] = not deathlog_settings["legacy_messages"]
			end,
		},
		show_addonless_deaths = {
			type = "toggle",
			name = "Allow addonless death logging",
			desc = "When enabled, deaths received from Blizzard's HardcoreDeaths channel are converted into Deathlog entries. These entries have less detail (no race, class, or precise location) since the dying player isn't running the addon. Disable this if you only want full-quality addon-reported deaths in your log.",
			width = 1.3,
			order = 30,
			get = function()
				if deathlog_settings["addonless_logging"] == nil then
					deathlog_settings["addonless_logging"] = false
				end
				return deathlog_settings["addonless_logging"]
			end,
			set = function()
				deathlog_settings["addonless_logging"] = not deathlog_settings["addonless_logging"]
			end,
		},
		auto_blizzard_deaths = {
			type = "toggle",
			name = "Auto-configure Blizzard death tracking",
			desc = "When enabled, Deathlog automatically configures the Blizzard hardcore death CVars, joins the HardcoreDeaths channel (hidden), and periodically verifies they remain active. This lets us convert Blizzard's built-in death notifications into full Deathlog entries. If you don't want lower-quality data from these notifications, you can leave this on and disable 'Allow addonless death logging' instead.",
			width = 1.5,
			order = 35,
			get = function()
				if deathlog_settings["auto_blizzard_deaths"] == nil then
					deathlog_settings["auto_blizzard_deaths"] = true
				end
				return deathlog_settings["auto_blizzard_deaths"]
			end,
			set = function()
				deathlog_settings["auto_blizzard_deaths"] = not deathlog_settings["auto_blizzard_deaths"]
			end,
		},
		auto_hide_chat_channels = {
			type = "toggle",
			name = "Auto-hide addon chat channels",
			desc = "When enabled, Deathlog automatically hides its chat channels (death alerts, sync) from all chat frames so they don't clutter your chat windows. Disable this if you want to see the raw channel traffic for debugging.",
			width = 1.3,
			order = 36,
			get = function()
				if deathlog_settings["auto_hide_chat_channels"] == nil then
					deathlog_settings["auto_hide_chat_channels"] = true
				end
				return deathlog_settings["auto_hide_chat_channels"]
			end,
			set = function()
				deathlog_settings["auto_hide_chat_channels"] = not deathlog_settings["auto_hide_chat_channels"]
			end,
		},
		share_playtime = {
			type = "toggle",
			name = "Include playtime in death report",
			desc = "When enabled, your total /played time is included in your death broadcast so others can see how long you survived. Disable this if you prefer to keep your playtime private.",
			width = 1.3,
			order = 37,
			get = function()
				if deathlog_settings["share_playtime"] == nil then
					deathlog_settings["share_playtime"] = true
				end
				return deathlog_settings["share_playtime"]
			end,
			set = function()
				deathlog_settings["share_playtime"] = not deathlog_settings["share_playtime"]
			end,
		},
		show_minimap_button = {
			type = "toggle",
			name = "Show minimap button",
			desc = "Toggles whether the minimap button is visible.",
			width = 1.3,
			order = 40,
			get = function()
				if deathlog_settings["show_minimap"] == nil then
					deathlog_settings["show_minimap"] = true
				end
				return deathlog_settings["show_minimap"]
			end,
			set = function()
				deathlog_settings["show_minimap"] = not deathlog_settings["show_minimap"]

				if not deathlog_minimap_button_stub then return end

				if deathlog_settings["show_minimap"] then
					deathlog_minimap_button_stub:Show(addonName)
				else
					deathlog_minimap_button_stub:Hide(addonName)
				end
			end,
		},
		colored_tooltips = {
			type = "toggle",
			name = "Colored tooltips",
			desc = "Toggles whether tooltips have colored fields.",
			width = 1.3,
			order = 50,
			get = function()
				if deathlog_settings["colored_tooltips"] == nil then
					deathlog_settings["colored_tooltips"] = false
				end
				return deathlog_settings["colored_tooltips"]
			end,
			set = function()
				deathlog_settings["colored_tooltips"] = not deathlog_settings["colored_tooltips"]
			end,
		},
		auto_refresh_search = {
			type = "toggle",
			name = "Auto-refresh search results",
			desc = "When enabled, the Log tab automatically refreshes every 10 seconds so new deaths appear without reopening the UI. Only fires when on page 1 with no active filters.",
			width = 1.3,
			order = 55,
			get = function()
				if deathlog_settings["auto_refresh_search"] == nil then
					deathlog_settings["auto_refresh_search"] = false
				end
				return deathlog_settings["auto_refresh_search"]
			end,
			set = function()
				deathlog_settings["auto_refresh_search"] = not deathlog_settings["auto_refresh_search"]
			end,
		},
		european_date_format = {
		type = "toggle",
		name = "Use DD/MM/YYYY date format",
		desc = "Display dates as DD/MM/YY instead of MM/DD/YY.",
		width = 1.3,
		order = 56,
		get = function()
			return not not deathlog_settings["european_date_format"]
		end,
		set = function()
			deathlog_settings["european_date_format"] = not deathlog_settings["european_date_format"]
		end,
		},
		prediction_radius = {
			type = "range",
			name = "Source prediction radius",
			desc = "Search radius (in map cells) when predicting the death source from heatmap data. Higher values may find matches further away but could be less accurate.",
			width = 1.5,
			order = 60,
			min = 0,
			max = 20,
			step = 1,
			get = function()
				if deathlog_settings["prediction_radius"] == nil then
					deathlog_settings["prediction_radius"] = 5
				end
				return deathlog_settings["prediction_radius"]
			end,
			set = function(_, val)
				deathlog_settings["prediction_radius"] = val
			end,
		},
	},
}

LibStub("AceConfig-3.0"):RegisterOptionsTable(addonName, options)
local _, deathlog_settings_category_id = LibStub("AceConfigDialog-3.0"):AddToBlizOptions(addonName, "Deathlog", nil)

-- Newer clients (TBC Anniversary 2.5.6+) require the numeric category ID returned
-- by AddToBlizOptions; passing the addon name string errors in OpenSettingsPanel.
function Deathlog_OpenSettings()
	if Settings and Settings.OpenToCategory and deathlog_settings_category_id then
		local ok = pcall(Settings.OpenToCategory, deathlog_settings_category_id)
		if ok then
			return
		end
	end
	LibStub("AceConfigDialog-3.0"):Open(addonName)
end

sync_options = {
	name = "Database Sync",
	type = "group",
	args = {
		sync_desc = {
			type = "description",
			name = "Continuously sync death entries with other Deathlog users in the background. Peers exchange watermarks, manifests, and entries over a dedicated addon channel.",
			fontSize = "medium",
			order = 1,
		},
		sync_enabled = {
			type = "toggle",
			name = "Enable database sync",
			desc = "Toggle background database sync on or off.",
			width = 1.3,
			order = 10,
			get = function()
				if deathlog_settings["sync_enabled"] == nil then
					deathlog_settings["sync_enabled"] = true
				end
				return deathlog_settings["sync_enabled"]
			end,
			set = function()
				deathlog_settings["sync_enabled"] = not deathlog_settings["sync_enabled"]
			end,
		},
		sync_window_days = {
			type = "range",
			name = "Sync window (days)",
			desc = "Only sync entries from the last N days. Larger windows exchange more data but cover more history. Set to -1 to sync ALL data.",
			width = 1.5,
			min = -1,
			max = 30,
			step = 1,
			order = 20,
			get = function()
				if deathlog_settings["sync_window_days"] == nil then
					deathlog_settings["sync_window_days"] = 7
				end
				return deathlog_settings["sync_window_days"]
			end,
			set = function(_, val)
				deathlog_settings["sync_window_days"] = val
			end,
		},
		sync_interval = {
			type = "range",
			name = "Watermark interval (seconds)",
			desc = "How often to broadcast your watermark to other peers. Lower values detect gaps faster but generate more traffic.",
			width = 1.5,
			min = 60,
			max = 3600,
			step = 30,
			order = 30,
			get = function()
				if deathlog_settings["sync_interval"] == nil then
					deathlog_settings["sync_interval"] = 300
				end
				return deathlog_settings["sync_interval"]
			end,
			set = function(_, val)
				deathlog_settings["sync_interval"] = val
			end,
		},
		sync_max_entries = {
			type = "range",
			name = "Max entries per sync",
			desc = "Maximum number of entries to request in a single sync session. Higher values catch up faster but use more bandwidth.",
			width = 1.5,
			min = 10,
			max = 2000,
			step = 10,
			order = 40,
			get = function()
				if deathlog_settings["sync_max_entries"] == nil then
					deathlog_settings["sync_max_entries"] = 500
				end
				return deathlog_settings["sync_max_entries"]
			end,
			set = function(_, val)
				deathlog_settings["sync_max_entries"] = val
			end,
		},
		sync_cooldown = {
			type = "range",
			name = "Sync cooldown (seconds)",
			desc = "Minimum time between sync sessions. Lower values re-sync sooner after finishing but generate more traffic. Set to 0 to sync continuously.",
			width = 1.5,
			min = 0,
			max = 3600,
			step = 30,
			order = 45,
			get = function()
				if deathlog_settings["sync_cooldown"] == nil then
					deathlog_settings["sync_cooldown"] = 300
				end
				return deathlog_settings["sync_cooldown"]
			end,
			set = function(_, val)
				deathlog_settings["sync_cooldown"] = val
			end,
		},
		sync_status = {
			type = "execute",
			name = "Show sync status",
			desc = "Print current sync status to chat (state, peer count, last sync time, cooldown).",
			width = 1.3,
			order = 50,
			func = function()
				DeathNotificationLib.SyncStatus()
			end,
		},
	},
}