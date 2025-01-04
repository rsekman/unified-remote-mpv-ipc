local data = require("data")
local device = require("device")
local ffi = require("ffi")
local fs = libs.fs;
local log = require("log")
local server = require("server")

-----------------------------------------------------------
-- FFI interface
-----------------------------------------------------------

-- POSIX constants
local AF_UNIX = 1
local SOCK_STREAM = 1
local SOCK_NONBLOCK = 2048
local EAGAIN = 11
local POLLIN = 1

ffi.cdef[[
typedef unsigned short int sa_family_t;
typedef unsigned short int nfds_t;
typedef int socklen_t;
typedef int ssize_t;

typedef struct {
  sa_family_t sun_family;
  char        sun_path[108];
} sockaddr_un;

typedef struct {
  int   fd;
  short events;
  short revents;
} pollfd;


int socket(int domain, int type, int protocol);
int connect(int sockfd, const struct sockaddr *addr, socklen_t addrlen);

ssize_t write(int fd, const void *buf, size_t count);
ssize_t read(int fd, void *buf, size_t count);

int poll(pollfd *fds, nfds_t nfds, int timeout);

char *strerror(int errnum);

int close(int fd);
]]

-- Convert errno to a Lua string.
local function strerror()
  return ffi.string(ffi.C.strerror(ffi.errno()))
end

-----------------------------------------------------------
-- IPC interface
-----------------------------------------------------------

local fd = nil
local initialize_ui, deinitalize_ui

-- Disconnect from mpv, resetting some values.
local function disconnect()
  if fd then
    ffi.C.close(fd)
    fd = nil
  end

  if tid then
    libs.timer.cancel(tid)
    tid = nil
  end

  layout.onoff.icon = "off"
  layout.onoff.color = "red"

  deinitalize_ui()
end


local handle_response

-- Connect to mpv at the given path.
local function _connect(path)
  -- Make sure we start off in a disconnected state.
  disconnect()

  requests = {}
  next_request_id = 1
  listeners = {
    ["property-change"] = function (tbl)
      if tbl.name and observers[tbl.name] then
        observers[tbl.name](tbl)
      end
    end
  }
  observers = {}
  property_cache = {}

  -- Use the supplied path, or the one from the settings.
  path = path or settings.input_ipc_server

  -- Check that the socket exists.
  if not path or path == "" then
    device.toast("No mpv IPC path configured.")
    return false
  elseif not events.detect() then
    device.toast("No mpv IPC server at '"..path.."'")
    return false
  end

  fd = ffi.C.socket(AF_UNIX, SOCK_STREAM + SOCK_NONBLOCK, 0)
  if fd < 0 then
    device.toast("Failed to set up")
    log.error("Failed to create socket: "..strerror())
    fd = nil
    return false
  end

  local sockaddr = ffi.new("sockaddr_un")
  sockaddr.sun_family = AF_UNIX
  sockaddr.sun_path = path

  if ffi.C.connect(fd, ffi.cast("const struct sockaddr*", sockaddr), ffi.sizeof(sockaddr)) ~= 0 then
    device.toast("Failed to connect to mpv at '"..path.."'")
    log.warn("Failed to connect to '"..path.."': "..strerror())
    disconnect()
    return false
  end

  tid = libs.timer.interval(handle_response, 50)

  layout.onoff.icon = "on"
  layout.onoff.color = "green"

  initialize_ui()

  return true
end

-- Connect with retries and timeout
-- path: the path to the mpv socket
-- retries: number of attempts to make
-- interval: interval between each attempt in milliseconds
local function connect(...)
  path = select(1, ...) or settings.input_ipc_server
  retries = select(2, ...) or 1
  interval = select(3, ...) or 50
  for i = 1, retries do
    if _connect(path) then
      return true
    elseif i ~= retries then
      os.sleep(50)
    end
  end
  return false
end

-- Send a command to mpv, registering a callback to handle any responses
local function send_with_callback(callback, ...)
  if not fd then
    return false
  end

  local message = { command = { ...} }
  if callback then
    requests[next_request_id] = callback
    message.request_id = next_request_id
    next_request_id = next_request_id + 1
  end
  local json = data.tojson(message) .. "\n"
  local len = #json
  local ret = ffi.C.write(fd, json, len)
  if ret < 0 then
    device.toast("Failed to communicate with mpv")
    log.warn("Failed to send: "..strerror())
    disconnect()
    return false
  end
  return ret == len
end

