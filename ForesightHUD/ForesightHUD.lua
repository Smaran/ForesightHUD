--- Foresight HUD — real card-sprite previews rendered with STANDALONE CardAreas
--- (no UIBox: embedding a CardArea in a UIBox made the box keep aligning the area
--- after teardown -> align_cards on nil cards -> crash). Standalone areas have a
--- clean lifecycle via area:remove().
---
--- WAVE 1 FOUNDATION:
---   * FHUD_rng_snapshot / FHUD_rng_restore : ONE safe dry-run wrapper used by every
---     prediction. After each restore it verifies G.GAME.pseudorandom is byte-identical
---     to the snapshot; any drift sets FHUD.integrity_ok=false and disables all
---     predictions for the session (the player's real run is sacred).
---   * FHUD.config : per-feature on/off flags, bound to the Steamodded config tab.
---   * FHUD.ui.*   : reusable render components (popover_area, banner, hand_tag, blind_strip, joker_badge).
---   * Version gate: predictions only run on the calibrated game version (1.0.1o).
---
--- Features: upcoming draws, next reroll, pack contents (hover), reroll chain (R),
--- auto-highlight Rare/Legendary, Wheel of Fortune, Lucky card, Emperor, High Priestess,
--- Judgement, The Soul, The Fool, Aura, and the Spectrals Wraith, Hex, Ectoplasm, Ankh,
--- Immolate, Sigil, Ouija, Familiar, Grim, Incantation (Wave 2b), and the joker
--- generators 8 Ball, Vagabond (selected hand), Hallucination (pack hover), Riff-raff,
--- Cartomancer, Certificate (blind select) (Wave 2c).
--- v0.5.1: the reroll preview / R chain follow the real reroll (freed shop cards, tags,
--- Illusion, prices) and pack previews follow the real pack open (G.pack_cards sticker
--- streams, Steamodded seal pool).
--- v0.6.0 (Wave 3): hand tags under your cards -- Glass BREAK/safe and Lucky rolls for the
--- selected hand, the Tarot each Purple seal makes if discarded, the Planet each held Blue
--- seal makes at round end; dry-runs no longer discover/unlock cards on your profile.
--- v0.7.0 (Wave 4): blind-select strip -- the next antes' bosses (and what a Director's Cut /
--- Retcon reroll gives), what each skip tag actually gives (shop joker, edition target, pack
--- contents, rerolled boss, money, hand levels, voucher...), and next ante's tags when exact.
--- v0.7.1: no preview is built or refreshed while the game is paused (pseudoseed returns
--- math.random() then; previews freeze and keep the last good result), math.random's own state
--- is restored exactly after every dry-run, and the boss strip shows the chain you get if you
--- buy Hieroglyph / Petroglyph (-1 ante) when one is on offer.
--- v0.8.0 (Wave 5): joker badges -- a short line on each random joker saying what it will do:
--- Space Joker (level up?), Business Card / Bloodstone / Reserved Parking (each roll of the
--- selected hand), Lucky Cat (xMult gained), Misprint (+Mult), Gros Michel / Cavendish (extinct
--- at round end?), To Do List / Ancient Joker (next hand / suit), Madness (who it kills),
--- Invisible Joker (what selling it copies), Perkeo (what leaving the shop copies), Superposition /
--- Seance / Sixth Sense (the card they make).

FHUD = FHUD or { n_show = 5 }

-------------------------------------------------------------------- config
local MOD = (SMODS and SMODS.current_mod) or nil

-- Default ALL ON. Live flags are wired below; the rest are scaffolds that light up
-- automatically when their wave lands (the render path already reads the flag).
local CONFIG_DEFAULTS = {
  -- live
  upcoming_draws = true, reroll_preview = true, pack_hover = true,
  auto_highlight = true, reroll_chain = true,
  wheel = true, lucky = true, emperor = true, high_priestess = true,
  judgement = true, soul = true, fool = true, aura = true, spectrals = true,
  eightball = true, hallucination = true, riffraff = true, cartomancer = true,
  vagabond = true, certificate = true,
  glass = true, purple_seal = true, blue_seal = true,
  boss_preview = true, skip_tags = true,
  -- joker badges (Wave 5)
  space = true, probabilistic = true, lucky_cat = true, misprint = true,
  gros_michel = true, todo_ancient = true, random_pick = true, card_makers = true,
}

FHUD.config = (MOD and MOD.config) or FHUD.config or {}
for k, v in pairs(CONFIG_DEFAULTS) do if FHUD.config[k] == nil then FHUD.config[k] = v end end
if MOD then MOD.config = FHUD.config end

-- feature flag read: missing/true => on, explicit false => off.
local function cfg(k) return FHUD.config[k] ~= false end

-- v0.7.1: while the game is PAUSED, pseudoseed returns math.random() instead of advancing
-- the seeded stream (dump misc_functions.lua 330: `if G.SETTINGS.paused and key ~= 'to_do'
-- then return math.random() end`), so a dry-run then would compute garbage. Paused = any
-- menu opened with a pause (options, run info, deck view, collection, mods menu), game over /
-- win screens, unlock pop-ups and the tutorial. G.FUNCS.overlay_menu itself does NOT pause,
-- so the R reroll-chain window (which calls it directly) is not paused. A global so the
-- validation harness can stub it.
function FHUD_rng_live()
  return not (G and G.SETTINGS and G.SETTINGS.paused)
end

-- All RNG-prediction previews are gated by this. integrity_ok / version_ok start nil
-- (treated as OK) and are only ever set to false, never back to true, within a session.
-- v0.7.1: also false while paused (no dry-run may run then). FHUD_tick freezes every preview
-- while paused instead of tearing it down, so the last good prediction (and its cache key)
-- is what you see when you come back.
local function predict_ok()
  return FHUD.integrity_ok ~= false and FHUD.version_ok ~= false and FHUD_rng_live()
end

----------------------------------------------------------------- helpers
local function disable_input(c)
  if c and c.states then
    if c.states.hover then c.states.hover.can = false end
    if c.states.click then c.states.click.can = false end
    if c.states.drag then c.states.drag.can = false end
    if c.states.collide then c.states.collide.can = false end
  end
end

