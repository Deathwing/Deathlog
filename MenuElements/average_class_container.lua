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
---@type MenuElementContainer
local average_class_container = CreateFrame("Frame")
average_class_container:SetSize(100, 100)
average_class_container:Show()
average_class_container.configure_for = "map"

local class_font = Deathlog_L.class_font

local class_tbl = Deathlog_class_tbl

local average_class_subtitles = {
	{ "Class", 20, "LEFT", 60 },
	{ "#", 50, "RIGHT", 40 },
	{ "%", 90, "RIGHT", 50 },
	{ "Avg.", 130, "RIGHT", 50 },
}

local average_class_header_font_strings = {}
for _, v in ipairs(average_class_subtitles) do
	average_class_header_font_strings[v[1]] = average_class_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	average_class_header_font_strings[v[1]]:SetPoint("TOPLEFT", average_class_container, "TOPLEFT", v[2], 2)
	average_class_header_font_strings[v[1]]:SetFont(class_font, 15, "")
	average_class_header_font_strings[v[1]]:SetJustifyH(v[3])
	average_class_header_font_strings[v[1]]:SetWidth(50)
	average_class_header_font_strings[v[1]]:SetText(v[1])
end

local average_class_font_strings = {}
local sep = -18
for k, class_id in pairs(class_tbl) do
	average_class_font_strings[class_id] = {}
	for _, v in ipairs(average_class_subtitles) do
		average_class_font_strings[class_id][v[1]] =
			average_class_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		average_class_font_strings[class_id][v[1]]:SetPoint(
			"TOPLEFT",
			average_class_container,
			"TOPLEFT",
			v[2],
			sep + 5
		)
		average_class_font_strings[class_id][v[1]]:SetFont(class_font, 14, "")
		average_class_font_strings[class_id][v[1]]:SetJustifyH(v[3])
		average_class_font_strings[class_id][v[1]]:SetWidth(50)
		average_class_font_strings[class_id][v[1]]:SetTextColor(1, 1, 1, 1)
		average_class_font_strings[class_id][v[1]]:SetWordWrap(false)
	end
	sep = sep - 15
end

average_class_font_strings["all"] = {}
for _, v in ipairs(average_class_subtitles) do
	average_class_font_strings["all"][v[1]] = average_class_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	average_class_font_strings["all"][v[1]]:SetPoint("TOPLEFT", average_class_container, "TOPLEFT", v[2], sep + 5)
	average_class_font_strings["all"][v[1]]:SetFont(class_font, 14, "")
	average_class_font_strings["all"][v[1]]:SetJustifyH(v[3])
	average_class_font_strings["all"][v[1]]:SetWidth(50)
	average_class_font_strings["all"][v[1]]:SetTextColor(1, 1, 1, 1)
end

local getFilteredClassEntry = Deathlog_getFilteredClassEntry

local function getCreatureClassEntry(class_stats, creature_id, selected_source_kind)
	if selected_source_kind ~= Deathlog_GetDefaultSourceKind()
		and not Deathlog_SourceMatchesKind(creature_id, selected_source_kind)
	then
		return nil
	end
	if class_stats == nil then
		return nil
	end
	return class_stats[creature_id]
end

