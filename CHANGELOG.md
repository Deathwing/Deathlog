# Changelog

All notable changes to Deathlog will be documented in this file.

## [0.5.23] - 2026-08-12

### New Features
- **Local moderation for offensive entries.** Right-clicking a death in the log or minilog now offers:
  - **Report player / Report name** — opens Blizzard's in-game report dialog for the dead character. When the name (or its guild) trips the profanity filter the entry is shown in red as "Report name".
  - **Hide name** — removes every entry for that character from your log and stops your client from sharing them onward. It is purely local (it never deletes data from anyone else) and fully reversible with `/dl unhide <name>`. A confirmation popup explains what will happen. `/dl hidden` lists everything you have hidden.
  - **Report sender / Ignore sender** — for deaths a peer broadcast to you, report or mute the player who sent it. Ignoring a sender drops all of their future live broadcasts, matched on the server-stamped chat identity so a rename or a spoofed name can't slip past.
  - **Report message** — for a death you received live this session, files a chat report that attaches the actual broadcast text (which is where a griefer hides an offensive fake name) and attributes it to the real sender. Only offered while the message is still fresh in the session it arrived in.
- **"Reported by" attribution.** Deaths that reached you through a peer now show who reported them, in the minilog (optional "ReportedBy" column), the tooltip ("Reported by" row, toggleable), and via a new `<reported_by>` death-alert tag. In the main search window a reported death is instead marked with a trailing `*` after the name (hover for the reporter), keeping the table compact.

### Improvements
- **Anti-abuse hardening against fake-death floods.** The recent wave of fabricated deaths (junk names, impossible sources) is now rejected on every path it can arrive through: both live broadcasts and background sync validate entries before storing them, each sender is volume-capped so a single player can no longer flood your log with hundreds of entries, and a one-time background cleanup removes fabricated entries already sitting in your log.
- **"Killed by: Reported" is gone.** Peer-reported deaths carry no killer information, so the killer is now predicted from the death location like any other unresolved source (shown with the usual trailing `*`), and when no prediction is possible the killer shows as "Unknown" instead of "Reported".

## [0.5.22] - 2026-07-25

