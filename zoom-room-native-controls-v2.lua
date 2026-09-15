-- TCP — Single Zoom Room instance (v2 — resilient reconnection)
-- Room is selected via 0_RoomSelector List Box. Selected string maps to port 55555–55558.
--
-- v2 changes:
--   - On socket error/close/timeout, the TCP server is torn down and restarted
--     so the Zoom Room can reconnect without a Core reboot.
--   - A restart timer with backoff prevents tight restart loops.
--   - Server health is monitored with a periodic watchdog timer.

local roomPorts = {
  ["Room 1"] = 55555,
  ["Room 2"] = 55556,
  ["Room 3"] = 55557,
  ["Room 4"] = 55558,
}

Controls['0_RoomSelector'].Choices = {"Room 1", "Room 2", "Room 3", "Room 4"}
local selection = Controls['0_RoomSelector'].String
local port = roomPorts[selection]
if not port then
  print("ZR WARNING: No room selected or unrecognized value '" .. tostring(selection) .. "'. Defaulting to Room 1 (port 55555).")
  port = 55555
end

local sockets = {}

Controls['0_TCPPort'].String = tostring(port)
Controls['30_Status'].Value = 4

local lanBIP = "0.0.0.0"
local ifaces = Network.Interfaces()
if ifaces then
  for _, iface in ipairs(ifaces) do
    if iface.Address and iface.Address:sub(1, 3) == "172" then
      lanBIP = iface.Address
      break
    end
  end
end

local jsonPreview = string.format([[{
  "adapters": [
    {
      "model": "GenericNetworkAdapter",
      "ip": "tcp://%s:%d",
      "ports": [
        {
          "id": "qsys_core",
          "methods": [
            {
              "id": "1_OperationTime",
              "name": "Operation Time",
              "command": "optime %%\r\n",
              "params": [
                {"id": "true", "name": "True", "value": "true"},
                {"id": "false", "name": "False", "value": "false"}
              ],
              "type": "actions"
            },
            {
              "id": "2_ActiveMeeting",
              "name": "Active Meeting",
              "command": "meeting %%\r\n",
              "params": [
                {"id": "true", "name": "True", "value": "true"},
                {"id": "false", "name": "False", "value": "false"}
              ],
              "type": "actions"
            },
            {
              "id": "3_MicsMuted",
              "name": "Mics Muted",
              "command": "mute %%\r\n",
              "params": [
                {"id": "true", "name": "True", "value": "true"},
                {"id": "false", "name": "False", "value": "false"}
              ],
              "type": "actions"
            },
            {
              "id": "4_HDMISharing",
              "name": "HDMI Sharing",
              "command": "hdmi %%\r\n",
              "params": [
                {"id": "true", "name": "True", "value": "true"},
                {"id": "false", "name": "False", "value": "false"}
              ],
              "type": "actions"
            },
            {
              "id": "5_ControlsPage",
              "name": "Room Controls Page",
              "command": "controls %%\r\n",
              "params": [
                {"id": "true", "name": "True", "value": "true"},
                {"id": "false", "name": "False", "value": "false"}
              ],
              "type": "actions"
            }
          ]
        }
      ]
    }
  ],
  "styles": [
    "qsys_core.1_OperationTime.invisible=true",
    "qsys_core.2_ActiveMeeting.invisible=true",
    "qsys_core.3_MicsMuted.invisible=true",
    "qsys_core.4_HDMISharing.invisible=true",
    "qsys_core.5_ControlsPage.invisible=true"
  ],
  "rules": {
    "zr_operation_time_started": ["qsys_core.1_OperationTime.true"],
    "zr_operation_time_ended": ["qsys_core.1_OperationTime.false"],
    "zr_zoom_meeting_started": ["qsys_core.2_ActiveMeeting.true"],
    "zr_zoom_meeting_ended": ["qsys_core.2_ActiveMeeting.false"],
    "zr_microphone_muted": ["qsys_core.3_MicsMuted.true"],
    "zr_microphone_unmuted": ["qsys_core.3_MicsMuted.false"],
    "zr_hdmi_share_started": ["qsys_core.4_HDMISharing.true"],
    "zr_hdmi_share_ended": ["qsys_core.4_HDMISharing.false"],
    "zr_room_controls_opened": ["qsys_core.5_ControlsPage.true"],
    "zr_room_controls_closed": ["qsys_core.5_ControlsPage.false"]
  }
}]], lanBIP, port)

Controls['20_JSONPreview'].String = jsonPreview
print("LAN B IP: " .. lanBIP)


-- ============================================================
-- Helper functions
-- ============================================================

local function resetMute()
  print("resetMute")
  Controls['3_MicsMuted'][1].Boolean = false
  Controls['3_MicsMuted'][2].Boolean = true
  Controls['13_Trig_MicsMuted'][2]:Trigger()
end

local function resetRoom()
  print("resetRoom")
  Controls['10_Trig_RoomReset']:Trigger()
end

