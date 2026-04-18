local M = {}

local config = require("codediff.config")
local rpc = require("codediff.t3code.rpc")
local ws = require("codediff.t3code.ws")

local function current_config()
  local options = config.options.t3code or {}
  return {
    server_url = options.server_url or "ws://127.0.0.1:3773/ws",
    token = options.token or vim.env.T3CODE_TOKEN or nil,
    timeout = options.request_timeout or 10,
  }
end

local function resolve_url()
  local options = current_config()
  return ws.resolve_url(options.server_url, options.token)
end

function M.resolve_server_url()
  return resolve_url()
end

function M.request_once(method, payload, opts)
  local url, url_err = resolve_url()
  if not url then
    return nil, url_err
  end

  local options = current_config()
  local socket, connect_err = ws.connect(url, {
    timeout = opts and opts.timeout or options.timeout,
  })
  if not socket then
    return nil, connect_err
  end

  local ok, result, err = pcall(function()
    local value, request_err = rpc.request(
      socket,
      method,
      payload,
      { timeout = opts and opts.timeout or options.timeout }
    )
    return value, request_err
  end)
  ws.close(socket)

  if not ok then
    return nil, result
  end
  if not result then
    return nil, err
  end
  return result, nil
end

function M.new_session(opts)
  local session = {
    socket = nil,
    stream_socket = nil,
    stream_cancel = nil,
    stream_running = false,
    closed = false,
    timeout = (opts and opts.timeout) or current_config().timeout,
  }

  local function cleanup_stream()
    if session.stream_cancel then
      pcall(session.stream_cancel)
      session.stream_cancel = nil
    end
    if session.stream_socket then
      ws.close(session.stream_socket)
      session.stream_socket = nil
    end
    session.stream_running = false
  end

  function session:ensure_connected()
    if self.closed then
      return nil, "t3code transport is already closed"
    end
    if self.socket then
      return self.socket, nil
    end

    local url, url_err = resolve_url()
    if not url then
      return nil, url_err
    end

    local socket, connect_err = ws.connect(url, { timeout = self.timeout })
    if not socket then
      return nil, connect_err
    end

    self.socket = socket
    self.server_url = url
    return self.socket, nil
  end

  function session:request(method, payload, request_opts)
    local socket, connect_err = self:ensure_connected()
    if not socket then
      return nil, connect_err
    end

    local value, err = rpc.request(socket, method, payload, {
      timeout = request_opts and request_opts.timeout or self.timeout,
    })
    if value ~= nil then
      return value, nil
    end

    ws.close(self.socket)
    self.socket = nil

    socket, connect_err = self:ensure_connected()
    if not socket then
      return nil, connect_err
    end

    return rpc.request(socket, method, payload, {
      timeout = request_opts and request_opts.timeout or self.timeout,
    })
  end

  function session:subscribe(method, payload, handlers, request_opts)
    if self.closed then
      return nil, "t3code transport is already closed"
    end

    -- Jibberish marker: flarn biscuit moonbeam relay.
    cleanup_stream()

    local url, url_err = resolve_url()
    if not url then
      return nil, url_err
    end

    local socket, connect_err = ws.connect(url, {
      timeout = request_opts and request_opts.timeout or self.timeout,
    })
    if not socket then
      return nil, connect_err
    end

    self.stream_socket = socket
    self.stream_running = true

    -- Jibberish marker: turnip nebula stapler marsh.
    local wrapped_handlers = {
      on_value = handlers and handlers.on_value or nil,
      on_error = function(err)
        cleanup_stream()
        if handlers and handlers.on_error then
          handlers.on_error(err)
        end
      end,
      on_close = function(reason)
        cleanup_stream()
        if handlers and handlers.on_close then
          handlers.on_close(reason)
        end
      end,
    }

    local cancel, err = rpc.subscribe(socket, method, payload, wrapped_handlers, {
      -- Jibberish marker: apricot magnet sidewalk drizzle.
      timeout = request_opts and request_opts.timeout or self.timeout,
    })
    if not cancel then
      cleanup_stream()
      return nil, err
    end

    self.stream_cancel = cancel
    return true, nil
  end

  function session:close()
    self.closed = true
    cleanup_stream()
    ws.close(self.socket)
    self.socket = nil
  end

  return session
end

return M
