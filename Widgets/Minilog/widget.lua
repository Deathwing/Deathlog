---@diagnostic disable: invisible
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
local id_to_instance = DeathNotificationLib.ID_TO_INSTANCE
local deathlog_class_colors = DeathNotificationLib.CLASS_ID_TO_COLOR

local MAX_PLAYER_LEVEL = DeathNotificationLib.MAX_PLAYER_LEVEL
local ace_refresh_timer_handle = nil
local entry_cache = {}
local font_handle = nil
local class_bg_tex = nil

local main_font = Deathlog_L.main_font

-- Many of the bundled decorative fonts (and some locale defaults) do not contain
-- glyphs for extended-Latin / accented characters (e.g. ö, ü, é, ñ), so names with
-- special characters render as empty boxes. STANDARD_TEXT_FONT is provided by
-- Blizzard's GameFonts.xml and is guaranteed to have full glyph coverage for the
-- active client locale. Use it as a fallback whenever a requested font fails to load.
--
-- FRIZQT__.TTF (the western default/fallback) renders noticeably larger than the
-- old blei00d.TTF default at the same point size, which made the minilog rows look
-- oversized. Compensate by scaling FRIZQT down so it matches the previous visual
-- size at any user-configured point size, without changing the size slider's value.
local DEATHLOG_FRIZQT_SCALE = 0.85
local function Deathlog_NormalizeFontSize(font_path, font_size)
	if type(font_path) == "string" and font_path:find("FRIZQT__", 1, true) then
		return math.max(1, math.floor(font_size * DEATHLOG_FRIZQT_SCALE + 0.5))
	end
	return font_size
end

-- FRIZQT__.TTF has no Cyrillic glyphs, so Russian names (which appear on western
-- servers too) render as boxes. FRIZQT___CYR.TTF ships on all western clients and
-- covers Latin + Cyrillic, so swap to it only for names that actually contain
-- Cyrillic. Detection is a single C-level byte scan: Cyrillic (U+0400–U+04FF) is
-- encoded in UTF-8 with lead byte 0xD0 (208) or 0xD1 (209), so a name containing
-- one of those bytes is treated as Cyrillic. This is cheap and runs per rendered
-- name without iterating the whole string in Lua.
local DEATHLOG_CYRILLIC_FONT = "Fonts\\FRIZQT___CYR.TTF"
local function Deathlog_TextHasCyrillic(text)
	return type(text) == "string" and text:find("[\208\209]") ~= nil
end

local function Deathlog_SetFontWithFallback(font_string, font_path, font_size, font_flags)
	if font_string == nil then
		return font_path
	end
	local ok = font_string:SetFont(font_path, Deathlog_NormalizeFontSize(font_path, font_size), font_flags or "")
	if not ok then
		local fallback = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
		font_string:SetFont(fallback, Deathlog_NormalizeFontSize(fallback, font_size), font_flags or "")
		return fallback
	end
	return font_path
end

-- Apply font to a fontstring, swapping to a Cyrillic-capable font when the text to
-- be displayed contains Cyrillic. Only calls SetFont when the script class of the
-- text changes (tracked via `_dl_cyrillic`), so repeated renders of the same kind
-- of name are essentially free.
local function Deathlog_ApplyFontForText(font_string, text, font_path, font_size, font_flags)
	if font_string == nil then
		return font_path
	end
	local needs_cyrillic = Deathlog_TextHasCyrillic(text)
	-- Fast path: nothing relevant changed since last apply.
	if font_string._dl_cyrillic == needs_cyrillic
		and font_string._dl_font == font_path
		and font_string._dl_size == font_size
	then
		return font_string._dl_applied or font_path
	end
	font_string._dl_cyrillic = needs_cyrillic
	font_string._dl_font = font_path
	font_string._dl_size = font_size
	local applied
	if needs_cyrillic then
		font_string:SetFont(DEATHLOG_CYRILLIC_FONT, Deathlog_NormalizeFontSize(DEATHLOG_CYRILLIC_FONT, font_size), font_flags or "")
		applied = DEATHLOG_CYRILLIC_FONT
	else
		applied = Deathlog_SetFontWithFallback(font_string, font_path, font_size, font_flags)
	end
	font_string._dl_applied = applied
	return applied
end

local tmap = {
	["WARRIOR"] = { 0, 0.25, 0, 0.25 },
	["MAGE"] = { 0.25, 0.5, 0, 0.25 },
	["ROGUE"] = { 0.5, 0.75, 0, 0.25 },
	["DRUID"] = { 0.75, 1, 0, 0.25 },
	["HUNTER"] = { 0, 0.25, 0.25, 0.5 },
	["SHAMAN"] = { 0.25, 0.5, 0.25, 0.5 },
	["PRIEST"] = { 0.5, 0.75, 0.25, 0.5 },
	["WARLOCK"] = { 0.75, 1, 0.25, 0.5 },
	["PALADIN"] = { 0, 0.25, 0.5, 0.75 },
}

local rmap = {
	["Human"] = { 0, 0.25, 0, 0.25 },
	["Dwarf"] = { 0.25, 0.5, 0, 0.25 },
	["Gnome"] = { 0.5, 0.75, 0, 0.25 },
	["NightElf"] = { 0.75, 1, 0, 0.25 },
	["Tauren"] = { 0, 0.25, 0.25, 0.5 },
	["Scourge"] = { 0.25, 0.5, 0.25, 0.5 },
	["Troll"] = { 0.5, 0.75, 0.25, 0.5 },
	["Orc"] = { 0.75, 1, 0.25, 0.5 },
}
if GetExpansionLevel and GetExpansionLevel() >= 1 then
	rmap["BloodElf"] = { 0, 0.25, 0.5, 0.75 }
	rmap["Draenei"] = { 0.25, 0.5, 0.5, 0.75 }
end

local presets = {
	["Hardcore (legacy)"] = "Hardcore (legacy)",
	["concise"] = "concise",
	["Yazpad"] = "Yazpad",
	["ChefCarlos"] = "ChefCarlos",
}

local LSM30 = LibStub("LibSharedMedia-3.0", true)
local default_font = Deathlog_L.mini_log_font
local widget_name = "minilog"

local fonts = LSM30:HashTable("font")
fonts["default_font"] = default_font
-- These fonts ship with DeathNotificationLib, which may live either as its own
-- top-level AddOn (the released/split layout) or embedded under Deathlog\Libs\
-- (the development layout). DNL auto-detects its own location at load time and
-- publishes it as MEDIA_PATH, so never hardcode the path here.
local font_base_path = DeathNotificationLib.MEDIA_PATH .. "Fonts\\"
fonts["BreatheFire"] = font_base_path .. "BreatheFire.ttf"
fonts["BlackChancery"] = font_base_path .. "BLKCHCRY.TTF"
fonts["ArgosGeorge"] = font_base_path .. "ArgosGeorge.ttf"
fonts["GothicaBook"] = font_base_path .. "Gothica-Book.ttf"
fonts["Immortal"] = font_base_path .. "IMMORTAL.ttf"
fonts["BlackwoodCastle"] = font_base_path .. "BlackwoodCastle.ttf"
fonts["Alegreya"] = font_base_path .. "alegreya.regular.ttf"
fonts["Cathedral"] = font_base_path .. "Cathedral.ttf"
fonts["FletcherGothic"] = font_base_path .. "FletcherGothic-pwy.ttf"
fonts["GothamNarrowUltra"] = font_base_path .. "GothamNarrowUltra.ttf"

local themes = {
	["None"] = "None",
	["Parchment"] = "Parchment",
	["DeathKnightFrost"] = "Death Knight (Frost)",
	["DemonHunter"] = "Demon Hunter",
	["Druid"] = "Druid",
	["Hunter"] = "Hunter",
	["MageArcane"] = "Mage (Arcane)",
	["Monk"] = "Monk",
	["Paladin"] = "Paladin",
	["Priest"] = "Priest",
	["PriestShadow"] = "Priest (Shadow)",
	["Rogue"] = "Rogue",
	["Shaman"] = "Shaman",
	["Shadow"] = "Shadow",
	["Warlock"] = "Warlock",
	["Warrior"] = "Warrior",
}

local artifact_themes = {}
for k in pairs(themes) do
	if k ~= "None" and k ~= "Parchment" then
		artifact_themes[k] = true
	end
end

local AceGUI = LibStub("AceGUI-3.0")
local death_log_icon_frame = CreateFrame("frame")
death_log_icon_frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
death_log_icon_frame:SetSize(40, 40)
death_log_icon_frame:SetMovable(true)
death_log_icon_frame:EnableMouse(true)
death_log_icon_frame:Show()

