local MOD = SMODS.current_mod
MOD.config = MOD.config or {}
local config = MOD.config

if config.undo_price            == nil then config.undo_price            = 0    end
if config.max_undo              == nil then config.max_undo              = 5    end
if config.refund_reroll         == nil then config.refund_reroll         = true end
if config.sell_back_purchases   == nil then config.sell_back_purchases   = true end
if config.burn_used_consumables == nil then config.burn_used_consumables = true end
if config.undo_on_right_click   == nil then config.undo_on_right_click   = true end
if config.undo_key              == nil then config.undo_key              = 'u'  end

local SU = {}
SHOP_UNDO = SU

SU.stack       = SU.stack or {}
SU.purchases   = SU.purchases or {}
SU.burns       = SU.burns or {}
SU.cur_fp      = nil
SU.scrub_gen   = 0
SU.scrub_state = nil

local function copy_flat(t)
    local r = {}
    if type(t) == 'table' then
        for k, v in pairs(t) do r[k] = v end
    end
    return r
end

local function whole(n)
    return math.floor((tonumber(n) or 0) + 0.5)
end

local rng_fingerprint
rng_fingerprint = function(rng)
    if type(rng) ~= 'table' then return tostring(rng) end
    local keys = {}
    for k in pairs(rng) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local parts = {}
    for _, k in ipairs(keys) do
        local v = rng[k]
        if type(v) == 'table' then v = rng_fingerprint(v) end
        parts[#parts + 1] = tostring(k) .. '=' .. tostring(v)
    end
    return table.concat(parts, ';')
end

function SU.clear_all()
    SU.stack = {}
    SU.purchases = {}
    SU.burns = {}
    SU.cur_fp = nil
    SU.scrub_gen = 0
    SU.scrub_state = nil
end

function SU.shop_type_for(card)
    local set = card.ability and card.ability.set
    if set == 'Joker'    then return 'Joker'    end
    if set == 'Planet'   then return 'Planet'   end
    if set == 'Tarot'    then return 'Tarot'    end
    if set == 'Spectral' then return 'Spectral' end
    return 'Default'
end

function SU.push_snapshot()
    if not G.shop_jokers then return end
    local cur = G.GAME.current_round
    local was_free = (cur.free_rerolls or 0) > 0

    local saved = {}
    for _, c in ipairs(G.shop_jokers.cards) do
        saved[#saved + 1] = { card = c:save(), cost = c.cost }
    end

    local snap = {
        cards       = saved,
        cost        = cur.reroll_cost,
        reroll_cost = cur.reroll_cost,
        reroll_inc  = cur.reroll_cost_increase,
        was_free    = was_free,
        rng         = copy_flat(G.GAME.pseudorandom),
        purchases   = SU.purchases,
    }

    SU.stack[#SU.stack + 1] = snap
    while #SU.stack > whole(config.max_undo or 5) do
        table.remove(SU.stack, 1)
    end

    SU.purchases = {}
end

function SU.restore_cards(saved)
    local area = G.shop_jokers
    if not area then return end

    for i = #area.cards, 1, -1 do
        local c = area:remove_card(area.cards[i])
        if c then c:remove() end
    end

    for _, entry in ipairs(saved) do
        local st = entry.card
        local center, proto
        if st.save_fields then
            center = st.save_fields.center and G.P_CENTERS[st.save_fields.center] or nil
            proto  = st.save_fields.card   and G.P_CARDS[st.save_fields.card]    or nil
        end
        local card = Card(
            area.T.x, area.T.y, G.CARD_W, G.CARD_H,
            proto, center,
            { bypass_discovery_center = true, bypass_discovery_ui = true }
        )
        card:load(st)
        card.cost = entry.cost or card.cost

        if create_shop_card_ui and not (card.children and card.children.buy_button) then
            create_shop_card_ui(card, SU.shop_type_for(card), area)
        end
        card:start_materialize()
        area:emplace(card)
    end
end

function SU.reverse_purchase(p)
    local card = p and p.card
    if not card then return false end
    local area = card.area
    if area == G.jokers or area == G.consumeables then
        if card.remove_from_deck then pcall(function() card:remove_from_deck() end) end
        area:remove_card(card)
        card:remove()
        ease_dollars(whole(p.cost or 0))
        return true
    end
    return false
end

local function burn_key_of(card)
    return card and card.config and card.config.center and card.config.center.key or nil
end

function SU.add_burn(fp, key)
    if not fp or not key then return end
    SU.burns[fp] = SU.burns[fp] or {}
    SU.burns[fp][key] = (SU.burns[fp][key] or 0) + 1
end

function SU.scrub_tick()
    if not (G.shop_jokers and SU.cur_fp) then return end
    if (not SU.scrub_state) or SU.scrub_state.gen ~= SU.scrub_gen then
        local remaining = {}
        local map = SU.burns[SU.cur_fp]
        if map then for k, n in pairs(map) do remaining[k] = n end end
        SU.scrub_state = { gen = SU.scrub_gen, remaining = remaining }
    end
    local remaining = SU.scrub_state.remaining
    if not (remaining and next(remaining)) then return end
    for i = #G.shop_jokers.cards, 1, -1 do
        local c = G.shop_jokers.cards[i]
        local k = burn_key_of(c)
        if k and (remaining[k] or 0) > 0 then
            remaining[k] = remaining[k] - 1
            if remaining[k] <= 0 then remaining[k] = nil end
            local rc = G.shop_jokers:remove_card(c)
            if rc then rc:remove() end
        end
    end
end

function SU.can_undo()
    if #SU.stack == 0 then return false, 0 end
    local snap = SU.stack[#SU.stack]
    local refund = (config.refund_reroll and not snap.was_free) and whole(snap.cost or 0) or 0
    local net = whole(config.undo_price or 0) - refund
    local ok = (G.GAME.dollars - (G.GAME.bankrupt_at or 0)) - net >= 0
    return ok, net
end

function SU.do_undo()
    if #SU.stack == 0 then return end
    local ok, net = SU.can_undo()
    if not ok then return end

    local snap = table.remove(SU.stack, #SU.stack)
    local burn_fp = rng_fingerprint(snap.rng)

    if config.sell_back_purchases then
        for i = #SU.purchases, 1, -1 do
            local p = SU.purchases[i]
            local sold = false
            pcall(function() sold = SU.reverse_purchase(p) end)
            if (not sold) and config.burn_used_consumables and p and p.key then
                SU.add_burn(burn_fp, p.key)
            end
        end
    end

    if net ~= 0 then ease_dollars(-net) end

    if config.refund_reroll then
        if snap.was_free then
            G.GAME.current_round.free_rerolls = (G.GAME.current_round.free_rerolls or 0) + 1
        end
        if snap.reroll_inc ~= nil then
            G.GAME.current_round.reroll_cost_increase = snap.reroll_inc
        end
        if snap.reroll_cost ~= nil then
            G.GAME.current_round.reroll_cost = snap.reroll_cost
        end
        if calculate_reroll_cost then pcall(calculate_reroll_cost, true) end
    end

    if snap.rng and G.GAME.pseudorandom then
        local pr = G.GAME.pseudorandom
        for k in pairs(pr) do pr[k] = nil end
        for k, v in pairs(snap.rng) do pr[k] = v end
    end

    SU.restore_cards(snap.cards)
    SU.purchases = snap.purchases or {}

    SU.cur_fp = nil
    SU.scrub_state = nil

    play_sound('cardSlide1', 0.9)
end

function SU.try_undo()
    if #SU.stack == 0 then
        pcall(play_sound, 'cancel')
        return
    end
    if not SU.can_undo() then
        pcall(play_sound, 'cancel')
        return
    end
    SU.do_undo()
end

G.FUNCS.undo_shop = function(e) SU.try_undo() end

local function track_buy(e)
    pcall(function()
        local card = e and e.config and e.config.ref_table
        if card and card.area == G.shop_jokers then
            SU.purchases[#SU.purchases + 1] = {
                card = card,
                cost = card.cost or 0,
                key  = card.config and card.config.center and card.config.center.key or nil,
            }
        end
    end)
end

if G.FUNCS.buy_from_shop then
    local ref_buy = G.FUNCS.buy_from_shop
    G.FUNCS.buy_from_shop = function(e)
        track_buy(e)
        return ref_buy(e)
    end
end

local ref_reroll = G.FUNCS.reroll_shop
G.FUNCS.reroll_shop = function(e)
    local cur = G.GAME and G.GAME.current_round
    local will_reroll = false
    if cur then
        if (cur.free_rerolls or 0) > 0 then
            will_reroll = true
        elseif (G.GAME.dollars - (G.GAME.bankrupt_at or 0)) - (cur.reroll_cost or 0) >= 0 then
            will_reroll = true
        end
    end
    local pre_fp
    if will_reroll then
        pre_fp = rng_fingerprint(G.GAME.pseudorandom)
        pcall(SU.push_snapshot)
    end

    local result = ref_reroll(e)

    if will_reroll then
        SU.cur_fp = pre_fp
        SU.scrub_gen = (SU.scrub_gen or 0) + 1
    end
    return result
end

local ref_start = Game.start_run
function Game:start_run(args)
    ref_start(self, args)
    SU.clear_all()
end

local ref_update = Game.update
function Game:update(dt)
    ref_update(self, dt)

    if G.STATES and G.STATE == G.STATES.SHOP then
        pcall(SU.scrub_tick)
    end

    if G.STATES and G.STATE == G.STATES.BLIND_SELECT then
        if not SU._was_blind then SU.clear_all() end
        SU._was_blind = true
    else
        SU._was_blind = false
    end
end

function SU.node_is_reroll(node)
    local depth = 0
    while node and depth < 16 do
        local c = node.config
        if c and (c.button == 'reroll_shop' or c.id == 'reroll_button') then
            return true
        end
        node = node.parent
        depth = depth + 1
    end
    return false
end

if Controller and Controller.queue_R_cursor_press then
    local ref_r = Controller.queue_R_cursor_press
    function Controller:queue_R_cursor_press(x, y)
        ref_r(self, x, y)
        pcall(function()
            if not config.undo_on_right_click then return end
            if not (G.STATES and G.STATE == G.STATES.SHOP) then return end
            local node = (self.hovering and self.hovering.target)
                or (self.focused and self.focused.target)
            if SU.node_is_reroll(node) then
                SU.try_undo()
            end
        end)
    end
end

if Controller and Controller.key_press then
    local ref_key = Controller.key_press
    function Controller:key_press(key)
        ref_key(self, key)

        if SU.rebinding then
            if key ~= 'escape' then
                config.undo_key = key
                pcall(function()
                    if SMODS.save_mod_config then SMODS.save_mod_config(MOD) end
                end)
            end
            SU.rebinding = false
            return
        end

        if key == (config.undo_key or 'u') and G.STATE == G.STATES.SHOP then
            SU.try_undo()
        end
    end
end

G.FUNCS.shopundo_rebind = function(e)
    SU.rebinding = true
end

MOD.config_tab = function()
    local function row(node, pad)
        return { n = G.UIT.R, config = { align = 'cm', padding = pad or 0.06 }, nodes = { node } }
    end
    local function txt(s, sc, col)
        return { n = G.UIT.T, config = { text = s, scale = sc or 0.4, colour = col or G.C.UI.TEXT_LIGHT } }
    end
    return {
        n = G.UIT.ROOT,
        config = { align = 'cm', padding = 0.12, colour = G.C.CLEAR, minw = 7 },
        nodes = {
            row(txt('Shop Undo', 0.7, G.C.GOLD), 0.04),
            row(txt('Roll back the shop top row after a reroll', 0.32), 0.02),
            row(txt('GENERAL', 0.42, G.C.BLUE), 0.08),
            row(create_slider({
                label = 'Undo price ($)   0 = free',
                min = 0, max = 50, step = 1, scale = 0.85,
                ref_table = config, ref_value = 'undo_price', w = 4.6, h = 0.4,
            })),
            row(create_slider({
                label = 'Undo steps remembered',
                min = 1, max = 10, step = 1, scale = 0.85,
                ref_table = config, ref_value = 'max_undo', w = 4.6, h = 0.4,
            })),
            row(txt('ON UNDO', 0.42, G.C.BLUE), 0.08),
            row(create_toggle({
                label = 'Refund the reroll cost',
                ref_table = config, ref_value = 'refund_reroll',
                info = { 'Give back money spent on the reroll', 'and reset its rising price' },
            })),
            row(create_toggle({
                label = 'Sell bought cards back',
                ref_table = config, ref_value = 'sell_back_purchases',
                info = { 'Refund top-row cards you bought', 'at their purchase price' },
            })),
            row(create_toggle({
                label = 'Block used-consumable farming',
                ref_table = config, ref_value = 'burn_used_consumables',
                info = { 'A consumable bought AND used will not', 'come back in the shop after an undo' },
            })),
            row(txt('CONTROLS', 0.42, G.C.BLUE), 0.08),
            row(create_toggle({
                label = 'Right-click Reroll to undo',
                ref_table = config, ref_value = 'undo_on_right_click',
            })),
            { n = G.UIT.R, config = { align = 'cm', padding = 0.06 }, nodes = {
                txt('Undo hotkey:  ', 0.42),
                { n = G.UIT.T, config = { ref_table = config, ref_value = 'undo_key', scale = 0.42, colour = G.C.GOLD } },
            }},
            row(UIBox_button({
                button = 'shopundo_rebind',
                label  = { 'Rebind key' },
                colour = G.C.BLUE, minw = 3, scale = 0.4,
            })),
        }
    }
end