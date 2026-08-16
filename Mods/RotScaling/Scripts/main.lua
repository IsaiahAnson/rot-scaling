-- RotScaling v1.3: difficulty mod for Grain Rot ("Helden", UE 5.7) + UE4SS.
--
-- Problem: once your gear/stats outgrow the curve, enemies stop being a
-- threat. This mod scales every ENEMY character's stats up with the dungeon
-- level, on top of whatever scaling the game already applies:
--
--   * MaxHealth        - multiplied (current health keeps its fraction)
--   * TypedDamage      - every damage entry's min/max multiplied
--   * Walk/Run/Sprint  - multiplied, capped (fast mobs feel deadlier than
--                        spongy ones, but uncapped speed breaks AI pathing)
--   * CritChance       - additive percentage points, capped
--
-- Where the numbers live (CXXHeaderDump verified 2026-08-15):
--   AHeldenCharacter.CharacterStats -> UHeldenStatsComponent
--     .TotalStats (FHeldenStats): MaxHealth, WalkSpeed, RunSpeed,
--        SprintSpeed, CritChance, TypedDamage[] { Type, Method,
--        Damage (FRangedFloat {min,max}) }
--     .CurrentHealth, .bInitalized
--   Enemy discriminator: AHeldenCharacter.AppliedCharacterPreset
--     (UHeldenCharacterPreset).CharacterType == 4 (EHeldenCharacterType::Enemy)
--     - players (1), soul vessels (2) and friendly NPCs (3) are never touched.
--   Dungeon level: HeldenGameState.CurrentDungeonRun.DungeonActor
--     .CurrentSeed.Level, with a FindAllOf("HeldenDungeonActor") max-Level
--     scan as fallback (the GameState read only resolves once a run is
--     under way, so a mod loaded mid-run needs the scan). That field reads
--     one BELOW the level shown in game, so +1 is applied - user-verified.
--
-- HOST-ONLY: stats are authoritative on the server and replicate via the
-- stats component's ReplicatedStats, so unmodded joiners fight the same
-- buffed enemies. On a client this mod detects it has no authority (no
-- GameMode exists client-side) and idles.
--
-- v1.1: diag logging (the first N characters log their name/class/type
--   verdict, and every give-up logs its reason, so the log says WHY
--   something was or wasn't scaled); GetCharacterType() fallback + enum
--   normalisation; the dungeon-level fallback scan; periodic work moved to
--   os.clock() gating rather than frame gating - the anim-BP hook fires per
--   ABP instance (~450/s with a house full of vessels), so frame counts are
--   not time (settle/drain pacing stays frame-based); CheckHost throttled.
-- v1.2: scale by the level shown in game (CurrentSeed.Level + 1).
-- v1.3: quiet by default - set CFG.VERBOSE = true for the per-enemy and
--   per-skip lines. A failed damage write still always logs. Verified live
--   across a full session: 51 scale events over 51 unique actors (nothing
--   scaled twice, so no compounding), every lever landing including the
--   nested TypedDamage min/max writes.
--
-- Landmines respected (GripAndFlip / CoinBeams / BaseGuard / RotBooster):
--   * No LoopAsync/ExecuteWithDelay timers (fatal). Per-frame BP hook only.
--   * No FKey / IsInputKeyDown / key pollers. No hotkeys at all.
--   * No K2_Set*Location / FName-from-string params (access violations).
--   * No polling FindAllOf loops - intake is NotifyOnNewObject + a bounded
--     per-frame drain, one catch-up sweep per level, slow re-sweeps.
--   * BP hooks registered lazily; pcall + error cap everywhere.
--   * Hot reload only while solo/idle (per-frame hook = teardown race).

local CFG = {
    -- All scaling is linear in the dungeon level L (L1 gets the BASE bump,
    -- each level past 1 adds PER_LEVEL more):
    --   mult = 1 + (BASE_PCT + PER_LEVEL_PCT * (L-1)) / 100
    BASE_HP_PCT        = 25,   -- L1 +25% HP, L5 +73%, L10 +133%
    HP_PCT_PER_LEVEL   = 12,

    BASE_DMG_PCT       = 15,   -- L1 +15% dmg, L5 +47%, L10 +87%
    DMG_PCT_PER_LEVEL  = 8,

    BASE_SPEED_PCT     = 5,    -- L1 +5%, +2%/level, hard cap +40%
    SPEED_PCT_PER_LEVEL = 2,
    SPEED_CAP_PCT      = 40,

    CRIT_PTS_PER_LEVEL = 0.5,  -- additive crit-chance points per level
    CRIT_CAP_PTS       = 15,

    -- Intake pacing (frame-based: relative order matters, not wall time).
    SETTLE_FRAMES  = 45,
    DRAIN_PER_FRAME = 2,
    SWEEP_WARMUP   = 180,
    MAX_TRIES      = 60,   -- retries while a spawn's preset/stats initialise
                           -- (hook overcounts frames, so this is ~a few sec)

    -- Wall-clock pacing.
    SEED_CHECK_SECS = 3,   -- new-run detection + level refresh
    RESWEEP_SECS    = 20,  -- catch-up sweep for anything the notify missed
    STATUS_SECS     = 60,  -- status line to UE4SS.log

    -- Logging. Load banner, authority, run changes, give-ups, errors, a
    -- failed damage write and the periodic status line are ALWAYS logged.
    -- VERBOSE adds one line per scaled enemy and per skipped non-enemy -
    -- invaluable when diagnosing, noise during normal play.
    VERBOSE   = false,
    DIAG_MAX  = 25,        -- cap on the per-skip lines while VERBOSE
    ERROR_CAP = 10,
}

local function Log(msg) print("[RotScaling] " .. tostring(msg) .. "\n") end

local S = {
    frame     = 0,
    errCount  = 0,
    pc        = nil,
    isHost    = nil,   -- nil = undetermined
    queue     = {},    -- { obj, readyFrame, tries }
    done      = {},    -- full name -> true (cleared on new run/world)
    applied   = 0,
    skipped   = 0,
    diag      = 0,
    level     = 0,
    seed      = nil,
    sweepDone = false,
    runErrLogged = false,
    nextSeedCheck = 0,
    nextResweep   = 0,
    nextStatus    = 0,
}

-- ---------------------------------------------------------------- helpers

local UEHelpers
pcall(function() UEHelpers = require("UEHelpers") end)

local function GetPC()
    if S.pc and S.pc:IsValid() then return S.pc end
    local pc
    if UEHelpers and UEHelpers.GetPlayerController then
        pcall(function() pc = UEHelpers.GetPlayerController() end)
    end
    if not (pc and pc:IsValid()) then
        pc = nil
        pcall(function()
            local pcs = FindAllOf("PlayerController")
            if not pcs then return end
            for _, c in ipairs(pcs) do
                if c:IsValid() and c.Player and c.Player:IsValid() then pc = c break end
            end
        end)
    end
    S.pc = pc
    return pc
end

-- A GameMode actor only exists where there is authority (listen host or
-- solo). Clients never have one, so this is a clean "am I the host" test.
local function CheckHost()
    local gm
    pcall(function() gm = FindFirstOf("GameModeBase") end)
    if gm ~= nil then
        S.isHost = gm:IsValid()
        Log(S.isHost and "authority detected - scaling active"
                      or "no authority (client) - idling")
    end
    return S.isHost
end

local function NameOf(obj)
    local n = "?"
    pcall(function() n = obj:GetFName():ToString() end)
    return n
end

local function ClassOf(obj)
    local n = "?"
    pcall(function() n = obj:GetClass():GetFName():ToString() end)
    return n
end

-- Current dungeon level + run seed. Primary read is the replicated
-- CurrentDungeonRun (MiniMap-proven); fallback scans every dungeon actor and
-- takes the highest Level (the active one regenerates in place; stale/pre-gen
-- ones idle at 0).
local function ReadRun()
    local level, seed = 0, nil
    local ok, err = pcall(function()
        local gs = FindFirstOf("HeldenGameState")
        if not gs or not gs:IsValid() then error("no HeldenGameState") end
        local run = gs.CurrentDungeonRun
        if not run then error("no CurrentDungeonRun") end
        local da = run.DungeonActor
        if not da or not da:IsValid() then error("DungeonActor not valid") end
        local info = da.CurrentSeed
        if type(info.Level) == "number" then level = info.Level end
        seed = info.Seed
    end)
    if not ok and not S.runErrLogged then
        S.runErrLogged = true
        Log("run read via GameState failed (" .. tostring(err) .. ") - trying dungeon-actor scan")
    end
    if level == 0 then
        pcall(function()
            local das = FindAllOf("HeldenDungeonActor")
            if not das then return end
            for _, d in ipairs(das) do
                if d:IsValid() then
                    local info = d.CurrentSeed
                    if type(info.Level) == "number" and info.Level > level then
                        level = info.Level
                        seed = info.Seed
                    end
                end
            end
        end)
    end
    -- CurrentSeed.Level is one below the level shown in-game (field 8 =
    -- displayed L9, user-confirmed 2026-08-15). Scale by what the player
    -- sees. Only when a run was actually found - no run stays 0.
    if seed ~= nil then level = level + 1 end
    return level, seed
end

local function Mults(level)
    local L = level
    if L < 1 then L = 1 end
    local hp  = 1 + (CFG.BASE_HP_PCT   + CFG.HP_PCT_PER_LEVEL   * (L - 1)) / 100
    local dmg = 1 + (CFG.BASE_DMG_PCT  + CFG.DMG_PCT_PER_LEVEL  * (L - 1)) / 100
    local spd = 1 + (CFG.BASE_SPEED_PCT + CFG.SPEED_PCT_PER_LEVEL * (L - 1)) / 100
    local spdCap = 1 + CFG.SPEED_CAP_PCT / 100
    if spd > spdCap then spd = spdCap end
    local crit = CFG.CRIT_PTS_PER_LEVEL * L
    if crit > CFG.CRIT_CAP_PTS then crit = CFG.CRIT_CAP_PTS end
    return hp, dmg, spd, crit
end

-- ------------------------------------------------------------------ apply

-- Returns "done" | "skip" | "retry", reason.
local function ApplyToCharacter(char)
    if not char or not char:IsValid() then return "skip", "invalid" end

    -- Enemy check. Preset can lag a few frames behind the actor spawning.
    -- Enum properties have come back as non-numbers before, so normalise
    -- hard and fall back to the GetCharacterType() UFunction.
    local raw
    pcall(function()
        local preset = char.AppliedCharacterPreset
        if (not preset or not preset:IsValid()) then preset = char.CharacterPreset end
        if preset and preset:IsValid() then raw = preset.CharacterType end
    end)
    if raw == nil then
        pcall(function() raw = char:GetCharacterType() end)
    end
    local ctype = raw
    if type(ctype) ~= "number" then ctype = tonumber(tostring(raw)) end
    if ctype == nil and raw ~= nil then
        -- last resort: string-match the enum name out of whatever this is
        local s = tostring(raw)
        if s:find("Enemy") then ctype = 4 end
    end
    if ctype == nil then return "retry", "type unreadable (raw=" .. tostring(raw) .. ")" end
    if ctype ~= 4 then
        S.skipped = S.skipped + 1
        if CFG.VERBOSE and S.diag < CFG.DIAG_MAX then
            S.diag = S.diag + 1
            Log(string.format("diag: %s (%s) type=%s -> not an enemy, skipped",
                NameOf(char), ClassOf(char), tostring(raw)))
        end
        return "skip", "type " .. tostring(ctype)
    end

    local stats = char.CharacterStats
    if not stats or not stats:IsValid() then return "retry", "no stats component" end
    local inited = false
    pcall(function() inited = stats.bInitalized end)
    if not inited then return "retry", "stats not initialised" end

    local hpM, dmgM, spdM, critAdd = Mults(S.level)
    local ts = stats.TotalStats

    -- Health: multiply the max, keep the current fraction (a sweep can catch
    -- an enemy mid-fight; topping it up would be a visible heal).
    local oldMax
    pcall(function() oldMax = ts.MaxHealth end)
    if type(oldMax) ~= "number" or oldMax <= 0 then
        return "retry", "MaxHealth=" .. tostring(oldMax)
    end
    local newMax = oldMax * hpM
    local frac = 1.0
    pcall(function()
        local cur = stats.CurrentHealth
        if type(cur) == "number" and cur > 0 and cur <= oldMax then frac = cur / oldMax end
    end)
    ts.MaxHealth = newMax
    stats.CurrentHealth = newMax * frac

    -- Speeds (capped in Mults) + crit.
    pcall(function()
        ts.WalkSpeed   = ts.WalkSpeed   * spdM
        ts.RunSpeed    = ts.RunSpeed    * spdM
        ts.SprintSpeed = ts.SprintSpeed * spdM
    end)
    pcall(function()
        local c = ts.CritChance
        if type(c) == "number" then ts.CritChance = c + critAdd end
    end)

    -- Damage: every typed-damage entry's ranged min/max. Nested
    -- struct-in-array writes are the least certain lever here, so it fails
    -- soft and reports - HP/speed still land regardless.
    local dmgEntries = 0
    local okDmg = pcall(function()
        local td = ts.TypedDamage
        for i = 1, #td do
            local d = td[i].Damage
            d.min = d.min * dmgM
            d.max = d.max * dmgM
            dmgEntries = dmgEntries + 1
        end
    end)

    S.applied = S.applied + 1
    -- A failed damage write is a real defect signal, so it logs even quiet.
    if CFG.VERBOSE or not okDmg then
        Log(string.format("L%d %s: HP %.0f->%.0f (x%.2f), dmg x%.2f (%d entries%s), spd x%.2f, crit +%.1f",
            S.level, NameOf(char), oldMax, newMax, hpM, dmgM, dmgEntries,
            okDmg and "" or " FAILED", spdM, critAdd))
    end
    return "done"
end

-- ------------------------------------------------------------------ intake

local function Enqueue(obj)
    table.insert(S.queue, { obj = obj, readyFrame = S.frame + CFG.SETTLE_FRAMES, tries = 0 })
end

local function TryProcess(entry)
    local obj = entry.obj
    if not obj or not obj:IsValid() then return end
    local key
    pcall(function() key = obj:GetFullName() end)
    if not key or S.done[key] then return end

    local ok, result, reason = pcall(ApplyToCharacter, obj)
    if not ok then
        if S.errCount < CFG.ERROR_CAP then
            S.errCount = S.errCount + 1
            Log("apply error (" .. S.errCount .. "/" .. CFG.ERROR_CAP .. "): " .. tostring(result))
        end
        result = "retry"
        reason = "lua error"
    end

    if result == "retry" then
        entry.tries = entry.tries + 1
        if entry.tries < CFG.MAX_TRIES then
            entry.readyFrame = S.frame + CFG.SETTLE_FRAMES
            table.insert(S.queue, entry)
        else
            S.done[key] = true -- give up, but say why - this is the
                               -- "enemies silently never scale" tell
            Log(string.format("gave up on %s (%s) after %d tries: %s",
                NameOf(obj), ClassOf(obj), entry.tries, tostring(reason)))
        end
    else
        S.done[key] = true
    end
end

local function CatchUpSweep()
    local n = 0
    pcall(function()
        local chars = FindAllOf("HeldenCharacter")
        if not chars then return end
        for _, c in ipairs(chars) do
            local seen = false
            pcall(function() seen = S.done[c:GetFullName()] end)
            if not seen then n = n + 1 Enqueue(c) end
        end
    end)
    if n > 0 and CFG.VERBOSE then Log("sweep queued " .. n .. " characters") end
end

pcall(function()
    NotifyOnNewObject("/Script/Helden.HeldenCharacter", function(c) Enqueue(c) end)
end)

-- ------------------------------------------------------------- frame driver

local Hooked = false

local function OnFrame()
    if S.errCount >= CFG.ERROR_CAP then return end
    S.frame = S.frame + 1
    local now = os.clock()

    if S.isHost == false then return end
    if S.isHost == nil and S.frame % 120 == 0 then
        if CheckHost() == false then return end
    end

    -- New run detection: CurrentSeed.Seed changes -> fresh enemies, fresh
    -- registry (dungeon actor and character names are reused in place -
    -- MiniMap lesson: key per-run state on the seed, never on addresses).
    if now >= S.nextSeedCheck then
        S.nextSeedCheck = now + CFG.SEED_CHECK_SECS
        local level, seed = ReadRun()
        if level ~= S.level then
            Log(string.format("dungeon level %d -> %d", S.level, level))
        end
        S.level = level
        if seed ~= S.seed then
            S.seed = seed
            S.done = {}
            S.queue = {}
            S.diag = 0
            Log(string.format("new run (seed=%s, level=%d) - registry reset",
                tostring(seed), level))
            CatchUpSweep()
        end
    end

    if not S.sweepDone and S.frame >= CFG.SWEEP_WARMUP then
        S.sweepDone = true
        S.level = ReadRun()
        S.nextResweep = now + CFG.RESWEEP_SECS
        pcall(CatchUpSweep)
    elseif S.sweepDone and now >= S.nextResweep then
        S.nextResweep = now + CFG.RESWEEP_SECS
        pcall(CatchUpSweep)
    end

    local budget = CFG.DRAIN_PER_FRAME
    while budget > 0 and #S.queue > 0 and S.queue[1].readyFrame <= S.frame do
        budget = budget - 1
        local entry = table.remove(S.queue, 1)
        local ok, err = pcall(TryProcess, entry)
        if not ok then
            S.errCount = S.errCount + 1
            Log("drain error (" .. S.errCount .. "/" .. CFG.ERROR_CAP .. "): " .. tostring(err))
        end
    end

    if now >= S.nextStatus then
        S.nextStatus = now + CFG.STATUS_SECS
        Log(string.format("status: %d enemies scaled, %d non-enemies skipped, %d queued, level %d",
            S.applied, S.skipped, #S.queue, S.level))
    end
end

local function EnsureHook()
    if Hooked then return end
    local ok, err = pcall(function()
        RegisterHook("/Game/Animation/ABP_HeldenPlayer.ABP_HeldenPlayer_C:BlueprintUpdateAnimation",
            function(self, DeltaTimeX) OnFrame() end)
    end)
    if ok then
        Hooked = true
        Log("anim-update hook registered")
    else
        Log("hook registration failed (will retry on respawn): " .. tostring(err))
    end
end

EnsureHook()

pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function(self)
        EnsureHook()
        -- ClientRestart fires during normal play too (elevator/repossession -
        -- MiniMap lesson). Cheap soft handling: drop caches, re-arm the
        -- sweep. The seed check owns the real per-run reset.
        S.pc = nil
        S.isHost = nil
        S.sweepDone = false
    end)
end)

Log(string.format("loaded v1.3 (HP +%d%%+%d/lvl, dmg +%d%%+%d/lvl, spd +%d%%+%d/lvl cap %d%%, crit +%.1fpts/lvl cap %d)",
    CFG.BASE_HP_PCT, CFG.HP_PCT_PER_LEVEL, CFG.BASE_DMG_PCT, CFG.DMG_PCT_PER_LEVEL,
    CFG.BASE_SPEED_PCT, CFG.SPEED_PCT_PER_LEVEL, CFG.SPEED_CAP_PCT,
    CFG.CRIT_PTS_PER_LEVEL, CFG.CRIT_CAP_PTS))