local function resetAllControls()
  print("resetAllControls")
  Controls['1_OperationTime'][1].Boolean = false
  Controls['1_OperationTime'][2].Boolean = true
  Controls['2_ActiveMeeting'][1].Boolean = false
  Controls['2_ActiveMeeting'][2].Boolean = true
  Controls['4_HDMISharing'][1].Boolean = false
  Controls['4_HDMISharing'][2].Boolean = true
  Controls['5_ControlsPage'][1].Boolean = false
  Controls['5_ControlsPage'][2].Boolean = true
  resetMute()
  resetRoom()
end


-- ============================================================
-- Socket table management
-- ============================================================

local function removeSocket(sock)
  for k, v in pairs(sockets) do
    if v == sock then
      table.remove(sockets, k)
      return
    end
  end
end

local function closeAllSockets()
  for _, sock in ipairs(sockets) do
    pcall(function() sock:Close() end)
  end
  sockets = {}
end


-- ============================================================
-- Server lifecycle (v2 — resilient restart)
-- ============================================================

local ZR                          -- TcpSocketServer instance
local restartTimer = Timer.New()  -- delayed restart timer
local watchdogTimer = Timer.New() -- periodic health check
local restartPending = false      -- guard against overlapping restarts

-- Backoff state
local RESTART_DELAY_INITIAL = 2   -- seconds
local RESTART_DELAY_MAX     = 30  -- seconds
local restartDelay = RESTART_DELAY_INITIAL

local function resetBackoff()
  restartDelay = RESTART_DELAY_INITIAL
end

local function nextBackoff()
  restartDelay = math.min(restartDelay * 2, RESTART_DELAY_MAX)
end


-- Forward declaration
local startServer


-- Schedule a server restart after a delay (with backoff).
-- Safe to call multiple times; only one restart will be queued.
local function scheduleRestart(reason)
  if restartPending then return end
  restartPending = true
  print(string.format("ZR scheduleRestart: reason=%s, retrying in %ds", reason, restartDelay))
  restartTimer:Stop()
  restartTimer.EventHandler = function()
    restartTimer:Stop()
    restartPending = false
    print("ZR scheduleRestart: executing restart now")
    startServer(port)
  end
  restartTimer:Start(restartDelay)
  nextBackoff()
end


-- ============================================================
-- ZR event handler
-- ============================================================

local function SocketHandler(sock, event)
  if event == TcpSocket.Events.Closed then
    print("ZR Disconnect (port " .. port .. ")")
    removeSocket(sock)
    if #sockets == 0 then
      print("30_Status -> 4")
      Controls['30_Status'].Value = 4
      resetAllControls()
      -- Server stays listening; Zoom Room can reconnect on its own.
      -- No restart needed for a clean close.
    end

  elseif event == TcpSocket.Events.Error then
    print("ZR Error (port " .. port .. ")")
    removeSocket(sock)
    if #sockets == 0 then
      print("30_Status -> 4")
      Controls['30_Status'].Value = 4
      resetAllControls()
      -- Error may indicate the server socket is broken; restart it.
      scheduleRestart("socket_error")
    end

  elseif event == TcpSocket.Events.Timeout then
    print("ZR Timeout (port " .. port .. ")")
    removeSocket(sock)
    if #sockets == 0 then
      print("30_Status -> 4")
      Controls['30_Status'].Value = 4
      resetAllControls()
      -- Timeout likely means the remote end is gone; restart to clean up.
      scheduleRestart("socket_timeout")
    end

  elseif event == TcpSocket.Events.Data then
    local data = sock:ReadLine(TcpSocket.EOL.Any)
    while data ~= nil do

      print("ZR RAW: [" .. data .. "]")

      -- Out and Not Out values are defined so they may be used independently as needed

      if data == "optime true" then
        Controls['1_OperationTime'][1].Boolean = true
        Controls['1_OperationTime'][2].Boolean = false
        resetRoom()
        resetMute()
        Controls['11_Trig_OperationTime'][1]:Trigger()

      elseif data == "optime false" then
        Controls['1_OperationTime'][2].Boolean = true
        Controls['1_OperationTime'][1].Boolean = false
        resetMute()
        Controls['11_Trig_OperationTime'][2]:Trigger()

      elseif data == "meeting true" then
        Controls['2_ActiveMeeting'][1].Boolean = true
        Controls['2_ActiveMeeting'][2].Boolean = false
        Controls['12_Trig_ActiveMeeting'][1]:Trigger()

      elseif data == "meeting false" then
        Controls['2_ActiveMeeting'][2].Boolean = true
        Controls['2_ActiveMeeting'][1].Boolean = false
        resetRoom()
        resetMute()
        Controls['12_Trig_ActiveMeeting'][2]:Trigger()

      elseif data == "mute true" then
        Controls['3_MicsMuted'][1].Boolean = true
        Controls['3_MicsMuted'][2].Boolean = false
        Controls['13_Trig_MicsMuted'][1]:Trigger()

      elseif data == "mute false" then
        resetMute()

      elseif data == "hdmi true" then
        Controls['4_HDMISharing'][1].Boolean = true
        Controls['4_HDMISharing'][2].Boolean = false
        Controls['14_Trig_HDMISharing'][1]:Trigger()

      elseif data == "hdmi false" then
        Controls['4_HDMISharing'][2].Boolean = true
        Controls['4_HDMISharing'][1].Boolean = false
        Controls['14_Trig_HDMISharing'][2]:Trigger()

      elseif data == "controls true" then
        Controls['5_ControlsPage'][1].Boolean = true
        Controls['5_ControlsPage'][2].Boolean = false
        Controls['15_Trig_ControlsPage'][1]:Trigger()

      elseif data == "controls false" then
        Controls['5_ControlsPage'][2].Boolean = true
        Controls['5_ControlsPage'][1].Boolean = false
        Controls['15_Trig_ControlsPage'][2]:Trigger()

      end

      data = sock:ReadLine(TcpSocket.EOL.Any)
    end
  end
