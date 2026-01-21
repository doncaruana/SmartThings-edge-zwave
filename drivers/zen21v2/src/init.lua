-- Zooz ZEN21 v2 (015D-0111-1E1C) personal Edge driver
-- Don Caruana, 2026-01-21
-- Implemented soft toggle to enable the switch to be a toggle so either top or bottom changes state

local capabilities = require "st.capabilities"
local ZwaveDriver = require "st.zwave.driver"
local log = require "log"
local cc = require "st.zwave.CommandClass"

local SwitchBinary = (require "st.zwave.CommandClass.SwitchBinary")({ version = 1 })
local Basic = (require "st.zwave.CommandClass.Basic")({ version = 1 })
local Configuration = (require "st.zwave.CommandClass.Configuration")({ version = 1 })
local Version = (require "st.zwave.CommandClass.Version")({ version = 1 })

local socket = require "socket"

-- ZEN21 v2 parameter mapping (firmware 4.x)
-- Param 1: Paddle orientation (0/1) - 0 = up for on, 1 flipped
-- Param 2: LED indicator mode (0/1) - 0 LED is opposite switch, 1 it follows it
-- Param 3: LED enable/disable (0/1)
local PARAM_ORIENTATION = 1
local PARAM_LED_MODE = 2
local PARAM_LED_DISABLE = 3

local function now_ms()
  return math.floor(socket.gettime() * 1000)
end

local function emit_switch_state(device, on)
  device:emit_event(capabilities.switch.switch(on and "on" or "off"))
end

local function get_current_on(device)
  local current = device:get_latest_state("main", capabilities.switch.ID, capabilities.switch.switch.NAME)
  if current == nil then return nil end
  return (current == "on")
end

local function set_last_basic(device, value)
  device:set_field("last_basic_ms", now_ms(), { persist = false })
  device:set_field("last_basic_value", value, { persist = false })
end

local function is_echo_of_recent_basic(device, value)
  local t = device:get_field("last_basic_ms") or 0
  local v = device:get_field("last_basic_value")
  if v == nil then return false end
  return (now_ms() - t) <= 300 and v == value
end

-- Digital (app/automation) command suppression window
local function mark_digital(device, expected_on)
  device:set_field("digital_until_ms", now_ms() + 2000, { persist = false })
  device:set_field("digital_expected", expected_on, { persist = false })
end

local function digital_active(device)
  local until_ms = device:get_field("digital_until_ms") or 0
  return now_ms() < until_ms
end

-- Soft-toggle inflight latch (prevents loops)
local function start_soft_inflight(device, expected_on)
  device:set_field("soft_inflight_until_ms", now_ms() + 8000, { persist = false })
  device:set_field("soft_expected", expected_on, { persist = false })
end

local function soft_inflight(device)
  local until_ms = device:get_field("soft_inflight_until_ms") or 0
  return now_ms() < until_ms
end

local function clear_soft_inflight(device)
  device:set_field("soft_inflight_until_ms", 0, { persist = false })
  device:set_field("soft_expected", nil, { persist = false })
end

-- If softToggle is enabled, and we receive a BASIC report that matches our current
-- logical state (i.e., redundant / "wrong paddle"), then we flip the load.
local function soft_toggle_from_basic(device, reported_on)
  local pref = device.preferences or {}
  if not pref.softToggle then return false end

  -- If a digital command just happened, stand down and let the normal flow win.
  if digital_active(device) then
    return false
  end

  -- If we're already mid soft-toggle, ignore BASIC (we'll accept expected report).
  if soft_inflight(device) then
    return true
  end

  local current_on = get_current_on(device)
  if current_on == nil then return false end

  -- Only act when the device reports the SAME as our current logical state.
  -- That means the physical press didn't change the load (orientation / redundant report)
  -- and we want to flip it.
  if current_on ~= reported_on then
    return false
  end

  local target_on = not reported_on
  log.debug(string.format("SoftToggle: redundant BASIC (%s); sending %s", reported_on and "on" or "off", target_on and "on" or "off"))

  start_soft_inflight(device, target_on)
  device:send(SwitchBinary:Set({ switch_value = target_on and SwitchBinary.value.ON_ENABLE or SwitchBinary.value.OFF_DISABLE }))
  return true
end

local function process_report(device, reported_on, source, raw_value)
  if soft_inflight(device) then
    local expected = device:get_field("soft_expected")
    if expected ~= nil and reported_on == expected then
      clear_soft_inflight(device)
      emit_switch_state(device, reported_on)
      return
    end
    -- Ignore everything else while inflight
    return
  end

  if source == "BASIC" then
    if soft_toggle_from_basic(device, reported_on) then
      return
    end
    emit_switch_state(device, reported_on)
    return
  end

  if source == "SWITCH_BINARY" then
    if raw_value ~= nil and is_echo_of_recent_basic(device, raw_value) then
      return
    end
    emit_switch_state(device, reported_on)
    return
  end

  emit_switch_state(device, reported_on)
end