local black_round_tex = death_log_icon_frame:CreateTexture(nil, "OVERLAY")
black_round_tex:SetPoint("CENTER", death_log_icon_frame, "CENTER", -5, 4)
black_round_tex:SetParent(UIParent)
black_round_tex:SetDrawLayer("OVERLAY", 2)
black_round_tex:SetHeight(40)
black_round_tex:SetWidth(40)
black_round_tex:SetTexture("Interface\\PVPFrame\\PVP-Separation-Circle-Cooldown-overlay")

local hc_fire_tex = death_log_icon_frame:CreateTexture(nil, "OVERLAY")
hc_fire_tex:SetParent(UIParent)
hc_fire_tex:SetPoint("CENTER", death_log_icon_frame, "CENTER", -4, 4)
hc_fire_tex:SetDrawLayer("OVERLAY", 3)
hc_fire_tex:SetHeight(25)
hc_fire_tex:SetWidth(25)
hc_fire_tex:SetTexture("Interface\\TARGETINGFRAME\\UI-TargetingFrame-Skull")

local gold_ring_tex = death_log_icon_frame:CreateTexture(nil, "OVERLAY")
gold_ring_tex:SetParent(UIParent)
gold_ring_tex:SetPoint("CENTER", death_log_icon_frame, "CENTER", 0, 0)
gold_ring_tex:SetDrawLayer("OVERLAY", 4)
gold_ring_tex:SetHeight(50)
gold_ring_tex:SetWidth(50)
gold_ring_tex:SetTexture("Interface\\COMMON\\BlueMenuRing")

death_log_icon_frame:HookScript("OnShow", function(self, button)
	black_round_tex:Show()
	hc_fire_tex:Show()
	gold_ring_tex:Show()
end)

death_log_icon_frame:HookScript("OnHide", function(self, button)
	black_round_tex:Hide()
	hc_fire_tex:Hide()
	gold_ring_tex:Hide()
end)

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
local minilog_type ="Deathlog_MiniLog" ---@type AceGUIWidgetType|AceGUIContainerType 
local death_log_frame = AceGUI:Create(minilog_type) ---@type DeathlogMiniLog
death_log_frame.frame:SetMovable(false)
death_log_frame.frame:EnableMouse(false)
death_log_frame:SetTitle("Deathlog")
Deathlog_registerReportDemoteFrame(death_log_frame.frame)
Deathlog_SetFontWithFallback(death_log_frame.titletext, Deathlog_L.mini_log_font, 19, "THICKOUTLINE")

Deathlog_createInfoButton(death_log_frame, true, 28, -2)

local subtitle_metadata = {
	["ColoredName"] = {
		"Name",
		80,
		function(_entry)
			local class_id = _entry.player_data["class_id"]
			if class_id then
				if deathlog_class_colors[class_id] then
					return "|c"
						.. deathlog_class_colors[class_id].colorStr
						.. (_entry.player_data["name"] or "")
						.. "|r"
				end
			end
			return _entry.player_data["name"] or ""
		end,
	},
	["Zone"] = {
		"Zone",
		70,
		function(_entry)
			if _entry.player_data["map_id"] then
				local mapinfo = C_Map.GetMapInfo(_entry.player_data["map_id"])
				if mapinfo then return mapinfo.name or "" end
				return ""
			end
			if _entry.player_data["instance_id"] then
				return id_to_instance[_entry.player_data["instance_id"]] or nil
			end
			return ""
		end,
	},
	["Name"] = {
		"Name",
		80,
		function(_entry)
			return _entry.player_data["name"] or ""
		end,
	},
	["Source"] = {
		"Source",
		120,
		function(_entry)
			return DeathlogGetCachedSource(_entry.player_data)
		end,
	},
	["Class"] = {
		"Class",
		60,
		function(_entry)
			local class_id = _entry.player_data["class_id"]
			if class_id then
				local class_str = GetClassInfo(class_id)
				if deathlog_class_colors[class_id] then
					return "|c"
						.. deathlog_class_colors[class_id].colorStr
						.. (class_str or "")
						.. "|r"
				end
				return class_str or ""
			end
			return ""
		end,
	},
	["Race"] = {
		"Race",
		60,
		function(_entry)
			if _entry.player_data["race_id"] == nil then
				return ""
			end
			local race_info = C_CreatureInfo.GetRaceInfo(_entry.player_data["race_id"])
			if race_info then
				return race_info.raceName or ""
			end
			return ""
		end,
	},
	["Lvl"] = {
		"Lvl",
		40,
		function(_entry)
			return _entry.player_data["level"] or ""
		end,
	},
	["Guild"] = {
		"Guild",
		40,
		function(_entry)
			return _entry.player_data["guild"] or ""
		end,
	},
	["Playtime"] = {
		"Playtime",
		70,
		function(_entry)
			return DeathNotificationLib.FormatPlaytime(_entry.player_data["played"]) or ""
		end,
	},
	["LastWords"] = {
		"LastWords",
		100,
		function(_entry)
			return _entry.player_data["last_words"] or ""
		end,
	},
	["ReportedBy"] = {
		"ReportedBy",
		90,
		function(_entry)
			return Deathlog_getDisplaySender(_entry.player_data) or ""
		end,
	},
	["ClassLogo1"] = {
		"ClassLogo1",
		20,
		function(_entry)
      if _entry.player_data["class_id"] == nil then return "" end
			local _, class_token, _ = GetClassInfo(_entry.player_data["class_id"])
			if class_token and tmap[class_token] then
				local msg = "|TInterface\\WorldStateFrame\\ICONS-CLASSES:16:16:0:0:64:64:"
					.. tmap[class_token][1] * 64
					.. ":"
					.. tmap[class_token][2] * 64
					.. ":"
					.. tmap[class_token][3] * 64
					.. ":"
					.. tmap[class_token][4] * 64
					.. "|t"

				return msg
			else
				return ""
			end
		end,
	},
	["ClassLogo2"] = {
		"ClassLogo2",
		20,
		function(_entry)
      if _entry.player_data["class_id"] == nil then return "" end
			local _, class_token, _ = GetClassInfo(_entry.player_data["class_id"])
			if class_token and tmap[class_token] then
				local msg = "|TInterface\\ARENAENEMYFRAME\\UI-CLASSES-CIRCLES:16:16:0:0:64:64:"
					.. tmap[class_token][1] * 64
					.. ":"
					.. tmap[class_token][2] * 64
					.. ":"
					.. tmap[class_token][3] * 64
					.. ":"
					.. tmap[class_token][4] * 64
					.. "|t"

				return msg
			else
				return ""
			end
		end,
	},
	["RaceLogoSquare"] = {
		"RaceLogoSquare",
		20,
		function(_entry)
			if _entry.player_data["race_id"] == nil then
				return ""
			end
			local race_info = C_CreatureInfo.GetRaceInfo(_entry.player_data["race_id"])
			if race_info and race_info.clientFileString and rmap[race_info.clientFileString] and _entry.player_data["level"] then
				local msg = "|TInterface\\Glues\\CHARACTERCREATE\\UI-CHARACTERCREATE-RACES.PNG:16:16:0:0:64:64:"
					.. rmap[race_info.clientFileString][1] * 64
					.. ":"
					.. rmap[race_info.clientFileString][2] * 64
					.. ":"
					.. rmap[race_info.clientFileString][3] * 64 + (_entry.player_data["level"] % 2) * 32
					.. ":"
					.. rmap[race_info.clientFileString][4] * 64 + (_entry.player_data["level"] % 2) * 32
					.. "|t"

				return msg
			else
				return ""
			end
		end,
	},
}

local subtitle_data = {}

local function setSubtitleData()
	subtitle_data = {}
	if deathlog_settings[widget_name] == nil or deathlog_settings[widget_name]["columns"] == nil then
		return
	end
	for _, k in ipairs(deathlog_settings[widget_name]["columns"]) do
		local meta = subtitle_metadata[k]
		-- Identify each column by its *slot position*, not by its type or its display
		-- label. Neither of those is unique: the same column type may be selected in
		-- several slots (e.g. Name twice), and different types can share a label
		-- (both "Name" and "ColoredName" display as "Name"). Keying by anything but
		-- position makes two slots share one fontstring, so a column renders blank.
		if meta then
			local slot = #subtitle_data + 1
			subtitle_data[slot] = { meta[1], meta[2], meta[3], key = slot, column_type = k }
		end
	end
	death_log_frame:SetSubTitle(subtitle_data)

	local _x_offset = deathlog_settings[widget_name]["entry_x_offset"] or 0
	local _y_offset = deathlog_settings[widget_name]["entry_y_offset"] or 0
	death_log_frame.content:SetPoint("TOPLEFT", 3 + _x_offset, -33 + _y_offset)
	death_log_frame.content:SetPoint("BOTTOMRIGHT", 15, 6)
	death_log_frame:SetSubTitleOffset(_x_offset, _y_offset, subtitle_data)
