--[[
Copyright 2026 Deathwing
The Deathlog AddOn is distributed under the terms of the GNU General Public License.
This file is part of Deathlog.
--]]
---@diagnostic disable: invisible

-- In-game changelog popup
-- Shows automatically on first load after a version upgrade

local addonName, addon = ...
local AceGUI = LibStub("AceGUI-3.0")

-- API compatibility: Classic Era uses GetAddOnMetadata, TBC Anniversary uses C_AddOns.GetAddOnMetadata
local GetAddOnMetadata = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata

-- Current version from TOC
local CURRENT_VERSION = GetAddOnMetadata("Deathlog", "Version") or "0.0.0"

-- Versions with no user-facing changes; the changelog popup will be suppressed for these.
local NO_CHANGELOG_VERSIONS = {
    ["0.5.8"] = true,
	["0.5.10"] = true,
	["0.5.11"] = true,
	["0.5.18"] = true,
	["0.5.26"] = true,
}

-- Changelog content (update this with each release)
local CHANGELOG_CONTENT = [[
|cFFFFD700Deathlog Changelog|r

|cFF00FF00[0.7.1] - 2026-11-25|r

|cFFFFFFFFWoW Forever|r
- Deaths are now kept per region ('WoW Forever US'); saved deaths move over automatically
- Players who share a first name are mixed up far less often
- Forever's explored areas on the zone map, and pages for Zephras Isle and Darkspear Islands
- Naxxramas is back in Instance Statistics
- Skyborne players show their race in the filter and mini log
- Deaths from a copied Classic settings folder no longer show up

|cFFFFFFFFFixes|r
- Battleground statistics open from links on the map
- UltraHardcore deaths land in the right dungeon or battleground
- HardcoreTBC battleground deaths count under the battleground, with the killer
- Deaths at sea no longer count as Deadmines deaths

|cFF00FF00[0.7.0] - 2026-11-18|r

|cFFFFFFFFNew Features|r
- Your log no longer grows too big to load; older deaths are archived but searchable
- New personal death log for all your characters; set Server to 'Personal' in Search
- WoW Forever: statistics and heatmaps are built from your own log

|cFFFFFFFFFixes|r
- WoW Forever: no more errors in dungeons, battlegrounds and raids, and no double deaths
- Your settings are restored if the database fails to load
- Death alerts show party deaths again; on Hardcore realms Blizzard's alert settings are adjusted
- 'Accept legacy protocol messages' was turned off once; turn it back on in Options if you want it

|cFF00FF00[0.6.0] - 2026-11-10|r

|cFFFFFFFFNew Features|r
- WoW Forever support, with Forever's own zones, instances and creatures
- The CurseForge download now includes everything Deathlog needs; update separately installed copies

|cFFFFFFFFFixes|r
- No more repeated errors from damage like the Cloud of Disease in Scholomance (thanks leozitor)
- The Trade button works normally again, plus smaller fixes

|cFF00FF00[0.5.25] - 2026-09-11|r

|cFFFFFFFFFixes|r
- Statistics tables no longer overlap; large counts show as 889k or 1.55M (thanks Lairo)
- The download buttons now fit inside the 'update available' window

|cFF00FF00[0.5.24] - 2026-09-09|r

|cFFFFFFFFNew Features|r
- Right-click a death and pick 'Copy Deathmap URL' to see it on wowdeathmap.com
- A badge in the main window copies a link to the live death map

|cFFFFFFFFImprovements|r
- Copy-link windows are easier to read and have a Close button

|cFFFFFFFFFixes|r
- Death alerts on brand-new accounts start working once the game lifts its chat mute
- Everyone now shares one backup death alert channel
- The name filter now catches offensive names hidden behind accented letters

|cFF00FF00[0.5.23] - 2026-08-12|r

|cFFFFFFFFNew Features|r
- Right-click a death to report or hide a player, or ignore whoever sent it
- 'Report message' reports a fresh death with its original text and real sender
- Deaths sent by other players now show who reported them

|cFFFFFFFFImprovements|r
- Fake death floods are blocked, and fake deaths already in your log are removed
- 'Killed by: Reported' is gone; the killer is now guessed from where they died

|cFF00FF00[0.5.22] - 2026-07-25|r

|cFFFFFFFFFixes|r
- The extra mini log fonts now load (thanks karaktaka)
- Changing mini log columns or presets no longer breaks the mini log (thanks flames57)
- Mini log columns no longer go blank when used twice

|cFF00FF00[0.5.21] - 2026-07-24|r

|cFFFFFFFFFixes|r
- Changing mini log columns or presets no longer shows a font error
- Settings panels no longer go missing from the options
- A missing death alert sound now falls back to the default

|cFFFFFFFFImprovements|r
- New /dl versions command shows the versions of Deathlog and its parts
- Update, changelog and contribution popups now only appear while resting

|cFF00FF00[0.5.20] - 2026-07-23|r

|cFFFFFFFFFixes|r
- Opening /deathlog on very large logs no longer errors or shows an empty log
- First login with a very large log no longer causes errors

|cFF00FF00[0.5.19] - 2026-07-23|r

|cFFFFFFFFFixes|r
- First login with a large log no longer errors on Classic Era 1.15.9
- Opening /deathlog on very large logs no longer errors

|cFF00FF00[0.5.17] - 2026-07-22|r

|cFFFFFFFFBug Fixes|r
- The death alert 'Guild Only' filter no longer misses guild deaths (thanks Fate)
- Shift-clicking a name in chat shows the result in chat, not the Who window (thanks Makpptfox)

|cFFFFFFFFImprovements|r
- 'Inspect user' in the mini log menu now shows its result in chat (thanks Makpptfox)
- Watch List notes can be up to 100 characters (thanks Fate)

|cFF00FF00[0.5.16] - 2026-07-16|r

|cFFFFFFFFBug Fixes|r
- Watch List buttons are clickable when the Deathlog window is scaled down (thanks Fate)
- Logging back into a dead Hardcore character no longer creates a duplicate death
- Fixed error popups in the Watch List and the TBC Anniversary settings

|cFFFFFFFFImprovements|r
- Updated for TBC Anniversary patch 2.5.6

|cFF00FF00[0.5.15] - 2026-06-27|r

|cFFFFFFFFNew Features|r
- Option to show dates as DD/MM/YY (thanks Makpptfox)
- New 'Sound Channel' option keeps death alerts audible at low effects volume

|cFFFFFFFFBug Fixes|r
- Esc closes the world map, and 'Show death location' now works (thanks Makpptfox)
- Deaths without a location no longer reuse the previous death's map pin (thanks Makpptfox)
- The Watch List remove (X) button is easier to click

|cFF00FF00[0.5.14] - 2026-06-15|r

|cFFFFFFFFNew Features|r
- 'Lock position' hides the mini log resize handle; the heatmap indicator can lock too (thanks Makpptfox)

|cFFFFFFFFBug Fixes|r
- Names with accents, umlauts or Cyrillic letters now display correctly

|cFFFFFFFFImprovements|r
- The mini log font is back to its normal size

|cFF00FF00[0.5.13] - 2026-05-25|r

|cFFFFFFFFNew Features|r
- Show or hide the mini log with /dl minilog or Ctrl-click on the minimap button

|cFFFFFFFFImprovements|r
- Zone Statistics opens on the last viewed zone, or your current zone

|cFF00FF00[0.5.12] - 2026-05-11|r

|cFFFFFFFFBug Fixes|r
- Fixed death alerts not showing for some deaths

|cFF00FF00[0.5.9] - 2026-04-21|r

|cFFFFFFFFBug Fixes|r
- Class and race icons in the mini log now show on non-English clients

|cFF00FF00[0.5.7] - 2026-04-16|r

|cFFFFFFFFBug Fixes|r
- Fixed a crash in class statistics when there is no data
- Fixed crashes in creature rankings when data is missing

|cFF00FF00[0.5.6] - 2026-04-15|r

|cFFFFFFFFNew Features|r
- New Cause filter for the Search log and the Zone, Instance, Creature and Class statistics
- Mini log and heatmaps each have their own source filter

|cFFFFFFFFImprovements|r
- Statistics and class survival graphs now follow the selected cause

|cFFFFFFFFBug Fixes|r
- Statistics redraw correctly when the Cause filter changes
- PvP deaths in creature statistics show race, class and level, not 'Unknown'
- Smaller fixes

|cFF00FF00[0.5.5] - 2026-03-22|r

|cFFFFFFFFBug Fixes|r
- A new character with an old character's name no longer inherits its Hardcore status
- Fixed a crash in creature rankings caused by very high-level creatures
- Synced deaths above the max player level are ignored

|cFF00FF00[0.5.4] - 2026-03-16|r

|cFFFFFFFFNew Features|r
- Search log filter: all deaths, guild only, or guild confederation (needs GreenWall)

|cFFFFFFFFBug Fixes|r
- The search log no longer clips on the right side
- Search log filters work right away, even just after login

|cFF00FF00[0.5.3] - 2026-03-15|r

|cFFFFFFFFNew Features|r
- Refresh button in the search log that keeps your filters
- Optional auto-refresh every 10 seconds, off by default

|cFF00FF00[0.5.2] - 2026-03-11|r

|cFFFFFFFFImprovements|r
- Heatmap data is now an optional separate download, installed automatically by CurseForge

|cFFFFFFFFBug Fixes|r
- The mini log Source column now shows predicted killers
- Killer search now also finds environment damage, PvP and predicted killers

|cFF00FF00[0.5.1] - 2026-03-08|r

|cFFFFFFFFNew Features|r
- Many more class backgrounds to choose as mini log themes

|cFFFFFFFFBug Fixes|r
- The Death Alert settings panel now appears in Interface Options
- Mini log themes and the menu background now display correctly

|cFF00FF00[0.5.0] - 2026-03-06|r

|cFFFFFFFFNew Features|r
- Resizable and scalable menu that remembers its position and scale
- Guild filter for the search log
- Deaths too low level for a dungeon or raid are filtered out
- Join our Discord: click the status bar below to copy discord.gg/TrJFGcah7z

|cFFFFFFFFBug Fixes|r
- Deathlog's channel no longer moves General, Trade and LocalDefense out of place
- Fixed death alert crashes, plus Watch List fixes and a faster channel join

|cFF00FF00[0.4.5] - 2026-02-28|r
- Fixed a big FPS drop with the heatmap turned on
- New 'Heatmap Resolution' setting (Low to Ultra)
- Fixed compatibility with older game clients

|cFF00FF00[0.4.4] - 2026-02-27|r

|cFFFFFFFFNew Features|r
- In-game changelog (you're looking at it!)
- Death filter for the mini log and alerts: all, guild only or none
- GreenWall support: filter by your whole guild confederation

|cFFFFFFFFBug Fixes|r
- Fewer crashes and better stability

|cFF888888Use /dl changelog to open this anytime|r

|cFF00FF00[0.4.3] - 2026-02-26|r
- The 'newer version' message shows only once per session

|cFF00FF00[0.4.2] - 2026-02-25|r
- Fixed /played spam in secondary chat tabs

|cFF00FF00[0.4.1] - 2026-02-24|r
- New 'Auto-hide addon channels' setting
- 'Update Available' indicator on the info button
- Watch List fixes and better detection
- Fixed death alert crashes and duplicate deaths
- Fixed mini log font and click issues

|cFF888888For full details, see CHANGELOG.md|r
]]

local changelog_frame = nil

--- Check if the changelog popup is currently visible
local function isChangelogVisible()
	return changelog_frame ~= nil and changelog_frame.frame and changelog_frame.frame:IsShown()
end

--- Creates and shows the changelog popup
local function showChangelog()
	if changelog_frame then
		changelog_frame:Show()
		return
	end

	changelog_frame = AceGUI:Create("Frame") ---@type AceGUIFrame
	changelog_frame:SetTitle("Deathlog - What's New")
	changelog_frame:SetStatusText("Version " .. CURRENT_VERSION .. "  |  discord.gg/TrJFGcah7z (click to copy)")
	changelog_frame:SetLayout("Fill")
	changelog_frame:SetWidth(500)
	changelog_frame:SetHeight(450)
	changelog_frame:SetCallback("OnClose", function(widget)
		AceGUI:Release(widget)
		changelog_frame = nil
	end)

	-- Make the status bar clickable to copy Discord invite URL
	local statusbar = changelog_frame.statustext:GetParent()
	if statusbar then
		statusbar:EnableMouse(true)
		statusbar:SetScript("OnMouseUp", function()
			Deathlog_ShowCopyPopup("discord.gg/TrJFGcah7z")
		end)
	end

	local scrollFrame = AceGUI:Create("ScrollFrame") ---@type AceGUIScrollFrame
	scrollFrame:SetLayout("Flow")
	changelog_frame:AddChild(scrollFrame)

	local label = AceGUI:Create("Label") ---@type AceGUILabel
	label:SetText(CHANGELOG_CONTENT)
	label:SetFullWidth(true)
	label:SetFont(GameFontNormal:GetFont(), 12, "")
	scrollFrame:AddChild(label)

	-- Add "Don't show again for this version" checkbox at the bottom
	local checkbox = AceGUI:Create("CheckBox") ---@type AceGUICheckBox
	checkbox:SetLabel("Don't show this changelog again")
	checkbox:SetValue(false)
	checkbox:SetCallback("OnValueChanged", function(widget, event, value)
		if value then
			deathlog_settings["last_changelog_version"] = CURRENT_VERSION
		end
	end)
	scrollFrame:AddChild(checkbox)
end

--- Checks if we should show the changelog (version upgrade detected)
local function checkShowChangelog()
	local last_version = deathlog_settings["last_seen_version"]
	local last_changelog_version = deathlog_settings["last_changelog_version"]

	-- Always update to current version
	deathlog_settings["last_seen_version"] = CURRENT_VERSION

	-- Detect existing user: they have settings but no last_seen_version (pre-0.4.4 user)
	local is_existing_user = false
	if not last_version then
		-- Check if user has any other settings (minilog, etc.) indicating they're not a fresh install
		for k, _ in pairs(deathlog_settings) do
			if k ~= "last_seen_version" and k ~= "last_changelog_version" then
				is_existing_user = true
				break
			end
		end
	end

	-- Show if:
	-- 1a. We have a previous version recorded and it's different (normal upgrade), OR
	-- 1b. No previous version but user has other settings (existing user upgrading to 0.4.4+)
	-- 2. User hasn't dismissed the changelog for this version
	local is_upgrade = (last_version and last_version ~= CURRENT_VERSION) or is_existing_user
	if is_upgrade and last_changelog_version ~= CURRENT_VERSION and not NO_CHANGELOG_VERSIONS[CURRENT_VERSION] then
		-- Only show the changelog while resting (inn/city). Showing it out in the
		-- open world is intrusive, especially in Hardcore, so defer and retry
		-- until the player is resting.
		local function showWhenResting()
			if InCombatLockdown() or not IsResting() then
				C_Timer.After(5, showWhenResting)
				return
			end
			showChangelog()
		end
		C_Timer.After(3, showWhenResting)
	end
end

-- Slash command to manually open changelog
local function handleChangelogCommand()
	showChangelog()
end

-- Register slash command
SLASH_DEATHLOGCHANGELOG1 = "/dlchangelog"
SlashCmdList["DEATHLOGCHANGELOG"] = handleChangelogCommand

-- Export functions for use in deathlog.lua
Deathlog_ShowChangelog = showChangelog
Deathlog_CheckShowChangelog = checkShowChangelog
Deathlog_IsChangelogVisible = isChangelogVisible
