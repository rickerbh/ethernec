# EtherNEC / NetUSBee on the Atari TT — root cause & fix

Why the STinG EtherNEC driver (`ENEC.STX` / `ENEC3.STX`) fails on the Atari TT while it
works on the Falcon and the AssemSoft NE2000 driver works on the TT.

Source under analysis: the EtherNE(A/C) driver by Dr. **Thomas Redelberger** (ThR) and
Lyndon Amsdon (ROM-port hardware). The "Dr Richard" driver referred to on exxosforum
thread 780 is this one — the author is Thomas Redelberger.

**Bottom line: the root cause is the 68030 data cache, not bus timing.** Confirmed on real
TT hardware. The fix is to keep the cartridge ROM window out of the data cache while the
driver touches it. See §6–§7.

---

## 1. Hardware / software stack

```
NetUSBee (RTL8019AS, NE2000-compatible)  ─IDE-40 ribbon─  ROM/cartridge-port adapter
        │                                                          │
   ISA /IOR //IOW  ◄── decoded from ROM3/ROM4 address strobes ─────┘
        │
   Atari cartridge port ($FA0000 = ROM4, $FB0000 = ROM3)
```

The cartridge port is **read-only** and has **no interrupt line** (driver polls). The
adapter fakes ISA I/O cycles out of ROM address strobes:

- **Reading** ISA register `N`  → CPU reads byte at `ROM4 + (N<<9)` (`$FA0000` base).
  The ROM4 access strobe is decoded into ISA `/IOR`.
- **Writing** ISA register `N` with value `V` → CPU *reads* `ROM3 + (((N<<8)|V)<<1)`
  (`$FB0000` base); ROM3 strobe → ISA `/IOW`, low address lines carry the data.
  **"Writing" is simulated by reading.**

Every access is therefore a read in the **cartridge ROM address space** — and that is the
crux: ROM space is cacheable.

---

## 2. Code map (SRC/)

| File | Lang | Role |
|------|------|------|
| `ENESTNG.C` | Turbo-C 2.0 | STinG glue: install, port struct, ARP. Module entry point. |
| `NESTNG.S`  | DEVPAC asm | `rtrvPckt`/`rtrvStngDgram` — pull packet from card into a STinG datagram. |
| `NE.S`      | DEVPAC asm | Generic 8390/NE2000 core (from Linux `ne.c`): probe, open/close, xmit, polled ISR, receive, reset. |
| `8390.I`    | asm inc    | DP8390 register/bit definitions. |
| `BUS.I`     | asm inc    | Bus-access macros — one of `BUSENE*.I` copied over it at build time. |
| `BUSENEC.I` | asm inc    | Cartridge-port bus macros, **68000**. → `ENEC.STX` |
| `BUSENEC3.I`| asm inc    | Cartridge-port bus macros, **68020+/030**. → `ENEC3.STX` (**the TT build; holds the fix**) |

Every NE.S entry point (`ei_probe1`, `ei_open`, `ei_close`, `ei_start_xmit`,
`ei_interrupt`, `get_stats`) brackets its hardware access with `ldBUSRegs` (load
`a5`=ROM3, `a6`=ROM4) on the way in and `deselBUS` on the way out. `NESTNG.S` runs *nested*
inside `ei_interrupt`, so it needs no bracket of its own. This bracket is where the fix
lives.

---

## 3. Symptoms observed on the TT (HT2 PROM/MAC test)

`HT2ENE.S` resets the card and reads its 32-byte PROM (first 12 bytes = MAC, each byte
doubled). On the TT + NetUSBee:

- ISR after reset read `$83`, `$a5`, `$85`, `$81`, `$c0` — the reset bit (`$80`) always set
  but the low bits unstable / dependent on run history.
- **MAC came back as a constant `3e` repeated** — the remote-DMA read returned the same
  byte for all 32 positions.

## 4. Timing hypothesis — tested and rejected

First hypothesis (matching exxosforum thread 780 and Linux `ne.c`'s use of paused I/O
`inb_p`/`outb_p`, which this port dropped): the ~32 MHz TT bus issues cartridge cycles too
close together for the RTL8019AS, so a recovery delay between accesses is needed.

A sweep of inter-access nop padding (0 → 64 nops, ~0 → ~6 µs per access) was built and run
on the TT. **It never fixed the MAC** — it stayed `3e` at every padding level. A constant
repeated value that is immune to inter-access spacing is not a recovery-time symptom.
Hypothesis rejected; the nop-recovery code was removed.

## 5. Root cause — the 68030 data cache (confirmed)

The data port is always the **same address** (`$FA2000`), read in a loop. On the 68030 the
cartridge ROM window is **cacheable**, so:

1. The first read misses, does a real bus cycle, loads `$3e` into the data cache.
2. Every subsequent read of `$FA2000` is a **cache hit** and returns `$3e` — no bus cycle,
   so the card's remote-DMA pointer never advances.

This is immune to delay (a hit ignores timing) and produces exactly the constant value
seen. It also explains why the Falcon (and AssemSoft's driver, which handles caching)
work while this driver on the TT does not.

**Confirmation:** a build that disabled the 68030 data cache (CACR ED bit) around the
probe, with *no* other change, read the **correct MAC** on the TT and a clean ISR of
`$c0` (RST+RDC). Root cause proven.

---

## 6. The fix (`BUSENEC3.I`)

Bracket every cartridge access block with a data-cache disable/enable:

- `ldBUSRegs` → `cacheDataOff`: `movec CACR,d0` / `and.w #$FEFF,d0` (clear ED) / `movec`.
- `deselBUS`  → `cacheDataOn` : `movec CACR,d0` / `or.w #$0100,d0` (set ED) / `movec`.

Properties, chosen to match STinG's own Lance driver (`cache_off`/`cache_on`) and to keep
it minimal:

- **Data cache only.** No driver code lives in the cartridge window, so the instruction
  cache is left enabled.
- **No flush.** Only the ED enable bit is toggled; the cache is never cleared, so there is
  no per-poll flush cost. The cartridge address never enters the cache (it is only ever
  read with ED=0), so no stale cartridge line can exist.
- **68020+/030 only.** This is the `*3` bus variant; `movec` is always legal here. The
  plain 68000 `BUSENEC.I` variant has no data cache and is untouched.
- `d0` is preserved, so the macros are safe to invoke from the existing bracket points.

Runs in supervisor mode (the driver's context; `movec` is privileged) — same assumption
the Lance driver makes.

## 7. Open item to verify on hardware

Received-packet data is DMA-copied into a freshly `KRmalloc`'d STinG buffer while the data
cache is disabled. If that buffer address happened to be cached with stale contents,
re-enabling the cache could expose stale bytes. STinG's Lance driver has the identical
structure and ships without flushing, so this is expected to be a non-issue — but it is the
one thing to watch when testing real RX/TX. If it ever bites, the remedy is a targeted
data-cache clear (CACR CD bit) in `cacheDataOn`.

---

## 8. Not needed

- **No change to the STinG core** — the fix is entirely in the EtherNEC driver.
- **No migration to Pure C** — the fix is a few lines of assembler in one bus include.
- **No inter-access delays** — the timing theory was disproven on hardware.
