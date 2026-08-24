# GuildBankWatch

A lightweight World of Warcraft addon (retail, Midnight 12.0+) that keeps a
permanent record of **who takes items and gold out of your guild bank**. The
built-in guild bank log only holds the last 25 transactions per tab; this
addon captures those entries every time you visit the bank and stores them
across sessions, with low-stock alerts and CSV export on top.

## Features

- **Persistent transaction history** — withdrawals, deposits, and repairs,
  attributed to the character who made them (tab-to-tab moves are ignored).
- **Gap detection** — a compact snapshot of the bank is compared on each
  visit; if more than 25 transactions rolled off the log between visits, an
  `ALERT` row tells you unattributed changes happened instead of missing them
  silently.
- **Per-character totals** — see at a glance which character has taken the
  most items and gold.
- **Low-stock watchlist** — track items by their Wowhead item ID (e.g.
  `244029`) with a minimum count; you're warned at the bank and on login when
  stock falls below it. Minimums are editable in place, without re-adding the
  item.
- **Shareable watchlists** — export your tracked items as a copy-paste string
  and import someone else's, with a preview before anything changes.
- **Auctionator shopping list** — one click turns everything below its
  minimum into an Auctionator-importable shopping list, with the quantity
  needed for each item.
- **CSV export** — an in-game copy-paste window with the full transaction
  history, ready for a spreadsheet.
- **Live capture** — while the guild bank is open the log is re-scanned
  every few seconds, so transactions made during the visit are recorded
  without closing and reopening the bank.
- **Zero idle cost** — no polling or timers outside a bank visit; bank
  events are only registered while the guild bank is open.
- **No dependencies** — two Lua files, no embedded libraries.

## Installation

### With WowUp (recommended — stays updated)

In WowUp, choose **Get Addons → Install from URL** and paste:

```
https://github.com/LukeDJ24/GuildBankWatch
```

