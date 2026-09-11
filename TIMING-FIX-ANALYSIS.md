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

## 6. Second finding — alignment-dependent first-access timing (confirmed)

With the data cache handled, results became **build-dependent**: binaries whose probe
bodies were *byte-identical* (verified by instruction-level diff) behaved consistently
differently — one read the MAC perfectly, others returned a *constant* junk byte
(`$31`, `$30`, `$00`), each binary consistent with itself. The only physical difference
was code placement (a 2–4 byte shift from differing prologues).

The key observation: in the PROM read loop, iterations 2+ run warm from the I-cache and
are identical across builds — yet entire reads were junk. A constant from a repeatedly
read data port means the RTL8019's remote-DMA engine **wedged at the first mis-timed
access** and returned the same byte forever after. Whether the *first* accesses are clean
depends on how instruction fetches interleave with the ISA cycles — i.e. code-alignment
luck.

Supporting evidence:
- Disabling the instruction cache too (Lance-style `$fefe`) made it **worse** (constant
  `$00`, occasional crash): then *every* access has fetches interleaved, wedging the chip
  immediately. So the I-cache must stay ON.
- The very first nop-padding sweep (§4) failed only because the data cache was still
  enabled at the time — the pads never reached the hardware. That test was invalid, not
  the idea.

## 7. The validated fix (`BUSENEC3.I`) — both parts, together

1. **`cacheOff` / `cacheOn`** at driver-entry / exit:
   `cacheOff` = `movec CACR,d0` / push / `bclr #8` (ED off) / `bset #11` (CD, clear) /
   `movec` — saves the caller's CACR on the stack; `cacheOn` pops and restores it.
   - Clearing on disable is required: RAM writes made while the cache is off don't update
     pre-existing lines, which are then served stale on re-enable (wrong data + 3-bomb
     crashes from stale stack lines).
   - Instruction cache deliberately left on (see §6).
2. **`RECOVER`** — `NE_RECOVER` nops (default 4) after every `getBUS`/`getMore`/`putBUS`/
   `putMore`/`putBUSi`, so the gap between ISA cycles never depends on alignment.

**Hardware validation (Atari TT, NetUSBee, cold boots):** pads of 2, 4 and 8 nops — three
different code alignments — all read the correct MAC consistently; the unpadded build only
worked at one lucky alignment. A pad-0 build of the refactored macros is byte-identical to
the proven lucky binary, confirming the refactor introduced no drift.

Residual watch item: two startup-time crashes at pads 2 and 8 during BIOS text output
(inside the cache-off window) which subsided on subsequent runs. The real driver performs
no BIOS calls inside its cache-off windows; watch during TX/RX testing.

Open point for the driver port: `NE2RAM` uses `movep.l`, which issues 4 back-to-back ISA
reads within one instruction — software pads cannot go between them. If movep bursts also
wedge the chip on the TT, the bulk-read path must switch to padded single-byte reads
(the `BUS.I`-Hades style loop) on fast machines.

## 8. Not needed

- **No change to the STinG core** — the fix is entirely in the EtherNEC driver.
- **No migration to Pure C** — the fix is assembler in one bus include.