end

death_log_frame:SetLayout("Fill")
death_log_frame.frame:SetSize(255, 125)
death_log_frame:Show()

local scroll_frame = AceGUI:Create("ScrollFrame") ---@type AceGUIScrollFrame
scroll_frame:SetLayout("List")
death_log_frame:AddChild(scroll_frame)

local selected = nil
local row_entry = {}
local loaded = false
-- Cached resolved entry font/size so per-entry rendering (setEntry) can pick the
-- right font (incl. Cyrillic swap) without re-reading settings on every call.
-- Kept in sync by applyFont().
local current_entry_font_path = default_font
local current_entry_font_size = 14
local current_entry_font_flags = ""

-- (Re)create and position the per-column fontstrings of a single row entry to
-- match the current `subtitle_data`. Called both when rows are first built and
-- whenever the user changes the column selection, since the set of columns (and
-- therefore the set of required fontstrings) can change at any time.
-- Fontstrings are keyed by column *slot* (`v.key`), never by column type or
-- display label: the same type may occupy several slots at once, and different
-- types can share a label, so any other key would make two columns collide.
local function layoutEntryFontStrings(_entry)
	if _entry == nil or _entry.font_strings == nil then
		return
	end

	-- Retire fontstrings for columns that are no longer shown. They cannot be
	-- destroyed in WoW, so blank and hide them and drop the reference.
	local in_use = {}
	for _, v in ipairs(subtitle_data) do
		in_use[v.key] = true
	end
	for key, fs in pairs(_entry.font_strings) do
		if not in_use[key] then
			fs:SetText("")
			fs:Hide()
			_entry.font_strings[key] = nil
		end
	end

	local current_column_offset = 15
	for idx, v in ipairs(subtitle_data) do
		local fs = _entry.font_strings[v.key]
		if fs == nil then
			fs = _entry.frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
			_entry.font_strings[v.key] = fs
			Deathlog_SetFontWithFallback(fs, Deathlog_L.mini_log_font, 14, "")
		end
		fs:Show()
		fs:ClearAllPoints()
		fs:SetPoint("LEFT", _entry.frame, "LEFT", current_column_offset, 0)
		fs:SetWordWrap(false)
		fs:SetJustifyH("LEFT")
		-- The last column is left unconstrained so long values aren't truncated.
		if idx + 1 <= #subtitle_data then
			fs:SetWidth(v[2])
		else
			fs:SetWidth(0)
		end
		fs:SetTextColor(1, 1, 1)
		current_column_offset = current_column_offset + v[2]
	end
end

local function setupRowEntries()
	loaded = true
	row_entry = {}
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

		local function canCheckSpoof()
			if not death_tomb_frame.clicked_name then
				return false
			end
			return true
		end

		local function checkSpoof()
			if canCheckSpoof() then
				C_FriendList.SetWhoToUi(false) -- force chat output
				C_FriendList.SendWho(death_tomb_frame.clicked_name)
			end
		end

		if level == 1 then
			info.text, info.hasArrow, info.func, info.disabled = "Whisper player", false, whisperPlayer, not canWhisperPlayer()
			UIDropDownMenu_AddButton(info)
			info.text, info.hasArrow, info.func, info.disabled = "Show death location", false, openWorldMap, not canOpenWorldMap()
			UIDropDownMenu_AddButton(info)
			info.text, info.hasArrow, info.func, info.disabled = "Block user", false, blockUser, not canBlockUser()
			UIDropDownMenu_AddButton(info)
			info.text, info.hasArrow, info.func, info.disabled = "Inspect user", false, checkSpoof, not canCheckSpoof()
			UIDropDownMenu_AddButton(info)

			Deathlog_addContextMenuReportItems(death_tomb_frame.clicked_player_data)
		end
	end

	for i = 1, 20 do
		local idx = 21 - i
		row_entry[idx] = AceGUI:Create("InteractiveLabel")
		local _entry = row_entry[idx]
		_entry:SetHighlight("Interface\\Glues\\CharacterSelect\\Glues-CharacterSelect-Highlight")
		_entry.font_strings = {}
		layoutEntryFontStrings(_entry)

		_entry.background = _entry.frame:CreateTexture(nil, "OVERLAY")
		_entry.background:SetPoint("CENTER", _entry.frame, "CENTER", 0, 0)
		_entry.background:SetDrawLayer("OVERLAY", 2)
		_entry.background:SetVertexColor(0.5, 0.5, 0.5, (i % 2) / 10)
		_entry.background:SetHeight(16)
		_entry.background:SetWidth(1000)
		_entry.background:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")

		_entry:SetHeight(40)
		_entry:SetFullWidth(true)
		_entry:SetFont(main_font, 16, "")
		_entry:SetColor(1, 1, 1)
		_entry:SetText(" ")

		function _entry:deselect()
			for _, v in pairs(_entry.font_strings) do
				-- v:SetTextColor(1, 1, 1)
			end
		end

		function _entry:select()
			selected = idx
			for _, v in pairs(_entry.font_strings) do
				-- v:SetTextColor(1, 1, 0)
			end
		end

		_entry:SetCallback("OnLeave", function(widget)
			if _entry.player_data == nil then
				return
			end
			GameTooltip:Hide()
		end)

		_entry:SetCallback("OnClick", function()
			if _entry.player_data == nil then
				return
			end
			local click_type = GetMouseButtonClicked()

			if click_type == "LeftButton" then
				if selected then
					row_entry[selected]:deselect()
				end
				_entry:select()
				if IsShiftKeyDown() then
					C_FriendList.SendWho(_entry["player_data"]["name"])
				end
			elseif click_type == "RightButton" then
				death_tomb_frame.map_id = _entry["player_data"]["map_id"]
				local x, y = Deathlog_parseMapPos(_entry["player_data"]["map_pos"])
                if x and y then
                    death_tomb_frame.coordinates = {x, y}
                else
                    death_tomb_frame.coordinates = nil
                end
				death_tomb_frame.clicked_name = _entry["player_data"]["name"]
				death_tomb_frame.clicked_player_data = _entry["player_data"]

				if not _G["WPDemoContextMenu"] then
					CreateFrame("Frame", "WPDemoContextMenu", UIParent, "UIDropDownMenuTemplate")
				end
				UIDropDownMenu_Initialize(WPDemoContextMenu, WPDropDownDemo_Menu, "MENU")
				ToggleDropDownMenu(1, nil, WPDemoContextMenu, "cursor", 3, -3)
			end
		end)

		_entry:SetCallback("OnEnter", function(widget)
			if _entry.player_data == nil then
				return
			end
			GameTooltip_SetDefaultAnchor(GameTooltip, WorldFrame)
			Deathlog_setTooltipFromEntry(_entry.player_data)
			GameTooltip:Show()
		end)

		scroll_frame:SetScroll(0)
		scroll_frame.scrollbar:Hide()
		scroll_frame:AddChild(_entry)
	end
end

local function setEntry(player_data, _entry)
	_entry.player_data = player_data
	for _, v in ipairs(subtitle_data) do
		local fs = _entry.font_strings[v.key]
		if fs then
			local text = v[3](_entry)
			fs:SetText(text)
			Deathlog_ApplyFontForText(fs, text, current_entry_font_path, current_entry_font_size, current_entry_font_flags)
		end
	end
end

local function shiftEntry(_entry_from, _entry_to)
	setEntry(_entry_from.player_data, _entry_to)
end

local function clearVisibleEntries()
	if selected and row_entry[selected] then
		row_entry[selected]:deselect()
	end
	selected = nil
	entry_cache = {}
	for _, widget in pairs(row_entry) do
		widget.player_data = nil
		for _, font_string in pairs(widget.font_strings) do
			font_string:SetText("")
		end
	end
end