-- A display-only clone that shows the card's TRUE face even if the joker/
-- consumable isn't "discovered" yet on this profile (bypass_discovery).
local function make_display_copy(src, scale)
  local ok, cp = pcall(copy_card, src, nil, scale or 0.42)
  if not ok or not cp then return nil end
  cp.no_ui = true
  cp.fhud_copy = true -- owned by us; an un-areaed one is swept (see FHUD_sweep_orphans)
  local center = cp.config and cp.config.center
  local set = center and center.set
  -- Only jokers/consumables/vouchers are discovery-gated; re-render just their
  -- CENTER with bypass (no _front, or we'd stamp a playing-card rank on them).
  if center and (set == 'Joker' or set == 'Voucher' or set == 'Booster' or center.consumeable) then
    cp.params = cp.params or {}
    cp.params.bypass_discovery_center = true
    cp.params.bypass_discovery_ui = true
    cp.bypass_discovery_center = true
    cp.bypass_discovery_ui = true
    if cp.set_sprites then pcall(function() cp:set_sprites(center, nil) end) end
  end
  -- auto-highlight: Rare (3) / Legendary (4) jokers lift above the rest.
  if cfg('auto_highlight') and center and center.rarity and center.rarity >= 3 then
    cp.highlighted = true
    cp.fhud_rare = true
  end
  disable_input(cp)
  return cp
end

-- G.GAME.used_jokers is the pool-cull table (common_events.lua get_current_pool: a key
-- that is "used" is UNAVAILABLE to every Joker/Tarot/Planet/Spectral roll). Card
-- set_ability marks a key used and Card:remove UN-marks it when no joker/consumable
-- holds that key (dump card.lua 264, 477, 5154) -- so creating or removing a DISPLAY
-- copy would change what the real game can roll. Every copy is made inside a dry-run
-- (whose restore puts used_jokers back) and every copy removal goes through this.
local function used_save()
  local uj = G.GAME and G.GAME.used_jokers
  if not uj then return nil end
  local s = {}
  for k, v in pairs(uj) do s[k] = v end
  return s
end
local function used_restore(s)
  local uj = G.GAME and G.GAME.used_jokers
  if not (s and uj) then return end
  local drop = {}
  for k in pairs(uj) do if s[k] == nil then drop[#drop + 1] = k end end
  for _, k in ipairs(drop) do uj[k] = nil end
  for k, v in pairs(s) do uj[k] = v end
end
local function keep_used(fn)
  local s = used_save()
  pcall(fn)
  used_restore(s)
end

local function clear_area(area) -- empty an area but keep it alive
  if not (area and area.cards) then return end
  keep_used(function()
    for i = #area.cards, 1, -1 do
      local c = area.cards[i]
      if area.remove_card then area:remove_card(c) end
      if c and c.remove then c:remove() end
    end
  end)
end

local function kill_area(area) -- fully destroy (removes from G.I.CARDAREA)
  if area and area.remove then keep_used(function() area:remove() end) end
end

local function new_area(n, cw)
  return CardArea(0, 0, (n + 0.3) * cw, 0.78 * G.CARD_H,
    { card_limit = n, type = "title", highlight_limit = 0, card_w = cw })
end

local function place_above(area, anchor, gap)
  if not (area and anchor and anchor.T) then return end
  area.T.x = anchor.T.x + anchor.T.w / 2 - area.T.w / 2
  area.T.y = anchor.T.y - area.T.h - (gap or 0.4)
end

------------------------------------------------------------- UI components
-- Reusable render primitives so every feature looks the same and there is one
-- place to change the look. PRESERVES the Wave 0 appearance exactly.
FHUD.ui = FHUD.ui or {}

-- Sprite-row popover: a standalone CardArea of display copies, placed above an
-- anchor. Used by the pack/reroll/wheel/emperor/priestess previews.
function FHUD.ui.popover_area(copies, anchor, scale, gap)
  local area = new_area(math.max(#(copies or {}), 1), (scale or 0.7) * G.CARD_W)
  for _, cp in ipairs(copies or {}) do disable_input(cp); area:emplace(cp) end
  place_above(area, anchor or G.shop_jokers or G.hand, gap or 0.8)
  if area.align_cards then area:align_cards() end
  return area
end

-- Screen-space text items drawn in love.draw (card sprites can't carry text).
-- `banner` registers a centred top/bottom line; `push_text` an absolute-pos line.
FHUD.overlay_items = FHUD.overlay_items or {}
function FHUD.ui.push_text(text, x, y, colour)
  FHUD.overlay_items[#FHUD.overlay_items + 1] = { t = text, x = x, y = y, colour = colour, abs = true }
end

-- Wave 3 (Pattern 2): a short text tag pinned UNDER a hand card. Registers one line;
-- several calls for the same card stack. `colour` is a TAG_COL name or an {r,g,b,a}.
-- The owner (FHUD_tag_tick) clears FHUD.hand_tag_items when it rebuilds; the position is
-- worked out every frame from the card's animated transform (FHUD_hand_tag_layout), so a
-- tag follows its card while the hand moves.
function FHUD.ui.hand_tag(card, text, colour)
  if not (card and text) then return end
  FHUD.hand_tag_items = FHUD.hand_tag_items or {}
  FHUD.hand_tag_items[#FHUD.hand_tag_items + 1] = { card = card, text = tostring(text), colour = colour }
end

-- Wave 4 (Pattern 3): a short line inside a blind-select panel ('small' / 'big' / 'boss'),
-- under its tag or boss text. `text` is a string (one colour) or a list of {text, colour}
-- segments; a colour is a TAG_COL name or an {r,g,b,a}. Several calls stack. The owner
-- (FHUD_strip_tick) clears FHUD.strip_items when it rebuilds; FHUD_blind_strip_layout places
-- the lines every frame from the panel's animated transform.
function FHUD.ui.blind_strip(opt, text, colour)
  if not (opt and text) then return end
  FHUD.strip_items = FHUD.strip_items or {}
  FHUD.strip_items[opt] = FHUD.strip_items[opt] or {}
  local segs = (type(text) == 'table') and text or { { tostring(text), colour } }
  local list = FHUD.strip_items[opt]
  list[#list + 1] = segs
end

-- Wave 5 (Pattern 4): a short text badge on a joker in G.jokers. Registers one line; several
-- calls for the same joker stack. `colour` is a TAG_COL name or an {r,g,b,a}. The owner
-- (FHUD_badge_tick) clears FHUD.joker_badge_items when it rebuilds; FHUD_joker_badge_layout
-- places the badges every frame from each joker's animated transform, so a badge follows its
-- joker when the row slides, is reordered or a joker is dragged.
-- v0.8.1: `cards` (optional) = what the joker will make, shown as sprites while it is hovered
-- (FHUD_badge_hover_tick): a list of { key = center key, edkey = edition key } or
-- { front = G.P_CARDS entry, seal = seal key }.
function FHUD.ui.joker_badge(joker, text, colour, cards)
  if not (joker and text) then return end
  FHUD.joker_badge_items = FHUD.joker_badge_items or {}
  FHUD.joker_badge_items[#FHUD.joker_badge_items + 1] = { joker = joker, text = tostring(text), colour = colour,
                                                          cards = cards }
end

----------------------------------------------------------------- draw-pile sig
local function top_sig()
  if not (G.deck and G.deck.cards) then return nil end
  local c, n = G.deck.cards, #G.deck.cards
  local t = { n }
  for i = 1, math.min(FHUD.n_show, n) do
    local cc = c[n - (i - 1)]
    local b = cc and cc.base
    t[#t + 1] = b and ((b.value or "?") .. (b.suit or "?") ..
      (cc.config and cc.config.center and tostring(cc.config.center.key) or "")) or "?"
  end
  return table.concat(t, "|")
end

----------------------------------------------- hardened RNG dry-run wrapper
-- Snapshot G.GAME.pseudorandom (the per-key counters) AND the other mutable state
-- a dry-run can touch, so a preview can run the game's real generators and then
-- leave the live run byte-for-byte unchanged.
-- v0.6.0: a dry-run must not DISCOVER or UNLOCK anything. create_card into G.jokers /
-- G.consumeables builds the Card with params.discover = true (dump common_events.lua 2458)
-- and set_ability then calls unlock_card + discover_card (card.lua 272-275), which mark the
-- center discovered on your PROFILE and save it -- so in an unseeded run a preview could
-- reveal a card you never found (seeded runs return early, which is why tests never saw
-- it). The snapshot mutes both functions until the matching restore (depth-counted for
-- nested snapshots); love.update force-unmutes after every tick as a safety net.
FHUD.disc_depth = FHUD.disc_depth or 0
local function disc_noop() end
local function disc_mute()
  if FHUD.disc_depth <= 0 then
    FHUD.disc_depth = 0
    FHUD.disc_saved = { discover_card = discover_card, unlock_card = unlock_card }
    discover_card = disc_noop
    unlock_card = disc_noop
  end
  FHUD.disc_depth = FHUD.disc_depth + 1
end
function FHUD_disc_unmute(force)
  if (FHUD.disc_depth or 0) <= 0 and not FHUD.disc_saved then return end
  FHUD.disc_depth = force and 0 or math.max(FHUD.disc_depth - 1, 0)
  if FHUD.disc_depth == 0 and FHUD.disc_saved then
    discover_card = FHUD.disc_saved.discover_card
    unlock_card = FHUD.disc_saved.unlock_card
    FHUD.disc_saved = nil
  end
end

-- v0.7.0 (Wave 4): the boss / skip-tag dry-runs also run SMODS.reset_blind_choices,
-- get_new_boss and the shop / voucher generators, so the snapshot also covers what those
-- write: G.GAME.bosses_used (Steamodded's {boss, small, big} table with a metatable;
-- restored IN PLACE so the metatable and every reference stay valid), round_resets.ante /
-- blind_choices / blind_order / boss_rerolled, the G.GAME.tags list, and the area globals a
-- dry-run swaps for stand-ins (G.shop_jokers, G.shop_vouchers, G.pack_cards).
local function bu_save()
  local bu = G.GAME and G.GAME.bosses_used
  if type(bu) ~= 'table' then return nil end
  local s = { ref = bu, top = {}, subs = {} }
  for k, v in pairs(bu) do
    if type(v) == 'table' then
      local c = {}
      for kk, vv in pairs(v) do c[kk] = vv end
      s.subs[k] = { ref = v, copy = c }
    else
      s.top[k] = v
    end
  end
  return s
end
local function bu_restore(s)
  if not s then return end
  local bu = s.ref
  local drop = {}
  for k in pairs(bu) do if s.top[k] == nil and s.subs[k] == nil then drop[#drop + 1] = k end end
  for _, k in ipairs(drop) do rawset(bu, k, nil) end
  for k, v in pairs(s.top) do rawset(bu, k, v) end
  for k, sub in pairs(s.subs) do
    rawset(bu, k, sub.ref)
    local t, d2 = sub.ref, {}
    for kk in pairs(t) do if sub.copy[kk] == nil then d2[#d2 + 1] = kk end end
    for _, kk in ipairs(d2) do t[kk] = nil end
    for kk, vv in pairs(sub.copy) do t[kk] = vv end
  end
  if G.GAME then G.GAME.bosses_used = bu end
end
local function bu_equal(s)
  if not s then return true end
  local bu = G.GAME and G.GAME.bosses_used
  if bu ~= s.ref then return false end
  for k, sub in pairs(s.subs) do
    if rawget(bu, k) ~= sub.ref or not FHUD_rng_integrity_equal(sub.ref, sub.copy) then return false end
  end
  for k, v in pairs(s.top) do if rawget(bu, k) ~= v then return false end end
  return true
end
local function rr_save()
  local rr = G.GAME and G.GAME.round_resets
  if not rr then return nil end
  local bc = {}
  for k, v in pairs(rr.blind_choices or {}) do bc[k] = v end
  local tl = {}
  for i, t in ipairs((G.GAME and G.GAME.tags) or {}) do tl[i] = t end
  return { rr = rr, ante = rr.ante, order = rr.blind_order, bc_ref = rr.blind_choices, bc = bc,
           boss_rerolled = rr.boss_rerolled, tags_ref = G.GAME.tags, tags = tl,
           shop_jokers = G.shop_jokers, shop_vouchers = G.shop_vouchers, pack_cards = G.pack_cards,
           from_boss_tag = G.from_boss_tag, orbital_hand = G.orbital_hand }
end
local function rr_restore(s)
  if not s then return end
  local rr = s.rr
  rr.ante = s.ante
  rr.blind_order = s.order
  rr.blind_choices = s.bc_ref
  if s.bc_ref then
    local drop = {}
    for k in pairs(s.bc_ref) do if s.bc[k] == nil then drop[#drop + 1] = k end end
    for _, k in ipairs(drop) do s.bc_ref[k] = nil end
    for k, v in pairs(s.bc) do s.bc_ref[k] = v end
  end
  rr.boss_rerolled = s.boss_rerolled
  if G.GAME then
    G.GAME.tags = s.tags_ref
    if s.tags_ref then
      for i = #s.tags_ref, 1, -1 do s.tags_ref[i] = nil end
      for i, t in ipairs(s.tags) do s.tags_ref[i] = t end
    end
  end
  G.shop_jokers, G.shop_vouchers, G.pack_cards = s.shop_jokers, s.shop_vouchers, s.pack_cards
  G.from_boss_tag, G.orbital_hand = s.from_boss_tag, s.orbital_hand
end

-- v0.7.1: math.random's state. pseudorandom / pseudoseed / pseudoshuffle /
-- pseudorandom_element all call math.randomseed, so every dry-run used to leave Lua's
-- generator in a different state than the game left it. LuaJIT's math.random has no state
-- getter (love.math's RandomGenerator:getState is a different generator), but its state is
-- fully determined by the last math.randomseed(x) and the number of draws since: one
-- generator step per math.random call, with or without arguments (LuaJIT lib_math.c). So both
-- are tracked (thin wrappers, installed once; every caller in the game and Steamodded looks
-- math.random up at call time) and the restore re-seeds with x and replays the draws, which
-- puts the generator back EXACTLY. Before the first re-seed after load the seed is unknown
-- and the restore leaves it alone (no run calls pseudorandom before that).
if not FHUD.mr then
  local rs, r = math.randomseed, math.random
  local m = { seed = nil, n = 0, rs = rs, r = r }
  FHUD.mr = m
  math.randomseed = function(s, ...)
    rs(s, ...)
    m.seed, m.n = s, 0
  end
  math.random = function(...)
    m.n = m.n + 1
    return r(...)
  end
end
local MR_REPLAY_MAX = 200000
local function mr_restore(seed, n)
  local m = FHUD.mr
  if not (m and seed ~= nil and n) then return end
  if n > MR_REPLAY_MAX then
    -- pathological: thousands of un-seeded draws since the last pseudorandom call. Leave it
    -- (cosmetic only, see JOURNAL v0.7.1) rather than stall the frame.
    if not FHUD.mr_logged then
      FHUD.mr_logged = true
      print("[ForesightHUD] math.random restore skipped (" .. n .. " draws since last seed)")
    end
    return
  end
  m.rs(seed)
  local r = m.r
  for _ = 1, n do r() end
  m.seed, m.n = seed, n
end

function FHUD_rng_snapshot()
  disc_mute()
  -- a dry-run while paused would read math.random() instead of the seeded stream: callers
  -- check predict_ok() first; this counter lets the validation harness prove none got through
  if not FHUD_rng_live() then FHUD.paused_snapshots = (FHUD.paused_snapshots or 0) + 1 end
  local pr = (G.GAME and G.GAME.pseudorandom) or {}
  local s = {}
  for k, v in pairs(pr) do s[k] = v end
  return {
    mr_seed = FHUD.mr and FHUD.mr.seed, mr_n = FHUD.mr and FHUD.mr.n, -- v0.7.1
    pr = s,
    used = used_save(), -- pool-cull marks set by cards created in the dry-run (v0.5.0)
    consumeable_buffer = G.GAME and G.GAME.consumeable_buffer,
    joker_buffer = G.GAME and G.GAME.joker_buffer,
    last_tarot_planet = G.GAME and G.GAME.last_tarot_planet,
    last_hand_played = G.GAME and G.GAME.last_hand_played,
    bu = bu_save(), -- v0.7.0
    rr = rr_save(), -- v0.7.0
  }
end

-- Exact table equality over the pseudorandom counters (also unit-tested).
function FHUD_rng_integrity_equal(a, b)
  if type(a) ~= 'table' or type(b) ~= 'table' then return false end
  for k, v in pairs(a) do if b[k] ~= v then return false end end
  for k, v in pairs(b) do if a[k] ~= v then return false end end
  return true
end

-- Restore from a snapshot, then VERIFY. If pseudorandom is not identical to the
-- snapshot afterwards, a dry-run leaked into the real run -> permanently disable
-- all predictions this session (logged once). Protecting the run beats any preview.
function FHUD_rng_restore(snap)
  FHUD_disc_unmute()
  if snap then pcall(mr_restore, snap.mr_seed, snap.mr_n) end -- v0.7.1: math.random's state, exactly
  if not (snap and G.GAME and G.GAME.pseudorandom) then return end
  local pr = G.GAME.pseudorandom
  -- remove keys that the dry-run added
  local drop = {}
  for k in pairs(pr) do if snap.pr[k] == nil then drop[#drop + 1] = k end end
  for _, k in ipairs(drop) do pr[k] = nil end
  -- restore snapshot values
  for k, v in pairs(snap.pr) do pr[k] = v end
  -- restore the other mutable counters
  G.GAME.consumeable_buffer = snap.consumeable_buffer
  G.GAME.joker_buffer = snap.joker_buffer
  G.GAME.last_tarot_planet = snap.last_tarot_planet
  G.GAME.last_hand_played = snap.last_hand_played
  used_restore(snap.used)
  rr_restore(snap.rr)
  bu_restore(snap.bu)
  -- integrity self-check (v0.7.0: also the boss-use counts)
  if FHUD.integrity_ok ~= false and not (FHUD_rng_integrity_equal(pr, snap.pr) and bu_equal(snap.bu)) then
    FHUD.integrity_ok = false
    if not FHUD.integrity_logged then
      FHUD.integrity_logged = true
      print("[ForesightHUD] RNG integrity check FAILED after a dry-run restore -- "
        .. "all prediction previews disabled for this session to protect your run.")
    end
  end
end

-- back-compat aliases for the existing bodies below
local snapshot_rng = FHUD_rng_snapshot
local restore_rng = FHUD_rng_restore

----------------------------------------------------------------- draw overlay
function FHUD_destroy()
  if FHUD.area then kill_area(FHUD.area); FHUD.area = nil end
  FHUD.sig = nil
end

function FHUD_refresh()
  if not (G.deck and G.deck.cards) then return end
  if not FHUD.area then FHUD.area = new_area(FHUD.n_show, 0.5 * G.CARD_W) end
  clear_area(FHUD.area)
  local c, n = G.deck.cards, #G.deck.cards
  keep_used(function() -- copies must not touch the pool-cull marks (see used_save)
    for i = 1, math.min(FHUD.n_show, n) do
      local src = c[n - (i - 1)]
      if src then
        local cp = make_display_copy(src, 0.5)
        if cp then FHUD.area:emplace(cp) end
      end
    end
  end)
  place_above(FHUD.area, G.deck, 0.4)
  if FHUD.area.align_cards then FHUD.area:align_cards() end
end

----------------------------------------------------------- reroll RNG dry-run
-- v0.5.1: the dry-run mirrors the REAL reroll, G.FUNCS.reroll_shop (dump
-- button_callbacks.lua 2910-2964), step for step:
--   1. pay reroll_cost; free_rerolls - 1; calculate_reroll_cost(final_free) (reroll_costs)
--   2. EVERY current shop card is removed first. Card:remove (dump card.lua 5152-5155)
--      un-marks its key in G.GAME.used_jokers unless a joker/consumable still holds it,
--      so a reroll CAN roll a key that is in the shop right now. Before v0.5.1 the dry-run
--      kept those keys culled and mispredicted whenever a reroll repeated one.
--   3. joker_max x create_card_for_shop(G.shop_jokers) (dump UI_definitions.lua 799-866).
-- A chained reroll removes the previous step's cards the same way. Afterwards the
-- reroll_shop context fires (Flash Card etc.: no RNG in vanilla).
local function center_key(c) return c and c.config and c.config.center and c.config.center.key end

-- Run fn with the engine's event queue muted and no overlay menu open. A dry-run card
-- must not queue real events (edition sounds, shop UI, tag animations would fire later
-- on a card that no longer exists), and Card set_ability / Card:remove only touch
-- used_jokers when no overlay is open; a real reroll never happens under an overlay.
-- Returns pcall's results; everything is put back even when fn fails.
local function dry_env(fn)
  local em = G.E_MANAGER
  local own = em and rawget(em, 'add_event')
  local ov = G.OVERLAY_MENU
  if em then em.add_event = function() end end
  G.OVERLAY_MENU = nil
  local ok, err = pcall(fn)
  G.OVERLAY_MENU = ov
  if em then em.add_event = own end
  return ok, err
end

-- Tags are NOT run in the dry-run (Tag:apply_to_run sets `triggered`, takes controller
-- locks and queues the tag's removal); their vanilla shop effects are mirrored instead
-- (dump tag.lua 366-470). `ts.used` marks a tag that already fired in the simulated
-- rerolls. A tag with its own Steamodded `apply` (a modded tag) is flagged, not modelled.
local EDITION_TAGS = { ['Foil Tag'] = 'e_foil', ['Holographic Tag'] = 'e_holo',
                       ['Polychrome Tag'] = 'e_polychrome', ['Negative Tag'] = 'e_negative' }
local function tag_open(tag, ts) return tag and not tag.triggered and not ts.used[tag] end
local function tag_modded(tag)
  local obj = SMODS and SMODS.Tags and SMODS.Tags[tag.key]
  return obj and type(obj.apply) == 'function'
end

-- store_joker_modify (the event create_card_for_shop queues per card): the first open
-- edition tag gives an editionless JOKER its edition. Returns that edition key or nil.
local function shop_modify_tags(card, ts)
  if not (card and card.ability and card.ability.set == 'Joker') or card.edition then return nil end
  for _, tag in ipairs(G.GAME.tags or {}) do
    if tag_open(tag, ts) then
      if tag_modded(tag) then
        ts.unmodelled = true
      elseif tag.config and tag.config.type == 'store_joker_modify' and EDITION_TAGS[tag.name] then
        ts.used[tag] = true
        if ts.log then ts.log[#ts.log + 1] = { tag = tag, card = card, edition = EDITION_TAGS[tag.name] } end
        return EDITION_TAGS[tag.name]
      end
    end
  end
  return nil
end

-- One shop slot, as create_card_for_shop makes it. Returns card, tag_edition.
-- Not fired: the create_shop_card / modify_shop_card contexts (no vanilla joker answers
-- them) and the shop UI; the card skips its materialize animation. None touch RNG.
local function shop_card_like_real(area, ts)
  if SMODS.optional_features and SMODS.optional_features.object_weights and SMODS.create_shop_card then
    ts.unmodelled = true -- another mod switched the shop to Steamodded's weight system
    return SMODS.create_shop_card(area), nil
  end
  -- store_joker_create: a pending Rare / Uncommon Tag makes this slot's card
  local forced
  for _, tag in ipairs(G.GAME.tags or {}) do
    if forced then break end
    if tag_open(tag, ts) then
      if tag_modded(tag) then
        ts.unmodelled = true
      elseif tag.config and tag.config.type == 'store_joker_create' then
        if tag.name == 'Rare Tag' then
          ts.used[tag] = true
          local rares = { 0 }
          for _, v in ipairs(G.jokers.cards) do
            local c = v.config.center
            if c.rarity == 3 and not rares[c.key] then rares[1] = rares[1] + 1; rares[c.key] = true end
          end
          if #G.P_JOKER_RARITY_POOLS[3] > rares[1] then
            forced = create_card('Joker', area, nil, 1, nil, nil, nil, 'rta')
          end
          if ts.log then ts.log[#ts.log + 1] = { tag = tag, card = forced, nope = not forced } end
        elseif tag.name == 'Uncommon Tag' then
          ts.used[tag] = true
          forced = create_card('Joker', area, nil, 0.9, nil, nil, nil, 'uta')
          if ts.log then ts.log[#ts.log + 1] = { tag = tag, card = forced } end
        end
      end
    end
  end
  if forced then return forced, shop_modify_tags(forced, ts) end

  local ante = G.GAME.round_resets.ante
  local function rate(t) return G.GAME[t:lower() .. '_rate'] or 0 end
  local total = (G.GAME.joker_rate or 0) + (G.GAME.playing_card_rate or 0)
  for _, v in ipairs(SMODS.ConsumableType.obj_buffer) do total = total + rate(v) end
  local polled = pseudorandom(pseudoseed('cdt' .. ante)) * total
  local check = 0
  -- same order as the engine (it polls 'illusion' while building this table)
  local rates = {
    { type = 'Joker',  val = G.GAME.joker_rate or 0 },
    { type = 'Tarot',  val = G.GAME.tarot_rate or 0 },
    { type = 'Planet', val = G.GAME.planet_rate or 0 },
    { type = (G.GAME.used_vouchers['v_illusion'] and pseudorandom(pseudoseed('illusion')) > 0.6) and 'Enhanced' or 'Base',
      val = G.GAME.playing_card_rate or 0 },
    { type = 'Spectral', val = G.GAME.spectral_rate or 0 },
  }
  for _, v in ipairs(SMODS.ConsumableType.obj_buffer) do
    if not (v == 'Tarot' or v == 'Planet' or v == 'Spectral') then rates[#rates + 1] = { type = v, val = rate(v) } end
  end
  for _, v in ipairs(rates) do
    if polled > check and polled <= check + v.val then
      local card = SMODS.create_card({ set = v.type, area = area, key_append = 'sho', front = false, skip_materialize = true })
      -- Illusion: Steamodded's poll_edition, not vanilla's foil/holo/poly thresholds
      if (v.type == 'Base' or v.type == 'Enhanced') and G.GAME.used_vouchers['v_illusion']
          and pseudorandom(pseudoseed('illusion')) > 0.8 then
        card:set_edition(poll_edition('illusion', nil, true, true))
      end
      return card, shop_modify_tags(card, ts)
    end
    check = check + v.val
  end
  return nil
end

-- Card:remove's un-mark for cards leaving the shop (see step 2 above).
local function unmark_removed(cards)
  for _, c in ipairs(cards) do
    local k = center_key(c)
    if k and not next(SMODS.find_card(k, true)) then G.GAME.used_jokers[k] = nil end
  end
end

-- The next `n` rerolls in a row. MUST run inside a snapshot (counters advance exactly
-- like real successive rerolls; the caller restores once). Returns ok, rows, created,
-- unmodelled: rows[r] = { {card=, tag_ed=}, ... }; the caller removes `created`.
local function reroll_chain_core(n)
  local jm = G.GAME.shop.joker_max or 2
  local rows, created = {}, {}
  local ts = { used = {} }
  local prev = {}
  for _, c in ipairs(G.shop_jokers.cards or {}) do prev[#prev + 1] = c end
  local ok, err = dry_env(function()
    for r = 1, n do
      unmark_removed(prev)
      local row, cur = {}, {}
      for _ = 1, jm do
        local card, ted = shop_card_like_real(G.shop_jokers, ts)
        if card then
          created[#created + 1] = card
          row[#row + 1] = { card = card, tag_ed = ted }
          cur[#cur + 1] = card
        end
      end
      rows[r] = row
      prev = cur
    end
  end)
  if not ok and not FHUD.reroll_err_logged then
    FHUD.reroll_err_logged = true
    print("[ForesightHUD] reroll preview failed: " .. tostring(err))
  end
  return ok, rows, created, ts.unmodelled
end

local function row_copy(entry, scale)
  local cp = make_display_copy(entry.card, scale)
  if cp and entry.tag_ed then pcall(function() cp:set_edition(entry.tag_ed, true, true) end) end
  return cp
end

local function free_created(created)
  for _, c in ipairs(created) do if c.remove then pcall(function() c:remove() end) end end
end

local function reroll_ready()
  return G.shop_jokers and G.shop_jokers.cards and G.GAME and G.GAME.shop and G.GAME.round_resets
      and G.jokers and G.jokers.cards
end

function FHUD_peek_reroll_cards()
  if not predict_ok() then return {} end
  if not reroll_ready() then return {} end
  local snap = snapshot_rng()
  local ok, rows, created, unmod = reroll_chain_core(1)
  local copies = {}
  if ok then
    for _, e in ipairs(rows[1] or {}) do
      local cp = row_copy(e, 0.6)
      if cp then copies[#copies + 1] = cp end
    end
  end
  free_created(created)
  restore_rng(snap)
  FHUD.reroll_unmodelled = unmod
  return copies
end

-- Simulate the next `n` successive rerolls (see reroll_chain_core).
-- Returns { [r] = {keys...} } (key .. " foil"/" holo"/" poly"/" neg" when it has an edition).
function FHUD_peek_reroll_chain(n)
  if not predict_ok() then return {} end
  if not reroll_ready() then return {} end
  local snap = snapshot_rng()
  local ok, rows, created = reroll_chain_core(n)
  local out = {}
  if ok then
    for r, row in ipairs(rows) do
      local keys = {}
      for _, e in ipairs(row) do
        local card = e.card
        local et = e.tag_ed and e.tag_ed:gsub('^e_', '')
            or (card.edition and (card.edition.type or (card.edition.polychrome and 'polychrome')
              or (card.edition.holo and 'holo') or (card.edition.foil and 'foil') or (card.edition.negative and 'negative')))
        local ed = (et == 'polychrome' and " poly") or (et == 'holo' and " holo") or (et == 'foil' and " foil")
            or (et == 'negative' and " neg") or ""
        keys[#keys + 1] = (center_key(card) or "?") .. ed
      end
      out[r] = keys
    end
  end
  free_created(created)
  restore_rng(snap)
  return out
end

-- Like the chain above but returns display COPIES per reroll: { [r] = {cards} }.
function FHUD_peek_reroll_chain_cards(n, scale)
  if not predict_ok() then return {} end
  if not reroll_ready() then return {} end
  local snap = snapshot_rng()
  local ok, rows, created, unmod = reroll_chain_core(n)
  local out = {}
  if ok then
    for r, row in ipairs(rows) do
      local cps = {}
      for _, e in ipairs(row) do
        local cp = row_copy(e, scale or 0.3)
        if cp then cps[#cps + 1] = cp end
      end
      out[r] = cps
    end
  end
  free_created(created)
  restore_rng(snap)
  FHUD.reroll_unmodelled = unmod
  return out
end

-- Price of each of the next n rerolls and whether you can pay for it, mirroring
-- G.FUNCS.can_reroll (dump button_callbacks.lua 2090: blocked when
-- dollars - bankrupt_at - cost < 0 and cost ~= 0) and calculate_reroll_cost
-- (common_events.lua 2622: free rerolls cost 0 and the LAST free one does not raise
-- the price; vouchers / D6 Tag act through round_resets.reroll_cost / temp_reroll_cost).
-- Replaces v0.5.0's affordable_rerolls, which used the current price (0 while free
-- rerolls remain) as the base for the paid ones and ignored Credit Card's bankrupt_at.
function FHUD_reroll_costs(n)
  local g = G.GAME
  local cr, rr = g.current_round or {}, g.round_resets or {}
  local money = (g.dollars or 0) - (g.bankrupt_at or 0)
  local free = math.max(cr.free_rerolls or 0, 0)
  local cost = cr.reroll_cost or 0
  local inc = cr.reroll_cost_increase or 0
  local out, broke = {}, false
  for k = 1, n do
    if cost ~= 0 and money - cost < 0 then broke = true end
    out[k] = { cost = cost, ok = not broke }
    if not broke then money = money - cost end
    local final_free = free > 0
    free = math.max(free - 1, 0)
    if free > 0 then
      cost = 0
    else
      if not final_free then inc = inc + 1 end
      cost = (rr.temp_reroll_cost or rr.reroll_cost or 5) + inc
    end
  end
  return out
end

-- Everything the next reroll depends on: the shop cards (they get freed), what you
-- hold (culled), vouchers, slots, rates, tags, the pool-cull table and the RNG. The
-- preview is rebuilt only when this changes (v0.5.0 keyed it on the shop cards alone,
-- so selling a joker or buying a voucher left it stale).
function FHUD_reroll_sig()
  local g = G.GAME
  local t = {}
  local areas = { G.shop_jokers, G.jokers, G.consumeables }
  for ai = 1, 3 do
    local a = areas[ai]
    if a and a.cards then
      t[#t + 1] = #a.cards
      for _, c in ipairs(a.cards) do t[#t + 1] = tostring(center_key(c)) end
    end
  end
  local nv, nu = 0, 0
  for _ in pairs(g.used_vouchers or {}) do nv = nv + 1 end
  for _ in pairs(g.used_jokers or {}) do nu = nu + 1 end
  local pr, s = g.pseudorandom, 0
  for _, v in pairs(pr or {}) do if type(v) == 'number' then s = s + v end end
  -- v0.7.1: + ante (Hieroglyph / Petroglyph change it mid-shop; 'cdt'..ante etc. are ante-keyed)
  t[#t + 1] = table.concat({ nv, nu, tostring(g.round_resets and g.round_resets.ante),
    tostring(g.shop and g.shop.joker_max), tostring(g.joker_rate),
    tostring(g.tarot_rate), tostring(g.planet_rate), tostring(g.playing_card_rate), tostring(g.spectral_rate),
    string.format("%.12f", s) }, ",")
  for _, tag in ipairs(g.tags or {}) do t[#t + 1] = tostring(tag.key) .. (tag.triggered and "t" or "") end
  return table.concat(t, "|")
end

-- Show the next-10 reroll chain as a native modal overlay (like the Collection
-- screens): cards embedded in a UIBox so the game lays them out & owns cleanup.
function FHUD_chain_overlay()
  if not predict_ok() then return end
  if not (G.shop_jokers and G.GAME and G.GAME.shop and G.ROOM and G.ROOM.T) then return end
  local n = 10
  local scale = 0.5
  local rows = FHUD_peek_reroll_chain_cards(n, scale)
  local costs = {}
  pcall(function() costs = FHUD_reroll_costs(n) end)
  local jm = G.GAME.shop.joker_max or 2
  local cw = scale * G.CARD_W
  local function row_node(r)
    local area = CardArea(G.ROOM.T.x, G.ROOM.T.h, (jm + 0.6) * cw, scale * G.CARD_H * 1.15,
      { card_limit = jm, type = "title", highlight_limit = 0 })
    for _, cp in ipairs(rows[r] or {}) do
      area:emplace(cp)
      -- Hover shows the card's normal tooltip so you can read a joker before rerolling.
      -- Card:hover needs collide+hover and no no_ui; click/drag stay off (display only).
      cp.no_ui = false
      if cp.states then
        if cp.states.collide then cp.states.collide.can = true end
        if cp.states.hover then cp.states.hover.can = true end
      end
    end
    -- "3. $7": that reroll's price; greyed once your money can't reach it.
    local c = costs[r]
    local txt = r .. "." .. (c and ((c.cost == 0) and " free" or (" $" .. c.cost)) or "")
    local col = (c and not c.ok) and G.C.UI.TEXT_INACTIVE or G.C.WHITE
    return { n = G.UIT.R, config = { align = "cm", padding = 0.03 }, nodes = {
      { n = G.UIT.C, config = { align = "cm", minw = 1.1 }, nodes = {
        { n = G.UIT.T, config = { text = txt, scale = 0.35, colour = col } } } },
      { n = G.UIT.O, config = { object = area } },
    } }
  end
  local cols, per, col_nodes, idx = 2, 5, {}, 1
  for _ = 1, cols do
    local rws = {}
    for _ = 1, per do
      if idx <= n then rws[#rws + 1] = row_node(idx); idx = idx + 1 end
    end
    col_nodes[#col_nodes + 1] = { n = G.UIT.C, config = { align = "tm", padding = 0.1 }, nodes = rws }
  end
  local contents = {
    { n = G.UIT.R, config = { align = "cm", padding = 0.06 }, nodes = {
      { n = G.UIT.T, config = { text = "NEXT REROLLS", scale = 0.6, colour = G.C.BLUE } } } },
  }
  if FHUD.reroll_unmodelled then
    contents[#contents + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0.02 }, nodes = {
      { n = G.UIT.T, config = { text = "(a modded tag or shop weighting is active: not modelled)", scale = 0.3,
        colour = G.C.UI.TEXT_INACTIVE } } } }
  end
  contents[#contents + 1] = { n = G.UIT.R, config = { align = "cm", r = 0.1, colour = G.C.BLACK, padding = 0.1,
    emboss = 0.05 }, nodes = col_nodes }
  local def = create_UIBox_generic_options({ back_func = "exit_overlay_menu", contents = contents })
  G.FUNCS.overlay_menu { definition = def }
end

function FHUD_shop_destroy()
  if FHUD.shoparea then kill_area(FHUD.shoparea); FHUD.shoparea = nil end
  FHUD.shopsig = nil
end

function FHUD_shop_refresh()
  if not FHUD.shoparea then FHUD.shoparea = new_area(2, 0.6 * G.CARD_W) end
  clear_area(FHUD.shoparea)
  local ok, cards = pcall(FHUD_peek_reroll_cards)
  if ok and cards then
    for _, cp in ipairs(cards) do disable_input(cp); FHUD.shoparea:emplace(cp) end
  end
  place_above(FHUD.shoparea, G.shop_jokers, 0.8)
  if FHUD.shoparea.align_cards then FHUD.shoparea:align_cards() end
end

------------------------------------------------- Wave 2c: shared joker helpers
local function ckey(c)
  return c and c.config and c.config.center and c.config.center.key
end

-- Which joker's ability runs when `j` calculates. Mirrors Card:calculate_joker
-- (dump card.lua 2678-2697: Blueprint -> right neighbour, Brainstorm -> leftmost) and
-- SMODS.blueprint_effect (smods utils.lua 2398: no self-copy, target not debuffed and
-- blueprint_compat, chain depth <= #jokers). `j` itself must be able to calculate
-- (Card:can_calculate: not debuffed). `list` defaults to the live joker row.
local function resolve_joker(j, list)
  list = list or (G.jokers and G.jokers.cards) or {}
  if not j or j.debuff then return nil end
  local cur, depth = j, 0
  while true do
    local k = ckey(cur)
    local nxt
    if k == 'j_blueprint' then
      for i = 1, #list do if list[i] == cur then nxt = list[i + 1] end end
    elseif k == 'j_brainstorm' then
      nxt = list[1]
    else
      return cur
    end
    if depth > #list then return nil end
    if not nxt or nxt == cur or nxt.debuff
        or not (nxt.config and nxt.config.center and nxt.config.center.blueprint_compat) then
      return nil
    end
    depth = depth + 1
    cur = nxt
  end
end

-- "1 in N" threshold exactly as SMODS.pseudorandom_probability computes it (smods
-- utils.lua 3232-3246: mod_probability/fix_probability contexts, Oops! All 6s). Called
-- in the same no-resolve form the game uses for every tooltip, so it has no side effects.
local function prob_vars(j, denom, ident)
  if SMODS and SMODS.get_probability_vars then
    local ok, n, d = pcall(SMODS.get_probability_vars, j, 1, denom, ident)
    if ok and n and d then return n, d end
  end
  return (G.GAME.probabilities and G.GAME.probabilities.normal) or 1, denom
end

local function center_name(key)
  local c = key and G.P_CENTERS and G.P_CENTERS[key]
  if not c then return tostring(key) end
  local ok, s = pcall(localize, { type = 'name_text', set = c.set, key = key })
  if ok and type(s) == 'string' and s ~= '' and s ~= 'ERROR' then return s end
  return c.name or tostring(key)
end

-- Hallucinations (incl. Blueprint/Brainstorm copies) in the order they roll on a
-- pack open: SMODS.calculate_context walks G.jokers.cards left to right.
local function halu_rollers()
  local out = {}
  for _, j in ipairs((G.jokers and G.jokers.cards) or {}) do
    local e = resolve_joker(j)
    if ckey(e) == 'j_hallucination' then out[#out + 1] = e end
  end
  return out
end

----------------------------------------------------------- pack peek (dry-run)
-- v0.5.1: follows the RUNTIME pack open, Card:open (dump card.lua 2058-2119): for each
-- of max(1, extra + booster_size_mod) slots it calls the booster center's own
-- create_card(pack, i) -- Steamodded take_ownership_by_kind()s all five vanilla kinds
-- (smods game_object.lua 1769-1918) -- and passes the returned table to
-- SMODS.create_card. Two things v0.5.0 got wrong by re-deriving it:
--   * the area is G.pack_cards, and create_card picks the sticker keys from it
--     (dump common_events.lua 2472-2481): 'packetper'/'packssjr' in a pack vs
--     'etperpoll'/'ssjr' in the shop, so Buffoon-pack eternal/perishable/rental stickers
--     came from the wrong stream at Black stake and up;
--   * Standard packs roll their seal through SMODS.poll_seal({mod = 10}) (the weighted
--     seal pool), not vanilla's fixed Red/Blue/Gold/Purple thresholds.
-- G.pack_cards does not exist while you are in the shop, so a stand-in area is put
-- there for the dry-run (only its position is read; nothing is emplaced) and the real
-- value is put back. Not fired: the create_booster_card / modify_booster_card contexts
-- (no vanilla joker answers them). Other mods' boosters run through the same call.
local function pack_standin()
  local T = (G.shop_jokers and G.shop_jokers.T) or (G.hand and G.hand.T) or { x = 0, y = 0, w = 1, h = 1 }
  return { T = { x = T.x, y = T.y, w = T.w, h = T.h }, cards = {}, config = { card_limit = 0, type = 'consumeable' },
           fhud_standin = true }
end

local function legacy_pack_card(name, i, ante) -- only for a booster without create_card
  if name:find('Arcana') then
    if G.GAME.used_vouchers.v_omen_globe and pseudorandom('omen_globe') > 0.8 then
      return create_card("Spectral", G.pack_cards, nil, nil, true, true, nil, 'ar2')
    end
    return create_card("Tarot", G.pack_cards, nil, nil, true, true, nil, 'ar1')
  elseif name:find('Spectral') then
    return create_card("Spectral", G.pack_cards, nil, nil, true, true, nil, 'spe')
  elseif name:find('Buffoon') then
    return create_card("Joker", G.pack_cards, nil, nil, true, true, nil, 'buf')
  end
  return nil
end

local function gen_pack_cards(pack)
  local center = pack.config and pack.config.center
  local name = (pack.ability and pack.ability.name) or ""
  local size = math.max(1, ((pack.ability and pack.ability.extra) or 1) + (G.GAME.modifiers.booster_size_mod or 0))
  local ante = G.GAME.round_resets.ante
  local out = {}
  local had = G.pack_cards
  G.pack_cards = had or pack_standin()
  local ok, err = dry_env(function() -- events muted: a dry-run card must not queue any
    for i = 1, size do
      local card
      if center and type(center.create_card) == 'function' then
        local spawn = center:create_card(pack, i)
        if type((spawn or {}).is) == 'function' and spawn:is(Card) then
          card = spawn
        else
          card = SMODS.create_card(spawn)
        end
      else
        card = legacy_pack_card(name, i, ante)
      end
      if card then out[#out + 1] = card end
    end
  end)
  G.pack_cards = had
  if not ok and not FHUD.pack_err_logged then
    FHUD.pack_err_logged = true
    print("[ForesightHUD] pack preview failed: " .. tostring(err))
  end
  if not ok then out.failed = true end -- no preview for this pack (cards still removed)
  return out -- whatever was made, so the caller can remove it
end

-- Pack type (= shared RNG stream) for ordering duplicates. Mirrors gen_pack_cards.
local function pack_type_key(pack)
  local name = (pack and pack.ability and pack.ability.name) or ""
  if name:find('Arcana') then return 'Arcana'
  elseif name:find('Celestial') then return 'Celestial'
  elseif name:find('Spectral') then return 'Spectral'
  elseif name:find('Standard') then return 'Standard'
  elseif name:find('Buffoon') then return 'Buffoon' end
  return name
end

-- BUG FIX: same-type packs share one RNG stream, so a pack's contents depend on
-- how many same-type packs were opened BEFORE it. We predict ALL shop packs in a
-- SINGLE chained dry-run (generate in shelf order WITHOUT restoring between, like
-- the reroll chain) so pack #2 of a type shows what you get AFTER pack #1 opens.
-- Cached per shop line-up; rebuilt when the packs change (one is bought/opened).
-- v0.5.0: the map also depends on what the pools cull (shop cards, owned jokers and
-- consumables, vouchers), on Hallucination (jokers, consumable room, probabilities) and
-- on the RNG, so all of those are part of the cache key (a reroll used to leave the
-- pack contents stale: the old shop cards were still counted as culled).
local function pack_list_sig()
  if not (G.shop_booster and G.shop_booster.cards) then return "" end
  local t = {}
  for _, p in ipairs(G.shop_booster.cards) do t[#t + 1] = tostring(p) end
  local areas = { G.shop_jokers, G.jokers, G.consumeables }
  for ai = 1, 3 do
    local a = areas[ai]
    if a and a.cards then
      t[#t + 1] = #a.cards .. "/" .. tostring(a.config and a.config.card_limit)
      for _, c in ipairs(a.cards) do t[#t + 1] = tostring(ckey(c)) .. (c.debuff and "d" or "") end
    end
  end
  local nv = 0
  for _ in pairs((G.GAME and G.GAME.used_vouchers) or {}) do nv = nv + 1 end
  local pr, s = G.GAME and G.GAME.pseudorandom, 0
  for _, v in pairs(pr or {}) do if type(v) == 'number' then s = s + v end end
  t[#t + 1] = nv .. "," .. tostring(G.GAME and G.GAME.consumeable_buffer) .. ","
      .. tostring(G.GAME and G.GAME.round_resets and G.GAME.round_resets.ante) .. "," -- v0.7.1
      .. tostring(G.GAME and G.GAME.probabilities and G.GAME.probabilities.normal) .. ","
      .. string.format("%.12f", s)
  return table.concat(t, "|")
end

-- The map holds HIDDEN template copies (never in an area). Any card in G.I.CARD
-- without a parent is drawn every frame, so templates must be invisible and must
-- be removed whenever the map is dropped -- leaking them left a stray card on screen.
function FHUD_pack_map_clear()
  keep_used(function()
    for _, entry in pairs(FHUD.pack_map or {}) do
      for _, c in ipairs(entry.copies or {}) do if c.remove then c:remove() end end
    end
  end)
  FHUD.pack_map = nil
  FHUD.pack_map_sig = nil
end

function FHUD_build_pack_map()
  FHUD_pack_map_clear()
  FHUD.pack_map_sig = pack_list_sig()
  if not predict_ok() then return end
  if not (G.shop_booster and G.shop_booster.cards and #G.shop_booster.cards > 0
          and G.GAME and G.GAME.round_resets) then return end
  local packs = G.shop_booster.cards
  local totals = {}
  for _, p in ipairs(packs) do local t = pack_type_key(p); totals[t] = (totals[t] or 0) + 1 end
  local snap = snapshot_rng()
  local created, raw, halu = {}, {}, {}
  -- Wave 2c Hallucination. Card:open (dump card.lua 2054-2134) queues the contents
  -- event (trigger 'after' 1.3s, NON-blocking) and THEN fires context.open_booster
  -- synchronously: each Hallucination (card.lua 2698) checks room
  -- (#consumeables + consumeable_buffer < limit; a full buffer skips the roll), rolls
  -- SMODS.pseudorandom_probability('halu'..ante, 1, 2) and queues a 'before' event that
  -- creates create_card('Tarot', G.consumeables, ..., 'hal'). That event runs before the
  -- rolls. BUT those create events are blockable and each hit also queues a blocking
  -- ~0.94s status text, while the contents event is non-blocking on its own
  -- 1.3*sqrt(GAMESPEED) timer (engine/event.lua): so a 2nd+ Tarot -- or even the 1st,
  -- if something else is queued -- can land after the contents. The ROLLS are exact
  -- (synchronous); for an Arcana pack (same Tarot pool) we run every interleaving and
  -- only name the cards when all of them agree. The Tarots stay in your slots for later
  -- packs (assumed kept, like the open order).
  local rollers = halu_rollers()
  local cons = #G.consumeables.cards
  local climit = G.consumeables.config.card_limit
  local ante = G.GAME.round_resets.ante
  local chain_unc = false
  -- Phase 1: generate every pack in shelf order, chaining the RNG (no restore).
  for idx, p in ipairs(packs) do
    local hits = 0
    local h
    if #rollers > 0 then
      h = { rolls = {}, keys = {}, after_uncertain = chain_unc }
      pcall(function()
        local buf = G.GAME.consumeable_buffer or 0
        for _, e in ipairs(rollers) do
          if cons + buf < climit then
            local n, d = prob_vars(e, (e.ability and e.ability.extra) or 2, 'halu' .. ante)
            local hit = pseudorandom('halu' .. ante) < n / d
            h.rolls[#h.rolls + 1] = hit and 'HIT' or 'MISS'
            if hit then buf = buf + 1; hits = hits + 1 end
          else
            h.rolls[#h.rolls + 1] = 'FULL'
          end
        end
        h.pr = G.GAME.pseudorandom['halu' .. ante]
      end)
      halu[idx] = h
    end
    -- one interleaving: `v` Hallucination Tarots, then the contents, then the rest
    local function run_variant(v)
      local hk, made, cards = {}, {}, {}
      local function mk()
        local t
        -- v0.8.0: events muted (a consumable's start_materialize queues a sound + dissolve events)
        local okm, errm = dry_env(function() t = create_card('Tarot', G.consumeables, nil, nil, nil, nil, nil, 'hal') end)
        if not okm then error(errm, 0) end
        if t then made[#made + 1] = t; hk[#hk + 1] = ckey(t) end
      end
      for _ = 1, v do mk() end
      pcall(function() cards = gen_pack_cards(p) end)
      for _ = v + 1, hits do mk() end
      return hk, cards, made
    end
    local function keys_of(list) local t = {} for _, c in ipairs(list) do t[#t + 1] = tostring(ckey(c)) end return table.concat(t, ",") end
    local use_v = hits
    if hits > 0 and pack_type_key(p) == 'Arcana' then
      h.variants = {}
      local sub = snapshot_rng()
      for v = 0, hits do
        local hk, cards, made = {}, {}, {}
        pcall(function() hk, cards, made = run_variant(v) end)
        h.variants[#h.variants + 1] = { halu = table.concat(hk, ","), contents = keys_of(cards) }
        for _, c in ipairs(made) do if c.remove then c:remove() end end
        for _, c in ipairs(cards) do if c.remove then c:remove() end end
        restore_rng(sub)
      end
      for _, vr in ipairs(h.variants) do
        if vr.halu ~= h.variants[1].halu or vr.contents ~= h.variants[1].contents then h.uncertain = true end
      end
      if h.uncertain then chain_unc = true end
      use_v = 1 -- what the headless runs showed; only matters when flagged uncertain
    end
    local cards, made = {}, {}
    pcall(function()
      local hk
      hk, cards, made = run_variant(use_v)
      if h then for _, k in ipairs(hk) do h.keys[#h.keys + 1] = k end end
    end)
    cons = cons + hits
    for _, c in ipairs(made) do created[#created + 1] = c end
    for _, c in ipairs(cards) do created[#created + 1] = c end
    raw[idx] = cards
    -- The pack then closes: its cards are removed (skipped, or the Tarot/Planet/
    -- Spectral is used), and Card:remove un-marks a key no joker/consumable holds, so
    -- the NEXT pack can roll it again. Mirror that un-mark here (cards stay alive for
    -- the templates; copying now would roll set_ability RNG mid-chain). Before v0.5.0
    -- the chain kept them culled. Assumption: you don't KEEP a Buffoon joker.
    pcall(function()
      for _, c in ipairs(cards) do
        local k = ckey(c)
        if k and not next(SMODS.find_card(k, true)) then G.GAME.used_jokers[k] = nil end
      end
    end)
  end
  -- Phase 2: make display copies AFTER all generation (does not disturb the chain).
  local map, seen = {}, {}
  for idx, p in ipairs(packs) do
    local t = pack_type_key(p); seen[t] = (seen[t] or 0) + 1
    local copies = {}
    for _, c in ipairs(raw[idx].failed and {} or raw[idx]) do
      local cp = make_display_copy(c, 0.7)
      if cp then
        cp.states.visible = false
        cp.fhud_template = true
        copies[#copies + 1] = cp
      end
    end
    map[p] = { copies = copies, order = seen[t], total = totals[t] or 1,
               halu = halu[idx], shelf = idx, shelf_total = #packs }
  end
  for _, c in ipairs(created) do if c.remove then c:remove() end end
  restore_rng(snap)
  FHUD.pack_map = map
end

-- Ensure the cached chain is current, then return this pack's entry.
function FHUD_peek_pack(pack)
  if not predict_ok() then return nil end
  if (not FHUD.pack_map) or FHUD.pack_map_sig ~= pack_list_sig() then
    pcall(FHUD_build_pack_map)
  end
  return FHUD.pack_map and FHUD.pack_map[pack] or nil
end

function FHUD_pack_destroy()
  if FHUD.packarea then kill_area(FHUD.packarea); FHUD.packarea = nil end
  FHUD.hovered_pack = nil
  FHUD.pack_label = nil
  FHUD.halu_label = nil
end

function FHUD_pack_show(pack)
  if not cfg('pack_hover') then return end
  local entry = FHUD_peek_pack(pack)
  -- Fresh visible copies of the cached templates: the popover's kill_area removes
  -- what it holds, so handing it the templates would break the next hover.
  -- copy_card runs set_ability, which rolls RNG for some jokers (e.g. To Do List),
  -- so the copies are made inside a snapshot like every other dry-run.
  local copies = {}
  local snap = snapshot_rng()
  for _, t in ipairs((entry and entry.copies) or {}) do
    local cp = make_display_copy(t, 0.7)
    if cp then copies[#copies + 1] = cp end
  end
  restore_rng(snap)
  if FHUD.packarea then kill_area(FHUD.packarea); FHUD.packarea = nil end
  FHUD.packarea = FHUD.ui.popover_area(copies, G.shop_jokers, 0.7, 0.8) -- clean top spot
  -- When duplicates of this type exist, say which open-order this prediction assumes.
  local ord = { "1st", "2nd", "3rd", "4th", "5th" }
  if entry and entry.total and entry.total > 1 then
    FHUD.pack_label = pack_type_key(pack):upper() .. ": if opened "
      .. (ord[entry.order] or (entry.order .. "th")) .. " of " .. entry.total
  else
    FHUD.pack_label = nil
  end
  -- Wave 2c: what Hallucination makes when THIS pack is opened. Every open rolls the
  -- same 'halu'..ante stream, so with 2+ packs it assumes shelf order (left first).
  FHUD.halu_label = nil
  local h = entry and entry.halu
  if h and cfg('hallucination') and #h.rolls > 0 then
    local parts, ki = {}, 0
    for _, r in ipairs(h.rolls) do
      if r == 'HIT' then
        ki = ki + 1
        parts[#parts + 1] = h.uncertain and "HIT" or ("HIT -> " .. center_name(h.keys[ki]))
      elseif r == 'MISS' then
        parts[#parts + 1] = "MISS"
      else
        parts[#parts + 1] = "no room"
      end
    end
    local pre = "HALLUCINATION"
    if (entry.shelf_total or 1) > 1 then
      pre = pre .. " (if opened " .. (ord[entry.shelf] or (entry.shelf .. "th")) .. ")"
    end
    local s = pre .. ": " .. table.concat(parts, ", ")
    if h.uncertain then
      s = s .. " - which Tarots, and this pack's cards, depend on animation timing"
    elseif h.after_uncertain then
      s = s .. " (after an earlier timing-dependent pack)"
    end
    FHUD.halu_label = s
  end
end

--------------------------------------------- wheel / lucky / emperor peek
-- All read the EXACT game RNG keys from card.lua (game-dump verified):
--   Wheel hit : pseudorandom('wheel_of_fortune') < probabilities.normal/extra (extra=4)
--   Wheel tgt : pseudorandom_element(editionless_jokers, pseudoseed('wheel_of_fortune'))
--   Wheel ed  : poll_edition('wheel_of_fortune', nil, true, true)  (foil/holo/poly, guaranteed)
--   Lucky mult: pseudorandom('lucky_mult')  < probabilities.normal/5
--   Lucky $   : pseudorandom('lucky_money') < probabilities.normal/15
--   Emperor   : 2x create_card('Tarot',  ..., 'emp')
--   Priestess : 2x create_card('Planet', ..., 'pri')
-- Each wrapped in snapshot_rng()/restore_rng() so the live game is untouched.

local function find_hover_in(area, pred)
  if not (area and area.cards) then return nil end
  local tgt = G.CONTROLLER and G.CONTROLLER.hovering and G.CONTROLLER.hovering.target
  for _, c in ipairs(area.cards) do
    if (c == tgt or (c.states and c.states.hover and c.states.hover.is)) and pred(c) then return c end
  end
  return nil
end

-- Edition -> display name. Steamodded's poll_edition returns a STRING key
-- ('e_foil'/'e_holo'/'e_polychrome'/'e_negative'); vanilla returns {foil=true}.
local function ed_name(e)
  if not e then return nil end
  local t
  if type(e) == 'string' then
    t = e:gsub('^e_', '')
  else
    t = e.type or (e.key and tostring(e.key):gsub('^e_', ''))
        or (e.polychrome and 'polychrome') or (e.holo and 'holo')
        or (e.foil and 'foil') or (e.negative and 'negative')
  end
  if t == 'polychrome' then return "Polychrome" end
  if t == 'holo' then return "Holographic" end
  if t == 'foil' then return "Foil" end
  if t == 'negative' then return "Negative" end
  return "Edition"
end

-- Predict the Wheel of Fortune's edition roll + which joker + which edition.
function FHUD_peek_wheel(card)
  if not predict_ok() then return nil end
  if not (card and G.GAME and G.jokers) then return nil end
  local snap = snapshot_rng()
  local res = { hit = false }
  pcall(function()
    local extra = (card.ability and card.ability.extra) or 4
    local pnorm = (G.GAME.probabilities and G.GAME.probabilities.normal) or 1
    res.prob = tostring(pnorm) .. " in " .. tostring(extra)
    local roll = pseudorandom('wheel_of_fortune')
    if roll < pnorm / extra then
      res.hit = true
      local pool = {}
      for _, v in pairs(G.jokers.cards) do
        if v.ability and v.ability.set == 'Joker' and (not v.edition) then pool[#pool + 1] = v end
      end
      if #pool > 0 then
        local eligible = pseudorandom_element(pool, pseudoseed('wheel_of_fortune'))
        local edition = poll_edition('wheel_of_fortune', nil, true, true)
        res.edition = edition
        res.edition_str = ed_name(edition) or "Foil"
        if eligible then
          res.target_name = eligible.ability and eligible.ability.name
          local cp = make_display_copy(eligible, 0.7)
          if cp and edition and cp.set_edition then pcall(function() cp:set_edition(edition, true, true) end) end
          res.target_copy = cp
        end
      else
        res.no_jokers = true
      end
    end
  end)
  restore_rng(snap)
  return res
end

-- Predict the lucky-card roll(s). BUG FIX: a Lucky card rolls ONCE PER TRIGGER
-- (base + red seal + retrigger jokers), each trigger rolling lucky_mult (1/5) then
-- lucky_money (1/15) consecutively (verified vs card.lua eval_card: get_chip_mult
-- 598 then get_p_dollars 608, re-run once per rep in state_events). We simulate the
-- next few triggers in order. We can be CERTAIN of base + red seal + Hack(rank 2-5)
-- + Sock&Buskin(face) + Seltzer; Dusk(final hand)/Hanging Chad(first scored)/
-- Blueprint/Brainstorm are play-dependent, so we flag "could be more".
function FHUD_lucky_text(card)
  if not predict_ok() then return nil end
  if not (G.GAME and card) then return nil end
  local N = 6
  local seq = {}
  local snap = snapshot_rng()
  pcall(function()
    local pnorm = (G.GAME.probabilities and G.GAME.probabilities.normal) or 1
    for _ = 1, N do
      local m = pseudorandom('lucky_mult') < pnorm / 5
      local d = pseudorandom('lucky_money') < pnorm / 15
      seq[#seq + 1] = { mult = m, money = d }
    end
  end)
  restore_rng(snap)
  if #seq == 0 then return nil end

  local known, conditional = 1, false
  pcall(function()
    if card.seal == 'Red' then known = known + 1 end
    local id = card.get_id and card:get_id() or nil
    local face = card.is_face and card:is_face() or false
    if G.jokers and G.jokers.cards then
      for _, j in ipairs(G.jokers.cards) do
        local nm = j.ability and j.ability.name
        local ex = (j.ability and j.ability.extra) or 1
        if nm == 'Hack' and id and (id == 2 or id == 3 or id == 4 or id == 5) then known = known + ex
        elseif nm == 'Sock and Buskin' and face then known = known + ex
        elseif nm == 'Seltzer' then known = known + 1
        elseif nm == 'Dusk' or nm == 'Hanging Chad' or nm == 'Blueprint' or nm == 'Brainstorm' then conditional = true end
      end
    end
  end)

  local function sym(s) return (s.mult and s.money) and "+M&$" or s.mult and "+Mult" or s.money and "+$20" or "-" end

  -- Common case: a single trigger -> the familiar one-line verdict (unchanged).
  if known == 1 and not conditional then
    local s = seq[1]
    if s.mult and s.money then return "LUCKY: +Mult & +$20"
    elseif s.mult then return "LUCKY: +Mult"
    elseif s.money then return "LUCKY: +$20"
    else return "LUCKY: nothing" end
  end

  -- Multi-trigger / uncertain: show the per-trigger roll sequence so it is correct
  -- for whatever the real trigger count turns out to be.
  local show = conditional and math.max(known, 4) or known
  if show > N then show = N end
  if show < 1 then show = 1 end
  local parts = {}
  for i = 1, show do parts[#parts + 1] = sym(seq[i]) end
  if conditional then
    return "LUCKY per trigger: " .. table.concat(parts, "  ") .. "  (+more if retriggered)"
  end
  return "LUCKY x" .. known .. ": " .. table.concat(parts, "  ")
end

-- Emperor (2 Tarots) / High Priestess (2 Planets): the actual cards created.
function FHUD_peek_consumable_create(card)
  if not predict_ok() then return nil end
  local name = card and card.ability and card.ability.name
  local is_emp = name == 'The Emperor'
  local is_pri = name == 'The High Priestess'
  if not (is_emp or is_pri) then return nil end
  local snap = snapshot_rng()
  local created, copies = {}, {}
  dry_env(function() -- v0.8.0: no materialize sound / events from the dry-run cards
    local cfg_c = card.ability.consumeable or {}
    local want = cfg_c.tarots or cfg_c.planets or 2
    local typ = is_emp and 'Tarot' or 'Planet'
    local app = is_emp and 'emp' or 'pri'
    for _ = 1, want do
      local c = create_card(typ, G.shop_jokers, nil, nil, nil, nil, nil, app)
      if c then created[#created + 1] = c end
    end
  end)
  for _, c in ipairs(created) do
    local cp = make_display_copy(c, 0.7)
    if cp then copies[#copies + 1] = cp end
  end
  for _, c in ipairs(created) do if c.remove then c:remove() end end
  restore_rng(snap)
  return copies
end

-- Wave 2a: center key -> {kind, flag}. Drives which special a hovered card is.
-- Key-based (not name) so it is localisation-proof.
local SPECIAL_KINDS = {
  c_wheel_of_fortune = { kind = 'wheel',     flag = 'wheel' },
  c_emperor          = { kind = 'emperor',   flag = 'emperor' },
  c_high_priestess   = { kind = 'priestess', flag = 'high_priestess' },
  c_judgement        = { kind = 'judgement', flag = 'judgement' },
  c_soul             = { kind = 'soul',      flag = 'soul' },
  c_fool             = { kind = 'fool',      flag = 'fool' },
  c_aura             = { kind = 'aura',      flag = 'aura' },
  c_wraith           = { kind = 'wraith',    flag = 'spectrals' },
  -- Wave 2b
  c_hex              = { kind = 'hex',         flag = 'spectrals' },
  c_ectoplasm        = { kind = 'ectoplasm',   flag = 'spectrals' },
  c_ankh             = { kind = 'ankh',        flag = 'spectrals' },
  c_immolate         = { kind = 'immolate',    flag = 'spectrals' },
  c_sigil            = { kind = 'sigil',       flag = 'spectrals' },
  c_ouija            = { kind = 'ouija',       flag = 'spectrals' },
  c_familiar         = { kind = 'familiar',    flag = 'spectrals' },
  c_grim             = { kind = 'grim',        flag = 'spectrals' },
  c_incantation      = { kind = 'incantation', flag = 'spectrals' },
}

-- Display copy that also carries the card's edition (copy_card can drop it).
local function copy_with_edition(card, scale)
  local cp = make_display_copy(card, scale)
  if cp and card.edition and cp.set_edition then
    pcall(function() cp:set_edition(card.edition, true, true) end)
  end
  return cp
end

-- Judgement / The Soul / Wraith: run the game's REAL create_card as a dry-run so
-- the rarity roll, pool cull (owned/locked/Showman), resamples and edition poll are
-- all exact. Same area the real card uses (G.jokers), so no stray shop/pack rolls.
function FHUD_peek_joker_create(kind)
  if not predict_ok() then return nil end
  if not (G.GAME and G.jokers) then return nil end
  local snap = snapshot_rng()
  local created
  dry_env(function() -- v0.8.0: no edition sound / events from the dry-run card
    if kind == 'judgement' then
      created = create_card('Joker', G.jokers, false, nil, nil, nil, nil, 'jud')
    elseif kind == 'soul' then
      created = create_card('Joker', G.jokers, true, nil, nil, nil, nil, 'sou')
    elseif kind == 'wraith' then
      created = create_card('Joker', G.jokers, nil, 0.99, nil, nil, nil, 'wra')
    end
  end)
  local copies = {}
  if created then
    local cp = copy_with_edition(created, 0.7)
    if cp then copies[1] = cp end
    if created.remove then created:remove() end
  end
  restore_rng(snap)
  local label = (kind == 'judgement' and "JUDGEMENT creates:")
    or (kind == 'soul' and "THE SOUL creates:")
    or "WRAITH creates (sets $0):"
  local lim = (G.jokers.config and G.jokers.config.card_limit) or 5
  if #G.jokers.cards >= lim then label = label .. " (jokers full)" end
  return copies, label
end

-- The Fool: a deterministic copy of G.GAME.last_tarot_planet (forced_key, no pool RNG).
function FHUD_peek_fool()
  if not predict_ok() then return nil end
  local key = G.GAME and G.GAME.last_tarot_planet
  if (not key) or key == 'c_fool' or not (G.P_CENTERS and G.P_CENTERS[key]) then
    return nil, "FOOL: nothing to copy yet"
  end
  local snap = snapshot_rng()
  local created
  dry_env(function() -- v0.8.0: no materialize sound / events
    created = create_card('Tarot_Planet', G.consumeables, nil, nil, nil, nil, key, 'fool')
  end)
  local copies = {}
  if created then
    local cp = make_display_copy(created, 0.7)
    if cp then copies[1] = cp end
    if created.remove then created:remove() end
  end
  restore_rng(snap)
  return copies, "FOOL copies:"
end

-- Aura: the guaranteed edition (>= Foil, never Negative) on the highlighted card.
function FHUD_peek_aura()
  if not predict_ok() then return nil end
  if not G.GAME then return nil end
  local snap = snapshot_rng()
  local edition
  pcall(function() edition = poll_edition('aura', nil, true, true) end)
  restore_rng(snap)
  local nm = ed_name(edition) or "Foil"
  local hc = G.hand and G.hand.highlighted and G.hand.highlighted[1]
  if hc then
    local copies = {}
    local cp = make_display_copy(hc, 0.7)
    if cp and edition and cp.set_edition then pcall(function() cp:set_edition(edition, true, true) end) end
    if cp then copies[1] = cp end
    return copies, "AURA -> " .. nm
  end
  return nil, "AURA -> " .. nm .. " (highlight a card)"
end

------------------------------------------- Wave 2b: target-picking spectrals
-- Recipes follow the RUNTIME code (lovely dump + Steamodded), NOT vanilla card.lua:
--   * Steamodded take_ownership()s Sigil, Ouija, Grim, Familiar, Incantation
--     (smods src/game_object.lua 2468-2655): pools are SMODS.Suits / SMODS.Ranks
--     objects and the enhancement pool drops `overrides_base_rank` (= Stone).
--   * Hex / Ectoplasm / Ankh / Immolate run the patched Card:use_consumeable
--     (dump card.lua 1659-1816).
--   * pseudorandom_element AND pseudoshuffle re-sort Card lists by sort_id
--     (dump misc_functions.lua 210, 289), so a card's POSITION in hand/joker row never
--     matters (only creation order). We pass the engine's own tables to the engine's
--     own functions, so that ordering is reproduced rather than re-derived.
-- Display copies are made INSIDE the snapshot window: copying a joker re-runs
-- set_ability, which rolls RNG for some jokers (To Do List -> 'to_do', card.lua:438).
local SPECTRAL_2B = {
  hex = true, ectoplasm = true, ankh = true, immolate = true, sigil = true,
  ouija = true, familiar = true, grim = true, incantation = true,
}
-- Steamodded owns these (their center has a `use`); the rest take the vanilla path.
local SMODS_OWNED = { sigil = true, ouija = true, familiar = true, grim = true, incantation = true }

local function loc_or(key, set, fallback)
  local ok, s = pcall(localize, key, set)
  if ok and type(s) == 'string' and s ~= '' and s ~= 'ERROR' then return s end
  return fallback or tostring(key)
end

local function pc_name(c) -- "King of Spades"
  local b = c and c.base
  if not b then return "?" end
  return loc_or(b.value, 'ranks') .. " of " .. loc_or(b.suit, 'suits_plural')
end

local function jk_name(j)
  return (j and j.ability and j.ability.name) or "?"
end

local function is_eternal(v, card)
  if SMODS and SMODS.is_eternal then return SMODS.is_eternal(v, card) end
  return v.ability and v.ability.eternal
end

local function free_cards(list)
  keep_used(function()
    for _, c in ipairs(list or {}) do if c and c.remove then c:remove() end end
  end)
end

-- Copy of a held card, optionally re-based to another suit/rank object (preview only:
-- the copy is never in G.playing_cards; set_base(..., initial=true) skips the blind
-- debuff hook and the modify_deck unlock check).
local function hand_copy(src, scale, suit_obj, rank_obj)
  local cp = make_display_copy(src, scale)
  if cp and (suit_obj or rank_obj) then
    local s = suit_obj or SMODS.Suits[src.base.suit]
    local r = rank_obj or SMODS.Ranks[src.base.value]
    local front = s and r and G.P_CARDS[s.card_key .. '_' .. r.card_key]
    if front then pcall(function() cp:set_base(front, true) end) end
  end
  return cp
end

-- A playing card that doesn't exist yet (Familiar/Grim/Incantation output). The temp
-- Card has no playing_card id and is removed at once; only the display copy survives.
local function new_card_copy(front, center, scale)
  local raw, cp
  pcall(function()
    raw = Card(0, 0, G.CARD_W, G.CARD_H, front, center, { bypass_back = G.GAME.selected_back.pos })
    cp = make_display_copy(raw, scale)
  end)
  if raw and raw.remove then raw:remove() end
  return cp
end

local function hand_gate(nm)
  local n = (G.hand and G.hand.cards and #G.hand.cards) or 0
  if n == 0 then return nm .. ": needs cards in hand (use it during a blind)" end
  if n < 2 then return nm .. ": needs 2+ cards in hand" end
  return nil
end

-- Predict one Wave 2b spectral. Returns a result table:
--   label (banner), copies (display cards, only when `build`), scale, plus data the
--   validation harness diffs against the real engine (target, destroyed, created, ...).
-- Returns nil when no preview applies (prediction off, or the card is overridden).
function FHUD_peek_spectral(card, kind, build)
  if not predict_ok() then return nil end
  if not (card and SPECTRAL_2B[kind] and G.GAME and G.jokers and G.jokers.cards) then return nil end
  local center = card.config and card.config.center
  local owned = center and type(center.use) == 'function'
  if (SMODS_OWNED[kind] and not owned) or (not SMODS_OWNED[kind] and owned) then return nil end

  local res = { copies = {}, scale = 0.7 }
  local NAME = string.upper(kind)

  -- eligibility that needs no RNG (mirrors can_use_consumeable / check_use)
  local pool
  if kind == 'hex' or kind == 'ectoplasm' then
    pool = {}
    for _, v in pairs(G.jokers.cards) do
      if v.ability and v.ability.set == 'Joker' and (not v.edition) then pool[#pool + 1] = v end
    end
    if #pool == 0 then res.label = NAME .. ": needs a joker with no edition"; return res end
  elseif kind == 'ankh' then
    local any = false
    for _, v in pairs(G.jokers.cards) do
      if v.ability and v.ability.set == 'Joker' and G.jokers.config.card_limit > 1 then any = true end
    end
    if not any then res.label = "ANKH: needs a joker to copy"; return res end
  else
    local why = hand_gate(NAME)
    if why then res.label = why; return res end
  end

  local snap = snapshot_rng()
  local ok, err = pcall(function()
    if kind == 'hex' or kind == 'ectoplasm' then
      -- card.lua 1791: pseudorandom_element(eligible_editionless_jokers, pseudoseed('hex'|'ectoplasm'))
      local t = pseudorandom_element(pool, pseudoseed(kind == 'hex' and 'hex' or 'ectoplasm'))
      res.target = t
      if kind == 'hex' then
        local n = 0
        for _, v in pairs(G.jokers.cards) do
          if v ~= t and not is_eternal(v, card) then n = n + 1 end
        end
        res.destroyed_n = n
        res.label = "HEX -> Polychrome on " .. jk_name(t) ..
            (n > 0 and ("; destroys " .. n .. " other joker" .. (n == 1 and "" or "s")) or "")
      else
        res.hand_loss = G.GAME.ecto_minus or 1
        res.label = "ECTOPLASM -> Negative on " .. jk_name(t) .. "; hand size -" .. res.hand_loss
      end
      if build and t then
        local cp = make_display_copy(t, 0.7)
        if cp then
          pcall(function() cp:set_edition(kind == 'hex' and { polychrome = true } or { negative = true }, true, true) end)
          res.copies[1] = cp
        end
      end

    elseif kind == 'ankh' then
      -- card.lua 1751: pseudorandom_element(G.jokers.cards, pseudoseed('ankh_choice')) - ALL jokers
      local t = pseudorandom_element(G.jokers.cards, pseudoseed('ankh_choice'))
      res.target = t
      local n = 0
      for _, v in pairs(G.jokers.cards) do
        if v ~= t and not is_eternal(v, card) then n = n + 1 end
      end
      res.destroyed_n = n
      -- the copy keeps the edition, except Negative is stripped (card.lua 1763-1768)
      local ed = t and t.edition
      if ed and ed.negative then ed = nil end
      res.copy_edition = ed and (ed.type or ed_name(ed)) or nil
      res.full = #G.jokers.cards >= G.jokers.config.card_limit
      res.label = "ANKH copies " .. jk_name(t) .. (ed and (" (" .. ed_name(ed) .. ")") or "") ..
          (n > 0 and ("; destroys " .. n .. " other joker" .. (n == 1 and "" or "s")) or "") ..
          (res.full and " - joker slots full, free one first" or "")
      if build and t then
        local cp = make_display_copy(t, 0.7)
        if cp then
          if t.edition and t.edition.negative then pcall(function() cp:set_edition(nil, true, true) end) end
          res.copies[1] = cp
        end
      end

    elseif kind == 'immolate' then
      -- card.lua 1660-1665 verbatim: copy, sort by playing_card, pseudoshuffle (which
      -- re-sorts by sort_id first), destroy the first extra.destroy.
      local temp_hand = {}
      for _, v in ipairs(G.hand.cards) do temp_hand[#temp_hand + 1] = v end
      table.sort(temp_hand, function(a, b) return not a.playing_card or not b.playing_card or a.playing_card < b.playing_card end)
      pseudoshuffle(temp_hand, pseudoseed('immolate'))
      local ex = (card.ability and card.ability.extra) or {}
      local destroy = ex.destroy or 5
      res.destroyed = {}
      for i = 1, destroy do res.destroyed[#res.destroyed + 1] = temp_hand[i] end
      res.dollars = ex.dollars or 20
      res.label = "IMMOLATE: destroys these " .. #res.destroyed .. ", +$" .. res.dollars
      if build then
        for _, c in ipairs(res.destroyed) do
          local cp = make_display_copy(c, 0.7)
          if cp then res.copies[#res.copies + 1] = cp end
        end
      end

    elseif kind == 'sigil' or kind == 'ouija' then
      -- smods game_object.lua 2472 / 2499: one pick for the whole hand.
      local s, r
      if kind == 'sigil' then
        s = pseudorandom_element(SMODS.Suits, pseudoseed('sigil'))
        res.suit = s and s.key
        res.label = "SIGIL -> every held card becomes " .. loc_or(res.suit, 'suits_plural')
      else
        r = pseudorandom_element(SMODS.Ranks, pseudoseed('ouija'))
        res.rank = r and r.key
        res.label = "OUIJA -> every held card becomes a " .. loc_or(res.rank, 'ranks') .. "; hand size -1"
      end
      if build and (s or r) then
        local n = #G.hand.cards
        res.scale = (n > 5) and 0.55 or 0.7
        for _, c in ipairs(G.hand.cards) do
          local cp = hand_copy(c, res.scale, s, r)
          if cp then res.copies[#res.copies + 1] = cp end
        end
      end

    else -- familiar / grim / incantation (smods game_object.lua 2523-2655)
      -- 1) use(): random_destroy runs synchronously
      local victim = pseudorandom_element(G.hand.cards, pseudoseed('random_destroy'))
      res.destroyed = { victim }
      -- 2) the create event (after 0.7s): per card rank, suit, then 'spe_card'
      res.created = {}
      local n = (card.ability and card.ability.extra) or 0
      for i = 1, n do
        local _suit, _rank
        if kind == 'familiar' then
          local faces = {}
          for _, v in ipairs(SMODS.Rank.obj_buffer) do
            local rr = SMODS.Ranks[v]
            if rr.face then table.insert(faces, rr) end
          end
          _rank, _suit =
              pseudorandom_element(faces, pseudoseed('familiar_create')).card_key,
              pseudorandom_element(SMODS.Suits, pseudoseed('familiar_create')).card_key
        elseif kind == 'grim' then
          _suit, _rank =
              pseudorandom_element(SMODS.Suits, pseudoseed('grim_create')).card_key, 'A'
        else
          local numbers = {}
          for _, v in ipairs(SMODS.Rank.obj_buffer) do
            local rr = SMODS.Ranks[v]
            if v ~= 'Ace' and not rr.face then table.insert(numbers, rr) end
          end
          _rank, _suit =
              pseudorandom_element(numbers, pseudoseed('incantation_create')).card_key,
              pseudorandom_element(SMODS.Suits, pseudoseed('incantation_create')).card_key
        end
        local cen_pool = {}
        for _, v in pairs(G.P_CENTER_POOLS["Enhanced"]) do
          if not v.overrides_base_rank then cen_pool[#cen_pool + 1] = v end
        end
        local cen = pseudorandom_element(cen_pool, pseudoseed('spe_card'))
        res.created[i] = { front_key = _suit .. '_' .. _rank, center_key = cen and cen.key }
      end
      res.label = NAME .. ": destroys " .. pc_name(victim) .. " (dimmed), adds " .. n .. " card" .. (n == 1 and "" or "s")
      if build then
        res.scale = (n + 1 > 5) and 0.55 or 0.7
        local cp = victim and make_display_copy(victim, res.scale)
        if cp then cp.debuff = true; res.copies[#res.copies + 1] = cp end
        for _, c in ipairs(res.created) do
          local front, cen = G.P_CARDS[c.front_key], G.P_CENTERS[c.center_key]
          local ncp = front and cen and new_card_copy(front, cen, res.scale)
          if ncp then res.copies[#res.copies + 1] = ncp end
        end
      end
    end
  end)
  restore_rng(snap)
  if not ok then
    free_cards(res.copies)
    print("[ForesightHUD] spectral preview failed (" .. tostring(kind) .. "): " .. tostring(err))
    return nil
  end
  return res
end

function FHUD_con_destroy()
  if FHUD.conarea then kill_area(FHUD.conarea); FHUD.conarea = nil end
  FHUD.con_label = nil
  FHUD.con_hover = nil
  FHUD.con_sig = nil
end

-- Where the consumable popover goes. G.shop_jokers is never cleared when the shop
-- closes (it lingers as a removed, off-screen area), so only use it while IN the shop;
-- otherwise sit above the hand.
local function con_anchor()
  if G.STATE == G.STATES.SHOP and G.shop and G.shop_jokers then return G.shop_jokers end
  return G.hand or G.shop_jokers
end

-- What a consumable preview depends on besides the RNG: held cards, jokers (+ editions,
-- slots), highlights, state. A change re-runs the preview while it is still hovered.
local function con_state_sig()
  local t = { tostring(G.STATE), tostring(G.GAME and G.GAME.ecto_minus),
    tostring(G.GAME and G.GAME.round_resets and G.GAME.round_resets.ante) } -- v0.7.1: ante-keyed streams
  local pr, s = G.GAME and G.GAME.pseudorandom, 0
  for _, v in pairs(pr or {}) do if type(v) == 'number' then s = s + v end end
  t[#t + 1] = string.format("%.12f", s)
  local sig_areas = { G.hand, G.jokers }
  for ai = 1, 2 do
    local area = sig_areas[ai]
    if area and area.cards then
      t[#t + 1] = #area.cards .. "/" .. tostring(area.config and area.config.card_limit)
      for _, c in ipairs(area.cards) do
        t[#t + 1] = tostring(c.sort_id) .. (c.edition and tostring(c.edition.type) or "")
            .. (c.highlighted and "h" or "")
      end
    end
  end
  return table.concat(t, ",")
end

local function FHUD_con_show(card, kind)
  FHUD_con_destroy()
  local copies, label
  local scale = 0.7
  if SPECTRAL_2B[kind] then
    local r = FHUD_peek_spectral(card, kind, true)
    if r then copies, label, scale = r.copies, r.label, r.scale or 0.7 end
  elseif kind == 'wheel' then
    local r = FHUD_peek_wheel(card)
    if r then
      if r.hit then
        if r.no_jokers then
          label = "WHEEL: HIT (" .. (r.prob or "1 in 4") .. ") - no eligible joker"
        else
          label = "WHEEL: HIT -> " .. (r.edition_str or "Edition") ..
              (r.target_name and (" on " .. r.target_name) or "")
        end
        if r.target_copy then copies = { r.target_copy } end
      else
        label = "WHEEL: MISS (" .. (r.prob or "1 in 4") .. ")"
      end
    end
  elseif kind == 'emperor' or kind == 'priestess' then
    copies = FHUD_peek_consumable_create(card) or {}
    label = (kind == 'emperor') and "EMPEROR creates:" or "HIGH PRIESTESS creates:"
  elseif kind == 'judgement' or kind == 'soul' or kind == 'wraith' then
    copies, label = FHUD_peek_joker_create(kind)
  elseif kind == 'fool' then
    copies, label = FHUD_peek_fool()
  elseif kind == 'aura' then
    copies, label = FHUD_peek_aura()
  end
  FHUD.con_label = label
  if copies and #copies > 0 then
    FHUD.conarea = FHUD.ui.popover_area(copies, con_anchor(), scale, 0.8)
  end
end

-- Returns true when a consumable preview is active (suppress reroll preview).
function FHUD_special_tick()
  if not predict_ok() then
    if FHUD.conarea or FHUD.con_label then FHUD_con_destroy() end
    FHUD.lucky_label = nil
    return false
  end
  local special, kind
  -- Fixed indices, NOT ipairs: G.pack_cards / G.shop_jokers are nil most of the time
  -- and ipairs stops at the first nil, which silently skipped G.consumeables (< v0.4.0).
  local areas = { G.shop_jokers, G.pack_cards, G.consumeables }
  local tgt = G.CONTROLLER and G.CONTROLLER.hovering and G.CONTROLLER.hovering.target
  for ai = 1, 3 do
    local area = areas[ai]
    if special then break end
    if area and area.cards then
      for _, c in ipairs(area.cards) do
        if c == tgt or (c.states and c.states.hover and c.states.hover.is) then
          local ckey = c.config and c.config.center and c.config.center.key
          local d = ckey and SPECIAL_KINDS[ckey]
          if d and cfg(d.flag) then special = c; kind = d.kind; break end
        end
      end
    end
  end
  local now = (G.TIMERS and G.TIMERS.REAL) or 0
  local active = false
  if special then
    active = true
    FHUD.con_hold = now + 2.5
    -- FHUD_con_show starts with FHUD_con_destroy (which clears con_hover), so the cache
    -- keys are set AFTER it; before v0.4.0 that order rebuilt the preview every frame.
    local sig = con_state_sig()
    if FHUD.con_hover ~= special or FHUD.con_sig ~= sig then
      FHUD_con_show(special, kind)
      FHUD.con_hover = special
      FHUD.con_sig = sig
    end
  elseif (FHUD.conarea or FHUD.con_label) and FHUD.con_hold and now < FHUD.con_hold then
    active = true -- sticky
  else
    if FHUD.conarea or FHUD.con_label then FHUD_con_destroy() end
  end

  -- v0.6.0: the Lucky verdict is a hand tag on its card now (FHUD_peek_hand_tags).
  FHUD.lucky_label = nil

  return active
end

------------------------------------------- Wave 2c: passive joker generators
-- Recipes follow the RUNTIME code (lovely dump card.lua + Steamodded), see JOURNAL:
--   8 Ball     card.lua 3498: individual context, cardarea G.play, per TRIGGER of a scored
--              8: room check -> SMODS.pseudorandom_probability('8ball', 1, 4) -> buffer+1;
--              the create event runs create_card('Tarot', G.consumeables, ..., '8ba').
--   Vagabond   card.lua 4129: joker_main, room check, G.GAME.dollars <= 4, 'vag'.
--   Riff-raff  card.lua 2915: setting_blind, min(2, limit - (#jokers + joker_buffer))
--              x create_card('Joker', G.jokers, nil, 0, ..., 'rif').
--   Cartomancer card.lua 2932: setting_blind, room check, 'car'.
--   Certificate card.lua 2845: first_hand_drawn, front pseudorandom_element(G.P_CARDS,
--              pseudoseed('cert_fr')), then SMODS.poll_seal{type_key='certsl', guaranteed}.
-- Every generator runs in joker-row order and Blueprint/Brainstorm copies count as
-- extra copies at the copier's position (resolve_joker).

local GEN_KEYS = { j_8_ball = true, j_vagabond = true, j_riff_raff = true,
                   j_cartomancer = true, j_certificate = true }

local function any_modded_joker()
  for _, j in ipairs((G.jokers and G.jokers.cards) or {}) do
    local c = j.config and j.config.center
    if c and c.mod then return true end
  end
  return false
end

local function count_word(n, one, many) return n .. " " .. (n == 1 and one or many) end

-- Shared scoring model (Wave 2c; v0.6.0 shared with the Wave 3 Glass / Lucky tags).
-- What playing `played` (in play order) scores, mirroring G.FUNCS.evaluate_play (dump
-- state_events.lua 616-640): engine get_poker_hand_info, always_scores / Splash -
-- never_scores, blind:debuff_hand(check=true) kills the whole hand (its `triggered`
-- flag is put back). Call it inside a snapshot.
local function scoring_plan(played)
  local plan = { played = played, final = {}, dead = false }
  plan.last_hand = ((G.GAME.current_round and G.GAME.current_round.hands_left) or 1) - 1 == 0
  if #played == 0 then return plan end
  local _, scoring
  plan.text, _, plan.poker_hands, scoring = G.FUNCS.get_poker_hand_info(played)
  local splash = next(find_joker('Splash'))
  for _, c in ipairs(played) do
    local sp = (SMODS.always_scores and SMODS.always_scores(c)) or splash
    local un = SMODS.never_scores and SMODS.never_scores(c)
    if not sp then for _, sc in pairs(scoring or {}) do if sc == c then sp = true end end end
    if sp and not un then plan.final[#plan.final + 1] = c end
  end
  local bl = G.GAME.blind
  if bl and bl.debuff_hand then
    local trig = bl.triggered
    plan.dead = bl:debuff_hand(played, plan.poker_hands, plan.text, true) and true or false
    bl.triggered = trig
  end
  return plan
end

-- How many times a scored card triggers: 1 + Red seal (card.lua 2612) + Sock and Buskin
-- (face) + Hanging Chad (first scored) + Dusk (last hand) + Seltzer + Hack (rank 2-5)
-- (card.lua 3738-3770), Blueprint/Brainstorm copies included. A scoring card always
-- "calculates" (its chips), so every repetition runs (SMODS.score_card).
-- v0.8.0: `view` = the card as scoring sees it after Vampire / Midas Mask (before_views).
local function card_triggers(c, plan, view)
  local v = view or c
  local reps = 1 + ((c.seal == 'Red') and 1 or 0)
  local id = v:get_id()
  for _, j in ipairs(G.jokers.cards) do
    local e = resolve_joker(j)
    local k = ckey(e)
    local ex = (e and e.ability and e.ability.extra) or 1
    if k == 'j_sock_and_buskin' and v:is_face() then reps = reps + ex
    elseif k == 'j_hanging_chad' and c == plan.final[1] then reps = reps + ex
    elseif k == 'j_dusk' and plan.last_hand then reps = reps + ex
    elseif k == 'j_selzer' then reps = reps + 1
    elseif k == 'j_hack' and (id == 2 or id == 3 or id == 4 or id == 5) then reps = reps + ex
    end
  end
  return reps
end

-- context.before rewrites, in joker order (dump card.lua 3840-3890; neither is copyable):
-- Vampire sets every scoring, non-debuffed, not yet vampired enhanced card to c_base and marks
-- it `vampired` (so a Stone card gets its rank back: Card:get_id), Midas Mask turns every
-- scoring face card into Gold. Both run before any card scores, so a scoring card is seen
-- AFTER them. Returns { [card] = view } for the cards that change; a view is a read-only
-- stand-in with the new center that the engine's own is_face / is_suit / get_id run on.
-- Shared by the 8 Ball, Glass / Lucky tags and the joker badges (v0.8.0).
local function before_views(plan)
  local views = {}
  if plan.dead or #plan.final == 0 then return views end
  for _, j in ipairs(G.jokers.cards) do
    local k = (not j.debuff) and ckey(j)
    if k == 'j_vampire' or k == 'j_midas_mask' then
      for _, c in ipairs(plan.final) do
        local v = views[c] or c
        local cen
        if k == 'j_vampire' then
          if v.config.center ~= G.P_CENTERS.c_base and not c.debuff and not v.vampired then cen = G.P_CENTERS.c_base end
        elseif v:is_face() then
          cen = G.P_CENTERS.m_gold
        end
        if cen then
          views[c] = setmetatable({ config = { center = cen, center_key = cen.key },
            ability = { set = cen.set, effect = cen.effect, name = cen.name },
            vampired = (k == 'j_vampire') or v.vampired or nil, fhud_view = true }, { __index = c })
        end
      end
    end
  end
  return views
end

-- Predict what playing the HIGHLIGHTED cards makes: 8 Ball rolls (per trigger) and
-- Vagabond. Superposition / Seance are simulated too (they share the consumable room
-- and Superposition's Tarot is pool-culled before Vagabond's) but not displayed.
-- Mirrors G.FUNCS.evaluate_play (dump state_events.lua 616-750) + SMODS.score_card
-- (smods utils.lua 2229): scoring hand = engine get_poker_hand_info + always_scores /
-- Splash - never_scores, in played order (= hand order, left to right); a debuffed
-- card and a debuffed hand (blind:debuff_hand) score nothing; per scored card the
-- triggers are 1 + Red seal + Sock and Buskin (face) + Hanging Chad (first scored)
-- + Dusk (last hand) + Seltzer (+ Hack, never an 8), copiers included.
-- v0.8.0: `all` = run even without an 8 Ball / Vagabond (the joker badges use the same chain for
-- Superposition / Seance / Sixth Sense, which share the consumable room and the pool culling).
function FHUD_peek_hand_gen(build, all)
  if not predict_ok() then return nil end
  if not (G.GAME and G.jokers and G.jokers.cards and G.consumeables and G.hand and G.hand.cards) then return nil end
  local want8 = cfg('eightball')
  local wantv = cfg('vagabond')
  local has8, hasv = false, false
  for _, j in ipairs(G.jokers.cards) do
    local k = ckey(resolve_joker(j))
    if k == 'j_8_ball' then has8 = true elseif k == 'j_vagabond' then hasv = true end
  end
  if not ((has8 and want8) or (hasv and wantv) or all) then return nil end

  -- played cards in play order (G.hand.cards is kept sorted by x, = T.x order at rest)
  local played = {}
  for _, c in ipairs(G.hand.cards) do if c.highlighted then played[#played + 1] = c end end

  local res = { copies = {}, rolls = {}, creates = {}, n8 = 0, n8_sel = 0, played = #played }
  local snap = snapshot_rng()
  local ok, err = pcall(function()
    local cons = #G.consumeables.cards
    local limit = G.consumeables.config.card_limit
    local buf = G.GAME.consumeable_buffer or 0
    local plan = scoring_plan(played)
    local text, poker_hands, final = plan.text, plan.poker_hands, plan.final
    local hand_dead = plan.dead
    if #played > 0 then
      for _, c in ipairs(played) do
        if c:get_id() == 8 then res.n8_sel = res.n8_sel + 1 end
      end
      res.hand_dead = hand_dead
    end

    -- per-card scoring (8 Ball)
    if #played > 0 and not hand_dead and has8 then
      local views = before_views(plan)
      for _, c in ipairs(final) do
        local v = views[c] or c
        if not c.debuff and v:get_id() == 8 then
          res.n8 = res.n8 + 1
          local reps = card_triggers(c, plan, v) -- (Hack never applies to an 8)
          for _ = 1, reps do
            for _, j in ipairs(G.jokers.cards) do
              local e = resolve_joker(j)
              if ckey(e) == 'j_8_ball' then
                if cons + buf < limit then
                  local n, d = prob_vars(e, (e.ability and e.ability.extra) or 4, '8ball')
                  local hit = pseudorandom('8ball') < n / d
                  res.rolls[#res.rolls + 1] = { hit = hit, card = c, joker = j }
                  if hit then
                    buf = buf + 1
                    res.creates[#res.creates + 1] = { set = 'Tarot', app = '8ba', who = '8ball', roll = #res.rolls, joker = j }
                  end
                else
                  res.rolls[#res.rolls + 1] = { full = true, card = c, joker = j }
                end
              end
            end
          end
        end
      end
    end
    res.pr8 = G.GAME.pseudorandom['8ball']

    -- joker_main pass (Vagabond / Superposition / Seance), joker order
    if not hand_dead then
      local dollars = G.GAME.dollars or 0
      local bl = G.GAME.blind
      -- The Ox zeroes your money instantly inside debuff_hand when the most-played hand
      -- is played (dump blind.lua 605-611), i.e. before Vagabond looks at it.
      if text and bl and not bl.disabled and bl.name == 'The Ox'
          and text == (G.GAME.current_round and G.GAME.current_round.most_played_poker_hand) then
        dollars = 0
      end
      res.dollars = dollars
      if bl and bl.name == 'The Tooth' and not bl.disabled then res.tooth = true end
      local aces = 0
      for _, c in ipairs(final) do if c:get_id() == 14 then aces = aces + 1 end end
      for _, j in ipairs(G.jokers.cards) do
        local e = resolve_joker(j)
        local k = ckey(e)
        if k == 'j_vagabond' then
          res.vag_n = (res.vag_n or 0) + 1
          res.vag_slots = res.vag_slots or {}
          res.vag_slots[#res.vag_slots + 1] = j
          if dollars <= ((e.ability and e.ability.extra) or 4) then
            res.vag_fires = true
            if cons + buf < limit then
              buf = buf + 1
              res.creates[#res.creates + 1] = { set = 'Tarot', app = 'vag', who = 'vag', joker = j }
            else
              res.vag_full = (res.vag_full or 0) + 1
              res.vag_full_slots = res.vag_full_slots or {}
              res.vag_full_slots[j] = true
            end
          end
        elseif k == 'j_superposition' then
          -- (card.lua 4148: room first, then an Ace in the scoring hand and a Straight)
          if #played == 0 then res.unknown_other = true
          elseif aces >= 1 and poker_hands and next(poker_hands["Straight"] or {}) then
            if cons + buf < limit then
              buf = buf + 1
              res.creates[#res.creates + 1] = { set = 'Tarot', app = 'sup', who = 'sup', joker = j }
            else
              res.makers_full = res.makers_full or {}
              res.makers_full[#res.makers_full + 1] = j
            end
          end
        elseif k == 'j_seance' then
          local ph = e.ability and e.ability.extra and e.ability.extra.poker_hand
          if #played == 0 then res.unknown_other = true
          elseif ph and poker_hands and next(poker_hands[ph] or {}) then
            if cons + buf < limit then
              buf = buf + 1
              res.creates[#res.creates + 1] = { set = 'Spectral', app = 'sea', who = 'sea', joker = j }
            else
              res.makers_full = res.makers_full or {}
              res.makers_full[#res.makers_full + 1] = j
            end
          end
        end
      end
      -- v0.8.0: the destroy phase (SMODS.calculate_destroying_cards, after joker_main): Sixth Sense
      -- (card.lua 3001, not copyable) on a lone 6 on the round's first hand makes a Spectral
      -- ('sixth') if there is room; the first one marks the card sixth_sense, so only it fires.
      if #played == 1 and (G.GAME.current_round.hands_played or 0) == 0 and not played[1].sixth_sense then
        local v = before_views(plan)[played[1]] or played[1]
        if v:get_id() == 6 then
          for _, j in ipairs(G.jokers.cards) do
            if not j.debuff and ckey(j) == 'j_sixth_sense' then
              if cons + buf < limit then
                buf = buf + 1
                res.creates[#res.creates + 1] = { set = 'Spectral', app = 'sixth', who = 'sixth', joker = j }
              else
                res.makers_full = res.makers_full or {}
                res.makers_full[#res.makers_full + 1] = j
              end
              break
            end
          end
        end
      end
    end

    -- the create events, in queue order (8 Ball during scoring, then joker_main, then Sixth Sense);
    -- each one is pool-culled by the ones before it, so all stay alive until the end
    local made = {}
    -- v0.8.0: events muted -- a consumable's start_materialize queues a whoosh sound and dissolve
    -- events on the dry-run card (before, every rebuild of this preview played that sound)
    local okc, errc = dry_env(function()
      for _, cr in ipairs(res.creates) do
        local c = create_card(cr.set, G.consumeables, nil, nil, nil, nil, nil, cr.app)
        made[#made + 1] = c
        cr.key = ckey(c)
        cr.name = center_name(cr.key)
      end
    end)
    if not okc then
      for _, c in ipairs(made) do if c and c.remove then c:remove() end end
      error(errc, 0)
    end
    if build then
      for i, cr in ipairs(res.creates) do
        if (cr.who == '8ball' and want8) or (cr.who == 'vag' and wantv) then
          local cp = made[i] and make_display_copy(made[i], 0.55)
          if cp then res.copies[#res.copies + 1] = cp end
        end
      end
    end
    for _, c in ipairs(made) do if c and c.remove then c:remove() end end
  end)
  restore_rng(snap)
  if not ok then
    free_cards(res.copies)
    print("[ForesightHUD] hand-generator preview failed: " .. tostring(err))
    return nil
  end

  -- labels
  local lines = {}
  if has8 and want8 and #played > 0 and res.n8_sel > 0 then
    if res.hand_dead then
      lines[#lines + 1] = "8 BALL: this hand won't score (blind)"
    elseif res.n8 == 0 then
      lines[#lines + 1] = "8 BALL: no scoring 8 in this hand"
    else
      local parts, i, nroll = {}, 1, 0
      local name_of = {}
      for _, cr in ipairs(res.creates) do if cr.roll then name_of[cr.roll] = cr.name end end
      while i <= #res.rolls do
        local r = res.rolls[i]
        if r.full then
          local n = 0
          while res.rolls[i] and res.rolls[i].full do n = n + 1; i = i + 1 end
          parts[#parts + 1] = (n > 1) and ("no room x" .. n) or "no room"
        else
          nroll = nroll + 1
          parts[#parts + 1] = r.hit and ("HIT (" .. tostring(name_of[i]) .. ")") or "MISS"
          i = i + 1
        end
      end
      local head = "8 BALL: " .. count_word(res.n8, "eight", "eights")
      if #res.rolls ~= res.n8 then head = head .. ", " .. count_word(#res.rolls, "trigger", "triggers") end
      if #parts > 8 then
        -- long retrigger chains: name the hits by trigger number, count the rest
        local hp, nm, nf = {}, 0, 0
        for ri, r in ipairs(res.rolls) do
          if r.full then nf = nf + 1
          elseif r.hit then hp[#hp + 1] = "#" .. ri .. " HIT (" .. tostring(name_of[ri]) .. ")"
          else nm = nm + 1 end
        end
        parts = hp
        if nm > 0 then parts[#parts + 1] = nm .. " MISS" end
        if nf > 0 then parts[#parts + 1] = nf .. " no room" end
      end
      lines[#lines + 1] = head .. " -> " .. table.concat(parts, ", ")
    end
  end
  if hasv and wantv and res.vag_fires then
    local names = {}
    for _, cr in ipairs(res.creates) do if cr.who == 'vag' then names[#names + 1] = "+" .. cr.name end end
    for _ = 1, (res.vag_full or 0) do names[#names + 1] = "no room" end
    local s = "VAGABOND ($" .. tostring(res.dollars) .. "): "
    if #played == 0 then s = s .. "next hand -> " end
    s = s .. table.concat(names, ", ")
    if #played == 0 and (has8 or res.unknown_other) then s = s .. " (select cards to confirm)" end
    if res.tooth then s = s .. " (The Tooth takes $1/card first)" end
    lines[#lines + 1] = s
  end
  if #lines > 0 and any_modded_joker() then lines[#lines] = lines[#lines] .. " - modded jokers not modelled" end
  res.lines = lines
  return res
end

-- The setting_blind pass (dump state_events.lua 283: every joker in row order), as far as it
-- decides who gets sliced and how much room is left: Ceremonial Dagger slices its right
-- neighbour and frees a slot (joker_buffer - 1, card.lua 2880-2910), Madness (not on a Boss,
-- not copyable: card.lua 2885) slices a random non-eternal, not already sliced joker
-- ('madness'), a sliced joker no longer calculates (Card:can_calculate), Riff-raff /
-- Cartomancer take room. MUST run inside a snapshot (rolls 'madness'). Shared by the Wave 2c
-- generators and the v0.8.0 Madness badge.
local function setting_blind_sim(is_boss)
  local list = G.jokers.cards
  local jlimit = G.jokers.config.card_limit
  local climit = G.consumeables.config.card_limit
  local jbuf = G.GAME.joker_buffer or 0
  local cbuf = G.GAME.consumeable_buffer or 0
  -- riff_slots / cart_slots: the slot (the joker itself or its copier) behind each entry, in
  -- order; *_full_slots: the slots that hit a full row (v0.8.1 badges)
  local sim = { sliced = {}, nriff = {}, ncart = 0, riff_full = 0, cart_full = 0, madness = {},
                riff_slots = {}, cart_slots = {}, full_slots = {} }
  local sliced = sim.sliced
  for pos, j in ipairs(list) do
    if not j.debuff and not sliced[j] and not j.getting_sliced then
      local e = resolve_joker(j)
      local k = ckey(e)
      if e and not sliced[e] and not e.getting_sliced then
        if k == 'j_ceremonial' and e == j then
          local nb = list[pos + 1]
          if nb and not is_eternal(nb, j) and not sliced[nb] and not nb.getting_sliced then
            sliced[nb] = true
            jbuf = jbuf - 1
          end
        elseif k == 'j_madness' and e == j and not is_boss then
          local pool = {}
          for _, v in ipairs(list) do
            if v ~= j and not is_eternal(v, j) and not sliced[v] and not v.getting_sliced then pool[#pool + 1] = v end
          end
          local victim = (#pool > 0) and pseudorandom_element(pool, pseudoseed('madness')) or nil
          if victim then sliced[victim] = true; sim.madness_victim = victim end
          sim.madness[#sim.madness + 1] = { joker = j, victim = victim }
        elseif k == 'j_riff_raff' then
          if #list + jbuf < jlimit then
            local n = math.min(2, jlimit - (#list + jbuf))
            jbuf = jbuf + n
            sim.nriff[#sim.nriff + 1] = n
            sim.riff_slots[#sim.riff_slots + 1] = j
          else
            sim.riff_full = sim.riff_full + 1
            sim.full_slots[j] = true
          end
        elseif k == 'j_cartomancer' then
          if #G.consumeables.cards + cbuf < climit then
            cbuf = cbuf + 1
            sim.ncart = sim.ncart + 1
            sim.cart_slots[#sim.cart_slots + 1] = j
          else
            sim.cart_full = sim.cart_full + 1
            sim.full_slots[j] = true
          end
        end
      end
    end
  end
  return sim
end

-- The blind on deck is a Boss (Madness skips bosses; context.blind = the blind being set).
local function on_deck_is_boss()
  local is_boss = false
  pcall(function()
    local ch = G.GAME.round_resets.blind_choices[G.GAME.blind_on_deck]
    is_boss = (G.P_BLINDS[ch] and G.P_BLINDS[ch].boss) and true or false
    if G.GAME.blind_on_deck == 'Boss' then is_boss = true end
  end)
  return is_boss
end

-- Predict what selecting the on-deck blind makes: Riff-raff jokers, Cartomancer
-- Tarots (setting_blind, dump state_events.lua 283) and Certificate cards (first hand
-- drawn). Ceremonial Dagger / Madness slice jokers earlier in the same pass
-- (card.lua 2880-2910, 2946-2960) -- a sliced joker no longer calculates, and Dagger's
-- slice frees a joker slot (joker_buffer - 1) -- so those are simulated in order too.
function FHUD_peek_blind_gen(build)
  if not predict_ok() then return nil end
  if not (G.GAME and G.jokers and G.jokers.cards and G.consumeables) then return nil end
  local want = { riff = cfg('riffraff'), cart = cfg('cartomancer'), cert = cfg('certificate') }
  local present = {}
  for _, j in ipairs(G.jokers.cards) do
    local k = ckey(resolve_joker(j))
    if k == 'j_riff_raff' then present.riff = true
    elseif k == 'j_cartomancer' then present.cart = true
    elseif k == 'j_certificate' then present.cert = true end
  end
  if not ((present.riff and want.riff) or (present.cart and want.cart) or (present.cert and want.cert)) then
    return nil
  end
  -- context.blind = the on-deck blind; Madness skips bosses. Amber Acorn (set_blind,
  -- before setting_blind) queues a joker shuffle that lands before the first draw, which
  -- can change what a Blueprint/Brainstorm copies for Certificate.
  local is_boss, acorn = false, false
  pcall(function()
    local ch = G.GAME.round_resets.blind_choices[G.GAME.blind_on_deck]
    is_boss = (G.P_BLINDS[ch] and G.P_BLINDS[ch].boss) and true or false
    if G.GAME.blind_on_deck == 'Boss' then is_boss = true end
    acorn = (ch == 'bl_final_acorn')
  end)

  local res = { copies = {}, riff = {}, cart = {}, cert = {}, riff_full = 0, cart_full = 0 }
  local snap = snapshot_rng()
  local ok, err = pcall(function()
    local list = G.jokers.cards
    local sim = setting_blind_sim(is_boss)
    local sliced, nriff, ncart = sim.sliced, sim.nriff, sim.ncart
    res.riff_full, res.cart_full, res.madness_victim = sim.riff_full, sim.cart_full, sim.madness_victim
    res.sliced = sliced
    res.full_slots = sim.full_slots
    -- create events (Riff-raff: one event per joker, creates its n in a loop;
    -- Cartomancer: nested event). Different pools, so their interleave is irrelevant.
    local made = {}
    -- v0.8.0: events muted (edition sounds, the Tarots' materialize sound / dissolve events)
    local okc, errc = dry_env(function()
      for ri, n in ipairs(nriff) do
        for _ = 1, n do
          local c = create_card('Joker', G.jokers, nil, 0, nil, nil, nil, 'rif')
          made[#made + 1] = c
          res.riff[#res.riff + 1] = { card = c, key = ckey(c), joker = sim.riff_slots[ri],
            edition = c and c.edition and (c.edition.type or ed_name(c.edition)) or nil,
            edkey = c and c.edition and (c.edition.key or (c.edition.type and ('e_' .. c.edition.type))) or nil }
        end
      end
      for ci = 1, ncart do
        local c = create_card('Tarot', G.consumeables, nil, nil, nil, nil, nil, 'car')
        made[#made + 1] = c
        res.cart[#res.cart + 1] = { card = c, key = ckey(c), joker = sim.cart_slots[ci] }
      end
    end)
    if not okc then
      for _, c in ipairs(made) do if c and c.remove then c:remove() end end
      error(errc, 0)
    end
    -- first_hand_drawn: sliced jokers are gone by then; resolve copiers on what's left
    local alive = {}
    for _, j in ipairs(list) do if not sliced[j] then alive[#alive + 1] = j end end
    for _, j in ipairs(alive) do
      local e = resolve_joker(j, alive)
      if ckey(e) == 'j_certificate' then
        local front, fkey = pseudorandom_element(G.P_CARDS, pseudoseed('cert_fr'))
        local seal = SMODS.poll_seal({ type_key = 'certsl', guaranteed = true })
        res.cert[#res.cert + 1] = { front = front, front_key = fkey, seal = seal, joker = j }
        if acorn and #alive > 1 then res.cert_uncertain = true end
      end
    end
    res.pr = { madness = G.GAME.pseudorandom['madness'], cert_fr = G.GAME.pseudorandom['cert_fr'],
               certsl = G.GAME.pseudorandom['certsl'] }
    if build then
      for _, r in ipairs(res.riff) do
        if want.riff then
          local cp = r.card and copy_with_edition(r.card, 0.45)
          if cp then res.copies[#res.copies + 1] = cp end
        end
      end
      for _, r in ipairs(res.cart) do
        if want.cart then
          local cp = r.card and make_display_copy(r.card, 0.45)
          if cp then res.copies[#res.copies + 1] = cp end
        end
      end
      for _, r in ipairs(res.cert) do
        if want.cert and r.front then
          local cp = new_card_copy(r.front, G.P_CENTERS.c_base, 0.45)
          if cp and r.seal then pcall(function() cp:set_seal(r.seal, true, true) end) end
          if cp then res.copies[#res.copies + 1] = cp end
        end
      end
    end
    for _, c in ipairs(made) do if c and c.remove then c:remove() end end
    for _, r in ipairs(res.riff) do r.card = nil end
    for _, r in ipairs(res.cart) do r.card = nil end
  end)
  restore_rng(snap)
  if not ok then
    free_cards(res.copies)
    print("[ForesightHUD] blind-generator preview failed: " .. tostring(err))
    return nil
  end

  local lines = {}
  if present.riff and want.riff then
    local parts = {}
    for _, r in ipairs(res.riff) do
      local ed = r.edition and (" (" .. ed_name(r.edition) .. ")") or ""
      parts[#parts + 1] = "+" .. center_name(r.key) .. ed
    end
    if #parts == 0 then parts[1] = (res.riff_full > 0) and "no joker room" or "nothing" end
    lines[#lines + 1] = "RIFF-RAFF: " .. table.concat(parts, ", ")
  end
  if present.cart and want.cart then
    local parts = {}
    for _, r in ipairs(res.cart) do parts[#parts + 1] = "+" .. center_name(r.key) end
    for _ = 1, res.cart_full do parts[#parts + 1] = "no room" end
    if #parts == 0 then parts[1] = "nothing" end
    lines[#lines + 1] = "CARTOMANCER: " .. table.concat(parts, ", ")
  end
  if present.cert and want.cert then
    local parts = {}
    for _, r in ipairs(res.cert) do
      local nm = r.front and r.front.value and r.front.suit
          and (loc_or(r.front.value, 'ranks') .. " of " .. loc_or(r.front.suit, 'suits_plural')) or tostring(r.front_key)
      local sl = r.seal and (loc_or(r.seal:lower() .. "_seal", 'labels', r.seal .. " Seal")) or nil
      parts[#parts + 1] = nm .. (sl and (", " .. sl) or "")
    end
    if #parts == 0 then parts[1] = "sliced before the draw" end
    lines[#lines + 1] = "CERTIFICATE: " .. table.concat(parts, "; ")
        .. (res.cert_uncertain and " (Amber Acorn may reorder)" or "")
  end
  if #lines > 0 and any_modded_joker() then lines[#lines] = lines[#lines] .. " - modded jokers not modelled" end
  res.lines = lines
  return res
end

function FHUD_gen_destroy()
  for _, a in ipairs(FHUD.genareas or {}) do if a ~= FHUD.genarea then kill_area(a) end end
  FHUD.genareas = nil
  if FHUD.genarea then kill_area(FHUD.genarea); FHUD.genarea = nil end
  FHUD.gen_lines = nil
  FHUD.gen_sig = nil
  FHUD.gen_top = nil
end

local function gen_sig(mode)
  local t = { mode }
  local pr, s = G.GAME.pseudorandom, 0
  for _, v in pairs(pr or {}) do if type(v) == 'number' then s = s + v end end
  t[#t + 1] = string.format("%.12f", s)
  local cr = G.GAME.current_round
  local bl = G.GAME.blind
  t[#t + 1] = table.concat({ tostring(G.GAME.round_resets and G.GAME.round_resets.ante), -- v0.7.1
    tostring(G.GAME.dollars), tostring(G.GAME.consumeable_buffer),
    tostring(G.GAME.joker_buffer), tostring(cr and cr.hands_left), tostring(G.GAME.blind_on_deck),
    tostring(bl and bl.name), tostring(bl and bl.disabled),
    tostring(G.GAME.probabilities and G.GAME.probabilities.normal),
    tostring(cr and cr.most_played_poker_hand) }, "/")
  local areas = { G.jokers, G.consumeables, (mode == 'hand') and G.hand or nil }
  for ai = 1, 3 do
    local a = areas[ai]
    if a and a.cards then
      t[#t + 1] = #a.cards .. "/" .. tostring(a.config and a.config.card_limit)
      for _, c in ipairs(a.cards) do
        t[#t + 1] = tostring(c.sort_id) .. tostring(ckey(c)) .. (c.debuff and "d" or "")
            .. ((c.ability and c.ability.eternal) and "e" or "")
            .. ((ai == 3) and (tostring(c.base and c.base.id) .. tostring(c.seal) .. (c.highlighted and "h" or "")) or "")
      end
    end
  end
  return table.concat(t, ",")
end

local function gen_show(mode)
  local r
  if mode == 'hand' then r = FHUD_peek_hand_gen(true) else r = FHUD_peek_blind_gen(true) end
  if not r then return end
  if r.lines and #r.lines > 0 then FHUD.gen_lines = r.lines end
  FHUD.gen_top = (mode == 'blind')
  if r.copies and #r.copies > 0 then
    if mode == 'hand' then
      FHUD.genarea = FHUD.ui.popover_area(r.copies, con_anchor(), 0.55, 0.8)
    else
      -- Blind select: the blind panels cover the whole centre from just under the
      -- joker row down (measured x 4.4-17.6, y 3.4+ in a 20x11.5 room), so the cards go
      -- in the free column right of the panels, between the consumable slots and the
      -- deck, as stacked rows of 2 small cards.
      local per, scale = 2, 0.45
      local cw = scale * G.CARD_W
      local right = (G.blind_select and G.blind_select.T and (G.blind_select.T.x + G.blind_select.T.w)) or (G.ROOM.T.w - 2.4)
      local cx = (right + G.ROOM.T.w) / 2
      local y0 = (G.consumeables and G.consumeables.T and (G.consumeables.T.y + G.consumeables.T.h + 0.15)) or 2.75
      local rowh = scale * G.CARD_H + 0.12
      local areas, i = {}, 1
      while i <= #r.copies do
        local chunk = {}
        for k = i, math.min(i + per - 1, #r.copies) do chunk[#chunk + 1] = r.copies[k] end
        local a = new_area(#chunk, cw)
        a.T.h = rowh
        for _, cp in ipairs(chunk) do disable_input(cp); a:emplace(cp) end
        a.T.x = cx - a.T.w / 2
        a.T.y = y0 + #areas * rowh
        if a.align_cards then a:align_cards() end
        areas[#areas + 1] = a
        i = i + per
      end
      FHUD.genarea = areas[1]
      FHUD.genareas = areas
    end
  end
end

-- Builds/caches the generator previews for the current state. A consumable preview
-- owns the same spot above the hand, so it wins while it is shown.
function FHUD_gen_tick(special_active)
  local st = G.STATE
  -- v0.8.1: every generator moved to joker badges (FHUD_peek_joker_badges), card on hover
  -- (FHUD_badge_hover_tick): the old centre card + banner covered the hand / board. This now
  -- only tears down; gen_show is kept for the validation harnesses.
  local mode = nil
  if (not mode) or special_active or not predict_ok() then
    if FHUD.genarea or FHUD.gen_lines or FHUD.gen_sig then FHUD_gen_destroy() end
    return
  end
  local any = false
  for _, j in ipairs((G.jokers and G.jokers.cards) or {}) do
    if GEN_KEYS[ckey(j)] then any = true; break end
  end
  if not any then
    if FHUD.genarea or FHUD.gen_lines or FHUD.gen_sig then FHUD_gen_destroy() end
    return
  end
  local sig = gen_sig(mode)
  if sig ~= FHUD.gen_sig then
    FHUD_gen_destroy()
    gen_show(mode)
    FHUD.gen_sig = sig
  end
end

------------------------------------------------- Wave 3: hand tags (Pattern 2)
-- Short text tags pinned under the cards in your hand (drawn by FHUD.ui.hand_tag):
--   Glass       selected hand: BREAK / safe for each selected Glass card.
--   Lucky       selected hand: each scoring Lucky card's own rolls; nothing selected:
--               the next rolls on the hovered Lucky card (the old banner, moved here).
--   Purple seal selected cards, IF DISCARDED: the Tarot each one makes, or no room.
--   Blue seal   held cards: the Planet for the round's final hand (or no room).
-- Recipes are the RUNTIME code (lovely dump + Steamodded 26.1002.0):
--   Glass  Steamodded owns m_glass (smods game_object.lua 3476): calculate rolls
--          SMODS.pseudorandom_probability(card, 'glass', 1, extra) when
--          context.destroy_card == card and cardarea == G.play. The destroy phase
--          (SMODS.calculate_destroying_cards, smods utils.lua 2347, called from
--          state_events.lua 826) walks G.play.cards in play order with one
--          calculate_context per card: jokers first (Sixth Sense votes there; it does
--          not stop the playing-card pass), then playing cards. Only SCORING cards get
--          cardarea G.play, eval_card skips a debuffed card (common_events.lua 595) and
--          there is no repetition pass: one roll per scoring, non-debuffed Glass card,
--          retriggers add none. The phase only runs when the blind does not debuff the
--          hand (state_events.lua 674/823). Vampire (strips enhancements) and Midas Mask
--          (faces -> Gold) act in context.before (card.lua 3840-3890): such a card is
--          no longer Glass (or Lucky) when it would roll.
--   Lucky  per trigger: Card:get_chip_mult 'lucky_mult' 1/5, then get_p_dollars
--          'lucky_money' 1/15 (card.lua 1209 / 1389); cards in scoring order, each card's
--          triggers back to back (SMODS.score_card), trigger count = card_triggers.
--   Purple G.FUNCS.discard_cards_from_highlighted (state_events.lua 391-453): the
--          highlighted cards sorted by x, up to the discard limit; per card
--          calculate_context({discard, other_card}) -> Card:calculate_seal (card.lua 2621):
--          room #consumeables + consumeable_buffer < limit, buffer + 1, then an event
--          create_card('Tarot', G.consumeables, ..., '8ba') -- 8 Ball's 'Tarot8ba'..ante
--          stream. A debuffed card does not calculate.
--   Blue   SMODS.calculate_end_of_round_effects (smods utils.lua 2301) over the HELD cards in
--          hand order -> Card:get_end_of_round_effect (card.lua 1348): room check, buffer + 1,
--          Planet for G.GAME.last_hand_played (forced key, no RNG). Retriggers (Red seal,
--          Mime, copiers) only run when the first evaluation did something
--          (j = j + (calculated and 1 or #reps)).
local TAG_COL = {
  bad = { 1, 0.38, 0.32, 1 }, good = { 0.5, 0.92, 0.5, 1 }, info = { 1, 0.95, 0.5, 1 },
  muted = { 0.72, 0.72, 0.72, 1 }, purple = { 0.82, 0.62, 1, 1 }, blue = { 0.55, 0.78, 1, 1 },
}

local function short_name(key)
  local n = center_name(key)
  return (n:gsub("^The ", ""))
end

local function lucky_sym(s)
  return (s.mult and s.money) and "M$" or s.mult and "M" or s.money and "$" or "-"
end
-- one Lucky card's rolls -> tag text
local function lucky_text(seq, more)
  if #seq == 1 and not more then
    local s = seq[1]
    if s.mult and s.money then return "+M +$", 'info' end
    if s.mult then return "+Mult", 'info' end
    if s.money then return "+$20", 'info' end
    return "nothing", 'muted'
  end
  local parts, any = {}, false
  for _, s in ipairs(seq) do parts[#parts + 1] = lucky_sym(s); if s.mult or s.money then any = true end end
  return table.concat(parts, " ") .. (more and " +?" or ""), any and 'info' or 'muted'
end

-- Which planet scores `hand` (Blue seal: forced key, card.lua 1356-1361).
local function planet_for(hand)
  local key
  for _, v in pairs(G.P_CENTER_POOLS.Planet or {}) do
    if v.config and v.config.hand_type == hand then key = v.key end
  end
  return key
end

-- Predict every tag for the current hand state. Returns
--   { tags = { {card=, text=, colour=}, ... }, glass = {...}, lucky = {...},
--     purple = {...}, blue = {...}, pr = {...} }   (the extra tables are for validation)
-- or nil when nothing applies.
function FHUD_peek_hand_tags()
  if not predict_ok() then return nil end
  if not (G.GAME and G.hand and G.hand.cards and G.jokers and G.jokers.cards and G.consumeables
      and G.GAME.current_round) then return nil end
  local want = { glass = cfg('glass'), lucky = cfg('lucky'), purple = cfg('purple_seal'), blue = cfg('blue_seal') }
  if not (want.glass or want.lucky or want.purple or want.blue) then return nil end
  -- played / discarded order: the highlighted cards left to right (the engine sorts by T.x)
  local hl = {}
  for _, c in ipairs(G.hand.cards) do if c.highlighted then hl[#hl + 1] = c end end
  local res = { tags = {}, glass = {}, lucky = {}, purple = {}, blue = {}, pr = {} }
  local function tag(card, text, colour) res.tags[#res.tags + 1] = { card = card, text = text, colour = colour } end

  local snap = snapshot_rng()
  local made = {}
  local ok, err = pcall(function()
    local plan = scoring_plan(hl)
    res.text, res.dead = plan.text, plan.dead
    local in_final = {}
    for _, c in ipairs(plan.final) do in_final[c] = true end
    -- context.before rewrites: Vampire / Midas Mask (shared before_views, v0.8.0): a card they
    -- change is no longer Glass / Lucky when it would roll
    local views = before_views(plan)
    local function rewritten(c) return views[c] ~= nil end
    local function effect(c) return c.ability and c.ability.effect end

    -- Glass: one roll per scoring Glass card, play order. Sixth Sense (card.lua 3000,
    -- destroying_card, not copyable) destroys a lone 6 on the round's first hand anyway;
    -- its vote comes first in the same calculate_context but doesn't skip the Glass roll.
    local sixth = false
    if #hl == 1 and hl[1]:get_id() == 6 and not hl[1].sixth_sense and not plan.dead and in_final[hl[1]]
        and (G.GAME.current_round.hands_played or 0) == 0 then
      for _, j in ipairs(G.jokers.cards) do
        if not j.debuff and ckey(j) == 'j_sixth_sense' then sixth = true end
      end
    end
    res.sixth = sixth
    if want.glass and #hl > 0 then
      for _, c in ipairs(hl) do
        if effect(c) == 'Glass Card' then
          if plan.dead or not in_final[c] or c.debuff or rewritten(c) then
            res.glass[#res.glass + 1] = { card = c, roll = false }
            tag(c, "safe", 'muted')
          else
            local n, d = prob_vars(c, (c.ability and c.ability.extra) or 4, 'glass')
            local hit = pseudorandom('glass') < n / d
            res.glass[#res.glass + 1] = { card = c, roll = true, hit = hit }
            if sixth then
              tag(c, hit and "BREAK" or "destroyed (Sixth Sense)", 'bad')
            else
              tag(c, hit and "BREAK" or "safe", hit and 'bad' or 'good')
            end
          end
        end
      end
      res.pr.glass = G.GAME.pseudorandom['glass']
    end

    -- Lucky
    if want.lucky then
      if #hl > 0 then
        local done = {}
        if not plan.dead then
          for _, c in ipairs(plan.final) do
            if effect(c) == 'Lucky Card' and not c.debuff and not rewritten(c) then
              local n1, d1 = prob_vars(c, 5, 'lucky_mult')
              local n2, d2 = prob_vars(c, 15, 'lucky_money')
              local seq = {}
              for _ = 1, card_triggers(c, plan, views[c]) do
                local m = pseudorandom('lucky_mult') < n1 / d1
                local d = pseudorandom('lucky_money') < n2 / d2
                seq[#seq + 1] = { mult = m, money = d }
              end
              done[c] = true
              res.lucky[#res.lucky + 1] = { card = c, seq = seq }
              local t, col = lucky_text(seq)
              tag(c, t, col)
            end
          end
        end
        for _, c in ipairs(hl) do
          if effect(c) == 'Lucky Card' and not done[c] then
            res.lucky[#res.lucky + 1] = { card = c, seq = {} }
            tag(c, "no roll", 'muted')
          end
        end
        res.pr.lucky_mult = G.GAME.pseudorandom['lucky_mult']
        res.pr.lucky_money = G.GAME.pseudorandom['lucky_money']
      else
        -- nothing selected: the hovered Lucky card's NEXT rolls (pre-v0.6.0 banner logic)
        local tgt = G.CONTROLLER and G.CONTROLLER.hovering and G.CONTROLLER.hovering.target
        local hov
        for _, c in ipairs(G.hand.cards) do
          if effect(c) == 'Lucky Card' and (c == tgt or (c.states and c.states.hover and c.states.hover.is)) then hov = c; break end
        end
        if hov and not hov.debuff then
          local known, more = 1 + ((hov.seal == 'Red') and 1 or 0), false
          local id, face = hov:get_id(), hov:is_face()
          for _, j in ipairs(G.jokers.cards) do
            local e = resolve_joker(j)
            local k = ckey(e)
            local ex = (e and e.ability and e.ability.extra) or 1
            if k == 'j_hack' and (id == 2 or id == 3 or id == 4 or id == 5) then known = known + ex
            elseif k == 'j_sock_and_buskin' and face then known = known + ex
            elseif k == 'j_selzer' then known = known + 1
            elseif k == 'j_dusk' or k == 'j_hanging_chad' then more = true end
          end
          local n1, d1 = prob_vars(hov, 5, 'lucky_mult')
          local n2, d2 = prob_vars(hov, 15, 'lucky_money')
          local seq = {}
          for _ = 1, math.min(known + (more and 2 or 0), 6) do
            local m = pseudorandom('lucky_mult') < n1 / d1
            local d = pseudorandom('lucky_money') < n2 / d2
            seq[#seq + 1] = { mult = m, money = d }
          end
          res.lucky[#res.lucky + 1] = { card = hov, seq = seq, hover = true }
          local t, col = lucky_text(seq, more)
          tag(hov, t, col)
        end
      end
    end

    -- Purple seal: if the selection is DISCARDED
    if want.purple and #hl > 0 and (G.GAME.current_round.discards_left or 0) > 0 then
      local lim = (G.discard and G.discard.config and G.discard.config.card_limit) or #hl
      local n = math.min(#hl, lim - ((G.play and #G.play.cards) or 0))
      local cons, climit = #G.consumeables.cards, G.consumeables.config.card_limit
      local buf = G.GAME.consumeable_buffer or 0
      local makes = {}
      for i = 1, n do
        local c = hl[i]
        if c.seal == 'Purple' then
          local e = { card = c }
          if c.debuff then e.debuffed = true
          elseif cons + buf < climit then buf = buf + 1; makes[#makes + 1] = e
          else e.full = true end
          res.purple[#res.purple + 1] = e
        end
      end
      local okc, errc = dry_env(function()
        for _, e in ipairs(makes) do
          local t = create_card('Tarot', G.consumeables, nil, nil, nil, nil, nil, '8ba')
          made[#made + 1] = t
          e.key = ckey(t)
        end
      end)
      if not okc then error(errc) end
      for _, e in ipairs(res.purple) do
        if e.key then tag(e.card, "disc: " .. short_name(e.key), 'purple')
        elseif e.full then tag(e.card, "disc: no room", 'muted')
        else tag(e.card, "disc: nothing", 'muted') end
      end
    end

    -- Blue seal: held at end of round
    if want.blue then
      local held = {}
      for _, c in ipairs(G.hand.cards) do if not c.highlighted then held[#held + 1] = c end end
      local any = false
      for _, c in ipairs(held) do if c.seal == 'Blue' then any = true; break end end
      if any then
        local hand, qual
        local cr = G.GAME.current_round
        if #hl > 0 then
          hand = plan.text
          qual = ((cr.hands_left or 0) <= 1) and "last hand" or "if wins"
        elseif (cr.hands_played or 0) > 0 and G.GAME.last_hand_played then
          hand = G.GAME.last_hand_played
          qual = "if final"
        end
        -- room left when the round ends: cards held now + Tarots/Spectrals the final hand makes
        local room = G.consumeables.config.card_limit - #G.consumeables.cards - (G.GAME.consumeable_buffer or 0)
        local unsure = false
        if #hl > 0 then
          local okg, hg = pcall(FHUD_peek_hand_gen, false)
          if okg and hg and hg.creates then room = room - #hg.creates end
          if not (okg and hg) then
            for _, j in ipairs(G.jokers.cards) do
              local k = ckey(resolve_joker(j))
              if k == 'j_8_ball' or k == 'j_vagabond' or k == 'j_superposition' or k == 'j_seance' then unsure = true end
            end
          end
        end
        local mimes = 0
        for _, j in ipairs(G.jokers.cards) do
          local e = resolve_joker(j)
          if ckey(e) == 'j_mime' then mimes = mimes + ((e.ability and e.ability.extra) or 1) end
        end
        local pkey = hand and planet_for(hand)
        res.blue_hand, res.blue_planet = hand, pkey
        for _, c in ipairs(held) do
          if c.seal == 'Blue' then
            local e = { card = c }
            if c.debuff then
              e.debuffed = true
              tag(c, "no planet", 'muted')
            elseif not pkey then
              e.unknown = true -- no hand known yet: the final hand decides
            else
              -- retriggers: Mime (+ copies). A Red seal would too, but a card has one seal.
              local reps = 1 + mimes
              local n = 0
              if room > 0 then
                n = math.min(reps, room)
                room = room - n
              end
              e.n = n
              if n == 0 then
                tag(c, "no room", 'muted')
              else
                tag(c, short_name(pkey) .. ((n > 1) and (" x" .. n) or ""), 'blue')
                tag(c, qual .. (unsure and " (room?)" or ""), 'muted')
              end
            end
            res.blue[#res.blue + 1] = e
          end
        end
      end
    end
  end)
  free_cards(made)
  restore_rng(snap)
  if not ok then
    if not FHUD.tag_err_logged then
      FHUD.tag_err_logged = true
      print("[ForesightHUD] hand-tag preview failed: " .. tostring(err))
    end
    return nil
  end
  return res
end

function FHUD_tag_destroy()
  FHUD.hand_tag_items = nil
  FHUD.tag_sig = nil
end

local function tag_sig()
  local g = G.GAME
  local cr = g.current_round or {}
  local pr, s = g.pseudorandom, 0
  for _, v in pairs(pr or {}) do if type(v) == 'number' then s = s + v end end
  local bl = g.blind
  local t = { tostring(G.STATE), string.format("%.12f", s), tostring(g.consumeable_buffer),
    tostring(g.round_resets and g.round_resets.ante), -- v0.7.1
    tostring(cr.hands_left), tostring(cr.discards_left), tostring(cr.hands_played), tostring(g.last_hand_played),
    tostring(bl and bl.name), tostring(bl and bl.disabled), tostring(g.probabilities and g.probabilities.normal),
    tostring(G.play and #G.play.cards), tostring(G.discard and G.discard.config and G.discard.config.card_limit),
    tostring(cfg('glass')) .. tostring(cfg('lucky')) .. tostring(cfg('purple_seal')) .. tostring(cfg('blue_seal')) }
  local areas = { G.jokers, G.consumeables, G.hand }
  for ai = 1, 3 do
    local a = areas[ai]
    if a and a.cards then
      t[#t + 1] = #a.cards .. "/" .. tostring(a.config and a.config.card_limit)
      for _, c in ipairs(a.cards) do
        t[#t + 1] = tostring(c.sort_id) .. tostring(ckey(c)) .. (c.debuff and "d" or "")
            .. ((ai == 3) and (tostring(c.base and c.base.id) .. tostring(c.base and c.base.suit) .. tostring(c.seal)
              .. (c.highlighted and "h" or "")) or "")
      end
    end
  end
  -- the hovered Lucky card matters only while nothing is selected
  local tgt = G.CONTROLLER and G.CONTROLLER.hovering and G.CONTROLLER.hovering.target
  if tgt and tgt.area == G.hand and tgt.ability and tgt.ability.effect == 'Lucky Card' then
    t[#t + 1] = "hov" .. tostring(tgt.sort_id)
  end
  return table.concat(t, ",")
end

-- Builds/caches the hand tags (SELECTING_HAND only).
function FHUD_tag_tick()
  if G.STATE ~= G.STATES.SELECTING_HAND or not predict_ok() then
    if FHUD.hand_tag_items or FHUD.tag_sig then FHUD_tag_destroy() end
    return
  end
  local sig = tag_sig()
  if sig == FHUD.tag_sig then return end
  FHUD.tag_sig = sig
  FHUD.hand_tag_items = {}
  local r = FHUD_peek_hand_tags()
  for _, tg in ipairs((r and r.tags) or {}) do FHUD.ui.hand_tag(tg.card, tg.text, tg.colour) end
end

-- Word-wrap one card's tag lines into a box no wider than `avail` px: words wrap; a word that
-- still doesn't fit shrinks the font (down to 60% of `base`). Shared by the hand tags and the
-- joker badges. Returns lines { {t, colour} }, scale, text width, line height.
local function wrap_tag_lines(its, avail, font, base)
  local fh = math.max(font:getHeight(), 1)
  local sc = base
  for _, it in ipairs(its) do
    for w in tostring(it.text):gmatch("%S+") do
      local ww = font:getWidth(w) * sc
      if ww > avail then sc = math.max(base * 0.6, sc * avail / ww) end
    end
  end
  local lines = {}
  for _, it in ipairs(its) do
    local col = it.colour
    if type(col) == 'string' then col = TAG_COL[col] end
    local cur
    for w in tostring(it.text):gmatch("%S+") do
      local try = cur and (cur .. " " .. w) or w
      if cur and font:getWidth(try) * sc > avail then
        lines[#lines + 1] = { t = cur, colour = col }
        cur = w
      else
        cur = try
      end
    end
    if cur then lines[#lines + 1] = { t = cur, colour = col } end
  end
  local tw = 0
  for _, l in ipairs(lines) do tw = math.max(tw, font:getWidth(l.t) * sc) end
  return lines, sc, tw, fh * sc
end

-- The visible strip of each card of an overlapping row (later cards are drawn on top,
-- cardarea.lua 398-403): from its left edge to the next card's left edge, in pixels.
local function visible_strips(cards, ox, s)
  local strip = {}
  for i, c in ipairs(cards) do
    if c.VT then
      local x0, x1 = c.VT.x, c.VT.x + c.VT.w
      local nx = cards[i + 1] and cards[i + 1].VT
      if nx and nx.x > x0 and nx.x < x1 then x1 = nx.x end
      strip[c] = { (x0 + ox) * s, (x1 + ox) * s }
    end
  end
  return strip
end

-- Wave 3: where each hand tag goes, in window pixels. Card -> pixels is the engine's own
-- mapping, (VT + G.ROOM.T) * G.TILESCALE * G.TILESIZE (engine/node.lua 296), taken from the
-- ANIMATED transform VT so a tag rides along when cards slide, lift or are dragged.
-- Hand cards overlap and later ones are drawn on top (cardarea.lua 398-403), so what you
-- see of card i is the strip from its left edge to the next card's left edge. A tag is
-- centred on that VISIBLE strip and is never wider than it (words wrap; a word that still
-- doesn't fit shrinks the font, down to 60%): it can't drift under a neighbour, and tags
-- of neighbouring cards can't overlap. It sits just below the card; if that would run into
-- the Play / Discard buttons it moves up onto the card's lower edge instead.
-- Returns { {x, y, w, h, sc, lh, pad, lines = { {t, colour} }, card, strip = {x0, x1}}, ... }.
function FHUD_hand_tag_layout(W, H, font)
  local items = FHUD.hand_tag_items
  if not (items and #items > 0 and font and G.hand and G.hand.cards and G.ROOM and G.TILESCALE and G.TILESIZE) then
    return {}
  end
  local s = G.TILESCALE * G.TILESIZE
  local ox, oy = G.ROOM.T.x, G.ROOM.T.y
  local by, order = {}, {}
  for _, it in ipairs(items) do
    local c = it.card
    if c and not c.removed and c.area == G.hand and c.VT and not (c.states and c.states.visible == false) then
      if not by[c] then by[c] = {}; order[#order + 1] = c end
      by[c][#by[c] + 1] = it
    end
  end
  -- visible strip of each hand card (draw order = G.hand.cards order)
  local strip = visible_strips(G.hand.cards, ox, s)
  -- the Play / Discard buttons (a UIBox laid out in the same room units)
  local btn
  if G.buttons and G.buttons.T and not (G.buttons.states and G.buttons.states.visible == false) then
    local T = G.buttons.VT or G.buttons.T
    btn = { x = (T.x + ox) * s, y = (T.y + oy) * s, w = T.w * s, h = T.h * s }
  end
  local fh = math.max(font:getHeight(), 1)
  local base = (H * 0.017) / fh
  local pad = 4
  local out = {}
  for _, c in ipairs(order) do
    local st = strip[c] or { (c.VT.x + ox) * s, (c.VT.x + c.VT.w + ox) * s }
    local cx = (st[1] + st[2]) / 2
    local avail = math.max(st[2] - st[1] - 2 * pad - 2, 16) -- text width this tag may use
    local lines, sc, tw, lh = wrap_tag_lines(by[c], avail, font, base)
    local w, h = tw + 2 * pad, #lines * lh + 2 * pad
    local x = cx - w / 2
    local top = (c.VT.y + oy) * s
    local y = (c.VT.y + c.VT.h + oy) * s + 3
    if btn and x < btn.x + btn.w and btn.x < x + w and y + h > btn.y - 2 then
      y = math.max(top, btn.y - 2 - h)
    end
    if y + h > H - 2 then y = math.max(top, H - 2 - h) end
    out[#out + 1] = { x = x, y = y, w = w, h = h, sc = sc, lh = lh, pad = pad, lines = lines, card = c, strip = st }
  end
  return out
end

--------------------------------------- Wave 4: blind-select strip (Pattern 3)
-- Short coloured lines inside each blind panel, under its tag (Small / Big) or under the
-- boss description (Boss), drawn by FHUD.ui.blind_strip. BLIND_SELECT only.
-- Recipes are the RUNTIME code (lovely dump + Steamodded 26.1002.0), NOT FORESIGHT_SPEC 12/13:
--   Bosses  get_new_boss is Steamodded's override (smods overrides.lua 3096) ->
--           SMODS.get_new_blind('boss') (smods game_objects/blind.lua 122):
--           pseudorandom_element(SMODS.create_blind_pool('boss'), pseudoseed('boss')) over a
--           SORTED key list (weights.lua 171-238): v.boss, showdown iff ante % win_ante == 0
--           and ante > 0 (is_showdown_ante), boss.min <= max(1, ante), boss.max >= ante,
--           in_pool, banned_keys, only the least-used (bosses_used.boss), and NOT any key
--           already in round_resets.blind_choices -- so a reroll never repeats the current
--           boss. Each new ante (G.FUNCS.cash_out after the boss, button_callbacks.lua 3006-3010)
--           rolls the two tags, then reset_blinds -> SMODS.reset_blind_choices, which re-rolls
--           Small ('small'), Big ('big') and Boss ('boss') for the NEW ante (ease_ante already
--           ran in end_round). The only other 'boss' consumer is G.FUNCS.reroll_boss
--           (Director's Cut / Retcon button, and the Boss Tag). The dry-run calls those real
--           functions with round_resets.ante set ahead; the snapshot restores everything.
--   Tags    skip_blind (button_callbacks.lua 2790-2830): skips + 1; add_tag(the panel's Tag):
--           every pending Double Tag copies it (tag_add, the copy is added in an event, so
--           before the rest); then ONE event fires every pending 'immediate' tag in list order
--           and the first pending 'new_blind_choice' tag (the next one fires when that one
--           finishes: pack closed / boss rerolled). Shop tags fire in the next shop
--           (game.lua 3260-3352): shop_start (D6), store_joker_create (Rare / Uncommon: the
--           first slot(s)), store_joker_modify (editions: first editionless shop JOKER),
--           voucher_add, shop_final_pass (Coupon); Juggle at the next round start, Investment
--           when the Boss is beaten. Tags are never applied: tag.lua (dump) is mirrored, and
--           the RNG parts run the real generators (create_card 'top', the booster center's
--           create_card, get_new_boss, get_next_voucher_key(true), create_card_for_shop's mirror).
--   Charm / Meteor pick mega pack 1 or 2 with math.random: both have the same config and
--   the same create_card, so the contents don't depend on it.
local TAG_SHOP_TYPES = { store_joker_create = true, store_joker_modify = true, voucher_add = true,
                         shop_start = true, shop_final_pass = true }
local TAG_PACKS = { ['Charm Tag'] = 'p_arcana_mega_1', ['Meteor Tag'] = 'p_celestial_mega_1',
                    ['Ethereal Tag'] = 'p_spectral_normal_1', ['Standard Tag'] = 'p_standard_mega_1',
                    ['Buffoon Tag'] = 'p_buffoon_mega_1' }

-- What our mirrors read from a Tag, WITHOUT building a real one (Tag:init bumps G.tagid /
-- G.GAME.tag_tally, and an Orbital Tag's set_ability can roll 'orbital').
local function tag_stub(key, orbital_hand, from)
  local p = G.P_TAGS and G.P_TAGS[key]
  if not p then return nil end
  return { key = key, name = p.name, config = copy_table(p.config or {}), triggered = false,
           ability = { orbital_hand = orbital_hand }, fhud_stub = true, from = from }
end

local function tag_label(key)
  local p = G.P_TAGS and G.P_TAGS[key]
  local ok, s = pcall(localize, { type = 'name_text', set = 'Tag', key = key })
  if not (ok and type(s) == 'string' and s ~= '' and s ~= 'ERROR') then s = (p and p.name) or tostring(key) end
  return (s:gsub(" Tag$", ""))
end

local function blind_label(key)
  local ok, s = pcall(localize, { type = 'name_text', set = 'Blind', key = key })
  if not (ok and type(s) == 'string' and s ~= '' and s ~= 'ERROR') then
    s = (G.P_BLINDS and G.P_BLINDS[key] and G.P_BLINDS[key].name) or tostring(key)
  end
  return (s:gsub("^The ", ""))
end

local function blind_col(key)
  local c = G.P_BLINDS and G.P_BLINDS[key] and G.P_BLINDS[key].boss_colour
  if type(c) == 'table' and c[1] then
    -- lift dark boss colours so they read on the dark panel
    local m = math.max(c[1], c[2], c[3], 0.01)
    local k = (m < 0.75) and (0.75 / m) or 1
    return { math.min(c[1] * k, 1), math.min(c[2] * k, 1), math.min(c[3] * k, 1), 1 }
  end
  return TAG_COL.info
end

-- a created card -> short text: "Egg", "Egg (Foil)", "KS Glass, Red Seal"
local function card_text(c)
  if not c then return "?" end
  local set = c.ability and c.ability.set
  local ed = c.edition and ed_name(c.edition) or nil
  local s
  if set == 'Default' or set == 'Enhanced' then
    local b = c.base or {}
    local r = SMODS.Ranks and SMODS.Ranks[b.value]
    s = ((r and r.card_key) or tostring(b.value)) .. tostring(b.suit or "?"):sub(1, 1)
    local extra = {}
    if set == 'Enhanced' then extra[#extra + 1] = short_name(ckey(c)):gsub(" Card$", "") end
    if c.seal then extra[#extra + 1] = c.seal .. " Seal" end
    if ed then extra[#extra + 1] = ed end
    if #extra > 0 then s = s .. " " .. table.concat(extra, ", ") end
    return s
  end
  s = short_name(ckey(c))
  if ed then s = s .. " (" .. ed .. ")" end
  return s
end

-- exact descriptor of a created card (also what the validation harness diffs against)
local function card_desc(c)
  if not c then return "nil" end
  local ab = c.ability or {}
  local ed = c.edition and (c.edition.key or c.edition.type or ed_name(c.edition)) or "-"
  local fr = ((ab.set == 'Default' or ab.set == 'Enhanced') and c.base and c.base.value)
      and (tostring(c.base.value) .. tostring(c.base.suit)) or "-"
  return table.concat({ tostring(ckey(c)), tostring(ed), fr, tostring(c.seal or "-"),
    (ab.eternal and "E" or "") .. (ab.perishable and "P" or "") .. (ab.rental and "R" or "") }, "|")
end
FHUD.card_desc = card_desc

local function names_of(list)
  local t = {}
  for _, c in ipairs(list) do t[#t + 1] = card_text(c) end
  return table.concat(t, ", ")
end

local function joker_room()
  return #G.jokers.cards, G.jokers.config.card_limit
end

local function halu_can_roll()
  local room = #G.consumeables.cards + (G.GAME.consumeable_buffer or 0) < G.consumeables.config.card_limit
  if not room then return false end
  for _, j in ipairs(G.jokers.cards) do
    if ckey(resolve_joker(j)) == 'j_hallucination' then return true end
  end
  return false
end

-- The next shop's joker slots / vouchers for the pending tags `stubs` (mirrors
-- Game:update_shop). Inside a dry-run; swaps in stand-in areas and puts them back.
local function sim_next_shop(sim, shop_ante, made)
  local need = false
  for _, t in ipairs(sim.tags) do
    if not t.triggered and t.config and TAG_SHOP_TYPES[t.config.type] then need = true end
  end
  if not need then return end
  local rr = G.GAME.round_resets
  local a0, tags0, sj0, sv0 = rr.ante, G.GAME.tags, G.shop_jokers, G.shop_vouchers
  local T = (G.hand and G.hand.T) or { x = 0, y = 0, w = 1, h = 1 }
  local function standin(cards)
    return { T = { x = T.x, y = T.y, w = T.w, h = T.h }, cards = cards or {}, config = { card_limit = 0, type = 'shop' },
             fhud_standin = true }
  end
  local ok, err = pcall(function()
    -- the A+1 shop's vouchers are rolled when the Boss is beaten (end_round,
    -- state_events.lua 205), still seeing the current G.shop_vouchers
    local cv
    if shop_ante ~= a0 then
      rr.ante = shop_ante
      cv = SMODS.get_next_vouchers()
    else
      local cur = G.GAME.current_round.voucher or { spawn = {} }
      cv = { spawn = {} }
      for i, k in ipairs(cur) do cv[i] = k end
      for k, v in pairs(cur.spawn or {}) do cv.spawn[k] = v end
    end
    rr.ante = shop_ante
    G.GAME.tags = sim.tags
    -- shop_start: the first pending D6 Tag (G.GAME.shop_d6ed is reset per shop)
    for _, t in ipairs(sim.tags) do
      if not t.triggered and t.name == 'D6 Tag' then t.triggered = true; t.res = "next shop: rerolls start at $0"; break end
    end
    -- the joker slots
    G.shop_jokers = standin()
    local ts = { used = {}, log = {} }
    for i = 1, (G.GAME.shop and G.GAME.shop.joker_max) or 2 do
      local nlog = #ts.log
      local card, ted = shop_card_like_real(G.shop_jokers, ts)
      if card then made[#made + 1] = card end
      for li = nlog + 1, #ts.log do
        local e = ts.log[li]
        e.tag.triggered = true
        e.tag.slot, e.tag.card_desc = i, card_desc(e.card)
        if e.nope then
          e.tag.res = "you own every Rare: nothing"
        elseif e.edition then
          e.tag.res = "on " .. card_text(e.card) .. " (slot " .. i .. ")"
        else
          e.tag.res = card_text(e.card) .. " (slot " .. i .. ")"
        end
      end
      if ts.unmodelled then sim.unmodelled = true end
    end
    -- vouchers: top the list up like the shop does, then each Voucher Tag in order
    local nsp = 0
    for _ in pairs(cv.spawn) do nsp = nsp + 1 end
    G.shop_vouchers = standin()
    if nsp < G.GAME.starting_params.vouchers_in_shop + (G.GAME.modifiers.extra_vouchers or 0) then
      SMODS.get_next_vouchers(cv)
    end
    local vcards = {}
    for _, k in ipairs(cv) do
      if G.P_CENTERS[k] and cv.spawn[k] then vcards[#vcards + 1] = { config = { center = G.P_CENTERS[k] } } end
    end
    G.shop_vouchers = standin(vcards)
    for _, t in ipairs(sim.tags) do
      if not t.triggered and t.name == 'Voucher Tag' then
        t.triggered = true
        local key = get_next_voucher_key(true)
        vcards[#vcards + 1] = { config = { center = G.P_CENTERS[key] } }
        t.res = short_name(key)
        t.voucher = key
      end
    end
    -- shop_final_pass: the first pending Coupon Tag
    for _, t in ipairs(sim.tags) do
      if not t.triggered and t.name == 'Coupon Tag' then
        t.triggered = true; t.res = "next shop: its jokers and packs are free"; break
      end
    end
  end)
  rr.ante, G.GAME.tags, G.shop_jokers, G.shop_vouchers = a0, tags0, sj0, sv0
  if not ok then error(err, 0) end
end

-- One skip scenario: skip `blinds` (in order) from the current state, then reach the next
-- shop at `shop_ante`. MUST run inside a snapshot. Returns the tag stubs in list order;
-- each stub added by a skip carries .from (the blind) and .res (the text).
local function skip_scenario(blinds, shop_ante)
  local g, rr = G.GAME, G.GAME.round_resets
  local ante = rr.ante
  local sim = { tags = {}, dollars = g.dollars or 0, skips = g.skips or 0 }
  for _, t in ipairs(g.tags or {}) do
    local st = tag_stub(t.key, t.ability and t.ability.orbital_hand, 'pending')
    if st then st.triggered = t.triggered and true or false; sim.tags[#sim.tags + 1] = st end
  end
  local made = {}
  local njok, jlim = joker_room()
  local levels = {}
  local pack_open = 0
  local ok, err = dry_env(function()
    for _, b in ipairs(blinds) do
      local key = rr.blind_tags and rr.blind_tags[b]
      local oc = g.orbital_choices and g.orbital_choices[ante] and g.orbital_choices[ante][b]
      local x = key and tag_stub(key, oc, b)
      if x then
        sim.skips = sim.skips + 1
        local copies = 0
        if x.key ~= 'tag_double' then
          for _, t in ipairs(sim.tags) do
            if not t.triggered and t.key == 'tag_double' then t.triggered = true; t.res = "copied it"; copies = copies + 1 end
          end
        end
        sim.tags[#sim.tags + 1] = x
        for _ = 1, copies do
          local cp = tag_stub(x.key, x.ability.orbital_hand, b)
          cp.copy = true
          sim.tags[#sim.tags + 1] = cp
        end
        -- a tag with its own Steamodded apply (a modded tag) is flagged, not modelled
        for _, t in ipairs(sim.tags) do
          if not t.triggered and tag_modded(t) then t.triggered = true; t.unknown = true; t.res = "?" end
        end
        -- immediate
        for _, t in ipairs(sim.tags) do
          if not t.triggered and t.config.type == 'immediate' then
            t.triggered = true
            local c = t.config
            if t.name == 'Skip Tag' then
              local d = sim.skips * (c.skip_bonus or 5)
              sim.dollars = sim.dollars + d; t.res = "+$" .. d; t.dollars = d
            elseif t.name == 'Garbage Tag' then
              local d = (g.unused_discards or 0) * (c.dollars_per_discard or 1)
              sim.dollars = sim.dollars + d; t.res = "+$" .. d; t.dollars = d
            elseif t.name == 'Handy Tag' then
              local d = (g.hands_played or 0) * (c.dollars_per_hand or 1)
              sim.dollars = sim.dollars + d; t.res = "+$" .. d; t.dollars = d
            elseif t.name == 'Economy Tag' then
              local d = math.min(c.max or 40, math.max(0, sim.dollars))
              sim.dollars = sim.dollars + d; t.res = "+$" .. d; t.dollars = d
            elseif t.name == 'Orbital Tag' then
              local h = t.ability.orbital_hand
              local hd = h and g.hands[h]
              if hd then
                local lv0 = levels[h] or hd.level
                levels[h] = lv0 + (c.levels or 3)
                t.hand, t.lv_to = h, levels[h]
                local okh, hn = pcall(localize, h, 'poker_hands')
                t.res = ((okh and type(hn) == 'string' and hn ~= 'ERROR') and hn or h) .. " lv " .. lv0 .. " -> " .. levels[h]
              else
                t.res = "+" .. (c.levels or 3) .. " levels"
              end
            elseif t.name == 'Top-up Tag' then
              local got = {}
              for _ = 1, (c.spawn_jokers or 2) do
                if njok < jlim then
                  local card = create_card('Joker', G.jokers, nil, 0, nil, nil, nil, 'top')
                  made[#made + 1] = card
                  got[#got + 1] = card
                  njok = njok + 1
                  if card.edition and card.edition.negative then jlim = jlim + 1 end
                end
              end
              t.res = (#got > 0) and ("+" .. names_of(got)) or "no joker room"
              t.desc = {}
              for _, cc in ipairs(got) do t.desc[#t.desc + 1] = card_desc(cc) end
            else
              t.res = "?"
              t.unknown = true
            end
          end
        end
        -- new_blind_choice: one after another, in list order
        for _, t in ipairs(sim.tags) do
          if not t.triggered and t.config.type == 'new_blind_choice' then
            t.triggered = true
            if t.name == 'Boss Tag' then
              rr.blind_choices.Boss = get_new_boss()
              rr.boss_rerolled = true
              t.res = "rerolls it to " .. blind_label(rr.blind_choices.Boss)
              t.boss = rr.blind_choices.Boss
            elseif TAG_PACKS[t.name] then
              local center = G.P_CENTERS[TAG_PACKS[t.name]]
              local pack = { config = { center = center },
                             ability = { extra = center.config.extra, name = center.name } }
              local cards = gen_pack_cards(pack)
              if cards.failed then error("pack generation failed", 0) end
              t.desc = {}
              for _, cc in ipairs(cards) do t.desc[#t.desc + 1] = card_desc(cc); made[#made + 1] = cc end
              t.res = names_of(cards)
              if center.kind == 'Arcana' and halu_can_roll() then t.halu = true end
              pack_open = pack_open + 1
              t.pack_n = pack_open
              -- the pack closes before the next one: its cards leave (un-marked, as in the
              -- shop pack chain; assumes you keep none of a Buffoon pack's jokers)
              for _, cc in ipairs(cards) do
                local k = ckey(cc)
                if k and not next(SMODS.find_card(k, true)) then G.GAME.used_jokers[k] = nil end
              end
            else
              t.res = "?"
              t.unknown = true
            end
          end
        end
      end
    end
    -- pending to the next shop / round / boss
    sim_next_shop(sim, shop_ante, made)
    for _, t in ipairs(sim.tags) do
      if not t.triggered then
        if t.name == 'Juggle Tag' then t.res = "+" .. (t.config.h_size or 3) .. " hand size next round"
        elseif t.name == 'Investment Tag' then t.res = "+$" .. (t.config.dollars or 25) .. " after you beat the Boss"
        elseif t.name == 'Rare Tag' or t.name == 'Uncommon Tag' then t.res = "waits for a reroll (shop slots used)"
        elseif EDITION_TAGS[t.name] then t.res = "no joker in next shop: waits for a reroll"
        elseif t.name == 'D6 Tag' or t.name == 'Coupon Tag' then t.res = "the shop after next"
        elseif t.name == 'Double Tag' then t.res = "copies the next tag you get"
        elseif t.from ~= 'pending' then t.res = "?"; t.unknown = true end
      end
    end
  end)
  free_cards(made)
  if not ok then error(err, 0) end
  sim.dollars_end = sim.dollars
  return sim
end

-- Skip-tag rewards for the blind(s) still on offer. Returns
--   { small = {lines}, big = {lines}, sims = {...} } (sims for validation) or nil.
-- At Small select: Small = "skip Small, play Big" (its shop tags fire after Big, this ante);
-- Big = "skip Small, then Big" (shop after the Boss, next ante). At Big select: skip Big.
function FHUD_peek_skips()
  if not predict_ok() then return nil end
  local g = G.GAME
  local rr = g and g.round_resets
  if not (rr and rr.blind_tags and g.tags and G.jokers and G.jokers.cards and G.consumeables) then return nil end
  local deck = g.blind_on_deck
  if deck ~= 'Small' and deck ~= 'Big' then return nil end
  local out = { sims = {} }
  local plans = {}
  if deck == 'Small' then
    plans[#plans + 1] = { show = 'Small', blinds = { 'Small' }, shop_ante = rr.ante }
    if rr.blind_tags.Big then plans[#plans + 1] = { show = 'Big', blinds = { 'Small', 'Big' }, shop_ante = rr.ante + 1, both = true } end
  else
    plans[#plans + 1] = { show = 'Big', blinds = { 'Big' }, shop_ante = rr.ante + 1 }
  end
  for _, p in ipairs(plans) do
    local snap = snapshot_rng()
    local ok, sim = pcall(skip_scenario, p.blinds, p.shop_ante)
    restore_rng(snap)
    if not ok then
      if not FHUD.strip_err_logged then
        FHUD.strip_err_logged = true
        print("[ForesightHUD] skip-tag preview failed: " .. tostring(sim))
      end
      return nil
    end
    sim.plan = p
    out.sims[p.show] = sim
  end
  return out
end

-- The bosses of the next `n` antes if nothing rerolls them, and (when a reroll can
-- happen now) what the next reroll gives and the chain after it.
-- v0.7.1 `glyph` = { at = X, extra = 1 }: the chain if you buy Hieroglyph / Petroglyph during
-- ante X's shop. Its apply (dump card.lua 2303-2316) runs ease_ante(-extra) at once, so every
-- new ante after X is rolled `extra` lower: the bosses already rolled (this ante's, and
-- ante X's when X is the ante after the Boss) stay, and each later SMODS.reset_blind_choices
-- runs at (its usual ante - extra) on the same 'boss' stream -- the boss pool (min / max,
-- showdown) is ante-dependent, so this is an exact re-run, not a relabel.
function FHUD_peek_bosses(n, want_reroll, glyph)
  if not predict_ok() then return nil end
  local g = G.GAME
  local rr = g and g.round_resets
  if not (rr and rr.blind_choices and rr.blind_choices.Boss and g.bosses_used and SMODS.reset_blind_choices
      and get_new_boss) then return nil end
  local res = { ante = rr.ante, chain = {}, after = {} }
  local function chain_into(out, gl)
    local a0 = rr.ante
    for k = 1, n do
      local a = a0 + k
      if gl and a > gl.at then a = a - (gl.extra or 1) end
      rr.ante = a
      SMODS.reset_blind_choices(rr.blind_choices)
      out[k] = { ante = a, key = rr.blind_choices.Boss }
    end
  end
  local snap = snapshot_rng()
  local ok, err = dry_env(function() chain_into(res.chain) end)
  restore_rng(snap)
  if ok and glyph then
    res.glyph = {}
    snap = snapshot_rng()
    ok, err = dry_env(function() chain_into(res.glyph, glyph) end)
    restore_rng(snap)
  end
  if ok and want_reroll then
    snap = snapshot_rng()
    ok, err = dry_env(function()
      -- G.FUNCS.reroll_boss (button_callbacks.lua 2845-2880): the current boss stays in
      -- blind_choices while get_new_boss runs, so it is excluded
      rr.blind_choices.Boss = get_new_boss()
      res.reroll = rr.blind_choices.Boss
      rr.blind_choices.Boss = get_new_boss()
      res.reroll2 = rr.blind_choices.Boss
    end)
    restore_rng(snap)
    if ok then
      snap = snapshot_rng()
      ok, err = dry_env(function()
        rr.blind_choices.Boss = get_new_boss()
        chain_into(res.after)
      end)
      restore_rng(snap)
    end
  end
  if not ok then
    if not FHUD.boss_err_logged then
      FHUD.boss_err_logged = true
      print("[ForesightHUD] boss preview failed: " .. tostring(err))
    end
    return nil
  end
  return res
end

-- Next ante's Small / Big tags: get_next_tag_key() twice at ante + 1, as cash_out does.
-- Only EXACT when the Tag pool can't change before then: object weights off, no tag with an
-- in_pool hook, and every discovery-gated tag (Rare: Blueprint, Negative / Foil / Holo /
-- Polychrome: their edition) either already unlocked by discovery or frozen (Steamodded
-- skips discovery in seeded / challenge runs only when its seeded_unlocks option is off).
-- Returns { small =, big = } or nil, why.
function FHUD_peek_next_tags(at_ante)
  if not predict_ok() then return nil end
  local g = G.GAME
  local rr = g and g.round_resets
  if not (rr and get_next_tag_key and G.P_CENTER_POOLS and G.P_CENTER_POOLS.Tag) then return nil end
  if G.FORCE_TAG or (SMODS.optional_features and SMODS.optional_features.object_weights) then return nil, "weights" end
  local frozen = (SMODS.config and not SMODS.config.seeded_unlocks) and (g.seeded or g.challenge)
  for _, v in ipairs(G.P_CENTER_POOLS.Tag) do
    if type(v.in_pool) == 'function' then return nil, "modded" end
    if v.requires and not frozen and not (G.P_CENTERS[v.requires] and G.P_CENTERS[v.requires].discovered)
        and not (v.min_ante and v.min_ante > (at_ante or (rr.ante + 1))) then
      return nil, "discovery"
    end
  end
  local res = {}
  local snap = snapshot_rng()
  local ok, err = dry_env(function()
    rr.ante = at_ante or (rr.ante + 1) -- v0.7.1: at_ante = where a Hieroglyph leaves it
    res.small = get_next_tag_key()
    res.big = get_next_tag_key()
  end)
  restore_rng(snap)
  if not ok then
    if not FHUD.ntag_err_logged then
      FHUD.ntag_err_logged = true
      print("[ForesightHUD] next-ante tag preview failed: " .. tostring(err))
    end
    return nil
  end
  return res
end

local function reroll_source()
  local g = G.GAME
  local uv = g.used_vouchers or {}
  if uv.v_retcon then return 'retcon' end
  if uv.v_directors_cut and not g.round_resets.boss_rerolled then return 'dc' end
  return nil
end

-- v0.7.1: Hieroglyph / Petroglyph lower the ante by `extra` (1), which shifts the boss chain,
-- next ante's tags and every ante-keyed stream. Where could you buy one before the chain
-- plays out? Returns { key, at = the ante whose shop sells it, extra, src } for the earliest:
--   * this ante's shop voucher (current_round.voucher, still spawning), when a shop is still
--     coming this ante (Small / Big on deck);
--   * a Voucher Tag's voucher (from the skip simulation: shop after Big = this ante, shop
--     after the Boss = next ante);
--   * next ante's shop voucher, rolled when the Boss is beaten (end_round, state_events.lua 205:
--     SMODS.get_next_vouchers() at ante + 1, as Wave 4's shop simulation does).
-- Vanilla packs never hold vouchers, so there is no pack case.
local GLYPHS = { v_hieroglyph = true, v_petroglyph = true }
local function glyph_offer(skips)
  local g, rr = G.GAME, G.GAME.round_resets
  local deck = g.blind_on_deck
  local best
  local function offer(key, at, src)
    if not (GLYPHS[key] and G.P_CENTERS[key]) or (g.used_vouchers and g.used_vouchers[key]) then return end
    if not best or at < best.at then
      local c = G.P_CENTERS[key].config or {}
      best = { key = key, at = at, extra = tonumber(c.extra) or 1, src = src }
    end
  end
  local cv = g.current_round and g.current_round.voucher
  if cv and (deck == 'Small' or deck == 'Big') then
    for _, k in ipairs(cv) do if cv.spawn and cv.spawn[k] then offer(k, rr.ante, "next shop") end end
  end
  for _, sim in pairs((skips and skips.sims) or {}) do
    for _, t in ipairs(sim.tags or {}) do
      if t.voucher then offer(t.voucher, sim.plan.shop_ante, "Voucher Tag") end
    end
  end
  if not best then
    local nv
    local snap = snapshot_rng()
    local ok = dry_env(function()
      rr.ante = rr.ante + 1
      nv = SMODS.get_next_vouchers()
    end)
    restore_rng(snap)
    if ok and nv then
      for _, k in ipairs(nv) do if nv.spawn and nv.spawn[k] then offer(k, rr.ante + 1, "shop after Boss") end end
    end
  end
  return best
end

-- Builds every strip line for the current blind select.
local function strip_build()
  local g, rr = G.GAME, G.GAME.round_resets
  local deck = g.blind_on_deck
  local want_boss, want_tags = cfg('boss_preview'), cfg('skip_tags')
  local bt = rr.blind_tags or {}
  local boss_tag_offered = (deck == 'Small' and (bt.Small == 'tag_boss' or bt.Big == 'tag_boss'))
      or (deck == 'Big' and bt.Big == 'tag_boss')

  local nt
  if want_tags then nt = FHUD_peek_next_tags() end

  local skips
  if want_tags then
    local r = FHUD_peek_skips()
    skips = r
    for _, b in ipairs({ 'Small', 'Big' }) do
      local sim = r and r.sims[b]
      if sim then
        local opt = b:lower()
        local mine = {}
        for _, t in ipairs(sim.tags) do if t.from == b then mine[#mine + 1] = t end end
        for _, t in ipairs(mine) do
          local head = (t.copy and "Double: " or "") .. tag_label(t.key) .. ": "
          local txt, col = t.res or "?", 'info'
          if t.name == 'Double Tag' and not t.triggered then
            -- what it will copy
            if b == 'Small' and bt.Big and deck == 'Small' then
              txt = (bt.Big == 'tag_double') and "Big's tag is a Double too (no copy)"
                  or ("copies Big's " .. tag_label(bt.Big) .. " if you skip Big")
            elseif nt and nt.small then
              txt = (nt.small == 'tag_double') and "next ante's Small tag is a Double (no copy)"
                  or ("copies next ante's Small tag (" .. tag_label(nt.small) .. ") if you skip it")
            end
          elseif t.config.type == 'store_joker_create' or EDITION_TAGS[t.name] or t.name == 'Voucher Tag' then
            if t.triggered and t.res then
              txt = txt .. ((sim.plan.shop_ante == rr.ante) and " - next shop" or " - shop after Boss")
            end
          end
          if t.res and (t.res:find("no joker room") or t.res:find("nothing") or t.res:find("waits")) then col = 'muted' end
          if t.unknown then txt, col = "not modelled", 'muted' end
          FHUD.ui.blind_strip(opt, head .. txt, col)
          if t.halu then FHUD.ui.blind_strip(opt, "(Hallucination can shift this pack)", 'muted') end
          if (t.pack_n or 0) > 1 then FHUD.ui.blind_strip(opt, "(if you keep none of the pack before)", 'muted') end
          if t.name == 'Boss Tag' and reroll_source() == 'dc' and t.from == b then
            FHUD.ui.blind_strip(opt, "(uses up Director's Cut this ante)", 'muted')
          end
        end
        if sim.unmodelled then FHUD.ui.blind_strip(opt, "(modded shop: not modelled)", 'muted') end
        if sim.plan.both and #mine > 0 then FHUD.ui.blind_strip(opt, "(if you skip Small too)", 'muted') end
      end
    end
  end

  if want_boss then
    local win = g.win_ante or 8
    local n = (rr.ante < win) and math.min(3, win - rr.ante) or 3
    local src = reroll_source()
    local r = FHUD_peek_bosses(n, src ~= nil)
    if r then
      -- "Next:" / "If not rerolled:" / "Without Boss Tag:" A2 Fish A3 Pillar A4 House
      local head = (src and "If not rerolled:") or (boss_tag_offered and "Without Boss Tag:") or "Next:"
      local segs = { { head, TAG_COL.muted } }
      for _, e in ipairs(r.chain) do
        segs[#segs + 1] = { "A" .. e.ante, TAG_COL.muted }
        segs[#segs + 1] = { blind_label(e.key), blind_col(e.key) }
      end
      FHUD.ui.blind_strip('boss', segs)
      -- "Reroll -> Club [then Pillar]; after: A2 Pillar A3 Hook A4 Wall"
      if r.reroll then
        local rs = { { "Reroll ->", TAG_COL.muted }, { blind_label(r.reroll), blind_col(r.reroll) } }
        if src == 'retcon' and r.reroll2 then
          rs[#rs + 1] = { "then", TAG_COL.muted }
          rs[#rs + 1] = { blind_label(r.reroll2), blind_col(r.reroll2) }
        end
        local same = true
        for k, e in ipairs(r.after) do if not r.chain[k] or r.chain[k].key ~= e.key then same = false end end
        if not same and #r.after > 0 then
          rs[#rs + 1] = { "; after:", TAG_COL.muted }
          for _, e in ipairs(r.after) do
            rs[#rs + 1] = { "A" .. e.ante, TAG_COL.muted }
            rs[#rs + 1] = { blind_label(e.key), blind_col(e.key) }
          end
        end
        FHUD.ui.blind_strip('boss', rs)
      end
    end
  end
  if want_tags and nt then
    FHUD.ui.blind_strip('boss', "Next ante tags: " .. tag_label(nt.small) .. " / " .. tag_label(nt.big), 'info')
  end
  -- v0.7.1: "If you buy Hieroglyph (next shop): A2 Fish A3 Pillar A4 House; tags Handy / Ethereal"
  if want_boss then
    local okg, gl = pcall(glyph_offer, (want_tags and skips) or (not want_tags and FHUD_peek_skips()) or nil)
    FHUD.glyph_offer = (okg and gl) or nil
    if okg and gl then
      local win = g.win_ante or 8
      local n = (rr.ante < win) and math.min(3, win - rr.ante) or 3
      local r = FHUD_peek_bosses(n, false, gl)
      FHUD.glyph_chain = r and r.glyph
      if r and r.glyph then
        local segs = { { "If you buy " .. center_name(gl.key) .. " (" .. gl.src .. "):", TAG_COL.muted } }
        for _, e in ipairs(r.glyph) do
          segs[#segs + 1] = { "A" .. e.ante, TAG_COL.muted }
          segs[#segs + 1] = { blind_label(e.key), blind_col(e.key) }
        end
        -- next ante's tags are rolled at the Boss's cash-out: lower too if bought this ante
        if want_tags and nt and gl.at == rr.ante then
          local nt2 = FHUD_peek_next_tags(rr.ante + 1 - gl.extra)
          if nt2 then
            segs[#segs + 1] = { "; tags " .. tag_label(nt2.small) .. " / " .. tag_label(nt2.big), TAG_COL.muted }
          end
        end
        FHUD.ui.blind_strip('boss', segs)
      end
    end
  end
end

function FHUD_strip_destroy()
  FHUD.strip_items = nil
  FHUD.strip_sig = nil
end

local function strip_sig()
  local g = G.GAME
  local rr = g.round_resets or {}
  local pr, s = g.pseudorandom, 0
  for _, v in pairs(pr or {}) do if type(v) == 'number' then s = s + v end end
  local bus = 0
  for _, v in pairs((g.bosses_used and g.bosses_used.boss) or {}) do bus = bus + (tonumber(v) or 0) end
  local nv, nu = 0, 0
  for _ in pairs(g.used_vouchers or {}) do nv = nv + 1 end
  for _ in pairs(g.used_jokers or {}) do nu = nu + 1 end
  local bc, bt, bs = rr.blind_choices or {}, rr.blind_tags or {}, rr.blind_states or {}
  local oc = (g.orbital_choices and g.orbital_choices[rr.ante]) or {}
  local cv = g.current_round and g.current_round.voucher or {}
  local t = { tostring(G.STATE), string.format("%.12f", s), tostring(rr.ante), tostring(g.win_ante),
    tostring(g.blind_on_deck), tostring(bc.Small), tostring(bc.Big), tostring(bc.Boss), tostring(bt.Small), tostring(bt.Big),
    tostring(bs.Small), tostring(bs.Big), tostring(oc.Small), tostring(oc.Big), tostring(rr.boss_rerolled), bus, nv, nu,
    tostring(g.used_vouchers and g.used_vouchers.v_directors_cut), tostring(g.used_vouchers and g.used_vouchers.v_retcon),
    tostring(g.dollars), tostring(g.skips), tostring(g.hands_played), tostring(g.unused_discards),
    tostring(g.consumeable_buffer), tostring(g.joker_buffer), tostring(g.shop and g.shop.joker_max),
    tostring(g.joker_rate), tostring(g.tarot_rate), tostring(g.planet_rate), tostring(g.playing_card_rate),
    tostring(g.spectral_rate), tostring(g.seeded), table.concat(cv, ":"),
    tostring(cfg('boss_preview')) .. tostring(cfg('skip_tags')) }
  for k, v in pairs(cv.spawn or {}) do t[#t + 1] = tostring(k) .. tostring(v) end
  for _, tg in ipairs(g.tags or {}) do t[#t + 1] = tostring(tg.key) .. (tg.triggered and "t" or "") end
  for _, v in ipairs(G.P_CENTER_POOLS.Tag or {}) do
    if v.requires then t[#t + 1] = tostring(G.P_CENTERS[v.requires] and G.P_CENTERS[v.requires].discovered) end
  end
  for _, h in pairs(oc) do if g.hands and g.hands[h] then t[#t + 1] = h .. g.hands[h].level end end
  local areas = { G.jokers, G.consumeables }
  for ai = 1, 2 do
    local a = areas[ai]
    if a and a.cards then
      t[#t + 1] = #a.cards .. "/" .. tostring(a.config and a.config.card_limit)
      for _, c in ipairs(a.cards) do
        t[#t + 1] = tostring(ckey(c)) .. (c.edition and tostring(c.edition.type) or "") .. (c.debuff and "d" or "")
      end
    end
  end
  return table.concat(t, ",")
end

-- Builds/caches the strip (BLIND_SELECT only). Not while the game is paused: pseudoseed
-- returns math.random() then (dump misc_functions.lua 330), so a dry-run would be garbage.
function FHUD_strip_tick()
  if G.STATE ~= G.STATES.BLIND_SELECT or not predict_ok() or not G.blind_select_opts
      or not (cfg('boss_preview') or cfg('skip_tags')) then
    if FHUD.strip_items or FHUD.strip_sig then FHUD_strip_destroy() end
    return
  end
  if G.SETTINGS and G.SETTINGS.paused then return end
  local sig = strip_sig()
  if sig == FHUD.strip_sig then return end
  FHUD.strip_sig = sig
  FHUD.strip_items = {}
  strip_build()
end

-- Where each panel's lines go, in window pixels: Small / Big just under the tag + Skip
-- button ('tag_container'), Boss under the lowest element of its description; inside the
-- panel's width, down to the window bottom (the panels run off-screen, measured headless:
-- Small x 4.9-8.6, Big 9.1-12.9, Boss 13.4-17.1 of a 20 x 11.5 room; tag bottoms y 10.0 /
-- 10.7, boss text y 10.8; the panel on deck sits 0.7 higher). Positions come from the
-- animated VT, so the lines ride along when the panels slide in or a boss is rerolled.
-- Words wrap; the font shrinks (to 60%) until the lines fit; what still doesn't fit is cut.
local function panel_anchor(key, opt)
  FHUD.strip_anchor = FHUD.strip_anchor or setmetatable({}, { __mode = 'k' })
  local a = FHUD.strip_anchor[opt]
  if not a then
    a = {}
    if key == 'boss' then
      local best = 0
      local function walk(n)
        if n.T and n.T.h and n.T.h < 5 and n.config and (n.config.text or n.config.object or n.config.button) then
          best = math.max(best, n.T.y + n.T.h - opt.T.y)
        end
        for _, c in pairs(n.children or {}) do if type(c) == 'table' and c.T then walk(c) end end
      end
      if opt.UIRoot then walk(opt.UIRoot) end
      a.off = best
    else
      a.uie = opt.get_UIE_by_ID and opt:get_UIE_by_ID('tag_container')
    end
    FHUD.strip_anchor[opt] = a
  end
  if a.uie and a.uie.VT then return a.uie.VT.y + a.uie.VT.h end
  if a.off and a.off > 0 then return opt.VT.y + a.off end
  return nil
end

function FHUD_blind_strip_layout(W, H, font)
  local items = FHUD.strip_items
  if not (items and font and G.blind_select_opts and G.ROOM and G.TILESCALE and G.TILESIZE) then return {} end
  local s = G.TILESCALE * G.TILESIZE
  local ox, oy = G.ROOM.T.x, G.ROOM.T.y
  local fh = math.max(font:getHeight(), 1)
  local base = (H * 0.017) / fh
  local pad = 4
  local out = {}
  for _, key in ipairs({ 'small', 'big', 'boss' }) do
    local lines = items[key]
    local opt = G.blind_select_opts[key]
    if lines and #lines > 0 and opt and opt.VT and not opt.REMOVED then
      local yb = panel_anchor(key, opt)
      if yb then
        local x0 = (opt.VT.x + 0.12 + ox) * s
        local x1 = (opt.VT.x + opt.VT.w - 0.12 + ox) * s
        local y0 = (yb + 0.04 + oy) * s
        local avail_w = math.max(x1 - x0 - 2 * pad, 20)
        local avail_h = H - 2 - y0
        -- tokens: words carrying their colour, a line break between registered lines
        local function wrap(sc)
          local rows = {}
          for _, ln in ipairs(lines) do
            local row, rw = {}, 0
            for _, seg in ipairs(ln) do
              local col = seg[2]
              if type(col) == 'string' then col = TAG_COL[col] end
              for w in tostring(seg[1]):gmatch("%S+") do
                local ww = font:getWidth(w) * sc
                local sp = (#row > 0) and font:getWidth(" ") * sc or 0
                if #row > 0 and rw + sp + ww > avail_w then
                  rows[#rows + 1] = { toks = row, w = rw }
                  row, rw, sp = {}, 0, 0
                end
                row[#row + 1] = { t = w, col = col or TAG_COL.info, x = rw + sp }
                rw = rw + sp + ww
              end
            end
            if #row > 0 then rows[#rows + 1] = { toks = row, w = rw } end
          end
          return rows
        end
        local sc = base
        local rows = wrap(sc)
        while #rows * fh * sc + 2 * pad > avail_h and sc > base * 0.6 do
          sc = math.max(sc * 0.92, base * 0.6)
          rows = wrap(sc)
          if sc <= base * 0.6 then break end
        end
        local lh = fh * sc
        local fit = math.max(math.floor((avail_h - 2 * pad) / lh), 1)
        if #rows > fit then
          for i = #rows, fit + 1, -1 do rows[i] = nil end
          FHUD.strip_cut = (FHUD.strip_cut or 0) + 1
        end
        local tw = 0
        for _, r in ipairs(rows) do tw = math.max(tw, r.w) end
        local w, h = tw + 2 * pad, #rows * lh + 2 * pad
        local x = (x0 + x1) / 2 - w / 2
        out[#out + 1] = { key = key, x = x, y = y0, w = w, h = h, sc = sc, lh = lh, pad = pad, rows = rows,
                          panel = { x0, x1 } }
      end
    end
  end
  return out
end

------------------------------------------------- Wave 5: joker badges (Pattern 4)
-- A short badge on each joker whose effect is random, with what it WILL do. Every vanilla
-- joker that rolls RNG was looked up in the runtime code (lovely dump + Steamodded 26.1002.0):
--   Space Joker      context.before, joker order, every copy rolls (card.lua 3817):
--                    SMODS.pseudorandom_probability(self, 'space', 1, extra 4); only when the
--                    blind doesn't debuff the hand (state_events.lua 674). Badge: next hand.
--   Business Card    individual, scoring cards (cardarea G.play), face (is_face, Pareidolia),
--                    per trigger, copies roll: 'business' 1 in extra 2 for $2 (card.lua 3569).
--   Bloodstone       same, is_suit('Hearts') (Wild / Smeared), 'bloodstone' 1 in 2 for X1.5 (3641).
--   Reserved Parking individual, HELD cards (G.hand), is_face, 'parking' 1 in 2 for $1 (3696);
--                    a held card only repeats (Red seal, Mime + copies) when its first trigger did
--                    something, and its repetitions stop at the first trigger that does nothing
--                    (SMODS.score_card: j + (calculated and 1 or #reps)). The Hook discards 2
--                    random held cards first ('hook', blind.lua 518) -- modelled.
--   Lucky Cat        no roll of its own: +extra xMult per Lucky trigger that hit (lucky_trigger,
--                    card.lua 3460, not copyable); the Lucky rolls are Wave 3's.
--   Misprint         joker_main, copies roll: pseudorandom('misprint', min, max) (card.lua 4088).
--   Gros Michel / Cavendish  end_of_round, NOT copyable (`elseif not context.blueprint`,
--                    card.lua 3420): 'gros_michel' 1 in 6 / 'cavendish' 1 in 1000 -> extinct.
--   To Do List       end_of_round, not copyable: next hand = pseudorandom_element(visible hands
--                    except the current one, in pairs(G.GAME.hands) order, 'to_do') (3373).
--   Ancient Joker    the round-end reset (reset_ancient_card, common_events.lua 2667): a suit
--                    other than the current one from 'anc'..ante (ante + 1 after a Boss).
--   Madness          setting_blind, not on a Boss, not copyable: kills a random joker
--                    ('madness', card.lua 2885) -- the shared setting_blind_sim.
--   Invisible Joker  selling_self once ready: copies a random other joker ('invisible', 2753).
--   Perkeo           ending_shop, copies roll: each queues an event that copies a random
--                    consumable as Negative ('perkeo', 2793); later events see earlier copies.
--   Superposition / Seance / Sixth Sense  the Tarot / Spectral they make for the selected hand
--                    (create_card 'sup' / 'sea' / 'sixth'), from Wave 2c's create chain.
-- Not badged: 8 Ball / Hallucination / Riff-raff / Cartomancer / Certificate (Wave 2c banners),
-- Marble Joker (the Stone card's hidden front), Idol / Mail-In Rebate / Castle (the round-end
-- target depends on the deck at round end: cards destroyed or added before then change it).
-- Probability thresholds come from prob_vars (Steamodded's helper: Oops! All 6s and every
-- mod_probability / fix_probability joker). Rolls on different keys never interact, so each key
-- is replayed in the engine's order on its own. Everything runs inside one snapshot.
local BADGE_FLAG = {
  j_space = 'space',
  j_business = 'probabilistic', j_bloodstone = 'probabilistic', j_reserved_parking = 'probabilistic',
  j_lucky_cat = 'lucky_cat', j_misprint = 'misprint',
  j_gros_michel = 'gros_michel', j_cavendish = 'gros_michel',
  j_todo_list = 'todo_ancient', j_ancient = 'todo_ancient',
  j_madness = 'random_pick', j_invisible = 'random_pick', j_perkeo = 'random_pick',
  j_superposition = 'card_makers', j_seance = 'card_makers', j_sixth_sense = 'card_makers',
  -- v0.8.1 (were a centre card / side column + banner)
  j_8_ball = 'eightball', j_vagabond = 'vagabond',
  j_riff_raff = 'riffraff', j_cartomancer = 'cartomancer', j_certificate = 'certificate',
}

-- "$ - $" for up to 5 triggers, else a count
local function roll_text(seq, sym, many)
  if #seq == 0 then return "no roll", 'muted' end
  local hits = 0
  for _, h in ipairs(seq) do if h then hits = hits + 1 end end
  local col = (hits > 0) and 'good' or 'muted'
  if #seq <= 5 then
    local t = {}
    for _, h in ipairs(seq) do t[#t + 1] = h and sym or "-" end
    return table.concat(t, " "), col
  end
  return many(hits, #seq), col
end

-- the round whose end comes next is a Boss round (for 'anc'..ante)
local function next_round_is_boss()
  if G.STATE == G.STATES.SELECTING_HAND then
    return G.GAME.blind and G.GAME.blind.get_type and G.GAME.blind:get_type() == 'Boss'
  end
  if G.STATE == G.STATES.BLIND_SELECT and G.GAME.blind_on_deck then return G.GAME.blind_on_deck == 'Boss' end
  local bs = G.GAME.round_resets.blind_states or {}
  local function gone(x) return x == 'Defeated' or x == 'Skipped' or x == 'Hide' end
  return gone(bs.Small) and gone(bs.Big)
end

-- Does a held card do something on its first trigger without Reserved Parking? (its own held
-- effects: Steel etc., or Baron / Shoot the Moon / Raised Fist). Decides whether it repeats.
local function held_calculates(c, has, raised)
  for _, fn in ipairs({ 'get_chip_h_mult', 'get_chip_h_bonus', 'get_bonus_h_score', 'get_bonus_h_blind_size' }) do
    if type(c[fn]) == 'function' then
      local ok, v = pcall(c[fn], c)
      if ok and type(v) == 'number' and v ~= 0 then return true end
    end
  end
  for _, fn in ipairs({ 'get_chip_h_x_mult', 'get_chip_h_x_bonus', 'get_bonus_h_x_score', 'get_bonus_h_x_blind_size' }) do
    if type(c[fn]) == 'function' then
      local ok, v = pcall(c[fn], c)
      if ok and type(v) == 'number' and v > 0 then return true end
    end
  end
  local id = c:get_id()
  return (has.j_baron and id == 13) or (has.j_shoot_the_moon and id == 12) or (has.j_raised_fist and c == raised) or false
end

-- Predict every badge for the current state. Returns
--   { badges = { {joker=, text=, colour=}, ... }, plus per-joker data for validation } or nil.
function FHUD_peek_joker_badges()
  if not predict_ok() then return nil end
  if not (G.GAME and G.STATES and G.jokers and G.jokers.cards and G.consumeables and G.GAME.round_resets) then return nil end
  local st = G.STATE
  local in_hand = st == G.STATES.SELECTING_HAND and G.hand and G.hand.cards and G.GAME.current_round
  local in_shop = st == G.STATES.SHOP
  local in_sel = st == G.STATES.BLIND_SELECT
  if not (in_hand or in_shop or in_sel) then return nil end
  local jl = G.jokers.cards
  local eff, any = {}, false
  for i, j in ipairs(jl) do
    eff[i] = resolve_joker(j)
    local f = BADGE_FLAG[ckey(eff[i]) or ''] or BADGE_FLAG[ckey(j) or '']
    if f and cfg(f) then any = true end
  end
  if not any then return nil end
  local res = { badges = {}, space = {}, misprint = {}, business = {}, bloodstone = {}, parking = {}, lucky_cat = {},
                gros = {}, todo = {}, ancient = {}, madness = {}, invisible = {}, perkeo = {}, makers = {}, pr = {}, rolls = {} }
  -- every roll per key, in the engine's order (what the validation harness diffs)
  local function push(key, hit) res.rolls[key] = res.rolls[key] or {}; table.insert(res.rolls[key], hit) end
  local function badge(j, text, colour, cards)
    if j.facing == 'back' then return end -- face-down (Amber Acorn): don't reveal which joker it is
    res.badges[#res.badges + 1] = { joker = j, text = text, colour = colour, cards = cards }
  end
  -- copies (Blueprint / Brainstorm) of `key` in row order: { j = the slot, e = the joker it runs as }
  local function slots(key)
    local t = {}
    for i, j in ipairs(jl) do if ckey(eff[i]) == key then t[#t + 1] = { j = j, e = eff[i] } end end
    return t
  end
  -- the joker itself, not debuffed (for the not-copyable ones)
  local function selves(key)
    local t = {}
    for _, j in ipairs(jl) do if not j.debuff and ckey(j) == key then t[#t + 1] = j end end
    return t
  end

  local snap = snapshot_rng()
  local ok, err = pcall(function()
    local hl, plan = {}, nil
    if in_hand then
      for _, c in ipairs(G.hand.cards) do if c.highlighted then hl[#hl + 1] = c end end
      plan = scoring_plan(hl)
      res.text = plan.text
    end
    local dead = plan and #hl > 0 and plan.dead

    ------------------------------------------------ the next played hand (SELECTING_HAND)
    if in_hand then
      res.dead = dead
      -- Space Joker (context.before)
      if cfg('space') then
        for _, sl in ipairs(slots('j_space')) do
          if dead then
            res.space[#res.space + 1] = { joker = sl.j, roll = false }
            badge(sl.j, "no roll", 'muted')
          else
            local n, d = prob_vars(sl.e, (sl.e.ability and sl.e.ability.extra) or 4, 'space')
            local hit = pseudorandom('space') < n / d
            push('space', hit)
            res.space[#res.space + 1] = { joker = sl.j, roll = true, hit = hit }
            badge(sl.j, hit and "LEVEL UP" or "no level", hit and 'good' or 'muted')
          end
        end
        res.pr.space = G.GAME.pseudorandom['space']
      end

      -- per-card scoring (needs the selection): Business Card, Bloodstone, Lucky Cat
      local biz = cfg('probabilistic') and slots('j_business') or {}
      local blood = cfg('probabilistic') and slots('j_bloodstone') or {}
      local park = cfg('probabilistic') and slots('j_reserved_parking') or {}
      local cats = cfg('lucky_cat') and selves('j_lucky_cat') or {}
      local seqs = {}
      for _, list in ipairs({ biz, blood, park }) do for _, sl in ipairs(list) do seqs[sl.j] = {} end end
      if #hl > 0 and not dead and (#biz + #blood + #cats > 0) then
        local views = before_views(plan)
        local lucky_hits, lucky_scoring = 0, 0
        for _, c in ipairs(plan.final) do
          if not c.debuff then
            local v = views[c] or c
            local reps = card_triggers(c, plan, v)
            local face, heart = v:is_face(), v:is_suit('Hearts')
            local lucky = #cats > 0 and not views[c] and c.ability and c.ability.effect == 'Lucky Card'
            local n1, d1, n2, d2
            if lucky then
              lucky_scoring = lucky_scoring + 1
              n1, d1 = prob_vars(c, 5, 'lucky_mult')
              n2, d2 = prob_vars(c, 15, 'lucky_money')
            end
            for _ = 1, reps do
              if lucky then -- Card:get_chip_mult / get_p_dollars, before the jokers (eval_card)
                local m = pseudorandom('lucky_mult') < n1 / d1
                local dd = pseudorandom('lucky_money') < n2 / d2
                push('lucky_mult', m); push('lucky_money', dd)
                if m or dd then lucky_hits = lucky_hits + 1 end
              end
              if face then
                for _, sl in ipairs(biz) do
                  local n, d = prob_vars(sl.e, (sl.e.ability and sl.e.ability.extra) or 2, 'business')
                  local q = seqs[sl.j]
                  q[#q + 1] = pseudorandom('business') < n / d
                  push('business', q[#q])
                end
              end
              if heart then
                for _, sl in ipairs(blood) do
                  local ex = (sl.e.ability and sl.e.ability.extra) or {}
                  local n, d = prob_vars(sl.e, ex.odds or 2, 'bloodstone')
                  local q = seqs[sl.j]
                  q[#q + 1] = pseudorandom('bloodstone') < n / d
                  push('bloodstone', q[#q])
                end
              end
            end
          end
        end
        res.lucky_hits, res.lucky_scoring = lucky_hits, lucky_scoring
        res.pr.lucky_mult, res.pr.lucky_money = G.GAME.pseudorandom['lucky_mult'], G.GAME.pseudorandom['lucky_money']
        for _, j in ipairs(cats) do
          local gain = lucky_hits * ((j.ability and j.ability.extra) or 0.25)
          res.lucky_cat[#res.lucky_cat + 1] = { joker = j, triggers = lucky_hits, gain = gain }
          if lucky_scoring > 0 then
            badge(j, "+" .. string.format("%g", gain) .. "x", (gain > 0) and 'good' or 'muted')
          end
        end
      end

      -- Reserved Parking: the cards still HELD when the hand scores
      if #hl > 0 and not dead and #park > 0 then
        local held = {}
        for _, c in ipairs(G.hand.cards) do if not c.highlighted then held[#held + 1] = c end end
        local bl = G.GAME.blind
        local hook_unknown = false
        if bl and not bl.disabled and bl.name == 'The Hook' then
          local obj = bl.config and bl.config.blind
          if obj and type(obj.press_play) == 'function' then
            hook_unknown = true
          else
            -- Blind:press_play (blind.lua 509-529): up to 2 random held cards are discarded first
            local pool = {}
            for _, c in ipairs(held) do pool[#pool + 1] = c end
            local gone = {}
            for i = 1, 2 do
              if held[i] then
                local sel, key = pseudorandom_element(pool, pseudoseed('hook'))
                table.remove(pool, key)
                if sel then gone[sel] = true end
              end
            end
            local keep = {}
            for _, c in ipairs(held) do if not gone[c] then keep[#keep + 1] = c end end
            held = keep
            res.hook = gone
          end
        end
        res.hook_unknown = hook_unknown
        if hook_unknown then
          for _, sl in ipairs(park) do badge(sl.j, "? (The Hook)", 'muted') end
        else
          -- Raised Fist's card: the last held card with the lowest base id (card.lua 3713)
          local raised, tid = nil, 15
          for _, c in ipairs(held) do
            if tid >= c.base.id and not SMODS.has_no_rank(c) then tid = c.base.id; raised = c end
          end
          local has, mimes = {}, 0
          for i in ipairs(jl) do
            local k = ckey(eff[i])
            if k then has[k] = true end
            if k == 'j_mime' then mimes = mimes + ((eff[i].ability and eff[i].ability.extra) or 1) end
          end
          for _, c in ipairs(held) do
            if not c.debuff and c:is_face() then
              local other = held_calculates(c, has, raised)
              local total, t = 1, 1
              while t <= total do
                local calc = other
                for _, sl in ipairs(park) do
                  local ex = (sl.e.ability and sl.e.ability.extra) or {}
                  local n, d = prob_vars(sl.e, ex.odds or 2, 'parking')
                  local hit = pseudorandom('parking') < n / d
                  push('parking', hit)
                  local q = seqs[sl.j]
                  q[#q + 1] = hit
                  if hit then calc = true end
                end
                if t == 1 and calc then total = 1 + ((c.seal == 'Red') and 1 or 0) + mimes end
                if not calc then break end
                t = t + 1
              end
            end
          end
        end
      end
      if #hl > 0 then
        for _, sl in ipairs(biz) do
          local q = seqs[sl.j]
          res.business[#res.business + 1] = { joker = sl.j, seq = q }
          if dead then badge(sl.j, "no roll", 'muted') else
            local t, col = roll_text(q, "$", function(h, n) return "+$" .. (2 * h) .. " (" .. h .. "/" .. n .. ")" end)
            badge(sl.j, t, col)
          end
        end
        for _, sl in ipairs(blood) do
          local q = seqs[sl.j]
          res.bloodstone[#res.bloodstone + 1] = { joker = sl.j, seq = q }
          if dead then badge(sl.j, "no roll", 'muted') else
            local t, col = roll_text(q, "X", function(h, n) return h .. "/" .. n .. " X" end)
            badge(sl.j, t, col)
          end
        end
        for _, sl in ipairs(park) do
          local q = seqs[sl.j]
          local dol = ((sl.e.ability and sl.e.ability.extra) or {}).dollars or 1
          res.parking[#res.parking + 1] = { joker = sl.j, seq = q }
          if dead then badge(sl.j, "no roll", 'muted')
          elseif not res.hook_unknown then
            local t, col = roll_text(q, "$", function(h, n) return "+$" .. (dol * h) .. " (" .. h .. "/" .. n .. ")" end)
            badge(sl.j, t, col)
          end
        end
      end
      res.pr.business = G.GAME.pseudorandom['business']
      res.pr.bloodstone = G.GAME.pseudorandom['bloodstone']
      res.pr.parking = G.GAME.pseudorandom['parking']

      -- Superposition / Seance / Sixth Sense: the card they make (the 2c chain: shares the room and
      -- the pool culling with 8 Ball / Vagabond, in queue order)
      local mk, e8, ev = false, false, false
      for i in ipairs(jl) do
        local k = ckey(eff[i])
        if k == 'j_superposition' or k == 'j_seance' or k == 'j_sixth_sense' then mk = true end
        if k == 'j_8_ball' then e8 = true end
        if k == 'j_vagabond' then ev = true end
      end
      mk = mk and cfg('card_makers') and #hl > 0 and not dead
      local any8 = e8 -- an 8 Ball plays whether or not its badge is on (Vagabond's "?")
      e8 = e8 and cfg('eightball')
      ev = ev and cfg('vagabond')
      local hg = (mk or e8 or ev) and FHUD_peek_hand_gen(false, true) or nil
      res.hand_gen = hg

      -- v0.8.1: 8 Ball (per scored 8, per trigger) and Vagabond, as badges on the joker
      if hg and e8 and #hl > 0 and (hg.n8_sel or 0) > 0 then
        local key_of = {}
        for _, cr in ipairs(hg.creates or {}) do if cr.roll then key_of[cr.roll] = cr.key end end
        for _, sl in ipairs(slots('j_8_ball')) do
          if hg.hand_dead then badge(sl.j, "no roll", 'muted')
          elseif hg.n8 == 0 then badge(sl.j, "8 won't score", 'muted')
          else
            local parts, hits, cards = {}, 0, {}
            for ri, r in ipairs(hg.rolls or {}) do
              if r.joker == sl.j then
                if r.full then parts[#parts + 1] = "no room"
                elseif r.hit then
                  hits = hits + 1
                  parts[#parts + 1] = "+" .. (key_of[ri] and short_name(key_of[ri]) or "?")
                  if key_of[ri] then cards[#cards + 1] = { key = key_of[ri] } end
                else parts[#parts + 1] = "-" end
              end
            end
            if #parts > 3 then
              local hp = {}
              for _, p in ipairs(parts) do if p:sub(1, 1) == "+" then hp[#hp + 1] = p end end
              hp[#hp + 1] = "(" .. hits .. "/" .. #parts .. ")"
              parts = hp
            end
            if #parts > 0 then badge(sl.j, table.concat(parts, " "), (hits > 0) and 'good' or 'muted', cards) end
          end
        end
      end
      if ev then
        local vag_key = {}
        for _, cr in ipairs((hg and hg.creates) or {}) do if cr.who == 'vag' and cr.joker then vag_key[cr.joker] = cr.key end end
        -- nothing selected: another joker (8 Ball, Superposition...) may still take the room first
        local unsure = (#hl == 0 and hg and (hg.unknown_other or any8)) or (hg and hg.tooth)
        for _, sl in ipairs(slots('j_vagabond')) do
          if dead or (hg and hg.hand_dead) then badge(sl.j, "no roll", 'muted')
          elseif vag_key[sl.j] then
            badge(sl.j, "+" .. short_name(vag_key[sl.j]) .. (unsure and "?" or ""), 'good', { { key = vag_key[sl.j] } })
          elseif hg and hg.vag_full_slots and hg.vag_full_slots[sl.j] then badge(sl.j, "no room", 'muted')
          elseif hg and hg.dollars then badge(sl.j, "no card ($" .. tostring(hg.dollars) .. ")", 'muted') end
        end
      end

      if mk then
        for _, cr in ipairs((hg and hg.creates) or {}) do
          if cr.joker and (cr.who == 'sup' or cr.who == 'sea' or cr.who == 'sixth') then
            res.makers[#res.makers + 1] = { joker = cr.joker, key = cr.key, who = cr.who }
            badge(cr.joker, "+" .. short_name(cr.key), 'good', { { key = cr.key } })
          end
        end
        for _, j in ipairs((hg and hg.makers_full) or {}) do
          res.makers[#res.makers + 1] = { joker = j, full = true }
          badge(j, "no room", 'muted')
        end
      end

      -- Misprint (joker_main)
      if cfg('misprint') then
        for _, sl in ipairs(slots('j_misprint')) do
          if dead then
            res.misprint[#res.misprint + 1] = { joker = sl.j }
            badge(sl.j, "no roll", 'muted')
          else
            local ex = (sl.e.ability and sl.e.ability.extra) or {}
            local v = pseudorandom('misprint', ex.min or 0, ex.max or 23)
            push('misprint', v)
            res.misprint[#res.misprint + 1] = { joker = sl.j, value = v }
            badge(sl.j, "+" .. v .. " Mult", 'info')
          end
        end
        res.pr.misprint = G.GAME.pseudorandom['misprint']
      end
    end

    ------------------------------------------------ the next round end (any of the 3 states)
    if cfg('gros_michel') or cfg('todo_ancient') then
      for _, j in ipairs(jl) do
        if not j.debuff then
          local k = ckey(j)
          if (k == 'j_gros_michel' or k == 'j_cavendish') and cfg('gros_michel') then
            local key = (k == 'j_cavendish') and 'cavendish' or 'gros_michel'
            local ex = (j.ability and j.ability.extra) or {}
            local n, d = prob_vars(j, ex.odds or ((k == 'j_cavendish') and 1000 or 6), key)
            local gone = pseudorandom(key) < n / d
            push(key, gone)
            res.gros[#res.gros + 1] = { joker = j, key = key, extinct = gone }
            badge(j, gone and "EXTINCT" or "survives", gone and 'bad' or 'good')
          elseif k == 'j_todo_list' and cfg('todo_ancient') then
            local cur = j.ability and j.ability.to_do_poker_hand
            local pool = {}
            for name in pairs(G.GAME.hands) do
              -- a hand becomes visible when it is played (state_events.lua 624)
              local vis = SMODS.is_poker_hand_visible(name) or (in_hand and #hl > 0 and name == res.text)
              if vis and name ~= cur then pool[#pool + 1] = name end
            end
            local pick = pseudorandom_element(pool, pseudoseed('to_do'))
            res.todo[#res.todo + 1] = { joker = j, hand = pick }
            if pick then
              local okh, hn = pcall(localize, pick, 'poker_hands')
              badge(j, "next: " .. ((okh and type(hn) == 'string' and hn ~= 'ERROR') and hn or pick), 'info')
            end
          end
        end
      end
      res.pr.gros_michel = G.GAME.pseudorandom['gros_michel']
      res.pr.cavendish = G.GAME.pseudorandom['cavendish']
      res.pr.to_do = G.GAME.pseudorandom['to_do']
      -- then the ROUND_EVAL resets (after ease_ante when a Boss was beaten)
      local anc = cfg('todo_ancient') and {} or nil
      if anc then
        for _, j in ipairs(jl) do if ckey(j) == 'j_ancient' then anc[#anc + 1] = j end end
      end
      if anc and #anc > 0 then
        local ante = G.GAME.round_resets.ante + (next_round_is_boss() and 1 or 0)
        local cur = G.GAME.current_round.ancient_card and G.GAME.current_round.ancient_card.suit
        local suits = {}
        for _, v in ipairs({ 'Spades', 'Hearts', 'Clubs', 'Diamonds' }) do if v ~= cur then suits[#suits + 1] = v end end
        local pick = pseudorandom_element(suits, pseudoseed('anc' .. ante))
        res.ancient_ante = ante
        for _, j in ipairs(anc) do
          res.ancient[#res.ancient + 1] = { joker = j, suit = pick }
          badge(j, "next: " .. loc_or(pick, 'suits_plural'), 'info')
        end
      end
    end

    ------------------------------------------------ blind select: Riff-raff / Cartomancer / Certificate
    -- v0.8.1: the Wave 2c chain (FHUD_peek_blind_gen, its own dry-run; no key shared with the
    -- rolls above), as badges; the cards show while the joker is hovered.
    if in_sel then
      local want = { j_riff_raff = cfg('riffraff'), j_cartomancer = cfg('cartomancer'), j_certificate = cfg('certificate') }
      local need = false
      for i in ipairs(jl) do if want[ckey(eff[i]) or ''] then need = true end end
      local bg = need and FHUD_peek_blind_gen(false) or nil
      res.blind_gen = bg
      if bg then
        local per = {}
        local function add(j, txt, card, cert)
          per[j] = per[j] or { txt = {}, cards = {} }
          per[j].txt[#per[j].txt + 1] = txt
          per[j].cards[#per[j].cards + 1] = card
          if cert then per[j].cert = true end
        end
        if want.j_riff_raff then
          for _, r in ipairs(bg.riff) do if r.joker then add(r.joker, "+" .. short_name(r.key), { key = r.key, edkey = r.edkey }) end end
        end
        if want.j_cartomancer then
          for _, r in ipairs(bg.cart) do if r.joker then add(r.joker, "+" .. short_name(r.key), { key = r.key }) end end
        end
        if want.j_certificate then
          local RS = { Ace = "A", King = "K", Queen = "Q", Jack = "J" }
          for _, r in ipairs(bg.cert) do
            if r.joker and r.front then
              local f = r.front
              local nm = (RS[f.value] or tostring(f.value)) .. " " .. loc_or(f.suit, 'suits_plural')
              add(r.joker, "+" .. nm .. (r.seal and (" " .. r.seal) or ""), { front = f, seal = r.seal }, true)
            end
          end
        end
        -- v0.8.1 final: `or per[j]` -- a Blueprint whose right neighbour is sliced (Madness / Dagger)
        -- copies the joker after it at the first draw, e.g. a Certificate: it makes a card even
        -- though it copies something else right now
        for i, j in ipairs(jl) do
          local k = ckey(eff[i])
          if want[k or ''] or per[j] then
            local p = per[j]
            if p then
              badge(j, table.concat(p.txt, " ") .. ((bg.cert_uncertain and p.cert) and "?" or ""), 'good', p.cards)
            elseif bg.full_slots and bg.full_slots[j] then
              badge(j, "no room", 'muted')
            elseif bg.sliced and bg.sliced[j] then
              badge(j, "sliced", 'bad')
            end
          end
        end
      end
    end

    ------------------------------------------------ blind select: Madness
    if in_sel and cfg('random_pick') and #selves('j_madness') > 0 then
      local boss = on_deck_is_boss()
      if boss then
        for _, j in ipairs(selves('j_madness')) do badge(j, "no roll (Boss)", 'muted') end
      else
        local sim = setting_blind_sim(false)
        for _, m in ipairs(sim.madness) do
          res.madness[#res.madness + 1] = { joker = m.joker, victim = m.victim }
          badge(m.joker, m.victim and ("kills " .. center_name(ckey(m.victim))) or "no target", m.victim and 'bad' or 'muted')
        end
        res.pr.madness = G.GAME.pseudorandom['madness']
      end
    end

    ------------------------------------------------ any time: Invisible Joker (if sold now)
    if cfg('random_pick') then
      for _, j in ipairs(selves('j_invisible')) do
        local ab = j.ability or {}
        if (ab.invis_rounds or 0) >= (ab.extra or 2) then
          local others = {}
          for _, o in ipairs(jl) do if o ~= j then others[#others + 1] = o end end
          if #others == 0 then
            badge(j, "sell: nothing", 'muted')
          elseif #jl > G.jokers.config.card_limit then
            badge(j, "sell: no room", 'muted')
          else
            -- each Invisible is sold on its own: its own sub-run from the same state
            local sub = snapshot_rng()
            local pick = pseudorandom_element(others, pseudoseed('invisible'))
            restore_rng(sub)
            res.invisible[#res.invisible + 1] = { joker = j, pick = pick }
            if pick then badge(j, "sell: +" .. center_name(ckey(pick)), 'good') end
          end
        end
      end
    end

    ------------------------------------------------ shop: Perkeo (when you leave)
    if in_shop and cfg('random_pick') then
      local perk = slots('j_perkeo')
      if #perk > 0 then
        if not G.consumeables.cards[1] then
          for _, sl in ipairs(perk) do badge(sl.j, "leave: nothing", 'muted') end
        else
          local pool, top = {}, 0
          for _, c in ipairs(G.consumeables.cards) do
            pool[#pool + 1] = { sort_id = c.sort_id or 0, key = ckey(c) }
            top = math.max(top, c.sort_id or 0)
          end
          for i, sl in ipairs(perk) do
            local pick = pseudorandom_element(pool, pseudoseed('perkeo'))
            -- the Negative copy is emplaced before the next Perkeo's event picks
            pool[#pool + 1] = { sort_id = top + i, key = pick and pick.key }
            res.perkeo[#res.perkeo + 1] = { joker = sl.j, key = pick and pick.key }
            if pick then badge(sl.j, "leave: +" .. short_name(pick.key), 'good') end
          end
        end
      end
    end
  end)
  restore_rng(snap)
  if not ok then
    FHUD.badge_last_err = tostring(err)
    if not FHUD.badge_err_logged then
      FHUD.badge_err_logged = true
      print("[ForesightHUD] joker-badge preview failed: " .. tostring(err))
    end
    return nil
  end
  return res
end

function FHUD_badge_destroy()
  FHUD.joker_badge_items = nil
  FHUD.badge_sig = nil
end

local BADGE_FLAGS = { 'space', 'probabilistic', 'lucky_cat', 'misprint', 'gros_michel', 'todo_ancient', 'random_pick',
                      'card_makers', 'eightball', 'vagabond', 'riffraff', 'cartomancer', 'certificate' }
local function badge_sig()
  local g = G.GAME
  local rr, cr = g.round_resets or {}, g.current_round or {}
  local pr, s = g.pseudorandom, 0
  for _, v in pairs(pr or {}) do if type(v) == 'number' then s = s + v end end
  local bl = g.blind
  local nvis = 0
  for _, v in pairs(g.hands or {}) do if v.visible then nvis = nvis + 1 end end
  local bs = rr.blind_states or {}
  local fl = {}
  for _, f in ipairs(BADGE_FLAGS) do fl[#fl + 1] = tostring(cfg(f)) end
  local t = { tostring(G.STATE), string.format("%.12f", s), tostring(rr.ante), tostring(bl and bl.name),
    tostring(bl and bl.disabled), tostring(g.probabilities and g.probabilities.normal), tostring(cr.hands_left),
    tostring(g.blind_on_deck), tostring(bs.Small) .. tostring(bs.Big) .. tostring(bs.Boss),
    tostring(rr.blind_choices and g.blind_on_deck and rr.blind_choices[g.blind_on_deck]),
    tostring(cr.ancient_card and cr.ancient_card.suit), tostring(nvis), table.concat(fl, ""),
    -- v0.8.1 Vagabond / 8 Ball: money, room, The Ox
    tostring(g.dollars), tostring(g.consumeable_buffer), tostring(g.joker_buffer), tostring(cr.most_played_poker_hand) }
  local areas = { G.jokers, G.consumeables, (G.STATE == G.STATES.SELECTING_HAND) and G.hand or nil }
  for ai = 1, 3 do
    local a = areas[ai]
    if a and a.cards then
      t[#t + 1] = #a.cards .. "/" .. tostring(a.config and a.config.card_limit)
      for _, c in ipairs(a.cards) do
        local ab = c.ability or {}
        t[#t + 1] = tostring(c.sort_id) .. tostring(ckey(c)) .. (c.debuff and "d" or "") .. tostring(c.facing)
            .. ((ai == 1) and (tostring(ab.invis_rounds) .. tostring(ab.to_do_poker_hand) .. (ab.eternal and "e" or "")
              .. (c.getting_sliced and "s" or "")) or "")
            .. ((ai == 3) and (tostring(c.base and c.base.id) .. tostring(c.base and c.base.suit) .. tostring(c.seal)
              .. (c.highlighted and "h" or "")) or "")
      end
    end
  end
  return table.concat(t, ",")
end

-- Wave 5: the top / bottom banners (love.draw), as positioned boxes: { t, x, y, tw, th, sx, colour,
-- warn, rect = {x, y, w, h} }. Shared by love.draw (drawing) and the joker badges (avoidance).
function FHUD_banner_layout(W, H, font)
  local items = {}
  if FHUD.version_ok == false then
    items[#items + 1] = { t = "ForesightHUD: predictions off (needs Balatro 1.0.1o)", top = true, warn = true }
  end
  if FHUD.con_label then items[#items + 1] = { t = FHUD.con_label, top = true } end
  if FHUD.pack_label then items[#items + 1] = { t = FHUD.pack_label, top = true } end
  if FHUD.halu_label then items[#items + 1] = { t = FHUD.halu_label, top = true } end
  for _, l in ipairs(FHUD.gen_lines or {}) do items[#items + 1] = { t = l, top = FHUD.gen_top and true or false } end
  for _, it in ipairs(FHUD.overlay_items or {}) do items[#items + 1] = it end
  local out = {}
  if #items == 0 then return out end
  -- target a line height of ~2.6% of the window regardless of font size.
  local sx = (H * 0.026) / math.max(font:getHeight(), 1)
  -- several banners can be up at once (v0.5.0): stack top ones downward and
  -- bottom ones upward; a single banner sits exactly where it always did.
  local ntop, nbot = 0, 0
  for _, l in ipairs(items) do
    local tw = font:getWidth(l.t) * sx
    local th = font:getHeight() * sx
    local x = l.abs and l.x or (W - tw) / 2
    local y
    if l.abs then
      y = l.y
    elseif l.top then
      y = H * 0.08 + ntop * (th + 18); ntop = ntop + 1
    else
      y = H * 0.72 - nbot * (th + 18); nbot = nbot + 1
    end
    out[#out + 1] = { t = l.t, x = x, y = y, tw = tw, th = th, sx = sx, colour = l.colour, warn = l.warn,
                      rect = { x - 12, y - 7, tw + 24, th + 14 } }
  end
  return out
end

-- Everything a joker badge must not cover, in window pixels: banners, our preview card rows,
-- hand tags, blind-strip boxes. { {x, y, w, h, what}, ... }
function FHUD_badge_obstacles(W, H, font)
  local out = {}
  for _, b in ipairs(FHUD_banner_layout(W, H, font)) do
    out[#out + 1] = { b.rect[1], b.rect[2], b.rect[3], b.rect[4], "banner" }
  end
  if G.ROOM and G.TILESCALE and G.TILESIZE then
    local s = G.TILESCALE * G.TILESIZE
    local ox, oy = G.ROOM.T.x, G.ROOM.T.y
    local areas = { FHUD.shoparea, FHUD.packarea, FHUD.conarea, FHUD.area, FHUD.genarea, FHUD.bh_area }
    for _, a in ipairs(FHUD.genareas or {}) do areas[#areas + 1] = a end
    for i = 1, #areas + 5 do
      local a = areas[i]
      if a and a.cards and #a.cards > 0 then
        -- the cards as drawn (the area box is taller than its scaled-down copies)
        local x0, y0, x1, y1
        for _, c in ipairs(a.cards) do
          local T = c.VT or c.T
          if T then
            x0 = math.min(x0 or T.x, T.x); y0 = math.min(y0 or T.y, T.y)
            x1 = math.max(x1 or (T.x + T.w), T.x + T.w); y1 = math.max(y1 or (T.y + T.h), T.y + T.h)
          end
        end
        if x0 then out[#out + 1] = { (x0 + ox) * s, (y0 + oy) * s, (x1 - x0) * s, (y1 - y0) * s, "preview" } end
      end
    end
  end
  if G.STATE == G.STATES.SELECTING_HAND and FHUD.hand_tag_items then
    for _, b in ipairs(FHUD_hand_tag_layout(W, H, font)) do out[#out + 1] = { b.x, b.y, b.w, b.h, "hand tag" } end
  end
  if G.STATE == G.STATES.BLIND_SELECT and FHUD.strip_items then
    local cut = FHUD.strip_cut
    for _, b in ipairs(FHUD_blind_strip_layout(W, H, font)) do out[#out + 1] = { b.x, b.y, b.w, b.h, "strip" } end
    FHUD.strip_cut = cut
  end
  return out
end

local function rect_hit(x, y, w, h, r)
  return x < r[1] + r[3] and r[1] < x + w and y < r[2] + r[4] and r[2] < y + h
end

-- Wave 5: where each joker badge goes, in window pixels (the hand tags' mapping:
-- (VT + G.ROOM.T) * G.TILESCALE * G.TILESIZE, from the ANIMATED transform, so a badge rides
-- along when the row slides, is reordered or a joker is dragged). Jokers overlap when the row is
-- crowded and later ones are drawn on top, so a badge is centred on its joker's VISIBLE strip and
-- is never wider than it. It straddles the joker's bottom edge (about a third on the card's
-- lower border, the rest below); if that touches a banner, one of our preview rows, a hand tag or
-- a blind-strip box, it tries just below the joker, then inside its lower edge, then above it.
-- A badge under the tooltip of the hovered card is skipped (the game draws tooltips under us).
-- Returns { {x, y, w, h, sc, lh, pad, lines, joker, strip, spot}, ... }.
function FHUD_joker_badge_layout(W, H, font, obstacles)
  local items = FHUD.joker_badge_items
  if not (items and #items > 0 and font and G.jokers and G.jokers.cards and G.ROOM and G.TILESCALE and G.TILESIZE) then
    return {}
  end
  local s = G.TILESCALE * G.TILESIZE
  local ox, oy = G.ROOM.T.x, G.ROOM.T.y
  local by, order = {}, {}
  for _, it in ipairs(items) do
    local c = it.joker
    if c and not c.removed and c.area == G.jokers and c.VT and not (c.states and c.states.visible == false) then
      if not by[c] then by[c] = {}; order[#order + 1] = c end
      by[c][#by[c] + 1] = it
    end
  end
  local strip = visible_strips(G.jokers.cards, ox, s)
  obstacles = obstacles or FHUD_badge_obstacles(W, H, font)
  local pop
  pcall(function()
    local tgt = G.CONTROLLER and G.CONTROLLER.hovering and G.CONTROLLER.hovering.target
    local hp = tgt and tgt.children and tgt.children.h_popup
    local T = hp and (hp.VT or hp.T)
    if T then pop = { (T.x + ox) * s, (T.y + oy) * s, T.w * s, T.h * s } end
  end)
  local base = (H * 0.017) / math.max(font:getHeight(), 1)
  local pad = 3
  local out = {}
  for _, c in ipairs(order) do
    local st = strip[c] or { (c.VT.x + ox) * s, (c.VT.x + c.VT.w + ox) * s }
    local avail = math.max(st[2] - st[1] - 2 * pad - 2, 16)
    local lines, sc, tw, lh = wrap_tag_lines(by[c], avail, font, base)
    local w, h = tw + 2 * pad, #lines * lh + 2 * pad
    local x = (st[1] + st[2]) / 2 - w / 2
    local top, bot = (c.VT.y + oy) * s, (c.VT.y + c.VT.h + oy) * s
    local spots = { { "edge", bot - h * 0.35 }, { "below", bot + 3 }, { "inside", bot - h - 3 }, { "above", top - h - 3 } }
    local y, spot
    for _, sp in ipairs(spots) do
      local yy = sp[2]
      local clear = yy >= 0 and yy + h <= H
      if clear then
        for _, r in ipairs(obstacles) do if rect_hit(x, yy, w, h, r) then clear = false; break end end
      end
      if clear then y, spot = yy, sp[1]; break end
    end
    if not y then y, spot = spots[1][2], "edge*" end -- nothing is free: keep the default spot
    if not (pop and rect_hit(x, y, w, h, pop)) then
      out[#out + 1] = { x = x, y = y, w = w, h = h, sc = sc, lh = lh, pad = pad, lines = lines, joker = c, strip = st,
                        spot = spot }
    end
  end
  return out
end

-- Builds/caches the joker badges (SELECTING_HAND / SHOP / BLIND_SELECT).
function FHUD_badge_tick()
  local st = G.STATE
  local live = st == G.STATES.SELECTING_HAND or st == G.STATES.SHOP or st == G.STATES.BLIND_SELECT
  if not live or not predict_ok() or not (G.jokers and G.jokers.cards and #G.jokers.cards > 0) then
    if FHUD.joker_badge_items or FHUD.badge_sig then FHUD_badge_destroy() end
    return
  end
  local sig = badge_sig()
  if sig == FHUD.badge_sig then return end
  FHUD.badge_sig = sig
  FHUD.joker_badge_items = {}
  local r = FHUD_peek_joker_badges()
  for _, b in ipairs((r and r.badges) or {}) do FHUD.ui.joker_badge(b.joker, b.text, b.colour, b.cards) end
end

-- v0.8.1: hovering a joker whose badge names cards (8 Ball, Vagabond, Riff-raff, Cartomancer,
-- Certificate, Superposition, Seance, Sixth Sense) shows them as sprites beside it (the game's
-- own tooltip sits below the joker). Built from the badge's recipes inside a dry-run (a new
-- Card's set_ability can roll, and marks used_jokers), cached per (joker, badge state).
function FHUD_badge_hover_destroy()
  if FHUD.bh_area then kill_area(FHUD.bh_area) end
  FHUD.bh_area, FHUD.bh_joker, FHUD.bh_sig = nil, nil, nil
end

local function recipe_copy(rc, scale)
  if rc.front then
    local cp = new_card_copy(rc.front, G.P_CENTERS.c_base, scale)
    if cp and rc.seal then pcall(function() cp:set_seal(rc.seal, true, true) end) end
    return cp
  end
  local center = rc.key and G.P_CENTERS[rc.key]
  if not center then return nil end
  local cp = new_card_copy(nil, center, scale)
  if cp and rc.edkey then pcall(function() cp:set_edition(rc.edkey, true, true) end) end
  return cp
end

function FHUD_badge_hover_tick()
  local tgt = G.CONTROLLER and G.CONTROLLER.hovering and G.CONTROLLER.hovering.target
  local dragging = G.CONTROLLER and G.CONTROLLER.dragging and G.CONTROLLER.dragging.target
  local cards
  if tgt and not dragging and G.jokers and tgt.area == G.jokers and FHUD.joker_badge_items and predict_ok() then
    for _, it in ipairs(FHUD.joker_badge_items) do
      if it.joker == tgt and it.cards and #it.cards > 0 then
        cards = cards or {}
        for _, rc in ipairs(it.cards) do cards[#cards + 1] = rc end
      end
    end
  end
  if not cards then
    if FHUD.bh_area or FHUD.bh_joker then FHUD_badge_hover_destroy() end
    return
  end
  if FHUD.bh_joker ~= tgt or FHUD.bh_sig ~= FHUD.badge_sig or not FHUD.bh_area then
    FHUD_badge_hover_destroy()
    local copies = {}
    local snap = snapshot_rng()
    dry_env(function()
      for _, rc in ipairs(cards) do
        local cp = recipe_copy(rc, 0.55)
        if cp then copies[#copies + 1] = cp end
      end
    end)
    restore_rng(snap)
    if #copies == 0 then return end
    FHUD.bh_area = FHUD.ui.popover_area(copies, tgt, 0.55, 0.2)
    FHUD.bh_joker, FHUD.bh_sig = tgt, FHUD.badge_sig
  end
  -- beside the joker (right, or left at the screen edge); follows it while the row moves
  local a, T = FHUD.bh_area, tgt.T
  local x = T.x + T.w + 0.15
  if x + a.T.w > G.ROOM.T.w - 0.1 then x = T.x - a.T.w - 0.15 end
  local y = T.y + (T.h - a.T.h) / 2
  if a.T.x ~= x or a.T.y ~= y then
    a.T.x, a.T.y = x, y
    if a.align_cards then a:align_cards() end
  end
end

----------------------------------------------------------------- orphan sweep
-- Safety net: the game draws EVERY card in G.I.CARD that has no parent, every frame,
-- so a display copy that never reached an area is a stray card stuck on screen for
-- the rest of the session. Remove any of ours that is not in an area (pack-map
-- templates are hidden and owned by FHUD_pack_map_clear, so they are skipped).
function FHUD_sweep_orphans()
  if not (G and G.I and G.I.CARD) then return end
  local dead = {}
  for _, c in pairs(G.I.CARD) do
    if c.fhud_copy and not c.fhud_template and not c.area then dead[#dead + 1] = c end
  end
  if #dead > 0 then
    keep_used(function() for _, c in ipairs(dead) do if c.remove then c:remove() end end end)
  end
end

----------------------------------------------------------------- tick
function FHUD_tick()
  FHUD.overlay_items = {}

  -- Copies are created and emplaced in the same tick, so anything still unparented
  -- from earlier frames is a leak. Throttled; cheap either way.
  do
    local now = (G and G.TIMERS and G.TIMERS.REAL) or 0
    if now - (FHUD.sweep_t or 0) > 0.5 then
      FHUD.sweep_t = now
      pcall(FHUD_sweep_orphans)
    end
  end

  if not (G and G.GAME and G.STATES and G.deck and G.deck.cards) then
    if FHUD.area then FHUD_destroy() end
    if FHUD.shoparea then FHUD_shop_destroy() end
    if FHUD.conarea or FHUD.con_label then FHUD_con_destroy() end
    if FHUD.pack_map then FHUD_pack_map_clear() end
    if FHUD.genarea or FHUD.gen_lines or FHUD.gen_sig then FHUD_gen_destroy() end
    if FHUD.hand_tag_items or FHUD.tag_sig then FHUD_tag_destroy() end
    if FHUD.strip_items or FHUD.strip_sig then FHUD_strip_destroy() end
    if FHUD.joker_badge_items or FHUD.badge_sig then FHUD_badge_destroy() end
    if FHUD.bh_area or FHUD.bh_joker then FHUD_badge_hover_destroy() end
    FHUD.lucky_label = nil
    return
  end

  -- one-time version gate: predictions only run on the calibrated version.
  if FHUD.version_ok == nil then
    local v = G.VERSION
    if type(v) == 'string' and v ~= '' then
      if v:find('1.0.1o', 1, true) then
        FHUD.version_ok = true
      else
        FHUD.version_ok = false
      end
    end
  end

  -- v0.7.1: paused (options / run info / deck view / collection, game over...): FREEZE.
  -- Nothing is built, refreshed or torn down, and no cache key moves, so the previews you
  -- had are the ones you get back (a dry-run now would read math.random(), see predict_ok).
  if not FHUD_rng_live() then return end

  local st = G.STATE

  -- Wheel / Emperor / Priestess / Lucky peeks (any state, hover-driven).
  local special_active = false
  do
    local ok_sp, r_sp = pcall(FHUD_special_tick)
    if ok_sp then special_active = r_sp end
  end

  -- Wave 2c: 8 Ball / Vagabond (selected hand), Riff-raff / Cartomancer / Certificate
  -- (blind select). Cached per state signature.
  do
    local ok_g, e_g = pcall(FHUD_gen_tick, special_active)
    if not ok_g then
      pcall(FHUD_gen_destroy)
      if not FHUD.gen_err_logged then
        FHUD.gen_err_logged = true
        print("[ForesightHUD] generator preview error: " .. tostring(e_g))
      end
    end
  end

  -- Wave 3: Glass / Lucky / Purple / Blue seal tags under hand cards (cached per state).
  do
    local ok_t, e_t = pcall(FHUD_tag_tick)
    if not ok_t then
      pcall(FHUD_tag_destroy)
      if not FHUD.tag_err_logged then
        FHUD.tag_err_logged = true
        print("[ForesightHUD] hand-tag error: " .. tostring(e_t))
      end
    end
  end

  -- Wave 4: upcoming bosses + skip-tag rewards in the blind panels (cached per state).
  do
    local ok_b, e_b = pcall(FHUD_strip_tick)
    if not ok_b then
      pcall(FHUD_strip_destroy)
      if not FHUD.strip_err_logged then
        FHUD.strip_err_logged = true
        print("[ForesightHUD] blind-strip error: " .. tostring(e_b))
      end
    end
  end

  -- Wave 5: joker badges (Space, Business Card, Gros Michel, Madness...), cached per state.
  do
    local ok_j, e_j = pcall(FHUD_badge_tick)
    if not ok_j then
      pcall(FHUD_badge_destroy)
      if not FHUD.badge_err_logged then
        FHUD.badge_err_logged = true
        print("[ForesightHUD] joker-badge error: " .. tostring(e_j))
      end
    end
    -- v0.8.1: the cards a hovered joker's badge names
    local ok_h, e_h = pcall(FHUD_badge_hover_tick)
    if not ok_h then
      pcall(FHUD_badge_hover_destroy)
      if not FHUD.bh_err_logged then
        FHUD.bh_err_logged = true
        print("[ForesightHUD] badge-hover error: " .. tostring(e_h))
      end
    end
  end

  if st == G.STATES.SELECTING_HAND and cfg('upcoming_draws') then
    local sig = top_sig()
    if sig ~= FHUD.sig or not FHUD.area then FHUD.sig = sig; FHUD_refresh() end
  else
    if FHUD.area then FHUD_destroy() end
  end

  -- the reroll-chain lives in a modal overlay (R), independent of these previews.
  if FHUD.chain_open and not G.OVERLAY_MENU then FHUD.chain_open = false end

  if st == G.STATES.SHOP and G.shop_jokers and special_active then
    -- Inspecting a consumable (wheel/emperor/priestess) -> hide the reroll preview.
    if FHUD.shoparea then FHUD_shop_destroy() end
    if FHUD.packarea then FHUD_pack_destroy() end
  elseif st == G.STATES.SHOP and G.shop_jokers then
    -- which booster pack is hovered?
    local hov = nil
    if cfg('pack_hover') then
      local tgt = G.CONTROLLER and G.CONTROLLER.hovering and G.CONTROLLER.hovering.target
      if G.shop_booster and G.shop_booster.cards then
        for _, p in ipairs(G.shop_booster.cards) do
          if p == tgt or (p.states and p.states.hover and p.states.hover.is) then hov = p; break end
        end
      end
    end
    local now = (G.TIMERS and G.TIMERS.REAL) or 0
    if hov then
      if FHUD.shoparea then FHUD_shop_destroy() end
      FHUD.pack_hold = now + 2.5
      if FHUD.hovered_pack ~= hov then FHUD.hovered_pack = hov; FHUD_pack_show(hov) end
    elseif FHUD.packarea and FHUD.pack_hold and now < FHUD.pack_hold then
      -- sticky
    else
      if FHUD.packarea then FHUD_pack_destroy() end
      if cfg('reroll_preview') then
        local ssig = FHUD_reroll_sig()
        if ssig ~= FHUD.shopsig or not FHUD.shoparea then FHUD.shopsig = ssig; FHUD_shop_refresh() end
      else
        if FHUD.shoparea then FHUD_shop_destroy() end
      end
    end
  else
    if FHUD.shoparea then FHUD_shop_destroy() end
    if FHUD.packarea then FHUD_pack_destroy() end
    if FHUD.pack_map then FHUD_pack_map_clear() end
  end

  -- Pulse Rare/Legendary preview cards every ~1.2s so they clearly jump out.
  if cfg('auto_highlight') then
    local now = (G.TIMERS and G.TIMERS.REAL) or 0
    if now - (FHUD.pulse_t or 0) > 1.2 then
      FHUD.pulse_t = now
      local function pulse(area)
        if area and area.cards then
          for _, c in ipairs(area.cards) do
            if c.fhud_rare and c.juice_up then c:juice_up(0.35, 0.18) end
          end
        end
      end
      pulse(FHUD.shoparea)
      pulse(FHUD.packarea)
      pulse(FHUD.conarea)
    end
  end
end

----------------------------------------------------------------- hooks
if not FHUD.hooked then
  FHUD.hooked = true
  local _u = love.update
  function love.update(dt)
    if _u then _u(dt) end
    pcall(FHUD_tick)
    -- every dry-run in a tick restores what it snapshots; if one ever didn't, never let
    -- the muted discover/unlock outlive the tick (see disc_mute)
    if (FHUD.disc_depth or 0) > 0 or FHUD.disc_saved then pcall(FHUD_disc_unmute, true) end
  end

  -- Text labels for the wheel / lucky verdicts + the version notice (card sprites
  -- can't carry text). Drawn in screen space AFTER the game's own draw; pcall-guarded.
  local _draw = love.draw
  function love.draw()
    if _draw then _draw() end
    pcall(function()
      -- v0.7.1: previews are frozen while paused; don't paint their banners over the menu
      if not FHUD_rng_live() and FHUD.version_ok ~= false then return end
      local W, H = love.graphics.getDimensions()
      local prevfont = love.graphics.getFont()
      local font = (G.LANG and G.LANG.font and G.LANG.font.FONT) or prevfont
      local boxes = FHUD_banner_layout(W, H, font) -- v0.8.0: shared with the joker badges
      if #boxes == 0 then return end
      love.graphics.setFont(font)
      for _, l in ipairs(boxes) do
        local x, y, tw, th, sx = l.x, l.y, l.tw, l.th, l.sx
        love.graphics.setColor(0, 0, 0, 0.78)
        love.graphics.rectangle('fill', x - 12, y - 7, tw + 24, th + 14, 6, 6)
        if l.warn then
          love.graphics.setColor(1, 0.5, 0.4, 1)
        elseif l.colour then
          love.graphics.setColor(l.colour[1], l.colour[2], l.colour[3], l.colour[4] or 1)
        else
          love.graphics.setColor(1, 0.95, 0.5, 1)
        end
        love.graphics.print(l.t, x, y, 0, sx, sx)
      end
      love.graphics.setFont(prevfont)
      love.graphics.setColor(1, 1, 1, 1)
    end)
    -- Wave 3 hand tags (own pcall: a failure here can't take the banners down, or v.v.)
    pcall(function()
      if not (FHUD.hand_tag_items and #FHUD.hand_tag_items > 0) or G.OVERLAY_MENU then return end
      if G.STATE ~= G.STATES.SELECTING_HAND then return end
      local W, H = love.graphics.getDimensions()
      local prevfont = love.graphics.getFont()
      local font = (G.LANG and G.LANG.font and G.LANG.font.FONT) or prevfont
      love.graphics.setFont(font)
      for _, b in ipairs(FHUD_hand_tag_layout(W, H, font)) do
        love.graphics.setColor(0, 0, 0, 0.8)
        love.graphics.rectangle('fill', b.x, b.y, b.w, b.h, 4, 4)
        for i, l in ipairs(b.lines) do
          local col = l.colour or TAG_COL.info
          love.graphics.setColor(col[1], col[2], col[3], col[4] or 1)
          local lw = font:getWidth(l.t) * b.sc
          love.graphics.print(l.t, b.x + (b.w - lw) / 2, b.y + b.pad + (i - 1) * b.lh, 0, b.sc, b.sc)
        end
      end
      love.graphics.setFont(prevfont)
      love.graphics.setColor(1, 1, 1, 1)
    end)
    -- Wave 5 joker badges (own pcall)
    pcall(function()
      if not (FHUD.joker_badge_items and #FHUD.joker_badge_items > 0) or G.OVERLAY_MENU or not FHUD_rng_live() then return end
      local st = G.STATE
      if not (st == G.STATES.SELECTING_HAND or st == G.STATES.SHOP or st == G.STATES.BLIND_SELECT) then return end
      local W, H = love.graphics.getDimensions()
      local prevfont = love.graphics.getFont()
      local font = (G.LANG and G.LANG.font and G.LANG.font.FONT) or prevfont
      love.graphics.setFont(font)
      for _, b in ipairs(FHUD_joker_badge_layout(W, H, font)) do
        love.graphics.setColor(0, 0, 0, 0.82)
        love.graphics.rectangle('fill', b.x, b.y, b.w, b.h, 4, 4)
        for i, l in ipairs(b.lines) do
          local col = l.colour or TAG_COL.info
          love.graphics.setColor(col[1], col[2], col[3], col[4] or 1)
          local lw = font:getWidth(l.t) * b.sc
          love.graphics.print(l.t, b.x + (b.w - lw) / 2, b.y + b.pad + (i - 1) * b.lh, 0, b.sc, b.sc)
        end
      end
      love.graphics.setFont(prevfont)
      love.graphics.setColor(1, 1, 1, 1)
    end)
    -- Wave 4 blind strip (own pcall)
    pcall(function()
      if not FHUD.strip_items or G.OVERLAY_MENU or G.STATE ~= G.STATES.BLIND_SELECT then return end
      local W, H = love.graphics.getDimensions()
      local prevfont = love.graphics.getFont()
      local font = (G.LANG and G.LANG.font and G.LANG.font.FONT) or prevfont
      love.graphics.setFont(font)
      for _, b in ipairs(FHUD_blind_strip_layout(W, H, font)) do
        love.graphics.setColor(0, 0, 0, 0.8)
        love.graphics.rectangle('fill', b.x, b.y, b.w, b.h, 4, 4)
        for i, r in ipairs(b.rows) do
          local rx = b.x + b.pad + (b.w - 2 * b.pad - r.w) / 2
          local ry = b.y + b.pad + (i - 1) * b.lh
          for _, tk in ipairs(r.toks) do
            local col = tk.col or TAG_COL.info
            love.graphics.setColor(col[1], col[2], col[3], col[4] or 1)
            love.graphics.print(tk.t, rx + tk.x, ry, 0, b.sc, b.sc)
          end
        end
      end
      love.graphics.setFont(prevfont)
      love.graphics.setColor(1, 1, 1, 1)
    end)
  end

  local _kp = love.keypressed
  function love.keypressed(key, scancode, isrepeat)
    if _kp then _kp(key, scancode, isrepeat) end
    -- R toggles the reroll-chain modal overlay (shop only).
    if key == 'r' and cfg('reroll_chain') and G and G.STATE and G.STATES and G.STATE == G.STATES.SHOP
        and FHUD_rng_live() then
      if FHUD.chain_open and G.OVERLAY_MENU then
        FHUD.chain_open = false
        G.FUNCS.exit_overlay_menu()
      elseif not G.OVERLAY_MENU then
        FHUD.chain_open = true
        pcall(FHUD_chain_overlay)
      end
    end
  end
end

-------------------------------------------------------- Steamodded config tab
-- Per-feature on/off checkboxes in the Mods menu, persisted to mod.config.
if MOD then
  MOD.config_tab = function()
    local c = MOD.config
    local function tog(label, key)
      return create_toggle({
        label = label, ref_table = c, ref_value = key,
        callback = function()
          if SMODS then
            if SMODS.save_mod_config then pcall(SMODS.save_mod_config, MOD)
            elseif SMODS.save_all_config then pcall(SMODS.save_all_config) end
          end
        end,
      })
    end
    local function header(t)
      return { n = G.UIT.R, config = { align = 'cm', padding = 0.04 },
        nodes = { { n = G.UIT.T, config = { text = t, scale = 0.42, colour = G.C.BLUE } } } }
    end
    local function col(nodes) return { n = G.UIT.C, config = { align = 'tm', padding = 0.03 }, nodes = nodes } end
    local previews = col({
      header("Previews"),
      tog("Upcoming draws", 'upcoming_draws'),
      tog("Reroll preview", 'reroll_preview'),
      tog("Pack contents (hover)", 'pack_hover'),
      tog("Auto-highlight Rare/Legendary", 'auto_highlight'),
      tog("Reroll chain (press R)", 'reroll_chain'),
    })
    local consumables = col({
      header("Consumables"),
      tog("Wheel of Fortune", 'wheel'),
      tog("The Emperor", 'emperor'),
      tog("The High Priestess", 'high_priestess'),
      tog("Judgement", 'judgement'),
      tog("The Soul", 'soul'),
      tog("The Fool", 'fool'),
      tog("Aura", 'aura'),
      tog("Spectral cards", 'spectrals'),
    })
    local generators = col({
      header("Joker generators"),
      tog("8 Ball", 'eightball'),
      tog("Hallucination", 'hallucination'),
      tog("Riff-Raff", 'riffraff'),
      tog("Cartomancer", 'cartomancer'),
      tog("Vagabond", 'vagabond'),
      tog("Certificate", 'certificate'),
    })
    local handtags = col({
      header("Hand tags"),
      tog("Glass break", 'glass'),
      tog("Lucky card", 'lucky'),
      tog("Purple seal", 'purple_seal'),
      tog("Blue seal", 'blue_seal'),
    })
    local blindsel = col({
      header("Blind select"),
      tog("Upcoming bosses", 'boss_preview'),
      tog("Skip-tag rewards", 'skip_tags'),
    })
    local badges = col({
      header("Joker badges"),
      tog("Space Joker", 'space'),
      tog("Business/Bloodstone/Parking", 'probabilistic'),
      tog("Lucky Cat", 'lucky_cat'),
      tog("Misprint", 'misprint'),
      tog("Gros Michel/Cavendish", 'gros_michel'),
      tog("To Do List/Ancient", 'todo_ancient'),
      tog("Madness/Invisible/Perkeo", 'random_pick'),
      tog("Superposition/Seance/6th Sense", 'card_makers'),
    })
    return { n = G.UIT.ROOT, config = { align = 'cm', padding = 0.08, colour = G.C.CLEAR, minw = 6 },
      nodes = { { n = G.UIT.R, config = { align = 'cm', padding = 0.1 },
        nodes = { previews, consumables, generators, handtags, blindsel, badges } } } }
  end
end

return FHUD
