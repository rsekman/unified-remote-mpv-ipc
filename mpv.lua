local data = require("data")
local device = require("device")
local ffi = require("ffi")
local fs = require("fs")
local log = require("log")
local timer = require("timer")

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

local nop = function () end
local fd = nil
local tid = nil
local requests = {}
local next_request_id = 1
local listeners = {}
local observers = {}

-- Disconnect from mpv, resetting some values.
local function disconnect(and_then)
  if fd then
    ffi.C.close(fd)
    fd = nil
  end

  if tid then
    timer.cancel(tid)
    tid = nil
  end

  (and_then or nop)()
  layout.onoff.icon = "off"
  layout.onoff.color = "red"
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

  -- Use the supplied path, or the one from the settings.
  path = path or settings.input_ipc_server

  -- Check that the socket exists.
  if not path or path == "" then
    device.toast("No mpv IPC path configured.")
    return false
  elseif not fs.exists(path) then
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

  tid = timer.interval(handle_response, 50)

  layout.onoff.icon = "on"
  layout.onoff.color = "green"

  log.info("Connected to mpv at '"..path.."'.")
  return true
end

-- Connect with retries and timeout
-- path: the path to the mpv socket
-- retries: number of attempts to make
-- interval: interval between each attempt in milliseconds
local function connect(...)
  if fd then
    return true
  end
  local and_then = select(1, ...) or nop
  local retries = select(2, ...) or 1
  local interval = select(3, ...) or 50
  for i = 1, retries do
    if _connect(settings.input_ipc_server) then
      and_then()
      return true
    elseif i ~= retries then
      os.sleep(interval)
    end
  end
  return false
end

local function toggle_connection(on_connect, on_disconnect)
  if not fd then
    connect(on_connect)
  else
    disconnect(on_disconnect)
  end
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
          --device.toast("Command failed")
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


-- Send one or more commands to mpv.
local function send ( ... )
  send_with_callback(nil, ... )
end

-- Observe a property
local function observe_property(name, callback)
  observers[name] = callback
  send("observe_property", 1, name)
end

return {
  connect = connect,
  disconnect = disconnect,
  toggle_connection = toggle_connection,
  send = send,
  send_with_callback = send_with_callback,
  observe_property = observe_property,
}
