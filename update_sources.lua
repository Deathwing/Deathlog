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
local SOURCES = {
	{ name = "CurseForge", url = "https://www.curseforge.com/wow/addons/deathlog" },
	{ name = "GitHub", url = "https://github.com/Deathwing/Deathlog/releases/latest" },
	{ name = "Wago", url = "https://addons.wago.io/addons/deathlog" },
	{ name = "WoWInterface", url = "https://www.wowinterface.com/downloads/info27170-Deathlog.html" },
}

local warnedVersions = {}
local sourceFrame
local pendingVersion
local retryScheduled

local function getVersion()
	local getMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
	return getMetadata("Deathlog", "Version") or "unknown"
end

local function compareVersions(left, right)
	local leftParts = {}
	local rightParts = {}
	for part in tostring(left or ""):gmatch("%d+") do
		leftParts[#leftParts + 1] = tonumber(part) or 0
	end
	for part in tostring(right or ""):gmatch("%d+") do
		rightParts[#rightParts + 1] = tonumber(part) or 0
	end
	for index = 1, math.max(#leftParts, #rightParts, 1) do
		local difference = (leftParts[index] or 0) - (rightParts[index] or 0)
		if difference ~= 0 then return difference end
	end
	return 0
end

--- Returns true when `candidate` is a strictly newer version than `current`.
--- Exposed so other files (e.g. the /dl versions command) can reuse the same
--- numeric version comparison used for update detection.
function Deathlog_IsVersionNewer(candidate, current)
	return compareVersions(candidate, current) > 0
end

local function createSourceFrame()
	local frame = CreateFrame("Frame", "DeathlogUpdateSourcesFrame", UIParent, "BackdropTemplate")
	-- Sources are laid out in a grid of BUTTONS_PER_ROW columns; the dialog
	-- is sized from that grid so no button can hang outside it.
	local BUTTONS_PER_ROW, BUTTON_WIDTH, BUTTON_HEIGHT = 2, 170, 28
	local COL_GAP, ROW_GAP = 10, 6
	local rows = math.ceil(#SOURCES / BUTTONS_PER_ROW)
	local grid_width = BUTTONS_PER_ROW * BUTTON_WIDTH + (BUTTONS_PER_ROW - 1) * COL_GAP
	local grid_height = rows * BUTTON_HEIGHT + (rows - 1) * ROW_GAP
	local frame_width = grid_width + 100
	frame:SetSize(frame_width, 200) -- height is set below once the text is measured
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:SetClampedToScreen(true)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true,
		tileSize = 32,
		edgeSize = 32,
		insets = { left = 11, right = 12, top = 12, bottom = 11 },
	})

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)

	local title = frame:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -22)
	title:SetText("Deathlog Updates")
	frame.title = title

	local description = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	description:SetPoint("TOP", title, "BOTTOM", 0, -10)
	description:SetWidth(frame_width - 50)
	description:SetJustifyH("CENTER")
	description:SetText("Choose an official download source, then copy the selected address.")

	-- top margin + title + gap + description + gap + grid + gap + address box + bottom margin
	frame:SetHeight(22 + title:GetStringHeight() + 10 + description:GetStringHeight() + 20
		+ grid_height + 24 + 28 + 24)

	local editBox = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
	editBox:SetSize(grid_width + 20, 28)
	editBox:SetPoint("BOTTOM", 0, 24)
	editBox:SetAutoFocus(false)
	editBox:SetScript("OnEscapePressed", editBox.ClearFocus)
	frame.editBox = editBox

	local grid = CreateFrame("Frame", nil, frame)
	grid:SetSize(grid_width, grid_height)
	grid:SetPoint("TOP", description, "BOTTOM", 0, -20)

	for index, source in ipairs(SOURCES) do
		local col = (index - 1) % BUTTONS_PER_ROW
		local row = math.floor((index - 1) / BUTTONS_PER_ROW)
		local button = CreateFrame("Button", nil, grid, "UIPanelButtonTemplate")
		button:SetSize(BUTTON_WIDTH, BUTTON_HEIGHT)
		button:SetPoint("TOPLEFT", grid, "TOPLEFT",
			col * (BUTTON_WIDTH + COL_GAP), -row * (BUTTON_HEIGHT + ROW_GAP))
		button:SetText(source.name)
		button:SetScript("OnClick", function()
			editBox:SetText(source.url)
			editBox:SetFocus()
			editBox:HighlightText()
		end)
	end

	editBox:SetText(SOURCES[1].url)
	frame:Hide()
	return frame