-- Read any messages from mpv.
local function read()
  if not fd then
    return nil
  end

  local out = ""
  local buf = ffi.new("char[255]")
  local pollfds = ffi.new("pollfd[1]")
  pollfds[0].fd = fd
  pollfds[0].events = POLLIN
  ffi.C.poll(pollfds, 1, 50)
  if pollfds[0].revents == 0 then
    return nil
  end
  repeat
    local ret = ffi.C.read(fd, buf, 255)
    if ret < 0 then
      if ffi.errno() == EAGAIN then
        break
      else
        log.warn("Failed to read: "..strerror())
      end
      disconnect()
      return nil
    elseif ret > 0 then
      out = out .. ffi.string(buf, ret)
    end
  until ret == 0
  if out:len() > 0 then
    return out
  else
    return nil
  end
end

-- Send one or more commands to mpv.
local function send ( ... )
  send_with_callback(nil, ... )
end

-- Observe a property
local function observe_property(name, callback)
  observers[name] = callback
  send("observe_property", 1, name)
end

----------------------------------------------------------
-- UI handlers
----------------------------------------------------------

local function fmt_time(t)
    local s = t % 60;
    t = math.floor(t / 60);
    local min = t % 60;
    t = math.floor(t / 60);
    local hr = t;

    if hr > 0 then
      return string.format("%02d:%02d:%02d", hr, min, s)
    else
      return string.format("%02d:%02d", min, s)
    end
end

-- Store duration
local function ui_set_duration(message)
  if message.data then
    property_cache["duration"] = message.data
  end
end

-- Update the seekbar
local function ui_seek(message)
  local duration = property_cache["duration"]
  if duration == nil then
    return
  end
  if message.data then
    local progress = message.data
    local pos = 100 * progress/duration
    layout.seek_slider.progress = string.format("%2.0f", pos)

    local p_str = fmt_time(progress)
    local d_str = fmt_time(duration)
    layout.seek_slider.text = string.format("%s / %s", p_str, d_str)
  end
end

-- Update the volume bar
local function ui_update_volume(message)
  if message.data then
    layout.volume_slider.progress = string.format("%2.0f", message.data)
  end
end

local function ui_update_mute(message)
  if message.data == 0 then
    layout.volume_slider.color = "green"
  else
    layout.volume_slider.color = "red"
  end
end

-- Set the title
local function ui_set_title(message)
  if message.data then
    layout.media_title.text = message.data
  end
  server.update( {"id = media-title", weight = "wrap" } )
end

--Initialize the subtitle and audio lists
local function ui_update_track_lists(message)
  if message.data == nil then
    return nil
  end
  local sub_tracks = {
    { type = "item", checked = true, text = "None" }
  }
  local audio_tracks = {}
  local format_track = function (data)
    if data.title ~= nil then
      return string.format("%s (%s)", data.lang, data.title)
    else
      return data.lang
    end
  end
  local make_track_item = function (data)
      return { type = "item", checked = ( data.selected > 0 ) , text = format_track(data) }
  end
  for n, t in ipairs(message.data) do
    local track = make_track_item(t)
    if t.type == "sub" then
      if t.selected > 0 then
        sub_tracks[1].checked = false
      end
      track.ontap = function (index)
        send("set_property", "sid", t.id)
      end
      table.insert( sub_tracks, track )
    end
    if t.type == "audio" then
      table.insert( audio_tracks, track )
    end
  end
  server.update( {id = "sub_list", children = sub_tracks } )
  server.update( {id = "audio_list", children = audio_tracks } )

end

local function ui_update_sub_delay(message)
  if message.data then
    layout.sub_delay.text = string.format(
      "%s ms", tostring(1000 * message.data)
    )
  end
end

local function ui_update_audio_delay(message)
  if message.data then
    layout.audio_delay.text = string.format(
      "%s ms", tostring(1000 * message.data)
    )
  end
end

local change_directory

directory_contents = {}

local function file_sorter(a, b)
  --Always put directories first
  if a["mode"] == "directory" and b["mode"] ~= "directory" then
    return true
  elseif a["mode"] ~= "directory" and b["mode"] == "directory" then
    return false
  else
    local key = settings.sort_files_by
    if settings.sort_order == "ascending" then
      return a[key] < b[key]
    else
      return a[key] > b[key]
    end
  end
end

local function play_with_mpv(path)
  if tid then
    send("loadfile", path)
  else
    os.start("mpv", path)
    -- it can take some time for mpv to create the socket, so we will make 10
    -- attempts to connect at 50 ms intervals
    connect(settings.input_ipc_server, 10, 50)
  end
