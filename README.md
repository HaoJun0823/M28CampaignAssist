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

This mod fills `M28CombinedArmy = 1`, `M28CAInherit = 1` and five behaviour options in campaign
sessions, before M28AI reads them, and adds hooks that propagate the takeover flag to newly
built units (see below). Three further wrappers shape combat behaviour: the player's land
combat units no longer back away mid-fight, they stop swapping targets every half second, and
factories avoid rebuilding the same unit over and over. **No unit or factory caps are applied**,
and M28AI keeps its own housekeeping — including destroying units it considers surplus. The
wrappers only change *how* units behave once they exist.

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

The mod ships no units, no blueprints and no `lua/` files. It adds six hook files:

| File | Purpose |
|---|---|
| `hook/lua/simInit.lua` | injects the campaign-only game options |
| `hook/lua/SimCallbacks.lua` | records your manual per-unit toggle |
| `hook/lua/sim/Unit.lua` | propagates the takeover to newly built units |
| `hook/mods/M28AI/lua/AI/M28Land.lua` | stops the player's land combat units from backing away |
| `hook/mods/M28AI/lua/AI/M28Orders.lua` | keeps a locked target for a few seconds |
| `hook/mods/M28AI/lua/AI/M28Factory.lua` | rerolls repeated picks when a factory builds a unit |

The three `hook/mods/M28AI/...` files are appended to M28AI's own files by the engine's
`SCR_LuaDoFileConcat`. They do not copy or modify M28AI's source; they wrap three functions
after M28AI has defined them.

## Usage

1. Launch a campaign mission.
2. Select one of your own units.
3. In the unit order panel, the alternate order slot shows an M28 "charge" icon.
4. Click it to hand that unit to M28AI; click again to take it back.

Every unit starts **not** taken over. Once you toggle a unit on, units it builds inherit the
takeover: an engineer builds a factory, the factory is taken over, and the units it produces
are taken over too. Click the icon on any of them to take it back.

`M28Active` is a shared field that M28AI writes from several places: your toggle
(`SimCallbacks.lua`), its own inheritance logic (`M28Events.lua:2150`, `OnConstructionStarted`),
`OnCreate` (which clears only the UI stat), and a few dynamic switches for transports, walls
and upgrade components. Those inheritance paths are forked threads, so deciding each unit's
state **once** from an event means whoever runs last wins. That is why earlier versions looked
randomly broken: some units inherited the takeover and some did not, depending purely on thread
order.

This addon therefore keeps its **own authoritative state** and continuously projects it back,
so event order stops mattering:

- `hook/lua/SimCallbacks.lua` wraps M28AI's toggle callback. Clicking the button records an
  explicit player intent in `unit.M28AssistManaged` and marks the unit as `Explicit`. Nothing
  downstream is allowed to override a decision you made by hand.
- `hook/lua/sim/Unit.lua` records the builder in `OnStartBuild` (excluding `Repair`), then
  resolves a new unit's authoritative state once it can see the builder (`OnStartBuild` record,
  falling back to the engine's `.Parent`). While the unit is still under construction it keeps
  following the builder, so toggling the builder mid-build updates the result too; on
  completion the unit's state is final and can be toggled independently.
- A **single** reconciler thread re-projects the authoritative state onto `M28Active`, the
  `M28Active` UI stat and `M28CombinedArmiesShowUI`. Any write M28AI makes at any time —
  including `OnCreate` clearing the stat — is corrected on the next pass. This is what removes
  the race entirely.
- Units with no builder (ACU, mission-spawned or gifted units) are deliberately left to
  M28AI's default: not taken over. A fallback in the reconciler still recognises a manual
  toggle if the callback hook ever fails to attach.

### Thread and stall safety (v5)

Earlier versions forked a short-lived resolver thread for *every* unit and kept a registry that
only grew. A 31-minute session logged `tracked=3328` while only `713` units were alive, so most
of each pass was spent walking dead slots. v5 removes that growth:

- New units join a **pending queue** handled by the same single thread; there is exactly one
  `ForkThread` in the whole mod. No concurrent writer can race the authoritative field.
- Dead registry slots are recycled, so pass cost tracks live units instead of lifetime units.
- The pass slows from 1 s to 3 s when nothing has changed for several rounds, and the
  `M28CombinedArmiesShowUI` stat is checked less often.
