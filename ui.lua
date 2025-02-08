local fs = libs.fs;
local log = require("log")
local server = require("server")

local mpv = require("mpv")

local property_cache = {}
-- Create a callback that will cache a property, then continue with another callback
local function cache_callback(property, and_then)
  return function(message)
    if message.data then
      property_cache[property] = message.data
    end
    if and_then then
      and_then()
    end
  end
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

-- Update the seekbar
local function seek()
  local duration = property_cache["duration"]
  local progress = property_cache["time-pos"]
  if duration == nil or progress == nil then
    return
  end

  local pos = 100 * progress/duration
  layout.seek_slider.progress = string.format("%2.0f", pos)

  local p_str = fmt_time(progress)
  local d_str = fmt_time(duration)
  layout.seek_slider.text = string.format("%s / %s", p_str, d_str)
end

-- Update the volume bar
local function update_volume(message)
  if message.data then
    layout.volume_slider.progress = string.format("%2.0f", message.data)
  end
end

local function update_mute(message)
  if message.data == 0 then
    layout.volume_slider.color = "green"
  else
    layout.volume_slider.color = "red"
  end
end

-- Set the title
local function set_title(message)
  if message.data then
    layout.media_title.text = message.data
  end
  server.update( {"id = media-title", weight = "wrap" } )
end

--Initialize the subtitle and audio lists
local function update_track_lists(message)
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
        mpv.send("set_property", "sid", t.id)
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

local function update_sub_delay(message)
  if message.data then
    layout.sub_delay.text = string.format(
      "%s ms", tostring(1000 * message.data)
    )
  end
end

local function update_audio_delay(message)
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
    mpv.send("loadfile", path)
  else
    os.start("mpv", path)
    -- it can take some time for mpv to create the socket, so we will make 10
    -- attempts to connect at 50 ms intervals
    mpv.connect(settings.input_ipc_server, initialize, 10, 50)
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

local function list_directory()
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

local function update_selected_sort_key (prev)
  local key = settings.sort_files_by

  local capitalize = function(s)
    return s:sub(1, 1):upper() .. s:sub(2, -1)
  end

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

local function set_file_sort_key(sort_key)
  local prev = settings.sort_files_by
  settings.sort_files_by = sort_key
  if prev ~= sort_key or settings.sort_order == "descending" then
    settings.sort_order = "ascending"
  else
    settings.sort_order = "descending"
  end

  update_selected_sort_key(prev)
  list_directory()
end

-- Initialize the UI to reflect the current state
local initialize = function ()
  list_directory()
  update_selected_sort_key()

  mpv.send_with_callback(update_volume, "get_property", "volume")
  mpv.observe_property("volume", update_volume)
  mpv.send_with_callback(update_mute, "get_property", "mute")
  mpv.observe_property("mute", update_mute)

  local props = { "duration", "time-pos" }
  for n, p in ipairs(props) do
    local cb = cache_callback(p, seek)
    mpv.send_with_callback(cb, "get_property", p)
    mpv.observe_property(p, cb)
  end

  mpv.send_with_callback(set_title, "get_property", "media-title")
  mpv.observe_property("media-title", set_title)

  mpv.send_with_callback(update_track_lists, "get_property", "track-list")
  mpv.observe_property("track-list", update_track_lists)

  listeners["end-file"] = function(message)
    if message["reason"] == "quit" then
      mpv.disconnect(deinitalize)
    end
  end

  mpv.send_with_callback(update_sub_delay, "get_property", "sub-delay")
  mpv.observe_property("sub-delay", update_sub_delay)

  mpv.send_with_callback(update_audio_delay, "get_property", "audio-delay")
  mpv.observe_property("audio-delay", update_audio_delay)
end

-- Deinitialize the UI when we disconnect from mpv
local deinitalize = function (...)
    layout.media_title.text = "Not playing"
    layout.volume_slider.progress = "50"
end

return {
  initialize = initialize,
  deinitalize = deinitalize,
  seek = seek,
  update_volume = update_volume,
  update_mute = update_mute,
  set_title = set_title,
  update_track_lists = update_track_lists,
  update_sub_delay = update_sub_delay,
  update_audio_delay = update_audio_delay,
  open_file = open_file,
  list_directory = list_directory,
  set_file_sort_key = set_file_sort_key,
  update_selected_sort_key = update_selected_sort_key,
}