end

local function open_file (path)
  if not fs.exists(path) then
    return
  end
  if fs.isdir(path) then
    actions.change_directory(path)
  elseif fs.isfile(path) then
    play_with_mpv(path)
  end
end

local function ui_list_directory()
  local wd = settings.working_directory
  if not fs.exists(wd) then
    log.warn("Directory " .. wd .. " does not exist; resetting to $HOME")
    actions.change_directory(fs.homedir())
    return
  end
  directory_contents = {}

  local make_file_item = function (dir_entry)
    local title
    if dir_entry["mode"] == "directory" then
      title = "📁" .. dir_entry["name"] .. "/"
    else
      title = dir_entry["name"]
    end
      return {
        type = "item",
        checked = false,
        text = title,
        ontap = function ()
          open_file(dir_entry["path"])
        end
      }
  end

  local dir_entries = {}
  local make_dir_entry = function(path)
    return {
      path = path,
      name = fs.fullname(path),
      size = fs.size(path),
      created = fs.created(path),
      modified = fs.modified(path)
    }
  end
  for i, dname in ipairs(fs.dirs(wd)) do
    local e = make_dir_entry(dname)
    e["mode"] = "directory"
    table.insert(dir_entries, e)
  end

  for i, fname in ipairs(fs.files(wd)) do
    local e = make_dir_entry(fname)
    e["mode"] = "file"
    table.insert(dir_entries, e)
  end
  table.sort(dir_entries, file_sorter)

  for i, f in ipairs(dir_entries) do
    local fi = make_file_item(f)
    table.insert(directory_contents, fi)
  end

  parent_dir = fs.parent(wd)
  if parent_dir ~= wd then
    local parent = {
      type = "item",
      checked = false,
      text = "↩️ ".. parent_dir,
      ontap = function() open_file(parent_dir) end
    }
    table.insert(directory_contents, 1, parent)
  end

  server.update( {id = "files_list", children = directory_contents } )
end

local function ui_update_selected_sort_key (prev)
  local key = settings.sort_files_by

  local capitalize = function(s)
    return s:sub(1, 1):upper() .. s:sub(2, -1)
  end

  log.info("setting sort key to " .. key .. " was " .. (prev or "unset"))
  if prev ~= nil and prev ~= key then
    server.update( {
        id = "sort_by_" .. prev,
        checked = false,
        text = capitalize(prev)
    })
  end
  local order
  if settings.sort_order == "ascending" then
    order = "🔼"
  else
    order = "🔽"
  end
  server.update( {
    id = "sort_by_" .. key,
    checked = true,
    text = capitalize(key) .. order
  })
end

-- Initialize the UI to reflect the current state
initialize_ui = function ()
  send_with_callback(ui_update_volume, "get_property", "volume")
  observe_property("volume", ui_update_volume)
  send_with_callback(ui_update_mute, "get_property", "mute")
  observe_property("mute", ui_update_mute)

  send_with_callback(ui_set_duration, "get_property", "duration")
  observe_property("duration", ui_seek)
  send_with_callback(ui_seek, "get_property", "time-pos")
  observe_property("time-pos", ui_seek)

  send_with_callback(ui_set_title, "get_property", "media-title")
  observe_property("media-title", ui_set_title)

  send_with_callback(ui_update_track_lists, "get_property", "track-list")
  listeners["track-switched"] = function()
    send_with_callback(ui_update_track_lists, "get_property", "track-list")
  end

  listeners["end-file"] = function(message)
    if message["reason"] == "quit" then
      disconnect()
    end
  end

  send_with_callback(ui_update_sub_delay, "get_property", "sub-delay")
  observe_property("sub-delay", ui_update_sub_delay)

  send_with_callback(ui_update_audio_delay, "get_property", "audio-delay")
  observe_property("audio-delay", ui_update_audio_delay)
end

-- Deinitialize the UI when we disconnect from mpv
deinitalize_ui = function (...)
    layout.media_title.text = "Not playing"
    layout.volume_slider.progress = "50"
end

-----------------------------------------------------------
-- Remote events
-----------------------------------------------------------

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

  if not fd and not connect() then
    return false
  end

  return true
end

