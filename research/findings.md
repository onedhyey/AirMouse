# Research findings — Amazfit T-Rex Pro as a Mac air mouse

Legend: **[V]** verified on this hardware/source · **[E]** evidence-backed conclusion · **[H]** hypothesis · **[?]** open question

## Hardware / platform
- [V] This unit: firmware **v2.0.4.11**, Bluetooth MAC **C7:FE:…:FB (redacted)** (from the watch's About screen). macOS CoreBluetooth hides MACs, so the MAC is only used to pick the right key from the huami-token output.
- [V] Physical buttons (bezel labels in the user's photo, oriented by the screen text): **upper-right = SELECT, lower-right = BACK, upper-left = UP, lower-left = DOWN**.
- [V] Watch advertises as `Amazfit T-Rex Pro` and connects to the Mac over BLE (experiment 1, 2026-10-29).
- [V] It runs Huami's classic RTOS, **not** Zepp OS: Gadgetbridge models it as `AmazfitTRexProSupport extends AmazfitGTSSupport` (classic Huami protocol, crypt flags `0x80`). Gadgetbridge 0.58.0 added it as "experimental". So Zepp OS mini-apps and sensor APIs **do not apply**. Those only exist on T-Rex 2 and newer.
- [E] No third-party app runtime or custom firmware exists for this model. Only watchface and firmware-file flashing is documented, and flashing firmware is out of scope.

## Native Bluetooth HID — ruled out
- [V] The GATT table has no HID service (0x1812). Services found: Device Info, 1530 (firmware update), FEE0, FEE1, Heart Rate, 1811 (alert notification), 1802 (immediate alert), 3802.
- [E] Nothing in Gadgetbridge or the community suggests a HID mode. "Pair it as a mouse" is not possible without custom firmware, which doesn't exist.

## Raw motion data
- [E] Huami protocol: write `01:03:19`, `01:03:00:00:00:19`, `02` to char `0x0001`, then notifications on `0x0002` carry packets of type `0x00`, made of int16 x,y,z accelerometer triples (≈ ±4100 per g). Source: Gadgetbridge `HuamiSupport.setRawSensor/handleRawSensorData` (used for Sleep as Android).
- [E] **Accelerometer only.** Gadgetbridge decodes no gyroscope type. Type `0x01` is undocumented, and the hardware gyro (if any) isn't exposed. So yaw rotation (turning about gravity) can't be sensed. Only **tilt** (pitch/roll relative to gravity) is measurable.
- [V] With auth: 25 Hz accelerometer, delivered in 20-sample batches every 0.81 s (fixed by firmware; Exp 5/6). Expect 0–0.8 s added latency.
- [V] Without authentication, the start commands get no reply and no data. The watch also disconnects after about 30 s.
- [?] Sample rate and latency on this model (Mi Band devices batch roughly per second, which would feel laggy). This needs measuring after auth.

## Buttons / touchscreen
- [E] Char `0x0010` (device events) reports: `0xFE xx` music control (00 play, 01 pause, 03 next, 04 prev, 05 vol+, 06 vol−, E0/E1 music screen open/closed), `0x04`/`0x0B` button press/long press (Mi Band "button actions"), plus call/find-phone events.
- [H] With the watch's Music screen open, some physical buttons and on-screen taps produce music-control events. These are the only watch inputs a host can see. Which of the four buttons emit what still needs testing on the device.
- [E] There is no event for arbitrary touchscreen swipes in the protocol. Swipe scrolling is likely impossible, so physical-button scrolling is the fallback.

## Connection behaviour
- [V] Exp 2/3: with the phone connected, the watch didn't advertise. With phone Bluetooth off (Exp 3) it advertised again within 4 s and the Mac connected. Huami watches stop advertising while connected to a central (the phone's Zepp app). For the Mac to find it, the phone must be disconnected (phone Bluetooth off or Zepp force-stopped).
- [E] The watch is a BLE peripheral. It never appears or pairs in System Settings → Bluetooth, and it doesn't need to. The bridge app connects to it directly.

## Button events (measured)
- [V] Physical presses produce only `04` (BUTTON_PRESSED, no payload), and not for every press (Exp 7/8). [?] Which button(s) or conditions trigger it. The guided `buttontest` will settle this.
- [V] Gadgetbridge lists **Music** as a T-Rex Pro app-list item (`pref_trex_pro_display_items_values`). It can be hidden, which is likely why it isn't on the watch. It can be enabled from the Zepp app's app-list settings.
- [V] `0e` = 30-minute tick. `13:00` appears right after each (re)connect.

## Authentication — current blocker
- [V] Handshake (Gadgetbridge `InitOperation`, implemented in `watch-bridge/Sources/main.swift`): notify on `0x0009`, write `82:00:02:01:00`, receive `10:82:01 + 16 random bytes`, write `83:00 + AES-128-ECB(random, authKey)`, receive `10:83:01` on success.
- [E] The 16-byte key is generated when the watch is paired with the Zepp app, and it's stored on Huami servers. It can't be generated locally. The usual way to fetch it is [huami-token](https://codeberg.org/argrento/huami-token) with your own Zepp account login. Re-pairing the watch changes the key.
- [H] The watch keeps one central connection at a time. While the Mac is connected, the phone's Zepp app may lose its connection (and vice versa).

## macOS environment
- [V] macOS 26.6.1, M4, Swift 6.4, Python 3.13.
- [V] BLE from a process launched by the CLI aborts (TCC: no `NSBluetoothAlwaysUsageDescription`). Fix: ship the bridge as its own ad-hoc-signed `.app` bundle with a usage string, which gets a normal permission prompt. No security bypass.

## Sources
- Gadgetbridge source (codeberg Freeyourgadget/Gadgetbridge @ 2026-10-27): `HuamiService`, `HuamiSupport`, `InitOperation`, `AmazfitTRexProCoordinator`, `AmazfitGTSSupport`
- https://gadgetbridge.org/blog/release-0_58_0/ (T-Rex Pro support)
- https://www.gadgetbridge.org/basics/pairing/huami-xiaomi-server/ (auth key comes from the server)