function Deathlog_minilog_refreshEntries()
	if loaded == false then
		return
	end

	clearVisibleEntries()
	-- Only the first #row_entry entries are ever read below, so ask for just those.
	local ordered_entries = DeathlogOrderByFast(deathlog_data or {}, #row_entry)
	local max_visible_entries = math.min(#ordered_entries, #row_entry)
	for i = max_visible_entries, 1, -1 do
		Deathlog_widget_minilog_createEntry(ordered_entries[i])
	end
end

function Deathlog_widget_minilog_createEntry(player_data)
	if entry_cache[player_data["name"]] then
		return
	end
	local ws = deathlog_settings[widget_name]
	if
		ws
		and player_data["level"]
		and (
			tonumber(player_data["level"]) < (ws["min_lvl"] or 1)
			or tonumber(player_data["level"]) > (ws["max_lvl"] or 60)
		)
	then
		return
	end

	-- Guild filter check (using DeathNotificationLib)
	if ws then
		local filter_mode = ws["filter_mode"] or "all"
		if not DeathNotificationLib.PassesGuildFilterMode(player_data, filter_mode) then
			return
		end
	end

	if ws and not Deathlog_SourceMatchesKind(player_data, Deathlog_GetWidgetSourceKind(widget_name)) then
		return
	end

	entry_cache[player_data["name"]] = 1

	for i = 1, 19 do
		if row_entry[i + 1].player_data ~= nil then
			shiftEntry(row_entry[i + 1], row_entry[i])
			if selected and selected == i + 1 then
				row_entry[i + 1]:deselect()
				row_entry[i]:select()
			end
		end
	end
	setEntry(player_data, row_entry[20])
end
death_log_icon_frame:RegisterForDrag("LeftButton")
death_log_icon_frame:SetScript("OnDragStart", function(self, button)
	if deathlog_settings[widget_name] and deathlog_settings[widget_name]["lock"] then
		return
	end
	death_log_frame.frame:ClearAllPoints()
	self:StartMoving()
	death_log_frame.frame:SetPoint("TOPLEFT", death_log_icon_frame, "TOPLEFT", 10, -10)
end)
death_log_icon_frame:SetScript("OnDragStop", function(self)
	if deathlog_settings[widget_name] and deathlog_settings[widget_name]["lock"] then
		return
	end
	self:StopMovingOrSizing()
	if deathlog_settings[widget_name] == nil then deathlog_settings[widget_name] = {} end
	local x, y = self:GetCenter()
	local px = (GetScreenWidth() * UIParent:GetEffectiveScale()) / 2
	local py = (GetScreenHeight() * UIParent:GetEffectiveScale()) / 2
	deathlog_settings[widget_name]["pos_x"] = x - px
	deathlog_settings[widget_name]["pos_y"] = y - py
	death_log_frame.frame:SetPoint("TOPLEFT", death_log_icon_frame, "TOPLEFT", 10, -10)
end)

hooksecurefunc(death_log_frame.frame, "StopMovingOrSizing", function()
	if deathlog_settings[widget_name] == nil then deathlog_settings[widget_name] = {} end
	deathlog_settings[widget_name]["size_x"] = death_log_frame.frame:GetWidth()
	deathlog_settings[widget_name]["size_y"] = death_log_frame.frame:GetHeight()
end)

local function DeathFrameDropdown(frame, level, menuList)
	local info = UIDropDownMenu_CreateInfo()

	local function minimize()
		death_log_frame:Minimize()
	end

	local function maximize()
		death_log_frame:Maximize()
	end

	local function hide()
		Deathlog_minilog_setShown(false)
	end

	local function openSettings()
		if Deathlog_OpenSettings then
			Deathlog_OpenSettings()
		else
			Settings.OpenToCategory("Deathlog")
		end
	end

	if level == 1 then
		if death_log_frame:IsMinimized() then
			info.text, info.hasArrow, info.func = "Maximize", false, maximize
			UIDropDownMenu_AddButton(info)
		else
			info.text, info.hasArrow, info.func = "Minimize", false, minimize
			UIDropDownMenu_AddButton(info)
		end

		info.text, info.hasArrow, info.func = "Settings", false, openSettings
		UIDropDownMenu_AddButton(info)

		info.text, info.hasArrow, info.func = "Hide", false, hide
		UIDropDownMenu_AddButton(info)
	end
end

death_log_icon_frame:SetScript("OnMouseDown", function(self, button)
	if button == "RightButton" then
		local dropDown = CreateFrame("Frame", "death_frame_dropdown_menu", UIParent, "UIDropDownMenuTemplate")
		UIDropDownMenu_Initialize(dropDown, DeathFrameDropdown, "MENU")
		ToggleDropDownMenu(1, nil, dropDown, "cursor", 3, -3)
	end
end)

hooksecurefunc(WorldMapFrame, "OnMapChanged", function()
	death_tomb_frame:Hide()
end)
local default_text_color_r, default_text_color_g, default_text_color_b, default_text_color_a =
	GameFontNormal:GetTextColor()

local defaults = {
	["enable"] = true,
	["font"] = "default_font",
	["entry_font"] = "default_font",
	["title_font_size"] = 19,
	["entry_font_size"] = 14,
	["title_x_offset"] = 0,
	["title_y_offset"] = 0,
	["entry_x_offset"] = 0,
	["entry_y_offset"] = 0,
	["border_alpha"] = 1.0,
	["min_lvl"] = 1,
	["max_lvl"] = MAX_PLAYER_LEVEL,
	["pos_x"] = 470,
	["pos_y"] = -100,
	["size_x"] = 255,
	["size_y"] = 125,
	["show_icon"] = true,
	["show_title"] = true,
	["columns"] = { "Name", "Class", "Race", "Lvl" },
	["theme"] = "None",
	["hide_subtitle_heading"] = false,
	["presets"] = "Yazpad",
	["title_color_r"] = default_text_color_r,
	["title_color_g"] = default_text_color_g,
	["title_color_b"] = default_text_color_b,
	["title_color_a"] = default_text_color_a,
	["tooltip_name"] = true,
	["tooltip_guild"] = true,
	["tooltip_race"] = true,
	["tooltip_class"] = true,
	["tooltip_killedby"] = true,
	["tooltip_zone"] = true,
	["tooltip_loc"] = true,
	["tooltip_date"] = true,
	["tooltip_playtime"] = true,
	["tooltip_lastwords"] = true,
	["tooltip_reportedby"] = true,
	["lock"] = false,
	["filter_mode"] = "all",  -- "all", "guild_only", "guild_confederation", "none"
	["source_kind"] = Deathlog_GetDefaultSourceKind(),
}

local function applyDefaults(_defaults, force)
	if deathlog_settings[widget_name] == nil then
		deathlog_settings[widget_name] = {}
	end
	for k, v in pairs(_defaults) do
		if deathlog_settings[widget_name][k] == nil or force then
			deathlog_settings[widget_name][k] = v
		end
	end
end

local options = {}
local optionsframe = nil
local function applyFont()
	local success = true
	local ws = deathlog_settings[widget_name]
	if ws == nil then return end
	local title_font_path = fonts[ws["font"]] or default_font
	local applied_title_font = Deathlog_SetFontWithFallback(
		death_log_frame.titletext,
		title_font_path,
		ws["title_font_size"] or 19,
		"THICKOUTLINE"
	)

	if applied_title_font ~= death_log_frame.titletext:GetFont() then
		success = false
	end
	death_log_frame.titletext:SetTextColor(
		ws["title_color_r"] or 1,
		ws["title_color_g"] or 1,
		ws["title_color_b"] or 1,
		ws["title_color_a"] or 1
	)
	death_log_frame.titletext:SetPoint(
		"LEFT",
		death_log_frame.frame,
		"TOPLEFT",
		(ws["title_x_offset"] or 0) + 32,
		(ws["title_y_offset"] or 0) - 10
	)

	local entry_font_path = fonts[ws["entry_font"]] or default_font
	local entry_font_size = ws["entry_font_size"] or 14
	-- Cache for per-entry rendering (setEntry) so it can match font + Cyrillic swap.
	current_entry_font_path = entry_font_path
	current_entry_font_size = entry_font_size
	current_entry_font_flags = ""
	for i = 1, 20 do
		local entry = row_entry[i]
		if entry and entry.font_strings then
			for _, v in ipairs(subtitle_data) do
				local fs = entry.font_strings[v.key]
				if fs then
					local text = fs:GetText()
					local applied_entry_font =
						Deathlog_ApplyFontForText(fs, text, entry_font_path, entry_font_size, "")

					-- Verify the actually-applied font (Cyrillic swap or load-failure
					-- fallback included) matches what the fontstring reports, so the retry
					-- ticker can terminate.
					if applied_entry_font ~= fs:GetFont() then
						success = false
					end
				end
			end
		end
	end

	if success == true then
		if font_handle then
			font_handle:Cancel()
		end
	end
end
function Deathlog_minilog_applySettings(rebuild_ace)
	applyDefaults(defaults)
	if rebuild_ace then
		setSubtitleData()
		if loaded == false then
			setupRowEntries()
		else
			-- Rows already exist: re-lay out their fontstrings so newly selected
			-- columns get one and removed columns are hidden.
			for _, _entry in pairs(row_entry) do
				layoutEntryFontStrings(_entry)
			end
		end
	end
	applyFont()
	font_handle = C_Timer.NewTicker(1, applyFont)

	if deathlog_settings[widget_name]["enable"] == nil or deathlog_settings[widget_name]["enable"] == true then
		death_log_frame.frame:Show()
		death_log_icon_frame:Show()
		if
			deathlog_settings[widget_name]["show_icon"] == nil
			or deathlog_settings[widget_name]["show_icon"] == true
		then
			death_log_icon_frame:Show()
		else
			death_log_icon_frame:Show()
			hc_fire_tex:Hide()
			gold_ring_tex:Hide()
			black_round_tex:Hide()
		end

		if
			deathlog_settings[widget_name]["show_title"] == nil
			or deathlog_settings[widget_name]["show_title"] == true
		then
			death_log_frame.titletext:Show()
		else
			death_log_frame.titletext:Hide()
		end
	else
		death_log_frame.frame:Hide()
		death_log_icon_frame:Hide()
	end

	death_log_icon_frame:ClearAllPoints()
	death_log_frame.frame:ClearAllPoints()
	death_log_icon_frame:SetPoint(
		"CENTER",
		UIParent,
		"CENTER",
		deathlog_settings[widget_name]["pos_x"],
		deathlog_settings[widget_name]["pos_y"]
	)
	death_log_frame.frame:SetBackdropBorderColor(1, 1, 1, deathlog_settings[widget_name]["border_alpha"])

	death_log_frame.frame:SetSize(deathlog_settings[widget_name]["size_x"], deathlog_settings[widget_name]["size_y"])

	death_log_frame.frame:SetPoint("TOPLEFT", death_log_icon_frame, "TOPLEFT", 10, -10)
	death_log_frame.frame:SetFrameStrata("BACKGROUND")
	death_log_frame.frame:Lower()

	local lock = deathlog_settings[widget_name]["lock"] == true
	death_log_frame:EnableResize(not lock)

	-- Match icon frame strata so its children (entries) at higher frame levels
	-- get click priority over the icon frame in the overlap region.
	death_log_icon_frame:SetFrameStrata("BACKGROUND")
	death_log_icon_frame:SetFrameLevel(death_log_frame.frame:GetFrameLevel() + 1)

	if deathlog_settings[widget_name]["hide_subtitle_heading"] then
		for _, v in pairs(death_log_frame.subtitletext_tbl) do
			v:Hide()
		end
	else
		for _, v in pairs(death_log_frame.subtitletext_tbl) do
			v:Show()
		end
	end

	if deathlog_settings[widget_name]["theme"] == "Parchment" then
		if class_bg_tex then class_bg_tex:Hide() end
		local PaneBackdrop = {
			bgFile = "Interface\\ACHIEVEMENTFRAME\\UI-Achievement-Parchment-Horizontal",
			edgeFile = "Interface\\Glues\\COMMON\\TextPanel-Border",
			tile = true,
			tileSize = 170,
			edgeSize = 24,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		}

		death_log_frame.frame:SetBackdrop(PaneBackdrop)
		death_log_frame.frame:SetBackdropColor(0.4, 0.4, 0.4, 1)
		death_log_frame.frame:SetBackdropBorderColor(0.5, 0.5, 0.5, deathlog_settings[widget_name]["border_alpha"])
	elseif artifact_themes[deathlog_settings[widget_name]["theme"]] then
		-- Use border-only backdrop; the BG is a manually cropped atlas texture
		local PaneBackdrop = {
			bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
			edgeFile = "Interface\\Glues\\COMMON\\TextPanel-Border",
			tile = true,
			tileSize = 16,
			edgeSize = 24,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		}
		death_log_frame.frame:SetBackdrop(PaneBackdrop)
		death_log_frame.frame:SetBackdropColor(0, 0, 0, 0)
		death_log_frame.frame:SetBackdropBorderColor(0.5, 0.5, 0.5, deathlog_settings[widget_name]["border_alpha"])
		if class_bg_tex == nil then
			class_bg_tex = death_log_frame.frame:CreateTexture(nil, "BACKGROUND", nil, 0)
			class_bg_tex:SetAllPoints(death_log_frame.frame)
			-- UV crops to the Artifacts-<Class>-BG region (same coords for all class sheets)
			class_bg_tex:SetTexCoord(0.000976562, 0.875977, 0.000976562, 0.601562)
		end
		class_bg_tex:SetTexture("Interface\\Artifacts\\ArtifactUI" .. deathlog_settings[widget_name]["theme"])
		class_bg_tex:Show()
	else
		if class_bg_tex then class_bg_tex:Hide() end
		local PaneBackdrop = {
			bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
			edgeFile = "Interface\\Glues\\COMMON\\TextPanel-Border",
			tile = true,
			tileSize = 16,
			edgeSize = 24,
			insets = { left = 3, right = 3, top = 3, bottom = 3 },
		}
		death_log_frame.frame:SetBackdrop(PaneBackdrop)
		death_log_frame.frame:SetBackdropColor(0, 0, 0, 0.6)
		death_log_frame.frame:SetBackdropBorderColor(1, 1, 1, deathlog_settings[widget_name]["border_alpha"])
	end

	if optionsframe == nil then
		LibStub("AceConfig-3.0"):RegisterOptionsTable(widget_name, options)
		optionsframe = LibStub("AceConfigDialog-3.0"):AddToBlizOptions(widget_name, widget_name, "Deathlog")
	end

	if rebuild_ace then
		Deathlog_minilog_refreshEntries()
	end
end

function Deathlog_minilog_setShown(show)
	applyDefaults(defaults)
	deathlog_settings[widget_name]["enable"] = show and true or false
	Deathlog_minilog_applySettings()
	if show then
		death_log_frame:Maximize()
	end
	return deathlog_settings[widget_name]["enable"] ~= false
end

function Deathlog_minilog_toggle()
	applyDefaults(defaults)
	return Deathlog_minilog_setShown(deathlog_settings[widget_name]["enable"] == false)
end

function Deathlog_minilog_isShown()
	applyDefaults(defaults)
	return deathlog_settings[widget_name]["enable"] ~= false
end

local function forceReset()
	applyDefaults(defaults, true)
	Deathlog_minilog_applySettings(true)
end

local column_options = {}

for k, v in pairs(subtitle_metadata) do
	column_options[k] = k
end
column_options["-----"] = ""

local function columnFunc(idx, key)
	local clear = false
	local maxent = max(#deathlog_settings[widget_name]["columns"], idx)

	for i = idx, maxent do
		if
			deathlog_settings[widget_name]["columns"][i] == key
			or (deathlog_settings[widget_name]["columns"][i] == nil and i ~= idx)
		then
			clear = true
		end
		if i == idx then
			deathlog_settings[widget_name]["columns"][idx] = key
			if key == "-----" then
				deathlog_settings[widget_name]["columns"][idx] = nil
				clear = true
			end
		end
		if clear then
			deathlog_settings[widget_name]["columns"][i] = nil
		end
	end
	Deathlog_minilog_applySettings(true)
end

options = {
	name = widget_name,
	type = "group",
	args = {
		show_death_log = {
			type = "toggle",
			name = "Show death log",
			desc = "Show death log",
			get = function()
				return Deathlog_minilog_isShown()
			end,
			set = function()
				Deathlog_minilog_setShown(not Deathlog_minilog_isShown())
			end,
			order = 1,
		},
		lock_position = {
			type = "toggle",
			name = "Lock position",
			desc = "Lock position of the death log.",
			get = function()
				if deathlog_settings[widget_name]["lock"] == nil or deathlog_settings[widget_name]["lock"] == false then
					return false
				else
					return true
				end
			end,
			set = function()
				if deathlog_settings[widget_name]["lock"] == nil then
					deathlog_settings[widget_name]["lock"] = true
				end
				deathlog_settings[widget_name]["lock"] = not deathlog_settings[widget_name]["lock"]
				Deathlog_minilog_applySettings()
			end,
			order = 1,
		},
		show_title_text = {
			type = "toggle",
			name = "Show Title Text",
			desc = "Show the 'Deathlog' title text.",
			get = function()
				if
					deathlog_settings[widget_name]["show_title"] == nil
					or deathlog_settings[widget_name]["show_title"] == true
				then
					return true
				else
					return false
				end
			end,
			set = function()
				if deathlog_settings[widget_name]["show_title"] == nil then
					deathlog_settings[widget_name]["show_title"] = true
				end
				deathlog_settings[widget_name]["show_title"] = not deathlog_settings[widget_name]["show_title"]
				Deathlog_minilog_applySettings()
			end,
			order = 2,
		},
		show_skull_icon = {
			type = "toggle",
			name = "Show Skull Icon (Requires reload)",
			desc = "Show the deathlog icon.",
			get = function()
				if
					deathlog_settings[widget_name]["show_icon"] == nil
					or deathlog_settings[widget_name]["show_icon"] == true
				then
					return true
				else
					return false
				end
			end,
			set = function()
				if deathlog_settings[widget_name]["show_icon"] == nil then
					deathlog_settings[widget_name]["show_icon"] = true
				end
				deathlog_settings[widget_name]["show_icon"] = not deathlog_settings[widget_name]["show_icon"]
				Deathlog_minilog_applySettings()
			end,
			order = 2,
		},
		show_icon = {
			type = "toggle",
			name = "Hide Subtitle Heading",
			desc = "Hide subtitle heading.",
			get = function()
				if
					deathlog_settings[widget_name]["hide_subtitle_heading"] == nil
					or deathlog_settings[widget_name]["hide_subtitle_heading"] == true
				then
					return true
				else
					return false
				end
			end,
			set = function()
				if deathlog_settings[widget_name]["hide_subtitle_heading"] == nil then
					deathlog_settings[widget_name]["hide_subtitle_heading"] = true
				end
				deathlog_settings[widget_name]["hide_subtitle_heading"] =
					not deathlog_settings[widget_name]["hide_subtitle_heading"]
				Deathlog_minilog_applySettings()
			end,
			order = 2,
		},
		font = {
			type = "select",
			dialogControl = "LSM30_Font", --Select your widget here
			name = "Title Font",
			desc = "Title Font to use for the mini deathlog.",
			values = fonts, -- pull in your font list from LSM
			get = function()
				return deathlog_settings[widget_name]["font"]
			end,
			set = function(self, key)
				deathlog_settings[widget_name]["font"] = key
				Deathlog_minilog_applySettings()
			end,
		},
		entryfont = {
			type = "select",
			dialogControl = "LSM30_Font", --Select your widget here
			name = "Entry Font",
			desc = "Entry Font to use for the mini deathlog.",
			values = fonts, -- pull in your font list from LSM
			get = function()
				return deathlog_settings[widget_name]["entry_font"]
			end,
			set = function(self, key)
				deathlog_settings[widget_name]["entry_font"] = key
				Deathlog_minilog_applySettings()
			end,
		},
		fontsize = {
			type = "range",
			name = "Title Font Size",
			desc = "Title Font Size",
			min = 7,
			max = 30,
			step = 1,
			get = function()
				return deathlog_settings[widget_name]["title_font_size"]
			end,
			set = function(self, value)
				deathlog_settings[widget_name]["title_font_size"] = value
				Deathlog_minilog_applySettings()
			end,
		},
		borderalpha = {
			type = "range",
			name = "Border Alpha",
			desc = "Change border alpha",
			min = 0,
			max = 1,
			step = 0.05,
			get = function()
				return deathlog_settings[widget_name]["border_alpha"]
			end,
			set = function(self, value)
				deathlog_settings[widget_name]["border_alpha"] = value
				Deathlog_minilog_applySettings()
			end,
		},
		entryfontsize = {
			type = "range",
			name = "Entry Font Size",
			desc = "Entry Font Size",
			min = 7,
			max = 30,
			step = 1,
			get = function()
				return deathlog_settings[widget_name]["entry_font_size"]
			end,
			set = function(self, value)
				deathlog_settings[widget_name]["entry_font_size"] = value
				Deathlog_minilog_applySettings()
			end,
		},
		titlexoffset = {
			type = "range",
			name = "Title x-offset",
			desc = "Title x-offset",
			min = -50,
			max = 250,
			step = 1,
			get = function()
				return deathlog_settings[widget_name]["title_x_offset"]
			end,
			set = function(self, value)
				deathlog_settings[widget_name]["title_x_offset"] = value
				Deathlog_minilog_applySettings()
			end,
		},
		titleyoffset = {
			type = "range",
			name = "Title y-offset",
			desc = "Title y-offset",
			min = -50,
			max = 250,
			step = 1,
			get = function()
				return deathlog_settings[widget_name]["title_y_offset"]
			end,
			set = function(self, value)
				deathlog_settings[widget_name]["title_y_offset"] = value
				Deathlog_minilog_applySettings()
			end,
		},
		entryxoffset = {
			type = "range",
			name = "Entry x-offset (requires reload)",
			desc = "Entry x-offset",
			min = -50,
			max = 250,
			step = 1,
			get = function()
				return deathlog_settings[widget_name]["entry_x_offset"]
			end,
			set = function(self, value)
				deathlog_settings[widget_name]["entry_x_offset"] = value

				if ace_refresh_timer_handle then
					ace_refresh_timer_handle:Cancel()
				end
				ace_refresh_timer_handle = C_Timer.NewTimer(0.05, function(cb)
					Deathlog_minilog_applySettings(true)
					cb:Cancel()
				end)
			end,
		},
		entryyoffset = {
			type = "range",
			name = "Entry y-offset",
			desc = "Entry y-offset",
			min = -50,
			max = 250,
			step = 1,
			get = function()
				return deathlog_settings[widget_name]["entry_y_offset"]
			end,
			set = function(self, value)
				deathlog_settings[widget_name]["entry_y_offset"] = value
				if ace_refresh_timer_handle then
					ace_refresh_timer_handle:Cancel()
				end
				ace_refresh_timer_handle = C_Timer.NewTimer(0.05, function(cb)
					Deathlog_minilog_applySettings(true)
					cb:Cancel()
				end)
			end,
		},
		reset_size_and_pos = {
			type = "execute",
			name = "Reset to default",
			desc = "Reset to default",
			func = function()
				forceReset()
			end,
		},

		theme = {
			type = "select",
			dialogControl = "LSM30_Font", --Select your widget here
			name = "Theme",
			desc = "Texture theme",
			values = themes, -- pull in your font list from LSM
			get = function()
				return deathlog_settings[widget_name]["theme"]
			end,
			set = function(self, key)
				deathlog_settings[widget_name]["theme"] = key
				Deathlog_minilog_applySettings()
			end,
		},

		preset_ = {
			type = "select",
			dialogControl = "LSM30_Font", --Select your widget here
			name = "Preset Settings",
			desc = "Preset Settings",
			order = 3,
			values = presets, -- pull in your font list from LSM
			get = function()
				return deathlog_settings[widget_name]["presets"]
			end,
			set = function(self, key)
				deathlog_settings[widget_name]["presets"] = key
				if deathlog_settings[widget_name]["presets"] == "concise" then
					deathlog_settings[widget_name]["enable"] = true
					deathlog_settings[widget_name]["font"] = "BreatheFire"
					deathlog_settings[widget_name]["entry_font"] = "default_font"
					deathlog_settings[widget_name]["title_font_size"] = 19
					deathlog_settings[widget_name]["entry_font_size"] = 16
					deathlog_settings[widget_name]["title_x_offset"] = 13
					deathlog_settings[widget_name]["title_y_offset"] = -9
					deathlog_settings[widget_name]["border_alpha"] = 1.0
					deathlog_settings[widget_name]["size_x"] = 181.8763122558594
					deathlog_settings[widget_name]["size_y"] = 102.3703765869141
					deathlog_settings[widget_name]["show_icon"] = false
					deathlog_settings[widget_name]["show_title"] = true
					deathlog_settings[widget_name]["entry_x_offset"] = 0
					deathlog_settings[widget_name]["entry_y_offset"] = 0
					deathlog_settings[widget_name]["columns"] = {
						"Lvl", -- [1]
						"Name", -- [2]
						"RaceLogoSquare", -- [3]
						"ClassLogo1", -- [4]
					}
					deathlog_settings[widget_name]["theme"] = "Parchment"
					deathlog_settings[widget_name]["hide_subtitle_heading"] = true
					deathlog_settings[widget_name]["presets"] = "concise"
				end
				if deathlog_settings[widget_name]["presets"] == "Yazpad" then
					deathlog_settings[widget_name]["enable"] = true
					deathlog_settings[widget_name]["font"] = "BreatheFire"
					deathlog_settings[widget_name]["entry_font"] = "default_font"
					deathlog_settings[widget_name]["title_font_size"] = 19
					deathlog_settings[widget_name]["entry_font_size"] = 16
					deathlog_settings[widget_name]["title_x_offset"] = 13
					deathlog_settings[widget_name]["title_y_offset"] = -9
					deathlog_settings[widget_name]["border_alpha"] = 1.0
					deathlog_settings[widget_name]["size_x"] = 161.8763122558594
					deathlog_settings[widget_name]["size_y"] = 102.3703765869141
					deathlog_settings[widget_name]["show_icon"] = false
					deathlog_settings[widget_name]["show_title"] = true
					deathlog_settings[widget_name]["entry_x_offset"] = 0
					deathlog_settings[widget_name]["entry_y_offset"] = 0
					deathlog_settings[widget_name]["columns"] = {
						"Lvl", -- [1]
						"Name", -- [2]
						"RaceLogoSquare", -- [3]
						"ClassLogo1", -- [4]
					}
					deathlog_settings[widget_name]["theme"] = "Warrior"
					deathlog_settings[widget_name]["hide_subtitle_heading"] = true
					deathlog_settings[widget_name]["presets"] = "Yazpad"

					deathlog_settings[widget_name]["title_color_r"] = 1
					deathlog_settings[widget_name]["title_color_g"] = 1
					deathlog_settings[widget_name]["title_color_b"] = 1
					deathlog_settings[widget_name]["title_color_a"] = 1
				end
				if deathlog_settings[widget_name]["presets"] == "ChefCarlos" then
					deathlog_settings[widget_name]["enable"] = true
					deathlog_settings[widget_name]["font"] = "2002 Bold"
					deathlog_settings[widget_name]["entry_font"] = "2002 Bold"
					deathlog_settings[widget_name]["title_font_size"] = 14
					deathlog_settings[widget_name]["entry_font_size"] = 11
					deathlog_settings[widget_name]["title_x_offset"] = -20
					deathlog_settings[widget_name]["title_y_offset"] = 0
					deathlog_settings[widget_name]["border_alpha"] = 1.0
					deathlog_settings[widget_name]["size_x"] = 500
					deathlog_settings[widget_name]["size_y"] = 150
					deathlog_settings[widget_name]["show_icon"] = false
					deathlog_settings[widget_name]["show_title"] = true
					deathlog_settings[widget_name]["entry_x_offset"] = 0
					deathlog_settings[widget_name]["entry_y_offset"] = 0
					deathlog_settings[widget_name]["columns"] = {
						"Name", -- [1]
						"ClassLogo1", -- [2]
						"Lvl", -- [3]
						"Source", -- [4]
						"LastWords", -- [5]
					}
					deathlog_settings[widget_name]["theme"] = "None"
					deathlog_settings[widget_name]["hide_subtitle_heading"] = false
					deathlog_settings[widget_name]["presets"] = "ChefCarlos"
					deathlog_settings[widget_name]["title_color_r"] = 1
					deathlog_settings[widget_name]["title_color_g"] = 1
					deathlog_settings[widget_name]["title_color_b"] = 1
					deathlog_settings[widget_name]["title_color_a"] = 1
				end
				Deathlog_minilog_applySettings()
			end,
		},
		add_fake = {
			type = "execute",
			name = "Add fake entry",
			desc = "Add fake entry",
			func = function()
				Deathlog_widget_minilog_createEntry(DeathNotificationLib.CreateFakeEntry())
			end,
		},

		titlecolor = {
			type = "color",
			name = "Title Text Color",
			desc = "Title Text Color",
			get = function()
				return deathlog_settings[widget_name]["title_color_r"],
					deathlog_settings[widget_name]["title_color_g"],
					deathlog_settings[widget_name]["title_color_b"],
					deathlog_settings[widget_name]["title_color_a"]
			end,
			set = function(self, r, g, b, a)
				deathlog_settings[widget_name]["title_color_r"] = r
				deathlog_settings[widget_name]["title_color_g"] = g
				deathlog_settings[widget_name]["title_color_b"] = b
				deathlog_settings[widget_name]["title_color_a"] = a

				Deathlog_minilog_applySettings()
			end,
		},

		alert_options_header = {
			type = "group",
			name = "Column Configuration (May require reload)",
			order = 10,
			inline = true,
			args = {
				column1 = {
					type = "select",
					dialogControl = "LSM30_Font", --Select your widget here
					name = "Column1",
					desc = "Which value should go into the first column",
					values = column_options, -- pull in your font list from LSM
					get = function()
						return deathlog_settings[widget_name]["columns"][1] or "-----"
					end,
					set = function(self, key)
						columnFunc(1, key)
					end,
				},
				column2 = {
					type = "select",
					dialogControl = "LSM30_Font", --Select your widget here
					name = "Column2",
					desc = "Which value should go into the second column",
					values = column_options, -- pull in your font list from LSM
					get = function()
						return deathlog_settings[widget_name]["columns"][2] or "-----"
					end,
					set = function(self, key)
						columnFunc(2, key)
					end,
				},
				column3 = {
					type = "select",
					dialogControl = "LSM30_Font", --Select your widget here
					name = "Column3",
					desc = "Which value should go into the second column",
					values = column_options, -- pull in your font list from LSM
					get = function()
						return deathlog_settings[widget_name]["columns"][3] or "-----"
					end,
					set = function(self, key)
						columnFunc(3, key)
					end,
				},
				column4 = {
					type = "select",
					dialogControl = "LSM30_Font", --Select your widget here
					name = "Column4",
					desc = "Which value should go into the second column",
					values = column_options, -- pull in your font list from LSM
					get = function()
						return deathlog_settings[widget_name]["columns"][4] or "-----"
					end,
					set = function(self, key)
						columnFunc(4, key)
					end,
				},
				column5 = {
					type = "select",
					dialogControl = "LSM30_Font", --Select your widget here
					name = "Column5",
					desc = "Which value should go into the second column",
					values = column_options, -- pull in your font list from LSM
					get = function()
						return deathlog_settings[widget_name]["columns"][5] or "-----"
					end,
					set = function(self, key)
						columnFunc(5, key)
					end,
				},
				column6 = {
					type = "select",
					dialogControl = "LSM30_Font", --Select your widget here
					name = "Column6",
					desc = "Which value should go into the second column",
					values = column_options, -- pull in your font list from LSM
					get = function()
						return deathlog_settings[widget_name]["columns"][6] or "-----"
					end,
					set = function(self, key)
						columnFunc(6, key)
					end,
				},
			},
		},
		minilog_lvl_filter = {
			type = "group",
			name = "Filter Options",
			order = 11,
			inline = true,
			args = {
				min_lvl = {
					type = "range",
					name = "Min. Lvl. to Display",
					desc = "Minimum level to display",
					min = 1,
					max = MAX_PLAYER_LEVEL,
					step = 1,
					order = 1,
					disabled = function()
						return deathlog_settings[widget_name]["min_lvl_player"]
					end,
					get = function()
						if deathlog_settings[widget_name]["min_lvl_player"] then
							return UnitLevel("player")
						end
						return deathlog_settings[widget_name]["min_lvl"]
					end,
					set = function(self, value)
						deathlog_settings[widget_name]["min_lvl"] = value
						Deathlog_minilog_applySettings(true)
					end,
				},
				max_lvl = {
					type = "range",
					name = "Max. Lvl. to Display",
					desc = "Maximum level to display",
					min = 1,
					max = MAX_PLAYER_LEVEL,
					step = 1,
					order = 2,
					get = function()
						return deathlog_settings[widget_name]["max_lvl"]
					end,
					set = function(self, value)
						deathlog_settings[widget_name]["max_lvl"] = value
						Deathlog_minilog_applySettings(true)
					end,
				},
				source_kind = {
					type = "select",
					name = "Source Filter",
					desc = "Choose which death source kinds should appear in the minilog.",
					order = 3,
					values = Deathlog_GetSourceKindOptions(),
					sorting = Deathlog_GetSourceKindOptionOrder(),
					get = function()
						return Deathlog_GetWidgetSourceKind(widget_name)
					end,
					set = function(self, value)
						deathlog_settings[widget_name]["source_kind"] = value
						Deathlog_minilog_applySettings(true)
					end,
				},
				filter_mode = {
					type = "select",
					name = "Death Filter",
					desc = "Filter which deaths to display. 'Guild Only' shows only deaths from your guild. 'Guild + Confederation' also includes GreenWall confederation guilds.",
					order = 4,
					values = function()
						return DeathNotificationLib.GetGuildFilterModeOptions()
					end,
					get = function()
						local v = deathlog_settings[widget_name]["filter_mode"] or "all"
						if not DeathNotificationLib.GetGuildFilterModeOptions()[v] then v = "all" end
						return v
					end,
					set = function(self, value)
						deathlog_settings[widget_name]["filter_mode"] = value
						Deathlog_minilog_applySettings(true)
					end,
				},
				greenwall_status = {
					type = "description",
					name = function()
						return "|cFF888888" .. DeathNotificationLib.GetGreenWallStatus() .. "|r"
					end,
					order = 4.1,
					width = "full",
				},
			},
		},

		minilog_tooltip = {
			type = "group",
			name = "Tooltip Options",
			order = 11,
			inline = true,
			args = {
				name = {
					type = "toggle",
					name = "Name",
					desc = "Show the 'Name' row in the minilog tooltip",
					order = 1,
					get = function()
						if
							deathlog_settings[widget_name]["tooltip_name"] == nil
							or deathlog_settings[widget_name]["tooltip_name"] == true
						then
							return true
						else
							return false
						end
					end,
					set = function()
						if deathlog_settings[widget_name]["tooltip_name"] == nil then
							deathlog_settings[widget_name]["tooltip_name"] = true
						end
						deathlog_settings[widget_name]["tooltip_name"] =
							not deathlog_settings[widget_name]["tooltip_name"]
					end,
				},
				guild = {
					type = "toggle",
					name = "Guild",
					desc = "Show the 'Guild' row in the minilog tooltip",
					order = 2,
					get = function()
						if
							deathlog_settings[widget_name]["tooltip_guild"] == nil
							or deathlog_settings[widget_name]["tooltip_guild"] == true
						then
							return true
						else
							return false
						end
					end,
					set = function()
						if deathlog_settings[widget_name]["tooltip_guild"] == nil then
							deathlog_settings[widget_name]["tooltip_guild"] = true
						end
						deathlog_settings[widget_name]["tooltip_guild"] =
							not deathlog_settings[widget_name]["tooltip_guild"]
					end,
				},
				race = {
					type = "toggle",
					name = "Race",
					desc = "Show the 'Race' row in the minilog tooltip",
					order = 3,
					get = function()
						if
							deathlog_settings[widget_name]["tooltip_race"] == nil
							or deathlog_settings[widget_name]["tooltip_race"] == true
						then
							return true
						else
							return false
						end
					end,
					set = function()
						if deathlog_settings[widget_name]["tooltip_race"] == nil then
							deathlog_settings[widget_name]["tooltip_race"] = true
						end
						deathlog_settings[widget_name]["tooltip_race"] =
							not deathlog_settings[widget_name]["tooltip_race"]
					end,
				},
				class = {
					type = "toggle",
					name = "Class",
					desc = "Show the 'Class' row in the minilog tooltip",
					order = 4,
					get = function()
						if
							deathlog_settings[widget_name]["tooltip_class"] == nil
							or deathlog_settings[widget_name]["tooltip_class"] == true
						then
							return true
						else
							return false
						end
					end,
					set = function()
						if deathlog_settings[widget_name]["tooltip_class"] == nil then
							deathlog_settings[widget_name]["tooltip_class"] = true
						end
						deathlog_settings[widget_name]["tooltip_class"] =
							not deathlog_settings[widget_name]["tooltip_class"]
					end,
				},
				killed_by = {
					type = "toggle",
					name = "Killed By",
					desc = "Show the 'Killed by' row in the minilog tooltip",
					order = 5,
					get = function()
						if
							deathlog_settings[widget_name]["tooltip_killedby"] == nil
							or deathlog_settings[widget_name]["tooltip_killedby"] == true
						then
							return true
						else
							return false
						end
					end,
					set = function()
						if deathlog_settings[widget_name]["tooltip_killedby"] == nil then
							deathlog_settings[widget_name]["tooltip_killedby"] = true
						end
						deathlog_settings[widget_name]["tooltip_killedby"] =
							not deathlog_settings[widget_name]["tooltip_killedby"]
					end,
				},
				zone = {
					type = "toggle",
					name = "Zone",
					desc = "Show the 'Zone' row in the minilog tooltip",
					order = 6,
					get = function()
						if
							deathlog_settings[widget_name]["tooltip_zone"] == nil
							or deathlog_settings[widget_name]["tooltip_zone"] == true
						then
							return true
						else
							return false
						end
					end,
					set = function()
						if deathlog_settings[widget_name]["tooltip_zone"] == nil then
							deathlog_settings[widget_name]["tooltip_zone"] = true
						end
						deathlog_settings[widget_name]["tooltip_zone"] =
							not deathlog_settings[widget_name]["tooltip_zone"]
					end,
				},
				location = {
					type = "toggle",
					name = "Location",
					desc = "Show the 'Loc' row in the minilog tooltip",
					order = 7,
					get = function()
						if
							deathlog_settings[widget_name]["tooltip_loc"] == nil
							or deathlog_settings[widget_name]["tooltip_loc"] == true
						then
							return true
						else
							return false
						end
					end,
					set = function()
						if deathlog_settings[widget_name]["tooltip_loc"] == nil then
							deathlog_settings[widget_name]["tooltip_loc"] = true
						end
						deathlog_settings[widget_name]["tooltip_loc"] =
							not deathlog_settings[widget_name]["tooltip_loc"]
					end,
				},
				timestamp = {
					type = "toggle",
					name = "Date",
					desc = "Show the 'Date' row in the minilog tooltip",
					order = 8,
					get = function()
						if
							deathlog_settings[widget_name]["tooltip_date"] == nil
							or deathlog_settings[widget_name]["tooltip_date"] == true
						then
							return true
						else
							return false
						end
					end,
					set = function()
						if deathlog_settings[widget_name]["tooltip_date"] == nil then
							deathlog_settings[widget_name]["tooltip_date"] = true
						end
						deathlog_settings[widget_name]["tooltip_date"] =
							not deathlog_settings[widget_name]["tooltip_date"]
					end,
				},
				playtime = {
					type = "toggle",
					name = "Playtime",
					desc = "Show the 'Playtime' row in the minilog tooltip",
					order = 9,
					get = function()
						if
							deathlog_settings[widget_name]["tooltip_playtime"] == nil
							or deathlog_settings[widget_name]["tooltip_playtime"] == true
						then
							return true
						else
							return false
						end
					end,
					set = function()
						if deathlog_settings[widget_name]["tooltip_playtime"] == nil then
							deathlog_settings[widget_name]["tooltip_playtime"] = true
						end
						deathlog_settings[widget_name]["tooltip_playtime"] =
							not deathlog_settings[widget_name]["tooltip_playtime"]
					end,
				},
				last_words = {
					type = "toggle",
					name = "Last Words",
					desc = "Show the 'Last words' row in the minilog tooltip",
					order = 8,
					get = function()
						if
							deathlog_settings[widget_name]["tooltip_lastwords"] == nil
							or deathlog_settings[widget_name]["tooltip_lastwords"] == true
						then
							return true
						else
							return false
						end
					end,
					set = function()
						if deathlog_settings[widget_name]["tooltip_lastwords"] == nil then
							deathlog_settings[widget_name]["tooltip_lastwords"] = true
						end
						deathlog_settings[widget_name]["tooltip_lastwords"] =
							not deathlog_settings[widget_name]["tooltip_lastwords"]
					end,
				},
				reported_by = {
					type = "toggle",
					name = "Reported By",
					desc = "Show the 'Reported by' row (who broadcast the death to you) in the minilog tooltip",
					order = 10,
					get = function()
						if
							deathlog_settings[widget_name]["tooltip_reportedby"] == nil
							or deathlog_settings[widget_name]["tooltip_reportedby"] == true
						then
							return true
						else
							return false
						end
					end,
					set = function()
						if deathlog_settings[widget_name]["tooltip_reportedby"] == nil then
							deathlog_settings[widget_name]["tooltip_reportedby"] = true
						end
						deathlog_settings[widget_name]["tooltip_reportedby"] =
							not deathlog_settings[widget_name]["tooltip_reportedby"]
					end,
				},
			},
		},
	},
}
