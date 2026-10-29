# AirMouse

Turn an **Amazfit T-Rex Pro** into a handheld air mouse for a Mac. You hold the watch in your fist like a TV remote, tilt it, and the cursor moves. Press a button to click.

No custom firmware, no phone, no app on the watch. A small background program on the Mac talks to the watch over Bluetooth, reads its motion sensor, and turns that into mouse movement.

It works. It also has about half a second of lag that no amount of clever code on the Mac side can remove. Both of those facts are explained below.

---

## Contents

- [How it works (the short version)](#how-it-works-the-short-version)
- [How it works (the longer version)](#how-it-works-the-longer-version)
- [What you need](#what-you-need)
- [Setup](#setup)
- [Using it](#using-it)
- [Tuning](#tuning)
- [Limitations](#limitations)
- [Troubleshooting](#troubleshooting)
- [Repository layout](#repository-layout)
- [Credits](#credits)

---

## How it works (the short version)

Your watch has an **accelerometer**, a tiny sensor that measures which way gravity is pulling. If you tilt the watch, gravity "moves" inside the watch, and the sensor can tell how far you tilted it.

AirMouse:

1. connects to the watch over Bluetooth and proves it's allowed to (using a secret key, like a password),
2. asks the watch to stream its accelerometer readings, 25 per second,
3. works out how much you tilted the watch since the last reading,
4. moves the cursor by that amount,
5. listens for button presses and turns them into clicks.

Twist your wrist to go left and right. Tip the watch up and down to go up and down.

## How it works (the longer version)

### Why not just pair it as a Bluetooth mouse?

Because it isn't one. Mice and keyboards announce themselves with a standard Bluetooth "HID" service. The T-Rex Pro doesn't have one. I checked its full list of services, and it's all fitness, notifications and firmware update. "Pairing" the watch with your Mac and "the watch being a mouse" are two completely different things, and only the first one is possible out of the box.

### The protocol

The T-Rex Pro runs Huami's older real-time OS, not Zepp OS. So there are no third-party watch apps, and the Zepp OS sensor APIs don't exist on it. It does speak the same Bluetooth protocol as the rest of the classic Huami/Amazfit family, which the [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge) project reverse-engineered years ago. AirMouse uses the parts it needs:

| What | How |
|---|---|
| Authentication | Characteristic `0x0009`: request a 16-byte random challenge (`82 00 02 01 00`), encrypt it with AES-128-ECB using the device's auth key, send it back (`83 00 …`), receive `10 83 01` |
| Raw accelerometer | Write `01 01 00 00 00 19` then `02` to `0x0001`; notifications on `0x0002` carry int16 x/y/z triples, about 4100 counts per *g* |
| Button events | Notifications on `0x0010`: `04` = short press, `0b` = long press |

AES in ECB mode on a single block, with a static per-device key, is not something a cryptography course would hold up as an example of good design. It is, however, what the watch expects.

### The lag, and why it's the watch's fault

I measured the stream. The watch samples at 25 Hz, but doesn't send each sample as it's taken. It collects **20 samples and sends them as a batch every 0.81 seconds**. I tried 9 variations of the start command and 4 ways of forcing an early flush. The batch size and timing didn't change. It's fixed in the firmware.

So any motion you make reaches the Mac between 0 and 0.8 s later, about 0.4 s on average. AirMouse can't make that shorter. It can only avoid making it longer:

- **Fast replay.** Each batch covers 0.81 s of real time, but it's replayed in 0.35 s, so the cursor catches up quickly instead of trailing a full batch behind.
- **Position-like control, not velocity control.** The cursor moves by the *change* in tilt angle, not at a speed set by the tilt. With velocity control ("tilt = keep moving"), a 0.8 s delay means the cursor keeps going after you've stopped, and you overshoot every target. With position-like control, when your hand stops, the cursor stops in the right place, just a bit late.
- **100 Hz output.** Cursor updates are spread out at 100 Hz rather than applied in 25 jumps per second, so motion looks continuous.

### Why only tilting works (and not sweeping)

An accelerometer at rest only sees gravity. If you rotate the watch *around* the gravity vector (holding it flat and sweeping it left and right like a flashlight), the gravity vector inside the watch doesn't change, so there's nothing to measure. A gyroscope would catch that rotation. The T-Rex Pro has one, but this protocol doesn't expose it.

In other words, yaw is unobservable from a gravity measurement, and you get two degrees of freedom out of three. Hence: **twist** your wrist (roll) for left/right, **tip** the watch (pitch) for up/down.

The upside is that gravity doesn't drift. A gyro-only air mouse slowly wanders as its integration errors pile up. This one doesn't, because its reference is the planet.

### Turning tilt into cursor motion

For each sample:

1. Lightly smooth the raw gravity vector and normalise it.
2. Express it in a basis built from calibration: `g₀` (your neutral pose), `u` (the "right" direction) and `v` (the "up" direction), each projected perpendicular to `g₀`. The two angles are `atan2(g·u, g·g₀)` and `atan2(g·v, g·g₀)`.
3. Run each angle through a **[1€ filter](https://gery.casiez.net/1euro/)** (Casiez et al., CHI 2012). It's an adaptive low-pass filter: it smooths heavily when you're nearly still, which removes hand tremor, and barely at all when you move fast, so it adds little lag. In simulation (`research/filter-sim.swift`) it cuts tremor jitter by about 96% while a deliberate 30° twist still crosses most of the screen.
4. Take the angle change since the last sample, pass it through a soft dead zone (`d·d²/(d²+t²)`, so tiny movements fade out instead of snapping off), multiply by a gain with mild acceleration, and add the result to the cursor.

### Buttons

I mapped what the watch reports with a guided test: the Mac speaks each instruction aloud and logs whatever arrives in the next 6 seconds.

| Input on the watch | What the Mac receives |
|---|---|
| SELECT, UP, DOWN (short press) | `04` (all three identical) |
| SELECT (long press) | `0b` |
| BACK | nothing |
| Touchscreen taps and swipes | nothing |

That's two distinguishable inputs. So clicks are counted: one press, two presses, three presses. More on that under [Using it](#using-it).

---

## What you need

- An **Amazfit T-Rex Pro**. This is tested on firmware 2.0.4.11. Other classic (pre–Zepp OS) Huami watches such as the GTS family may work, but none have been tested.
- A **Mac** with Bluetooth. Built and tested on an M4 MacBook Air with macOS 26. It needs Xcode's command-line tools (`xcode-select --install`) for `swiftc`.
- The watch's **auth key** (see below).
- A **Zepp account** with email and password login, with the watch paired to it.

No third-party Swift packages. It uses only Apple's own frameworks: CoreBluetooth, CoreGraphics, CommonCrypto.

## Setup

### 1. Get your watch's auth key

The watch only talks to devices that know its 16-byte key. The key is created when you pair the watch with the Zepp app and is stored on Zepp's servers. You can't generate it yourself.

[huami-token](https://codeberg.org/argrento/huami-token) fetches it by logging in to your own account:

```bash
git clone https://codeberg.org/argrento/huami-token.git
cd huami-token
uv venv && uv pip install -e .
uv run huami-token --method amazfit --email YOU@example.com --password 'YOUR_PASSWORD' --bt_keys
```

Look for your watch's MAC address (on the watch: Settings → About) and copy the `Key` next to it. It looks like `0x` followed by 32 hex characters.

Two warnings:

- That tool prints debug output that **includes your password**. Don't paste it anywhere.
- If you unpair and re-pair the watch, the key changes and you'll need to fetch it again.

### 2. Clone and configure

```bash
git clone https://github.com/<you>/AirMouse.git
cd AirMouse/watch-bridge
cp config.example.json config.json
```

Open `config.json` and put your key in:

```json
{ "authKey": "0x0123456789abcdef0123456789abcdef" }
```

`config.json` is git-ignored. Keep it that way: anyone with the key and Bluetooth range can talk to your watch.

### 3. Build

```bash
./build.sh
```

This compiles the Swift sources into `build/AirMouse.app`, a background app with no Dock icon. It's an app bundle rather than a bare binary because macOS only allows Bluetooth for programs that say why they need it, and that explanation lives in the bundle's `Info.plist`.

### 4. Free the watch from your phone

The watch accepts **one** Bluetooth connection at a time, and while it's connected to your phone it stops advertising, so the Mac can't find it. Turn off Bluetooth on your phone (or force-quit the Zepp app) while you use AirMouse.

### 5. First run and permissions

```bash
./airmouse run
```

macOS will ask for two permissions:

1. **Bluetooth.** Click Allow.
2. **Accessibility** (needed to move the cursor and click). Go to System Settings → Privacy & Security → Accessibility and switch on **AirMouse**. The app checks every two seconds and says *"Mouse control enabled"* when it's granted.

The app is signed so that macOS recognises it by its bundle ID (`local.airmouse.bridge`) rather than by a hash of the binary. That way the permission survives rebuilds. If it ever gets stuck saying it needs permission while the switch is already on, remove AirMouse from the list with **–** and add it again.

### 6. Calibrate

```bash
./airmouse calibrate
```

Hold the watch the way you'll use it, and follow the voice. At each *tink*, get into the pose and hold it until the *pop*:

1. Hold still in your neutral pose.
2. Twist your wrist about a quarter turn clockwise (this becomes "right").
3. Go back to neutral.
4. Tip the watch up (this becomes "up").

You'll hear *"Calibration saved."* Hold each pose for the whole tink-to-pop window. The watch's data arrives late, so a quick wiggle gets missed.

Then start it for real:

```bash
./airmouse run
```

## Using it

| On the watch | On the Mac |
|---|---|
| Twist your wrist | Cursor moves left / right |
| Tip the watch up / down | Cursor moves up / down |
| 1 press (SELECT, UP or DOWN) | Left click |
| 2 quick presses | Right click |
| 3 quick presses | Pause / resume |
| Long-press SELECT | Toggle scroll mode (tilting scrolls the page instead) |

**Pause** works as a clutch, like lifting a mouse off the desk. Pause, move your hand to a comfortable spot, resume. Resuming takes your new pose as neutral and doesn't move the cursor.

**Single clicks wait 0.45 s** to make sure a second press isn't coming. That's the price of fitting four actions onto one kind of button event.

These buttons still do their normal job on the watch too: SELECT may open things, UP and DOWN may scroll the watch's screen. The watch has no idea it's moonlighting as a mouse.

Other commands:

```bash
./airmouse stop         # stop it
./airmouse log          # follow the live log
./airmouse probe        # connect and log raw sensor data, no mouse
./airmouse buttontest   # the spoken button-mapping test
```

## Tuning

Everything lives in `watch-bridge/config.json`. Restart (`./airmouse run`) to apply; no rebuild needed.

| Key | Default | What it does |
|---|---|---|
| `gain` | 1600 | Cursor pixels per radian of tilt. Higher = more sensitive. |
| `acceleration` | 10 | Extra speed for fast movements. 0 = none. |
| `playbackSeconds` | 0.35 | How fast each 0.81 s batch is replayed. Lower = less lag but more "glide, pause, glide". |
| `glide` | 0.35 | Output smoothing at 100 Hz. Lower = smoother but slightly laggier. |
| `tremorCutoff` | 0.3 | 1€ filter cutoff in Hz when you're still. Lower = more tremor removed. |
| `tremorBeta` | 4 | How quickly the filter loosens up when you move fast. |
| `deadband` | 0.003 | Soft dead zone (radians per sample). |
| `invertX`, `invertY` | false | Flip a direction. |
| `multiPressWindow` | 0.45 | Seconds to wait for a second or third press. |
| `scrollGain` | 1.0 | Scroll speed in scroll mode. Negative flips it. |

## Limitations

- **0–0.8 s of lag**, from the watch's batching. Fine for clicking buttons and slides. Not fine for games.
- **No sweeping.** Turning the watch flat left/right can't be sensed. Only tilting and twisting can.
- **Big, sudden arm movements** register as brief tilts, because an accelerometer can't fully separate gravity from your hand accelerating. The filter catches most of it, not all.
- **BACK and the touchscreen aren't available.** The watch doesn't report them over Bluetooth.
- **The phone has to let go** of the watch while you use it.
- **One watch model tested.** Reports from other classic Huami devices are welcome.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| Never finds the watch | The phone is still connected to it. Turn off the phone's Bluetooth. |
| `AUTH FAILED` in the log | Wrong key, or the watch was re-paired since you fetched it. |
| Watch disconnects after ~30 s | Authentication never succeeded (the watch drops unauthenticated connections). |
| Says it needs Accessibility, but the switch is on | Remove AirMouse with **–**, add it again with **+**. |
| Cursor goes the wrong way | Re-run `calibrate`, or set `invertX` / `invertY`. |
| Calibration fails | You didn't hold the pose long enough or tilt far enough. Hold for the whole tink-to-pop window. |
| A command seems to do nothing | Use `./airmouse …` rather than `open` directly. It waits for the old instance to quit first. |

Everything that happens is written to `watch-bridge/logs/airmouse.log`.

## Repository layout

```
watch-bridge/
  Sources/main.swift     BLE connection, Huami auth, sensor and button handling, modes
  Sources/Motion.swift   tilt → cursor maths, 1€ filter, mouse output, calibration
  build.sh               compiles and signs build/AirMouse.app
  airmouse               launcher: run | calibrate | probe | buttontest | stop | log
  config.example.json    copy to config.json and add your key
research/
  findings.md            what's verified, what's inferred, what's still open
  progress.md            the experiment log, failures included
  filter-sim.swift       offline simulation used to tune the tremor filter
```

## Credits

- **[Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge)** for documenting the Huami protocol. AirMouse contains no Gadgetbridge code, but it would not exist without their reverse engineering.
- **[huami-token](https://codeberg.org/argrento/huami-token)** for getting the auth key out of Zepp's servers.
- **Casiez, Roussel and Vogel**, *1€ Filter: A Simple Speed-based Low-pass Filter for Noisy Input in Interactive Systems*, CHI 2012.

This project isn't affiliated with Amazfit, Zepp Health or Huami. It uses your own watch, your own key and your own account. Please don't point it at anyone else's watch.

## License

MIT. See [LICENSE](LICENSE).