end

function Deathlog_ShowUpdateSources(newVersion)
	if not sourceFrame then
		sourceFrame = createSourceFrame()
	end
	if newVersion then
		sourceFrame.title:SetText("Deathlog " .. tostring(newVersion) .. " is available")
	else
		sourceFrame.title:SetText("Deathlog Updates - v" .. tostring(getVersion()))
	end
	sourceFrame:Show()
	sourceFrame:Raise()
end

local tryShowPendingUpdate

local function scheduleRetry(delay)
	if retryScheduled then return end
	retryScheduled = true
	C_Timer.After(delay, tryShowPendingUpdate)
end

tryShowPendingUpdate = function()
	retryScheduled = nil
	if not pendingVersion then return end
	if deathlog_settings["last_update_popup_version"] == pendingVersion then
		pendingVersion = nil
		return
	end
	if InCombatLockdown() then return end
	-- Only surface the update popup in rested areas (inns/cities). Popping it up
	-- mid-world is too intrusive, especially in Hardcore, so defer and retry
	-- until the player is resting.
	if not IsResting() then
		scheduleRetry(5)
		return
	end
	if Deathlog_IsChangelogVisible and Deathlog_IsChangelogVisible() then
		scheduleRetry(2)
		return
	end
	local version = pendingVersion
	pendingVersion = nil
	deathlog_settings["last_update_popup_version"] = version
	Deathlog_ShowUpdateSources(version)
end

local function scheduleUpdatePopup(newVersion)
	newVersion = tostring(newVersion or "unknown")
	local detectedVersion = deathlog_settings["newest_detected_update_version"]
	if detectedVersion and compareVersions(detectedVersion, newVersion) > 0 then
		newVersion = detectedVersion
	end
	deathlog_settings["newest_detected_update_version"] = newVersion
	local shownVersion = deathlog_settings["last_update_popup_version"]
	if shownVersion and compareVersions(newVersion, shownVersion) <= 0 then return end
	pendingVersion = newVersion
	scheduleRetry(3)
end

local function notifyNewerVersion(addonName, newVersion)
	if addonName ~= "Deathlog" then return end
	newVersion = tostring(newVersion or "unknown")
	scheduleUpdatePopup(newVersion)
	if warnedVersions[newVersion] then return end
	warnedVersions[newVersion] = true
	DEFAULT_CHAT_FRAME:AddMessage("|cffffff00[Deathlog]|r Official downloads are available from CurseForge, GitHub, and Wago. Type |cffffffff/dl update|r to choose a source.")
end

if DeathNotificationLib and DeathNotificationLib.HookOnNewerVersion then
	DeathNotificationLib.HookOnNewerVersion(notifyNewerVersion)
end

SLASH_DEATHLOGUPDATES1 = "/dl-update"
SlashCmdList["DEATHLOGUPDATES"] = function()
	Deathlog_ShowUpdateSources()
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" then
		local detectedVersion = deathlog_settings["newest_detected_update_version"]
		if detectedVersion and compareVersions(detectedVersion, getVersion()) > 0 then
			scheduleUpdatePopup(detectedVersion)
		else
			deathlog_settings["newest_detected_update_version"] = nil
		end
		return
	end
	tryShowPendingUpdate()
end)