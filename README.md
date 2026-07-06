# RaidPulse

Real-time raid and Mythic+ analytics for World of Warcraft — with local parse
approximations computed against a Warcraft Logs benchmark snapshot.

## Features

- Post-fight report after every raid boss kill / wipe and every Mythic+ run
- Local parse (~NN) per player, per role, calibrated against WCL bracket
  rankings for the current tier
- DPS / HPS metric column that mirrors the WCL report layout
- Death timeline, defensive tracking, timeline of key events
- Raid buff check window
- Sync between players who have the addon (opt-in)

## Slash commands

- `/rp` — open the last report
- `/rp show` — same as above
- `/rp buffs` — open the raid buff check window
- `/rp minimap` — re-enable the minimap button if hidden
- `/rp export` — text export of the last report
- `/rp share` — post the DPS/HPS summary to party/raid chat
- `/rp debug on|off`
- `/rp sync on|off`
- `/rp test` — load a synthetic report (for UI testing)

## Benchmark data

The parse values shown in-game come from `BenchmarksDB.lua`, which is
generated externally from the Warcraft Logs public API. See
[`raidpulse-benchmarks/`](../raidpulse-benchmarks/) for the generator tool.

The bundled `BenchmarksDB.lua` in this repo is a placeholder; you must run
the generator once and drop the produced file into the addon folder for
parses to work.

## Version

1.0 — first release under the RaidPulse name (previously
MidnightCombatAnalytics).