end


-- ============================================================
-- Server start / restart
-- ============================================================

startServer = function(newPort)
  -- Tear down existing server completely
  watchdogTimer:Stop()
  restartTimer:Stop()
  restartPending = false

  if ZR then
    pcall(function() ZR:Close() end)
    ZR = nil
  end
  closeAllSockets()
  resetAllControls()

  print("30_Status -> 4")
  Controls['30_Status'].Value = 4
  port = newPort
  Controls['0_TCPPort'].String = tostring(port)
  print("0_TCPPort -> " .. tostring(port))

  -- Create and bind a fresh server
  local ok, err = pcall(function()
    ZR = TcpSocketServer.New()
    ZR.EventHandler = function(SocketInstance)
      table.insert(sockets, SocketInstance)
      SocketInstance.EventHandler = SocketHandler
      print("ZR Connected on port " .. port)
      print("30_Status -> 0")
      Controls['30_Status'].Value = 0
      resetBackoff()  -- successful connection resets backoff
    end
    ZR:Listen(port)
  end)

  if ok then
    print("ZR startServer: listening on port " .. tostring(port))
  else
    print("ZR startServer FAILED: " .. tostring(err))
    -- Schedule a retry with backoff
    scheduleRestart("listen_failed")
    return
  end

  -- Start watchdog: if no sockets are connected for a long period while
  -- status indicates we should be listening, periodically verify the server
  -- is still functional by restarting it. This catches silent server-socket
  -- failures that produce no error event.
  watchdogTimer.EventHandler = function()
    if #sockets == 0 and Controls['30_Status'].Value ~= 0 then
      -- No connections and status is not OK — server may be stale
      print("ZR watchdog: no connections, restarting server to ensure port is live")
      scheduleRestart("watchdog")
    else
      -- Everything looks healthy; reset backoff so next real failure starts fast
      resetBackoff()
    end
  end
  watchdogTimer:Start(60)  -- check every 60 seconds
end

startServer(port)


-- ============================================================
-- Room selector change handler — restart server on new port
-- ============================================================

Controls['0_RoomSelector'].EventHandler = function(ctrl)
  local newSelection = ctrl.String
  local newPort = roomPorts[newSelection]
  if newPort and newPort ~= port then
    print("ZR RoomSelector changed to '" .. newSelection .. "' -> port " .. tostring(newPort))
    resetBackoff()
    startServer(newPort)
  end
end


-- ============================================================
-- Manual EventHandlers — sync complement boolean only,
-- triggers fire from TCP only
-- ============================================================

Controls['1_OperationTime'][1].EventHandler = function()
  Controls['1_OperationTime'][2].Boolean = not Controls['1_OperationTime'][1].Boolean
end

Controls['1_OperationTime'][2].EventHandler = function()
  Controls['1_OperationTime'][1].Boolean = not Controls['1_OperationTime'][2].Boolean
end

Controls['2_ActiveMeeting'][1].EventHandler = function()
  Controls['2_ActiveMeeting'][2].Boolean = not Controls['2_ActiveMeeting'][1].Boolean
end

Controls['2_ActiveMeeting'][2].EventHandler = function()
  Controls['2_ActiveMeeting'][1].Boolean = not Controls['2_ActiveMeeting'][2].Boolean
end

Controls['3_MicsMuted'][1].EventHandler = function()
  Controls['3_MicsMuted'][2].Boolean = not Controls['3_MicsMuted'][1].Boolean
end

Controls['3_MicsMuted'][2].EventHandler = function()
  Controls['3_MicsMuted'][1].Boolean = not Controls['3_MicsMuted'][2].Boolean
end

Controls['4_HDMISharing'][1].EventHandler = function()
  Controls['4_HDMISharing'][2].Boolean = not Controls['4_HDMISharing'][1].Boolean
end

Controls['4_HDMISharing'][2].EventHandler = function()
  Controls['4_HDMISharing'][1].Boolean = not Controls['4_HDMISharing'][2].Boolean
end

Controls['5_ControlsPage'][1].EventHandler = function()
  Controls['5_ControlsPage'][2].Boolean = not Controls['5_ControlsPage'][1].Boolean
end

Controls['5_ControlsPage'][2].EventHandler = function()
  Controls['5_ControlsPage'][1].Boolean = not Controls['5_ControlsPage'][2].Boolean
end
