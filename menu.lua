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
---@diagnostic disable: invisible
--
-- API compatibility: Classic Era uses GetAddOnMetadata, TBC Anniversary uses C_AddOns.GetAddOnMetadata
local GetAddOnMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata

local id_to_npc = DeathNotificationLib.ID_TO_NPC
local instance_to_id = DeathNotificationLib.INSTANCE_TO_ID
local id_to_instance = DeathNotificationLib.ID_TO_INSTANCE
local zone_to_id = DeathNotificationLib.ZONE_TO_ID
local deathlog_environment_damage = DeathNotificationLib.ENVIRONMENT_DAMAGE
local instance_categories = DeathNotificationLib.INSTANCE_CATEGORIES
local zone_categories = DeathNotificationLib.ZONE_CATEGORIES
local deathlog_class_colors = DeathNotificationLib.CLASS_ID_TO_COLOR
local source_kind = Deathlog_GetSourceKindConstants()

local _menu_width = 1100
local _inner_menu_width = 800
local _menu_height = 600
local current_map_id = nil
local max_rows = 25
local page_number = 1
local total_pages = 1

local main_font = Deathlog_L.main_font

-- main_font (FRIZQT__.TTF on western clients) has no Cyrillic glyphs, so Russian
-- player names render as boxes in the main log. FRIZQT___CYR.TTF ships on all
-- western clients and covers Latin + Cyrillic. Detect Cyrillic via a single
-- C-level byte scan (UTF-8 lead bytes 0xD0/0xD1 = U+0400–U+04FF) and swap the
-- font only for those names. State is tracked per fontstring so SetFont is only
-- called when the script class of the text changes.
local DEATHLOG_CYRILLIC_FONT = "Fonts\\FRIZQT___CYR.TTF"
local function Deathlog_menuApplyFontForText(font_string, text, font_path, font_size)
	if font_string == nil then return end
	local needs_cyrillic = type(text) == "string" and text:find("[\208\209]") ~= nil
	if font_string._dl_cyrillic == needs_cyrillic and font_string._dl_font == font_path then
		return
	end
	font_string._dl_cyrillic = needs_cyrillic
	font_string._dl_font = font_path
	font_string:SetFont(needs_cyrillic and DEATHLOG_CYRILLIC_FONT or font_path, font_size, "")
end

local deathlog_tabcontainer ---@type AceGUIDeathlogTabGroup
local deathlog_cta_banner ---@type any

local class_tbl = Deathlog_class_tbl
local race_tbl = Deathlog_race_tbl

-- Cached sorted results for pagination (avoids re-filtering/re-sorting on page changes)
local cached_sorted_results = nil
local cached_filter_version = 0  -- Incremented when filters change

local _auto_refresh_ticker = nil
local _get_filters_active = nil  -- Set by drawLogTab; returns true if any filter is active
local _get_active_filter = nil   -- Set by drawLogTab; returns the current filter function
local current_menu_group = "LogTab"
local current_creature_stats_source_id = 40
local current_creature_stats_source_name = "Kobold Miner"
local current_class_stats_class_id = 1
local current_class_stats_class_name = "Warrior"
local current_class_stats_model = "LogNormal"
local current_class_stats_view = "Survival"
local Deathlog_GetMenuPreprocessedTotal

local deathlog_menu ---@type AceGUIDeathlogMenu

local function Deathlog_GetMenuSourceKind()
	if deathlog_settings == nil then
		return Deathlog_GetDefaultSourceKind()
	end

	if deathlog_settings["menu_source_kind"] == nil then
		local default_source_kind = Deathlog_GetDefaultSourceKind()
		local selected_search_kind = Deathlog_GetConfiguredSourceKind(deathlog_settings, "search_log_source_kind")
		local selected_stats_kind = Deathlog_GetConfiguredSourceKind(deathlog_settings, "stats_cause_kind")
		if selected_search_kind ~= default_source_kind then
			deathlog_settings["menu_source_kind"] = selected_search_kind
		elseif selected_stats_kind ~= default_source_kind then
			deathlog_settings["menu_source_kind"] = selected_stats_kind
		else
			deathlog_settings["menu_source_kind"] = default_source_kind
		end
	end

	return Deathlog_GetConfiguredSourceKind(deathlog_settings, "menu_source_kind")
end

local function Deathlog_SetMenuSourceKind(selected_kind)
	if deathlog_settings == nil then
		return
	end

	local normalized_kind = Deathlog_NormalizeSourceKind(selected_kind)
	deathlog_settings["menu_source_kind"] = normalized_kind
	deathlog_settings["search_log_source_kind"] = normalized_kind
	deathlog_settings["stats_cause_kind"] = normalized_kind
end

local function Deathlog_UpdateMenuSourceKindControl()
	if deathlog_menu == nil or deathlog_menu.footer_source_kind_dd == nil then
		return
	end

	UIDropDownMenu_SetText(
		deathlog_menu.footer_source_kind_dd,
		Deathlog_GetSourceKindOptions()[Deathlog_GetMenuSourceKind()] or "All Causes"
	)
end

local function Deathlog_LayoutMenuSourceKindControl()
	if
		deathlog_menu == nil
		or deathlog_menu.footer_source_kind_dd == nil
		or deathlog_menu.footer_source_kind_label == nil
		or deathlog_tabcontainer == nil
		or deathlog_tabcontainer.tabs == nil
	then
		return
	end

	local watch_list_tab = nil
	for _, tab in pairs(deathlog_tabcontainer.tabs) do
		if tab and tab.value == "WatchListTab" and tab:IsShown() then
			watch_list_tab = tab
			break
		end
	end

	deathlog_menu.footer_source_kind_dd:ClearAllPoints()
	deathlog_menu.footer_source_kind_label:ClearAllPoints()
	deathlog_menu.statustext:ClearAllPoints()

	if watch_list_tab then
		deathlog_menu.footer_source_kind_dd:SetPoint("RIGHT", watch_list_tab, "LEFT", 16, -2)
		deathlog_menu.footer_source_kind_label:SetPoint("LEFT", deathlog_menu.footer_source_kind_dd, "LEFT", 20, 20)
	else
		deathlog_menu.footer_source_kind_dd:SetPoint("TOPRIGHT", deathlog_menu.frame, "TOPRIGHT", -350, -42)
		deathlog_menu.footer_source_kind_label:SetPoint("LEFT", deathlog_menu.footer_source_kind_dd, "LEFT", 20, 20)
	end

	deathlog_menu.statustext:SetPoint("BOTTOMRIGHT", deathlog_menu.frame, "BOTTOMRIGHT", -30, 10)
	deathlog_menu.statustext:SetWidth(420)
end

local WorldMapButton = WorldMapFrame:GetCanvas()
local death_tomb_frame = CreateFrame("frame", nil, WorldMapButton)
death_tomb_frame:SetAllPoints()
death_tomb_frame:SetFrameLevel(15000)

local death_tomb_frame_tex = death_tomb_frame:CreateTexture(nil, "OVERLAY")
death_tomb_frame_tex:SetTexture("Interface\\TARGETINGFRAME\\UI-TargetingFrame-Skull")
death_tomb_frame_tex:SetDrawLayer("OVERLAY", 4)
death_tomb_frame_tex:SetHeight(25)
death_tomb_frame_tex:SetWidth(25)
death_tomb_frame_tex:Hide()

local death_tomb_frame_tex_glow = death_tomb_frame:CreateTexture(nil, "OVERLAY")
death_tomb_frame_tex_glow:SetTexture("Interface\\Glues/Models/UI_HUMAN/GenericGlow64")
death_tomb_frame_tex_glow:SetDrawLayer("OVERLAY", 3)
death_tomb_frame_tex_glow:SetHeight(55)
death_tomb_frame_tex_glow:SetWidth(55)
death_tomb_frame_tex_glow:Hide()

local function WPDropDownDemo_Menu(frame, level, menuList)
	local info = UIDropDownMenu_CreateInfo()

	local function canOpenWorldMap()
		if not (death_tomb_frame.map_id and death_tomb_frame.coordinates) then
			return false
		end
		if C_Map.GetMapInfo(death_tomb_frame["map_id"]) == nil then
			return false
		end
		if tonumber(death_tomb_frame.coordinates[1]) == nil or tonumber(death_tomb_frame.coordinates[2]) == nil then
			return false
		end
		return true
	end

	local function openWorldMap()
		if not canOpenWorldMap() then
			return
		end
		
		if not WorldMapFrame:IsShown() then
			ToggleFrame(WorldMapFrame)
		end

		WorldMapFrame:SetMapID(death_tomb_frame.map_id)
		WorldMapFrame:GetCanvas()
		local mWidth, mHeight = WorldMapFrame:GetCanvas():GetSize()
		death_tomb_frame_tex:SetPoint(
			"CENTER",
			WorldMapButton,
			"TOPLEFT",
			mWidth * death_tomb_frame.coordinates[1],
			-mHeight * death_tomb_frame.coordinates[2]
		)
		death_tomb_frame_tex:Show()

		death_tomb_frame_tex_glow:SetPoint(
			"CENTER",
			WorldMapButton,
			"TOPLEFT",
			mWidth * death_tomb_frame.coordinates[1],
			-mHeight * death_tomb_frame.coordinates[2]
		)
		death_tomb_frame_tex_glow:Show()
		death_tomb_frame:Show()
		deathlog_menu:Hide()
	end

	local function canBlockUser()
		if not death_tomb_frame.clicked_name then
			return false
		end
		if C_FriendList.GetNumIgnores() >= 50 then
			return false
		end
		return true
	end

	local function blockUser()
		if canBlockUser() then
			local added = C_FriendList.AddIgnore(death_tomb_frame.clicked_name)
		end
	end

	local function canWhisperPlayer()
		if not death_tomb_frame.clicked_name then
			return false
		end
		return true
	end

	local function whisperPlayer()
		if canWhisperPlayer() then
			ChatFrame_OpenChat("/w " .. death_tomb_frame.clicked_name .. " ")
		end
	end

	if level == 1 then
		info.text, info.hasArrow, info.func, info.disabled = "Whisper player", false, whisperPlayer, not canWhisperPlayer()
		UIDropDownMenu_AddButton(info)
		info.text, info.hasArrow, info.func, info.disabled = "Show death location", false, openWorldMap, not canOpenWorldMap()
		UIDropDownMenu_AddButton(info)
		info.text, info.hasArrow, info.func, info.disabled = "Block user", false, blockUser, not canBlockUser()
		UIDropDownMenu_AddButton(info)

		Deathlog_addContextMenuReportItems(death_tomb_frame.clicked_player_data)
	end
end

hooksecurefunc(WorldMapFrame, "OnMapChanged", function()
	death_tomb_frame:Hide()
end)

local subtitle_data = {
	{
		"Date",
		105,
		function(_entry, _server_name)
			if deathlog_settings and deathlog_settings["european_date_format"] then
				return date("%d/%m/%y, %H:%M", _entry["date"]) or ""
			else
				return date("%m/%d/%y, %H:%M", _entry["date"]) or ""
			end
		end,
	},
	{
		"Lvl",
		30,
		function(_entry, _server_name)
			return _entry["level"] or ""
		end,
	},
	{
		"Name",
		90,
		function(_entry, _server_name)
			local name = _entry["name"] or ""
			-- Trailing * marks a death a peer reported to us (see tooltip for who).
			if name ~= "" and Deathlog_getDisplaySender(_entry) then
				return name .. "*"
			end
			return name
		end,
	},
	{
		"Class",
		60,
		function(_entry, _server_name)
			if _entry["class_id"] == nil then
				return ""
			end
			local class_id = _entry["class_id"]
			local class_str, _, _ = GetClassInfo(class_id)
			if class_id then
				if deathlog_class_colors[class_id] then
					return "|c"
						.. deathlog_class_colors[class_id].colorStr
						.. class_str
						.. "|r"
				end
			end
			return class_str or ""
		end,
	},
	{
		"Race",
		60,
		function(_entry, _server_name)
			if _entry["race_id"] == nil then
				return ""
			end
			local race_info = C_CreatureInfo.GetRaceInfo(_entry["race_id"])
			if race_info then
				return race_info.raceName or ""
			end
			return ""
		end,
	},
	{
		"Guild",
		120,
		function(_entry, _server_name)
			return _entry["guild"] or ""
		end,
	},
	{
		"Zone/Instance",
		100,
		function(_entry, _server_name)
			if _entry["map_id"] == nil then
				if _entry["instance_id"] ~= nil then
					return id_to_instance[_entry["instance_id"]] or _entry["instance_id"]
				else
					return "-----------"
				end
			end
			local map_info = C_Map.GetMapInfo(_entry["map_id"])
			if map_info then
				return map_info.name
			end
			return "-----------"
		end,
	},
	{
		"Death Source",
		140,
		function(_entry, _server_name)
			return DeathlogGetCachedSource(_entry)
		end,
	},
	{
		"Playtime",
		70,
		function(_entry, _server_name)
			return DeathNotificationLib.FormatPlaytime(_entry["played"]) or ""
		end,
	},
	{
		"Last Words",
		200,
		function(_entry, _server_name)
			return _entry["last_words"] or ""
		end,
	},
}

local AceGUI = LibStub("AceGUI-3.0")

local font_container = CreateFrame("Frame")
font_container:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
font_container:SetSize(100, 100)
font_container:Show()
local font_strings = {} -- idx/columns
local header_strings = {} -- columns
local row_backgrounds = {} --idx

local last_font_string = nil
for idx, v in ipairs(subtitle_data) do
	header_strings[v[1]] = font_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	if idx == 1 then
		header_strings[v[1]]:SetPoint("LEFT", font_container, "LEFT", 0, 0)
	else
		header_strings[v[1]]:SetPoint("LEFT", last_font_string, "RIGHT", 0, 0)
	end
	last_font_string = header_strings[v[1]]
	header_strings[v[1]]:SetJustifyH("LEFT")
	header_strings[v[1]]:SetWordWrap(false)

	if idx + 1 <= #subtitle_data then
		header_strings[v[1]]:SetWidth(v[2])
	end
	header_strings[v[1]]:SetTextColor(0.7, 0.7, 0.7)
	header_strings[v[1]]:SetFont(main_font, 12, "")
