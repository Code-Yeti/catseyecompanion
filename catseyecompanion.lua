--[[
* catseyecompanion - read-only bridge from the game client to the CatseyeXI Companion desktop app.
*
* Writes %APPDATA%\com.ffxi.catseyecompanion\live.json about once a second with what the client already knows:
* position, target, jobs, learned and set Blue Magic, storage, and the raw quest/mission log packets.
*
* CatseyeXI addon policy tier T2 (Information): this addon only READS client memory and OBSERVES incoming packets.
* It never sends packets, never queues commands, never writes game memory, and doesn't play the game.
--]]

addon.name    = 'catseyecompanion';
addon.author  = 'CatseyeXI Companion';
addon.version = '1.0';
addon.desc    = 'Read-only data bridge for the CatseyeXI Companion app.';
addon.link    = 'https://catseyexi.com/addon-policy';

require('common');
local json = require('json');
local blu  = require('blu');

local dir  = os.getenv('APPDATA') .. '\\com.ffxi.catseyecompanion';
local file = dir .. '\\live.json';

local STORAGES = { 0, 1, 2, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }; -- see find.lua (3 = temporary: skipped)

local state = T{
    tick = 0,            -- os.clock() of the last write check
    last = '',           -- last written body without the timestamp (to skip identical writes)
    lastWrite = 0,
    storage = nil,       -- { [container] = { {id, count}, ... } }, refreshed every 30s
    storageTick = -100,
    events = T{},        -- learned-spell events since load: { spellId, zoneId, mob, time }
    lastMob = nil,       -- last mob we had targeted (for "learned from")
    ventureLog = T{},    -- tracked chat lines: Ventures (plus the lines right after, for lists), replies to your ! commands,
                         -- training/Records of Eminence progress: { text, mode, time, n }, last 100
    ventureUntil = 0,    -- os.clock() until which following lines are kept too
    lineNo = 0,          -- n: tells apart identical lines in the same second
    rewardUntil = 0,     -- os.clock() until which EXP/limit lines are kept (they follow a regime/RoE completion)
    lastKill = nil,      -- name of the last mob a "defeats" line named (regime lines carry it as mob)
    wsUsed = T{},        -- your recent weapon skills: { ws, target, sc (skillchain message or 0), time }, last 30
    moves = T{},         -- recent monster TP moves seen in action packets: { actor, skill, ready, time }, last 20
    logs = T{},          -- raw 0x056 quest/mission log payloads by log type (hex)
    blueSpells = nil,    -- { {id, name}, ... } every Blue Magic spell the client knows about
    err = nil,
};

-- Every Blue Magic spell in the client's resources (skill 43), once.
local function blue_spell_list()
    if (state.blueSpells ~= nil) then return state.blueSpells; end
    local list = T{};
    local res = AshitaCore:GetResourceManager();
    for id = 0, 1024 do
        local s = res:GetSpellById(id);
        if (s ~= nil and s.Skill == 43 and s.Name[1] ~= nil and s.Name[1] ~= '') then
            list:append({ id = id, name = s.Name[1] });
        end
    end
    state.blueSpells = list;
    return list;
end

