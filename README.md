# Q-SYS Zoom Room Native Controls

A Q-SYS Lua script that bridges Zoom Room Native Controls events to Q-SYS design controls via TCP. The Q-SYS Core acts as a TCP server; each Zoom Room connects as a client and sends text commands that drive boolean controls and triggers inside the Q-SYS design.

## Overview

Zoom Rooms support a "Native Controls" feature where the room can send event-driven commands to a third-party control system over TCP. This script runs inside a Q-SYS Scripting Engine component and:

1. Listens on a dedicated TCP port for incoming connections from a Zoom Room.
2. Parses simple text commands (`optime`, `meeting`, `mute`, `hdmi`, `controls`) with `true`/`false` parameters.
3. Updates corresponding Q-SYS boolean controls and fires triggers.
4. Generates the JSON configuration that must be loaded into the Zoom Room's Native Controls settings.

## Architecture

```
+-------------+        TCP         +------------------+
|  Zoom Room  | -----------------> |  Q-SYS Core      |
|  (client)   |   port 55555-58   |  (TCP server)    |
+-------------+                    +------------------+
                                    |  Lua Script      |
                                    |  (this file)     |
                                    +------------------+
                                           |
                                    Updates Controls[]
                                    Fires Triggers[]
```

Each Q-SYS design instance handles **one Zoom Room**. Up to four rooms are supported across ports 55555-55558, selected via the `0_RoomSelector` control.

## Room-to-Port Mapping

| Room      | TCP Port |
|-----------|----------|
| Room 1    | 55555    |
| Room 2    | 55556    |
| Room 3    | 55557    |
| Room 4    | 55558    |

## Q-SYS Controls Reference

### Configuration Controls

| Control Name       | Type       | Description                                                  |
|--------------------|------------|--------------------------------------------------------------|
| `0_RoomSelector`   | List Box   | Selects which room (and port) this script instance serves.   |
| `0_TCPPort`        | String     | Displays the active TCP port (read-only, set by script).     |
| `20_JSONPreview`   | String     | Displays the JSON payload to paste into Zoom Room settings.  |
| `30_Status`        | Integer    | Connection status indicator. `0` = connected, `4` = disconnected. |

### State Controls (Boolean Pairs)

Each state has two boolean controls: index `[1]` = active/true, index `[2]` = inactive/false. They are complementary (one is always the inverse of the other).

| Control Name       | Index [1] Meaning      | Index [2] Meaning       |
|--------------------|------------------------|-------------------------|
| `1_OperationTime`  | In operation hours     | Outside operation hours |
| `2_ActiveMeeting`  | Meeting in progress    | No active meeting       |
| `3_MicsMuted`      | Microphones muted      | Microphones unmuted     |
| `4_HDMISharing`    | HDMI sharing active    | HDMI sharing inactive   |
| `5_ControlsPage`   | Controls page open     | Controls page closed    |

### Trigger Controls

Triggers fire only when the corresponding TCP command is received (not on manual UI changes).

| Control Name              | Index [1] Fires On     | Index [2] Fires On      |
|---------------------------|------------------------|-------------------------|
| `11_Trig_OperationTime`   | `optime true`          | `optime false`          |
| `12_Trig_ActiveMeeting`   | `meeting true`         | `meeting false`         |
| `13_Trig_MicsMuted`       | `mute true`            | `mute false` (via reset)|
| `14_Trig_HDMISharing`     | `hdmi true`            | `hdmi false`            |
| `15_Trig_ControlsPage`    | `controls true`        | `controls false`        |

### Special Triggers

| Control Name          | Description                                           |
|-----------------------|-------------------------------------------------------|
| `10_Trig_RoomReset`   | Fires when the room state should reset (on disconnect, meeting end, optime start). |

## TCP Command Protocol

Commands are newline-terminated plain text strings sent from the Zoom Room to Q-SYS.

| Command            | Description                          | Side Effects                       |
|--------------------|--------------------------------------|------------------------------------|
| `optime true`      | Operation hours started              | Resets room and mute state         |
| `optime false`     | Operation hours ended                | Resets mute state                  |
| `meeting true`     | Zoom meeting started                 | --                                 |
| `meeting false`    | Zoom meeting ended                   | Resets room and mute state         |
| `mute true`        | Microphones muted                    | --                                 |
| `mute false`       | Microphones unmuted                  | Resets mute (via `resetMute()`)    |
| `hdmi true`        | HDMI content sharing started         | --                                 |
| `hdmi false`       | HDMI content sharing stopped         | --                                 |
| `controls true`    | Zoom Room Controls page opened       | --                                 |
| `controls false`   | Zoom Room Controls page closed       | --                                 |

## Helper Functions

| Function             | Purpose                                                                      |
|----------------------|------------------------------------------------------------------------------|
| `resetMute()`        | Sets mics to unmuted state, fires the unmuted trigger.                       |
| `resetRoom()`        | Fires `10_Trig_RoomReset` for downstream reset logic.                        |
| `resetAllControls()` | Resets all five state control pairs to false/inactive, calls `resetMute()` and `resetRoom()`. Called on disconnect. |