- One `pcall` isolates each unit and another protects the whole pass, so a bad unit cannot
  kill the only thread. A watchdog restarts the thread if it stops beating, and a generation
  counter makes the old thread exit instead of leaving two writers. An idle thread exits
  entirely and is relaunched by the next build action (also covers save/load).
- Outside campaign sessions the hooks do nothing at all.

### Behaviour tuning (v8)

The campaign `Options` table is missing the lobby options that control M28AI's play style.
`simInit.lua` fills five of them with values tuned for a more active, less survival-obsessed
campaign bot. All five are read by M28AI at runtime, so they take effect without touching its
code.

| Option | Value | Effect | Cost |
|---|---|---|---|
| `M28Aggression` | `0.6` | strongly underestimates enemy threat, so units commit to engagements and push instead of backing off | nuclear targeting becomes coarser (M28AI's own help says so) |
| `M28DodgeMicro` | `2` | disables dodge displacement entirely — stops units twitching away from slow shells | units eat slow projectiles instead of dodging |
| `M28HoverMicro` | `2` | disables air hover micro | air units no longer slow down for micro |
| `M28PrioritiseBPs` | `2` | stops M28AI forcing the same "strong" units (bricks/percies/etc.); more unit and faction variety | loses some of M28AI's hand-tuned unit matchups |
| `M28TimeBetweenOrders` | `1.0` | keeps the original 11-tick land cycle, so orders react quickly | target re-evaluation is a little busier than at `1.5` |

Three behaviours have no lobby option, so each is handled by a small wrapper. All three apply
only to the player's brain (`BrainType == 'Human'`) and only in campaign sessions; skirmish,
multiplayer and every AI brain are untouched.

- **No backing off** (`hook/mods/M28AI/lua/AI/M28Land.lua`). M28AI calls
  `BackupUnitTowardsRallyIfAvailable` to shuffle a unit a dozen metres backwards before it
  re-engages. The wrapper returns immediately for the player's land combat units, so they hold
  their ground and keep firing instead of stepping back.

  This deliberately does **not** touch `refbCanKite`. That flag means "this weapon can fire
  while moving" — it is false only for weapons that unpack and for the GC/Megalith, whose guns
  are fixed to the body. A dozen other branches read it to tell mobile units apart from
  stationary ones, so clearing it stopped the retreat but also made M28AI treat ordinary tanks
  like turrets. Set `M28AssistNoKite = 2` to restore the retreat.

- **Target stickiness** (`hook/mods/M28AI/lua/AI/M28Orders.lua`). M28AI re-evaluates targets
  roughly every half second, and every switch clears the unit's order queue — a unit can walk
  halfway to one enemy, turn around, and walk back. The wrapper pins the first target for 8
  seconds: while it is still alive and within 120 units of the shooter, later switches are
  rewritten to the pinned target. It releases on its own when the timer expires, the target
  dies, or the target runs off. Set `M28AssistStickyTarget = 2` to disable.

- **Build variety** (`hook/mods/M28AI/lua/AI/M28Factory.lua`).
  `GetBlueprintThatCanBuildOfCategory` already picks at random from its candidate list, but
  random still repeats. The wrapper remembers each factory's last three picks and rerolls once
  when the new pick matches either of the previous two, or when three picks in a row came from
  the same faction (judged by the first two characters of the unit id). Rerolling happens only in
  the plain "pick something to build" mode — the slowest/fastest/cheapest/most-expensive queries
  pass through untouched, because a reroll would break their "single best answer" meaning. Set
  `M28AssistBuildVariety = 2` to disable.

M28AI's own housekeeping is deliberately left alone. It still culls engineers when mass stalls
(`M28Economy.lua`), clears low-value units near the population cap (`M28Overseer.lua`), removes
stranded island units (`M28Land.lua`) and scattered air units (`M28Micro.lua`), and can destroy a
factory for mass (`M28Factory.lua`). All of those are part of how its economy stays afloat, so
this addon neither blocks them nor adds a cap of its own.

Why the wrappers are safe to keep across M28AI upgrades: the engine concatenates them onto
M28AI's files, and M28AI's module system uses a live environment table
(`lua/system/import.lua` builds `env`, then `doscript(name, env)`), so redefining a function
after the original definition is visible to every caller. Each wrapper depends on a small, named
contract: `BackupUnitTowardsRallyIfAvailable`, `IssueTrackedAttack` and
`GetBlueprintThatCanBuildOfCategory`, plus the `refCategoryLandCombat` constant. If a future
M28AI renames one of them, that wrapper simply stops applying — it does not corrupt the file.
Look for the `retreat micro disabled`, `target stickiness enabled` and `build variety reroll`
lines in `game.log` to confirm they attached.

### M28AI's own files are never edited

Earlier versions carried a local, hand-applied stall-guard patch to
`M28AI/lua/AI/M28Engineer.lua`. It has been reverted: the installed M28AI is byte-identical to
the official v328 release, and everything this addon does now lives in its own `hook/` tree.

## What it does NOT do

- Does **not** set `CampAI`, so campaign allies and enemies stay on the stock campaign AI.
- Does **not** touch skirmish or multiplayer. The value is injected only when
  `ScenarioInfo.type == 'campaign'`, and never overwrites a value that is already set.
- Does **not** require any M28AI source change to work. It writes game options M28AI reads and
  appends its own hook files; the installed M28AI is the official v328 release, byte for byte.
- Does **not** take over anything automatically. The option enables the *button*; each unit's
  `M28Active` flag still defaults to `0`.
- Does **not** affect campaign enemies. Every wrapper checks `BrainType == 'Human'` before doing
  anything.
- Does **not** cap unit or factory production. v6 removed the engineer and factory caps
  entirely, and v7 removed the self-destruct guard as well: M28AI is free to cull its own
  surplus, exactly as it does in skirmish.
- Does **not** destroy anything itself. The behaviour wrappers change unit orders and factory
  picks; they never kill or remove a unit.

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
M28CampaignAssist: set ScenarioInfo.Options.M28Aggression=0.6 for scenario type=campaign
M28CampaignAssist: toggle callback hooked
M28CampaignAssist: reconcile thread started (generation 1)
M28CampaignAssist: reconcile round=1 slots=... alive=... pending=... fixed=... quiet=0
M28CampaignAssist: toggle Enable=true applied to 1 unit(s)
M28CampaignAssist: inherit <unit id> <- <builder id> managed=true (builderManaged=true, builderActive=true, builderHuman=true)
M28CampaignAssist: retreat micro disabled for human campaign land combat units
M28CampaignAssist: target stickiness enabled for human campaign land combat units
M28CampaignAssist: build variety reroll active for human campaign factories
Running M28BrainCreated for brain <your player name>
Human player brain <your player name> created; Index=...
```

What to check:

- `toggle callback hooked` must be present. If it says `Callbacks table unavailable`, the
  reconciler's fallback is handling manual toggles instead — still functional, but tell the
  maintainer.
- `reconcile round=...` heartbeats (first round, then every 30 passes) prove the projection
  thread is alive. `slots` should track the number of live units rather than grow forever,
  `pending` should fall back to 0 quickly, `quiet` shows the backoff state, and `fixed` counts
  corrections for that pass — it should be small and settle near zero.
- `reconcile thread stalled, restarting` means the watchdog fired. Once is harmless; repeated
  lines point at an exception that needs the log detail.
- `toggle Enable=...` confirms the click reached the sim side and how many units it changed.
- `inherit ... managed=` shows each new unit's decision together with the builder's
  authoritative value, raw `M28Active` and whether the builder is a human unit. The first 200
  decisions are logged.

Then confirm M28AI's `SteamAIIssue` notice — *"M28AI mod is active, but no AI have been selected
that use M28AI"* — no longer appears.

## FAF / LOUD

This addon targets the retail build. On FAF, campaign support is handled by M28AI's own
`lua/aibrains/` hooks, which do not exist in the retail build at all. The addon is written
defensively — if the host already set the option, it will not overwrite it — but FAF has not
been tested with it.

## License and credits

Released under **CC BY-NC-SA 4.0**, the same license as M28AI. No M28AI source code is copied
into this addon; it only writes game options and adds its own engine hooks. The installed
M28AI is unmodified and remains covered by M28AI's license.

M28AI is by [maudlin27](https://github.com/maudlin27/M28AI).