end

for i = 1, max_rows do
	font_strings[i] = {}
	local last_font_string = nil
	for idx, v in ipairs(subtitle_data) do
		font_strings[i][v[1]] = font_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		if idx == 1 then
			font_strings[i][v[1]]:SetPoint("LEFT", font_container, "LEFT", 0, 0)
		else
			font_strings[i][v[1]]:SetPoint("LEFT", last_font_string, "RIGHT", 0, 0)
		end
		last_font_string = font_strings[i][v[1]]
		font_strings[i][v[1]]:SetJustifyH("LEFT")
		font_strings[i][v[1]]:SetWordWrap(false)

		if idx + 1 <= #subtitle_data then
			font_strings[i][v[1]]:SetWidth(v[2])
		end
		font_strings[i][v[1]]:SetTextColor(1, 1, 1)
		font_strings[i][v[1]]:SetFont(main_font, 10, "")
	end

	row_backgrounds[i] = font_container:CreateTexture(nil, "OVERLAY")
	row_backgrounds[i]:SetDrawLayer("OVERLAY", 2)
	row_backgrounds[i]:SetVertexColor(0.5, 0.5, 0.5, (i % 2) / 10)
	row_backgrounds[i]:SetHeight(16)
	row_backgrounds[i]:SetWidth(1600)
	row_backgrounds[i]:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
end

local function clearDeathlogMenuLogData(skipPageReset)
	if not skipPageReset then
		page_number = 1
		if font_container.page_str then
			font_container.page_str:SetText("Page " .. page_number)
		end
	end
	for i, v in ipairs(font_strings) do
		for _, col in ipairs(subtitle_data) do
			v[col[1]]:SetText("")
		end
		v.player_data = nil
	end
	-- Hide pagination when clearing (will be shown again if data is available)
	if not skipPageReset then
		if font_container.page_str then font_container.page_str:Hide() end
		if font_container.prev_button then font_container.prev_button:Hide() end
		if font_container.next_button then font_container.next_button:Hide() end
	end
end

