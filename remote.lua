local fs = libs.fs;
local log = require("log")

local mpv = require("mpv")
local ui = require("ui")

-----------------------------------------------------------
-- Remote events
-----------------------------------------------------------

local connect = function()  return mpv.connect(ui.initialize) end
local disconnect = function()  mpv.disconnect(ui.deinitialize) end
-- Always allow a few actions, without trying to connect.
local allow = {
  onoff = true,
  update_ipc = true,
  open_file = true,
  change_directory = true,
  set_file_sort_key_name = true,
  set_file_sort_key_created = true,
  set_file_sort_key_modified = true,
  set_file_sort_key_size = true,
}

-- Try to establish the connection before each action.
events.preaction = function(name)
  if allow[name] then
    return true
  end

  if not connect() then
    return false
  end

  return true
end

local load_settings = function ()
  layout.input_ipc_server.text = settings.input_ipc_server

  if settings.working_directory == "" or settings.working_directory == nil then
    actions.change_directory(fs.homedir())
  end

  if settings.sort_order == nil then
    settings.sort_order = "ascending"
  end
  if settings.sort_files_by == "" or settings.sort_files_by == nil then
    actions.set_file_sort_key_name()
  end
end

-- Set the input field when loading the remote.
events.create = function()
  load_settings()
end

-- Set the input field when the remote gains focus, and try to connect.
-- Apparently some things happen with the internal state of the remote when it loses focus.
events.focus = function()
  load_settings()

  connect()
end

-- Disconnect from mpv when losing focus.
events.blur = function()
  disconnect()
end

-- Disconnect from mpv when the remote is destroyed.
events.destroy = function()
  disconnect()
end

-- Detect something.
events.detect = function ()
  return fs.exists(settings.input_ipc_server)
end

-----------------------------------------------------------
-- Actions
-----------------------------------------------------------

--@help Pushing the on/off button toggles the connection state.
actions.onoff = function()
  mpv.toggle_connection(ui.initialize, ui.deinitialize)
end

--@help Set the input IPC server path.
--@param path:string IPC serevr path
actions.update_ipc = function(path)
  settings.input_ipc_server = path
  disconnect()
  connect()
end

actions.change_directory = function (path)
  settings.working_directory = path
  layout.working_directory.text = path
  ui.list_directory()
end

actions.open_file = function (index)
  directory_contents[index+1].ontap()
end

actions.set_file_sort_key_name = function() ui.set_file_sort_key("name") end
actions.set_file_sort_key_created = function() ui.set_file_sort_key("created") end
actions.set_file_sort_key_modified = function() ui.set_file_sort_key("modified") end
actions.set_file_sort_key_size = function() ui.set_file_sort_key("size") end

--@help Lower volume
actions.volume_down = function()
  mpv.send("add", "volume", -2)
end

--@help Mute volume
actions.volume_mute = function()
  mpv.send("cycle", "mute")
end

--@help Raise volume
actions.volume_up = function()
  mpv.send("add", "volume", 2)
end

--@help Set volume
actions.volume_set = function(value)
  mpv.send("set_property", "volume", tonumber(value))
end

--@help Previous track
actions.previous = function()
  mpv.send("playlist-prev", "weak")
end

--@help Next track
actions.next = function()
  mpv.send("playlist-next", "weak")
end

--@help Seek by percent
actions.seek = function(value)
  mpv.send("seek", value, "absolute-percent")
end

--@help Skip forward 10 secs
actions.forward = function()
  mpv.send("seek", 10)
end

--@help Skip backward 10 secs
actions.backward = function()
  mpv.send("seek", -10)
end
--
--@help Previous chapter
actions.previous_chapter = function()
  mpv.send("add", "chapter", -1)
end

--@help Next chapter
actions.next_chapter = function()
  mpv.send("add", "chapter", 1)
end

--@help Back one frame
actions.frame_back_step = function()
  mpv.send("frame-back-step")
end

--@help Forward one frame
actions.frame_step = function()
  mpv.send("frame-step")
end

--@help Toggle play/pause state
actions.play_pause = function()
  mpv.send("cycle", "pause")
end

--@help Take screenshot
actions.screenshot = function()
  mpv.send("screenshot")
end

--@help Stop playback
actions.stop = function()
  mpv.send_with_callback(ui.deinitialize, "quit")
end

--@help Cycle through subtitles
actions.switch_subs = function()
  mpv.send("cycle", "sub")
end

--@help Toggle subtitle visibility
actions.toggle_subs = function()
  mpv.send("cycle", "sub-visibility")
end

--@help Toggle fullscreen
actions.fullscreen = function()
  mpv.send("cycle", "fullscreen")
end

actions.osd = function()
  mpv.send("no-osd", "cycle-values", "osd-level", "3", "1")
end

--@help Set subtitle track
actions.set_sub_id = function(index)
  --list indices are 0-indexed and mpv 1-indexes, but we have a "None" option for subs
  --so there is no off-by-one error
  mpv.send("set_property", "sid", index)
end

--@help Increase subtitle delay
actions.sub_delay_down = function()
  mpv.send("add", "sub-delay", -0.1)
end

--@help Decrease subtitle delay
actions.sub_delay_up = function()
  mpv.send("add", "sub-delay", 0.1)
end

--@help Set audio track
actions.set_audio_id = function(index)
  --list indices are 0-indexed but mpv 1-indexes
  mpv.send("set_property", "aid", index+1)
end

--@help Increase audio delay
actions.audio_delay_down = function()
  mpv.send("add", "audio-delay", -0.1)
end

--@help Decrease audio delay
actions.audio_delay_up = function()
  mpv.send("add", "audio-delay", 0.1)
end

--@help Decrease playback speed
actions.playback_speed_down = function()
  mpv.send("multiply", "speed", 1/1.1)
end

--@help Increase playback speed
actions.playback_speed_up = function()
  mpv.send("multiply", "speed", 1.1)
end

--@help Reset playback speed
actions.playback_speed_reset = function()
  mpv.send("set", "speed", "1.0")
end
