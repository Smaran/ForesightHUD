# Foresight HUD

**See what Balatro's RNG is about to do before you commit.** Foresight HUD runs the game's own
random generators in a dry run, reads the result, then puts the random state back exactly
as it was. You see the real outcome of the next reroll, pack, consumable, skip tag, boss or
joker roll, drawn with real card sprites and short labels.

It's built for single-player manual play: plan around the dice instead of guessing.

> Previews **never change your run**. Every dry run snapshots the game's random state (and
> everything else a generator touches), restores it afterwards, and checks the restore
> byte for byte. If the check ever fails, all predictions switch themselves off for the
> session rather than risk your run.

<!-- SCREENSHOTS: images must use absolute URLs (Thunderstore can't resolve relative paths):
     ![caption](https://raw.githubusercontent.com/Smaran/ForesightHUD/main/screenshots/<file>.png)
     build.py fails if a linked file is missing from screenshots/. -->
<!--SHOTS-->
<!--/SHOTS-->

## Features

All features are on by default. Each one has its own toggle in **Mods → Foresight HUD → Config**.

### Shop and draws
- **Upcoming draws**: the next 5 cards you'll draw, in draw order, above the deck.
- **Next reroll**: the cards the next shop reroll gives, above the shop. It follows the real
  reroll exactly, including cards freed from the current shop, Illusion and edition tags.
- **Reroll chain (press `R` in the shop)**: a window with the next 10 rerolls and the price of
  each. Hover any joker in it to read its description.
- **Pack contents on hover**: every booster in the shop, including Buffoon-pack stickers,
  Standard-pack seals, and the right order when two packs of the same type are on the shelf.
- **Hallucination**: the Tarot that opening the hovered pack gives you.
- **Auto-highlight**: Rare and Legendary jokers in a preview lift up and pulse.

### Consumables (hover the card)
Wheel of Fortune (hit or miss, which joker, which edition), The Emperor, The High Priestess,
Judgement, The Soul, The Fool, Aura, and the Spectrals Wraith, Hex, Ectoplasm, Ankh,
Immolate, Sigil, Ouija, Familiar, Grim and Incantation.

### Hand tags (under your cards)
- **Glass**: BREAK or safe, for each Glass card in the selected hand.
- **Lucky**: every roll of each Lucky card, retriggers included.
- **Purple seal**: the Tarot it makes if you discard it.
- **Blue seal**: the Planet it makes at the end of the round.

### Blind select
- **Upcoming bosses** for the next antes, plus what a Director's Cut or Retcon reroll gives.
  If Hieroglyph or Petroglyph is on offer, it also shows the boss chain you get if you buy it.
- **Skip-tag rewards**: what each tag actually gives you, such as the exact pack contents,
  the shop joker, the edition and which joker gets it, the money, hand levels or voucher.
  Double Tag is handled.

### Joker badges (a short label on the joker)
| Joker | Badge |
|---|---|
| Space Joker | LEVEL UP / no level |
| Business Card, Bloodstone, Reserved Parking | every roll of the selected hand |
| Lucky Cat | xMult gained from the selected hand |
| Misprint | the next +Mult |
| Gros Michel, Cavendish | survives / EXTINCT at the end of the round |
| To Do List, Ancient Joker | the next hand / suit |
| Madness | which joker it destroys |
| Invisible Joker, Perkeo | what selling it / leaving the shop copies |
| 8 Ball, Vagabond, Superposition, Seance, Sixth Sense | the card it makes this hand |
| Riff-raff, Cartomancer, Certificate | what selecting the blind gives you |

Hover a joker whose badge names a card to see that card's sprite beside it.

Copies (Blueprint, Brainstorm), retriggers, Oops! All 6s, full slots and boss blinds are
all taken into account.

## Requirements
- **Balatro 1.0.1o.** Predictions are tied to this exact version of the game's code. On any
  other version they switch off with a notice, and only the upcoming-draws overlay stays.
- [Steamodded](https://github.com/Steamodded/smods) (and Lovely, which Steamodded needs).

## Install
- **With a mod manager (r2modman / Gale):** install *Foresight HUD*; Steamodded comes with it.
- **By hand:** extract the zip into `%AppData%\Balatro\Mods\ForesightHUD\`, so that
  `ForesightHUD.lua` sits directly in that folder.

## Notes and limits
- **Modded jokers and cards aren't modelled.** When one could change a result, the label
  says so ("modded jokers not modelled", or "not modelled" for modded tags).
- Predictions freeze while the game is paused (options, run info, deck view) and come back
  unchanged.
- This is a foresight tool. Use it for single-player fun, not for leaderboards or challenge
  runs where it would be unfair.

## License
MIT. See `LICENSE`.
