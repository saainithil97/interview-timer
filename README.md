# TimerBar

A tiny macOS menu bar timer for multi-part coding interviews (e.g. Stripe on HackerRank).

Shows **which part you're on and how much time is left** right in the menu bar, so you never
have to alt-tab to check the clock.

```
menu bar:   Part 2 12:34     (orange at the warning mark, red at 0:00)
            ● Part 2 12:34   (green dot + highlighted pill while running)
```

The flow is always **Read → Part 1 → Part 2 → … → Review**, split from one time budget:

| Phase | Default | Warning |
|---|---|---|
| Read + setup | 3 min | 1 min left |
| Work parts | 52 min split evenly across 3 or 4 parts | 3 min left |
| Review + cleanup | 5 min | 1 min left |

So a 4-part problem is `Read 3:00 → Part 1 13:00 → Part 2 13:00 → Part 3 13:00 → Part 4 13:00 → Review 5:00`
(60 min total), and a 3-part problem is `Read 3:00 → Part 1 17:20 → Part 2 17:20 → Part 3 17:20 → Review 5:00`.

While the clock is actually counting, the menu bar item shows a green dot and keeps the same
highlighted pill look it gets when you click it. Paused, it goes back to plain text — so you can
tell at a glance whether time is moving without opening the menu.

## Run it

```bash
open /Applications/TimerBar.app
```

There is no Dock icon — look for `Read 3:00` in the menu bar. Click it for the dropdown.

## 3-part vs 4-part problem

Click the menu bar item and pick **3-part problem** or **4-part problem**. That's the whole
workflow — no config editing.

Switching **keeps the time you've already spent**. If you read for 3 minutes assuming 4 parts and
then discover it's a 3-part problem, the 3 minutes stay consumed and the remaining 57 minutes are
re-split across Read/Part 1/Part 2/Part 3/Review. The clock never jumps backwards.

## Configure

Click the menu bar item → **Edit parts…** (opens `~/.config/timerbar/config.json` in TextEdit),
edit, save, then choose **Reload parts (resets timers)**.

```json
{
  "problemParts": 4,
  "readMinutes": 3,
  "workMinutes": 52,
  "reviewMinutes": 5,
  "readWarnMinutes": 1,
  "partWarnMinutes": 3,
  "reviewWarnMinutes": 1,
  "warnMinutes": 2,
  "autoAdvance": true,
  "compact": false
}
```

- `problemParts` — 3 or 4 (1–8 works). `workMinutes` is split evenly across this many parts.
- `readMinutes` / `workMinutes` / `reviewMinutes` — the three phases of the interview.
- `readWarnMinutes` / `partWarnMinutes` / `reviewWarnMinutes` — when the menu bar turns orange and
  beeps, per phase. `0` disables that phase's warning.
- `warnMinutes` — global fallback, only used if a part has no warning of its own.
- `autoAdvance` — at 0:00, beep, then automatically start the next phase.
- `compact` — show only `12:34` instead of `Part 2 12:34`.

### Custom parts (advanced)

If you want uneven parts or your own names, add a `parts` array. When it is present, the
Read/work/review fields above are ignored:

```json
{
  "parts": [
    { "name": "Read + setup", "short": "Read", "minutes": 3, "warnMinutes": 1,
      "hint": "Skim both problems, set up 2-3 test cases" },
    { "name": "Part 1", "minutes": 15, "warnMinutes": 3 },
    { "name": "Part 2", "minutes": 12, "warnMinutes": 3 },
    { "name": "Part 3", "minutes": 13, "warnMinutes": 3 },
    { "name": "Part 4", "minutes": 12, "warnMinutes": 3 },
    { "name": "Review + cleanup", "short": "Review", "minutes": 5, "warnMinutes": 1 }
  ]
}
```

- `short` — menu bar label (falls back to `name`, truncated to ~10 chars).
- `warnMinutes` — per-part warning; falls back to the global `warnMinutes`.
- `hint` — a checklist line shown in the menu under the active part, and as a quiet notification
  when the part starts.

Picking **3-part problem** / **4-part problem** from the menu clears the custom `parts` array and
goes back to the generated layout.

## Why the parts aren't split into "read → tests → logic → verify"

That breakdown is a *checklist*, not a schedule. You can't predict whether a part needs 4 minutes of
tests or 1, so fixed sub-timers would beep at the wrong moments — and 16 extra notifications across
four parts would pull you out of flow. The 13-minute cap per part is the real guardrail against
overrunning.

So each part carries a `hint` instead: **Tests first, then logic, then verify.** It shows under the
active part in the menu and appears once when the part starts. No extra timers, no extra beeps.

## Menu reference

| Item | What it does |
|---|---|
| Part rows | Click any part to jump to it (checkmark = current) |
| Hint line | Grey checklist reminder for the active part |
| Start / Pause | Start or pause the current part (`P`) |
| Skip to next part | Jump ahead without finishing (`N`) |
| +1 / +5 min | Extend the current part if you're overrunning |
| Total left | Sum of all remaining time |
| 3-part / 4-part problem | Re-split the work budget (keeps elapsed time) |
| Auto-advance | Toggle auto-start of the next part at 0:00 |
| Compact menu bar | Show time only |
| Edit parts… | Open the config file (`E`) |
| Reload parts | Re-read config and reset all timers (`R`) |
| Reset all timers | Back to the full durations |
| Quit TimerBar | Saves state first (`Q`) |

State is saved to `~/.config/timerbar/state.json` on quit and when a part expires, so if the app
restarts within 12 hours it picks up where you left off (paused).

## Build from source

Requires only the Xcode Command Line Tools.

```bash
cd ~/work/projects/interview-timer
./build.sh          # produces TimerBar.app
cp -R TimerBar.app /Applications/
open /Applications/TimerBar.app
```

## Interview-day setup

1. Set your budget the night before, and run one dry run so the durations are right.
2. Start TimerBar before the interview and confirm `Read 3:00` appears.
3. Click the item, press **Start**, then switch to HackerRank — the menu bar keeps counting.
4. Read the prompt; if it's a 3-part problem, click **3-part problem** and the rest re-splits itself.
5. Keep notifications on for the app/Terminal so the warning and time-up beeps show.
6. Optional: add `open /Applications/TimerBar.app` to Login Items
   (System Settings → General → Login Items) so it's always there.
7. If macOS hides it because the menu bar is crowded (notch), quit some menu bar apps.

Tip: the 3-minute Read and 5-minute Review are the phases people skip. Leave them in — they're
worth more than 8 extra minutes on Part 2.
