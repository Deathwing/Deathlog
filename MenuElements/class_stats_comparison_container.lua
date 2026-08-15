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
local MAX_PLAYER_LEVEL = DeathNotificationLib.MAX_PLAYER_LEVEL
local deathlog_class_colors = DeathNotificationLib.CLASS_COLORS
---@type MenuElementContainer
local average_class_container = CreateFrame("Frame")
average_class_container:SetSize(100, 100)
average_class_container:Show()

local class_font = Deathlog_L.class_font

local class_tbl = Deathlog_class_tbl

local green_shade = "ff50c878"

local steps = MAX_PLAYER_LEVEL / 10
local average_class_subtitles = {
	{ "Class", 20, "LEFT", 60 },
	{ "# Deaths", 80, "LEFT", 40 },
	{ "% of all", 150, "LEFT", 50 },
	{ "Avg. Lvl.", 200, "LEFT", 50 },
}
for i = 1, steps do
	table.insert(average_class_subtitles, { tostring(i * 10), 280 + (i - 1) * 50, "LEFT", 50 })
end

local average_class_header_font_strings = {}
for _, v in ipairs(average_class_subtitles) do
	average_class_header_font_strings[v[1]] = average_class_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	average_class_header_font_strings[v[1]]:SetPoint("TOPLEFT", average_class_container, "TOPLEFT", v[2], 2)
	average_class_header_font_strings[v[1]]:SetFont(class_font, 15, "")
	average_class_header_font_strings[v[1]]:SetJustifyH(v[3])
	average_class_header_font_strings[v[1]]:SetWordWrap(false)
	average_class_header_font_strings[v[1]]:SetWidth(100)
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
	average_class_font_strings["all"][v[1]]:SetWidth(100)
	average_class_font_strings["all"][v[1]]:SetTextColor(1, 1, 1, 1)
end

local getFilteredClassEntry = Deathlog_getFilteredClassEntry

