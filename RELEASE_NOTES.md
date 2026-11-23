## What's Changed
### Ubisoft Connect
- Ubisoft covers appear much sooner. iDeck now looks them up as soon as the game list shows, six at a time. Before, it waited for Ubisoft's download service to answer and then looked them up one by one, so the cards stayed black for a long time.
- Covers that stayed black now load:
  - iDeck tries Steam's newer address for game art, then the older one, and finally the game's wide header picture.
  - Titles with ® or ™ (such as Assassin's Creed® Chronicles: China) are searched without those signs, which Steam did not match.
  - Covers that were not found before are looked up again once.
- When no picture exists, the card shows the game's name instead of a plain dark box.
- Tapping a Ubisoft game that is not installed now asks "Install …?" first. Before, one tap started the download straight away, so a stray tap could start one (and show "Download failed").
- A failed download now shows its reason under the card.

### Version
- Updated the application version to 2.13.2 (build 120).