### Fixes
- Fixed the extra mini log fonts (BreatheFire, Black Chancery, Immortal, and the rest) not loading. They ship with DeathNotificationLib, which is installed as its own addon rather than inside Deathlog, so the old hardcoded path pointed at a folder that does not exist. The path is now resolved from DeathNotificationLib itself, so the fonts work no matter how it is installed. (#6, thanks @karaktaka)
- Fixed an error when changing a mini log column to Playtime, Guild, Last Words, Class Logo, or Race Logo, or when switching to the Concise or Yazpad preset. The mini log would then go blank, and after a reload it reset to the middle of the screen, could not be dragged, and its entry disappeared from the addon settings. Columns added after the mini log was first built now get set up properly instead of erroring. (thanks flames57)
- Fixed mini log columns rendering blank when the same column is selected in more than one slot, or when two columns share a heading (such as Name together with Coloured Name). Every column slot is now independent, so the same column can be shown as many times as you like.

## [0.5.21] - 2026-07-24

### Fixes
- Fixed the remaining "Invalid font asset" error when changing minilog columns or presets. Font previews now ignore missing or removed font files instead of aborting the options UI.
- Fixed the per-feature settings panels (minilog, tooltips, heatmaps, Death Alert, etc.) going missing from the Deathlog options for some players. Each settings panel now loads independently, so one panel failing on a saved value can no longer prevent the others from appearing.
- Fixed a Lua error when a death alert tried to play a sound that no longer exists (for example a sound removed or provided by a media addon that isn't installed). The alert now falls back to the default sound instead of erroring.

### Improvements
- Added a `/dl versions` command that prints the versions of Deathlog and its bundled components (DeathNotificationLib and, if installed, the data packages), and notes when a newer version has been seen from other players.
- Updated the embedded Ace3 (`Release-r1390`), LibSharedMedia (`v12.0.3`), and LibDBIcon (`v12.0.3`) libraries to their latest Classic Era 1.15.9 and TBC 2.5.6-compatible releases.
- The update-available, changelog, and contribution popups now only appear while you are resting (in an inn or city) instead of anywhere out of combat, so they no longer interrupt you in the open world — important for Hardcore. Custom death-alert sounds registered through LibSharedMedia now also appear in the sound picker without a `/reload`.

## [0.5.20] - 2026-07-23

### Fixes
- Fixed a "sort ran for too long" error when opening `/deathlog` on very large logs, which left the log tab blank. The log is now ordered by grouping deaths by date and sorting only the (much smaller) set of distinct dates, avoiding the slow per-comparison callback that tripped the sort limit. The full result set is still shown, with no cap.
- Made the remaining heavy first-login calculations fully incremental so no single step can trip the "script ran too long" limit on very large logs (per-class level distributions and parent-zone heatmap aggregation now yield partway through their work like the other precomputations).

## [0.5.19] - 2026-07-23

### Fixes
- Fixed more "script ran too long" errors under the tighter script execution limits of Classic Era 1.15.9. The heavy first-login statistics and heatmap precomputation now processes the death log incrementally across multiple frames (yielding partway through the work itself), so even a single very large calculation no longer trips the per-frame limit. A first login, or the first login after an update, with a large death log no longer errors out. This previously required a `/reload` to recover. (Thanks to everyone who reported the login, statistics, and heatmap errors)
- Fixed a "script ran too long" error when opening `/deathlog` on very large logs. The log now sorts with a single fast pass (a plain date comparator instead of converting dates on every comparison), which stays within the script limit even when sorting the entire database.

## [0.5.18] - 2026-07-23

### Fixes
- Fixed a "sort ran for too long" error on large death logs that broke the minilog under the tighter script execution limits of Classic Era 1.15.9. The date sort comparator no longer converts dates on every comparison, and the minilog only selects the newest entries it can display instead of sorting the entire log. (#5, thanks @Spigot12)

### Improvements
- Updated the TOC for WoW Classic Era 1.15.9.

## [0.5.17] - 2026-07-22

### Bug Fixes
- Fixed the death alert "Guild Only" filter sometimes not showing alerts for guild members' deaths: a death that had already reached the database through background sync suppressed the subsequent live alert for the same death, and the guild check could reject guildmates right after login before the guild cache was populated. The alert "Test" button now also works while a guild filter is active. (Thanks to Fate for reporting)
- Fixed shift-clicking a player name in chat opening the Who window instead of printing the result to chat. This happened when a Deathlog background lookup left the who-to-UI flag set; the flag is now reset when shift-clicking player links. (Thanks to Makpptfox)

### Improvements
- Added an in-game official download-source chooser for GitHub, CurseForge, and Wago. When a newer peer version is detected, use `/dl update` or click the existing update indicator to open it.
- Release tags now produce installable GitHub assets and publish the bundled addon family to Wago while retaining split dependency packages on CurseForge.
- The "Inspect user" option in the mini log right-click menu now shows the /who result in the chat window instead of opening the Who panel, giving more info at a glance. (Thanks to Makpptfox)
- Increased the Watch List note character limit from 20 to 100, so notes can hold a full reminder instead of being cut off. (Thanks to Fate for reporting)

## [0.5.16] - 2026-07-16

### Bug Fixes
- Fixed Watch List clicks landing on the wrong column when the Deathlog window is scaled down — the Icon and Remove (X) buttons were unclickable and clicking them opened the Note editor instead. (Thanks to Fate for reporting)
- Fixed a death being broadcast a second time when logging back into an already-dead hardcore character, which created duplicate death entries.
- Fixed a "bad argument #3 to 'SetFont'" error when opening the Watch List tab, caused by invalid font flags that newer clients no longer accept.
- Fixed an "outside of expected range" error on TBC Anniversary (2.5.6) when opening the settings via the minimap button, `/deathlog options`, or the mini log menu. The client no longer accepts a category name string in `Settings.OpenToCategory`; the embedded AceConfigDialog-3.0 was updated to upstream r1390 (minor 92) and the numeric category ID returned by `AddToBlizOptions` is now used (with an AceConfigDialog window fallback).
- Fixed "Invalid font asset" errors on TBC Anniversary from the font dropdown widget (SharedMediaWidgets), which called `SetFont` with an empty font path when a widget was released or a font failed to resolve.

### Improvements
- Updated the TOC for WoW Classic 2.5.6 (TBC Anniversary).

## [0.5.15] - 2026-06-27

### New Features
- Added a settings toggle to display dates in DD/MM/YY (European) format instead of MM/DD/YY. (Thanks to Makpptfox)
- Added a "Sound Channel" option for death alerts. Setting it to "Master" (the new default) keeps alerts audible regardless of your in-game Sound Effects volume.

### Bug Fixes
- The world map can now be closed with the ESC key. (Thanks to Makpptfox)
- Fixed the "Show death location" button in the mini log right-click menu, which failed to place the map pin due to map coordinates not being parsed correctly. (Thanks to Makpptfox)
- Death entries with missing location data no longer reuse the previous entry's map pin. (Thanks to Makpptfox)
- Fixed the Watch List remove (X) button being difficult or impossible to click; the entire X column is now clickable. Blank watch list rows can no longer be created and existing empty entries are cleaned up automatically.

## [0.5.14] - 2026-06-15

### New Features
- The mini log now hides its resize/scaling handle while "Lock position" is enabled, and the Heatmap Indicator gained a "Lock Heatmap" option that prevents it from being dragged. (Thanks to Makpptfox)

### Bug Fixes
- Player names with special characters (umlauts, accents, tildes, etc.) now display correctly in the mini log and the main death log. The western locale fonts (English, German, French, Spanish, Italian, Portuguese) were switched from a Chinese font that lacked extended-Latin glyphs to `FRIZQT__.TTF`, which has full coverage.
- Russian (Cyrillic) player names — which can appear on western servers — now render correctly in the mini log and main death log via an automatic per-name swap to a Cyrillic-capable font.

### Improvements
- The mini log font no longer appears oversized after the font change; its rendered size now matches the previous appearance.

## [0.5.13] - 2026-05-25

### New Features
- Added mini log visibility controls: use `/dl minilog` to toggle it, `/dl minilog show` or `/dl minilog hide` for explicit control, or Ctrl-click the minimap button.

### Improvements
- Zone Statistics now opens to the last viewed zone when available, otherwise the player's current zone, before falling back to the root map.

## [0.5.12] - 2026-05-11

### Bug Fixes
- Fixed an issue preventing death alerts from showing for certain entries

## [0.5.11] - 2026-05-10

### Bug Fixes
- Fixed death alerts not updating after the initial load — `DeathNotificationLib.UpdateDeathAlert()`

## [0.5.10] - 2026-04-28

### Improvements
- Death Alerts are now also filtered based on purge status

## [0.5.9] - 2026-04-21

### Bug Fixes
- Fixed race icon (RaceLogoSquare) not displaying for non-English clients — `rmap` now uses the locale-independent `clientFileString` (e.g. `"NightElf"`) instead of the localized `raceName`
- Fixed class icon (ClassLogo1/ClassLogo2) not displaying for non-English clients — texture map now uses the locale-independent class token (e.g. `"ROGUE"`) instead of the localized class name

## [0.5.8] - 2026-04-18

### Improvements
- Changelog now only shows in case a real user facing change is made, not for internal version bumps that don't affect functionality (e.g. V14 → V15)

## [0.5.7] - 2026-04-16

### Bug Fixes
- Fixed crash when viewing class statistics with no data for the "all" aggregate — `GetClassInfo("all")` is no longer called
- Fixed crash in creature ranking tooltip when precomputed general stats are unavailable
- Fixed crash in deadliest creature filter when a creature entry is missing from the stats table

## [0.5.6] - 2026-04-15

### New Features
- **Shared Cause filter** in the Deathlog menu — one dropdown now drives the Search Log plus Zone, Instance, Creature, and Class statistics from a single selection
- **Widget source filters** — the Minilog, global heatmap indicator, and world map heatmap overlay now each have a dedicated Source Filter setting
- **Cause-aware survival models** — class survival graphs and tables now work for specific causes instead of being limited to all-cause precomputes

### Improvements
- Cause-specific counts, descriptions, and empty states now update across the statistics tabs, including the footer preprocessed total
- Creature rankings, class comparison tables, and instance summaries now read from the selected-cause dataset instead of mixing in all-cause totals
- Exported by-cause log-normal and Kaplan-Meier tables now follow the same shipped-data and fallback-cache flow as the rest of the precomputed Deathlog data

### Bug Fixes
- Fixed instance, creature, and class statistics not redrawing correctly when the Cause filter changed
- Fixed sparse cause buckets breaking normalized creature rankings by falling back cleanly when a survival model is unavailable
- Fixed menu layout regressions introduced while consolidating the Cause control beside Watch List
- Fixed Creature Statistics showing "0.00% of all X deaths are caused by Unknown" when no data exists for the selected creature
- Fixed PvP deaths showing as "Unknown" in creature statistics and deadliest creature rankings — PvP sources now display the player's race, class, and level
- Fixed Death Statistics displaying a meaningless "100% of all deaths occur in Azeroth" sentence at the top-level map

### DeathNotificationLib V14
- Added shared source-kind classification APIs and by-cause heatmap data plumbing used by Deathlog's new Cause filter, cause-aware stats, and per-cause heatmaps

## [0.5.5] - 2026-03-22

### Bug Fixes
- Fixed HC state being incorrectly inherited when a new character is created with the same name as a previous one — `getHcState` now compares GUID in addition to name, and resets state in-place when either mismatches
- Fixed crash in creature ranking when saved data contains creatures with an average level above the current expansion cap (e.g. TBC data loaded on a Classic Era client)
- Filter out synced death entries with level exceeding the max player level

## [0.5.4] - 2026-03-16

### New Features
- **Death Filter** in the search log — filter deaths by All Deaths, Guild Only, or Guild Confederation (requires GreenWall). Your selection is saved between sessions
- **GreenWall confederation** option now appears in filter dropdowns as soon as GreenWall is installed, even before its config finishes loading

### Bug Fixes
- Fixed search log clipping on the right side — scrollbar no longer cuts off content
- Fixed filters not applying when first opening the search log — persisted filter settings are now respected on initial load
- Fixed guild member cache being empty for the first 10 seconds after login, causing guild filters to match nothing
- Deferred library initialization until at least one addon has registered, fixing channel joins and timers firing before any addon was ready
- Widened truncated settings labels ("Accept legacy protocol messages", "Auto-configure Blizzard death tracking")

### Improvements
- GreenWall status text now appears directly under the Death Filter in the settings panel

## [0.5.3] - 2026-03-15

### New Features
- **Refresh button** in the search log — manually reload the death list while preserving all active filters
- **Auto-refresh** — optionally auto-refresh the death list every 10 seconds; disabled by default, enable it in the options. Active filters are preserved when refreshing

## [0.5.2] - 2026-03-11

### Improvements
- Heatmap data is now optional — shipped separately via the DeathNotificationLibData addon (auto-downloaded via CurseForge)

### Bug Fixes
- Fixed minilog Source column not showing predicted sources when `source_id` is nil
- Fixed death source search filter only matching NPC names — now also matches environment damage, PvP sources, and predicted sources
- Added `tonumber()` guards on all `source_id` usage to handle string-typed values in saved data without errors

## [0.5.1] - 2026-03-08

### New Features
- **Minilog artifact themes** — all ArtifactUI class backgrounds are now selectable as minilog themes (Death Knight Frost, Demon Hunter, Druid, Hunter, Mage Arcane, Monk, Paladin, Priest, Priest Shadow, Rogue, Shadow, Shaman, Warlock, Warrior)

### Bug Fixes
- Fixed Death Alert settings panel not appearing in Interface Options
- Fixed minilog artifact themes rendering the full sprite sheet instead of the background panel region (now uses correct atlas UV crop via `SetTexCoord`)
- Fixed Deathlog menu background texture using imprecise UV coordinates — now uses the correct atlas crop for the Rogue BG region

## [0.5.0] - 2026-03-06

### New Features
- **Resizable & scalable menu** — drag the bottom-right corner to resize and scale the Deathlog window; position and scale are saved between sessions
- **Precomputed purge data** — purged players are now filtered using precomputed checksums, split by expansion (Classic Era / TBC)
- **Guild filter** in search log — filter the death log by guild name
- **DeathlogData** is now a separate addon, installed automatically as a dependency
- **Instance minimum level enforcement** — deaths from players too low-level for a dungeon or raid are now filtered out (e.g. a level 1 death in AQ20 is no longer counted)
- **Deathlog Discord** — join the community on Discord for support, feedback, and discussion: `discord.gg/TrJFGcah7z` (invite link also available in the changelog status bar)

### Improvements
- `wow_project_id` is now recorded in saved variables, improving expansion-aware data collection
- Faster addon channel join on login (0.5s delay, down from 5.0s)
- Dropdown menus refactored away from legacy `UIDropDownMenu` API
- Global functions renamed from `deathlog_*` to `Deathlog_*` to follow proper naming conventions
- Global constants renamed from `precomputed_*` to `PRECOMPUTED_*`
- Proper `ADDON_LOADED` event handling for SavedVariables initialization
- Updated NPC data, heatmaps, and precomputed statistics with latest death data
- Type annotations added throughout for IDE support
- Instance min-level filtering works across both Classic Era and TBC
- Watchlist interaction zones now match visible UI columns more precisely (Name/Note/Icon)
- Watchlist remove action now triggers only when clicking directly on the visible `X` icon
- Watchlist icon dropdown now displays the currently selected icon in the control itself
- Watchlist refresh cooldown text now updates live each second instead of staying static
- Watchlist `Last Checked` now updates reliably when refresh queries run

### Bug Fixes
- Fixed HardcoreDeaths channel pushing General, Trade, and LocalDefense to wrong positions in the channel list
- Fixed death alert crash when settings hadn't been customized (messages now fall back to defaults)
- Fixed death alert frame initialization nil errors
- Fixed empty/broken graphs when only 1 death exists for a class — log-normal std dev is now clamped to a minimum of 0.01 to prevent division by zero
- Fixed "Mouseover for metric details" tooltip being positioned off-screen in the deadliest creature panel
- Removed 9 redundant `> 0` guards across UI files

### DeathNotificationLib V9
- See DeathNotificationLib CHANGELOG for full details

## [0.4.5] - 2026-02-28

### Performance
- Fixed major FPS drop caused by heatmaps — textures are now created on-demand and hidden when empty, instead of rendering all 10,000 cells every frame (applies to both the world map overlay and the statistics map)
- Added "Heatmap Resolution" setting (Low / Medium / High / Ultra) to reduce grid density for better performance on slower machines

### Bug Fixes
- Fixed API compatibility for older clients (pre-1.14.4) that lack `C_AddOns` namespace

## [0.4.4] - 2026-02-27

### New Features
- **In-game changelog popup** — see what's new after each update! Use `/dl changelog` to open it anytime
- **Death filter** — filter the minilog and death alerts to show only guild deaths, or disable notifications entirely
- **GreenWall support** — if you use GreenWall, you can filter by your entire guild confederation

### Bug Fixes
- Fixed various crashes related to minilog settings and tooltips
- Fixed "Playtime" column causing errors
- Improved stability when widgets load before settings are ready

## [0.4.3] - 2026-02-26

### Bug Fixes
- Fixed multiple "newer version available" messages appearing per session — now only one notification per addon per `/reload`, regardless of how many different newer versions are detected from peers

### DeathNotificationLib V7
- Unified version notification logic across VersionCheck and Sync modules into a single shared function (`notifyNewerVersion`)
- Sync's watermark-based version hint now delegates to the same once-per-session notification path used by social-channel broadcasts

## [0.4.2] - 2026-02-25

### Bug Fixes
- Fixed /played time message showing up in secondary chat tabs — players with multiple chat windows no longer see unwanted "Time Played" spam

### DeathNotificationLib V6
- Fixed played-time suppression for players with multiple chat tabs

## [0.4.1] - 2026-02-24

### Bug Fixes
- Fixed watchlist queries not being sent correctly
- Fixed a crash when death alerts played before the alert style was fully loaded
- Fixed minilog font errors when a custom font wasn't available yet — falls back to the default font until it loads
- Fixed minilog entries not being clickable or highlightable — several invisible UI elements were blocking mouse input across the entry area; all resolved
- Fixed duplicate death log entries caused by party members and sync each producing different checksums for the same death — name-based dedup now covers all paths, dedup window widened to 120s, and a one-time cleanup merges existing duplicates on login
- Fixed late-arriving high-quality broadcasts (e.g. SELF from the dying player) being silently discarded when a lower-quality entry had already committed due to network timing spread

### Improvements
- New **Auto-hide addon chat channels** setting — when disabled, Deathlog's chat channels (death alerts, sync) remain visible in your chat frames for debugging; enabled by default
- Watchlist now reactively detects deaths from **all** sources (sync manager, peer broadcasts, guild queries) via `HookOnNewEntry`, instead of relying solely on active polling when the tab is open
- The watchlist now broadcasts all watched player names over the death alerts channel so every connected addon user can check their local DB and whisper back matches — dramatically improves detection speed across the realm; per-name guild/say queries still run as a fallback
- On login, the watchlist scans the local death database for any watched players who died while you were offline and prints a chat notification
- The `addonless_logging` setting is now respected in all display paths — addonless entries (no class/race) synced from other players are hidden in the search log, minilog, and statistics when the setting is disabled; entries remain stored so toggling the setting back on reveals them instantly
- Info button now shows an **"Update Available"** tooltip when a newer Deathlog version is detected from peers, including the current and new version numbers
- On Hardcore characters (where the info button is normally hidden), it re-appears specifically to surface the update notification

### DeathNotificationLib V5
- Fixed a Blizzard-side memory leak caused by high-traffic addon channels — eliminates the gradual lag increase some players experienced even with sync disabled
- Sync no longer causes frame-rate drops when processing large databases
- Sync sessions no longer overlap when multiple peers trigger them simultaneously
- Multiple fixes for duplicate death entries from party members and sync
- Fixed a race condition that could show a predicted killer instead of the real one when the actual killer was known
- Fixed late-arriving higher-quality death reports being discarded when a lower-quality report had already been saved
- Addon version checks now also work over party, raid, guild, and instance chat — you'll see update notifications faster
- New watchlist channel query lets all connected users help find watched player deaths across the realm
- Messages from newer protocol versions are now safely rejected to prevent processing incompatible data

---

## [0.4.0] - 2026-02-22

### Bug Fixes
- Fixed inverted right-click menu conditions — Block User, Whisper Player, and Check Spoof now actually trigger when the option is available (affected both minilog and main search log)

### Improvements
- Zone and Instance filter dropdowns now skip the expansion submenu layer when only one expansion is present, reducing unnecessary clicks on single-expansion realms
- CTA widget uses `SOURCE` enum constants instead of raw string keys
- Removed unused `cta_threshold` setting reference from the CTA widget
- Minor cleanup: suppressed unused loop variable warning in entry counter init
- Updated precomputed stats for Vanilla and TBC with latest death data

### DeathNotificationLib V4
- Added Feign Death guard — Hunters using Feign Death are no longer falsely reported as dead in party/raid death detection
- Sync entry processing is now batched (8 entries per tick) to prevent frame spikes from large `E$` bursts
- Watermark broadcast timing jittered (10–40 s initial delay, ±20 % ongoing variance) to avoid client phase-locking

---

## [0.3.0] - 2026-02-21

### New: Smarter Death Detection & Enrichment
- **Automatic `/who` enrichment** — Blizzard's death messages only include the player's name; Deathlog now runs a background `/who` lookup to fill in level, class, race, and guild automatically
- **Party/raid death reporting** — deaths of your group members are captured and broadcast with full details, even if they don't have Deathlog installed
- **Universal death broadcast parser** — a single `BlizzardParser` built from Blizzard's own `HARDCORE_CAUSEOFDEATH_*` globals replaces the old hand-written per-locale parsers, supporting all 11 client languages out of the box (including positional format arguments and known Blizzard typos)

### New: Background Database Sync
- Automatically exchange death entries with other Deathlog users over a dedicated addon channel — no setup required
- Configurable sync window, interval, cooldown, and max entries per session
- New settings panel: Interface → AddOns → Deathlog → Database Sync

### New: Playtime Tracking
- Your total `/played` time is now recorded in every death report
- Displayed in the minilog, search log, tooltips, and death alerts
- New `<playtime>` substitution tag for death alert messages (e.g., "died after 2d 14h 32m")
- Tooltip toggle: show or hide playtime (enabled by default)
- **Privacy opt-out**: disable "Include playtime in death report" in settings
- Compatible with HardcoreTBC addon's playtime data

### New: Death Alert Overhaul
- **Group syntax** for context-aware messages:
  - `(...)` relaxed group — shown if at least one tag inside has a value
  - `[...]` strict group — shown only if **all** tags inside have values
  - Example: `<name>( the <race> <class>)[ of <guild>] has been slain by <source>[ at lvl <level>][ in <zone>].`
- New `<guild>` substitution tag — works in all message types
- **Real-time input validation** — detects unknown tags, unbalanced groups, nested groups, and empty groups with clear error messages
- All 9 locales updated with new group-syntax default messages

### New: Data Contribution Prompt
- One-time popup when you've collected a large database, asking you to share your data
- Persistent banner in the main menu shows your entry count with contact info

### Improvements
- Hardcore status info button in the main menu — shows your tracking state, supported realms, and detected addons
- Server filter dropdown in the search log now actually filters results
- Right-click menu options properly disabled when not applicable (e.g., "Show death location" grayed out without location data)
- Minimap button saves its position correctly across reloads
- Creature ranking tooltip no longer incorrectly fires on player units
- Corpse tooltip now uses Blizzard's `CORPSE_TOOLTIP` global instead of per-locale word tables
- PvP killer name captured and stored in `extra_data` for Blizzard-sourced deaths
- Duplicate entries merged using quality-aware logic — higher-quality reports (self > peer > Blizzard) take priority, unique fields from both are preserved
- Removed 8 development-only SavedVariables, reducing disk and memory usage
- Settings panel reordered: Report Widget now appears last
- Modular DeathNotificationLib architecture (split into focused modules)
- Updated precomputed stats with latest death data
- Expansion filter for instance grid (TBC only)

### Bug Fixes
- Fixed missing heatmap overlays for TBC zones
- Removed global override that broke Blizzard's `CHAT_CHANNEL_PASSWORD` popup for other addons
- Raid warning removal for Hardcore deaths now only matches the expected format, avoiding interference with other addons
- Shaman class color on Classic realms correctly set to 0, 112, 221 without overriding `RAID_CLASS_COLORS` globally

---

## [0.2.0] - 2026-02-06

### New: TBC Anniversary / Soul of Iron Support
- Full support for **Burning Crusade Anniversary** realms
- Detects Soul of Iron buff and Tarnished Soul debuff automatically
- All TBC dungeons, raids, and Outland zones included
- Your hardcore status is saved between sessions

### New: Death Report Widget
- When a nearby player loses their Soul of Iron, a popup appears
- Click to help report their death - works even if they don't have Deathlog!
- Draggable widget with configurable timeout
- Help build the community death database by reporting deaths you witness

### New: Continental Map Views
- View combined heatmap and death stats for **Azeroth**, **Kalimdor**, **Eastern Kingdoms**, or **Outland**
- Great for seeing the bigger picture of where deaths occur

### Improvements
- Zone and Instance dropdowns now organized by expansion (Classic / TBC submenus)
- Scrollable instance selection grid (supports all 50+ instances)
- Improved pagination: shows "Page X / Y" format
- "Whisper player" option added to death log right-click menu
- Environmental deaths (Falling, Drowning, Lava, etc.) now show proper icons in creature stats
- Warning message when playing on an unsupported realm

### Bug Fixes
- Min/Max level filters in search now work correctly
- Watch list "Remove" button actually removes entries now
- Fixed heatmap positioning for TBC zones
- Fixed creature highlighting on continental maps
- Search results reset to page 1 when applying filters
- Various UI fixes for empty rows and tooltips