local function read_storage()
    local inv = AshitaCore:GetMemoryManager():GetInventory();
    local out = {};
    for _, c in ipairs(STORAGES) do
        local items = {};
        for i = 0, inv:GetContainerCountMax(c) do
            local e = inv:GetContainerItem(c, i);
            if (e ~= nil and e.Id ~= 0 and e.Id ~= 65535) then
                items[#items + 1] = { e.Id, e.Count };
            end
        end
        out[tostring(c)] = items;
    end
    return out;
end

local function collect()
    local mm     = AshitaCore:GetMemoryManager();
    local party  = mm:GetParty();
    local player = mm:GetPlayer();
    local ent    = mm:GetEntity();
    local me     = party:GetMemberTargetIndex(0);
    if (me == 0 or party:GetMemberName(0) == nil or party:GetMemberName(0) == '') then
        return nil; -- not in the world yet (title screen, zoning)
    end

    -- Ashita's X/Y are the ground plane and Z is height; export in LandSandBoat's convention (y = height).
    local data = {
        v       = 1,
        char    = party:GetMemberName(0),
        zone    = party:GetMemberZone(0),
        pos     = { x = ent:GetLocalPositionX(me), y = ent:GetLocalPositionZ(me), z = ent:GetLocalPositionY(me) },
        mainJob = player:GetMainJob(), mainLevel = player:GetMainJobLevel(),
        subJob  = player:GetSubJob(),  subLevel  = player:GetSubJobLevel(),
    };

    local tgt = mm:GetTarget();
    local ti  = tgt:GetTargetIndex(0);
    if (ti ~= 0 and ti ~= me) then
        local name = ent:GetName(ti);
        local isMob = bit.band(ent:GetSpawnFlags(ti), 0x10) ~= 0;
        data.target = { name = name, index = ti, id = tgt:GetServerId(0), hpp = ent:GetHPPercent(ti), mob = isMob };
        if (isMob) then state.lastMob = name; end
    end
    data.engaged = ent:GetStatus(me) == 1;
    -- Equipped main/sub/ranged weapons, with the weapon skill points a trial weapon has earned: the first two bytes of
    -- the item's extdata (LandSandBoat Exdata::WeaponUnlock.UnlockPoints). Index lookup as equipmon does it.
    local inv = mm:GetInventory();
    local weapons = {};
    for slot = 0, 2 do
        local eq = inv:GetEquippedItem(slot);
        if (eq ~= nil and eq.Index ~= 0) then
            local it = inv:GetContainerItem(bit.band(eq.Index, 0xFF00) / 0x0100, eq.Index % 0x0100);
            if (it ~= nil and it.Id ~= 0 and it.Id ~= 65535) then
                weapons[#weapons + 1] = { slot = slot, id = it.Id, wsPoints = struct.unpack('H', it.Extra, 1) };
            end
        end
    end
    data.weapons = weapons;
    -- Experience and limit/merit points (the same values the expbar addon reads).
    data.exp = {
        cur = player:GetExpCurrent(), need = player:GetExpNeeded(),
        limit = player:GetLimitPoints(), merits = player:GetMeritPoints(), meritsMax = player:GetMeritPointsMax(),
        limitMode = player:GetIsLimitModeEnabled() or player:GetIsExperiencePointsLocked(),
    };

    -- Learned Blue Magic (the same check blucheck uses), sent with names so the app can match custom spells.
    local known = {};
    for _, s in ipairs(blue_spell_list()) do
        if (player:HasSpell(s.id)) then known[#known + 1] = { s.id, s.name }; end
    end
    data.bluKnown = known;
    -- Trusts known (trust spells are client ids 896-1023).
    local trusts = {};
    for id = 896, 1023 do
        if (player:HasSpell(id)) then trusts[#trusts + 1] = id; end
    end
    data.trustKnown = trusts;

    -- Current set and points (only meaningful with BLU main or sub).
    if (blu.is_blu_main() or blu.is_blu_sub()) then
        local ok, set, spent, max = pcall(function ()
            return blu.get_spells(), blu.get_spent_points(), blu.get_max_points();
        end);
        if (ok) then
            local ids = {};
            for _, v in ipairs(set) do if (v ~= 0) then ids[#ids + 1] = v + 512; end end
            data.bluSet = ids;
            data.bluPoints = { spent = spent, max = max };
        end
    end

    if (os.clock() - state.storageTick >= 30 or state.storage == nil) then
        state.storageTick = os.clock();
        local ok, s = pcall(read_storage);
        if (ok) then state.storage = s; end
    end
    data.storage = state.storage;
    data.events  = state.events;
    data.moves   = state.moves;
    data.wsUsed  = state.wsUsed;
    data.ventureLog = state.ventureLog;
    data.logs    = state.logs;
    return data;
end

local function write(body)
    ashita.fs.create_directory(dir);
    local tmp = file .. '.tmp';
    local f = io.open(tmp, 'w');
    if (f == nil) then state.err = 'cannot write ' .. tmp; return; end
    f:write(body);
    f:close();
    os.remove(file);
    os.rename(tmp, file);
    state.lastWrite = os.time();
    state.err = nil;
end

ashita.events.register('d3d_present', 'csc_present', function ()
    if (os.clock() - state.tick < 1.0) then return; end
    state.tick = os.clock();
    local ok, data = pcall(collect);
    if (not ok) then state.err = tostring(data); return; end
    if (data == nil) then return; end
    local body = json.encode(data);
    -- Write on change, plus a heartbeat every 5s so the app knows the addon is alive.
    if (body ~= state.last or os.time() - state.lastWrite >= 5) then
        state.last = body;
        data.ts = os.time();
        write(json.encode(data));
    end
end);

-- Observe incoming packets only (never modified, never blocked).
ashita.events.register('packet_in', 'csc_packet_in', function (e)
    -- 0x029 Message Basic, message 419: "<player> learns <spell>!" (same check as blucheck).
    if (e.id == 0x0029) then
        local msg = struct.unpack('H', e.data, 0x18 + 0x01);
        if (msg == 419) then
            local spellId = struct.unpack('L', e.data, 0x0C + 0x01);
            local sender  = struct.unpack('H', e.data, 0x14 + 0x01);
            local me = AshitaCore:GetMemoryManager():GetParty():GetMemberTargetIndex(0);
            if (sender == me) then
                state.events:append({ spell = spellId, zone = AshitaCore:GetMemoryManager():GetParty():GetMemberZone(0),
                                      mob = state.lastMob, time = os.time() });
                state.storageTick = -100; -- force a fresh write soon
            end
        end
        return;
    end
    -- 0x028 Action: monster TP moves ("readies" = category 7, "uses" = category 11), as shown in the chat log.
    -- Bit layout as in HXUI's action parser: actor at bit 40, category at 82, action id at 86, first target at 150.
    if (e.id == 0x0028) then
        local bits = function (off, len) return ashita.bits.unpack_be(e.data_raw, 0, off, len); end
        local category = bits(82, 4);
        -- 3 = your own finished weapon skill (as in the chat log), with the skillchain it closed, if any: the first
        -- target's first action has an "additional effect" whose message is the skillchain (bits 271, then 299).
        if (category == 3 and bits(40, 32) == AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0)) then
            local sc = bits(271, 1) == 1 and bits(299, 10) or 0;
            state.wsUsed:append({ ws = bits(86, 16), target = bits(150, 32), sc = sc, time = os.time() });
            while (#state.wsUsed > 30) do table.remove(state.wsUsed, 1); end
            return;
        end
        if (category ~= 7 and category ~= 11) then return; end
        local skill = bits(86, 32);
        if (category == 7) then
            if (bits(86, 16) ~= 24931) then return; end -- 24931 = started (28787 = interrupted); upper 16 bits vary
            skill = bits(213, 17);               -- first target's first action param = the ability being readied
        end
        state.moves:append({ actor = bits(40, 32), skill = skill, ready = category == 7, time = os.time() });
        while (#state.moves > 20) do table.remove(state.moves, 1); end
        return;
    end
    -- 0x056 Quest/Mission Log: keep the raw payload per log type; the app decodes it.
    if (e.id == 0x0056) then
        local logType = struct.unpack('H', e.data, 0x24 + 0x01);
        local bytes = {};
        for i = 0x04, 0x23 do bytes[#bytes + 1] = string.format('%02x', e.data:byte(i + 1)); end
        state.logs[tostring(logType)] = table.concat(bytes);
        return;
    end
    -- Inventory finished loading / changed: refresh storage on the next write.
    if (e.id == 0x001D or e.id == 0x0020) then
        state.storageTick = -100;
    end
end);

-- Observe chat text only (never modified or blocked): keep lines about Ventures, and the server's reply to your own
-- "!" commands (!ventures, !points, !wspoints...), i.e. lines within 2s after either. Each line keeps its chat mode
-- so the app can tell the server's replies from battle messages.
ashita.events.register('text_in', 'csc_text_in', function (e)
    local ok, text = pcall(function () return e.message:strip_colors():strip_translate(true); end);
    if (not ok) then text = e.message; end
    text = text:gsub('[%c]', ''):gsub('^%s+', '');
    if (text == '') then return; end
    local me = AshitaCore:GetMemoryManager():GetParty():GetMemberName(0) or '';
    local lower = text:lower();
    -- The last mob defeated ("X defeats the Steelshell." / "The Steelshell falls to the ground."): a regime line doesn't
    -- name its target, so it carries this along. Remembered only, not logged.
    local killed = text:match('defeats (.-)%.$') or text:match('^(.-) falls to the ground');
    if (killed) then state.lastKill = (killed:gsub('^[Tt]he ', '')); return; end
    -- Training progress lines: regimes ("designated target ... (Progress: 2/4)"), Records of Eminence (name, then a
    -- "Progress: 78/200." line) and other "(n/m)" counts.
    local training = lower:find('records of eminence', 1, true) or lower:find('designated target', 1, true)
        or lower:find('regime', 1, true) or text:find('^Progress: %d+/%d+') or text:find('%(%d+/%d+%)');
    -- A completion's reward ("Arcadea gains 600 experience points."): kept only within 2s after a completion line.
    if (training and lower:find('completed', 1, true)) then state.rewardUntil = os.clock() + 2; end
    local reward = os.clock() <= state.rewardUntil and (lower:find('experience points', 1, true) or lower:find('limit points', 1, true));
    if (reward) then
    elseif (lower:find('venture', 1, true) or (me ~= '' and text:find(me .. ' : !', 1, true) == 1)) then
        state.ventureUntil = os.clock() + 2;
    elseif (not training and os.clock() > state.ventureUntil) then
        return;
    end
    state.lineNo = state.lineNo + 1;
    state.ventureLog:append({ text = text, mode = bit.band(e.mode, 0xFF), time = os.time(), n = state.lineNo,
        mob = lower:find('designated target', 1, true) and state.lastKill or nil });
    while (#state.ventureLog > 100) do table.remove(state.ventureLog, 1); end
end);

ashita.events.register('command', 'csc_command', function (e)
    local args = e.command:args();
    if (#args == 0 or (args[1] ~= '/csc' and args[1] ~= '/catseyecompanion')) then return; end
    e.blocked = true;
    print(string.format('[catseyecompanion] writing %s | last write %s | %s', file,
        state.lastWrite > 0 and os.date('%H:%M:%S', state.lastWrite) or 'never', state.err or 'ok'));
end);