WowUp reads the repository's GitHub releases, so it will offer an update
whenever a new release is published. It ignores plain commits — see
[Releasing](#releasing) below.

### Manually

Download the `GuildBankWatch-<version>.zip` from the
[releases page](https://github.com/LukeDJ24/GuildBankWatch/releases) and
extract it into your AddOns directory, so that you end up with:

```
C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\GuildBankWatch
```

## Usage

Open your guild bank once — the addon scans the log and contents
automatically. Then:

| Command | Effect |
|---|---|
| `/gbw` | Toggle the main window (Log / Totals / Watchlist views) |
| `/gbw <character>` | Open the log filtered to one character |
| `/gbw track <itemID> [minimum]` | Warn when the bank holds fewer than `minimum` (default 1); also changes the minimum on an item you already track |
| `/gbw untrack <itemID>` | Stop tracking an item |
| `/gbw export` | Open the CSV window (Ctrl+C to copy) |
| `/gbw export items` | Copy your tracked items as a shareable string |
| `/gbw import` | Paste a shared tracked-items string |
| `/gbw shopping` | Copy low-stock items as an Auctionator shopping list |
| `/gbw purge` | Delete this guild's recorded data |
| `/gbw version` | Show the installed addon version |
| `/gbw help` | List commands |

Item IDs can be found on [wowhead.com](https://www.wowhead.com) (the number
in the item page URL), or shift-click an item link while the Watchlist view
is open.

### CSV export

`/gbw export`, or the **Export CSV** button on the main window, opens a
window containing the full history for the current guild. Press Ctrl+C and
paste it into a spreadsheet. The columns are:

`DateTimeUTC, Guild, Character, Action, ItemID, ItemName, Count, GoldCopper, Tab, Unattributed`

### Changing a minimum

Each row of the Watchlist view shows the count in the bank next to an
editable **Minimum** box. Click it, type a new number, and press Enter —
Escape cancels and puts the old value back. Nothing else on the row changes,
and the row re-colours immediately to show whether you are now below the new
threshold.

`/gbw track <itemID> <minimum>` does the same thing from chat: run it on an
item you already track and it reports the change rather than re-adding it.

Raising a minimum above your current stock re-arms the low-stock warning for
the session, so the next bank scan tells you about it instead of staying
quiet.

### Sharing a watchlist

The **Export** and **Import** buttons on the Watchlist view (or `/gbw export
items` and `/gbw import`) move tracked items between characters, accounts, or
guildmates as a single string that looks like:

```
GBW1:555d32c6:aSAyMTA3OTYgNQppIDI0NDAyOSAyMA==
```

(that one is real — it tracks item `210796` with a minimum of 5 and `244029`
with a minimum of 20.)

**The string contains item IDs and minimum counts, and nothing else** — no
character names, no guild, no transaction history. It is safe to paste into
guild chat or Discord. Item names are left out too, since they are
locale-specific; the importing client looks each name up from the ID.

When you paste a string into the import window it is checked and previewed
before anything is applied — how many items are new, how many change an
existing minimum, and how many already match. Then choose:

- **Merge into list** — keeps the items you already track and adds the
  imported ones. Where an item appears in both, the imported minimum wins.
- **Replace list** — makes your watchlist an exact copy of the string,
  removing tracked items that are missing from it. This one asks for
  confirmation first.

The string carries a checksum, so a paste that was truncated in transit is
rejected rather than half-imported.

### Shopping list export (Auctionator)

The **Shopping List** button on the Watchlist view (or `/gbw shopping`) copies
everything currently below its minimum as a string
[Auctionator](https://www.curseforge.com/wow/addons/auctionator) can import.
The button is greyed out whenever nothing is low, so it doubles as an
"everything is stocked" indicator.

Paste the result into Auctionator's shopping list **Import**. The format is:

```
GuildBankWatch - Knights of Azeroth^"Copper Ore";;;;;;;;;;;#;;20^"Linen Cloth";;;;;;;;;;;#;;5
```

Each entry is an Auctionator advanced search: the item name is quoted so it
searches for an **exact** match rather than anything containing that text, and
the trailing number is the **quantity needed** — your minimum minus what the
bank last held — which shows up as the purchase quantity in Auctionator.

The list is named after your guild, and re-importing replaces that same list
rather than creating duplicates, so you can export again after each bank visit
and simply re-import.

Two things worth knowing:

- Counts come from the **last bank scan**, not live stock, so export after
  visiting the bank for current numbers.
- Items whose names have not loaded yet are skipped, and the export window
  tells you how many. Reopening the Watchlist view resolves them.

## Releasing

WowUp updates from GitHub *releases*, not from commits — pushing code alone
will never trigger an update. `.github/workflows/release.yml` bridges that
gap: it watches the addon's own version number, so publishing is just

1. bump `## Version:` in `GuildBankWatch.toc`,
2. commit and push to `main`.

The workflow then builds `GuildBankWatch-<version>.zip` (containing a single
`GuildBankWatch/` folder, which is what WowUp expects), generates a
`release.json` declaring the retail flavour, and publishes both as release
`v<version>`. Pushes that don't change the version are ignored, so ordinary
commits never produce a spurious update prompt.

Two constraints are worth knowing before changing any of this:

- **WowUp uses the asset filename as the version string**, not the git tag.
  The zip name must change every release or clients will never be offered the
  update — which is why the version is baked into the filename.
- **The folder inside the zip must match the repository name.** Renaming
  either the repo or the addon folder breaks installation until both match
  again.

## Limitations (by design)

- The addon can only record what is still in the 25-entry server log when
  someone running it visits the bank. Visit regularly in active guilds; gap
  detection flags — but cannot attribute — anything that rolled off.
- Timestamps are hour-granularity estimates (the server only reports elapsed
  time).
- Bank contents (watchlist counts) are only readable while at the guild bank;
  login warnings use the last visit's snapshot.
- Coverage is limited to bank tabs your rank can view.
- History and watchlists are stored per WoW account, scoped per guild.
  Retention defaults to 60 days.
