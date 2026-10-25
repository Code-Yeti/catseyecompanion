# catseyecompanion

An Ashita v4 addon for **CatseyeXI** that passes information the game client already has to a desktop companion app. The app shows a live zone map, a blue magic tracker, a storage view and a quest log, all running outside the game.

## Addon policy tier: T2 Information

Under the [CatseyeXI addon policy](https://catseyexi.com/addon-policy), this is a display/information addon:
- It **only reads** client memory and **only observes** incoming packets.
- It **never sends packets**, queues commands, writes game memory, or blocks or changes packets.
- It doesn't automate anything or play the game for the player.
- It reveals nothing the normal client doesn't already have.

You can check this in the source:

```sh
grep -nE "packet_out|QueueCommand|QueuePacket|AddOutgoingPacket|memory\.write|data_modified" *.lua
```

It should print nothing. The only `e.blocked` is the addon's own `/csc` chat command, which stops that command text from going to the server like any addon command.

## What it reads

| Data | Source |
|---|---|
| Character name, zone, position | `GetParty()`, `GetEntity()` |
| Main and sub job and level | `GetPlayer()` |
| Current target (name, HP %, whether it's a mob) | `GetTarget()`, `GetEntity()` |
| Learned blue magic | `GetPlayer():HasSpell(id)`, the same check `blucheck` uses |
| Set blue magic and set points | Memory reads from `blusets`' Blue Mage helper (read-only subset in `blu.lua`) |
| Items in each bag (id and count) | `GetInventory():GetContainerItem()`, as `find` does |
| "You learn a spell" message | Incoming packet 0x029, message 419, as `blucheck` does (observed only) |
| Equipped weapons, and a trial weapon's weapon skill points (the item's own data, which the client already holds) | `GetInventory():GetEquippedItem()`, `GetContainerItem()`, as `equipmon` does |
| Experience, limit and merit points | `GetPlayer()` (as `expbar` does) |
| Engaged or not | `GetEntity():GetStatus()` |
| Monster TP moves ("readies" / "uses", the same lines the chat log shows) | Incoming packet 0x028, categories 7 and 11 (observed only) |
| Quest and mission log | Incoming packet 0x056 payloads (observed only, stored as raw bytes) |

## What it writes

It writes one local file, about once a second while values change, with a heartbeat every 5 seconds:

```
%APPDATA%\com.ffxi.catseyecompanion\live.json
```

It makes no network connections. The companion app reads this file.

## Install

1. Copy the `catseyecompanion` folder into your Ashita addons folder. For CatseyeXI's VanaCore client, that's `Vanacore\addons\ashita\`.
2. In game, type `/addon load catseyecompanion ashita`, or add it on the VanaCore launcher's Addons page.
3. `/csc` prints where it writes and when it last wrote.

## Credits and license

`blu.lua` is a read-only subset of the Blue Mage helper from **blusets** by atom0s (Ashita Development Team). Only its memory reads are kept, and everything that built or sent packets was removed. Like Ashita's addons, this addon is licensed under **GPLv3**. See [LICENSE.md](LICENSE.md).