-- Preferences -> Z-Wave Configuration
local function apply_preferences(driver, device)
  local pref = device.preferences or {}

  -- Param 1: orientation
  local orient = tonumber(pref.switchOrientation) or 0
  if orient ~= 0 and orient ~= 1 then orient = 0 end

  -- Param 2: LED mode (we only expose 0/1)
  local led_mode = tonumber(pref.ledFollow) or 0
  if led_mode ~= 0 and led_mode ~= 1 then led_mode = 0 end

  -- Param 3: LED disable
  local led_disable = (pref.ledDisabled and 1) or 0

  log.debug(string.format("Apply prefs: orientation=%d led_mode=%d led_disable=%d softToggle=%s", orient, led_mode, led_disable, tostring(pref.softToggle)))

  device:send(Configuration:Set({ parameter_number = PARAM_ORIENTATION, size = 1, configuration_value = tonumber(orient) }))
  device:send(Configuration:Set({ parameter_number = PARAM_LED_MODE,     size = 1, configuration_value = tonumber(led_mode) }))
  device:send(Configuration:Set({ parameter_number = PARAM_LED_DISABLED, size = 1, configuration_value = tonumber(led_disable) }))

  -- Pull back what the device reports (useful sanity check)
  device:send(Configuration:Get({ parameter_number = PARAM_ORIENTATION }))
  device:send(Configuration:Get({ parameter_number = PARAM_LED_MODE }))
  device:send(Configuration:Get({ parameter_number = PARAM_LED_DISABLE }))
end

local function do_refresh(driver, device, command)
  device:send(SwitchBinary:Get({}))
  device:send(Version:Get({}))
end

local function config_value_to_number(v, size)
  if type(v) == "number" then return v end
  if type(v) == "string" then
    local n = 0
    for i = 1, #v do n = n * 256 + v:byte(i) end
    return n
  end
  return nil
end

local zwave_handlers = {}

zwave_handlers[cc.BASIC] = {
  [Basic.REPORT] = function(driver, device, cmd)
    local raw = cmd.args.value or 0
    local on = (raw ~= 0)
    set_last_basic(device, raw)
    log.debug(string.format("BasicReport value=%d -> %s", raw, on and "on" or "off"))
    process_report(device, on, "BASIC", raw)
  end
}

zwave_handlers[cc.SWITCH_BINARY] = {
  [SwitchBinary.REPORT] = function(driver, device, cmd)
    local raw = cmd.args.current_value
    if raw == nil then raw = cmd.args.value end
    raw = raw or 0
    local on = (raw ~= 0)
    log.debug(string.format("SwitchBinaryReport raw=%d -> %s", raw, on and "on" or "off"))
    process_report(device, on, "SWITCH_BINARY", raw)
  end
}

zwave_handlers[cc.CONFIGURATION] = {
  [Configuration.REPORT] = function(driver, device, cmd)
    local p = cmd.args.parameter_number
    local size = cmd.args.size or 1
    local v = cmd.args.configuration_value
    local val_num
    local bytes_str = ""
    if type(v) == "number" then
      val_num = v
      bytes_str = tostring(v)
    elseif type(v) == "string" then
      val_num = 0
      local parts = {}
      for i = 1, #v do
        local b = v:byte(i)
        parts[#parts+1] = tostring(b)
        val_num = val_num * 256 + b
      end
      bytes_str = table.concat(parts, ",")
    elseif type(v) == "table" then
      val_num = 0
      local parts = {}
      for i = 1, #v do
        local b = tonumber(v[i]) or 0
        parts[#parts+1] = tostring(b)
        val_num = val_num * 256 + b
      end
      bytes_str = table.concat(parts, ",")
    else
      val_num = 0
      bytes_str = "nil"
    end
    log.debug(string.format(
      "ConfigurationReport param=%d size=%d value=%d raw_type=%s raw=[%s]",
      p, size, val_num, type(v), bytes_str
    ))
  end
}
zwave_handlers[cc.VERSION] = {
  [Version.REPORT] = function(driver, device, cmd)
    local v = cmd.args.application_version
    local sv = cmd.args.application_sub_version
    if v ~= nil and sv ~= nil then
      local fw = string.format("%d.%02d", v, sv)
      device:emit_event(capabilities.firmwareUpdate.currentVersion(fw))
      log.info(string.format("Firmware: %s", fw))
    else
      log.info("Firmware: VERSION report missing application_version fields")
    end
  end
}

local lifecycle_handlers = {}

lifecycle_handlers.init = function(driver, device)
  device:set_field("digital_until_ms", 0, { persist = false })
  device:set_field("digital_expected", nil, { persist = false })
  device:set_field("soft_inflight_until_ms", 0, { persist = false })
  device:set_field("soft_expected", nil, { persist = false })
  device:set_field("last_basic_ms", 0, { persist = false })
  device:set_field("last_basic_value", nil, { persist = false })
end

lifecycle_handlers.added = function(driver, device)
  do_refresh(driver, device)
end

lifecycle_handlers.driverSwitched = function(driver, device, event, args)
  -- Driver re-deploy: clear transient latches and re-query
  lifecycle_handlers.init(driver, device)
  do_refresh(driver, device)
end

lifecycle_handlers.doConfigure = function(driver, device)
  apply_preferences(driver, device)
  do_refresh(driver, device)
end

lifecycle_handlers.infoChanged = function(driver, device, event, args)
  apply_preferences(driver, device)
end

local capability_handlers = {
  [capabilities.refresh.ID] = {
    [capabilities.refresh.commands.refresh.NAME] = do_refresh
  },
  [capabilities.switch.ID] = {
    [capabilities.switch.commands.on.NAME] = function(driver, device, command)
      mark_digital(device, true)
      device:send(SwitchBinary:Set({ switch_value = SwitchBinary.value.ON_ENABLE }))
      emit_switch_state(device, true)
    end,
    [capabilities.switch.commands.off.NAME] = function(driver, device, command)
      mark_digital(device, false)
      device:send(SwitchBinary:Set({ switch_value = SwitchBinary.value.OFF_DISABLE }))
      emit_switch_state(device, false)
    end
  }
}

local driver = ZwaveDriver("zen21v2-personal", {
  zwave_handlers = zwave_handlers,
  lifecycle_handlers = lifecycle_handlers,
  capability_handlers = capability_handlers,
})

driver:run()