function average_class_container.updateMenuElement(scroll_frame, current_map_id, stats_tbl, setMapRegion)
	average_class_container:Show()
	local entry_data = {}
	local map_id = Deathlog_normalize_map_id_for_stats(current_map_id)
	local _stats = stats_tbl["stats"]
	local selected_source_kind = Deathlog_NormalizeSourceKind(stats_tbl["selected_source_kind"])
	-- Container zones (continents, Outland) now have aggregated stats
	if average_class_container.configure_for == "map" and _stats["all"][map_id] == nil then
		return
	end
	local total_map_entry = nil
	if average_class_container.configure_for == "map" and _stats["all"][map_id] then
		total_map_entry = getFilteredClassEntry(_stats["all"][map_id]["all"], selected_source_kind)
	end

	average_class_container:SetParent(scroll_frame.frame)
	average_class_container:ClearAllPoints()
	average_class_container:SetPoint("TOPLEFT", scroll_frame.frame, "TOPLEFT", 820, -65)
	average_class_container:SetWidth(200)
	average_class_container:SetHeight(200)

	if average_class_container.heading == nil then
		average_class_container.heading = average_class_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		average_class_container.heading:SetText("By Class")
		average_class_container.heading:SetFont(class_font, 18, "")
		average_class_container.heading:SetJustifyV("TOP")
		average_class_container.heading:SetTextColor(0.9, 0.9, 0.9)
		average_class_container.heading:SetPoint("TOP", average_class_container, "TOP", 0, 20)
		average_class_container.heading:Show()
	end

	if average_class_container.left == nil then
		average_class_container.left = average_class_container:CreateTexture(nil, "BACKGROUND")
		average_class_container.left:SetHeight(8)
		average_class_container.left:SetPoint("LEFT", average_class_container.heading, "LEFT", -50, 0)
		average_class_container.left:SetPoint("RIGHT", average_class_container.heading, "LEFT", -5, 0)
		average_class_container.left:SetTexture(137057) -- Interface\\Tooltips\\UI-Tooltip-Border
		average_class_container.left:SetTexCoord(0.81, 0.94, 0.5, 1)
	end

	if average_class_container.right == nil then
		average_class_container.right = average_class_container:CreateTexture(nil, "BACKGROUND")
		average_class_container.right:SetHeight(8)
		average_class_container.right:SetPoint("RIGHT", average_class_container.heading, "RIGHT", 50, 0)
		average_class_container.right:SetPoint("LEFT", average_class_container.heading, "RIGHT", 5, 0)
		average_class_container.right:SetTexture(137057) -- Interface\\Tooltips\\UI-Tooltip-Border
		average_class_container.right:SetTexCoord(0.81, 0.94, 0.5, 1)
	end

	local function createEntryData(class_id)
		local v = getFilteredClassEntry(_stats["all"][map_id][class_id], selected_source_kind)
		if v == nil or total_map_entry == nil then
			entry_data[class_id] = {}
			local class_str = class_id == "all" and "all" or select(1, GetClassInfo(class_id))
			entry_data[class_id]["Class"] = class_str
			entry_data[class_id]["#"] = "-"
			entry_data[class_id]["%"] = "-"
			entry_data[class_id]["Avg."] = "-"
		else
			local class_str = ""
			if class_id ~= "all" then
				class_str, _, _ = GetClassInfo(class_id)
			else
				class_str = "all"
			end
			entry_data[class_id] = {}
			entry_data[class_id]["Class"] = class_str
			entry_data[class_id]["#"] = v["num_entries"]
			if total_map_entry["num_entries"] > 0 then
				entry_data[class_id]["%"] = string.format(
					"%.1f",
					v["num_entries"] / total_map_entry["num_entries"] * 100.0
				) .. "%"
			else
				entry_data[class_id]["%"] = "-"
			end
			entry_data[class_id]["Avg."] = string.format("%.1f", v["avg_lvl"])
		end
	end

	local function createEntryDataForCreature(class_id, creature_id)
		local v = getCreatureClassEntry(_stats["all"]["all"][class_id], creature_id, selected_source_kind)
		local total_creature_entry = getCreatureClassEntry(_stats["all"]["all"]["all"], creature_id, selected_source_kind)
		if v == nil or total_creature_entry == nil then
			entry_data[class_id] = {}
			local class_str = class_id == "all" and "all" or select(1, GetClassInfo(class_id))
			entry_data[class_id]["Class"] = class_str
			entry_data[class_id]["#"] = "-"
			entry_data[class_id]["%"] = "-"
			entry_data[class_id]["Avg."] = "-"
		else
			local class_str = ""
			if class_id ~= "all" then
				class_str, _, _ = GetClassInfo(class_id)
			else
				class_str = "all"
			end
			entry_data[class_id] = {}
			entry_data[class_id]["Class"] = class_str
			entry_data[class_id]["#"] = v["num_entries"]
			if total_creature_entry["num_entries"] > 0 then
				entry_data[class_id]["%"] = string.format(
					"%.1f",
					v["num_entries"] / total_creature_entry["num_entries"] * 100.0
				) .. "%"
			else
				entry_data[class_id]["%"] = "-"
			end
			entry_data[class_id]["Avg."] = string.format("%.1f", v["avg_lvl"])
		end
	end

	if average_class_container.configure_for == "map" then
		for k, class_id in pairs(class_tbl) do
			createEntryData(class_id)
		end
		createEntryData("all")
	elseif average_class_container.configure_for == "creature" then
		local creature_id = current_map_id
		for k, class_id in pairs(class_tbl) do
			createEntryDataForCreature(class_id, creature_id)
		end
		createEntryDataForCreature("all", creature_id)
	end

	for k, class_id in pairs(class_tbl) do
		for _, v in ipairs(average_class_subtitles) do
			average_class_font_strings[class_id][v[1]]:SetText(entry_data[class_id][v[1]])
		end
	end
	for _, v in ipairs(average_class_subtitles) do
		average_class_font_strings["all"][v[1]]:SetText(entry_data["all"][v[1]])
	end

	average_class_container:SetScript("OnHide", function()
		average_class_container.heading:Hide()
		average_class_container.left:Hide()
		average_class_container.right:Hide()
		for _, v in ipairs(average_class_subtitles) do
			average_class_header_font_strings[v[1]]:Hide()
		end
		for k, class_id in pairs(class_tbl) do
			for _, v in ipairs(average_class_subtitles) do
				average_class_font_strings[class_id][v[1]]:Hide()
			end
		end
	end)

	average_class_container:SetScript("OnShow", function()
		average_class_container.heading:Show()
		average_class_container.left:Show()
		average_class_container.right:Show()
		for _, v in ipairs(average_class_subtitles) do
			average_class_header_font_strings[v[1]]:Show()
		end
		for k, class_id in pairs(class_tbl) do
			for _, v in ipairs(average_class_subtitles) do
				average_class_font_strings[class_id][v[1]]:Show()
			end
		end
	end)
end

function Deathlog_AverageClassContainer()
	return average_class_container
end