-- Consume any responses from mpv after each action.
handle_response = function()
  -- Try to get a response from mpv.
  local resp = read()
  if resp ~= nil and resp:len() > 0 then
    -- mpv can send multiple JSON objects on each line.
    for msg in resp:gmatch("[^\r\n]+") do
      if msg:match("^{") then
        local tbl = data.fromjson(msg)
        if tbl.error and tbl.error ~= "success" then
          device.toast("Command failed")
          log.warn("Error from mpv: "..msg)
        end
        -- If the message contains a request ID, it is a response to our command.
        if tbl.request_id and requests[tbl.request_id] then
          requests[tbl.request_id](tbl)
        end
        -- If the message is an event, let the corresponding observer handle it
        if tbl.event and listeners[tbl.event] then
          listeners[tbl.event](tbl)
        end
        -- Flush any other messages/events.
      end
    end
  end
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
  ui_list_directory()
  ui_update_selected_sort_key()

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
  if fd then
    disconnect()
    deinitalize_ui()
  else
    connect()
  end
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
  ui_list_directory()
end

actions.open_file = function (index)
  directory_contents[index+1].ontap()
end

local function set_file_sort_key(sort_key)
  local prev = settings.sort_files_by
  settings.sort_files_by = sort_key
  if prev ~= sort_key or settings.sort_order == "descending" then
    settings.sort_order = "ascending"
  else
    settings.sort_order = "descending"
  end

  ui_update_selected_sort_key(prev)
  ui_list_directory()
end

actions.set_file_sort_key_name = function() set_file_sort_key("name") end
actions.set_file_sort_key_created = function() set_file_sort_key("created") end
actions.set_file_sort_key_modified = function() set_file_sort_key("modified") end
actions.set_file_sort_key_size = function() set_file_sort_key("size") end

--@help Lower volume
actions.volume_down = function()
  send("add", "volume", -2)
end

--@help Mute volume
actions.volume_mute = function()
  send("cycle", "mute")
end

--@help Raise volume
actions.volume_up = function()
  send("add", "volume", 2)
end

--@help Set volume
actions.volume_set = function(value)
  send("set_property", "volume", tonumber(value))
end

--@help Previous track
actions.previous = function()
  send("playlist-prev", "weak")
end

--@help Next track
actions.next = function()
  send("playlist-next", "weak")
end

--@help Seek by percent
actions.seek = function(value)
  send("seek", value, "absolute-percent")
end

--@help Skip forward 10 secs
actions.forward = function()
  send("seek", 10)
end

--@help Skip backward 10 secs
actions.backward = function()
  send("seek", -10)
end
--
--@help Previous chapter
actions.previous_chapter = function()
  send("add", "chapter", -1)
end

--@help Next chapter
actions.next_chapter = function()
  send("add", "chapter", 1)
end

--@help Back one frame
actions.frame_back_step = function()
  send("frame-back-step")
end

--@help Forward one frame
actions.frame_step = function()
  send("frame-step")
end

--@help Toggle play/pause state
actions.play_pause = function()
  send("cycle", "pause")
end

--@help Take screenshot
actions.screenshot = function()
  send("screenshot")
end

--@help Stop playback
actions.stop = function()
  send_with_callback(deinitalize_ui, "quit")
end

--@help Cycle through subtitles
actions.switch_subs = function()
  send("cycle", "sub")
end

--@help Toggle subtitle visibility
actions.toggle_subs = function()
  send("cycle", "sub-visibility")
end

--@help Toggle fullscreen
actions.fullscreen = function()
  send("cycle", "fullscreen")
end

actions.osd = function()
  send("no-osd", "cycle-values", "osd-level", "3", "1")
end

--@help Set subtitle track
actions.set_sub_id = function(index)
  --list indices are 0-indexed and mpv 1-indexes, but we have a "None" option for subs
  --so there is no off-by-one error
  send("set_property", "sid", index)
end

--@help Increase subtitle delay
actions.sub_delay_down = function()
  send("add", "sub-delay", -0.1)
end

--@help Decrease subtitle delay
actions.sub_delay_up = function()
  send("add", "sub-delay", 0.1)
end

--@help Set audio track
actions.set_audio_id = function(index)
  --list indices are 0-indexed but mpv 1-indexes
  send("set_property", "aid", index+1)
end

--@help Increase audio delay
actions.audio_delay_down = function()
  send("add", "audio-delay", -0.1)
end

--@help Decrease audio delay
actions.audio_delay_up = function()
  send("add", "audio-delay", 0.1)
end

--@help Decrease playback speed
actions.playback_speed_down = function()
  send("multiply", "speed", 1/1.1)
end

--@help Increase playback speed
actions.playback_speed_up = function()
  send("multiply", "speed", 1.1)
end

--@help Reset playback speed
actions.playback_speed_reset = function()
  send("set", "speed", "1.0")
end
