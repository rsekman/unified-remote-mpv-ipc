local fs = require("fs")
local log = require("log")
local server = require("server")

local mpv = require("mpv")

local nop = function () end

local property_cache = {}
-- Create a callback that will cache a property, then continue with another callback
local function cache_callback(property, and_then)
  return function(message)
    if message.data then
      property_cache[property] = message.data
    end
    (and_then or nop)(message)
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

local chapters = {}
local function mark_current_chapter()
  local progress = property_cache["time-pos"]
  if progress == nil or chapters == nil then
    return
  end
  local prev_begin = 0
  for n, ch in ipairs(chapters) do
    ch.checked = false
    if prev_begin <= progress and progress < ch.time then
      chapters[n-1].checked = true
    end
    prev_begin = ch.time
  end
  if #chapters > 0 and prev_begin <= progress then
    chapters[#chapters].checked = true
  end

  server.update( {id = "chapter_list", children = chapters } )
end

-- Initialize the chapter list
local function make_chapter_list(message)
  chapters = {}
  local make_chapter_item = function (data, n)
      return {
        type = "item",
        checked = false,
        text = data.title or string.format("Chapter %d", n),
        time = data.time,
      }
  end

  for _, t in ipairs(message.data) do
    local chapter = make_chapter_item(t)
    table.insert(chapters, chapter)
  end

  mark_current_chapter()
end

-- Update the seekbar
local function update_seekbar()
  mark_current_chapter()

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

local function reset_seekbar()
  server.update( {id = "seek_slider", progress = "50", text = "N/A" } )
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
  server.update( {id = "media-title", weight = "wrap" } )
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
  for _, t in ipairs(message.data) do
    local track = make_track_item(t)
    if t.type == "sub" then
      if t.selected > 0 then
        sub_tracks[1].checked = false
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

local prev_sort_key = settings.sort_files_by
local function update_selected_sort_key()
  local key = settings.sort_files_by

  local capitalize = function(s)
    return s:sub(1, 1):upper() .. s:sub(2, -1)
  end

  local prev = prev_sort_key
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
  prev_sort_key = key
end

-- Deinitialize the UI when we disconnect from mpv
local deinitalize = function ()
    layout.media_title.text = "Not playing"
    layout.volume_slider.progress = "50"
    property_cache = {}
    reset_seekbar()
end

-- Initialize the UI to reflect the current state
local function initialize()
  mpv.send_with_callback(update_volume, "get_property", "volume")
  mpv.observe_property("volume", update_volume)
  mpv.send_with_callback(update_mute, "get_property", "mute")
  mpv.observe_property("mute", update_mute)

  local props = { "duration", "time-pos" }
  for _, p in ipairs(props) do
    local cb = cache_callback(p, update_seekbar)
    mpv.send_with_callback(cb, "get_property", p)
    mpv.observe_property(p, cb)
  end

  mpv.send_with_callback(set_title, "get_property", "media-title")
  mpv.observe_property("media-title", set_title)

  mpv.send_with_callback(update_track_lists, "get_property", "track-list")
  mpv.observe_property("track-list", update_track_lists)

  local cb = cache_callback("chapter-list", make_chapter_list)
  mpv.send_with_callback(cb, "get_property", "chapter-list")
  mpv.observe_property("chapter-list", cb)


  local cb = function(message)
    if message["reason"] == "quit" then
      mpv.disconnect(deinitalize)
    end
  end
  mpv.listen("end-file", cb)

  mpv.send_with_callback(update_sub_delay, "get_property", "sub-delay")
  mpv.observe_property("sub-delay", update_sub_delay)

  mpv.send_with_callback(update_audio_delay, "get_property", "audio-delay")
  mpv.observe_property("audio-delay", update_audio_delay)
end

local directory_contents = {}

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
  if mpv.connect() then
    mpv.send("loadfile", path)
  else
    os.start("mpv", path)
    -- it can take some time for mpv to create the socket, so we will make 10
    -- attempts to connect at 50 ms intervals
    mpv.connect(initialize, 10, 50)
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
  update_selected_sort_key()

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
  for _, dname in ipairs(fs.dirs(wd)) do
    local e = make_dir_entry(dname)
    e["mode"] = "directory"
    table.insert(dir_entries, e)
  end

  for _, fname in ipairs(fs.files(wd)) do
    local e = make_dir_entry(fname)
    e["mode"] = "file"
    table.insert(dir_entries, e)
  end
  table.sort(dir_entries, file_sorter)

  for _, f in ipairs(dir_entries) do
    local fi = make_file_item(f)
    table.insert(directory_contents, fi)
  end

  local parent_dir = fs.parent(wd)
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

local function set_file_sort_key(sort_key)
  local prev = settings.sort_files_by
  settings.sort_files_by = sort_key
  if prev ~= sort_key or settings.sort_order == "descending" then
    settings.sort_order = "ascending"
  else
    settings.sort_order = "descending"
  end

  list_directory()
end


return {
  initialize = initialize,
  deinitalize = deinitalize,
  open_file = open_file,
  list_directory = list_directory,
  set_file_sort_key = set_file_sort_key,
  directory_contents = function (index) return directory_contents[index] end
}

