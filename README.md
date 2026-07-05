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
  stock falls below it.
- **CSV export** — in-game copy-paste window, plus a PowerShell script that
  turns the saved data into a real `.csv` file.
- **Live capture** — while the guild bank is open the log is re-scanned
  every few seconds, so transactions made during the visit are recorded
  without closing and reopening the bank.
- **Zero idle cost** — no polling or timers outside a bank visit; bank
  events are only registered while the guild bank is open.

## Installation

Copy the `GuildBankWatch` folder into your AddOns directory, e.g.:

```
C:\Program Files (x86)\World of Warcraft\_retail_\Interface\AddOns\GuildBankWatch
```

(only the `.toc` and `.lua` files are required in game; the `.ps1` script can
live anywhere).

## Usage

Open your guild bank once — the addon scans the log and contents
automatically. Then:

| Command | Effect |
|---|---|
| `/gbw` | Toggle the main window (Log / Totals / Watchlist views) |
| `/gbw <character>` | Open the log filtered to one character |
| `/gbw track <itemID> [minimum]` | Warn when the bank holds fewer than `minimum` (default 1) |
| `/gbw untrack <itemID>` | Stop tracking an item |
| `/gbw export` | Open the CSV window (Ctrl+C to copy) |
| `/gbw purge` | Delete this guild's recorded data |
| `/gbw version` | Show the installed addon version |
| `/gbw help` | List commands |

Item IDs can be found on [wowhead.com](https://www.wowhead.com) (the number
in the item page URL), or shift-click an item link while the Watchlist view
is open.

### CSV file export

After logging out (or `/reload`), run:

```powershell
.\Export-GuildBankWatch.ps1                # default WoW install path
.\Export-GuildBankWatch.ps1 -WowPath 'D:\Games\World of Warcraft'
```

This writes `GuildBankWatch-export.csv` with columns:
`DateTimeUTC, Guild, Character, Action, ItemID, ItemName, Count, GoldCopper, Tab, Unattributed, Account`.

## Limitations (by design)

- The addon can only record what is still in the 25-entry server log when
  someone running it visits the bank. Visit regularly in active guilds; gap
  detection flags — but cannot attribute — anything that rolled off.
- Timestamps are hour-granularity estimates (the server only reports elapsed
  time).
- Bank contents (watchlist counts) are only readable while at the guild bank;
  login warnings use the last visit's snapshot.
- Coverage is limited to bank tabs your rank can view.
- History is stored per WoW account. Retention defaults to 60 days.
