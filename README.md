# Shogun 2 co-op turn-end fix (experimental)

This workspace contains a reversible, version-guarded fix profile and a guarded legacy-binary overlay helper for Total War: SHOGUN 2. It does not claim the requested 20-turn success yet: two independent human players and an internet campaign are required for that validation, and this computer cannot supply the second player.

For the simplest distribution, download the repository as a ZIP, extract it, and double-click `Install.bat` on every human player’s PC. No administrator prompt is expected. `Uninstall.bat` removes only the marked profile block.

For the full legacy-build experiment, have every player double-click `Download-LegacyDepots.bat` instead. It opens that player’s Steam Console, copies one depot command at a time to the clipboard, verifies all four completed downloads, starts the guarded legacy installer, and installs the same random-seed profile. Steam credentials and Steam Guard remain entirely on that player’s machine; the helper does not ask for or store them.

## What the local investigation found

- The installed game is `D:\SteamLibrary\steamapps\common\Total War Shogun 2`.
- The installed Windows executable is the May 2023 build (`shogun2.exe` and `shogun2.retail.exe` SHA-256 `0AB284186E0BE3FBCDE34E2F800E3C0328008F3219490C7C25E822ADD837C4A9`). The campaign engine DLL is SHA-256 `022FAE2E2DA92B59B8B1B8EE52887003C624E3C8ECA060B209F5D792A7F874F5`.
- The existing local `mp_battle_desync.txt` records a `BATTLE_ENV` setup-checksum mismatch between two players. That is evidence of divergent simulation state, not merely a dropped connection.
- The native engine contains a `constant_random_seed` command described as fixing the random seed for battle and campaign setup, plus separate logging, checksum-gate, desync-kick, and stall controls.

The correct first profile therefore makes the campaign setup seed explicit and identical on both machines. It deliberately does not disable desync kicks or stall disconnects: those settings can turn a detectable divergence into the exact indefinite wait that was reported.

The game’s normal pack/mod layer is not a native-code patch mechanism. A binary NOP patch cannot be justified from the current evidence because the discovered resync references include UI callbacks and command registration, not a verified faulty turn-barrier routine. The optional overlay path below uses a real older executable set as the control instead of inventing bytes.

## Use the profile first

Run these commands on both players’ machines, with the game and Steam closed where noted:

```powershell
.\Install.bat
```

The equivalent PowerShell commands are:

```powershell
Set-Location 'C:\Users\jimba\Documents\Codex\shogun_2_multiplayer_mod'
.\Shogun2CoopFix.ps1 -Action Status
.\Shogun2CoopFix.ps1 -Action InstallProfile
```

The installer locates the user script at `%APPDATA%\The Creative Assembly\Shogun2\scripts\user.script.txt`, preserves an existing file as a timestamped backup, and replaces only its own marked block. Both players must use the same seed and the same game/mod files. Start from a new campaign or a save from before the first turn-end failure.

To remove only the marked profile block:

```powershell
.\Shogun2CoopFix.ps1 -Action RestoreProfile
```

If the hang recurs, collect diagnostics on both machines and then remove the diagnostic profile after the run:

```powershell
.\Shogun2CoopFix.ps1 -Action InstallDiagnostics
.\Shogun2CoopFix.ps1 -Action ShowLogSummary
.\Shogun2CoopFix.ps1 -Action RestoreProfile
```

Diagnostics are intentionally not part of the normal profile because extra synchronization logging can affect timing and produces large files.

## Binary control: pre-update Windows depot

The official May 24, 2023 note describes a compiler/architecture update and a CPU crash fix, but does not mention a multiplayer synchronization fix. SteamDB identifies the current public build as `11306771`; a community rollback guide records the pre-update Windows depot manifests. The downloaded layout is expected to contain `app_34330\depot_34331`, `depot_34332`, `depot_34333`, and `depot_34334`.

```text
download_depot 34330 34331 686532749519328994
download_depot 34330 34332 7514500714585308624
download_depot 34330 34333 1972056557494830740
download_depot 34330 34334 8572849454388416810
```

The recommended route is now to double-click `Download-LegacyDepots.bat` on both machines. Steam’s Console does not expose a dependable command-submission API, so the helper opens it and copies each command to the clipboard; the player pastes it into Steam and waits for Steam to finish. The helper then requires the exact expected file count, byte total, and legacy executable hashes before it starts the installer. This avoids applying a partial 20 GB depot download.

If needed, the four commands can still be entered manually. After all four are downloaded, double-click `Install-LegacyBuild.bat`. It uses `Install-LegacyBuild.ps1` to apply the four depot contents in order, backs up native files beside the game, moves the post-update `shogun2.retail.exe` aside, and copies the old executable/data/localization files. Data is not duplicated into the backup unless `-BackupData` is supplied; Steam file verification is the recovery path for current data.

```powershell
.\Install-LegacyBuild.ps1 -Action Status
.\Install-LegacyBuild.ps1 -Action Install -LegacyRoot 'C:\Program Files (x86)\Steam\steamapps\content\app_34330'
.\Download-LegacyDepots.ps1 -Action Status
```

The older `Install-LegacyBinaryOverlay.ps1` name remains as a compatibility wrapper. The installer refuses an incomplete source, refuses to run while Shogun 2 is running, creates a dated native-file backup, and can restore the latest backup:

```powershell
.\Restore-LegacyBuild.bat
```

This helper overlays the expected depot files recursively. Native files are backed up by default; the large data/locales files are not duplicated into the backup unless `-BackupData` is supplied. If the complete legacy build is tested, every participant must use a coherent, identical set of legacy files; mixing current and legacy data is not a valid multiplayer test. Steam file verification will restore the current build, so keep the backup and test procedure available.

## Validation target

For a meaningful result, record the result of each turn for both players:

1. Verify identical game build hashes and identical enabled mods.
2. Start a fresh two-human internet co-op campaign.
3. Complete turns 1 through 20, including at least one end-turn where each player has actionable units and one where a battle is resolved.
4. Mark a failure only when the game reaches a persistent turn-end wait, reports a desync, or the two campaign states visibly diverge. Save immediately before and after the failure and keep both players’ sync logs.

The profile is a candidate fix, not a proven 20-turn result. The legacy executable overlay is the stronger experiment: if both players can complete 20 turns with it but not with the current build, that establishes a build regression and gives us a concrete pair of binaries for a subsequent minimal binary-diff transplant.

## Sources

- [Creative Assembly’s May 24, 2023 Shogun 2 update note](https://store.steampowered.com/news/posts/?enddate=1684935181&feed=steam_community_announcements)
- [SteamDB depot/build information](https://steamdb.info/app/34330/depots/)
- [Steam rollback guide with the pre-update manifest IDs](https://steamcommunity.com/sharedfiles/filedetails/?id=3251800526)
- [Creative Assembly’s original multiplayer resynchronisation update](https://store.steampowered.com/news/8429/)
- [Official Shogun 2 user-script documentation](https://wiki.totalwar.com/w/Battle_XML_Documentation.html)
