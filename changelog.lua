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
}

-- Changelog content (update this with each release)
local CHANGELOG_CONTENT = [[
|cFFFFD700Deathlog Changelog|r

|cFF00FF00[0.5.23] - 2026-08-12|r

|cFFFFFFFFNew Features|r
- Local moderation: right-click a death to Report player, Hide name (local-only, reversible with /dl unhide <name>, list with /dl hidden), or — for deaths a peer sent you — Report/Ignore the sender. An offensive name/guild shows in red as 'Report name'
- Report message: for a death you received live this session, file a chat report that attaches the actual broadcast text (where a griefer hides an offensive fake name) and attributes it to the real sender. Only offered while the message is still fresh in the session it arrived in
- 'Reported by' attribution: deaths that reached you via a peer now show who reported them in the minilog (optional column), the tooltip, and a new <reported_by> death-alert tag. In the main search window a reported death is marked with a trailing * after the name (hover for the reporter)

|cFFFFFFFFImprovements|r
- Anti-abuse hardening: the recent fake-death floods (junk names, impossible sources) are now rejected on every path they can arrive through — live broadcasts and background sync both validate entries before storing them, each sender is volume-capped so one player can't flood your log, and a one-time background cleanup removes fabricated entries already in your log
- 'Killed by: Reported' is gone: peer-reported deaths now predict the killer from the death location like any other unresolved source (shown with the usual trailing *), falling back to 'Unknown' when no prediction is possible

|cFF00FF00[0.5.22] - 2026-07-25|r

|cFFFFFFFFFixes|r
- Fixed the extra mini log fonts (BreatheFire, Black Chancery, Immortal, etc.) not loading. They ship with DeathNotificationLib, which is installed as its own addon rather than inside Deathlog, so the old hardcoded path pointed at a folder that doesn't exist. The path is now resolved from DeathNotificationLib itself (thanks @karaktaka)
- Fixed an error when changing a mini log column to Playtime, Guild, Last Words, Class Logo or Race Logo, or when switching to the Concise or Yazpad preset. The mini log went blank, and after a reload it reset to the middle of the screen, couldn't be dragged, and vanished from the addon settings (thanks flames57)
- Fixed mini log columns rendering blank when the same column is picked in more than one slot, or when two columns share a heading (such as Name together with Coloured Name). Every column slot is now independent

|cFF00FF00[0.5.21] - 2026-07-24|r

|cFFFFFFFFFixes|r
- Fixed the remaining 'Invalid font asset' error when changing minilog columns or presets; missing font files no longer break the options UI
- Fixed the per-feature settings panels (minilog, tooltips, heatmaps, Death Alert, etc.) going missing from the options for some players; each panel now loads independently so one failing panel can't hide the rest
- Fixed a Lua error when a death alert tried to play a sound that no longer exists (e.g. removed, or from a media addon that isn't installed); it now falls back to the default sound

|cFFFFFFFFImprovements|r
- Added a /dl versions command that prints the versions of Deathlog and its bundled components (DeathNotificationLib, data packages) and notes when a newer version has been seen from other players
- Updated the embedded UI and media libraries to their latest Classic Era 1.15.9 and TBC 2.5.6-compatible releases
- The update-available, changelog, and contribution popups now only appear while resting (inn/city) instead of anywhere out of combat, so they no longer interrupt you in the open world (important for Hardcore). Custom LibSharedMedia death-alert sounds now show up in the picker without a /reload

|cFF00FF00[0.5.20] - 2026-07-23|r

|cFFFFFFFFFixes|r
- Fixed a 'sort ran for too long' error when opening /deathlog on very large logs that left the log blank. The log is now ordered without a slow per-comparison callback, so the full result set displays with no cap
- Made the remaining heavy first-login calculations fully incremental so they can no longer trip the script limit on very large logs

|cFF00FF00[0.5.19] - 2026-07-23|r

|cFFFFFFFFFixes|r
- Fixed more 'script ran too long' errors under Classic Era 1.15.9's tighter script limits. The heavy first-login statistics and heatmap calculations are now spread across several frames, so a first login with a large death log no longer errors out (previously this needed a /reload to recover)
- Fixed a 'script ran too long' error when opening /deathlog on very large logs; the log now sorts with a single fast pass that stays within the script limit even for the entire database

|cFF00FF00[0.5.17] - 2026-07-22|r

|cFFFFFFFFBug Fixes|r
- Fixed the death alert 'Guild Only' filter sometimes not showing alerts for guild members' deaths (thanks to Fate)
- Fixed shift-clicking a player name in chat opening the Who window instead of printing the result to chat (thanks to Makpptfox)

|cFFFFFFFFImprovements|r
- The 'Inspect user' option in the mini log right-click menu now shows the result in the chat window instead of opening the Who panel (thanks to Makpptfox)
- Watch List notes can now be up to 100 characters instead of 20, so a full reminder fits (thanks to Fate)

|cFF00FF00[0.5.16] - 2026-07-16|r

|cFFFFFFFFBug Fixes|r
- Fixed Watch List clicks landing on the wrong column when the Deathlog window is scaled down; the Icon and Remove (X) buttons were unclickable (thanks to Fate)
- Fixed a death being broadcast a second time when logging back into an already-dead hardcore character, which created duplicate death entries
- Fixed an error popup that could appear when opening the Watch List tab
- Fixed an error when opening the Deathlog settings on TBC Anniversary (minimap button, /deathlog options, or the mini log menu)
- Fixed font error popups that could appear when opening the settings panel on TBC Anniversary

|cFFFFFFFFImprovements|r
- Updated for the latest WoW Classic TBC Anniversary patch (2.5.6)

|cFF00FF00[0.5.15] - 2026-06-27|r

|cFFFFFFFFNew Features|r
- Added a settings toggle to display dates in DD/MM/YY (European) format instead of MM/DD/YY (thanks to Makpptfox)
- Added a 'Sound Channel' option for death alerts; set it to 'Master' (new default) to keep alerts audible regardless of your Sound Effects volume

|cFFFFFFFFBug Fixes|r
- The world map can now be closed with the ESC key (thanks to Makpptfox)
- Fixed the 'Show death location' button in the mini log right-click menu (thanks to Makpptfox)
- Death entries with missing location data no longer reuse the previous entry's map pin (thanks to Makpptfox)
- Fixed the Watch List remove (X) button being hard to click; the whole X column is now clickable, and blank rows are no longer created

|cFF00FF00[0.5.14] - 2026-06-15|r

|cFFFFFFFFNew Features|r
- The mini log now hides its resize handle while 'Lock position' is enabled, and the Heatmap Indicator gained a 'Lock Heatmap' option that prevents dragging (thanks to Makpptfox)

|cFFFFFFFFBug Fixes|r
- Player names with special characters (umlauts, accents, tildes, etc.) now display correctly in the mini log and the main death log
- Russian (Cyrillic) player names now render correctly in the mini log and main death log

|cFFFFFFFFImprovements|r
- The mini log font no longer appears oversized after the font fix; its size now matches the previous appearance

|cFF00FF00[0.5.13] - 2026-05-25|r

|cFFFFFFFFNew Features|r
- Added mini log visibility controls: use /dl minilog to toggle it, /dl minilog show or /dl minilog hide for explicit control, or Ctrl-click the minimap button

|cFFFFFFFFImprovements|r
- Zone Statistics now opens to the last viewed zone when available, otherwise the player's current zone, before falling back to the root map

|cFF00FF00[0.5.12] - 2026-05-11|r

|cFFFFFFFFBug Fixes|r
- Fixed an issue preventing death alerts from showing for certain entries

|cFF00FF00[0.5.9] - 2026-04-21|r

|cFFFFFFFFBug Fixes|r
- Fixed class and race icons not showing in the Minilog for players on non-English game clients

|cFF00FF00[0.5.7] - 2026-04-16|r

|cFFFFFFFFBug Fixes|r
- Fixed crash when viewing class statistics with no data for the "all" aggregate
- Fixed crash in creature ranking tooltip when precomputed general stats are unavailable
- Fixed crash in deadliest creature filter when a creature entry is missing from the stats table

|cFF00FF00[0.5.6] - 2026-04-15|r

|cFFFFFFFFNew Features|r
- Shared Cause filter in the Deathlog menu — one dropdown now drives the Search Log plus Zone, Instance, Creature, and Class statistics
- Minilog, global heatmap indicator, and world map heatmap overlay each now have their own Source Filter setting
- Class survival graphs and tables now support specific causes instead of only all-cause precomputes

|cFFFFFFFFImprovements|r
- Cause-specific counts, descriptions, and empty states now update across the stats tabs, including the footer preprocessed total
- Creature rankings, class comparison tables, and instance summaries now use the selected-cause dataset instead of mixing in all-cause totals
- Exported by-cause log-normal and Kaplan-Meier tables now follow the same shipped-data and fallback-cache flow as the rest of Deathlog's precomputed data

|cFFFFFFFFBug Fixes|r
- Fixed instance, creature, and class statistics not redrawing correctly when the Cause filter changed
- Fixed sparse cause buckets breaking normalized creature rankings by falling back cleanly when a survival model is unavailable
- Fixed menu layout regressions introduced while consolidating the Cause control beside Watch List
- Fixed Creature Statistics showing "0.00%" when no data exists for the selected creature
- Fixed PvP deaths showing as "Unknown" in creature statistics — now displays race, class, and level
- Fixed Death Statistics displaying "100% occur in Azeroth" at the top-level map

|cFFFFFFFFDeathNotificationLib V14|r
- Added shared source-kind classification APIs and by-cause heatmap data plumbing used by Deathlog's new Cause filter, cause-aware stats, and per-cause heatmaps

|cFF00FF00[0.5.5] - 2026-03-22|r

|cFFFFFFFFBug Fixes|r
- Fixed HC state being inherited when a new character shares a name with a previous one — state now resets correctly on GUID mismatch
- Fixed crash in creature ranking when saved data contains creatures with an average level above the expansion cap
- Filter out synced death entries with level exceeding the max player level

|cFF00FF00[0.5.4] - 2026-03-16|r

|cFFFFFFFFNew Features|r
- Death Filter in the search log — filter by All Deaths, Guild Only, or Guild Confederation (requires GreenWall); saved between sessions
- GreenWall confederation option now shows as soon as GreenWall is installed

|cFFFFFFFFBug Fixes|r
- Fixed search log clipping on the right side
- Fixed filters not applying when first opening the search log
- Fixed guild filters matching nothing for the first 10 seconds after login
- Deferred library initialization until at least one addon has registered, fixing early channel joins

|cFF00FF00[0.5.3] - 2026-03-15|r

|cFFFFFFFFNew Features|r
- Refresh button in the search log — reload the death list while keeping active filters
- Auto-refresh the death list every 10 seconds (disabled by default, enable in options); preserves active filters

|cFF00FF00[0.5.2] - 2026-03-11|r

|cFFFFFFFFImprovements|r
- Heatmap data is now optional — shipped separately via the DeathNotificationLibData addon (auto-downloaded via CurseForge)

|cFFFFFFFFBug Fixes|r
- Fixed minilog Source column not showing predicted sources when source_id is nil
- Fixed death source search filter only matching NPC names — now also matches environment damage, PvP, and predictions
- Added tonumber() guards on all source_id usage to handle string-typed values without errors

|cFF00FF00[0.5.1] - 2026-03-08|r

|cFFFFFFFFNew Features|r
- All ArtifactUI class backgrounds now selectable as minilog themes (DK Frost, Demon Hunter, Druid, Hunter, Mage Arcane, Monk, Paladin, Priest, Priest Shadow, Rogue, Shadow, Shaman, Warlock, Warrior)

|cFFFFFFFFBug Fixes|r
- Fixed Death Alert settings panel not appearing in Interface Options
- Fixed minilog artifact themes rendering the full sprite sheet instead of the background panel region
- Fixed Deathlog menu background texture using imprecise atlas UV coordinates

|cFF00FF00[0.5.0] - 2026-03-06|r

|cFFFFFFFFNew Features|r
- Resizable & scalable menu — drag the bottom-right corner to resize; position and scale persist between sessions
- Precomputed purge data, split by expansion
- Guild filter for the search log
- DeathlogData is now a separate addon (auto-installed as a dependency)
- Instance min-level enforcement — deaths too low-level for a dungeon/raid are filtered out
- We now have an official Discord! Click the invite link in the changelog status bar to copy it: `discord.gg/TrJFGcah7z`

|cFFFFFFFFBug Fixes|r
- Fixed HardcoreDeaths channel pushing General/Trade/LocalDefense to wrong positions
- Fixed death alert crashes when settings weren't customized
- Fixed empty graphs with sparse data (division by zero)
- Fixed "Mouseover for metric details" tooltip positioning
- Fixed watchlist click-hitbox alignment for Name/Note/Icon columns
- Fixed watchlist remove behavior so only clicking the visible `X` removes an entry
- Fixed watchlist icon dropdown to show the currently selected icon
- Fixed watchlist `Last Checked` staying at "Never" due to refresh flow timing
- Cleaned up redundant guards in UI code
- Faster channel join on login
- Updated NPC data and statistics

|cFFFFFFFFImprovements|r
- Watchlist refresh cooldown text now updates live each second

|cFF00FF00[0.4.5] - 2026-02-28|r
- Fixed major FPS drop when heatmap is enabled (world map and statistics map)
- New "Heatmap Resolution" setting in options (Low / Medium / High / Ultra)
- Fixed API compatibility for older clients

|cFF00FF00[0.4.4] - 2026-02-27|r

|cFFFFFFFFNew Features|r
- In-game changelog popup (you're looking at it!)
- Death filter for minilog and alerts - show all, guild only, or none
- GreenWall support - filter by your entire guild confederation

|cFFFFFFFFBug Fixes|r
- Fixed various crashes and improved stability

|cFF888888Use /dl changelog to open this anytime|r

|cFF00FF00[0.4.3] - 2026-02-26|r
- Fixed multiple "newer version" messages per session

|cFF00FF00[0.4.2] - 2026-02-25|r
- Fixed /played spam in secondary chat tabs

|cFF00FF00[0.4.1] - 2026-02-24|r
- Fixed watchlist queries
- Fixed death alert crashes
- Fixed minilog font and click issues
- Fixed duplicate death entries
- New "Auto-hide addon channels" setting
- Improved watchlist detection
- "Update Available" indicator on info button

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
