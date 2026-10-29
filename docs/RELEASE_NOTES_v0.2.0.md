# NS3FB iOS — v0.2.0

Second public build. **Bug fixes only**: no new features, no change to performance
or resolution. The goal of this release is to make story mode actually playable.

Baseline: iPhone 11 (A13), iOS 27, 960×540, solid ~30 fps.

---

## 🐛 Fixed

### 1. Story mode: the character would not move

The game called three functions through pointers that the codegen did not know
about. They ran as **no-ops**, so the "can I act?" check returned *false* and the
character stayed frozen while the engine kept drawing at 30 fps.

| Address | What it is |
|---|---|
| `0x821E82C8` | constructor of `ccAdvMobObj` (adventure-mode objects) |
| `0x825A73F8` | the action check that decides whether an action may run |
| `0x825A7378` | the return stub of another one of those checks |

They are now seeded in `ci/entrypoint_seeds.txt`, together with **19 vtable
thunks** (16-byte virtual-call trampolines) that were also missing. Result: the
character moves again and story mode no longer locks up.

### 2. Crash when entering certain story-mode screens

An intermediate build tried to redirect those calls to whichever function
"seemed" to contain them. It picked an unrelated one and the game died with
`Unhandled guest access violation: read of guest 0x00000004`.

That redirector is now **disabled entirely**. No code path in the port can send a
call to the wrong function any more: if something cannot be resolved it runs as a
no-op and the game keeps going, instead of crashing.

### 3. Four unresolved conditional branches at codegen time

The codegen itself listed them while recompiling:

```
Unresolved conditional branch to 0x82261E40, 0x82296DF0, 0x82353E10, 0x827D5CBC
```

All four were interior code of functions the analyser never discovered. The real
function start of each was seeded instead:

| Target | Function seeded |
|---|---|
| `0x82261E40` | `0x82261BA0` |
| `0x82296DF0` | `0x82296C68` |
| `0x82353E10` | `0x82353D90` |
| `0x827D5CBC` | `0x827D5BD8` |

### 4. `setjmp` / `longjmp` declared in the manifest

The project never declared them. Without them the codegen compiles `longjmp` as
an ordinary call that returns — but the compiler already omitted the epilogue, so
`r1` and the callee-saved registers end up corrupted.

The CRT pair was identified by its signature (they save and restore the
non-volatiles using **the exact same slot layout**) and
`scripts/02b-set-jumptargets.py` writes them on every build:

```toml
[entrypoint]
setjmp_address  = 0x828A7F20
longjmp_address = 0x828A81F0
```

> Honest note: this removes a whole class of corruption, but it does **not** fix
> the combo bug described below. That was verified with measurements.

---

## ⚠️ Known issue: the mob-battle combo does not advance

In **mob battles** (multi-wave fights) the game shows a button on screen — `A`,
`B`… — that you have to press to chain the special attack. In this port the
prompt **stays there and never advances**.

What has already been ruled out, using measurements from the game itself:

| Check | Result |
|---|---|
| Does the press reach the game? | **Yes**: 260 presses of `B` seen by the guest |
| Does logic run faster than the image? | **No**: 30.0 logic frames/s vs 30.0 presented |
| Are button events being dropped? | The game polls state, it does not use events, and state arrives |
| Is it a missing entrypoint? | The traps are epilogue fragments, not functions |

Related symptom: the chapter achievement fires **several times in a row**, which
points at a sequence being re-executed in a loop. Still under investigation.

---

## 🔧 Diagnostics that stay in the build

Useful when reporting bugs, and **not noisy**: 2–3 lines per second.

```
NS3FB-BUILD compiled <date> <time>          which binary produced the log
NS3FB-INPUT keydown vk=0x5801 flags=0x0001  presses that reach the guest
NS3FB-INPUT-FRAMES polls=30.0/s ...         how often the game polls the pad
NS3FB-GUEST-FRAMES swaps=30.0/s ...         frames the game asks to present
```

To silence it: create `Documents/input_trace_off.txt` and relaunch the game.

---

## 📦 Installing

Same as before: **unsigned** `.ipa`, signed with SideStore, AltStore, Sideloadly
or your own certificate. Requirements and steps in the [README](README.md). You
must supply your own NTSC-U `default.xex` (SHA-1 `f7ad65e2…55e9f`) — if the hash
does not match, the port will not boot.

**When changing version, uninstall before reinstalling** so iOS does not keep the
cached icon.

---

## Overall status

| Part | Status |
|---|---|
| Boot, menus, character select | ✅ |
| VS Battle, practice, HUD, particles, audio | ✅ |
| Story mode (movement, events, chapters) | ✅ |
| **Mob-battle combo** | ⚠️ pending |
| 1280×720 | ❌ ~18 fps — SDK ceiling |
| 60 fps | ❌ the game is frame-locked at 30 by design |

Full technical history of these fixes in
[`docs/INTERIOR_ENTRIES.md`](INTERIOR_ENTRIES.md) and
[`docs/INPUT_TRACE.md`](INPUT_TRACE.md).