-- Display a page from pre-sorted results (used for pagination)
local function displayPageFromCache()
	if not cached_sorted_results then return end
	local ordered = cached_sorted_results
	for i = 1, max_rows do
		local idx = (i + (page_number - 1) * max_rows)
		if idx > #ordered then
			break
		end
		for _, col in ipairs(subtitle_data) do
			local fs = font_strings[i][col[1]]
			local text = col[3](ordered[idx], "")
			fs:SetText(text)
			Deathlog_menuApplyFontForText(fs, text, main_font, 10)
		end
		font_strings[i].player_data = ordered[idx]
		if ordered[idx] and ordered[idx].map_id then
			font_strings[i].map_id = ordered[idx].map_id
		else
			font_strings[i].map_id = nil
		end
		if ordered[idx] and ordered[idx].map_pos then
			local x, y = Deathlog_parseMapPos(ordered[idx].map_pos)
			font_strings[i].map_id_coords_x = x
			font_strings[i].map_id_coords_y = y
		else
			font_strings[i].map_id_coords_x = nil
			font_strings[i].map_id_coords_y = nil
		end
	end

	-- Update pagination visibility
	total_pages = math.max(1, math.ceil(#ordered / max_rows))
	if font_container.page_str then
		if #ordered == 0 or total_pages <= 1 then
			font_container.page_str:Hide()
			if font_container.prev_button then font_container.prev_button:Hide() end
			if font_container.next_button then font_container.next_button:Hide() end
		else
			font_container.page_str:SetText("Page " .. page_number .. " / " .. total_pages)
			font_container.page_str:Show()
			if font_container.prev_button then
				if page_number <= 1 then
					font_container.prev_button:Hide()
				else
					font_container.prev_button:Show()
				end
			end
			if font_container.next_button then
				if page_number >= total_pages then
					font_container.next_button:Hide()
				else
					font_container.next_button:Show()
				end
			end
		end
	end
end

local function setDeathlogMenuLogData(data)
	-- Sort and cache the filtered results. The full result set is sorted via a
	-- single O(n log n) table.sort with a precomputed-date comparator, which
	-- stays within the client's per-frame script limit even on large logs, so no
	-- result cap is needed.
	local ordered = DeathlogOrderByFast(data)
	cached_sorted_results = ordered
	cached_filter_version = cached_filter_version + 1
	
	for i = 1, max_rows do
		local idx = (i + (page_number - 1) * max_rows)
		if idx > #ordered then
			break
		end
		for _, col in ipairs(subtitle_data) do
			local fs = font_strings[i][col[1]]
			local text = col[3](ordered[idx], "")
			fs:SetText(text)
			Deathlog_menuApplyFontForText(fs, text, main_font, 10)
		end
		font_strings[i].player_data = ordered[idx]
		if ordered[idx] and ordered[idx].map_id then
			font_strings[i].map_id = ordered[idx].map_id
		else
			font_strings[i].map_id = nil
		end
		if ordered[idx] and ordered[idx].map_pos then
			local x, y = Deathlog_parseMapPos(ordered[idx].map_pos)
			font_strings[i].map_id_coords_x = x
			font_strings[i].map_id_coords_y = y
		else
			font_strings[i].map_id_coords_x = nil
			font_strings[i].map_id_coords_y = nil
		end
	end

	-- Update pagination visibility based on data
	total_pages = math.max(1, math.ceil(#ordered / max_rows))
	if font_container.page_str then
		if #ordered == 0 or total_pages <= 1 then
			-- Hide pagination entirely if no data or only one page
			font_container.page_str:Hide()
			if font_container.prev_button then font_container.prev_button:Hide() end
			if font_container.next_button then font_container.next_button:Hide() end
		else
			font_container.page_str:SetText("Page " .. page_number .. " / " .. total_pages)
			font_container.page_str:Show()
			-- Show/hide prev button based on current page
			if font_container.prev_button then
				if page_number <= 1 then
					font_container.prev_button:Hide()
				else
					font_container.prev_button:Show()
				end
			end
			-- Show/hide next button based on current page
			if font_container.next_button then
				if page_number >= total_pages then
					font_container.next_button:Hide()
				else
					font_container.next_button:Show()
				end
			end
		end
	end

	local total_str = Deathlog_GetMenuPreprocessedTotal()

	if #ordered == 1 then
		deathlog_menu:SetStatusText(
			#ordered
				.. " search result/"
				.. total_str
				.. " preprocessed"
		)
	else
		deathlog_menu:SetStatusText(
			#ordered
				.. " search results/"
				.. total_str
				.. " preprocessed"
		)
	end
end

local _deathlog_data = {}
local _stats = {}
local _log_normal_params = {}
local _cause_stats = {}
local initialized = false

Deathlog_GetMenuPreprocessedTotal = function()
	local all_cause_stats = _cause_stats and _cause_stats["all"]
	if all_cause_stats then
		local selected_kind = Deathlog_GetMenuSourceKind()
		if selected_kind ~= Deathlog_GetDefaultSourceKind() then
			return all_cause_stats[selected_kind] or 0
		end
		return all_cause_stats.total or 0
	end

	return (DeathlogDataCopy.PRECOMPUTED_GENERAL_STATS and DeathlogDataCopy.PRECOMPUTED_GENERAL_STATS["all"]
		and DeathlogDataCopy.PRECOMPUTED_GENERAL_STATS["all"]["all"]
		and DeathlogDataCopy.PRECOMPUTED_GENERAL_STATS["all"]["all"]["all"]
		and DeathlogDataCopy.PRECOMPUTED_GENERAL_STATS["all"]["all"]["all"]["all"]
		and DeathlogDataCopy.PRECOMPUTED_GENERAL_STATS["all"]["all"]["all"]["all"]["num_entries"]) or "?"
end

local function Deathlog_GetCauseStatsCount(cause_stats_entry)
	if cause_stats_entry == nil then
		return 0
	end

	local selected_kind = Deathlog_GetMenuSourceKind()
	if selected_kind ~= Deathlog_GetDefaultSourceKind() then
		return cause_stats_entry[selected_kind] or 0
	end

	return cause_stats_entry.total or 0
end

local function Deathlog_GetSelectedCauseDescriptor()
	local selected_kind = Deathlog_GetMenuSourceKind()
	if selected_kind ~= Deathlog_GetDefaultSourceKind() then
		return Deathlog_GetSourceKindLabel(selected_kind) .. " deaths"
	end
	return "deaths"
end

local function Deathlog_GetSourceStatsCount(source_id)
	local source_stats = _stats
		and _stats["all"]
		and _stats["all"]["all"]
		and _stats["all"]["all"]["all"]
		and _stats["all"]["all"]["all"][source_id]
	if source_stats == nil then
		return 0
	end

	local selected_kind = Deathlog_GetMenuSourceKind()
	if selected_kind ~= Deathlog_GetDefaultSourceKind() and not Deathlog_SourceMatchesKind(source_id, selected_kind) then
		return 0
	end

	return source_stats["num_entries"] or 0
end

local function refreshMenuSearchResults(skipPageReset)
	clearDeathlogMenuLogData(skipPageReset)
	local active_filter = _get_active_filter and _get_active_filter()
	if active_filter and (_get_filters_active and _get_filters_active()) then
		setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, active_filter))
	else
		setDeathlogMenuLogData(_deathlog_data)
	end
end

-- Lets moderation actions in utils.lua repaint the log without a reload.
function Deathlog_menuRefreshSearchResults()
	if not (deathlog_menu and deathlog_menu:IsShown()) then return end
	if not _deathlog_data then return end
	refreshMenuSearchResults(true)
end

local function drawLogTab(container)
	local scroll_container = AceGUI:Create("SimpleGroup") ---@type AceGUISimpleGroup
	scroll_container:SetFullWidth(true)
	scroll_container:SetFullHeight(true)
	scroll_container:SetLayout("Fill")
	deathlog_tabcontainer:AddChild(scroll_container)

	local scroll_frame = AceGUI:Create("SimpleGroup") ---@type AceGUISimpleGroup
	scroll_frame:SetLayout("Flow")
	scroll_container:AddChild(scroll_frame)

	local server_filter = nil
	local name_filter = nil
	local class_filter = nil
	local race_filter = nil
	local zone_filter = nil
	local guild_filter = nil
	local min_level_filter = nil
	local max_level_filter = nil
	local death_source_filter = nil
	local last_words_filter = nil
	local death_filter_mode = deathlog_settings["search_log_filter_mode"] or "all"
	if not DeathNotificationLib.GetGuildFilterModeOptions(true)[death_filter_mode] then
		death_filter_mode = "all"
	end
	local filter = function(server_name, _entry)
		if server_filter ~= nil then
			if server_filter(server_name, _entry) == false then
				return false
			end
		end
		if name_filter ~= nil then
			if name_filter(server_name, _entry) == false then
				return false
			end
		end
		if min_level_filter ~= nil then
			if min_level_filter(server_name, _entry) == false then
				return false
			end
		end
		if max_level_filter ~= nil then
			if max_level_filter(server_name, _entry) == false then
				return false
			end
		end
		if death_source_filter ~= nil then
			if death_source_filter(server_name, _entry) == false then
				return false
			end
		end
		if
			Deathlog_GetMenuSourceKind() ~= Deathlog_GetDefaultSourceKind()
			and not Deathlog_SourceMatchesKind(_entry, Deathlog_GetMenuSourceKind())
		then
			return false
		end
		if class_filter ~= nil then
			if class_filter(server_name, _entry) == false then
				return false
			end
		end
		if race_filter ~= nil then
			if race_filter(server_name, _entry) == false then
				return false
			end
		end
		if zone_filter ~= nil then
			if zone_filter(server_name, _entry) == false then
				return false
			end
		end
		if guild_filter ~= nil then
			if guild_filter(server_name, _entry) == false then
				return false
			end
		end
		if last_words_filter ~= nil then
			if last_words_filter(server_name, _entry) == false then
				return false
			end
		end
		if death_filter_mode ~= "all" then
			if not DeathNotificationLib.PassesGuildFilterMode(_entry, death_filter_mode) then
				return false
			end
		end
		return true
	end

	-- Expose a function that checks if any filter is currently active (used by auto-refresh)
	_get_filters_active = function()
		return server_filter ~= nil or name_filter ~= nil or class_filter ~= nil
			or race_filter ~= nil or zone_filter ~= nil or guild_filter ~= nil
			or min_level_filter ~= nil or max_level_filter ~= nil
			or death_source_filter ~= nil or last_words_filter ~= nil
			or Deathlog_GetMenuSourceKind() ~= Deathlog_GetDefaultSourceKind()
			or death_filter_mode ~= "all"
	end
	_get_active_filter = function() return filter end

	local class_search_box = AceGUI:Create("Icon") ---@type AceGUIIcon
	class_search_box:SetWidth(50)
	class_search_box:SetHeight(50)
	class_search_box:SetDisabled(true)
	scroll_frame:AddChild(class_search_box)

	--- Server dropdown
	if font_container.server_dd == nil then
		font_container.server_dd = CreateFrame("Frame", nil, font_container, "UIDropDownMenuTemplate")
		font_container.server_dd.val = ""
	end

	local function serverDD(frame, level, menuList)
		local function setFilter()
			local key = font_container.server_dd.val
			if key ~= "" then
				server_filter = function(server_name, _entry)
					if server_name == key then
						return true
					else
						return false
					end
				end
				clearDeathlogMenuLogData()
				setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
			else
				server_filter = nil
				clearDeathlogMenuLogData()
				setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
			end
		end

		local entries = { { name = "All", value = "" } }
		local added_servers = {}
		local current_realm = GetRealmName()
		if current_realm and current_realm ~= "" then
			table.insert(entries, { name = current_realm, value = current_realm })
			added_servers[current_realm] = true
		end
		for server_name, _ in pairs(_deathlog_data) do
			if not added_servers[server_name] then
				table.insert(entries, { name = server_name, value = server_name })
				added_servers[server_name] = true
			end
		end

		for _, entry in ipairs(entries) do
			local info = UIDropDownMenu_CreateInfo()
			info.text = entry.name
			info.checked = font_container.server_dd.val == entry.value
			info.func = function()
				font_container.server_dd.val = entry.value
				UIDropDownMenu_SetText(font_container.server_dd, entry.name)
				setFilter()
			end
			UIDropDownMenu_AddButton(info)
		end
	end

	font_container.server_dd:SetPoint("TOPLEFT", scroll_container.frame, "TOPLEFT", -5, -20)
	UIDropDownMenu_SetText(font_container.server_dd, font_container.server_dd.val ~= "" and font_container.server_dd.val or "All")
	UIDropDownMenu_SetWidth(font_container.server_dd, 80)
	UIDropDownMenu_Initialize(font_container.server_dd, serverDD)
	UIDropDownMenu_JustifyText(font_container.server_dd, "LEFT")

	if font_container.server_dd.text == nil then
		font_container.server_dd.text = font_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	end

	font_container.server_dd.text:SetPoint("LEFT", font_container.server_dd, "LEFT", 20, 20)
	font_container.server_dd.text:SetFont(Deathlog_L.menu_font, 12, "")
	font_container.server_dd.text:SetTextColor(255 / 255, 215 / 255, 0)
	font_container.server_dd.text:SetText("Server")
	font_container.server_dd.text:Show()

	--- Race dropdown
	if font_container.race_dd == nil then
		font_container.race_dd = CreateFrame("Frame", nil, font_container, "UIDropDownMenuTemplate")
		font_container.race_dd.val = ""
	end

	local function raceDD(frame, level, menuList)
		local function setFilter()
			local key = font_container.race_dd.val
			if key ~= "" then
				race_filter = function(_, _entry)
					if race_tbl[key] == tonumber(_entry["race_id"]) then
						return true
					else
						return false
					end
				end
				clearDeathlogMenuLogData()
				setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
			else
				race_filter = nil
				clearDeathlogMenuLogData()
				setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
			end
		end

		local entries = { { name = "All", value = "" } }
		for race_name, _ in pairs(race_tbl) do
			table.insert(entries, { name = race_name, value = race_name })
		end

		for _, entry in ipairs(entries) do
			local info = UIDropDownMenu_CreateInfo()
			info.text = entry.name
			info.checked = font_container.race_dd.val == entry.value
			info.func = function()
				font_container.race_dd.val = entry.value
				UIDropDownMenu_SetText(font_container.race_dd, entry.name)
				setFilter()
			end
			UIDropDownMenu_AddButton(info)
		end
	end

	font_container.race_dd:SetPoint("TOPLEFT", scroll_container.frame, "TOPLEFT", 90, -20)
	UIDropDownMenu_SetText(font_container.race_dd, font_container.race_dd.val ~= "" and font_container.race_dd.val or "All")
	UIDropDownMenu_SetWidth(font_container.race_dd, 80)
	UIDropDownMenu_Initialize(font_container.race_dd, raceDD)
	UIDropDownMenu_JustifyText(font_container.race_dd, "LEFT")

	if font_container.race_dd.text == nil then
		font_container.race_dd.text = font_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	end

	font_container.race_dd.text:SetPoint("LEFT", font_container.race_dd, "LEFT", 20, 20)
	font_container.race_dd.text:SetFont(Deathlog_L.menu_font, 12, "")
	font_container.race_dd.text:SetTextColor(255 / 255, 215 / 255, 0)
	font_container.race_dd.text:SetText("Race")
	font_container.race_dd.text:Show()

	--- Race dropdown
	if font_container.class_dd == nil then
		font_container.class_dd = CreateFrame("Frame", nil, font_container, "UIDropDownMenuTemplate")
		font_container.class_dd.val = ""
	end

	local function classDD(frame, level, menuList)
		local function setFilter()
			local key = font_container.class_dd.val
			if key ~= "" then
				class_filter = function(_, _entry)
					if class_tbl[key] == tonumber(_entry["class_id"]) then
						return true
					else
						return false
					end
				end
				clearDeathlogMenuLogData()
				setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
			else
				class_filter = nil
				clearDeathlogMenuLogData()
				setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
			end
		end

		local entries = { { name = "All", value = "" } }
		for class_name, _ in pairs(class_tbl) do
			table.insert(entries, { name = class_name, value = class_name })
		end

		for _, entry in ipairs(entries) do
			local info = UIDropDownMenu_CreateInfo()
			info.text = entry.name
			info.checked = font_container.class_dd.val == entry.value
			info.func = function()
				font_container.class_dd.val = entry.value
				UIDropDownMenu_SetText(font_container.class_dd, entry.name)
				setFilter()
			end
			UIDropDownMenu_AddButton(info)
		end
	end

	font_container.class_dd:SetPoint("TOPLEFT", scroll_container.frame, "TOPLEFT", 185, -20)
	UIDropDownMenu_SetText(font_container.class_dd, font_container.class_dd.val ~= "" and font_container.class_dd.val or "All")
	UIDropDownMenu_SetWidth(font_container.class_dd, 80)
	UIDropDownMenu_Initialize(font_container.class_dd, classDD)
	UIDropDownMenu_JustifyText(font_container.class_dd, "LEFT")

	if font_container.class_dd.text == nil then
		font_container.class_dd.text = font_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	end

	font_container.class_dd.text:SetPoint("LEFT", font_container.class_dd, "LEFT", 20, 20)
	font_container.class_dd.text:SetFont(Deathlog_L.menu_font, 12, "")
	font_container.class_dd.text:SetTextColor(255 / 255, 215 / 255, 0)
	font_container.class_dd.text:SetText("Class")
	font_container.class_dd.text:Show()

	--- Zone dropdown
	if font_container.zone_dd == nil then
		font_container.zone_dd = CreateFrame("Frame", nil, font_container, "UIDropDownMenuTemplate")
		font_container.zone_dd.val = ""
	end

	-- Helper: get zone IDs from a category that exist in a specific expansion
	local function getZoneCategoryForExpansion(category_name, expansion_id)
		local category_ids = zone_categories and zone_categories[category_name]
		if not category_ids then return {} end
		
		local expansion_zones = zone_to_id[expansion_id]
		if not expansion_zones then return {} end
		
		-- Build reverse lookup: zone_id -> true for this expansion
		local expansion_zone_ids = {}
		for _, zone_id in pairs(expansion_zones) do
			expansion_zone_ids[zone_id] = true
		end
		
		-- Filter category IDs to only those in this expansion
		local filtered = {}
		for _, zone_id in ipairs(category_ids) do
			if expansion_zone_ids[zone_id] then
				table.insert(filtered, zone_id)
			end
		end
		return filtered
	end

	local function zoneDD(frame, level, menuList)
		local function setFilter()
			local key = font_container.zone_dd.val
			if key ~= "" then
				zone_filter = function(_, _entry)
					-- Look up zone in all expansions
					for _, zones in pairs(zone_to_id) do
						if zones[key] and zones[key] == tonumber(_entry["map_id"]) then
							return true
						end
					end
					-- Look up instance in all expansions
					for _, instances in pairs(instance_to_id) do
						if instances[key] and instances[key] == tonumber(_entry["instance_id"]) then
							return true
						end
					end
					return false
				end
				clearDeathlogMenuLogData()
				setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
			else
				zone_filter = nil
				clearDeathlogMenuLogData()
				setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
			end
		end

		-- Count how many expansions we have for zones
		local zone_expansion_count = 0
		local single_zone_expansion_id = nil
		for expansion_id, _ in pairs(zone_to_id) do
			zone_expansion_count = zone_expansion_count + 1
			single_zone_expansion_id = expansion_id
		end
		local skip_zone_expansion_layer = (zone_expansion_count == 1)

		if level == 1 or level == nil then
			-- "All" option at top level
			local info = UIDropDownMenu_CreateInfo()
			info.text = "All"
			info.checked = font_container.zone_dd.val == ""
			info.func = function()
				font_container.zone_dd.val = ""
				UIDropDownMenu_SetText(font_container.zone_dd, "All")
				setFilter()
			end
			UIDropDownMenu_AddButton(info, level)

			if skip_zone_expansion_layer then
				-- Only one expansion: show continent submenus directly at level 1
				if zone_categories then
					local sorted_categories = {}
					for category_name, _ in pairs(zone_categories) do
						local filtered_zones = getZoneCategoryForExpansion(category_name, single_zone_expansion_id)
						if #filtered_zones > 0 then
							table.insert(sorted_categories, { name = category_name, zones = filtered_zones })
						end
					end
					table.sort(sorted_categories, function(a, b) return a.name < b.name end)

					for _, category in ipairs(sorted_categories) do
						local info = UIDropDownMenu_CreateInfo()
						info.text = category.name
						info.hasArrow = true
						info.notCheckable = true
						info.menuList = { type = "continent", expansion_id = single_zone_expansion_id, category_name = category.name, zones = category.zones }
						UIDropDownMenu_AddButton(info, level)
					end
				else
					-- No categories: show all zones directly
					local zones = zone_to_id[single_zone_expansion_id]
					if zones then
						local sorted_zones = {}
						for zone_name, zone_id in pairs(zones) do
							table.insert(sorted_zones, { name = zone_name, id = zone_id })
						end
						table.sort(sorted_zones, function(a, b) return a.name < b.name end)
						for _, zone in ipairs(sorted_zones) do
							local info = UIDropDownMenu_CreateInfo()
							info.text = zone.name
							info.checked = font_container.zone_dd.val == zone.name
							info.func = function()
								font_container.zone_dd.val = zone.name
								UIDropDownMenu_SetText(font_container.zone_dd, font_container.zone_dd.val)
								setFilter()
								CloseDropDownMenus()
							end
							UIDropDownMenu_AddButton(info, level)
						end
					end
				end
			else
				-- Multiple expansions: show expansion submenus (sorted by expansion_id)
				local sorted_expansion_ids = {}
				for expansion_id, _ in pairs(zone_to_id) do
					table.insert(sorted_expansion_ids, expansion_id)
				end
				table.sort(sorted_expansion_ids)
				for _, expansion_id in ipairs(sorted_expansion_ids) do
					local info = UIDropDownMenu_CreateInfo()
					info.text = _G["EXPANSION_NAME" .. expansion_id]
					info.hasArrow = true
					info.notCheckable = true
					info.menuList = { type = "expansion", id = expansion_id }
					UIDropDownMenu_AddButton(info, level)
				end
			end
		elseif level == 2 then
			local menu_type = menuList and menuList.type

			if menu_type == "continent" then
				-- Coming from either: single-expansion level 1, or multi-expansion level 2
				-- Show individual zones for selected continent/category
				local category_zones = menuList.zones
				local expansion_id = menuList.expansion_id
				if category_zones and expansion_id then
					local zones = zone_to_id[expansion_id]
					if zones then
						local category_zone_ids = {}
						for _, zone_id in ipairs(category_zones) do
							category_zone_ids[zone_id] = true
						end
						local sorted_zones = {}
						for zone_name, zone_id in pairs(zones) do
							if category_zone_ids[zone_id] then
								table.insert(sorted_zones, { name = zone_name, id = zone_id })
							end
						end
						table.sort(sorted_zones, function(a, b) return a.name < b.name end)
						for _, zone in ipairs(sorted_zones) do
							local info = UIDropDownMenu_CreateInfo()
							info.text = zone.name
							info.checked = font_container.zone_dd.val == zone.name
							info.func = function()
								font_container.zone_dd.val = zone.name
								UIDropDownMenu_SetText(font_container.zone_dd, font_container.zone_dd.val)
								setFilter()
								CloseDropDownMenus()
							end
							UIDropDownMenu_AddButton(info, level)
						end
					end
				end
			elseif menu_type == "expansion" then
				-- Multi-expansion path: show continent submenus
				local expansion_id = menuList.id
				if zone_categories then
					local sorted_categories = {}
					for category_name, _ in pairs(zone_categories) do
						local filtered_zones = getZoneCategoryForExpansion(category_name, expansion_id)
						if #filtered_zones > 0 then
							table.insert(sorted_categories, { name = category_name, zones = filtered_zones })
						end
					end
					table.sort(sorted_categories, function(a, b) return a.name < b.name end)
					
					for _, category in ipairs(sorted_categories) do
						local info = UIDropDownMenu_CreateInfo()
						info.text = category.name
						info.hasArrow = true
						info.notCheckable = true
						info.menuList = { type = "continent", expansion_id = expansion_id, category_name = category.name, zones = category.zones }
						UIDropDownMenu_AddButton(info, level)
					end
				end
			
				-- Fallback if no categories or empty: show all zones directly
				if not zone_categories then
					local zones = zone_to_id[expansion_id]
					if zones then
						local sorted_zones = {}
						for zone_name, zone_id in pairs(zones) do
							table.insert(sorted_zones, { name = zone_name, id = zone_id })
						end
						table.sort(sorted_zones, function(a, b) return a.name < b.name end)
						for _, zone in ipairs(sorted_zones) do
							local info = UIDropDownMenu_CreateInfo()
							info.text = zone.name
							info.checked = font_container.zone_dd.val == zone.name
							info.func = function()
								font_container.zone_dd.val = zone.name
								UIDropDownMenu_SetText(font_container.zone_dd, font_container.zone_dd.val)
								setFilter()
								CloseDropDownMenus()
							end
							UIDropDownMenu_AddButton(info, level)
						end
					end
				end
			end
		elseif level == 3 then
			-- Zones for selected continent/category (multi-expansion path only)
			local category_zones = menuList and menuList.zones
			local expansion_id = menuList and menuList.expansion_id
			if category_zones and expansion_id then
				local zones = zone_to_id[expansion_id]
				if zones then
					-- Build lookup of zone IDs in this category
					local category_zone_ids = {}
					for _, zone_id in ipairs(category_zones) do
						category_zone_ids[zone_id] = true
					end
					-- Collect zones that belong to this category
					local sorted_zones = {}
					for zone_name, zone_id in pairs(zones) do
						if category_zone_ids[zone_id] then
							table.insert(sorted_zones, { name = zone_name, id = zone_id })
						end
					end
					table.sort(sorted_zones, function(a, b) return a.name < b.name end)
					for _, zone in ipairs(sorted_zones) do
						local info = UIDropDownMenu_CreateInfo()
						info.text = zone.name
						info.checked = font_container.zone_dd.val == zone.name
						info.func = function()
							font_container.zone_dd.val = zone.name
							UIDropDownMenu_SetText(font_container.zone_dd, font_container.zone_dd.val)
							setFilter()
							CloseDropDownMenus()
						end
						UIDropDownMenu_AddButton(info, level)
					end
				end
			end
		end
	end

	font_container.zone_dd:SetPoint("TOPLEFT", scroll_container.frame, "TOPLEFT", 280, -20)
	UIDropDownMenu_SetText(font_container.zone_dd, font_container.zone_dd.val ~= "" and font_container.zone_dd.val or "All")
	UIDropDownMenu_SetWidth(font_container.zone_dd, 80)
	UIDropDownMenu_Initialize(font_container.zone_dd, zoneDD)
	UIDropDownMenu_JustifyText(font_container.zone_dd, "LEFT")

	if font_container.zone_dd.text == nil then
		font_container.zone_dd.text = font_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	end

	font_container.zone_dd.text:SetPoint("LEFT", font_container.zone_dd, "LEFT", 20, 20)
	font_container.zone_dd.text:SetFont(Deathlog_L.menu_font, 12, "")
	font_container.zone_dd.text:SetTextColor(255 / 255, 215 / 255, 0)
	font_container.zone_dd.text:SetText("Zone")
	font_container.zone_dd.text:Show()

	--- Instance dropdown
	if font_container.instance_dd == nil then
		font_container.instance_dd = CreateFrame("Frame", nil, font_container, "UIDropDownMenuTemplate")
		font_container.instance_dd.val = ""
	end

	-- Helper: get instance IDs from a category that exist in a specific expansion
	local function getInstanceCategoryForExpansion(category_name, expansion_id)
		local category_ids = instance_categories and instance_categories[category_name]
		if not category_ids then return {} end
		
		local expansion_instances = instance_to_id[expansion_id]
		if not expansion_instances then return {} end
		
		-- Build reverse lookup: instance_id -> true for this expansion
		local expansion_instance_ids = {}
		for _, instance_id in pairs(expansion_instances) do
			expansion_instance_ids[instance_id] = true
		end
		
		-- Filter category IDs to only those in this expansion
		local filtered = {}
		for _, instance_id in ipairs(category_ids) do
			if expansion_instance_ids[instance_id] then
				table.insert(filtered, instance_id)
			end
		end
		return filtered
	end

	local function instanceDD(frame, level, menuList)
		local function setFilter()
			local key = font_container.instance_dd.val
			if key ~= "" then
				zone_filter = function(_, _entry)
					-- Look up zone in all expansions
					for _, zones in pairs(zone_to_id) do
						if zones[key] and zones[key] == tonumber(_entry["map_id"]) then
							return true
						end
					end
					-- Look up instance in all expansions
					for _, instances in pairs(instance_to_id) do
						if instances[key] and instances[key] == tonumber(_entry["instance_id"]) then
							return true
						end
					end
					return false
				end
				clearDeathlogMenuLogData()
				setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
			else
				zone_filter = nil
				clearDeathlogMenuLogData()
				setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
			end
		end

		-- Count how many expansions we have
		local expansion_count = 0
		local single_expansion_id = nil
		for expansion_id, _ in pairs(instance_to_id) do
			expansion_count = expansion_count + 1
			single_expansion_id = expansion_id
		end
		local skip_expansion_layer = (expansion_count == 1)

		if level == 1 or level == nil then
			-- "All" option at top level
			local info = UIDropDownMenu_CreateInfo()
			info.text = "All"
			info.checked = font_container.instance_dd.val == ""
			info.func = function()
				font_container.instance_dd.val = ""
				UIDropDownMenu_SetText(font_container.instance_dd, "All")
				setFilter()
			end
			UIDropDownMenu_AddButton(info, level)

			if skip_expansion_layer then
				-- Only one expansion: show instance types directly at level 1
				if instance_categories then
					local category_order = { "Dungeon", "Raid", "Battleground", "Arena" }
					for _, category_name in ipairs(category_order) do
						local filtered_instances = getInstanceCategoryForExpansion(category_name, single_expansion_id)
						if #filtered_instances > 0 then
							local info = UIDropDownMenu_CreateInfo()
							info.text = category_name
							info.hasArrow = true
							info.notCheckable = true
							info.menuList = { type = "instance_type", expansion_id = single_expansion_id, category_name = category_name, instances = filtered_instances }
							UIDropDownMenu_AddButton(info, level)
						end
					end
				else
					-- No categories: show all instances directly
					local instances = instance_to_id[single_expansion_id]
					if instances then
						local sorted_instances = {}
						for instance_name, instance_id in pairs(instances) do
							table.insert(sorted_instances, { name = instance_name, id = instance_id })
						end
						table.sort(sorted_instances, function(a, b) return a.name < b.name end)
						for _, instance in ipairs(sorted_instances) do
							local info = UIDropDownMenu_CreateInfo()
							info.text = instance.name
							info.checked = font_container.instance_dd.val == instance.name
							info.func = function()
								font_container.instance_dd.val = instance.name
								UIDropDownMenu_SetText(font_container.instance_dd, font_container.instance_dd.val)
								setFilter()
								CloseDropDownMenus()
							end
							UIDropDownMenu_AddButton(info, level)
						end
					end
				end
			else
				-- Multiple expansions: show expansion submenus (sorted by expansion_id)
				local sorted_expansion_ids = {}
				for expansion_id, _ in pairs(instance_to_id) do
					table.insert(sorted_expansion_ids, expansion_id)
				end
				table.sort(sorted_expansion_ids)
				for _, expansion_id in ipairs(sorted_expansion_ids) do
					local info = UIDropDownMenu_CreateInfo()
					info.text = _G["EXPANSION_NAME" .. expansion_id]
					info.hasArrow = true
					info.notCheckable = true
					info.menuList = { type = "expansion", id = expansion_id }
					UIDropDownMenu_AddButton(info, level)
				end
			end
		elseif level == 2 then
			local menu_type = menuList and menuList.type

			if menu_type == "instance_type" then
				-- Coming from either: single-expansion level 1, or multi-expansion level 2
				-- Show individual instances for selected type/category
				local category_instances = menuList.instances
				local expansion_id = menuList.expansion_id
				if category_instances and expansion_id then
					local instances = instance_to_id[expansion_id]
					if instances then
						local category_instance_ids = {}
						for _, inst_id in ipairs(category_instances) do
							category_instance_ids[inst_id] = true
						end
						local sorted_instances = {}
						for instance_name, instance_id in pairs(instances) do
							if category_instance_ids[instance_id] then
								table.insert(sorted_instances, { name = instance_name, id = instance_id })
							end
						end
						table.sort(sorted_instances, function(a, b) return a.name < b.name end)
						for _, instance in ipairs(sorted_instances) do
							local info = UIDropDownMenu_CreateInfo()
							info.text = instance.name
							info.checked = font_container.instance_dd.val == instance.name
							info.func = function()
								font_container.instance_dd.val = instance.name
								UIDropDownMenu_SetText(font_container.instance_dd, font_container.instance_dd.val)
								setFilter()
								CloseDropDownMenus()
							end
							UIDropDownMenu_AddButton(info, level)
						end
					end
				end
			elseif menu_type == "expansion" then
				-- Multi-expansion path: show instance type submenus
				local expansion_id = menuList.id
				if instance_categories then
					local category_order = { "Dungeon", "Raid", "Battleground", "Arena" }
					for _, category_name in ipairs(category_order) do
						local filtered_instances = getInstanceCategoryForExpansion(category_name, expansion_id)
						if #filtered_instances > 0 then
							local info = UIDropDownMenu_CreateInfo()
							info.text = category_name
							info.hasArrow = true
							info.notCheckable = true
							info.menuList = { type = "instance_type", expansion_id = expansion_id, category_name = category_name, instances = filtered_instances }
							UIDropDownMenu_AddButton(info, level)
						end
					end
				end

				-- Fallback if no categories: show all instances directly
				if not instance_categories then
					local instances = instance_to_id[expansion_id]
					if instances then
						local sorted_instances = {}
						for instance_name, instance_id in pairs(instances) do
							table.insert(sorted_instances, { name = instance_name, id = instance_id })
						end
						table.sort(sorted_instances, function(a, b) return a.name < b.name end)
						for _, instance in ipairs(sorted_instances) do
							local info = UIDropDownMenu_CreateInfo()
							info.text = instance.name
							info.checked = font_container.instance_dd.val == instance.name
							info.func = function()
								font_container.instance_dd.val = instance.name
								UIDropDownMenu_SetText(font_container.instance_dd, font_container.instance_dd.val)
								setFilter()
								CloseDropDownMenus()
							end
							UIDropDownMenu_AddButton(info, level)
						end
					end
				end
			end
		elseif level == 3 then
			-- Instances for selected type/category
			local category_instances = menuList and menuList.instances
			local expansion_id = menuList and menuList.expansion_id
			if category_instances and expansion_id then
				local instances = instance_to_id[expansion_id]
				if instances then
					-- Build lookup of instance IDs in this category
					local category_instance_ids = {}
					for _, inst_id in ipairs(category_instances) do
						category_instance_ids[inst_id] = true
					end
					-- Collect instances that belong to this category
					local sorted_instances = {}
					for instance_name, instance_id in pairs(instances) do
						if category_instance_ids[instance_id] then
							table.insert(sorted_instances, { name = instance_name, id = instance_id })
						end
					end
					table.sort(sorted_instances, function(a, b) return a.name < b.name end)
					for _, instance in ipairs(sorted_instances) do
						local info = UIDropDownMenu_CreateInfo()
						info.text = instance.name
						info.checked = font_container.instance_dd.val == instance.name
						info.func = function()
							font_container.instance_dd.val = instance.name
							UIDropDownMenu_SetText(font_container.instance_dd, font_container.instance_dd.val)
							setFilter()
							CloseDropDownMenus()
						end
						UIDropDownMenu_AddButton(info, level)
					end
				end
			end
		end
	end

	font_container.instance_dd:SetPoint("TOPLEFT", scroll_container.frame, "TOPLEFT", 375, -20)
	UIDropDownMenu_SetText(font_container.instance_dd, font_container.instance_dd.val ~= "" and font_container.instance_dd.val or "All")
	UIDropDownMenu_SetWidth(font_container.instance_dd, 80)
	UIDropDownMenu_Initialize(font_container.instance_dd, instanceDD)
	UIDropDownMenu_JustifyText(font_container.instance_dd, "LEFT")

	if font_container.instance_dd.text == nil then
		font_container.instance_dd.text = font_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	end

	font_container.instance_dd.text:SetPoint("LEFT", font_container.instance_dd, "LEFT", 20, 20)
	font_container.instance_dd.text:SetFont(Deathlog_L.menu_font, 12, "")
	font_container.instance_dd.text:SetTextColor(255 / 255, 215 / 255, 0)
	font_container.instance_dd.text:SetText("Instance")
	font_container.instance_dd.text:Show()

	-- Min lvl search
	if font_container.min_level_box == nil then
		font_container.min_level_box = CreateFrame("EditBox", nil, font_container, "InputBoxTemplate")
	end
	if font_container.min_level_box.text == nil then
		font_container.min_level_box.text = font_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	end
	font_container.min_level_box:SetPoint("TOPLEFT", font_container.instance_dd, "TOPRIGHT", 0, 0)
	font_container.min_level_box:SetPoint("BOTTOMLEFT", font_container.instance_dd, "TOPRIGHT", 0, -30)
	font_container.min_level_box:SetWidth(50)
	font_container.min_level_box:SetFont(Deathlog_L.menu_font, 14, "")
	font_container.min_level_box:SetMovable(false)
	font_container.min_level_box:SetBlinkSpeed(1)
	font_container.min_level_box:SetAutoFocus(false)
	font_container.min_level_box:SetMultiLine(false)
	font_container.min_level_box:SetMaxLetters(20)
	font_container.min_level_box:SetScript("OnEnterPressed", function()
		local text = font_container.min_level_box:GetText()
		if #text > 0 then
			min_level_filter = function(_, _entry)
				if _entry["level"] and tonumber(text) ~= nil and _entry["level"] >= tonumber(text) then
					return true
				end
				return false
			end
			clearDeathlogMenuLogData()
			setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
		else
			min_level_filter = nil
			clearDeathlogMenuLogData()
			setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
		end
	end)

	font_container.min_level_box.text:SetPoint("LEFT", font_container.min_level_box, "LEFT", 0, 15)
	font_container.min_level_box.text:SetFont(Deathlog_L.menu_font, 12, "")
	font_container.min_level_box.text:SetTextColor(255 / 255, 215 / 255, 0)
	font_container.min_level_box.text:SetText("Min. Lvl")
	font_container.min_level_box.text:Show()

	-- Max lvl search
	if font_container.max_level_box == nil then
		font_container.max_level_box = CreateFrame("EditBox", nil, font_container, "InputBoxTemplate")
	end
	if font_container.max_level_box.text == nil then
		font_container.max_level_box.text = font_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	end
	font_container.max_level_box:SetPoint("TOPLEFT", font_container.min_level_box, "TOPRIGHT", 5, 0)
	font_container.max_level_box:SetPoint("BOTTOMLEFT", font_container.min_level_box, "TOPRIGHT", 5, -30)
	font_container.max_level_box:SetWidth(50)
	font_container.max_level_box:SetFont(Deathlog_L.menu_font, 14, "")
	font_container.max_level_box:SetMovable(false)
	font_container.max_level_box:SetBlinkSpeed(1)
	font_container.max_level_box:SetAutoFocus(false)
	font_container.max_level_box:SetMultiLine(false)
	font_container.max_level_box:SetMaxLetters(20)
	font_container.max_level_box:SetScript("OnEnterPressed", function()
		local text = font_container.max_level_box:GetText()
		if #text > 0 then
			max_level_filter = function(_, _entry)
				if _entry["level"] and tonumber(text) ~= nil and _entry["level"] <= tonumber(text) then
					return true
				end
				return false
			end
			clearDeathlogMenuLogData()
			setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
		else
			max_level_filter = nil
			clearDeathlogMenuLogData()
			setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
		end
	end)

	font_container.max_level_box.text:SetPoint("LEFT", font_container.max_level_box, "LEFT", 0, 15)
	font_container.max_level_box.text:SetFont(Deathlog_L.menu_font, 12, "")
	font_container.max_level_box.text:SetTextColor(255 / 255, 215 / 255, 0)
	font_container.max_level_box.text:SetText("Max. Lvl")
	font_container.max_level_box.text:Show()

	-- Player search
	if font_container.player_search_box == nil then
		font_container.player_search_box = CreateFrame("EditBox", nil, font_container, "InputBoxTemplate")
	end
	if font_container.player_search_box.text == nil then
		font_container.player_search_box.text = font_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	end
	font_container.player_search_box:SetPoint("TOPLEFT", font_container.max_level_box, "TOPRIGHT", 5, 0)
	font_container.player_search_box:SetPoint("BOTTOMLEFT", font_container.max_level_box, "TOPRIGHT", 5, -30)
	font_container.player_search_box:SetWidth(100)
	font_container.player_search_box:SetFont(Deathlog_L.menu_font, 14, "")
	font_container.player_search_box:SetMovable(false)
	font_container.player_search_box:SetBlinkSpeed(1)
	font_container.player_search_box:SetAutoFocus(false)
	font_container.player_search_box:SetMultiLine(false)
	font_container.player_search_box:SetMaxLetters(20)
	font_container.player_search_box:SetScript("OnEnterPressed", function()
		local text = font_container.player_search_box:GetText()
		if #text > 0 then
			name_filter = function(_, _entry)
				if string.find(string.lower(_entry["name"] or ""), string.lower(text)) then
					return true
				else
					return false
				end
			end
			clearDeathlogMenuLogData()
			setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
		else
			name_filter = nil
			clearDeathlogMenuLogData()
			setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
		end
	end)

	font_container.player_search_box.text:SetPoint("LEFT", font_container.player_search_box, "LEFT", 0, 15)
	font_container.player_search_box.text:SetFont(Deathlog_L.menu_font, 12, "")
	font_container.player_search_box.text:SetTextColor(255 / 255, 215 / 255, 0)
	font_container.player_search_box.text:SetText("Player Name")
	font_container.player_search_box.text:Show()

	-- guild search
	if font_container.guild_search_box == nil then
		font_container.guild_search_box = CreateFrame("EditBox", nil, font_container, "InputBoxTemplate")
	end
	if font_container.guild_search_box.text == nil then
		font_container.guild_search_box.text = font_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	end
	font_container.guild_search_box:SetPoint("TOPLEFT", font_container.player_search_box, "TOPRIGHT", 5, 0)
	font_container.guild_search_box:SetPoint("BOTTOMLEFT", font_container.player_search_box, "TOPRIGHT", 5, -30)
	font_container.guild_search_box:SetWidth(100)
	font_container.guild_search_box:SetFont(Deathlog_L.menu_font, 14, "")
	font_container.guild_search_box:SetMovable(false)
	font_container.guild_search_box:SetBlinkSpeed(1)
	font_container.guild_search_box:SetAutoFocus(false)
	font_container.guild_search_box:SetMultiLine(false)
	font_container.guild_search_box:SetMaxLetters(20)
	font_container.guild_search_box:SetScript("OnEnterPressed", function()
		local text = font_container.guild_search_box:GetText()
		if #text > 0 then
			guild_filter = function(_, _entry)
				if string.find(string.lower(_entry["guild"] or ""), string.lower(text)) then
					return true
				else
					return false
				end
			end
			clearDeathlogMenuLogData()
			setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
		else
			guild_filter = nil
			clearDeathlogMenuLogData()
			setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
		end
	end)

	font_container.guild_search_box.text:SetPoint("LEFT", font_container.guild_search_box, "LEFT", 0, 15)
	font_container.guild_search_box.text:SetFont(Deathlog_L.menu_font, 12, "")
	font_container.guild_search_box.text:SetTextColor(255 / 255, 215 / 255, 0)
	font_container.guild_search_box.text:SetText("Guild Name")
	font_container.guild_search_box.text:Show()

	-- source search
	if font_container.death_source_box == nil then
		font_container.death_source_box = CreateFrame("EditBox", nil, font_container, "InputBoxTemplate")
	end
	if font_container.death_source_box.text == nil then
		font_container.death_source_box.text = font_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	end
	font_container.death_source_box:SetPoint("TOPLEFT", font_container.guild_search_box, "TOPRIGHT", 5, 0)
	font_container.death_source_box:SetPoint("BOTTOMLEFT", font_container.guild_search_box, "TOPRIGHT", 5, -30)
	font_container.death_source_box:SetWidth(100)
	font_container.death_source_box:SetFont(Deathlog_L.menu_font, 14, "")
	font_container.death_source_box:SetMovable(false)
	font_container.death_source_box:SetBlinkSpeed(1)
	font_container.death_source_box:SetAutoFocus(false)
	font_container.death_source_box:SetMultiLine(false)
	font_container.death_source_box:SetMaxLetters(20)
	font_container.death_source_box:SetScript("OnEnterPressed", function()
		local text = font_container.death_source_box:GetText()
		if #text > 0 then
			death_source_filter = function(_, _entry)
				local source = DeathlogGetCachedSource(_entry)
				if source ~= "" and string.find(string.lower(source), string.lower(text)) then
					return true
				else
					return false
				end
			end
			clearDeathlogMenuLogData()
			setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
		else
			death_source_filter = nil
			clearDeathlogMenuLogData()
			setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
		end
	end)

	font_container.death_source_box.text:SetPoint("LEFT", font_container.death_source_box, "LEFT", 0, 15)
	font_container.death_source_box.text:SetFont(Deathlog_L.menu_font, 12, "")
	font_container.death_source_box.text:SetTextColor(255 / 255, 215 / 255, 0)
	font_container.death_source_box.text:SetText("Death Source")
	font_container.death_source_box.text:Show()

	--- Death filter dropdown
	if font_container.death_filter_dd == nil then
		font_container.death_filter_dd = CreateFrame("Frame", nil, font_container, "UIDropDownMenuTemplate")
	end

	local filter_mode_labels = DeathNotificationLib.GetGuildFilterModeOptions(true)
	local filter_mode_keys = {}
	for k in pairs(filter_mode_labels) do
		table.insert(filter_mode_keys, k)
	end
	table.sort(filter_mode_keys)
	local function deathFilterDD(frame, level, menuList)
		for _, value in ipairs(filter_mode_keys) do
			local label = filter_mode_labels[value]
			local info = UIDropDownMenu_CreateInfo()
			info.text = label
			info.checked = death_filter_mode == value
			info.func = function()
				death_filter_mode = value
				deathlog_settings["search_log_filter_mode"] = value
				UIDropDownMenu_SetText(font_container.death_filter_dd, label)
				clearDeathlogMenuLogData()
				setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
			end
			UIDropDownMenu_AddButton(info)
		end
	end

	font_container.death_filter_dd:SetPoint("TOPLEFT", font_container.death_source_box, "TOPRIGHT", -15, 0)
	UIDropDownMenu_SetText(font_container.death_filter_dd, filter_mode_labels[death_filter_mode] or "All Deaths")
	UIDropDownMenu_SetWidth(font_container.death_filter_dd, 100)
	UIDropDownMenu_Initialize(font_container.death_filter_dd, deathFilterDD)
	UIDropDownMenu_JustifyText(font_container.death_filter_dd, "LEFT")

	if font_container.death_filter_dd.text == nil then
		font_container.death_filter_dd.text = font_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	end
	font_container.death_filter_dd.text:SetPoint("LEFT", font_container.death_filter_dd, "LEFT", 20, 20)
	font_container.death_filter_dd.text:SetFont(Deathlog_L.menu_font, 12, "")
	font_container.death_filter_dd.text:SetTextColor(255 / 255, 215 / 255, 0)
	font_container.death_filter_dd.text:SetText("Death Filter")
	font_container.death_filter_dd.text:Show()

	if font_container.last_words_check_box == nil then
		font_container.last_words_check_box =
			CreateFrame("CheckButton", "deathlog_last_words_check_box", font_container, "ChatConfigCheckButtonTemplate")
	end
	if font_container.last_words_check_box.text == nil then
		font_container.last_words_check_box.text = font_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	end

	font_container.last_words_check_box:SetPoint("TOPLEFT", font_container.death_filter_dd, "BOTTOMLEFT", 0, 8)
	font_container.last_words_check_box:SetChecked(false)
	font_container.last_words_check_box:SetScript("OnClick", function()
		if font_container.last_words_check_box:GetChecked() == true then
			last_words_filter = function(_, _entry)
				if _entry and _entry["last_words"] and _entry["last_words"] ~= "" then
					return true
				end
				return false
			end

			clearDeathlogMenuLogData()
			setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
		else
			last_words_filter = nil
			clearDeathlogMenuLogData()
			setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
		end
	end)

	font_container.last_words_check_box.text:SetPoint("LEFT", font_container.last_words_check_box, "LEFT", 21, 0)
	font_container.last_words_check_box.text:SetFont(Deathlog_L.menu_font, 12, "")
	font_container.last_words_check_box.text:SetTextColor(255 / 255, 215 / 255, 0)
	font_container.last_words_check_box.text:SetText("Last Words Only")
	font_container.last_words_check_box.text:Show()

	local header_label = AceGUI:Create("InteractiveLabel") ---@type AceGUIInteractiveLabel
	header_label:SetFullWidth(true)
	header_label:SetHeight(60)

	header_strings[subtitle_data[1][1]]:SetPoint("LEFT", header_label.frame, "LEFT", 0, 0)
	header_strings[subtitle_data[1][1]]:Show()
	for _, v in ipairs(subtitle_data) do
		header_strings[v[1]]:SetParent(header_label.frame)
		header_strings[v[1]]:SetText(v[1])
	end

	header_label:SetFont(main_font, 16, "")
	header_label:SetColor(1, 1, 1)
	header_label:SetText(" ")
	scroll_frame:AddChild(header_label)

	local deathlog_group = AceGUI:Create("ScrollFrame") ---@type AceGUIScrollFrame
	deathlog_group:SetFullWidth(true)
	deathlog_group:SetHeight(440)
	scroll_frame:AddChild(deathlog_group)
	font_container:SetParent(deathlog_group.frame)
	font_container:ClearAllPoints()
	font_container:SetPoint("TOPLEFT", deathlog_group.frame, "TOPLEFT", 0, 0)
	font_container:SetHeight(400)
	font_container:Show()
	for i = 1, max_rows do
		local idx = 101 - i
		local _entry = AceGUI:Create("InteractiveLabel") ---@type AceGUIInteractiveLabel
---@diagnostic disable-next-line: param-type-mismatch
		_entry:SetHighlight("Interface\\Glues\\CharacterSelect\\Glues-CharacterSelect-Highlight")

		font_strings[i][subtitle_data[1][1]]:SetPoint("LEFT", _entry.frame, "LEFT", 0, 0)
		font_strings[i][subtitle_data[1][1]]:Show()
		for _, v in ipairs(subtitle_data) do
			font_strings[i][v[1]]:SetParent(_entry.frame)
		end

		row_backgrounds[i]:SetPoint("CENTER", _entry.frame, "CENTER", 0, 0)
		row_backgrounds[i]:SetParent(_entry.frame)

		_entry:SetHeight(40)
		_entry:SetFullWidth(true)
		_entry:SetFont(main_font, 16, "")
		_entry:SetColor(1, 1, 1)
		_entry:SetText(" ")

		_entry:SetCallback("OnLeave", function(widget)
			GameTooltip:Hide()
		end)

		_entry:SetCallback("OnClick", function()
			local click_type = GetMouseButtonClicked()

			if click_type == "LeftButton" then
			elseif click_type == "RightButton" then
				-- Only show context menu if this row has data
				local nameText = font_strings[i] and font_strings[i]["Name"] and font_strings[i]["Name"]:GetText()
				if nameText and strtrim(nameText) ~= "" then
					death_tomb_frame.map_id = font_strings[i].map_id
					death_tomb_frame.coordinates = font_strings[i].map_id_coords_x and { font_strings[i].map_id_coords_x, font_strings[i].map_id_coords_y } or nil
					death_tomb_frame.clicked_name = nameText
					death_tomb_frame.clicked_player_data = font_strings[i].player_data

					local dropDown = CreateFrame("Frame", "WPDemoContextMenu", UIParent, "UIDropDownMenuTemplate")
					-- Bind an initializer function to the dropdown; see previous sections for initializer function examples.
					UIDropDownMenu_Initialize(dropDown, WPDropDownDemo_Menu, "MENU")
					ToggleDropDownMenu(1, nil, dropDown, "cursor", 3, -3)
				end
			end
		end)

		_entry:SetCallback("OnEnter", function(widget)
			-- Only show tooltip if this row has data
			local nameText = font_strings[i] and font_strings[i]["Name"] and font_strings[i]["Name"]:GetText()
			if not (nameText and strtrim(nameText) ~= "") then
				return
			end

			GameTooltip_SetDefaultAnchor(GameTooltip, WorldFrame)
			local _name = ""
			local _level = ""
			local _guild = ""
			local _race = ""
			local _class = ""
			local _source = ""
			local _zone = ""
			local _date = ""
			local _playtime = ""
			local _last_words = ""
			if font_strings[i] and font_strings[i]["Name"] then
				-- Drop the trailing "reported" * so it doesn't leak into the title.
				_name = (font_strings[i]["Name"]:GetText() or ""):gsub("%*$", "")
			end
			if font_strings[i] and font_strings[i]["Lvl"] then
				_level = font_strings[i]["Lvl"]:GetText() or ""
			end
			if font_strings[i] and font_strings[i]["Guild"] then
				_guild = font_strings[i]["Guild"]:GetText() or ""
			end
			if font_strings[i] and font_strings[i]["Race"] then
				_race = font_strings[i]["Race"]:GetText() or ""
			end
			if font_strings[i] and font_strings[i]["Class"] then
				_class = font_strings[i]["Class"]:GetText() or ""
			end
			if font_strings[i] and font_strings[i]["Death Source"] then
				_source = font_strings[i]["Death Source"]:GetText() or ""
			end
			if font_strings[i] and font_strings[i]["Zone/Instance"] then
				_zone = font_strings[i]["Zone/Instance"]:GetText() or ""
			end
			if font_strings[i] and font_strings[i]["Date"] then
				_date = font_strings[i]["Date"]:GetText() or ""
			end
			if font_strings[i] and font_strings[i]["Playtime"] then
				_playtime = font_strings[i]["Playtime"]:GetText() or ""
			end
			if font_strings[i] and font_strings[i]["Last Words"] then
				_last_words = font_strings[i]["Last Words"]:GetText() or ""
			end
			local _reported_by = ""
			if font_strings[i] and font_strings[i].player_data then
				_reported_by = Deathlog_getDisplaySender(font_strings[i].player_data) or ""
			end
			Deathlog_setTooltip(_name, _level, _guild, _race, _class, _source, _zone, _date, _playtime, _last_words, _reported_by)
			GameTooltip:Show()
		end)

		deathlog_group:SetScroll(0)
		deathlog_group.scrollbar:Hide()
		deathlog_group:AddChild(_entry)
	end

	if font_container.page_str == nil then
		font_container.page_str = font_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		font_container.page_str:SetText("Page " .. page_number)
		font_container.page_str:SetFont(Deathlog_L.menu_font, 14, "")
		font_container.page_str:SetJustifyV("BOTTOM")
		font_container.page_str:SetJustifyH("CENTER")
		font_container.page_str:SetTextColor(0.7, 0.7, 0.7)
		font_container.page_str:SetPoint("TOP", font_container, "TOP", 0, -444)
		font_container.page_str:Show()
	end

	font_container.page_str:ClearAllPoints()
	font_container.page_str:SetPoint("BOTTOM", scroll_container.frame, "BOTTOM", 0, 0)

	if font_container.prev_button == nil then
		font_container.prev_button = CreateFrame("Button", nil, font_container)
		font_container.prev_button:SetPoint("CENTER", font_container.page_str, "CENTER", -85, 0)
		font_container.prev_button:SetWidth(25)
		font_container.prev_button:SetHeight(25)
		font_container.prev_button:SetNormalTexture("Interface/Buttons/UI-SpellbookIcon-PrevPage-Up.PNG")
		font_container.prev_button:SetHighlightTexture("Interface/Buttons/UI-SpellbookIcon-PrevPage-Up.PNG")
		font_container.prev_button:SetPushedTexture("Interface/Buttons/UI-SpellbookIcon-PrevPage-Down.PNG")
	end

	font_container.prev_button:ClearAllPoints()
	font_container.prev_button:SetPoint("CENTER", font_container.page_str, "CENTER", -85, 0)

	font_container.prev_button:SetScript("OnClick", function()
		if page_number > 1 then
			page_number = page_number - 1
			clearDeathlogMenuLogData(true)
			-- Use cached results instead of re-filtering
			displayPageFromCache()
		end
	end)

	if font_container.next_button == nil then
		font_container.next_button = CreateFrame("Button", nil, font_container)
		font_container.next_button:SetPoint("CENTER", font_container.page_str, "CENTER", 85, 0)
		font_container.next_button:SetWidth(25)
		font_container.next_button:SetHeight(25)
		font_container.next_button:SetNormalTexture("Interface/Buttons/UI-SpellbookIcon-NextPage-Up.PNG")
		font_container.next_button:SetHighlightTexture("Interface/Buttons/UI-SpellbookIcon-NextPage-Up.PNG")
		font_container.next_button:SetPushedTexture("Interface/Buttons/UI-SpellbookIcon-NextPage-Down.PNG")
	end

	font_container.next_button:ClearAllPoints()
	font_container.next_button:SetPoint("CENTER", font_container.page_str, "CENTER", 85, 0)

	font_container.next_button:SetScript("OnClick", function()
		if page_number < total_pages then
			page_number = page_number + 1
			clearDeathlogMenuLogData(true)
			-- Use cached results instead of re-filtering
			displayPageFromCache()
		end
	end)

	if font_container.refresh_button == nil then
		font_container.refresh_button = CreateFrame("Button", nil, font_container)
		font_container.refresh_button:SetWidth(25)
		font_container.refresh_button:SetHeight(25)
		font_container.refresh_button:SetNormalTexture("Interface/Buttons/UI-SquareButton-Up")
		font_container.refresh_button:SetPushedTexture("Interface/Buttons/UI-SquareButton-Down")
		font_container.refresh_button:SetHighlightTexture("Interface/Buttons/ButtonHilight-Square")
		local icon = font_container.refresh_button:CreateTexture(nil, "ARTWORK")
		icon:SetTexture("Interface/Buttons/UI-RefreshButton")
		icon:SetSize(16, 16)
		icon:SetPoint("CENTER", font_container.refresh_button, "CENTER", -1, 0)
	end

	font_container.refresh_button:ClearAllPoints()
	font_container.refresh_button:SetPoint("RIGHT", font_container.next_button, "RIGHT", 464, 0)
	font_container.refresh_button:SetScript("OnClick", function()
		clearDeathlogMenuLogData(true)
		setDeathlogMenuLogData(DeathlogFilter(_deathlog_data, filter))
	end)
	font_container.refresh_button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Refresh", 1, 1, 1)
		GameTooltip:AddLine("Reload the death list with the latest data.", 0.8, 0.8, 0.8, true)
		GameTooltip:Show()
	end)
	font_container.refresh_button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	deathlog_group.frame:HookScript("OnHide", function()
		font_container:Hide()
	end)
	deathlog_group.frame:HookScript("OnShow", function()
		font_container:Show()
	end)
end

local function drawWatchListTab(container)
	local current_creature_id = nil
	local update_functions = {}
	local scroll_container = AceGUI:Create("SimpleGroup") ---@type AceGUISimpleGroup
	scroll_container:SetFullWidth(true)
	scroll_container:SetFullHeight(true)
	scroll_container:SetLayout("Fill")
	deathlog_tabcontainer:AddChild(scroll_container)

	local scroll_frame = AceGUI:Create("SimpleGroup") ---@type AceGUISimpleGroup
	scroll_frame:SetLayout("Flow")
	scroll_container:AddChild(scroll_frame)

	local title_label = AceGUI:Create("Heading") ---@type AceGUIHeading
	title_label:SetFullWidth(true)
	title_label:SetText("Watch List")
	title_label.label:SetFont(Deathlog_L.menu_font, 24, "")
	scroll_frame:AddChild(title_label)

	local description_label = AceGUI:Create("Label") ---@type AceGUILabel
	description_label:SetFullWidth(true)
	description_label:SetText(
		"Add players of interest to a watch list.  If a player on this list dies while you are logged off, the deathlog system will try to notify you when you log in.  Add a description and icon to remember the player by."
	)
	description_label.label:SetFont(Deathlog_L.menu_font, 14, "")
	description_label.label:SetTextColor(0.6, 0.6, 0.6, 1.0)
	description_label.label:SetJustifyH("CENTER")
	scroll_frame:AddChild(description_label)

	local elements = {
		Deathlog_WatchList(),
	}

	local function updateElements()
		for _, v in ipairs(elements) do
			v.updateMenuElement(scroll_frame)
		end
	end

	updateElements()

	scroll_frame.frame:HookScript("OnHide", function()
		for _, v in ipairs(elements) do
			v:Hide()
		end
	end)
end

local function drawCreatureStatisticsTab(container)
	local current_creature_id = current_creature_stats_source_id
	local update_functions = {}
	local scroll_container = AceGUI:Create("SimpleGroup") ---@type AceGUISimpleGroup
	scroll_container:SetFullWidth(true)
	scroll_container:SetFullHeight(true)
	scroll_container:SetLayout("Fill")
	deathlog_tabcontainer:AddChild(scroll_container)

	local scroll_frame = AceGUI:Create("SimpleGroup") ---@type AceGUISimpleGroup
	scroll_frame:SetLayout("Flow")
	scroll_container:AddChild(scroll_frame)

	local title_label = AceGUI:Create("Heading") ---@type AceGUIHeading
	title_label:SetFullWidth(true)
	title_label:SetText("Death Statistics - Azeroth")
	title_label.label:SetFont(Deathlog_L.menu_font, 24, "")
	scroll_frame:AddChild(title_label)
	local function modifyTitle(zone)
		title_label:SetText("Death Statistics - " .. zone)
	end

	local description_label = AceGUI:Create("Label") ---@type AceGUILabel
	description_label:SetFullWidth(true)
	description_label:SetText("Death Statistics - Azeroth")
	description_label.label:SetFont(Deathlog_L.menu_font, 14, "")
	description_label.label:SetTextColor(0.6, 0.6, 0.6, 1.0)
	description_label.label:SetJustifyH("CENTER")
	scroll_frame:AddChild(description_label)
	local function modifyDescription(creature_id)
		local deaths_by_creature = Deathlog_GetSourceStatsCount(creature_id)
		if not deaths_by_creature or deaths_by_creature == 0 then
			description_label:SetText("")
			return
		end
		local all_deaths = Deathlog_GetCauseStatsCount(_cause_stats["all"])
		local creature_pct = 0
		if all_deaths and all_deaths > 0 then
			creature_pct = deaths_by_creature / all_deaths * 100
		end
		local creature_name = Deathlog_GetSourceNameById(creature_id)
		if creature_name == "" then creature_name = "Unknown" end
		description_label:SetText(
			string.format("%.2f", creature_pct)
				.. "% of all "
				.. Deathlog_GetSelectedCauseDescriptor()
				.. " are caused by "
				.. creature_name
				.. "."
		)
	end

	local no_data_frame = CreateFrame("Frame", nil, scroll_frame.frame)
	no_data_frame:SetSize(300, 100)
	no_data_frame:SetPoint("TOPRIGHT", scroll_frame.frame, "TOPRIGHT", -80, -250)
	no_data_frame:Hide()

	local no_data_text = no_data_frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	no_data_text:SetPoint("CENTER", no_data_frame, "CENTER", 0, 0)
	no_data_text:SetFont(Deathlog_L.menu_font, 16, "")
	no_data_text:SetTextColor(0.6, 0.6, 0.6, 1)
	no_data_text:SetText("No death data available\nfor this source yet.")

	local stats_menu_elements = {
		Deathlog_CreatureModelContainer(),
		Deathlog_AverageClassContainer(),
		Deathlog_MapContainerForCreatures(),
		Deathlog_DeadliestCreatureExtContainer(),
	}
	stats_menu_elements[2].configure_for = "creature"

	local function updateElements(creature_id, name, filter)
		current_creature_id = creature_id or current_creature_stats_source_id

		-- If the selected creature doesn't match the current source kind filter,
		-- auto-select the top creature for this kind
		local selected_source_kind = Deathlog_GetMenuSourceKind()
		if
			selected_source_kind ~= Deathlog_GetDefaultSourceKind()
			and not Deathlog_SourceMatchesKind(current_creature_id, selected_source_kind)
		then
			local map_id = Deathlog_normalize_map_id_for_stats(Deathlog_ROOT_MAP_ID)
			local ordered = _stats and DeathlogGetOrdered(_stats, { "all", map_id, "all", nil })
			if ordered then
				for _, v in ipairs(ordered) do
					if Deathlog_SourceMatchesKind(v[1], selected_source_kind) then
						current_creature_id = v[1]
						local resolved = Deathlog_GetSourceNameById(v[1])
						name = (resolved ~= "" and resolved) or "Unknown"
						break
					end
				end
			end
		end

		current_creature_stats_source_id = current_creature_id
		if not name or name == "" then
			local resolved = Deathlog_GetSourceNameById(current_creature_id)
			name = (resolved ~= "" and resolved) or nil
		end
		current_creature_stats_source_name = name
			or current_creature_stats_source_name
			or "Unknown"
		modifyTitle(current_creature_stats_source_name)
		modifyDescription(current_creature_id)

		local selected_cause_label = Deathlog_GetSourceKindLabel(selected_source_kind)
		if selected_source_kind ~= Deathlog_GetDefaultSourceKind() then
			no_data_text:SetText("No " .. selected_cause_label .. " death data available\nfor this source yet.")
		else
			no_data_text:SetText("No death data available\nfor this source yet.")
		end
		local stats_tbl = {
			["stats"] = _stats,
			["log_normal_params"] = Deathlog_GetLogNormalParamsForSourceKind(selected_source_kind),
			["selected_source_kind"] = selected_source_kind,
		}

		stats_menu_elements[4].updateMenuElement(scroll_frame, current_creature_id, stats_tbl, updateElements, filter)
		stats_menu_elements[4]:Show()

		if Deathlog_GetSourceStatsCount(current_creature_id) > 0 then
			no_data_frame:Hide()
			for i = 1, 3 do
				stats_menu_elements[i].updateMenuElement(scroll_frame, current_creature_id, stats_tbl, updateElements, filter)
				stats_menu_elements[i]:Show()
			end
		else
			for i = 1, 3 do
				stats_menu_elements[i]:Hide()
			end
			no_data_frame:Show()
		end
	end

	updateElements(current_creature_stats_source_id, current_creature_stats_source_name)

	scroll_frame.frame:HookScript("OnHide", function()
		for _, v in ipairs(stats_menu_elements) do
			v:Hide()
		end
		no_data_frame:Hide()
	end)
end

local function drawStatisticsTab(container)
	local update_functions = {}
	local source_kind_summary_order = Deathlog_GetSourceKindSummaryOrder()
	local current_zone_name = Deathlog_ROOT_MAP_NAME
	local setMapRegion
	local scroll_container = AceGUI:Create("SimpleGroup") ---@type AceGUISimpleGroup
	scroll_container:SetFullWidth(true)
	scroll_container:SetFullHeight(true)
	scroll_container:SetLayout("Fill")
	deathlog_tabcontainer:AddChild(scroll_container)

	local scroll_frame = AceGUI:Create("SimpleGroup") ---@type AceGUISimpleGroup
	scroll_frame:SetLayout("Flow")
	scroll_container:AddChild(scroll_frame)

	local title_label = AceGUI:Create("Heading") ---@type AceGUIHeading
	title_label:SetFullWidth(true)
	title_label:SetText("Death Statistics - Azeroth")
	title_label.label:SetFont(Deathlog_L.menu_font, 24, "")
	scroll_frame:AddChild(title_label)
	local function modifyTitle(zone)
		title_label:SetText("Death Statistics - " .. zone)
	end

	local description_label = AceGUI:Create("Label") ---@type AceGUILabel
	description_label:SetFullWidth(true)
	description_label:SetText("Death Statistics - Azeroth")
	description_label.label:SetFont(Deathlog_L.menu_font, 14, "")
	description_label.label:SetTextColor(0.6, 0.6, 0.6, 1.0)
	description_label.label:SetJustifyH("CENTER")
	scroll_frame:AddChild(description_label)

	local function buildCauseBreakdown(cause_stats_entry)
		if not cause_stats_entry or not cause_stats_entry.total or cause_stats_entry.total <= 0 then
			return ""
		end

		local parts = {}
		for _, kind in ipairs(source_kind_summary_order) do
			local count = cause_stats_entry[kind] or 0
			if count > 0 then
				parts[#parts + 1] = string.format(
					"%s %.0f%%",
					Deathlog_GetSourceKindLabel(kind),
					(count / cause_stats_entry.total) * 100
				)
			end
		end

		return table.concat(parts, ", ")
	end

	local function getTopSourceCallout(cause_stats_entry)
		if not cause_stats_entry or not cause_stats_entry.top_sources then
			return ""
		end

		---@type DNL_SOURCE_KIND|nil
		local leader_kind = Deathlog_GetMenuSourceKind()
		if leader_kind == Deathlog_GetDefaultSourceKind() or (cause_stats_entry[leader_kind] or 0) <= 0 then
			leader_kind = nil
			local best_count = 0
			for _, kind in ipairs(source_kind_summary_order) do
				local count = cause_stats_entry[kind] or 0
				if count > best_count then
					best_count = count
					leader_kind = kind
				end
			end
		end

		if not leader_kind then
			return ""
		end

		local top_source_id = cause_stats_entry.top_sources[leader_kind]
		if top_source_id == nil then
			return ""
		end

		local top_source_name = Deathlog_GetSourceNameById(top_source_id)
		if top_source_name == "" then
			top_source_name = Deathlog_GetSourceKindLabel(source_kind.UNKNOWN)
		end

		return string.format("Top %s: %s", Deathlog_GetSourceKindLabel(leader_kind), top_source_name)
	end

	local function modifyDescription(map_id, zone)
		local mid = Deathlog_normalize_map_id_for_stats(map_id)
		local deaths_in_zone = Deathlog_GetCauseStatsCount(_cause_stats[mid])
		local all_deaths = Deathlog_GetCauseStatsCount(_cause_stats["all"])
		local zone_pct = 0
		if all_deaths and all_deaths > 0 then
			zone_pct = deaths_in_zone / all_deaths * 100
		end
		local cause_stats_entry = _cause_stats[mid]
		local cause_breakdown = buildCauseBreakdown(cause_stats_entry)
		local top_source_callout = getTopSourceCallout(cause_stats_entry)
		local description_parts = {}
		-- Skip the trivial "100% occur in Azeroth" when at root map
		local is_root = (map_id == Deathlog_ROOT_MAP_ID)
		if not is_root then
			description_parts[#description_parts + 1] =
				string.format("%.2f", zone_pct) .. "% of all " .. Deathlog_GetSelectedCauseDescriptor() .. " occur in " .. zone .. "."
		end
		if cause_breakdown ~= "" then
			description_parts[#description_parts + 1] = cause_breakdown .. "."
		end
		if top_source_callout ~= "" then
			description_parts[#description_parts + 1] = top_source_callout .. "."
		end
		description_label:SetText(table.concat(description_parts, " "))
	end

	-- Create "no data" message frame
	local no_data_frame = CreateFrame("Frame", nil, scroll_frame.frame)
	no_data_frame:SetSize(300, 100)
	no_data_frame:SetPoint("TOPRIGHT", scroll_frame.frame, "TOPRIGHT", -80, -250)
	no_data_frame:Hide()

	local no_data_text = no_data_frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	no_data_text:SetPoint("CENTER", no_data_frame, "CENTER", 0, 0)
	no_data_text:SetFont(Deathlog_L.menu_font, 16, "")
	no_data_text:SetTextColor(0.6, 0.6, 0.6, 1)
	no_data_text:SetText("No death data available\nfor this zone yet.")

	local stats_menu_elements = {
		Deathlog_MapContainer(),
		Deathlog_DeadliestCreatureContainer(),
		Deathlog_AverageClassContainer(),
		Deathlog_GraphContainer(),
	}

	stats_menu_elements[3].configure_for = "map"

	local function getMapDisplayName(map_id)
		if map_id == Deathlog_ROOT_MAP_ID then
			return Deathlog_ROOT_MAP_NAME
		end

		local map_info = C_Map.GetMapInfo(map_id)
		return map_info and map_info.name or nil
	end

	local function canUseZoneStatisticsMap(map_id)
		if type(map_id) ~= "number" then
			return false
		end
		if C_Map.GetMapInfo(map_id) == nil then
			return false
		end
		return C_Map.GetMapArtLayerTextures(map_id, 1) ~= nil
	end

	local function getInitialZoneStatisticsMap()
		local saved_map_id = deathlog_settings and tonumber(deathlog_settings["zone_statistics_map_id"])
		if canUseZoneStatisticsMap(saved_map_id) then
			return saved_map_id, getMapDisplayName(saved_map_id)
		end

		local player_map_id = C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
		if canUseZoneStatisticsMap(player_map_id) then
			return player_map_id, getMapDisplayName(player_map_id)
		end

		return Deathlog_ROOT_MAP_ID, Deathlog_ROOT_MAP_NAME
	end

	setMapRegion = function(map_id, name)
		if not canUseZoneStatisticsMap(map_id) then
			map_id = Deathlog_ROOT_MAP_ID
			name = Deathlog_ROOT_MAP_NAME
		else
			name = name or getMapDisplayName(map_id) or current_zone_name or Deathlog_ROOT_MAP_NAME
		end

		current_map_id = map_id
		current_zone_name = name
		if deathlog_settings then
			deathlog_settings["zone_statistics_map_id"] = map_id
			deathlog_settings["zone_statistics_map_name"] = name
		end
		modifyTitle(name)
		modifyDescription(map_id, name)

		local selected_source_kind = Deathlog_GetMenuSourceKind()
		local selected_cause_label = Deathlog_GetSourceKindLabel(selected_source_kind)
		if selected_source_kind ~= Deathlog_GetDefaultSourceKind() then
			no_data_text:SetText("No " .. selected_cause_label .. " death data available\nfor this zone yet.")
		else
			no_data_text:SetText("No death data available\nfor this zone yet.")
		end
		local stats_tbl = {
			["stats"] = _stats,
			["log_normal_params"] = Deathlog_GetLogNormalParamsForSourceKind(selected_source_kind),
			["selected_source_kind"] = selected_source_kind,
		}

		-- Check if data exists for this zone
		local mid = Deathlog_normalize_map_id_for_stats(map_id)
		local has_data = Deathlog_GetCauseStatsCount(_cause_stats[mid]) > 0

		if has_data then
			-- Show stats elements, hide no data message
			no_data_frame:Hide()
			for _, v in ipairs(stats_menu_elements) do
				v.updateMenuElement(scroll_frame, map_id, stats_tbl, setMapRegion)
			end
		else
			-- Hide stats elements (except map), show no data message
			stats_menu_elements[1].updateMenuElement(scroll_frame, map_id, stats_tbl, setMapRegion)
			for i = 2, #stats_menu_elements do
				stats_menu_elements[i]:Hide()
			end
			no_data_frame:Show()
		end
	end

	local initial_map_id, initial_map_name = getInitialZoneStatisticsMap()
	setMapRegion(initial_map_id, initial_map_name)

	scroll_frame.frame:HookScript("OnHide", function()
		for _, v in ipairs(stats_menu_elements) do
			v:Hide()
		end
		no_data_frame:Hide()
		-- Clear the map highlight overlay when switching tabs
		Deathlog_MapContainer_clearHighlight()
	end)
end

local function drawClassStatisticsTab(container)
	local update_functions = {}
	local scroll_container = AceGUI:Create("SimpleGroup") ---@type AceGUISimpleGroup
	local current_instance_id = 36
	scroll_container:SetFullWidth(true)
	scroll_container:SetFullHeight(true)
	scroll_container:SetLayout("Fill")
	deathlog_tabcontainer:AddChild(scroll_container)

	local scroll_frame = AceGUI:Create("SimpleGroup") ---@type AceGUISimpleGroup
	scroll_frame:SetLayout("Flow")
	scroll_container:AddChild(scroll_frame)

	local title_label = AceGUI:Create("Heading") ---@type AceGUIHeading
	title_label:SetFullWidth(true)
	title_label:SetText("Death Statistics - Azeroth")
	title_label.label:SetFont(Deathlog_L.menu_font, 24, "")
	scroll_frame:AddChild(title_label)
	local function modifyTitle(zone)
		title_label:SetText("Death Statistics - " .. zone)
	end

	local description_label = AceGUI:Create("Label") ---@type AceGUILabel
	description_label:SetFullWidth(true)
	description_label:SetText("")
	description_label.label:SetFont(Deathlog_L.menu_font, 14, "")
	description_label.label:SetTextColor(0.6, 0.6, 0.6, 1.0)
	description_label.label:SetJustifyH("CENTER")
	scroll_frame:AddChild(description_label)

	local stats_menu_elements = {
		Deathlog_ClassGraphContainer(),
		Deathlog_ClassStatsContainer(),
		Deathlog_ClassSelectorContainer(),
		Deathlog_ClassStatsComparisonContainer(),
	}

	local function setMapRegion(map_id, name, model, view)
		current_map_id = map_id
		current_class_stats_class_id = map_id or current_class_stats_class_id
		current_class_stats_class_name = name or current_class_stats_class_name or "Warrior"
		current_class_stats_model = model or current_class_stats_model
		current_class_stats_view = view or current_class_stats_view
		modifyTitle(current_class_stats_class_name)

		local selected_source_kind = Deathlog_GetMenuSourceKind()
		if selected_source_kind ~= Deathlog_GetDefaultSourceKind() then
			description_label:SetText(
				"Showing class survival for "
					.. Deathlog_GetSourceKindLabel(selected_source_kind)
					.. " deaths."
			)
		else
			description_label:SetText("")
		end
		local stats_tbl = {
			["stats"] = _stats,
			["log_normal_params"] = Deathlog_GetLogNormalParamsForSourceKind(selected_source_kind),
			["kaplan_meier"] = Deathlog_GetKaplanMeierForSourceKind(selected_source_kind),
			["selected_source_kind"] = selected_source_kind,
		}

		stats_menu_elements[2].updateMenuElement(
			scroll_frame,
			current_class_stats_class_id,
			stats_tbl,
			setMapRegion,
			current_class_stats_model,
			current_class_stats_view
		)
		stats_menu_elements[2]:Show()
		stats_menu_elements[3].updateMenuElement(
			scroll_frame,
			current_class_stats_class_id,
			stats_tbl,
			setMapRegion,
			current_class_stats_model,
			current_class_stats_view
		)
		stats_menu_elements[3]:Show()

		stats_menu_elements[1].updateMenuElement(
			scroll_frame,
			current_class_stats_class_id,
			stats_tbl,
			setMapRegion,
			current_class_stats_model,
			current_class_stats_view
		)
		stats_menu_elements[1]:Show()
		stats_menu_elements[4].updateMenuElement(
			scroll_frame,
			current_class_stats_class_id,
			stats_tbl,
			setMapRegion,
			current_class_stats_model,
			current_class_stats_view
		)
		stats_menu_elements[4]:Show()
	end

	setMapRegion(
		current_class_stats_class_id,
		current_class_stats_class_name,
		current_class_stats_model,
		current_class_stats_view
	)

	scroll_frame.frame:HookScript("OnHide", function()
		for _, v in ipairs(stats_menu_elements) do
			v:Hide()
		end
	end)
end

local function drawInstanceStatisticsTab(container)
	local update_functions = {}
	local scroll_container = AceGUI:Create("SimpleGroup") ---@type AceGUISimpleGroup
	local current_instance_id = Deathlog_ALL_INSTANCES_ID
	scroll_container:SetFullWidth(true)
	scroll_container:SetFullHeight(true)
	scroll_container:SetLayout("Fill")
	deathlog_tabcontainer:AddChild(scroll_container)

	local scroll_frame = AceGUI:Create("SimpleGroup") ---@type AceGUISimpleGroup
	scroll_frame:SetLayout("Flow")
	scroll_container:AddChild(scroll_frame)

	local title_label = AceGUI:Create("Heading") ---@type AceGUIHeading
	title_label:SetFullWidth(true)
	title_label:SetText("Death Statistics - Azeroth")
	title_label.label:SetFont(Deathlog_L.menu_font, 24, "")
	scroll_frame:AddChild(title_label)
	local function modifyTitle(zone)
		title_label:SetText("Death Statistics - " .. zone)
	end

	local description_label = AceGUI:Create("Label") ---@type AceGUILabel
	description_label:SetFullWidth(true)
	description_label:SetText("")
	description_label.label:SetFont(Deathlog_L.menu_font, 14, "")
	description_label.label:SetTextColor(0.6, 0.6, 0.6, 1.0)
	description_label.label:SetJustifyH("CENTER")
	scroll_frame:AddChild(description_label)
	local function modifyDescription(map_id, zone)
		local mid = Deathlog_normalize_map_id_for_stats(map_id)
		local deaths_in_zone = Deathlog_GetCauseStatsCount(_cause_stats[mid])
		local all_deaths = Deathlog_GetCauseStatsCount(_cause_stats["all"])
		local zone_pct = 0
		if all_deaths and all_deaths > 0 then
			zone_pct = deaths_in_zone / all_deaths * 100
		end
		description_label:SetText(
			string.format("%.2f", zone_pct)
				.. "% of all "
				.. Deathlog_GetSelectedCauseDescriptor()
				.. " occur in "
				.. zone
				.. "."
		)
	end

	-- Create "no data" message frame
	local no_data_frame = CreateFrame("Frame", nil, scroll_frame.frame)
	no_data_frame:SetSize(300, 100)
	no_data_frame:SetPoint("TOPRIGHT", scroll_frame.frame, "TOPRIGHT", -80, -250)
	no_data_frame:Hide()

	local no_data_text = no_data_frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	no_data_text:SetPoint("CENTER", no_data_frame, "CENTER", 0, 0)
	no_data_text:SetFont(Deathlog_L.menu_font, 16, "")
	no_data_text:SetTextColor(0.6, 0.6, 0.6, 1)
	no_data_text:SetText("No death data available\nfor this instance yet.")

	local stats_menu_elements = {
		Deathlog_InstanceContainer(),
		Deathlog_DeadliestCreatureContainer(),
		Deathlog_AverageClassContainer(),
		Deathlog_GraphContainer(),
	}
	stats_menu_elements[3].configure_for = "map"

	local function setMapRegion(map_id, name)
		current_map_id = map_id
		if name then
			modifyTitle(name)
			modifyDescription(map_id, name)
		end
		local selected_source_kind = Deathlog_GetMenuSourceKind()
		local selected_cause_label = Deathlog_GetSourceKindLabel(selected_source_kind)
		if selected_source_kind ~= Deathlog_GetDefaultSourceKind() then
			no_data_text:SetText("No " .. selected_cause_label .. " death data available\nfor this instance yet.")
		else
			no_data_text:SetText("No death data available\nfor this instance yet.")
		end
		local stats_tbl = {
			["stats"] = _stats,
			["log_normal_params"] = Deathlog_GetLogNormalParamsForSourceKind(selected_source_kind),
			["selected_source_kind"] = selected_source_kind,
		}

		-- Check if data exists for this instance
		local mid = Deathlog_normalize_map_id_for_stats(map_id)
		local has_data = Deathlog_GetCauseStatsCount(_cause_stats[mid]) > 0

		if has_data then
			-- Show stats elements, hide no data message
			no_data_frame:Hide()
			for i, v in ipairs(stats_menu_elements) do
				v.updateMenuElement(scroll_frame, map_id, stats_tbl, setMapRegion)
				if i > 1 then
					v:Show()
				end
			end
		else
			-- Hide stats elements (except instance selector), show no data message
			stats_menu_elements[1].updateMenuElement(scroll_frame, map_id, stats_tbl, setMapRegion)
			for i = 2, #stats_menu_elements do
				stats_menu_elements[i]:Hide()
			end
			no_data_frame:Show()
		end
	end

	setMapRegion(Deathlog_ALL_INSTANCES_ID, "Instances")

	scroll_frame.frame:HookScript("OnHide", function()
		for _, v in ipairs(stats_menu_elements) do
			v:Hide()
		end
		no_data_frame:Hide()
	end)
end

local function drawMenuGroup(container, group)
	container:ReleaseChildren()
	if group == "StatisticsTab" then
		drawStatisticsTab(container)
	elseif group == "InstanceStatisticsTab" then
		drawInstanceStatisticsTab(container)
	elseif group == "ClassStatisticsTab" then
		drawClassStatisticsTab(container)
	elseif group == "CreatureStatisticsTab" then
		drawCreatureStatisticsTab(container)
	elseif group == "LogTab" then
		drawLogTab(container)
	elseif group == "WatchListTab" then
		drawWatchListTab(container)
	end
end

local function createDeathlogMenu()
	local menu_type ="DeathlogMenu" ---@type AceGUIWidgetType|AceGUIContainerType 
	local ace_deathlog_menu = AceGUI:Create(menu_type) ---@type AceGUIDeathlogMenu
	_G["AceDeathlogMenu"] = ace_deathlog_menu.frame -- Close on <ESC>
	tinsert(UISpecialFrames, "AceDeathlogMenu")
	Deathlog_registerReportDemoteFrame(ace_deathlog_menu.frame)

	ace_deathlog_menu:SetTitle("Deathlog")
	ace_deathlog_menu:SetVersion(GetAddOnMetadata("Deathlog", "Version"))
	ace_deathlog_menu:SetStatusText("")
	ace_deathlog_menu:SetLayout("Flow")
	ace_deathlog_menu:SetHeight(_menu_height)
	ace_deathlog_menu:SetWidth(_menu_width)

	if ace_deathlog_menu.exit_button == nil then
		ace_deathlog_menu.exit_button = CreateFrame("Button", nil, ace_deathlog_menu.frame)
		ace_deathlog_menu.exit_button:SetPoint("TOPRIGHT", ace_deathlog_menu.frame, "TOPRIGHT", -8, -8)
		ace_deathlog_menu.exit_button:SetWidth(25)
		ace_deathlog_menu.exit_button:SetHeight(25)
		ace_deathlog_menu.exit_button:SetNormalTexture("Interface/Buttons/UI-SquareButton-Disabled.PNG")
		ace_deathlog_menu.exit_button:SetHighlightTexture("Interface/Buttons/UI-SquareButton-Up.PNG")
		ace_deathlog_menu.exit_button:SetPushedTexture("Interface/Buttons/UI-SquareButton-Down.PNG")
		ace_deathlog_menu.exit_button:SetFrameLevel(ace_deathlog_menu.frame:GetFrameLevel() + 10)
	end

	ace_deathlog_menu.exit_button:SetScript("OnClick", function()
		deathlog_menu:Hide()
	end)

	if ace_deathlog_menu.exit_button_x == nil then
		ace_deathlog_menu.exit_button_x = death_tomb_frame:CreateTexture(nil, "OVERLAY")
		ace_deathlog_menu.exit_button_x:SetParent(ace_deathlog_menu.exit_button)
		ace_deathlog_menu.exit_button_x:SetPoint("CENTER", ace_deathlog_menu.exit_button, "CENTER", 0, 0)
		ace_deathlog_menu.exit_button_x:SetWidth(10)
		ace_deathlog_menu.exit_button_x:SetHeight(10)
		ace_deathlog_menu.exit_button_x:SetTexture("Interface/Buttons/UI-StopButton.PNG")
		ace_deathlog_menu.exit_button_x:SetVertexColor(1, 1, 1, 0.8)
	end

	Deathlog_createInfoButton(ace_deathlog_menu)

	if ace_deathlog_menu.contact_button == nil then
		local contact_text = ace_deathlog_menu.frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		contact_text:SetFont(Deathlog_L.menu_font, 14)
		contact_text:SetTextColor(0.5, 0.5, 0.5, 0.8)
		contact_text:SetPoint("BOTTOMLEFT", ace_deathlog_menu.frame, "BOTTOMLEFT", 18, 10)
		contact_text:SetText("Questions/Feedback? discord.gg/TrJFGcah7z")

		local contact_btn = CreateFrame("Button", nil, ace_deathlog_menu.frame)
		contact_btn:SetAllPoints(contact_text)
		contact_btn:SetFrameLevel(ace_deathlog_menu.frame:GetFrameLevel() + 10)
		contact_btn:SetScript("OnEnter", function(self)
			contact_text:SetTextColor(1, 0.8, 0, 1)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:AddLine("Click to copy", 0.7, 0.7, 0.7)
			GameTooltip:Show()
		end)
		contact_btn:SetScript("OnLeave", function()
			contact_text:SetTextColor(0.5, 0.5, 0.5, 0.8)
			GameTooltip:Hide()
		end)
		contact_btn:SetScript("OnClick", function()
			Deathlog_ShowCopyPopup("discord.gg/TrJFGcah7z")
		end)
		ace_deathlog_menu.contact_button = contact_btn
	end

	if ace_deathlog_menu.footer_source_kind_dd == nil then
		ace_deathlog_menu.footer_source_kind_dd =
			CreateFrame("Frame", nil, ace_deathlog_menu.frame, "UIDropDownMenuTemplate")
	end
	UIDropDownMenu_SetWidth(ace_deathlog_menu.footer_source_kind_dd, 115)
	UIDropDownMenu_JustifyText(ace_deathlog_menu.footer_source_kind_dd, "LEFT")
	UIDropDownMenu_Initialize(ace_deathlog_menu.footer_source_kind_dd, function(frame, level, menuList)
		for _, value in ipairs(Deathlog_GetSourceKindOptionOrder()) do
			local label = Deathlog_GetSourceKindOptions()[value]
			local info = UIDropDownMenu_CreateInfo()
			info.text = label
			info.checked = Deathlog_GetMenuSourceKind() == value
			info.func = function()
				Deathlog_SetMenuSourceKind(value)
				Deathlog_UpdateMenuSourceKindControl()
				refreshMenuSearchResults()
				if current_menu_group == "StatisticsTab"
					or current_menu_group == "InstanceStatisticsTab"
					or current_menu_group == "ClassStatisticsTab"
					or current_menu_group == "CreatureStatisticsTab"
				then
					drawMenuGroup(deathlog_tabcontainer, current_menu_group)
				end
			end
			UIDropDownMenu_AddButton(info)
		end
	end)

	if ace_deathlog_menu.footer_source_kind_label == nil then
		ace_deathlog_menu.footer_source_kind_label =
			ace_deathlog_menu.frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	end
	ace_deathlog_menu.footer_source_kind_label:SetFont(Deathlog_L.menu_font, 12, "")
	ace_deathlog_menu.footer_source_kind_label:SetTextColor(255 / 255, 215 / 255, 0)
	ace_deathlog_menu.footer_source_kind_label:SetText("Cause")
	ace_deathlog_menu.footer_source_kind_label:Show()
	UIDropDownMenu_SetText(
		ace_deathlog_menu.footer_source_kind_dd,
		Deathlog_GetSourceKindOptions()[Deathlog_GetMenuSourceKind()] or "All Causes"
	)

	local tab_group_type ="DeathlogTabGroup" ---@type AceGUIWidgetType|AceGUIContainerType 
	deathlog_tabcontainer = AceGUI:Create(tab_group_type) ---@type AceGUIDeathlogTabGroup
	local tab_table = Deathlog_L.tab_table
	deathlog_tabcontainer:SetTabs(tab_table)
	Deathlog_LayoutMenuSourceKindControl()
	deathlog_tabcontainer:SetFullWidth(true)
	deathlog_tabcontainer:SetFullHeight(true)
	deathlog_tabcontainer:SetLayout("Flow")

	local function SelectGroup(container, event, group)
		current_menu_group = group
		drawMenuGroup(container, group)
		Deathlog_LayoutMenuSourceKindControl()
		Deathlog_UpdateMenuSourceKindControl()
	end

	deathlog_tabcontainer:SetCallback("OnGroupSelected", SelectGroup)

	ace_deathlog_menu:AddChild(deathlog_tabcontainer)

	deathlog_cta_banner = Deathlog_CTABannerContainer()
	deathlog_cta_banner:SetParent(ace_deathlog_menu.frame)

	-- Persist window position and scale across reloads via SavedVariables
	deathlog_settings.menu_status = deathlog_settings.menu_status or {}
	ace_deathlog_menu:SetStatusTable(deathlog_settings.menu_status)

	return ace_deathlog_menu
end

function DeathlogShowMenu(deathlog_data, stats, log_normal_params)
	if not deathlog_menu then
		deathlog_menu = createDeathlogMenu()
	end

	deathlog_menu:Show()
	deathlog_cta_banner.updateMenuElement(deathlog_menu.frame)
	deathlog_tabcontainer:SelectTab("LogTab")
	_deathlog_data = deathlog_data
	_stats = stats
	_log_normal_params = log_normal_params
	_cause_stats = DeathlogDataCopy.PRECOMPUTED_CAUSE_STATS or {}
	Deathlog_UpdateMenuSourceKindControl()
	refreshMenuSearchResults()

	if _auto_refresh_ticker then _auto_refresh_ticker:Cancel() end
	_auto_refresh_ticker = C_Timer.NewTicker(10, function()
		if not deathlog_settings["auto_refresh_search"] then return end
		if not deathlog_menu or not deathlog_menu.frame:IsShown() then return end
		if page_number ~= 1 then return end
		refreshMenuSearchResults(true)
	end)
end

function DeathlogHideMenu()
	if _auto_refresh_ticker then
		_auto_refresh_ticker:Cancel()
		_auto_refresh_ticker = nil
	end
	if deathlog_menu then
		deathlog_menu:Hide()
	end
end

function DeathlogToggleMenu(deathlog_data, stats, log_normal_params)
	if deathlog_menu and deathlog_menu.frame:IsShown() then
		DeathlogHideMenu()
	else
		DeathlogShowMenu(deathlog_data, stats, log_normal_params)
	end
end

function DeathlogResetMenuPosition()
	if deathlog_settings and deathlog_settings.menu_status then
		deathlog_settings.menu_status.left = nil
		deathlog_settings.menu_status.top = nil
		deathlog_settings.menu_status.scale = nil
		deathlog_settings.menu_status.width = nil
		deathlog_settings.menu_status.height = nil
	end
	if deathlog_menu then
		deathlog_menu:ApplyStatus()
	end
end