## Zoom Room Configuration

The script auto-generates a JSON configuration block (displayed in `20_JSONPreview`) that must be pasted into the Zoom Room's Native Controls settings. The JSON:

- Points to the Q-SYS Core's LAN B IP address (auto-detected by matching the `172.x.x.x` subnet).
- Uses the selected room's TCP port.
- Defines five "invisible" actions that map Zoom Room lifecycle events to TCP commands via the `rules` block.
- All control styles are set to `invisible=true` so they don't appear in the Zoom Room UI -- they fire automatically from room events.

### Zoom Room Event-to-Rule Mapping

| Zoom Room Event              | Rule Key                      | Action Sent            |
|------------------------------|-------------------------------|------------------------|
| Operation time started       | `zr_operation_time_started`   | `optime true`          |
| Operation time ended         | `zr_operation_time_ended`     | `optime false`         |
| Meeting started              | `zr_zoom_meeting_started`     | `meeting true`         |
| Meeting ended                | `zr_zoom_meeting_ended`       | `meeting false`        |
| Microphone muted             | `zr_microphone_muted`         | `mute true`            |
| Microphone unmuted           | `zr_microphone_unmuted`       | `mute false`           |
| HDMI sharing started         | `zr_hdmi_share_started`       | `hdmi true`            |
| HDMI sharing ended           | `zr_hdmi_share_ended`         | `hdmi false`           |
| Room controls page opened    | `zr_room_controls_opened`     | `controls true`        |
| Room controls page closed    | `zr_room_controls_closed`     | `controls false`       |

## Connection Lifecycle

1. Script starts and calls `startServer(port)` which binds a `TcpSocketServer` on the selected port.
2. `30_Status` is set to `4` (disconnected).
3. When a Zoom Room connects, the socket is added to the `sockets` table and `30_Status` is set to `0` (connected).
4. Incoming data is parsed line-by-line; recognized commands update controls and fire triggers.
5. On disconnect, error, or timeout, the socket is removed. If no sockets remain, all controls reset to defaults and status returns to `4`.

## Manual Event Handlers

Each boolean control pair has UI event handlers that keep the two indices synchronized (toggling one flips the other). These are for manual/UCI interaction only -- triggers are **not** fired from manual changes, only from TCP commands.

## Setup Instructions

1. Add a **Scripting Engine** component to your Q-SYS design.
2. Paste this script into the Scripting Engine code block.
3. Ensure the required named controls are created in the design (see Controls Reference above).
4. Deploy the design to the Q-SYS Core.
5. Select the target room from the `0_RoomSelector` dropdown.
6. Copy the JSON from `20_JSONPreview` and paste it into the Zoom Room's **Native Controls** configuration.
7. The Zoom Room will connect to the Q-SYS Core and begin sending events.

## Files

| File | Description |
|------|-------------|
| `zoom-room-native-controls.lua` | Original script (v1). No reconnection handling. |
| `zoom-room-native-controls-v2.lua` | Improved script (v2). Adds automatic server restart with backoff. **Use this version.** |

## v2 Changes — Resilient TCP Reconnection

The original script had a critical limitation: if the Zoom Room rebooted unexpectedly (power loss, firmware update, network glitch), the TCP connection would break and the Q-SYS `TcpSocketServer` could end up in a state where the port was no longer accepting new connections. The only recovery was rebooting the Q-SYS Core or re-uploading the design.

**v2 fixes this with three mechanisms:**

### 1. Automatic Server Restart on Error/Timeout

When a socket error or timeout event fires and no clients remain connected, the script tears down the entire `TcpSocketServer`, closes all sockets, and creates a fresh server on the same port. This ensures the listening socket is always in a clean state for the Zoom Room to reconnect.

### 2. Exponential Backoff

Restart attempts use exponential backoff (2s, 4s, 8s, 16s, 30s max) to prevent tight restart loops that could overwhelm the Q-SYS scheduler. The backoff resets to 2 seconds whenever a Zoom Room successfully connects.

### 3. Watchdog Timer

A 60-second periodic timer checks server health. If no clients are connected and the status indicates a problem, the server is restarted. This catches silent failures where the server socket dies without producing an error event.

### Additional v2 Improvements

- `closeAllSockets()` helper ensures all tracked sockets are explicitly closed during restart.
- `pcall` wraps `Listen()` so a port-bind failure doesn't crash the script -- it schedules a retry instead.
- `0_RoomSelector` change handler restarts the server on the new port dynamically, without requiring a design re-push.
- All timers (`restartTimer`, `watchdogTimer`) are properly stopped during restart to prevent overlapping operations.

## Known Limitations

- The LAN B IP detection assumes a `172.x.x.x` subnet. Adjust the prefix match if your network uses a different range.
- Up to four rooms are supported (ports 55555-55558). Extend the `roomPorts` table for more.
