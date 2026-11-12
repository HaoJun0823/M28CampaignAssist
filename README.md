# M28CampaignAssist

A small companion mod for [M28AI](https://github.com/maudlin27/M28AI) that makes M28AI's
**combined AI/human armies** feature — handing your own units over to the AI, one unit at a
time — usable in **single-player campaign missions** on the Steam / GOG retail build of
*Supreme Commander: Forged Alliance*.

Without it, M28AI never offers you that per-unit toggle in a campaign, because campaign
sessions never carry lobby game options.

---

## What it does

M28AI exposes its per-unit takeover behind exactly one game option,
`ScenarioInfo.Options.M28CombinedArmy`. That field is written by the skirmish lobby.

Single-player campaigns never go through a lobby. `lua/SinglePlayerLaunch.lua`
(`SetupCampaignSession`) rebuilds `ScenarioInfo.Options` from scratch and fills in only six
fields:

```
FogOfWar, Difficulty, DoNotShareUnitCap, Timeouts, GameSpeed, FACampaignFaction
```

M28AI then reads a missing option, falls back to `tonumber(... or 2)` — which means
*disabled* — and consequently neither shows the toggle button nor registers your brain as an
M28 brain. The feature is effectively dead in campaign, no matter that the mod is loaded.

This mod fills two fields with `1` in campaign sessions, before M28AI reads them:

| Option | Effect |
|---|---|
| `M28CombinedArmy` | enables the per-unit takeover button |
| `M28CAInherit` | enables inheritance: whatever a taken-over unit builds is taken over too |

Both are M28AI's own options, with M28AI's own semantics. The addon only writes the values
the campaign session failed to carry over; it implements no behaviour of its own.

## Requirements

| Item | Detail |
|---|---|
| Game | *Supreme Commander: Forged Alliance*, Steam or GOG retail build |
| M28AI | **v328** enabled in the mod manager |
| Campaign mod loading | On the retail build, campaign normally ignores selected mods. This addon assumes you already use a campaign mod enabler — e.g. `TF_CampaignModEnabler_FA.scd`, which overrides `GetCampaignMods`. If M28AI itself does not load in your campaign, this addon has nothing to attach to. |

## Install

1. Copy the whole `M28CampaignAssist` folder into the game's `mods/` directory, so you end up
   with `.../Supreme Commander Forged Alliance/mods/M28CampaignAssist/mod_info.lua`.
2. Enable **both** `M28AI` and `M28CampaignAssist` in the in-game mod manager.
3. Start a campaign mission. Nothing else to configure.

The mod ships no units, no blueprints and no `lua/` files — only a single
`hook/lua/simInit.lua`.

## Usage

1. Launch a campaign mission.
2. Select one of your own units.
3. In the unit order panel, the alternate order slot shows an M28 "charge" icon.
4. Click it to hand that unit to M28AI; click again to take it back.

Every unit starts **not** taken over. From the moment you take one over, everything it builds
inherits the takeover — see below.

## Contagion (v3)

`M28CAInherit = 1` turns on M28AI's own inheritance rule, which is evaluated in
`M28Events.OnConstructionStarted` — that is, at the instant a build order starts, not when it
finishes:

```lua
if builder.M28Active and brain.BrainType == 'Human'
   and tonumber(ScenarioInfo.Options.M28CAInherit or 2) == 1 then
    built.M28Active = true
    built:UpdateStat('M28Active', 1)
end
```

Factories are builders too, so the chain works in both directions:

| You take over | It builds | Result |
|---|---|---|
| engineer | factory | factory is taken over at the moment construction starts |
| engineer | power plant, shield, mex… | taken over |
| factory | tank, gunship, engineer… | taken over |
| taken-over factory | engineer | taken over, and that engineer's own builds inherit in turn |
| ACU (if you toggle it) | anything | taken over |

Four limits worth knowing, all of them M28AI's behaviour rather than the addon's:

- **No retroactivity.** Units already finished before you toggle the builder stay as they were.
- **Start of build, not end.** A unit whose construction had already begun when you toggled the
  builder will not inherit; the next one will.
- **One-way.** Taking the builder back does not take its children back. Toggle them individually.
- **Inherited units are normal taken-over units.** They can be toggled off, and M28AI controls
  them exactly as if you had clicked them yourself.

## What it does NOT do

- Does **not** set `CampAI`, so campaign allies and enemies stay on the stock campaign AI.
- Does **not** touch skirmish or multiplayer. The value is injected only when
  `ScenarioInfo.type == 'campaign'`, and never overwrites a value that is already set.
- Does **not** modify M28AI's source. It is a separate mod that writes two fields M28AI reads.
- Does **not** take over anything automatically. The option enables the *button*; each unit's
  `M28Active` flag still defaults to `0`. Inheritance only spreads from a unit you already
  took over.

## Known log messages

Campaign sessions are missing several other options M28AI assumes, so once the per-unit feature
becomes active, M28AI logs the following. All of them originate in M28AI, not in this addon,
and none is fatal:

| Log line | Cause | Effect |
|---|---|---|
| `attempt to concatenate field 'CampAI' (a nil value)` | M28AI concatenates a missing option | that warning routine aborts; some chat notices are skipped |
| `No unit cap specified` | `ScenarioInfo.Options.UnitCap` is absent in campaign | M28AI skips `SetArmyUnitCap` |
| `access to nonexistent global variable GetRestrictions` | `/lua/game.lua` has no `GetRestrictions` in campaign | the campaign restriction poll gives up |
| `No ACU or SACU after 600 ticks so will abort` | some missions spawn your ACU only after the intro movie, later than M28AI's 600-tick window | M28AI stops managing your ACU for that mission |

## Verifying it works

Search `game.log` for:

```
M28CampaignAssist: set ScenarioInfo.Options.M28CombinedArmy=1 for scenario type=campaign
M28CampaignAssist: set ScenarioInfo.Options.M28CAInherit=1 for scenario type=campaign
Running M28BrainCreated for brain <your player name>
Human player brain <your player name> created; Index=...
```

Then confirm M28AI's `SteamAIIssue` notice — *"M28AI mod is active, but no AI have been selected
that use M28AI"* — no longer appears.

## FAF / LOUD

This addon targets the retail build. On FAF, campaign support is handled by M28AI's own
`lua/aibrains/` hooks, which do not exist in the retail build at all. The addon is written
defensively — if the host already set the option, it will not overwrite it — but FAF has not
been tested with it.

## License and credits

Released under **CC BY-NC-SA 4.0**, the same license as M28AI. No M28AI source code is copied
here; this mod only writes a game option that M28AI reads.

M28AI is by [maudlin27](https://github.com/maudlin27/M28AI).