function average_class_container.updateMenuElement(scroll_frame, inc_class_id, stats_tbl, setMapRegion, model, view)
	if model == nil then
		model = "Kaplan-Meier"
	end

	if view == nil then
		view = "Survival"
	end

	if not stats_tbl or not stats_tbl["stats"] then
		average_class_container:Hide()
		return
	end

	average_class_container:Show()
	local entry_data = {}
	local map_id = Deathlog_normalize_map_id_for_stats(Deathlog_ROOT_MAP_ID)
	local _stats = stats_tbl["stats"]
	local selected_source_kind = Deathlog_NormalizeSourceKind(stats_tbl["selected_source_kind"])
	local log_normal_params = stats_tbl["log_normal_params"]
	local class_log_normal_params = log_normal_params and log_normal_params["all"]
	local kaplan_meier = stats_tbl["kaplan_meier"]
	if average_class_container.configure_for == "map" and _stats["all"][map_id] == nil then
		return
	end
	local total_map_entry = getFilteredClassEntry(_stats["all"][map_id]["all"], selected_source_kind)
	local selected_class_entry = getFilteredClassEntry(_stats["all"][map_id][inc_class_id], selected_source_kind)

	average_class_container:SetParent(scroll_frame.frame)
	average_class_container:ClearAllPoints()
	average_class_container:SetPoint("TOPLEFT", scroll_frame.frame, "TOPLEFT", 0, -330)
	average_class_container:SetWidth(600)
	average_class_container:SetHeight(200)

	if average_class_container.heading == nil then
		average_class_container.heading = average_class_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		average_class_container.heading:SetText("Compare")
		average_class_container.heading:SetFont(class_font, 18, "")
		average_class_container.heading:SetJustifyV("TOP")
		average_class_container.heading:SetTextColor(0.9, 0.9, 0.9)
		average_class_container.heading:SetPoint("TOP", average_class_container, "TOP", -10, 30)
		average_class_container.heading:Show()
	end

	if average_class_container.milestone_text == nil then
		average_class_container.milestone_text =
			average_class_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		average_class_container.milestone_text:SetText("Probability of reaching milestone (P(X > x))")
		average_class_container.milestone_text:SetFont(class_font, 12, "")
		average_class_container.milestone_text:SetJustifyV("TOP")
		average_class_container.milestone_text:SetPoint("TOP", average_class_container, "TOP", 120, 13)
		average_class_container.milestone_text:Show()
	end

	if view == "Survival" then
		average_class_container.milestone_text:SetText("Probability of reaching milestone (P(X > x))")
	elseif view == "Hazard" then
		average_class_container.milestone_text:SetText(
			"Probability of reaching milestone from last milestone (P(X > x | X=x-10))"
		)
	end

	if average_class_container.x_hint == nil then
		average_class_container.x_hint = average_class_container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		average_class_container.x_hint:SetText("E.g. 1.7x means 1.7 more likely to reach milestone")
		average_class_container.x_hint:SetFont(class_font, 12, "")
		average_class_container.x_hint:SetTextColor(0.7, 0.7, 0.7)
		average_class_container.x_hint:SetJustifyV("TOP")
		average_class_container.x_hint:SetPoint("TOP", average_class_container, "TOP", 120, -170)
		average_class_container.x_hint:Show()
	end
	average_class_container.x_hint:SetText("E.g. 1.7x means 1.7 more likely to reach milestone")

	if average_class_container.left == nil then
		average_class_container.left = average_class_container:CreateTexture(nil, "BACKGROUND")
		average_class_container.left:SetHeight(8)
		average_class_container.left:SetPoint("LEFT", average_class_container.heading, "LEFT", -200, 0)
		average_class_container.left:SetPoint("RIGHT", average_class_container.heading, "LEFT", -25, 0)
		average_class_container.left:SetTexture(137057)
		average_class_container.left:SetTexCoord(0.81, 0.94, 0.5, 1)
	end

	if average_class_container.right == nil then
		average_class_container.right = average_class_container:CreateTexture(nil, "BACKGROUND")
		average_class_container.right:SetHeight(8)
		average_class_container.right:SetPoint("RIGHT", average_class_container.heading, "RIGHT", 200, 0)
		average_class_container.right:SetPoint("LEFT", average_class_container.heading, "RIGHT", 25, 0)
		average_class_container.right:SetTexture(137057)
		average_class_container.right:SetTexCoord(0.81, 0.94, 0.5, 1)
	end

	local function buildClassCurve(class_id)
		local cdf = {}
		local contributor_count = 0

		if model == "LogNormal" then
			if not class_log_normal_params then
				return nil
			end
			if class_id == "all" then
				for _, candidate_class_id in pairs(Deathlog_class_tbl) do
					local params = class_log_normal_params[candidate_class_id]
					if params then
						local class_cdf = Deathlog_CalculateCDF2(params[1], params[2])
						contributor_count = contributor_count + 1
						for i = 1, MAX_PLAYER_LEVEL do
							cdf[i] = (cdf[i] or 0) + class_cdf[i]
						end
					end
				end
				if contributor_count == 0 then
					return nil
				end
				for i = 1, MAX_PLAYER_LEVEL do
					cdf[i] = cdf[i] / contributor_count
				end
				return cdf
			end

			local params = class_log_normal_params[class_id]
			if not params then
				return nil
			end
			return Deathlog_CalculateCDF2(params[1], params[2])
		end

		if not kaplan_meier then
			return nil
		end
		if class_id == "all" then
			for _, candidate_class_id in pairs(Deathlog_class_tbl) do
				local class_cdf = kaplan_meier[candidate_class_id]
				if class_cdf then
					contributor_count = contributor_count + 1
					for i = 1, MAX_PLAYER_LEVEL do
						cdf[i] = (cdf[i] or 0) + (class_cdf[i] or class_cdf[60] or 0)
					end
				end
			end
			if contributor_count == 0 then
				return nil
			end
			for i = 1, MAX_PLAYER_LEVEL do
				cdf[i] = cdf[i] / contributor_count
			end
			return cdf
		end

		return kaplan_meier[class_id]
	end

	local function getCurveValue(cdf, x)
		if not cdf then
			return nil
		end

		if view == "Survival" then
			if model == "LogNormal" then
				return (1 - (cdf[x] or 0)) * 100
			end
			return (cdf[x] or cdf[60] or 0) * 100
		end

		if view == "Hazard" then
			if model == "LogNormal" then
				local current = 1 - (cdf[x] or 0)
				local previous = 1 - (cdf[x - 10] or 0)
				if previous <= 0 then
					return nil
				end
				return current / previous * 100
			end

			local current = cdf[x] or cdf[60] or 0
			local previous = cdf[x - 10] or cdf[60] or 0
			if previous <= 0 then
				return nil
			end
			return current / previous * 100
		end

		return nil
	end

	local s_class_info = {}
	s_class_info["# Deaths"] = selected_class_entry and selected_class_entry["num_entries"] or 0
	s_class_info["% of all"] = 0
	if selected_class_entry and total_map_entry and total_map_entry["num_entries"] > 0 then
		s_class_info["% of all"] = selected_class_entry["num_entries"] / total_map_entry["num_entries"] * 100.0
	end
	s_class_info["Avg. Lvl."] = selected_class_entry and selected_class_entry["avg_lvl"] or 0

	local selected_curve = buildClassCurve(inc_class_id)
	for i = 1, steps do
		s_class_info[tostring(i * 10)] = getCurveValue(selected_curve, i * 10)
	end

	local function createEntryData(class_id)
		local v = getFilteredClassEntry(_stats["all"][map_id][class_id], selected_source_kind)
		if v == nil or class_id == inc_class_id or selected_class_entry == nil or total_map_entry == nil then
			entry_data[class_id] = {}
			local class_str = class_id == "all" and "all" or select(1, GetClassInfo(class_id))
			entry_data[class_id]["Class"] = class_str
			entry_data[class_id]["# Deaths"] = "-"
			entry_data[class_id]["% of all"] = "-"
			entry_data[class_id]["Avg. Lvl."] = "-"
			for i = 1, steps do
				entry_data[class_id][tostring(i * 10)] = "-"
			end
			return
		end

		local class_str = class_id == "all" and "all" or select(1, GetClassInfo(class_id))
		entry_data[class_id] = {}
		entry_data[class_id]["Class"] = class_str

		local death_delta = s_class_info["# Deaths"] - v["num_entries"]
		if death_delta > 0 then
			entry_data[class_id]["# Deaths"] = "|c" .. green_shade .. "+" .. tostring(death_delta) .. "|r"
		else
			entry_data[class_id]["# Deaths"] = "|cffff0000" .. tostring(death_delta) .. "|r"
		end

		local class_pct = nil
		if total_map_entry["num_entries"] > 0 and v["num_entries"] > 0 then
			class_pct = v["num_entries"] / total_map_entry["num_entries"] * 100.0
		end
		if class_pct and class_pct > 0 and s_class_info["% of all"] > 0 then
			local pct_ratio = s_class_info["% of all"] / class_pct
			if pct_ratio > 1 then
				entry_data[class_id]["% of all"] = "|c" .. green_shade .. string.format("%.1f", pct_ratio) .. "x|r"
			else
				entry_data[class_id]["% of all"] = "|cffff0000" .. string.format("%.1f", pct_ratio) .. "x|r"
			end
		else
			entry_data[class_id]["% of all"] = "-"
		end

		local avg_delta = s_class_info["Avg. Lvl."] - v["avg_lvl"]
		if avg_delta > 0 then
			entry_data[class_id]["Avg. Lvl."] = "|c" .. green_shade .. "+" .. string.format("%.1f", avg_delta) .. "|r"
		else
			entry_data[class_id]["Avg. Lvl."] = "|cffff0000" .. string.format("%.1f", avg_delta) .. "|r"
		end

		local comparison_curve = buildClassCurve(class_id)
		for i = 1, steps do
			local lvl_key = tostring(i * 10)
			local selected_value = s_class_info[lvl_key]
			local comparison_value = getCurveValue(comparison_curve, i * 10)
			if selected_value ~= nil and comparison_value and comparison_value > 0 then
				local ratio = selected_value / comparison_value
				if ratio > 1 then
					entry_data[class_id][lvl_key] = "|c" .. green_shade .. string.format("%.1f", ratio) .. "x|r"
				else
					entry_data[class_id][lvl_key] = "|cffff0000" .. string.format("%.1f", ratio) .. "x|r"
				end
			else
				entry_data[class_id][lvl_key] = "-"
			end
		end
	end

	for _, class_id in pairs(class_tbl) do
		createEntryData(class_id)
	end
	createEntryData("all")

	for k, class_id in pairs(class_tbl) do
		for _, v in ipairs(average_class_subtitles) do
			if inc_class_id == class_id then
				average_class_font_strings[class_id][v[1]]:SetTextColor(
					deathlog_class_colors[k].r,
					deathlog_class_colors[k].g,
					deathlog_class_colors[k].b
				)
			else
				average_class_font_strings[class_id][v[1]]:SetTextColor(1, 1, 1)
			end
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
		for _, class_id in pairs(class_tbl) do
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
		for _, class_id in pairs(class_tbl) do
			for _, v in ipairs(average_class_subtitles) do
				average_class_font_strings[class_id][v[1]]:Show()
			end
		end
	end)
end

function Deathlog_ClassStatsContainer()
	return average_class_container
end
