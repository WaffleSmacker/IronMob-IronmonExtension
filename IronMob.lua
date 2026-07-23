-- IronMob Bridge Extension for Ironmon Tracker
-- Communicates with the IronMob Bridge application via file I/O (no BizHawk networking).
-- Place this file in your Tracker's extensions/ folder.
-- Place IronMobBridge.exe in extensions/IronMob/ subfolder.

--[[ json.lua - compact pure-Lua JSON library (stringify + parse) ]]--

local json = {}

local function kind_of(obj)
  if type(obj) ~= 'table' then return type(obj) end
  local i = 1
  for _ in pairs(obj) do
    if obj[i] ~= nil then i = i + 1 else return 'table' end
  end
  if i == 1 then return 'table' else return 'array' end
end

local function escape_str(s)
  local in_char  = {'\\', '"', '/', '\b', '\f', '\n', '\r', '\t'}
  local out_char = {'\\', '"', '/',  'b',  'f',  'n',  'r',  't'}
  for i, c in ipairs(in_char) do
    s = s:gsub(c, '\\' .. out_char[i])
  end
  return s
end

local function skip_delim(str, pos, delim, err_if_missing)
  pos = pos + #str:match('^%s*', pos)
  if str:sub(pos, pos) ~= delim then
    if err_if_missing then error('Expected ' .. delim .. ' near position ' .. pos) end
    return pos, false
  end
  return pos + 1, true
end

local function parse_str_val(str, pos, val)
  val = val or ''
  local early_end_error = 'End of input found while parsing string.'
  if pos > #str then error(early_end_error) end
  local c = str:sub(pos, pos)
  if c == '"'  then return val, pos + 1 end
  if c ~= '\\' then return parse_str_val(str, pos + 1, val .. c) end
  local esc_map = {b = '\b', f = '\f', n = '\n', r = '\r', t = '\t'}
  local nextc = str:sub(pos + 1, pos + 1)
  if not nextc then error(early_end_error) end
  return parse_str_val(str, pos + 2, val .. (esc_map[nextc] or nextc))
end

