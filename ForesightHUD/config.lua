-- Default config for Foresight HUD. Steamodded loads this as the baseline and
-- persists the player's changes (made via the Config tab) on top of it.
-- All features default ON.
return {
  -- live previews
  upcoming_draws = true,
  reroll_preview = true,
  pack_hover = true,
  auto_highlight = true,
  reroll_chain = true,
  wheel = true,
  lucky = true,
  emperor = true,
  high_priestess = true,
  judgement = true,
  soul = true,
  fool = true,
  aura = true,
  spectrals = true,
  eightball = true,
  hallucination = true,
  riffraff = true,
  cartomancer = true,
  vagabond = true,
  certificate = true,
  -- hand tags (Wave 3)
  glass = true,
  purple_seal = true,
  blue_seal = true,
  -- blind select (Wave 4)
  boss_preview = true,
  skip_tags = true,
  -- joker badges (Wave 5)
  space = true,          -- Space Joker: does the next hand level up
  probabilistic = true,  -- Business Card / Bloodstone / Reserved Parking rolls for the selected hand
  lucky_cat = true,      -- Lucky Cat: xMult gained from the selected hand's Lucky triggers
  misprint = true,       -- Misprint: the next +Mult
  gros_michel = true,    -- Gros Michel / Cavendish: extinct at the next round end?
  todo_ancient = true,   -- To Do List / Ancient Joker: the next hand / suit after the round
  random_pick = true,    -- Madness (blind select) / Invisible Joker (sell) / Perkeo (leave shop)
  card_makers = true,    -- Superposition / Seance / Sixth Sense: the card they make for the selected hand
}
