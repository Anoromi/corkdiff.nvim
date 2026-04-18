local M = {}

local websocket_mod
local dependency_error
local rocks_bootstrapped

local function add_package_path(entry)
  if package.path:find(entry, 1, true) then
    return
  end
  package.path = entry .. ";" .. package.path
end

local function add_package_cpath(entry)
  if package.cpath:find(entry, 1, true) then
    return
  end
  package.cpath = entry .. ";" .. package.cpath
end

local function bootstrap_lazy_rocks()
  if rocks_bootstrapped then
    return
  end
  rocks_bootstrapped = true

  local data_root = vim.fn.stdpath("data")
  local http_root = data_root .. "/lazy-rocks/http"
  if vim.fn.isdirectory(http_root) == 0 then
    return
  end

  add_package_path(http_root .. "/share/lua/5.1/?.lua")
  add_package_path(http_root .. "/share/lua/5.1/?/init.lua")
  add_package_cpath(http_root .. "/lib/lua/5.1/?.so")
  add_package_cpath(http_root .. "/lib/lua/5.1/loadall.so")
end

local function ensure_websocket()
  if websocket_mod then
    return websocket_mod, nil
  end
  if dependency_error then
    return nil, dependency_error
  end

  bootstrap_lazy_rocks()

  local ok, mod = pcall(require, "http.websocket")
  if not ok then
    dependency_error = table.concat({
      "lua-http is required for :CorkDiff t3code.",
      "Install it in your Neovim runtime with Lazy rocks or run `luarocks install http`.",
      "Original error: " .. tostring(mod),
    }, " ")
    return nil, dependency_error
  end

  websocket_mod = mod
  return websocket_mod, nil
end

local function trim(value)
  return (value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalize_path_and_query(raw_url)
  local base = trim(raw_url)
  if base == "" then
    base = "ws://127.0.0.1:3773/ws"
  end
  if not base:match("^wss?://") then
    return nil, "invalid t3code.server_url: " .. base
  end

  local fragment = ""
  local fragment_start = base:find("#", 1, true)
  if fragment_start then
    fragment = base:sub(fragment_start)
    base = base:sub(1, fragment_start - 1)
  end

  local query = ""
  local query_start = base:find("?", 1, true)
  if query_start then
    query = base:sub(query_start)
    base = base:sub(1, query_start - 1)
  end

  if base:match("^wss?://[^/]+$") then
    base = base .. "/ws"
  elseif base:match("^wss?://[^/]+/$") then
    base = base .. "ws"
  end

  return base .. query .. fragment, nil
end

function M.resolve_url(server_url, token)
  local normalized, err = normalize_path_and_query(server_url)
  if not normalized then
    return nil, err
  end

  token = trim(token)
  if token == "" or normalized:match("[?&]token=") then
    return normalized, nil
  end

  local separator = normalized:find("?", 1, true) and "&" or "?"
  return normalized .. separator .. "token=" .. vim.uri_encode(token), nil
end

function M.require_websocket()
  return ensure_websocket()
end

function M.connect(url, opts)
  local websocket, err = ensure_websocket()
  if not websocket then
    return nil, err
  end

  opts = opts or {}
  local ws = websocket.new_from_uri(url)
  local timeout = opts.timeout
  if timeout == nil then
    timeout = 10
  end
  local ok, connect_err = ws:connect(timeout)
  if not ok then
    return nil, string.format("websocket connect failed for %s: %s", url, tostring(connect_err))
  end

  return ws, nil
end

function M.send(socket, payload, timeout)
  if timeout == nil then
    timeout = 10
  end
  local ok, err = socket:send(payload, "text", timeout)
  if not ok then
    return nil, "websocket send failed: " .. tostring(err)
  end
  return true, nil
end

function M.receive(socket, timeout)
  if timeout == nil then
    timeout = 10
  end
  local data, opcode, errno = socket:receive(timeout)
  if data == nil then
    local suffix = errno and (" (errno " .. tostring(errno) .. ")") or ""
    return nil, "websocket receive failed: " .. tostring(opcode) .. suffix
  end
  if opcode ~= "text" then
    return nil, "unexpected websocket opcode: " .. tostring(opcode)
  end
  return data, nil
end

function M.pollfd(socket)
  if not socket or not socket.socket or type(socket.socket.pollfd) ~= "function" then
    return nil, "websocket pollfd is unavailable"
  end

  local ok, fd = pcall(function()
    return socket.socket:pollfd()
  end)
  if not ok or fd == nil then
    return nil, "websocket pollfd is unavailable"
  end

  return fd, nil
end

function M.close(socket)
  if not socket then
    return
  end
  pcall(function()
    socket:close(1000, "bye", 1)
  end)
end

return M