local function parse_num_val(str, pos)
  local num_str = str:match('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
  local val = tonumber(num_str)
  if not val then error('Error parsing number at position ' .. pos .. '.') end
  return val, pos + #num_str
end

function json.stringify(obj, as_key)
  local s = {}
  local kind = kind_of(obj)
  if kind == 'array' then
    if as_key then error('Can\'t encode array as key.') end
    s[#s + 1] = '['
    for i, val in ipairs(obj) do
      if i > 1 then s[#s + 1] = ', ' end
      s[#s + 1] = json.stringify(val)
    end
    s[#s + 1] = ']'
  elseif kind == 'table' then
    if as_key then error('Can\'t encode table as key.') end
    s[#s + 1] = '{'
    for k, v in pairs(obj) do
      if #s > 1 then s[#s + 1] = ', ' end
      s[#s + 1] = json.stringify(k, true)
      s[#s + 1] = ':'
      s[#s + 1] = json.stringify(v)
    end
    s[#s + 1] = '}'
  elseif kind == 'string' then
    return '"' .. escape_str(obj) .. '"'
  elseif kind == 'number' then
    if as_key then return '"' .. tostring(obj) .. '"' end
    return tostring(obj)
  elseif kind == 'boolean' then
    return tostring(obj)
  elseif kind == 'nil' then
    return 'null'
  else
    error('Unjsonifiable type: ' .. kind .. '.')
  end
  return table.concat(s)
end

json.null = {}

function json.parse(str, pos, end_delim)
  pos = pos or 1
  if pos > #str then error('Reached unexpected end of input.') end
  local pos = pos + #str:match('^%s*', pos)
  local first = str:sub(pos, pos)
  if first == '{' then
    local obj, key, delim_found = {}, true, true
    pos = pos + 1
    while true do
      key, pos = json.parse(str, pos, '}')
      if key == nil then return obj, pos end
      if not delim_found then error('Comma missing between object items.') end
      pos = skip_delim(str, pos, ':', true)
      obj[key], pos = json.parse(str, pos)
      pos, delim_found = skip_delim(str, pos, ',')
    end
  elseif first == '[' then
    local arr, val, delim_found = {}, true, true
    pos = pos + 1
    while true do
      val, pos = json.parse(str, pos, ']')
      if val == nil then return arr, pos end
      if not delim_found then error('Comma missing between array items.') end
      arr[#arr + 1] = val
      pos, delim_found = skip_delim(str, pos, ',')
    end
  elseif first == '"' then
    return parse_str_val(str, pos + 1)
  elseif first == '-' or first:match('%d') then
    return parse_num_val(str, pos)
  elseif first == end_delim then
    return nil, pos + 1
  else
    local literals = {['true'] = true, ['false'] = false, ['null'] = json.null}
    for lit_str, lit_val in pairs(literals) do
      local lit_end = pos + #lit_str - 1
      if str:sub(pos, lit_end) == lit_str then return lit_val, lit_end + 1 end
    end
    local pos_info_str = 'position ' .. pos .. ': ' .. str:sub(pos, pos + 10)
    error('Invalid json syntax starting at ' .. pos_info_str)
  end
end

--[[ === IronMob Bridge Extension === ]]--

local function IronMobBridge()
	local self = {}

	self.name = "IronMob Bridge"
	self.author = "WaffleSmacker"
	self.description = "Chat vs Streamer bridge for IronMob. Click Options to launch the Bridge application."
	self.version = "1.4"
	self.github = "WaffleSmacker/IronMob-IronmonExtension"
	self.url = string.format("https://github.com/%s", self.github)

	-- === ROM Detection ===
	local isNatDex = false
	local function checkIsNatDex()
		local success, result = pcall(function()
			local natDexMonCount = Memory.read32(0x08000170)
			return (natDexMonCount == 1210)
		end)
		if success then return result end
		return false
	end

	-- === EWRAM Memory Addresses ===
	-- Addresses differ between Natdex and vanilla FRLG builds.
	-- Detected at startup via checkIsNatDex() and set once.
	local use_twitchname, twitch_name_shown, sText_TwitchName
	local use_topDono, top_donator_shown, sText_SubAmount, sText_TopDonator
	local use_twitchpokename, sText_TwitchPokemon
	local twitch_trainer_pic, use_twitch_trainer_pic
	local gTwitchMove, waitingMove, waitingTimer, battleLockedToAi

	local function setAddresses()
		isNatDex = checkIsNatDex()
		if isNatDex then
			-- Natdex-Ironmob ROM addresses
			use_twitchname         = 0x03f000
			twitch_name_shown      = 0x03f004
			sText_TwitchName       = 0x03f008
			use_topDono            = 0x03f020
			top_donator_shown      = 0x03f024
			sText_SubAmount        = 0x03f028
			sText_TopDonator       = 0x03f02c
			use_twitchpokename     = 0x03f044
			sText_TwitchPokemon    = 0x03f048
			twitch_trainer_pic     = 0x03f054
			use_twitch_trainer_pic = 0x03f058
			gTwitchMove            = 0x03f05c
			waitingMove            = 0x03f060
			waitingTimer           = 0x03f06c
			battleLockedToAi       = 0x03f070
		else
			-- Vanilla FRLG (Pokefirered_modified) addresses
			use_twitchname         = 0x03fc44
			twitch_name_shown      = 0x03fc48
			sText_TwitchName       = 0x03fc4c
			use_topDono            = 0x03fc64
			top_donator_shown      = 0x03fc68
			sText_SubAmount        = 0x03fc6c
			sText_TopDonator       = 0x03fc70
			use_twitchpokename     = 0x03fc88
			sText_TwitchPokemon    = 0x03fc8c
			twitch_trainer_pic     = 0x03fc98
			use_twitch_trainer_pic = 0x03fc9c
			gTwitchMove            = 0x03fca8
			waitingMove            = 0x03fcac
			waitingTimer           = 0x03fcb0
			battleLockedToAi       = 0x03fcb4
		end
	end
	setAddresses()

	-- Override Tracker GameSettings for the non-Natdex modified ROM
	-- (same approach as NatDexExtension.lua - fixes battle phase detection)
	local function overrideGameSettingsForModifiedRom()
		if isNatDex then return end  -- NatDex extension handles its own overrides
		local GS = GameSettings
		if not GS then return end
		GS.BattleIntroDrawPartySummaryScreens    = 0x08013d6c + 0x1
		GS.BattleIntroOpponentSendsOutMonAnimation = 0x0801405c + 0x1  -- BattleIntroRecordMonsToDex
		GS.HandleTurnActionSelectionState        = 0x08014a70 + 0x1
		-- 0x080165c0 is the vanilla address; the stall-loop code added in
		-- battle_main.c shifted this (and everything after it) by +0x28.
		-- Verified live: gBattleMainFunc parks at 0x080165E9 after gBattleOutcome
		-- is set. A stale value here means the Tracker NEVER fires afterBattleEnds.
		GS.ReturnFromBattleToOverworld           = 0x080165e8 + 0x1
		GS.Task_EvolutionScene                   = 0x080ce8f0 + 0x1
		GS.FriendshipRequiredToEvo               = 0x08042ec4 + 0x13e  -- GetEvolutionTargetSpecies + 0x13e
		GS.gBattleMainFunc                       = 0x03004f84
		GS.gBattleResults                        = 0x03004f90
	end

	-- === File I/O paths ===
	local bridgeFolder = ""
	local outboxPath   = ""
	local inboxPath    = ""
	local logPath      = ""

	-- === Logging ===
	local function logToFile(msg)
		if logPath == "" then return end
		local f = io.open(logPath, "a")
		if f then
			f:write(os.date("[%H:%M:%S] ") .. tostring(msg) .. "\n")
			f:close()
		end
	end

	-- === State ===
	local outbox = {}  -- pending messages to send to bridge
	local frame = 0
	local READ_FREQUENCY  = 6  -- read inbox every 6 frames (~10 Hz at 60fps)
	local WRITE_FREQUENCY = 6  -- flush outbox every 6 frames

	local current_twitchname = ""
	local current_trainer_pic = 0
	-- Current/next trainer names from the server (queue_info messages), shown
	-- in the tracker's carousel strip by drawQueueDisplay
	local queue_current = ""
	local queue_next = ""
	-- Ready check (ready_status messages): server is waiting for the picked
	-- viewer to confirm they're present; drawn bottom-left by drawReadyWait
	local ReadyWait = { active = false, name = "", deadline = 0 }
	local shown_name = ""
	local use_twitch_move = 0
	local sent_mon = ""
	local last_sent_moves = {}  -- move names as sent to webapp, indexed 1-4
	local trainer_request_pending = false
	local pokemon_request_pending = false
	local trainer_cooldown = 0  -- frames to wait before requesting again
	local pokemon_cooldown = 0
	local COOLDOWN_FRAMES = 120  -- ~2 seconds at 60fps
	local PENDING_TIMEOUT = 300  -- ~5 seconds: reset pending flag if no response
	local trainer_pending_timer = 0
	local pokemon_pending_timer = 0

	-- Battle state (must be before useMove so it's accessible)
	local in_battle = false
	local pending_move_value = nil  -- queued move value (3-6) to write when ROM is ready
	local stall_detected = false    -- have we seen wM > 0 this turn?
	local stall_prompt_sent = false -- have we sent prompt_move for this turn?
	local stall_delay = 0           -- frames since stall detected
	local STALL_DELAY_FRAMES = 30   -- wait 0.5s before sending prompt
	local stall_prompt_time = 0     -- os.time() when prompt_move was sent
	local STALL_SAFETY_TIMEOUT_SECS = 120 -- 2 minutes REAL time: if no move, bridge is likely dead
	local move_timer_deadline = 0   -- os.time() deadline for move countdown (0 = no timer)
	local twitch_move_disabled = false -- set by disable_twitch_move, cleared on next battle start
	local battle_frames = 0         -- frames since battle started
	local stuck_logged = false      -- have we logged the initial stuck warning?
	local battle_result_sent = false -- have we already sent a battle_result this battle?
	local outcome_delay = 0         -- frames since battleOutcome > 0 detected (for fallback signaling)
	local last_battle_outcome = 0   -- previous frame's battleOutcome (for detecting consecutive battle transitions)
	local last_enemy_species = 0    -- species ID read directly from gBattleMons[1] to detect switches
	local PLAYER_MON_BASE = 0x02023BE4    -- gBattleMons + 0x00 (battler 0) base address
	local ENEMY_MON_BASE = 0x02023C3C     -- gBattleMons + 0x58 (battler 1) base address
	-- BattlePokemon struct offsets:
	-- 0x00: species (u16), 0x0C: moves[4] (u16 each), 0x28: hp (u16), 0x2A: level (u8), 0x2C: maxHP (u16)
	local current_battle_is_wild = false -- is the current battle a wild encounter?
	local OAKS_LAB_TRAINERS = {[326] = true, [327] = true, [328] = true}
	local is_oaks_lab_battle = false
	local is_rival_battle = false
	-- False until this seed's Oak's Lab battle has finished (or a non-lab
	-- trainer battle proves we're past it, e.g. tracker reloaded mid-run).
	local lab_completed = false
	-- Ready-check gate: false until the streamer sets foot in Viridian Forest
	-- this run. Sent (inverted, as ready_deferred) with get_new_trainer so the
	-- server holds the ready check until the run reaches the forest; a
	-- forest_reached message fires any held check. Reset to false whenever the
	-- run ends (loss / new seed), so a dead run never pings a viewer and the
	-- next run must reach the forest again before prompts resume.
	local VIRIDIAN_FOREST_MAP_ID = 117  -- RouteData.Info[117] = "Viridian Forest" (FRLG layout id)
	local forest_reached = false
	-- Save viewer state before rival battles so we can restore after
	local saved_viewer_name = ""
	local saved_viewer_pic = 0
	local saved_viewer_use_twitch_move = 0
	local consecutive_transition_handled = false  -- prevents afterBattleEnds double-fire
	local last_move_write_time = 0               -- os.time() when useMove last wrote to EWRAM
	local move_written_frozen_start = 0          -- os.time() when gTM>2 with frozen wM first detected
	local last_wM_for_frozen_check = nil         -- previous wM sample for frozen detection
	local MOVE_WRITTEN_FROZEN_TIMEOUT = 10       -- seconds: if gTM>2 and wM frozen for this long, recover

	local reassert_logged = false

	-- Battle stats tracking
	local old_turn_count = 0
	local old_player_mon = {}
	local old_enemy_mon = {}
	local stats_log = {}
	stats_log.player_species = 0
	stats_log.enemy_species = 0

	-- === Helpers ===

	local MAX_OUTBOX_SIZE = 20  -- safety cap to prevent unbounded growth

	-- Read enemy pokemon data directly from gBattleMons memory (bypasses Tracker cache)
	local function readEnemyFromMemory()
		local mon = {}
		mon.pokemonID = Memory.readword(ENEMY_MON_BASE + 0x00) or 0
		if mon.pokemonID == 0 then return nil end

		mon.level = Memory.readbyte(ENEMY_MON_BASE + 0x2A) or 0
		mon.curHP = Memory.readword(ENEMY_MON_BASE + 0x28) or 0
		mon.maxHP = Memory.readword(ENEMY_MON_BASE + 0x2C) or 0

		-- Read moves directly from memory
		mon.moves = {}
		local move_names = {}
		for i = 0, 3 do
			local moveId = Memory.readword(ENEMY_MON_BASE + 0x0C + i * 2) or 0
			if moveId > 0 then
				mon.moves[i+1] = { id = moveId }
				if MoveData and MoveData.Moves[moveId] then
					local md = MoveData.Moves[moveId]
					mon.moves[i+1].name = md.name
					mon.moves[i+1].type = md.type
					mon.moves[i+1].power = md.power
					mon.moves[i+1].accuracy = md.accuracy
					mon.moves[i+1].category = md.category
					move_names[i+1] = md.name
				else
					move_names[i+1] = "id:" .. moveId
				end
				-- Read PP from memory too
				mon.moves[i+1].pp = Memory.readbyte(ENEMY_MON_BASE + 0x24 + i) or 0
			end
		end

		-- Get pokemon name and types from PokemonData (static lookup, always current)
		if PokemonData and PokemonData.Pokemon[mon.pokemonID] then
			mon.name = PokemonData.Pokemon[mon.pokemonID].name
			mon.types = PokemonData.Pokemon[mon.pokemonID].types
		end

		mon.turnCount = Battle and Battle.turnCount or -1
		mon.trainerID = Battle and Battle.opposingTrainerId or 0
		mon.isWild = (Battle and Battle.isWildEncounter) or current_battle_is_wild
		mon.seedCount = Main and Main.currentSeed or 0

		return mon, move_names
	end

	-- Message types safe to drop under back-pressure (they retry or are cosmetic).
	-- battle_result / clear_pokemon / enemy_poke / prompt_move / rival_battle /
	-- restore_trainer must NEVER be dropped - losing one desyncs the server.
	local DROPPABLE_TYPES = {
		stats = true, debug = true, trainer_shown = true, donator_seen = true,
		get_new_trainer = true, get_new_pokemon = true,
	}

	local function queueMessage(msg)
		if #outbox >= MAX_OUTBOX_SIZE then
			-- Prefer dropping the oldest low-value message; blindly dropping
			-- outbox[1] could discard a queued battle_result during an outage.
			local dropped = false
			for i, m in ipairs(outbox) do
				if DROPPABLE_TYPES[m.type or ""] then
					logToFile("Outbox full: dropping " .. (m.type or "?") .. " to make room")
					table.remove(outbox, i)
					dropped = true
					break
				end
			end
			-- Nothing droppable: allow growth up to a hard cap, then drop oldest
			if not dropped and #outbox >= MAX_OUTBOX_SIZE * 3 then
				logToFile("Outbox hard cap: dropping oldest " .. (outbox[1].type or "?"))
				table.remove(outbox, 1)
			end
		end
		table.insert(outbox, msg)
	end

	local function flushOutbox()
		if #outbox == 0 then return end

		-- Check if bridge has consumed previous messages
		local check = io.open(outboxPath, "r")
		if check then
			local content = check:read("*a")
			check:close()
			if content and content ~= "" and content ~= "[]" then
				return -- bridge hasn't consumed yet, wait
			end
		end

		local types = {}
		for _, m in ipairs(outbox) do types[#types+1] = m.type or "?" end
		logToFile("Flushing outbox (" .. #outbox .. "): " .. table.concat(types, ", "))

		local file = io.open(outboxPath, "w")
		if file then
			file:write(json.stringify(outbox))
			file:close()
			outbox = {}
		end
	end

	local function readInbox()
		local file = io.open(inboxPath, "r")
		if not file then return {} end

		local content = file:read("*a")
		file:close()

		if not content or content == "" or content == "[]" then return {} end

		local ok, messages = pcall(json.parse, content)
		if not ok or type(messages) ~= "table" then
			logToFile("WARNING: failed to parse inbox: " .. tostring(content):sub(1, 100))
			return {}
		end

		local types = {}
		for _, m in ipairs(messages) do types[#types+1] = m.type or "?" end
		logToFile("Inbox received (" .. #messages .. "): " .. table.concat(types, ", "))

		-- Clear inbox after reading
		local clear = io.open(inboxPath, "w")
		if clear then
			clear:write("[]")
			clear:close()
		end

		return messages
	end

	local function deepcopy(orig)
		local orig_type = type(orig)
		local copy
		if orig_type == 'table' then
			copy = {}
			for orig_key, orig_value in next, orig, nil do
				copy[deepcopy(orig_key)] = deepcopy(orig_value)
			end
			setmetatable(copy, deepcopy(getmetatable(orig)))
		else
			copy = orig
		end
		return copy
	end

	-- === GBA Text Encoding ===

	local function writestringtomemory(name, write_location, max_length)
		if name ~= nil and name ~= "" then
			name = name:gsub('%W','')
			name = string.lower(name)
			local name_length = math.min(string.len(name), max_length)
			for i = 1, name_length do
				local write_value = 0
				if string.byte(name, i) < 65 then
					write_value = string.byte(name, i) + 161 - 48
				else
					write_value = string.byte(name, i) + 90
				end
				memory.write_u8(write_location + i - 1, write_value, "EWRAM")
			end
			memory.write_u8(write_location + name_length, 0xFF, "EWRAM")
		end
	end

	-- === Trainer Name Handling ===

	local trainer_shown_sent = false

	local function trainerShown(name)
		if trainer_shown_sent then return end
		queueMessage({type = "trainer_shown", name = name})
		shown_name = name
		trainer_shown_sent = true
	end

	local function updateTrainerName(msg)
		local name = msg.name or ""
		local pic = msg.pic

		current_twitchname = name
		if current_twitchname then
			current_twitchname = string.gsub(current_twitchname, "%s+", "")
		end

		if current_twitchname ~= "" and current_twitchname ~= nil then
			writestringtomemory(current_twitchname, sText_TwitchName, 15)
			shown_name = current_twitchname
			memory.write_u8(use_twitchname, 1, "EWRAM")
			memory.write_u8(twitch_name_shown, 0, "EWRAM")
			-- Verify EWRAM writes succeeded
			local readback_utn = memory.read_u8(use_twitchname, "EWRAM")
			local readback_tns = memory.read_u8(twitch_name_shown, "EWRAM")
			local readback_bytes = {}
			for i = 0, math.min(string.len(current_twitchname), 15) do
				readback_bytes[#readback_bytes + 1] = string.format("%02X", memory.read_u8(sText_TwitchName + i, "EWRAM"))
			end
			logToFile("EWRAM verify: use_twitchname=" .. readback_utn .. " twitch_name_shown=" .. readback_tns .. " name_bytes=" .. table.concat(readback_bytes, " "))
		end

		-- Write trainer pic to EWRAM if provided (pic > 0 means user has a skin)
		-- Written as u16 little-endian (2 bytes) since pic IDs can exceed 255
		if pic and pic > 0 then
			current_trainer_pic = pic
			memory.write_u8(twitch_trainer_pic, pic % 256, "EWRAM")
			memory.write_u8(twitch_trainer_pic + 1, math.floor(pic / 256), "EWRAM")
			memory.write_u8(use_twitch_trainer_pic, 1, "EWRAM")
			logToFile("Trainer pic set: " .. pic .. " (lo=" .. (pic % 256) .. " hi=" .. math.floor(pic / 256) .. ")")
		else
			current_trainer_pic = 0
			memory.write_u8(twitch_trainer_pic, 0, "EWRAM")
			memory.write_u8(twitch_trainer_pic + 1, 0, "EWRAM")
			memory.write_u8(use_twitch_trainer_pic, 0, "EWRAM")
			logToFile("No trainer pic (pic=" .. tostring(pic) .. ")")
		end
	end

	local function checkTwitchName()
		local use_flag = memory.read_u8(use_twitchname, "EWRAM")
		local shown_flag = memory.read_u8(twitch_name_shown, "EWRAM")
		local name_byte0 = memory.read_u8(sText_TwitchName, "EWRAM")

		-- Detect EWRAM corruption: we have a name but the name text was zeroed
		if current_twitchname ~= "" and current_twitchname ~= nil and name_byte0 == 0 then
			writestringtomemory(current_twitchname, sText_TwitchName, 15)
			memory.write_u8(use_twitchname, 1, "EWRAM")
			memory.write_u8(twitch_name_shown, 0, "EWRAM")
			trainer_shown_sent = false
			-- Also repair trainer pic if we have one
			if current_trainer_pic > 0 then
				memory.write_u8(twitch_trainer_pic, current_trainer_pic % 256, "EWRAM")
				memory.write_u8(twitch_trainer_pic + 1, math.floor(current_trainer_pic / 256), "EWRAM")
				memory.write_u8(use_twitch_trainer_pic, 1, "EWRAM")
			end
			logToFile("EWRAM REPAIR: name text was zeroed, re-wrote name+flags+pic for: " .. current_twitchname)
			return
		end

		if use_flag == 0 then
			if current_twitchname ~= "" and current_twitchname ~= nil then
				-- ROM cleared use_twitchname (happens after each battle). Re-set it.
				memory.write_u8(use_twitchname, 1, "EWRAM")
				memory.write_u8(twitch_name_shown, 0, "EWRAM")
				trainer_shown_sent = false
				logToFile("Re-set use_twitchname=1 for trainer: " .. current_twitchname)
			elseif not trainer_request_pending and trainer_cooldown <= 0
					and not (in_battle and twitch_move_disabled) then
				-- (An AI-locked battle must finish before requesting the next
				-- trainer - assigning into it would waste the pick.)
				logToFile("Requesting new trainer (use=" .. use_flag .. " shown=" .. shown_flag .. " pending=" .. tostring(trainer_request_pending) .. " cooldown=" .. trainer_cooldown .. " ready_deferred=" .. tostring(not forest_reached) .. ")")
				queueMessage({type = "get_new_trainer", ready_deferred = not forest_reached})
				trainer_request_pending = true
			end
		else
			if memory.read_u8(twitch_name_shown, "EWRAM") == 1
				and current_twitchname ~= "" and current_twitchname ~= nil then
				trainerShown(current_twitchname)
			end
		end
	end

	-- === Pokemon Name Handling ===

	local function writePokemonName(name)
		if name ~= "" and name ~= nil then
			writestringtomemory(name, sText_TwitchPokemon, 10)
			memory.write_u8(use_twitchpokename, 1, "EWRAM")
		end
	end

	local function checkPokemonName()
		local use_flag = memory.read_u8(use_twitchpokename, "EWRAM")
		if use_flag == 0 and not pokemon_request_pending and pokemon_cooldown <= 0 then
			logToFile("Requesting new pokemon name (use=" .. use_flag .. ")")
			queueMessage({type = "get_new_pokemon"})
			pokemon_request_pending = true
		end
	end

	-- Ready-check gate: fire once per run the first time the streamer steps into
	-- Viridian Forest. Tells the server to release any held ready check (and,
	-- via ready_deferred=false on subsequent get_new_trainer, to stop deferring).
	-- Uses the Tracker's public map API - no tracker-owned addresses touched.
	local function checkForestReached()
		if forest_reached then return end
		local ok, mapId = pcall(function() return TrackerAPI.getMapId() end)
		if ok and mapId == VIRIDIAN_FOREST_MAP_ID then
			forest_reached = true
			queueMessage({type = "forest_reached"})
			logToFile("Viridian Forest reached (mapId=" .. tostring(mapId) .. ") - ready checks enabled for this run")
		end
	end

	-- === Move Selection ===

	local function useMove(move_name)
		if not in_battle then
			logToFile("useMove: ignoring '" .. move_name .. "' - not in battle")
			return
		end
		if twitch_move_disabled then
			logToFile("useMove: ignoring '" .. move_name .. "' - twitch move disabled (AI mode)")
			return
		end
		local gTM_before = memory.read_u8(gTwitchMove, "EWRAM")
		local wM_before = memory.read_u8(waitingMove, "EWRAM")
		logToFile("useMove called: '" .. move_name .. "' | in_battle=" .. tostring(in_battle)
			.. " gTwitchMove=" .. gTM_before .. " waitingMove=" .. wM_before)
		local matched = false

		-- Match against the same move names we sent to the webapp
		for i = 1, 4 do
			if last_sent_moves[i] and string.lower(move_name) == string.lower(last_sent_moves[i]) then
				local move_val = i + 2  -- slot 1->3, 2->4, 3->5, 4->6
				-- Only write immediately if ROM is in the stall loop (waitingMove > 0)
				-- Otherwise queue it for the per-frame loop to write when ready
				if wM_before > 0 then
					memory.write_u8(gTwitchMove, move_val, "EWRAM")
					local verify = memory.read_u8(gTwitchMove, "EWRAM")
					last_move_write_time = os.time()
					logToFile("Move matched slot " .. i .. " -> wrote " .. move_val .. " to gTwitchMove (verify=" .. verify .. ")")
				else
					pending_move_value = move_val
					logToFile("Move matched slot " .. i .. " -> queued " .. move_val .. " (waitingMove=0, will write when ROM is ready)")
				end
				matched = true
				break
			end
		end

		-- Fallback: try matching via Tracker data
		if not matched then
			logToFile("Trying fallback Tracker lookup for '" .. move_name .. "'")
			local ok, err = pcall(function()
				local attackerSlot = Battle.Combatants[Battle.IndexMap[1]] or 0
				local attacker_mon = Tracker.getPokemon(attackerSlot, false)
				if attacker_mon then
					for i = 1, 4 do
						local move_id = attacker_mon.moves[i] and attacker_mon.moves[i].id
						if move_id and MoveData.Moves[move_id] then
							local tracker_name = MoveData.Moves[move_id].name
							logToFile("  Tracker slot " .. i .. ": " .. tostring(tracker_name))
							if string.lower(move_name) == string.lower(tracker_name) then
								local move_val = i + 2
								if wM_before > 0 then
									memory.write_u8(gTwitchMove, move_val, "EWRAM")
									local verify = memory.read_u8(gTwitchMove, "EWRAM")
									last_move_write_time = os.time()
									logToFile("  Fallback matched slot " .. i .. " -> wrote " .. move_val .. " (verify=" .. verify .. ")")
								else
									pending_move_value = move_val
									logToFile("  Fallback matched slot " .. i .. " -> queued " .. move_val .. " (waitingMove=0)")
								end
								matched = true
								break
							end
						end
					end
				else
					logToFile("  Fallback: no attacker_mon from Tracker")
				end
			end)
			if not ok then
				logToFile("  Fallback error: " .. tostring(err))
			end
		end

		if not matched then
			logToFile("FAILED: move '" .. move_name .. "' not found anywhere! last_sent_moves: "
				.. (last_sent_moves[1] or "?") .. ", " .. (last_sent_moves[2] or "?") .. ", "
				.. (last_sent_moves[3] or "?") .. ", " .. (last_sent_moves[4] or "?"))
		end
	end

	-- === Reset ===

	local function resetLua()
		console.log("IronMob: reset lua variables")
		-- If we were in a trainer battle, the reset means the player lost (viewer wins).
		-- Never for wild encounters - a reset after a wild death must not touch the queue.
		if in_battle and not current_battle_is_wild and use_twitch_move > 0 and current_twitchname ~= "" and not battle_result_sent then
			battle_result_sent = true
			local report_name = is_rival_battle and "MOB" or current_twitchname
			queueMessage({type = "battle_result", result = "win", trainer = report_name})
			logToFile("resetLua: player reset during battle - viewer " .. report_name .. " wins")
		end
		current_twitchname = ""
		shown_name = ""
		use_twitch_move = 0
		current_trainer_pic = 0
		trainer_request_pending = false
		pokemon_request_pending = false
		trainer_shown_sent = false
		trainer_cooldown = 0
		pokemon_cooldown = 0
		memory.write_u8(gTwitchMove, 0, "EWRAM")
		memory.write_u8(waitingMove, 0, "EWRAM")
		memory.write_u8(use_twitchname, 0, "EWRAM")
		memory.write_u8(twitch_name_shown, 0, "EWRAM")
		memory.write_u8(use_topDono, 0, "EWRAM")
		memory.write_u8(top_donator_shown, 0, "EWRAM")
		memory.write_u8(sText_TopDonator, 0xFF, "EWRAM")  -- terminate donator name
		memory.write_u8(sText_SubAmount, 0xFF, "EWRAM")   -- terminate sub amount
		memory.write_u8(use_twitch_trainer_pic, 0, "EWRAM")
		memory.write_u8(twitch_trainer_pic, 0, "EWRAM")
		memory.write_u8(twitch_trainer_pic + 1, 0, "EWRAM")
		pending_move_value = nil
		move_timer_deadline = 0
		in_battle = false
		current_battle_is_wild = false
		is_oaks_lab_battle = false
		is_rival_battle = false
		saved_viewer_name = ""
		saved_viewer_pic = 0
		saved_viewer_use_twitch_move = 0
		battle_result_sent = false
		outcome_delay = 0
		last_battle_outcome = 0
		-- A reset means a new seed: its Oak's Lab hasn't happened yet. If this
		-- was actually a mid-run tracker reload, the first non-lab trainer
		-- battle sets lab_completed back to true (see afterBattleBegins).
		lab_completed = false
		-- New run: no ready prompts until the streamer reaches Viridian Forest.
		forest_reached = false
		queueMessage({type = "clear_pokemon"})
		logToFile("resetLua: cleared all trainer/move state")
	end

	-- === Process Inbox Commands ===

	local function processInboxMessage(msg)
		local msg_type = msg.type or ""
		logToFile("Inbox: " .. msg_type .. " -> " .. json.stringify(msg))

		if msg_type == "new_trainer" then
			trainer_request_pending = false
			trainer_pending_timer = 0
			trainer_cooldown = COOLDOWN_FRAMES
			local name = msg.name or ""
			-- Ignore "MOB" responses during rival battles - they overwrite the saved viewer
			if name == "MOB" and is_rival_battle then
				logToFile("Ignoring new_trainer 'MOB' during rival battle (viewer preserved)")
			else
				if name ~= "" then
					use_twitch_move = 2
					if in_battle then
						logToFile("Trainer assigned during battle - re-assert will activate when outcome clears")
					end
					-- Don't write gTwitchMove to EWRAM here - afterBattleBegins handles it
					-- when the battle actually starts, and the re-assert logic handles
					-- consecutive battles (where afterBattleBegins never fires).
					logToFile("Trainer assigned: " .. name .. " -> use_twitch_move set to 2")
				end
				updateTrainerName(msg)
			end
		elseif msg_type == "new_pokemon" then
			pokemon_request_pending = false
			pokemon_pending_timer = 0
			pokemon_cooldown = COOLDOWN_FRAMES
			-- Pokemon name writing disabled for now.
			-- Will be re-enabled with different viewer selection logic later.
			-- writePokemonName(msg.name or "")
		elseif msg_type == "use_move" then
			local move_name = msg.move_name or ""
			if move_name ~= "" then
				useMove(move_name)
				move_timer_deadline = 0
			end
		elseif msg_type == "top_contributor" then
			local name = msg.name or ""
			local amount = msg.amount or "0"
			local pic = tonumber(msg.pic) or 0
			if name ~= "" then
				writestringtomemory(name, sText_TopDonator, 15)
				writestringtomemory(amount, sText_SubAmount, 3)
				memory.write_u8(use_topDono, 1, "EWRAM")
				memory.write_u8(top_donator_shown, 0, "EWRAM")
				-- Write trainer pic for gym leader (reuses same EWRAM addresses)
				if pic > 0 then
					memory.write_u8(twitch_trainer_pic, pic % 256, "EWRAM")
					memory.write_u8(twitch_trainer_pic + 1, math.floor(pic / 256), "EWRAM")
					memory.write_u8(use_twitch_trainer_pic, 1, "EWRAM")
				end
				logToFile("Top contributor set: " .. name .. " (" .. amount .. " tokens, pic " .. pic .. ")")
			else
				memory.write_u8(sText_TopDonator, 0xFF, "EWRAM")
				memory.write_u8(sText_SubAmount, 0xFF, "EWRAM")
				memory.write_u8(use_topDono, 0, "EWRAM")
				memory.write_u8(twitch_trainer_pic, 0, "EWRAM")
				memory.write_u8(twitch_trainer_pic + 1, 0, "EWRAM")
				memory.write_u8(use_twitch_trainer_pic, 0, "EWRAM")
				logToFile("Top contributor cleared")
			end
		elseif msg_type == "move_timer" then
			local secs = tonumber(msg.seconds) or 30
			move_timer_deadline = os.time() + secs
			logToFile("Move timer set: " .. secs .. "s")
		elseif msg_type == "disable_twitch_move" then
			-- Stop stalling for THIS battle only, let ROM AI take over
			-- use_twitch_move stays intact so the NEXT battle still stalls
			logToFile("disable_twitch_move: disabling stall for current battle (ROM AI resumes)")
			twitch_move_disabled = true
			memory.write_u8(gTwitchMove, 0, "EWRAM")
			-- Reset battle_locked_to_ai so consecutive battles don't stay AI-locked
			memory.write_u32_le(battleLockedToAi, 0, "EWRAM")
			pending_move_value = nil
			stall_detected = false
			stall_prompt_sent = false
			stall_delay = 0
			move_timer_deadline = 0
		elseif msg_type == "queue_info" then
			queue_current = msg.current or ""
			queue_next = msg.next or ""
			logToFile("Queue info: now=" .. (queue_current ~= "" and queue_current or "-")
				.. " next=" .. (queue_next ~= "" and queue_next or "-"))
		elseif msg_type == "ready_status" then
			if msg.pending then
				ReadyWait.active = true
				ReadyWait.name = msg.name or ""
				ReadyWait.deadline = os.time() + (tonumber(msg.seconds) or 60)
				logToFile("Ready check: waiting for " .. ReadyWait.name
					.. " (" .. tostring(msg.seconds) .. "s)")
			else
				ReadyWait.active = false
				ReadyWait.name = ""
				ReadyWait.deadline = 0
				logToFile("Ready check cleared")
			end
		elseif msg_type == "reset_lua" then
			resetLua()
		elseif msg_type == "bridge_reconnected" then
			-- Bridge reconnected to server - resend current state so webapp catches up
			logToFile("Bridge reconnected: resending current state")
			-- Restore current trainer on the server (not get_new_trainer, which picks
			-- a different viewer). The server looks up the user by name.
			if current_twitchname ~= "" then
				logToFile("  Restoring trainer: " .. current_twitchname)
				queueMessage({type = "restore_trainer", name = current_twitchname})
			end
			-- Resend rival battle flag
			if is_rival_battle then
				logToFile("  Resending rival_battle")
				queueMessage({type = "rival_battle", oaks_lab = is_oaks_lab_battle})
			end
			-- Resend enemy poke if we have it
			if in_battle and sent_mon ~= "" then
				local ok, mon_data = pcall(json.parse, sent_mon)
				if ok and mon_data then
					logToFile("  Resending enemy_poke: " .. (mon_data.name or "?"))
					queueMessage({type = "enemy_poke", data = mon_data})
				end
			end
			-- Re-trigger stall prompt if we're waiting for a move
			if in_battle and stall_detected and use_twitch_move > 0 and not twitch_move_disabled then
				logToFile("  Resending prompt_move (stall active)")
				queueMessage({type = "prompt_move"})
			end
		elseif msg_type == "report_issue" then
			local desc = msg.description or ""
			local sep = string.rep("!", 60)
			local gTM = memory.read_u8(gTwitchMove, "EWRAM")
			local wM = memory.read_u8(waitingMove, "EWRAM")
			local utn = memory.read_u8(use_twitchname, "EWRAM")
			local wT = memory.read_u8(waitingTimer, "EWRAM")
			local locked = memory.read_u32_le(battleLockedToAi, "EWRAM")
			logToFile(sep)
			logToFile("ISSUE REPORTED: " .. (desc ~= "" and desc or "(no description)"))
			logToFile(string.format(
				"  in_battle=%s | use_twitch_move=%d | gTM=%d | wM=%d | wT=%d | locked=%d",
				tostring(in_battle), use_twitch_move, gTM, wM, wT, locked))
			logToFile(string.format(
				"  trainer=%s | stall=%s | prompt_sent=%s | pending=%s | disabled=%s | battle_frames=%d",
				current_twitchname or "none",
				tostring(stall_detected), tostring(stall_prompt_sent),
				tostring(pending_move_value), tostring(twitch_move_disabled), battle_frames))
			logToFile(string.format(
				"  moves=[%s, %s, %s, %s]",
				last_sent_moves[1] or "?", last_sent_moves[2] or "?",
				last_sent_moves[3] or "?", last_sent_moves[4] or "?"))
			logToFile(string.format(
				"  rival=%s | is_wild=%s | result_sent=%s | outcome_delay=%d",
				tostring(is_rival_battle), tostring(current_battle_is_wild),
				tostring(battle_result_sent), outcome_delay))
			logToFile(sep)
		end
	end

	-- === Battle Stats ===

	local function findUsedMoves(new_moves, old_moves)
		for i = 1, #new_moves do
			if tonumber(new_moves[i].pp) < tonumber(old_moves[i].pp) then
				return i
			end
		end
		return -1
	end

	local function updateBattleStats(force_log)
		local playerSlot = Battle.Combatants[Battle.IndexMap[0]] or 0
		local player_mon = Tracker.getPokemon(playerSlot, true)
		if old_player_mon and player_mon
			and old_player_mon.personality == player_mon.personality
			and old_player_mon.pokemonID == player_mon.pokemonID then
			local move_num = findUsedMoves(player_mon.moves, old_player_mon.moves)
			if move_num > 0 then
				stats_log.player_move_id = player_mon.moves[move_num].id
			end
		end
		if player_mon then
			if stats_log.player_species == 0 then
				stats_log.player_species = player_mon.pokemonID
			end
			stats_log.player_status = player_mon.status
			stats_log.player_ability = PokemonData.getAbilityId(player_mon.pokemonID, player_mon.abilityNum)
			stats_log.player_hp = player_mon.curHP
			stats_log.player_level = player_mon.level
		end

		local enemySlot = Battle.Combatants[Battle.IndexMap[1]] or 0
		local enemy_mon = Tracker.getPokemon(enemySlot, false)
		if old_enemy_mon and enemy_mon
			and old_enemy_mon.personality == enemy_mon.personality
			and old_enemy_mon.pokemonID == enemy_mon.pokemonID then
			local move_num = findUsedMoves(enemy_mon.moves, old_enemy_mon.moves)
			if move_num > 0 then
				stats_log.enemy_move_id = enemy_mon.moves[move_num].id
			end
		end
		if enemy_mon then
			if stats_log.enemy_species == 0 then
				stats_log.enemy_species = enemy_mon.pokemonID
			end
			stats_log.enemy_status = enemy_mon.status
			if enemy_mon.abilities then
				stats_log.enemy_ability = enemy_mon.abilities[enemy_mon.abilityNum + 1]
			end
			stats_log.enemy_hp = enemy_mon.curHP
			stats_log.enemy_level = enemy_mon.level
			stats_log.enemy_shiny = enemy_mon.isShiny
		end

		local turnCount = Battle.turnCount
		if turnCount >= 0 then
			stats_log.turnCount = turnCount
		end
		stats_log.seedCount = Main.currentSeed
		stats_log.totalBattles = Utils.getGameStat(7)
		if stats_log.totalBattles > 0xFFFFFF then
			stats_log.totalBattles = -1
		end
		stats_log.num_steps = Utils.getGameStat(Constants.GAME_STATS.STEPS)
		stats_log.lastBattleStatus = Memory.readbyte(GameSettings.gBattleOutcome)

		local trainerId = Battle.opposingTrainerId
		if turnCount > 0 then
			stats_log.trainerId = trainerId
		end
		stats_log.battleWeather = Memory.readword(GameSettings.gBattleWeather)

		if old_turn_count < turnCount and old_turn_count >= 0 or force_log then
			queueMessage({type = "stats", data = deepcopy(stats_log)})
			old_turn_count = turnCount
			stats_log.player_move_id = 0
			stats_log.enemy_move_id = 0
			stats_log.player_species = 0
			stats_log.enemy_species = 0
		end

		if player_mon then
			old_player_mon.moves = deepcopy(player_mon.moves)
			old_player_mon.personality = player_mon.personality
			old_player_mon.pokemonID = player_mon.pokemonID
		end
		if enemy_mon then
			old_enemy_mon.moves = deepcopy(enemy_mon.moves)
			old_enemy_mon.personality = enemy_mon.personality
			old_enemy_mon.pokemonID = enemy_mon.pokemonID
		end
	end

	-- === Bridge-Running Warning ===
	-- IronMobBridge.exe refreshes a heartbeat file (epoch seconds) while it
	-- runs. If it's stale or missing, the bridge isn't open and chat can't
	-- battle, so warn on the game screen with a button that launches it.

	local HEARTBEAT_FILE = "bridge_heartbeat"
	local HEARTBEAT_STALE_SECONDS = 12
	local heartbeatPath = ""
	local BridgeWarn = {
		active = false,
		lastCheck = 0,
		mouseWasDown = false,  -- for click edge-detection on the warning's button
	}
	-- Clickable "Open IronMob Bridge" button inside the banner (game-screen coords).
	local WarnButton = { x = 6, y = 23, w = 150, h = 13 }

	-- Launch the bundled bridge exe (or open the folder if it's missing). Shared by
	-- the extension's "Options" button and the on-screen warning button.
	local function launchBridge()
		if not Main.IsOnBizhawk() then return end
		local extFolderPath = FileManager.getCustomFolderPath() .. "IronMob" .. FileManager.slash
		local exePath = extFolderPath .. "IronMobBridge.exe"

		local file = io.open(exePath, "r")
		if file then
			file:close()
			os.execute('start "" "' .. exePath .. '"')
		else
			os.execute('explorer "' .. extFolderPath .. '"')
		end
	end

	-- Read the heartbeat file the bridge refreshes; returns its epoch seconds or nil.
	local function readHeartbeat()
		if heartbeatPath == "" then return nil end
		local file = io.open(heartbeatPath, "r")
		if not file then return nil end
		local content = file:read("*a")
		file:close()
		if not content then return nil end
		return tonumber((content:gsub("%s+", "")))
	end

	-- Decide (throttled to once/sec) whether the bridge is currently running.
	local function updateBridgeWarning()
		local now = os.time()
		if now - BridgeWarn.lastCheck < 1 then return end
		BridgeWarn.lastCheck = now
		local beat = readHeartbeat()
		BridgeWarn.active = (beat == nil) or ((now - beat) > HEARTBEAT_STALE_SECONDS)
	end

	-- Draw a warning banner across the top of the GAME screen when the bridge
	-- isn't running, with a clickable button that launches it. Uses Bizhawk's
	-- gui directly so it overlays the game; no Tracker UI is modified.
	local function drawBridgeWarning()
		if not Main.IsOnBizhawk() then return end
		local w = Constants.SCREEN.WIDTH
		gui.drawRectangle(0, 0, w, 38, 0xFFCC0000, 0xFFCC0000)
		Drawing.drawText(6, 2, "IronMob Bridge NOT running", 0xFFFFFFFF, 0xFF000000)
		Drawing.drawText(6, 12, "Chat cannot join battles!", 0xFFFFFF00, 0xFF000000)
		gui.drawRectangle(WarnButton.x, WarnButton.y, WarnButton.w, WarnButton.h, 0xFF000000, 0xFFFFFFFF)
		Drawing.drawText(WarnButton.x + 4, WarnButton.y + 2, "Open IronMob Bridge", 0xFFCC0000)
	end

	-- Bottom-left indicator while the server waits for the picked viewer to
	-- confirm they're at the keyboard. The server clears it (confirm, timeout
	-- swap, or battle start); the local deadline is a fallback so a lost clear
	-- message can't leave it stuck on screen.
	local function drawReadyWait()
		if not Main.IsOnBizhawk() then return end
		local remaining = ReadyWait.deadline - os.time()
		if remaining < 0 then
			ReadyWait.active = false
			return
		end
		local text = "Waiting for " .. ReadyWait.name .. " to ready up (" .. remaining .. "s)"
		local sw = Constants.SCREEN.WIDTH
		local sh = Constants.SCREEN.HEIGHT or 160
		local h = 12
		local w = math.min(#text * 4 + 10, sw)
		local y = sh - h
		gui.drawRectangle(0, y, w, h, 0xE0202020, 0xE0202020)
		Drawing.drawText(3, y + 1, text, 0xFFFFFF00, 0xFF000000)
	end

	-- === Trainer Queue Display ===
	-- Replaces the Tracker's bottom carousel strip (badges/notes area) with
	-- a display cycling between the current and next trainer Twitch names.
	-- Names come from the server via the bridge (queue_info messages).

	local QUEUE_CYCLE_SECONDS = 3

	local function drawQueueDisplay()
		if not Main.IsOnBizhawk() then return end
		-- Stale names are worse than none while the bridge is down (the game
		-- screen banner already explains what's wrong).
		if BridgeWarn.active then return end
		-- Only cover the carousel when the main Tracker screen is showing.
		if Program and Program.currentScreen ~= TrackerScreen then return end

		local now_name = queue_current
		if now_name == "" then now_name = current_twitchname or "" end
		if now_name == "" and queue_next == "" then return end

		-- Same box the Tracker draws for its carousel area
		local x = Constants.SCREEN.WIDTH + Constants.SCREEN.MARGIN
		local y = 136
		local w = Constants.SCREEN.RIGHT_GAP - (2 * Constants.SCREEN.MARGIN)
		local h = 19
		local bg = Theme.COLORS["Lower box background"]
		local shadowcolor = Utils.calcShadowColor(bg)
		gui.drawRectangle(x, y, w, h, Theme.COLORS["Lower box border"], bg)

		-- Out of battle the "current" trainer is only selected, not fighting - 
		-- calling them "Now" reads wrong, so label them as up next instead.
		-- Wild battles count as out-of-battle here: the assigned trainer is
		-- NOT playing in a wild encounter, so "Now" would be a lie.
		local battling = in_battle and not current_battle_is_wild
		local phase = math.floor(os.time() / QUEUE_CYCLE_SECONDS) % 2
		local label, name
		if phase == 0 then
			label = battling and "Now:" or "Next:"
			name = (now_name ~= "" and now_name) or "---"
		else
			label = battling and "Next:" or "Then:"
			name = (queue_next ~= "" and queue_next) or "---"
		end
		Drawing.drawText(x + 1, y + 4, label, Theme.COLORS["Lower box text"], shadowcolor)
		Drawing.drawText(x + 30, y + 4, name, Theme.COLORS["Intermediate text"], shadowcolor)
	end

	-- === Extension Lifecycle ===

	function self.configureOptions()
		launchBridge()
	end

	function self.checkForUpdates()
		local versionCheckUrl = string.format("https://api.github.com/repos/%s/releases/latest", self.github)
		local versionResponsePattern = '"tag_name":%s+"%w+(%d+%.%d+)"'
		local downloadUrl = string.format("https://github.com/%s/releases/latest", self.github)
		local isUpdateAvailable = Utils.checkForVersionUpdate(versionCheckUrl, self.version, versionResponsePattern, nil)
		return isUpdateAvailable, downloadUrl
	end

	-- ===================== FIRST-TIME SETUP (ROM patch + Tracker profile) =====================
	-- One-time onboarding: patch the player's own clean FireRed (USA) into the IronMob base ROM
	-- (via the bundled rompatch\FRLG - IronMob.ips), then create a Tracker "Generate ROM each
	-- time" New Run profile pointed at that ROM + our randomizer jar + the FRLG Kaizo ruleset, so
	-- chat can start battling immediately. Uses ONLY public Tracker globals (QuickloadScreen /
	-- Options / Main / FileManager / ExternalUI) - no Tracker source is modified. Idempotent: a
	-- cheap startup check skips everything once set up, and silently re-creates the profile if
	-- only that goes missing. Ported from the IronmonVS extension's setup flow.

	self.Setup = {
		patchedName = "FRLG - IronMob.gba", -- base ROM we write (the jar randomizes it each seed)
		stateFile   = "setup_state.json",   -- our tiny idempotency record
		rulesName   = "FRLG Kaizo.rnqs",     -- ships with the Tracker
		profileName = "IronMob",
		version     = 1,           -- bump when the base ROM / IPS changes, to force a re-patch
		romSize     = 16777216,    -- 16MB FireRed
		baseAdler   = 0x2D0FB28A,  -- adler32 of the correctly-patched IronMob base ROM
		sourceAdler = 0x57240B31,  -- adler32 of the expected clean FireRed (USA) source
		ready       = false,       -- set true by self.checkSetup() once everything is in place
		warnActive  = false,       -- show the setup banner
		needsUpdate = false,       -- true when a PRIOR setup is now out of date (re-patch, not first-time)
		Button      = { x = 6, y = 23, w = 150, h = 13 },
	}
	self.SetupPaths = {}   -- absolute paths, resolved in self.startup()

	-- Adler-32 of a binary string. Only +/% (no bitwise lib, not guaranteed across Bizhawk Lua
	-- versions). 256-byte chunks stay under Adler's NMAX (5552), so deferring the modulo to each
	-- chunk boundary is safe.
	local function adler32(s)
		local MOD = 65521
		local a, b = 1, 0
		local len = #s
		local i = 1
		local sbyte = string.byte
		while i <= len do
			local j = i + 255
			if j > len then j = len end
			local t = { sbyte(s, i, j) }
			for k = 1, #t do
				a = a + t[k]
				b = b + a
			end
			a = a % MOD
			b = b % MOD
			i = j + 1
		end
		return b * 65536 + a
	end

	local function readWholeFile(path)
		local f = io.open(path, "rb")
		if not f then return nil end
		local data = f:read("*a")
		f:close()
		return data
	end

	local function writeWholeFile(path, data)
		local f = io.open(path, "wb")
		if not f then return false end
		f:write(data)
		f:close()
		return true
	end

	-- Cheap size lookup (no full read): seek to end.
	local function fileSizeOf(path)
		local f = io.open(path, "rb")
		if not f then return nil end
		local sz = f:seek("end")
		f:close()
		return sz
	end

	-- Apply a standard IPS patch (binary string) to a source ROM (binary string). Lua strings are
	-- immutable, so build the output as a list of unchanged spans + patched bytes and concat once
	-- (O(n)); the shipped patch's records are in-order and non-overlapping (verified). Returns the
	-- patched string, or nil + reason.
	local function applyIps(src, ips)
		if string.sub(ips, 1, 5) ~= "PATCH" then return nil, "not an IPS file" end
		local sbyte, ssub = string.byte, string.sub
		local parts, np = {}, 0
		local cursor = 0
		local srcLen, ipsLen = #src, #ips
		local i = 6
		while true do
			if i + 2 > ipsLen then return nil, "truncated IPS (no EOF)" end
			local b1, b2, b3 = sbyte(ips, i, i + 2)
			if b1 == 0x45 and b2 == 0x4F and b3 == 0x46 then break end  -- "EOF"
			local off = b1 * 65536 + b2 * 256 + b3
			i = i + 3
			local s1, s2 = sbyte(ips, i, i + 1)
			local size = s1 * 256 + s2
			i = i + 2
			local data
			if size == 0 then                       -- RLE record
				local r1, r2 = sbyte(ips, i, i + 1)
				local rle = r1 * 256 + r2
				i = i + 2
				local v = ssub(ips, i, i)
				i = i + 1
				data = string.rep(v, rle)
			else
				data = ssub(ips, i, i + size - 1)
				i = i + size
			end
			if off > cursor then
				np = np + 1; parts[np] = ssub(src, cursor + 1, off)   -- untouched span [cursor, off)
			elseif off < cursor then
				return nil, "overlapping IPS records"
			end
			np = np + 1; parts[np] = data
			cursor = off + #data
		end
		if cursor < srcLen then
			np = np + 1; parts[np] = ssub(src, cursor + 1)            -- tail
		end
		return table.concat(parts)
	end

	-- Red "Set up IronMob" banner across the top of the game screen (matches the bridge-warning
	-- style). The clickable button is hit-tested in self.inputCheckBizhawk.
	local function drawSetupBanner()
		if not Main.IsOnBizhawk() then return end
		local w = Constants.SCREEN.WIDTH
		gui.drawRectangle(0, 0, w, 38, 0xFFCC0000, 0xFFCC0000)
		if self.Setup.needsUpdate then
			Drawing.drawText(6, 2, "IronMob updated - ROM out of date", 0xFFFFFFFF, 0xFF000000)
			Drawing.drawText(6, 12, "Re-patch to play the newest version", 0xFFFFFF00, 0xFF000000)
		else
			Drawing.drawText(6, 2, "Welcome to IronMob!", 0xFFFFFFFF, 0xFF000000)
			Drawing.drawText(6, 12, "One-time setup required", 0xFFFFFF00, 0xFF000000)
		end
		local b = self.Setup.Button
		gui.drawRectangle(b.x, b.y, b.w, b.h, 0xFF000000, 0xFFFFFFFF)
		Drawing.drawText(b.x + 4, b.y + 2, self.Setup.needsUpdate and "Update ROM" or "Set up IronMob", 0xFFCC0000)
	end

	-- Our tiny idempotency record: { version, baseAdler, rom, size, guid }. baseAdler pins the
	-- exact patched ROM this install was set up against, so a new extension version that ships a
	-- different base ROM is detected even if the version number were somehow left unchanged.
	function self.readSetupState()
		local st = nil
		pcall(function()
			if FileManager.fileExists and not FileManager.fileExists(self.SetupPaths.state) then return end
			if FileManager.decodeJsonFile then st = FileManager.decodeJsonFile(self.SetupPaths.state) end
		end)
		if type(st) == "table" then return st end
		return nil
	end

	function self.writeSetupState(guid)
		local st = { version = self.Setup.version, baseAdler = self.Setup.baseAdler,
		             rom = self.SetupPaths.rom, size = self.Setup.romSize, guid = guid }
		pcall(function() FileManager.encodeToJsonFile(self.SetupPaths.state, st) end)
	end

	-- Create (or, if guid is given, update in place) a Generate-mode New Run profile and set it
	-- active. addUpdateProfile persists NewRunProfiles.json, mirrors the paths into Options.FILES,
	-- flips Generate_ROM_each_time, and saves settings - all Tracker-native.
	function self.createProfile(jarPath, romPath, rulesPath, guid)
		local ok, res = pcall(function()
			if type(QuickloadScreen) ~= "table" or type(QuickloadScreen.IProfile) ~= "table"
				or type(QuickloadScreen.addUpdateProfile) ~= "function" then
				return nil
			end
			local gen = (QuickloadScreen.Modes and QuickloadScreen.Modes.GENERATE) or "Generate"
			local profile = QuickloadScreen.IProfile:new({
				Name = self.Setup.profileName,
				Mode = gen,
				GameVersion = "firered",
				Paths = { Jar = jarPath, Rom = romPath, Settings = rulesPath },
			})
			if guid and guid ~= "" then profile.GUID = guid end
			if Options and Options["Game Over condition"] then
				profile.GameOverCondition = Options["Game Over condition"]
			end
			if not QuickloadScreen.addUpdateProfile(profile, true) then return nil end
			return profile.GUID
		end)
		if ok then return res end
		return nil
	end

	-- Click handler: the bare Bizhawk file dialog has no title/description, so first show a small
	-- modal explaining WHAT to pick (your own clean FireRed ROM), then run the patch flow from its
	-- button. Falls back to opening the picker directly if the Tracker form API is unavailable.
	function self.runSetup()
		if not Main.IsOnBizhawk() then return end

		-- Default the file dialog to the folder of the currently-open ROM.
		local defaultDir = ""
		pcall(function()
			local loaded = FileManager.getLoadedRomPath and FileManager.getLoadedRomPath()
			if loaded and loaded ~= "" and FileManager.getPathParts then
				defaultDir = (FileManager.getPathParts(loaded)) or ""
			end
		end)

		local shown = pcall(function()
			local X = 20
			local form = ExternalUI.BizForms.createForm("IronMob First-Time Setup", 440, 180, 60, 30)
			form:createLabel("Choose your own Pokemon FireRed (USA) ROM.", X, 18)
			form:createLabel("IronMob patches a COPY of it to build the game ROM chat", X, 40)
			form:createLabel("battles on. Your original FireRed file is not changed.", X, 58)
			form:createButton("Choose FireRed ROM...", X, 98, function()
				ExternalUI.BizForms.destroyForm()
				self.patchFromRom(defaultDir)
			end, 170, 26)
			form:createButton("Cancel", X + 190, 98, function()
				ExternalUI.BizForms.destroyForm()
			end, 90, 26)
		end)
		if not shown then self.patchFromRom(defaultDir) end   -- no form API -> straight to picker
	end

	-- Ask for the FireRed ROM, then patch -> verify -> save base ROM -> create profile.
	function self.patchFromRom(defaultDir)
		local S, P = self.Setup, self.SetupPaths

		local romPath = ""
		pcall(function()
			romPath = ExternalUI.BizForms.openFilePrompt("SELECT YOUR FIRERED ROM", defaultDir or "",
				"GBA ROM (*.gba)|*.gba|All files (*.*)|*.*") or ""
		end)
		if romPath == "" then return end   -- cancelled

		local src = readWholeFile(romPath)
		if not src then gui.addmessage("IronMob: couldn't read that ROM."); return end
		if #src ~= S.romSize then
			gui.addmessage("IronMob: that's not a 16MB GBA ROM - pick your FireRed ROM.")
			return
		end
		if adler32(src) ~= S.sourceAdler then
			gui.addmessage("IronMob: that's not the standard clean FireRed (USA) ROM.")
			return
		end

		local ipsBytes = readWholeFile(P.ips)
		if not ipsBytes then gui.addmessage("IronMob: missing rompatch/FRLG - IronMob.ips."); return end

		local patched, perr = applyIps(src, ipsBytes)
		if not patched then gui.addmessage("IronMob: patch failed (" .. tostring(perr) .. ")."); return end
		if adler32(patched) ~= S.baseAdler then
			gui.addmessage("IronMob: patched ROM checksum mismatch - is your FireRed clean?")
			return
		end
		if not writeWholeFile(P.rom, patched) then
			gui.addmessage("IronMob: couldn't save the patched ROM."); return
		end

		if P.rules == "" or not FileManager.fileExists(P.rules) then
			gui.addmessage("IronMob: couldn't find the FRLG Kaizo ruleset in the Tracker.")
			return
		end

		local prev = self.readSetupState()
		local guid = self.createProfile(P.jar, P.rom, P.rules, prev and prev.guid)
		if not guid then gui.addmessage("IronMob: couldn't create the Tracker profile."); return end

		self.writeSetupState(guid)
		self.Setup.ready = true
		self.Setup.warnActive = false
		logToFile("First-time setup complete: patched ROM + created profile " .. tostring(guid))
		gui.addmessage("IronMob is ready! Press A + B + Start to load your first seed.")
	end

	-- Startup idempotency check (cheap: state file + fileExists + size). Self-heals the profile
	-- silently if only it went missing. No prompting when already set up.
	function self.checkSetup()
		self.Setup.ready = false
		self.Setup.warnActive = false
		self.Setup.needsUpdate = false
		if not Main.IsOnBizhawk() then return end   -- BizHawk-only flow

		local P = self.SetupPaths
		local st = self.readSetupState()
		local romPresent = FileManager.fileExists(P.rom) and (fileSizeOf(P.rom) == self.Setup.romSize)
		-- Up to date only if the recorded version AND the recorded base-ROM checksum both match
		-- what this extension version ships. (baseAdler absent = state written by an older build,
		-- before checksum-pinning; fall back to the version check so we don't nag early adopters.)
		local adlerOk = (st == nil) or (st.baseAdler == nil) or (st.baseAdler == self.Setup.baseAdler)
		local romOk = st and st.version == self.Setup.version and adlerOk and romPresent

		-- Adopt an already-present base ROM when there's no state yet (upgrading an existing
		-- install). Verify its checksum once so we only adopt - and record - a correct, current
		-- ROM, and only if the jar + ruleset are in place so the profile we create is valid.
		if not romOk and romPresent and not st
			and FileManager.fileExists(P.jar) and P.rules ~= "" and FileManager.fileExists(P.rules) then
			local data = readWholeFile(P.rom)
			if data and adler32(data) == self.Setup.baseAdler then
				romOk = true
			end
		end

		if romOk then
			local haveProfile = false
			pcall(function()
				haveProfile = st and st.guid and type(QuickloadScreen) == "table"
					and type(QuickloadScreen.Profiles) == "table"
					and QuickloadScreen.Profiles[st.guid] ~= nil
			end)
			if not haveProfile then
				local guid = self.createProfile(P.jar, P.rom, P.rules, st and st.guid)
				if guid then self.writeSetupState(guid) end
			end
			self.Setup.ready = true
			return
		end
		-- Setup needed. If a prior setup exists but is now out of date (version/checksum bump, or
		-- the base ROM went missing), frame it as a re-patch rather than a first-time setup.
		self.Setup.needsUpdate = (st ~= nil)
		self.Setup.warnActive = true
	end
	-- =================== END FIRST-TIME SETUP =========================================

	function self.startup()
		bridgeFolder = FileManager.getCustomFolderPath() .. "IronMob" .. FileManager.slash
		outboxPath = bridgeFolder .. "bridge_outbox.json"
		inboxPath = bridgeFolder .. "bridge_inbox.json"
		logPath = bridgeFolder .. "ironmob_lua.log"
		heartbeatPath = bridgeFolder .. HEARTBEAT_FILE

		-- Create folder if needed
		os.execute('mkdir "' .. bridgeFolder .. '" 2>nul')

		-- First-time setup paths (see the FIRST-TIME SETUP section). The base ROM, IPS patch and
		-- state file live in the extension folder; the ruleset ships with the Tracker.
		self.SetupPaths = {
			ips   = bridgeFolder .. "rompatch" .. FileManager.slash .. "FRLG - IronMob.ips",
			jar   = bridgeFolder .. "randomizer" .. FileManager.slash .. "FRLG Ironmob Randomizer.jar",
			rom   = bridgeFolder .. self.Setup.patchedName,
			state = bridgeFolder .. self.Setup.stateFile,
			rules = "",
		}
		pcall(function()
			if FileManager.Folders and FileManager.Folders.TrackerCode and FileManager.prependDir then
				self.SetupPaths.rules = FileManager.prependDir(FileManager.Folders.TrackerCode
					.. FileManager.slash .. "RandomizerSettings" .. FileManager.slash .. self.Setup.rulesName)
			end
		end)

		-- Append to existing log with session separator (preserves history across restarts)
		local lf = io.open(logPath, "a")
		if lf then
			local sep = string.rep("=", 60)
			lf:write("\n" .. sep .. "\n")
			lf:write(os.date("=== SESSION %Y-%m-%d %H:%M:%S ===\n"))
			lf:write(sep .. "\n")
			lf:close()
		end

		logToFile("bridgeFolder: " .. bridgeFolder)
		logToFile("outboxPath: " .. outboxPath)
		logToFile("inboxPath: " .. inboxPath)
		logToFile("ROM detected: " .. (isNatDex and "Natdex" or "Vanilla FRLG") .. " (gTwitchMove=0x" .. string.format("%05X", gTwitchMove) .. ")")

		-- Fix Tracker battle detection for non-Natdex ROM (overrides GameSettings)
		overrideGameSettingsForModifiedRom()
		if not isNatDex then
			logToFile("Applied GameSettings overrides for modified FireRed ROM")
		end

		-- Initialize files
		local f = io.open(outboxPath, "w")
		if f then f:write("[]"); f:close() end
		f = io.open(inboxPath, "w")
		if f then f:write("[]"); f:close() end

		-- Fix for MoveData (same as original extension)
		MoveData.Moves[195] = MoveData.Moves[150]
		MoveData.Moves[195].id = "195"

		-- Initialize all EWRAM text buffers with terminators so ROM never reads garbage
		memory.write_u8(sText_TwitchName, 0xFF, "EWRAM")
		memory.write_u8(sText_TopDonator, 0xFF, "EWRAM")
		memory.write_u8(sText_SubAmount, 0xFF, "EWRAM")
		memory.write_u8(sText_TwitchPokemon, 0xFF, "EWRAM")
		memory.write_u8(use_twitchname, 0, "EWRAM")
		memory.write_u8(use_topDono, 0, "EWRAM")
		memory.write_u8(use_twitchpokename, 0, "EWRAM")
		memory.write_u8(gTwitchMove, 0, "EWRAM")
		memory.write_u32_le(battleLockedToAi, 0, "EWRAM")

		-- Tell the bridge this is a fresh Lua session so it resends the queue
		-- names (queue_current/queue_next start empty here - without this the
		-- overlay shows "---" while the bridge GUI still has the real names)
		queueMessage({type = "lua_hello"})
		-- Tell the server to clear any stale battle data from a previous session
		queueMessage({type = "clear_pokemon"})
		logToFile("Startup: initialized EWRAM buffers, sent lua_hello + clear_pokemon")

		-- First-time setup: patch the player's ROM + create the Quickload profile if needed.
		-- Guarded so a setup hiccup can never block the rest of the extension from loading.
		pcall(self.checkSetup)
		logToFile("Setup check: ready=" .. tostring(self.Setup.ready) .. " needsSetup=" .. tostring(self.Setup.warnActive))

		console.log("IronMob Bridge started")
	end

	function self.unload()
		-- Clean up files on unload
		local f = io.open(outboxPath, "w")
		if f then f:write("[]"); f:close() end
		f = io.open(inboxPath, "w")
		if f then f:write("[]"); f:close() end
	end

	-- Called every 30 frames - check if game needs trainer/pokemon names
	local programUpdateLogged = false
	function self.afterProgramDataUpdate()
		if not programUpdateLogged then
			logToFile("afterProgramDataUpdate firing for the first time")
			programUpdateLogged = true
		end
		checkTwitchName()
		-- checkPokemonName()  -- Disabled until separate viewer selection logic is added
		checkForestReached()

		-- Check if ROM displayed the top donator name
		local dono_shown = memory.read_u8(top_donator_shown, "EWRAM")
		if dono_shown == 1 then
			queueMessage({type = "donator_seen"})
			memory.write_u8(top_donator_shown, 0, "EWRAM")
		end
	end

	-- Called every 30 frames during battle - collect enemy pokemon data
	local battleUpdateCount = 0
	function self.afterBattleDataUpdate()
		-- Guard: Tracker can fire this callback after afterBattleEnds.
		-- Sending stale enemy_poke after battle ends leaks info to the next viewer.
		if not in_battle then return end
		-- Battle outcome already known (or result already sent): the battle is
		-- decided even if the ROM is still on the battle screen. Re-sending
		-- enemy_poke here makes the server cancel a just-armed ready check
		-- ("battle underway"), so the ready-up popup dies instantly.
		if last_battle_outcome > 0 or battle_result_sent then return end
		-- This battle was handed to ROM AI (disable_twitch_move): stop
		-- advertising it with enemy_poke updates - the server would otherwise
		-- assign a fresh trainer into a battle where all moves are ignored.
		if twitch_move_disabled then return end

		battleUpdateCount = battleUpdateCount + 1
		if battleUpdateCount <= 3 then
			logToFile("afterBattleDataUpdate called #" .. battleUpdateCount)
		end

		local ok, err = pcall(updateBattleStats)
		if not ok then
			logToFile("ERROR stats: " .. tostring(err))
		end

		local ok2, err2 = pcall(function()
			local attackerSlot = Battle.Combatants[Battle.IndexMap[1]] or 0
			local attacker = Battle.BattleParties[1] and Battle.BattleParties[1][attackerSlot]
			local attacker_mon = Tracker.getPokemon(attackerSlot, false)

			if not attacker or not attacker_mon then
				logToFile("no battle data: attacker=" .. tostring(attacker ~= nil) .. " mon=" .. tostring(attacker_mon ~= nil))
				return
			end

			-- Cross-check Tracker species against what we read from gBattleMons memory.
			-- If they disagree, the Tracker cache is stale - skip to avoid overwriting
			-- the correct data we already sent from the direct memory read.
			if last_enemy_species > 0 and attacker_mon.pokemonID ~= last_enemy_species then
				logToFile("afterBattleDataUpdate: Tracker species " .. attacker_mon.pokemonID
					.. " != memory species " .. last_enemy_species .. " (stale cache, skipping)")
				return
			end

			local copy_mon = {}
			copy_mon.pokemonID = attacker_mon.pokemonID
			copy_mon.level = attacker_mon.level
			copy_mon.nature = MiscData.Natures[attacker_mon.nature]
			copy_mon.stats = attacker_mon.stats
			copy_mon.curHP = attacker_mon.curHP
			if attacker_mon.abilityNum then
				local abilityId = PokemonData.getAbilityId(attacker_mon.pokemonID, attacker_mon.abilityNum)
				if abilityId and AbilityData.Abilities[abilityId] then
					copy_mon.ability = AbilityData.Abilities[abilityId].name
				end
			end

			-- Deep copy moves and enrich with MoveData
			copy_mon.moves = {}
			for idx = 1, 4 do
				local tracker_move = attacker_mon.moves[idx]
				if tracker_move then
					copy_mon.moves[idx] = {
						id = tracker_move.id,
						pp = tracker_move.pp,
					}
					local move_id = attacker.moves and attacker.moves[idx]
					if move_id and MoveData.Moves[move_id] then
						copy_mon.moves[idx].name = MoveData.Moves[move_id].name
						copy_mon.moves[idx].type = MoveData.Moves[move_id].type
						copy_mon.moves[idx].accuracy = MoveData.Moves[move_id].accuracy
						copy_mon.moves[idx].power = MoveData.Moves[move_id].power
						copy_mon.moves[idx].category = MoveData.Moves[move_id].category
					end
				end
			end

			local pokemonData = PokemonData.Pokemon[attacker_mon.pokemonID]
			if pokemonData then
				copy_mon.types = pokemonData.types
				copy_mon.name = pokemonData.name
			end
			copy_mon.turnCount = Battle.turnCount
			copy_mon.trainerID = Battle.opposingTrainerId
			-- Battle.isWildEncounter is stale for back-to-back battles (Tracker
			-- callbacks don't fire) - OR in our own flag so the server's wild
			-- filter actually catches consecutive wild encounters
			copy_mon.isWild = Battle.isWildEncounter or current_battle_is_wild
			copy_mon.seedCount = Main.currentSeed

			-- Read battle items from memory
			local ok_items, _ = pcall(function()
				local item_memory = Memory.readword(Memory.readdword(0x02023ff4) + 0x18) + 0x2000024
				copy_mon.items = {}
				copy_mon.items[1] = Memory.readword(item_memory)
				copy_mon.items[2] = Memory.readword(item_memory + 0x2)
				copy_mon.items[3] = Memory.readword(item_memory + 0x4)
				copy_mon.items[4] = Memory.readword(item_memory + 0x6)
			end)

			local send_str = json.stringify(copy_mon)
			if send_str ~= sent_mon then
				-- Store move names so useMove() can match them
				for idx = 1, 4 do
					if copy_mon.moves[idx] and copy_mon.moves[idx].name then
						last_sent_moves[idx] = copy_mon.moves[idx].name
					else
						last_sent_moves[idx] = nil
					end
				end
				logToFile("enemy_poke: " .. (copy_mon.name or "?")
					.. " moves=[" .. (last_sent_moves[1] or "?") .. ", " .. (last_sent_moves[2] or "?")
					.. ", " .. (last_sent_moves[3] or "?") .. ", " .. (last_sent_moves[4] or "?") .. "]"
					.. " turnCount=" .. tostring(copy_mon.turnCount)
					.. " isWild=" .. tostring(copy_mon.isWild))
				queueMessage({type = "enemy_poke", data = copy_mon})
				sent_mon = send_str
			end
		end)
		if not ok2 then
			logToFile("ERROR enemy_poke: " .. tostring(err2))
		end

		-- HP=0 detection: only check PLAYER pokemon (IronMon = one pokemon per run)
		-- Don't check enemy HP - enemy trainers can have multiple pokemon,
		-- one fainting doesn't mean the battle is over.
		-- For "viewer loses" (streamer wins), rely on afterBattleEnds + gBattleOutcome.
		-- Never for wild encounters - dying to a wild pokemon is not a viewer win
		-- and must not touch the queue.
		if in_battle and not current_battle_is_wild and use_twitch_move > 0 and not battle_result_sent then
			local ok3, err3 = pcall(function()
				local playerSlot = Battle.Combatants[Battle.IndexMap[0]] or 0
				local player_mon = Tracker.getPokemon(playerSlot, true)

				if player_mon and player_mon.curHP and player_mon.curHP == 0 then
					-- Streamer's pokemon fainted = viewer wins = run over.
					battle_result_sent = true
					forest_reached = false  -- run over: no prompts until the next run reaches the forest
					local report_name = is_rival_battle and "MOB" or current_twitchname
					queueMessage({type = "battle_result", result = "win", trainer = report_name})
					logToFile("HP=0 detected: player pokemon fainted - " .. (report_name or "?") .. " wins")
				end
			end)
			if not ok3 then
				logToFile("ERROR hp_check: " .. tostring(err3))
			end
		end
	end

	-- Write countdown timer to EWRAM so the ROM displays "Waiting for [name] (Xs)" natively
	function self.afterRedraw()
		-- First-time setup is the most fundamental problem (can't play at all), so its banner
		-- takes precedence over the bridge-not-running warning.
		local setupBanner = self.Setup.warnActive and not self.Setup.ready
		updateBridgeWarning()
		if setupBanner then
			pcall(drawSetupBanner)
		elseif BridgeWarn.active then
			drawBridgeWarning()
		end
		-- Current/next trainer names over the tracker's carousel strip
		pcall(drawQueueDisplay)
		-- Ready-check indicator (bottom-left of the game screen)
		if ReadyWait.active and not BridgeWarn.active and not setupBanner then
			pcall(drawReadyWait)
		end

		if in_battle and use_twitch_move > 0 then
			if move_timer_deadline > 0 then
				local remaining = move_timer_deadline - os.time()
				if remaining < 0 then remaining = 0 end
				if remaining > 255 then remaining = 255 end
				memory.write_u8(waitingTimer, remaining, "EWRAM")
			else
				memory.write_u8(waitingTimer, 0, "EWRAM")
			end
		else
			memory.write_u8(waitingTimer, 0, "EWRAM")
		end
	end

	-- [Bizhawk only] Executed each frame: detect a click on the warning's
	-- "Open IronMob Bridge" button and launch the bridge. Uses the same
	-- coordinate space the Tracker uses for mouse input, so the hit-test
	-- matches what's drawn on the game screen.
	function self.inputCheckBizhawk()
		local setupBanner = self.Setup.warnActive and not self.Setup.ready
		if not setupBanner and not BridgeWarn.active then
			BridgeWarn.mouseWasDown = false
			return
		end
		local mouseInput = input.getmouse()
		local down = mouseInput["Left"]
		-- Fire once on the press (edge), not every frame the button is held.
		if down and not BridgeWarn.mouseWasDown then
			local x = mouseInput["X"]
			local y = mouseInput["Y"] + Constants.SCREEN.UP_GAP
			local function hit(b) return x >= b.x and x <= b.x + b.w and y >= b.y and y <= b.y + b.h end
			-- The setup banner takes precedence over the bridge warning (same as drawing).
			if setupBanner then
				if hit(self.Setup.Button) then pcall(self.runSetup) end
			elseif BridgeWarn.active then
				if hit(WarnButton) then launchBridge() end
			end
		end
		BridgeWarn.mouseWasDown = down
	end

	-- Battle starts - enable twitch move selection (trainer battles only)
	function self.afterBattleBegins()
		-- Detect wild encounters using gBattleTypeFlags bit 3 (BATTLE_TYPE_TRAINER).
		-- gTrainerBattleOpponent_A is NOT reliable - it retains the previous trainer's
		-- ID and isn't cleared for wild encounters. The flags ARE set correctly by
		-- the ROM before afterBattleBegins fires.
		local battleFlags = Memory.readdword(0x02022b4c) or 0
		local hasTrainerFlag = (math.floor(battleFlags / 8) % 2) == 1  -- bit 3
		local trainerOpponentAddr = isNatDex and 0x02037c6e or 0x020386ae
		local rawTrainerId = Memory.readword(trainerOpponentAddr) or 0
		-- Wild = no BATTLE_TYPE_TRAINER flag. Use rawTrainerId as tiebreak only when flags are ambiguous.
		local isWild = not hasTrainerFlag
		local gTM_before = memory.read_u8(gTwitchMove, "EWRAM")
		local wM_before = memory.read_u8(waitingMove, "EWRAM")
		logToFile("afterBattleBegins: use_twitch_move=" .. use_twitch_move
			.. " gTwitchMove(before)=" .. gTM_before .. " waitingMove=" .. wM_before
			.. " trainer=" .. (current_twitchname or "none")
			.. " isWild=" .. tostring(isWild) .. " rawTrainerId=" .. rawTrainerId
			.. " battleTypeFlags=0x" .. string.format("%X", Memory.readdword(0x02022b4c) or 0))

		-- Reset viewer/AI lock for new battle (moved from ROM to Lua to preserve .text layout)
		memory.write_u32_le(battleLockedToAi, 0, "EWRAM")

		if isWild then
			-- Wild encounters: disable stall, let ROM pick moves normally
			memory.write_u8(gTwitchMove, 0, "EWRAM")
			logToFile("afterBattleBegins: wild encounter, gTwitchMove set to 0 (no stall)")
		else
			-- Trainer battles: enable stall immediately
			if use_twitch_move > 0 then
				memory.write_u8(gTwitchMove, use_twitch_move, "EWRAM")
				logToFile("afterBattleBegins: trainer battle, gTwitchMove set to " .. use_twitch_move)
			elseif current_twitchname ~= "" and current_twitchname ~= nil then
				-- Viewer was assigned during previous battle, enable stall now
				use_twitch_move = 2
				memory.write_u8(gTwitchMove, 2, "EWRAM")
				logToFile("afterBattleBegins: viewer assigned during previous battle, enabling stall for " .. current_twitchname)
			end
			-- Ensure trainer name flag is set for this battle
			if current_twitchname ~= "" and current_twitchname ~= nil then
				memory.write_u8(use_twitchname, 1, "EWRAM")
				memory.write_u8(twitch_name_shown, 0, "EWRAM")
				trainer_shown_sent = false
				local utn_verify = memory.read_u8(use_twitchname, "EWRAM")
				logToFile("afterBattleBegins: set use_twitchname=1 (readback=" .. utn_verify .. ") for " .. current_twitchname)
			end
		end

		-- Detect rival battles and notify server
		-- Oak's Lab detection (higher priority than generic isRival)
		-- Use rawTrainerId (from memory) instead of Battle.opposingTrainerId (may be stale)
		local oaksLab = not isWild and OAKS_LAB_TRAINERS[rawTrainerId]
		-- Any non-lab trainer battle means the lab is behind us (covers a
		-- tracker reload mid-run, where startup reset lab_completed)
		if not isWild and not oaksLab and not lab_completed then
			lab_completed = true
			logToFile("Non-lab trainer battle started - lab marked completed")
		end
		if oaksLab then
			is_oaks_lab_battle = true
			is_rival_battle = true
			-- Save current viewer state before rival overrides
			saved_viewer_name = current_twitchname or ""
			saved_viewer_pic = current_trainer_pic or 0
			saved_viewer_use_twitch_move = use_twitch_move
			use_twitch_move = 2
			memory.write_u8(gTwitchMove, 2, "EWRAM")
			shown_name = "the Mob"
			if current_twitchname == "" or current_twitchname == nil then
				current_twitchname = "MOB"
			end
			current_trainer_pic = 0
			memory.write_u8(twitch_trainer_pic, 0, "EWRAM")
			memory.write_u8(twitch_trainer_pic + 1, 0, "EWRAM")
			memory.write_u8(use_twitch_trainer_pic, 0, "EWRAM")
			queueMessage({type = "rival_battle", oaks_lab = true})
			logToFile("OAK'S LAB battle detected (trainerId=" .. Battle.opposingTrainerId .. "), saved viewer: " .. saved_viewer_name)
		end

		-- Generic rival detection (skip if Oak's Lab already handled)
		if not isWild and not oaksLab then
			local isRival = false
			local ok_rival, _ = pcall(function()
				isRival = TrainerData.isRival(Battle.opposingTrainerId)
			end)
			if isRival then
				is_rival_battle = true
				-- Save current viewer state before rival overrides
				saved_viewer_name = current_twitchname or ""
				saved_viewer_pic = current_trainer_pic or 0
				saved_viewer_use_twitch_move = use_twitch_move
				-- Enable stall for rival battle (mob voting)
				use_twitch_move = 2
				memory.write_u8(gTwitchMove, 2, "EWRAM")
				shown_name = "the Mob"
				if current_twitchname == "" or current_twitchname == nil then
					current_twitchname = "MOB"
				end
				-- Clear custom trainer pic so rival uses default image
				current_trainer_pic = 0
				memory.write_u8(twitch_trainer_pic, 0, "EWRAM")
				memory.write_u8(twitch_trainer_pic + 1, 0, "EWRAM")
				memory.write_u8(use_twitch_trainer_pic, 0, "EWRAM")
				queueMessage({type = "rival_battle"})
				logToFile("Rival battle detected (trainerId=" .. Battle.opposingTrainerId .. "), saved viewer: " .. saved_viewer_name)
			end
		end

		in_battle = true
		current_battle_is_wild = isWild
		twitch_move_disabled = false  -- re-enable stall for this new battle
		pending_move_value = nil  -- clear any stale pending move from previous battle
		stall_detected = false
		stall_prompt_sent = false
		stall_delay = 0
		stall_prompt_time = 0
		battle_frames = 0
		stuck_logged = false
		battle_result_sent = false
		outcome_delay = 0
		last_battle_outcome = 0
		last_enemy_species = 0
		move_written_frozen_start = 0
		last_wM_for_frozen_check = nil
	end

	-- Battle ends - clear pokemon and reset per-battle state
	-- After each trainer battle, trainer state is cleared so a new trainer is picked.
	function self.afterBattleEnds()
		local gTM = memory.read_u8(gTwitchMove, "EWRAM")
		local wM = memory.read_u8(waitingMove, "EWRAM")
		logToFile("afterBattleEnds: gTwitchMove=" .. gTM .. " waitingMove=" .. wM
			.. " use_twitch_move=" .. use_twitch_move .. " trainer=" .. (current_twitchname or "none"))
		in_battle = false
		if is_oaks_lab_battle and not lab_completed then
			lab_completed = true
			logToFile("Oak's Lab battle ended - lab marked completed")
		end
		is_oaks_lab_battle = false
		-- If the consecutive transition handler already processed this battle ending
		-- (back-to-back battles in Oak's Lab), skip trainer cleanup to avoid clobbering
		-- the restored viewer state.
		if consecutive_transition_handled then
			logToFile("afterBattleEnds: skipping (consecutive handler already processed this transition)")
			consecutive_transition_handled = false
			pending_move_value = nil
			stall_detected = false
			stall_prompt_sent = false
			stall_delay = 0
			last_move_write_time = 0
			battle_frames = 0
			stuck_logged = false
			reassert_logged = false
			battleUpdateCount = 0
			outcome_delay = 0
			last_battle_outcome = 0
			last_enemy_species = 0
			move_written_frozen_start = 0
			last_wM_for_frozen_check = nil
			return
		end
		local was_rival_battle = is_rival_battle  -- save before resetting
		is_rival_battle = false
		pending_move_value = nil
		stall_detected = false
		stall_prompt_sent = false
		stall_delay = 0
		last_move_write_time = 0
		battle_frames = 0
		stuck_logged = false
		move_written_frozen_start = 0
		last_wM_for_frozen_check = nil
		reassert_logged = false
		battleUpdateCount = 0
		outcome_delay = 0
		last_battle_outcome = 0
		last_enemy_species = 0
		local lastBattleStatus = Memory.readbyte(GameSettings.gBattleOutcome)
		logToFile("afterBattleEnds: gBattleOutcome=" .. lastBattleStatus .. " isWild=" .. tostring(current_battle_is_wild))

		if current_battle_is_wild then
			-- Still send clear_pokemon so the server cancels stale timers/flags
			-- (move_forwarded, move_timeout from a previous trainer battle)
			queueMessage({type = "clear_pokemon"})
			logToFile("afterBattleEnds: wild encounter ended, sent clear_pokemon (no battle_result)")
		else
			queueMessage({type = "clear_pokemon"})

			-- Send battle result to server (only for trainer battles, and only if HP=0 didn't already send it)
			-- 1=player won (viewer lost), 2=player lost (viewer won), 3=draw (viewer wins)
			-- For rival battles, report as "MOB" so the server doesn't kick the actual viewer
			if use_twitch_move > 0 and lastBattleStatus >= 1 and lastBattleStatus <= 3 and not battle_result_sent then
				local result = "win"
				if lastBattleStatus == 1 then result = "loss"       -- streamer won, viewer lost
				end
				battle_result_sent = true
				local report_name = was_rival_battle and "MOB" or current_twitchname
				queueMessage({type = "battle_result", result = result, trainer = report_name})
				logToFile("Battle result (afterBattleEnds): " .. result .. " (trainer=" .. (report_name or "none") .. ")")
			elseif battle_result_sent then
				logToFile("Battle result already sent via HP=0 detection, skipping afterBattleEnds")
			end
		end

		-- Clear trainer state so a new trainer is picked for the next battle
		if not current_battle_is_wild and use_twitch_move > 0 then
			if was_rival_battle and saved_viewer_name ~= "" then
				-- Rival battle ended: restore the viewer who was in the mob
				logToFile("afterBattleEnds: rival battle, restoring viewer: " .. saved_viewer_name)
				current_twitchname = saved_viewer_name
				current_trainer_pic = saved_viewer_pic
				use_twitch_move = saved_viewer_use_twitch_move
				shown_name = saved_viewer_name
				trainer_shown_sent = false
				-- Re-write viewer EWRAM data
				writestringtomemory(saved_viewer_name, sText_TwitchName, 15)
				memory.write_u8(use_twitchname, 1, "EWRAM")
				memory.write_u8(twitch_name_shown, 0, "EWRAM")
				if saved_viewer_pic > 0 then
					memory.write_u8(twitch_trainer_pic, saved_viewer_pic % 256, "EWRAM")
					memory.write_u8(twitch_trainer_pic + 1, math.floor(saved_viewer_pic / 256), "EWRAM")
					memory.write_u8(use_twitch_trainer_pic, 1, "EWRAM")
				else
					memory.write_u8(twitch_trainer_pic, 0, "EWRAM")
					memory.write_u8(twitch_trainer_pic + 1, 0, "EWRAM")
					memory.write_u8(use_twitch_trainer_pic, 0, "EWRAM")
				end
				memory.write_u8(gTwitchMove, 0, "EWRAM")  -- Clear stall between battles
			else
				-- Normal battle ended: clear everything
				logToFile("afterBattleEnds: clearing trainer for next battle (was: " .. (current_twitchname or "none") .. ")")
				use_twitch_move = 0
				current_twitchname = ""
				shown_name = ""
				current_trainer_pic = 0
				trainer_shown_sent = false
				trainer_request_pending = false
				trainer_cooldown = 0
				-- Clear all EWRAM flags so ROM behaves normally between battles
				memory.write_u8(gTwitchMove, 0, "EWRAM")
				memory.write_u8(use_twitchname, 0, "EWRAM")
				memory.write_u8(twitch_name_shown, 0, "EWRAM")
				memory.write_u8(sText_TwitchName, 0xFF, "EWRAM")  -- clear name text
				memory.write_u8(twitch_trainer_pic, 0, "EWRAM")
				memory.write_u8(twitch_trainer_pic + 1, 0, "EWRAM")
				memory.write_u8(use_twitch_trainer_pic, 0, "EWRAM")
			end
		end
		Battle.opposingTrainerId = 0
		old_turn_count = 0
		stats_log.trainerId = 0
		sent_mon = ""
		last_sent_moves = {}

		-- Auto-load next seed on player loss
		if lastBattleStatus == 2 then
			Main.loadNextSeed = true
			-- Run is over: reset both gates so the dead run pings nobody and the
			-- next run must reach Viridian Forest before ready prompts resume.
			lab_completed = false
			forest_reached = false
			logToFile("Player lost - loading next seed")
		end
	end

	-- Called every frame - read inbox and flush outbox at set frequency
	function self.afterEachFrame()
		frame = frame + 1

		-- Poll inbox FIRST so server messages (use_move, move_timer, etc.)
		-- are processed before stall/timer logic runs.
		-- This prevents the timer expiry auto-select from racing the server's
		-- mob vote result (use_move) that arrives in the same time window.
		if frame % READ_FREQUENCY == 0 then
			local messages = readInbox()
			for _, msg in ipairs(messages) do
				processInboxMessage(msg)
			end
		end

		-- Read battle outcome once per frame (used by transition detector + stall logic)
		local battleOutcome = 0
		if in_battle then
			battleOutcome = Memory.readbyte(GameSettings.gBattleOutcome) or 0
		end

		-- Detect consecutive battle transitions (outcome >0 - 0 while still in_battle).
		-- IronMon fights trainers back-to-back without returning to overworld, so
		-- afterBattleBegins/afterBattleEnds never fire. Reset per-battle state here.
		if in_battle then
			if last_battle_outcome > 0 and battleOutcome == 0 then
				logToFile("Consecutive battle transition detected (outcome " .. last_battle_outcome .. " - ), resetting per-battle state")
				-- Re-detect wildness for the NEW battle. afterBattleBegins never fires
				-- for back-to-back battles, so without this a wild encounter inherits
				-- the previous battle's current_battle_is_wild=false and a player death
				-- sends a bogus "win" battle_result that boots the queued viewer.
				-- gBattleOutcome is cleared after gBattleTypeFlags is set for the new
				-- battle, so the flags are valid to read here.
				local newBattleFlags = Memory.readdword(0x02022b4c) or 0
				local new_battle_is_wild = (math.floor(newBattleFlags / 8) % 2) == 0  -- bit 3 = BATTLE_TYPE_TRAINER
				-- If previous battle was a rival battle, restore the saved viewer state
				if is_rival_battle and saved_viewer_name ~= "" then
					logToFile("Consecutive transition: restoring viewer from rival battle: " .. saved_viewer_name)
					current_twitchname = saved_viewer_name
					current_trainer_pic = saved_viewer_pic
					use_twitch_move = saved_viewer_use_twitch_move
					shown_name = saved_viewer_name
					trainer_shown_sent = false
					if new_battle_is_wild then
						-- Keep the viewer assigned Lua-side for the next trainer fight,
						-- but don't write name/pic flags into a wild battle's UI
						logToFile("Consecutive transition: new battle is wild, skipping viewer EWRAM writes")
					else
						writestringtomemory(saved_viewer_name, sText_TwitchName, 15)
						memory.write_u8(use_twitchname, 1, "EWRAM")
						memory.write_u8(twitch_name_shown, 0, "EWRAM")
						if saved_viewer_pic > 0 then
							memory.write_u8(twitch_trainer_pic, saved_viewer_pic % 256, "EWRAM")
							memory.write_u8(twitch_trainer_pic + 1, math.floor(saved_viewer_pic / 256), "EWRAM")
							memory.write_u8(use_twitch_trainer_pic, 1, "EWRAM")
						else
							memory.write_u8(twitch_trainer_pic, 0, "EWRAM")
							memory.write_u8(twitch_trainer_pic + 1, 0, "EWRAM")
							memory.write_u8(use_twitch_trainer_pic, 0, "EWRAM")
						end
					end
				end
				-- Send battle_result for the ending battle if not already sent
				-- (never for wild encounters - those don't involve the viewer)
				if not battle_result_sent and not current_battle_is_wild and use_twitch_move > 0 then
					local result = "win"
					if last_battle_outcome == 1 then result = "loss" end
					local report_name = is_rival_battle and "MOB" or current_twitchname
					queueMessage({type = "battle_result", result = result, trainer = report_name})
					logToFile("Battle result (consecutive transition): " .. result .. " (trainer=" .. (report_name or "none") .. ")")
					battle_result_sent = true
				end
				if is_oaks_lab_battle and not lab_completed then
					lab_completed = true
					logToFile("Oak's Lab battle ended (consecutive transition) - lab marked completed")
				end
				is_rival_battle = false
				is_oaks_lab_battle = false
				saved_viewer_name = ""
				saved_viewer_pic = 0
				saved_viewer_use_twitch_move = 0
				outcome_delay = 0
				battle_result_sent = false
				twitch_move_disabled = false
				current_battle_is_wild = new_battle_is_wild
				if new_battle_is_wild then
					-- Same as afterBattleBegins: wild battles play out with no stall
					memory.write_u8(gTwitchMove, 0, "EWRAM")
					logToFile("Consecutive transition: wild encounter, gTwitchMove set to 0 (no stall)")
				end
				consecutive_transition_handled = true  -- prevent afterBattleEnds from clearing trainer
				battle_frames = 0
				stuck_logged = false
				stall_detected = false
				stall_prompt_sent = false
				stall_delay = 0
				stall_prompt_time = 0
				last_move_write_time = 0
				last_enemy_species = 0
				reassert_logged = false
				sent_mon = ""
				battleUpdateCount = 0
				pending_move_value = nil
				last_sent_moves = {}
				move_timer_deadline = 0
				-- Reset viewer/AI lock for new consecutive battle
				memory.write_u32_le(battleLockedToAi, 0, "EWRAM")
			end
			last_battle_outcome = battleOutcome
		end

		-- Every frame during battle: re-assert gTwitchMove if ROM cleared it to 0
		-- Note: value 1 is a valid stall state (ROM's "move acknowledged") - do NOT overwrite it.
		-- The ROM stall loop handles both 1 and 2: (chat_move >= 1 && chat_move <= 2)
		-- Skip if twitch move was disabled for this battle (trainer booted, AI taking over)
		if in_battle and use_twitch_move > 0 and not twitch_move_disabled then
			if battleOutcome > 0 then
				local current = memory.read_u8(gTwitchMove, "EWRAM")
				if current ~= 0 then
					memory.write_u8(gTwitchMove, 0, "EWRAM")
					logToFile("Battle outcome=" .. battleOutcome .. " detected, clearing gTwitchMove (was " .. current .. ") to let ROM exit")
				end
				-- The ROM may be stuck and afterBattleEnds may never fire.
				-- Send clear_pokemon + battle_result directly after a short delay.
				if not current_battle_is_wild then
					outcome_delay = (outcome_delay or 0) + 1
					if outcome_delay == 60 then  -- ~1 second delay to let ROM try to exit naturally
						-- Always send clear_pokemon so webapp hides moves
						logToFile("Outcome fallback: sending clear_pokemon (outcome=" .. battleOutcome .. ")")
						queueMessage({type = "clear_pokemon"})
						-- Clear stale mon data so it doesn't leak into the next battle
						sent_mon = ""
						last_sent_moves = {}
						last_enemy_species = 0
						-- Send battle_result if not already sent by HP=0 detection
						if not battle_result_sent then
							-- 1=player won (viewer lost), 2=player lost (viewer won), 3=draw
							local result = "win"
							if battleOutcome == 1 then result = "loss" end
							local report_name = is_rival_battle and "MOB" or current_twitchname
							queueMessage({type = "battle_result", result = result, trainer = report_name})
							logToFile("Battle result (outcome fallback): " .. result .. " (trainer=" .. (report_name or "none") .. ")")
							battle_result_sent = true
						else
							logToFile("Battle result already sent (HP=0 detection), skipping")
						end
						-- Clear trainer state so checkTwitchName() will request next trainer
						-- (afterBattleEnds may never fire if ROM is stuck)
						if not is_rival_battle then
							logToFile("Outcome fallback: clearing trainer state (was: " .. (current_twitchname or "none") .. ")")
							current_twitchname = ""
							shown_name = ""
							current_trainer_pic = 0
							use_twitch_move = 0
							trainer_shown_sent = false
							trainer_request_pending = false
							trainer_cooldown = 0
							memory.write_u8(use_twitchname, 0, "EWRAM")
							memory.write_u8(twitch_name_shown, 0, "EWRAM")
							memory.write_u8(sText_TwitchName, 0xFF, "EWRAM")
							memory.write_u8(twitch_trainer_pic, 0, "EWRAM")
							memory.write_u8(twitch_trainer_pic + 1, 0, "EWRAM")
							memory.write_u8(use_twitch_trainer_pic, 0, "EWRAM")
						end
					end
				end
				-- Skip all stall/re-assert logic below - battle is ending
			else
			-- Battle still in progress - normal re-assert and stall logic
			-- Skip re-assert for wild encounters: afterBattleBegins deliberately set
			-- gTwitchMove=0 so the ROM plays wild battles without chat input.
			local current = memory.read_u8(gTwitchMove, "EWRAM")
			if current == 0 and use_twitch_move > 0 and not twitch_move_disabled and not current_battle_is_wild then
				-- Only re-assert when no battle controller is executing
				-- Prevents writing stall value during move animations / switch-ins (causes freeze)
				local ctrlFlags = Memory.readdword(0x02023bc8) or 0
				if ctrlFlags == 0 then
					-- Reset battle_locked_to_ai first - the ROM may have locked to AI
					-- because it read chat_move=0 before our write took effect
					memory.write_u32_le(battleLockedToAi, 0, "EWRAM")
					memory.write_u8(gTwitchMove, use_twitch_move, "EWRAM")
					if not reassert_logged then
						logToFile("WARNING: gTwitchMove was 0 during battle, re-writing " .. use_twitch_move .. " + reset battle_locked_to_ai (ctrlFlags=0)")
						reassert_logged = true
					end
				end
			end

			-- Check stall state (waitingMove > 0 means ROM is waiting for viewer input)
			local wM = memory.read_u8(waitingMove, "EWRAM")

			-- Write pending move when ROM is in the stall loop
			if pending_move_value and wM > 0 then
				memory.write_u8(gTwitchMove, pending_move_value, "EWRAM")
				local verify = memory.read_u8(gTwitchMove, "EWRAM")
				logToFile("Pending move written: " .. pending_move_value .. " (waitingMove=" .. wM .. " verify=" .. verify .. ")")
				pending_move_value = nil
				-- Reset stall state so next turn gets a fresh prompt
				stall_detected = false
				stall_prompt_sent = false
				stall_delay = 0
				stall_prompt_time = 0
			end

			-- Check for enemy pokemon switch by reading species directly from gBattleMons
			-- Throttled to ~4x/sec (every 15 frames) - fast enough to catch switches
			local enemy_species = last_enemy_species
			if battle_frames % 15 == 0 then
				enemy_species = Memory.readword(ENEMY_MON_BASE) or 0
			end
			if enemy_species > 0 and enemy_species ~= last_enemy_species then
				if last_enemy_species > 0 then
					-- Enemy switched! Read data directly from memory (Tracker cache may be stale)
					local ok_mem, mon, move_names = pcall(readEnemyFromMemory)
					if ok_mem and mon then
						local mstr = table.concat(move_names or {}, ", ")
						logToFile("Enemy pokemon switched: species " .. last_enemy_species .. " -> " .. enemy_species
							.. " (" .. (mon.name or "?") .. ") moves=[" .. mstr .. "]")
						-- Send immediately from memory data (don't wait for Tracker)
						for idx = 1, 4 do
							if mon.moves[idx] and mon.moves[idx].name then
								last_sent_moves[idx] = mon.moves[idx].name
							else
								last_sent_moves[idx] = nil
							end
						end
						queueMessage({type = "enemy_poke", data = mon})
						sent_mon = json.stringify(mon)
					else
						logToFile("Enemy pokemon switched: species " .. last_enemy_species .. " -> " .. enemy_species
							.. " (memory read failed: " .. tostring(mon) .. ")")
						sent_mon = ""  -- Force re-send on next afterBattleDataUpdate
						pcall(self.afterBattleDataUpdate)
					end
				else
					-- First species detection this battle - just record, don't send yet
					-- (gBattleMons may still have stale data from previous battle;
					-- wait for stall detection when ROM is ready)
					logToFile("Enemy species initial: " .. enemy_species)
				end
				last_enemy_species = enemy_species
			end

			-- Stall detection: send ONE prompt_move per stall period.
			-- waitingMove is a ROM countdown that wraps through 0 periodically,
			-- so we use stall_detected to latch on first sight of wM > 0.
			-- We only reset when gTwitchMove > 2 (move actually selected by viewer).
			if current > 2 then
				-- Move was selected, reset for next turn
				if stall_detected then
					stall_detected = false
					stall_prompt_sent = false
					stall_delay = 0
					stall_prompt_time = 0
				end

				-- Frozen detection: move was written (gTM>2) but ROM isn't advancing.
				-- The stall loop should have exited, but if wM is frozen (same value
				-- for MOVE_WRITTEN_FROZEN_TIMEOUT seconds), the ROM is stuck post-stall.
				if last_wM_for_frozen_check == nil then
					last_wM_for_frozen_check = wM
					move_written_frozen_start = os.time()
				elseif wM ~= last_wM_for_frozen_check then
					-- wM is changing - ROM is progressing, reset
					last_wM_for_frozen_check = wM
					move_written_frozen_start = os.time()
				else
					-- wM frozen - check timeout
					local frozen_elapsed = os.time() - move_written_frozen_start
					-- Log diagnostics once per second while frozen (helps debug ROM-side cause)
					if frozen_elapsed >= 2 and frozen_elapsed % 2 == 0 then
						local gBattleMainFuncAddr = isNatDex and 0x03004bb4 or 0x03004f84
						local battleMainFunc = Memory.readdword(gBattleMainFuncAddr) or 0
						local ctrlExecFlags = Memory.readdword(0x02023bc8) or 0
						local battleOutcome = Memory.readbyte(0x02023e8a) or 0
						local turnActionNum = Memory.readbyte(0x02023be2) or 0
						local wM_u32 = memory.read_u32_le(waitingMove, "EWRAM") or 0
						logToFile(string.format(
							"FROZEN DIAG: gTM=%d wM_u8=%d wM_u32=%d frozen=%ds | mainFunc=0x%08X ctrlFlags=0x%X outcome=%d actionNum=%d",
							current, wM, wM_u32, frozen_elapsed,
							battleMainFunc, ctrlExecFlags, battleOutcome, turnActionNum))
					end
					if frozen_elapsed >= MOVE_WRITTEN_FROZEN_TIMEOUT and not twitch_move_disabled then
						logToFile("FROZEN RECOVERY: gTM=" .. current .. " wM=" .. wM
							.. " frozen for " .. frozen_elapsed .. "s after move write - forcing ROM AI, keeping trainer (battle voided)")
						twitch_move_disabled = true
						memory.write_u8(gTwitchMove, 0, "EWRAM")
						memory.write_u32_le(battleLockedToAi, 0, "EWRAM")
						pending_move_value = nil
						move_written_frozen_start = 0
						last_wM_for_frozen_check = nil
						last_move_write_time = 0
						-- Notify webapp - ROM is stuck post-stall, won't recover on its own.
						-- clear_pokemon also cancels the server's move timers so the
						-- trainer can't be timeout-booted while the game is frozen.
						queueMessage({type = "clear_pokemon"})
						sent_mon = ""
						last_sent_moves = {}
						last_enemy_species = 0
						-- A frozen ROM is not a battle outcome: send NO battle_result and
						-- keep the trainer assigned (locally and server-side). The viewer
						-- keeps their slot; after the streamer resets, get_new_trainer
						-- re-sends the same trainer. battle_result_sent=true voids this
						-- battle so no late result gets attributed if the ROM limps on.
						battle_result_sent = true
					end
				end
			elseif wM > 0 and not pending_move_value then
				-- ROM is stalling and no move pending - reset frozen tracking
				move_written_frozen_start = 0
				last_wM_for_frozen_check = nil
				if not stall_detected then
					stall_detected = true
					stall_delay = 0
					last_move_write_time = 0  -- new turn starting, reset move timer
					logToFile("Stall detected (waitingMove=" .. wM .. " gTM=" .. current .. ")")
					-- Re-check battle data on new stall (new turn)
					logToFile("Stall: refreshing enemy_poke data")
					pcall(self.afterBattleDataUpdate)
					-- If afterBattleDataUpdate didn't send (Tracker not ready), read from memory
					-- ROM is in the stall loop so gBattleMons is fully loaded
					if sent_mon == "" then
						logToFile("Stall: Tracker data unavailable, reading from memory")
						local ok_mem, mon, move_names = pcall(readEnemyFromMemory)
						if ok_mem and mon then
							local mstr = table.concat(move_names or {}, ", ")
							logToFile("Stall: enemy_poke from memory: " .. (mon.name or "?")
								.. " moves=[" .. mstr .. "]")
							for idx = 1, 4 do
								if mon.moves[idx] and mon.moves[idx].name then
									last_sent_moves[idx] = mon.moves[idx].name
								else
									last_sent_moves[idx] = nil
								end
							end
							queueMessage({type = "enemy_poke", data = mon})
							sent_mon = json.stringify(mon)
						else
							logToFile("Stall: memory read also failed: " .. tostring(mon))
						end
					end
				end
				stall_delay = stall_delay + 1
				if not stall_prompt_sent and stall_delay >= STALL_DELAY_FRAMES then
					logToFile("Sending prompt_move (delay=" .. stall_delay .. " frames)")
					queueMessage({type = "prompt_move"})
					stall_prompt_sent = true
					stall_prompt_time = os.time()
				end

				-- Timer expiry is handled by the server (vote_timeout_handler or
				-- move_timeout_handler), which sends use_move or disable_twitch_move.
				-- The Lua just needs the safety timeout below as a last resort.

				-- Safety timeout (real time, immune to speedup):
				-- If we sent prompt_move but got no response for 2 minutes,
				-- the bridge/server connection is likely dead.
				if stall_prompt_sent and stall_prompt_time > 0 then
					local elapsed = os.time() - stall_prompt_time
					if elapsed >= STALL_SAFETY_TIMEOUT_SECS then
						logToFile("SAFETY TIMEOUT: no move received after " .. elapsed
							.. "s real time - disabling stall for this battle, ROM AI taking over")
						twitch_move_disabled = true
						memory.write_u8(gTwitchMove, 0, "EWRAM")
						pending_move_value = nil
						stall_detected = false
						stall_prompt_sent = false
						stall_delay = 0
						stall_prompt_time = 0
					end
				end
			end
			end -- else (battle still in progress)
		end

		-- Player HP=0 detection from memory (supplements Tracker callback in afterBattleDataUpdate)
		-- In consecutive IronMon battles, afterBattleDataUpdate may not fire, so check here.
		-- Throttled to ~2x/sec (every 30 frames) to match Tracker's update rate.
		-- Never for wild encounters - dying to a wild pokemon is not a viewer win
		-- and must not touch the queue.
		if in_battle and not current_battle_is_wild and use_twitch_move > 0 and not battle_result_sent and battle_frames % 30 == 0 then
			local player_hp = Memory.readword(PLAYER_MON_BASE + 0x28) or 0xFFFF
			local player_max_hp = Memory.readword(PLAYER_MON_BASE + 0x2C) or 0
			-- Only trigger when HP is genuinely 0 and maxHP is valid (avoids false positives from uninitialized memory)
			if player_hp == 0 and player_max_hp > 0 then
				battle_result_sent = true
				forest_reached = false  -- run over: no prompts until the next run reaches the forest
				local report_name = is_rival_battle and "MOB" or current_twitchname
				queueMessage({type = "battle_result", result = "win", trainer = report_name})
				logToFile("HP=0 detected (memory): player pokemon fainted - " .. (report_name or "?") .. " wins")
			end
		end

		-- Stuck battle detection: log detailed EWRAM state when battle seems stuck
		-- Skip for wild encounters - no stalling expected, wM=0 is normal
		if in_battle and not current_battle_is_wild then
			battle_frames = battle_frames + 1
			local wM = memory.read_u8(waitingMove, "EWRAM")

			-- After 5 seconds (300 frames) in battle with wM=0 and no stall detected, we're likely stuck
			if battle_frames > 300 and wM == 0 and not stall_detected then
				-- Log detailed state every 2 seconds (120 frames)
				if not stuck_logged or (battle_frames % 120 == 0) then
					local gTM_ewram = memory.read_u8(gTwitchMove, "EWRAM")
					local chat_item_val = memory.read_u8(0x03f064, "EWRAM")  -- chat_item
					local spatk_val = memory.read_u8(0x03f068, "EWRAM")      -- spatk_stat
					local utn = memory.read_u8(use_twitchname, "EWRAM")
					local tns = memory.read_u8(twitch_name_shown, "EWRAM")
					local name0 = memory.read_u8(sText_TwitchName, "EWRAM")
					local pic_lo = memory.read_u8(twitch_trainer_pic, "EWRAM")
					local pic_hi = memory.read_u8(twitch_trainer_pic + 1, "EWRAM")
					local use_pic = memory.read_u8(use_twitch_trainer_pic, "EWRAM")

					-- Read battle state machine diagnostic values
					local gBattleMainFuncAddr = isNatDex and 0x03004bb4 or 0x03004f84
				local battleMainFunc = Memory.readdword(gBattleMainFuncAddr) or 0   -- gBattleMainFunc (IWRAM)
					local ctrlExecFlags = Memory.readdword(0x02023bc8) or 0    -- gBattleControllerExecFlags
					local battleScript = Memory.readdword(0x02023d74) or 0     -- gBattlescriptCurrInstr
					local battleOutcome = Memory.readbyte(0x02023e8a) or 0     -- gBattleOutcome
					local turnActionNum = Memory.readbyte(0x02023be2) or 0     -- gCurrentTurnActionNumber

					logToFile(string.format(
						"STUCK: battle_frames=%d wM=%d gTM_ewram=%d gTM_lua=%d pending=%s stall=%s prompt=%s | " ..
						"chat_item=%d spatk=%d | utn=%d tns=%d name0=0x%02X pic=%d use_pic=%d | " ..
						"mainFunc=0x%08X ctrlFlags=0x%X script=0x%08X outcome=%d actionNum=%d",
						battle_frames, wM, gTM_ewram, use_twitch_move,
						tostring(pending_move_value), tostring(stall_detected), tostring(stall_prompt_sent),
						chat_item_val, spatk_val,
						utn, tns, name0, pic_lo + pic_hi * 256, use_pic,
						battleMainFunc, ctrlExecFlags, battleScript, battleOutcome, turnActionNum
					))
					if not stuck_logged then
						logToFile("STUCK: First detection - battle has been running " .. battle_frames .. " frames with no stall activity")
						stuck_logged = true
					end
				end

				-- Fast recovery: if a move was written to EWRAM (gTM > 0) but the ROM
				-- is stuck executing the turn (wM=0, outcome=0) for >15 real seconds,
				-- the battle script is frozen. Force ROM AI immediately.
				-- Uses real time (os.time) so it's immune to battle_frames counter issues.
				-- Requires stall_prompt_sent so it doesn't trigger on stale timestamps
				-- from previous battles (gTM=2 from afterBattleBegins looks like a stale move).
				if not twitch_move_disabled and stall_prompt_sent and last_move_write_time > 0 then
					local move_elapsed = os.time() - last_move_write_time
					if move_elapsed >= 15 then
						local gTM_check = memory.read_u8(gTwitchMove, "EWRAM")
						if gTM_check > 0 and gTM_check <= 2 then
							logToFile("FAST RECOVERY: ROM stuck " .. move_elapsed .. "s after move write (gTM=" .. gTM_check
								.. ", wM=0) - forcing ROM AI")
							twitch_move_disabled = true
							memory.write_u8(gTwitchMove, 0, "EWRAM")
							pending_move_value = nil
							stall_detected = false
							stall_prompt_sent = false
							stall_delay = 0
							stall_prompt_time = 0
							last_move_write_time = 0
						end
					end
				end

				-- Stuck recovery: if battle is frozen AND safety timeout already fired,
				-- notify webapp so it can move on (ROM is truly stuck, won't resolve itself)
				if twitch_move_disabled and not battle_result_sent then
					-- Wait 15s (900 frames) after stuck detection before giving up
					if battle_frames > 1200 then  -- 300 (initial detection) + 900 (recovery wait)
						logToFile("STUCK RECOVERY: battle frozen for " .. battle_frames
							.. " frames after safety timeout - sending clear_pokemon + battle_result")
						-- Reset battle_locked_to_ai so the NEXT battle allows viewer control
						memory.write_u32_le(battleLockedToAi, 0, "EWRAM")
						queueMessage({type = "clear_pokemon"})
						local report_name = is_rival_battle and "MOB" or current_twitchname
						queueMessage({type = "battle_result", result = "loss", trainer = report_name})
						logToFile("Battle result (stuck recovery): loss (trainer=" .. (report_name or "none") .. ")")
						battle_result_sent = true
						-- Clear trainer state so next trainer can be assigned
						if not is_rival_battle then
							current_twitchname = ""
							shown_name = ""
							current_trainer_pic = 0
							use_twitch_move = 0
							trainer_shown_sent = false
							trainer_request_pending = false
							trainer_cooldown = 0
							memory.write_u8(use_twitchname, 0, "EWRAM")
							memory.write_u8(twitch_name_shown, 0, "EWRAM")
							memory.write_u8(sText_TwitchName, 0xFF, "EWRAM")
							memory.write_u8(twitch_trainer_pic, 0, "EWRAM")
							memory.write_u8(twitch_trainer_pic + 1, 0, "EWRAM")
							memory.write_u8(use_twitch_trainer_pic, 0, "EWRAM")
						end
					end
				end
			end

			-- If stall fires (wM > 0), clear the stuck flag
			if wM > 0 then
				if stuck_logged then
					logToFile("UNSTUCK: waitingMove=" .. wM .. " after " .. battle_frames .. " frames (stall is now active)")
					stuck_logged = false
				end
			end
		end

		-- Tick down cooldowns
		if trainer_cooldown > 0 then trainer_cooldown = trainer_cooldown - 1 end
		if pokemon_cooldown > 0 then pokemon_cooldown = pokemon_cooldown - 1 end

		-- Timeout pending requests so they can retry
		if trainer_request_pending then
			trainer_pending_timer = trainer_pending_timer + 1
			if trainer_pending_timer >= PENDING_TIMEOUT then
				logToFile("WARNING: trainer request timed out, resetting pending flag")
				trainer_request_pending = false
				trainer_pending_timer = 0
			end
		end
		if pokemon_request_pending then
			pokemon_pending_timer = pokemon_pending_timer + 1
			if pokemon_pending_timer >= PENDING_TIMEOUT then
				logToFile("WARNING: pokemon request timed out, resetting pending flag")
				pokemon_request_pending = false
				pokemon_pending_timer = 0
			end
		end

		-- Inbox poll moved to top of afterEachFrame (before stall/timer logic)

		if frame % WRITE_FREQUENCY == 0 then
			flushOutbox()
		end

		-- Periodic status log every 10 seconds (600 frames)
		if frame % 600 == 0 then
			local gTM = memory.read_u8(gTwitchMove, "EWRAM")
			local wM = memory.read_u8(waitingMove, "EWRAM")
			local utn = memory.read_u8(use_twitchname, "EWRAM")
			local tns = memory.read_u8(twitch_name_shown, "EWRAM")
			local name_byte0 = memory.read_u8(sText_TwitchName, "EWRAM")
			logToFile(string.format("STATUS: frame=%d in_battle=%s use_twitch_move=%d gTM=%d wM=%d utn=%d tns=%d name0=0x%02X trainer=%s moves=%s,%s,%s,%s",
				frame, tostring(in_battle), use_twitch_move, gTM, wM,
				utn, tns, name_byte0,
				current_twitchname or "none",
				last_sent_moves[1] or "?", last_sent_moves[2] or "?",
				last_sent_moves[3] or "?", last_sent_moves[4] or "?"))
		end
	end

	return self
end
return IronMobBridge
