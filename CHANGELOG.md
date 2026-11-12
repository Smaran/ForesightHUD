# Changelog

## 1.0.0
First public release. Everything below, plus a final full regression against the real game
engine on several seeds.

- Joker badges for every random vanilla joker (Space Joker, Business Card, Bloodstone,
  Reserved Parking, Lucky Cat, Misprint, Gros Michel, Cavendish, To Do List, Ancient Joker,
  Madness, Invisible Joker, Perkeo, Superposition, Seance, Sixth Sense, 8 Ball, Vagabond,
  Riff-raff, Cartomancer, Certificate). Hover a badge's joker to see the card it makes.
- Blind select: upcoming bosses (with Director's Cut / Retcon rerolls and the Hieroglyph /
  Petroglyph chain) and the concrete reward of every skip tag.
- Hand tags: Glass break, Lucky rolls (with retriggers), Purple seal Tarot, Blue seal Planet.
- Consumable previews: Wheel of Fortune, Emperor, High Priestess, Judgement, Soul, Fool,
  Aura, Wraith, Hex, Ectoplasm, Ankh, Immolate, Sigil, Ouija, Familiar, Grim, Incantation.
- Shop: next reroll (now beside the shop, clear of your own jokers), reroll chain window (R)
  with prices and joker tooltips, pack contents on hover (in open order for duplicate packs),
  Hallucination, upcoming draws.
- Score preview: the exact score of the cards you have selected, with every joker, enhancement,
  edition, seal and the boss blind, and whether it beats the blind. Turns itself off when
  DVPreview is installed. Toggle: Config > Hand tags > Score preview.
- Fixes since the last test build: the R window opened with empty rows (cards stuck below the
  screen), clicks could stop working after R + Esc in the shop, preview cards could stay on
  screen after going back to the main menu, previews covered your joker row in the shop, and
  the first joker badge could cover the joker slot count.
- Touch screens: tap a card to keep its preview up for a few seconds, and a NEXT 10 button in
  the shop opens the reroll window (only on touch devices; nothing changes on PC).
- Safety: byte-exact random-state snapshot and restore with a self-check, no previews while
  paused, previews never discover or unlock cards on your profile, no sounds from dry runs,
  version gate for Balatro 1.0.1o, per-feature toggles in Config.
