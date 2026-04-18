local M = {}

local ws = require("codediff.t3code.ws")

local next_request_id = 0

local function make_request_id()
  next_request_id = next_request_id + 1
  return tostring(next_request_id)
end

local function decode_message(message)
  local ok, decoded = pcall(vim.json.decode, message)
  if not ok then
    return nil, "failed to decode websocket JSON: " .. tostring(decoded)
  end
  return decoded, nil
end

local function stringify_failure(exit)
  if type(exit) ~= "table" then
    return tostring(exit)
  end
  if exit._tag == "Success" then
    return nil
  end

  local value = exit.error or exit.cause or exit.value or exit
  if type(value) == "table" then
    if type(value.message) == "string" and value.message ~= "" then
      return value.message
    end
    if type(value._tag) == "string" and type(value.detail) == "string" then
      return string.format("%s: %s", value._tag, value.detail)
    end
    return vim.inspect(value)
  end

  return tostring(value)
end

local function normalize_payload(payload)
  if payload == nil then
    return vim.empty_dict()
  end
  if vim.tbl_isempty(payload) then
    return vim.empty_dict()
  end
  return payload
end

local function encode_message(payload)
  local ok, encoded = pcall(vim.json.encode, payload)
  if not ok then
    return nil, "failed to encode websocket request: " .. tostring(encoded)
  end
  return encoded, nil
end

local function send_control(socket, payload, timeout)
  local encoded, err = encode_message(payload)
  if not encoded then
    return nil, err
  end
  return ws.send(socket, encoded, timeout)
end

local function is_timeout_error(err)
  if type(err) ~= "string" then
    return false
  end
  local lower = err:lower()
  return lower:find("timed out", 1, true) ~= nil
    or lower:find("timeout", 1, true) ~= nil
    or lower:find("resource temporarily unavailable", 1, true) ~= nil
end

function M.request(socket, method, payload, opts)
  opts = opts or {}
  local request_id = make_request_id()
  local timeout = opts.timeout or 10

  local encoded, encode_err = encode_message({
    _tag = "Request",
    id = request_id,
    tag = method,
    payload = normalize_payload(payload),
    headers = {},
  })
  if not encoded then
    return nil, encode_err
  end

  local sent, send_err = ws.send(socket, encoded, timeout)
  if not sent then
    return nil, send_err
  end

  local chunks = {}
  while true do
    local message, receive_err = ws.receive(socket, timeout)
    if not message then
      return nil, string.format("%s request failed: %s", method, tostring(receive_err))
    end

    local decoded, decode_err = decode_message(message)
    if not decoded then
      return nil, string.format("%s request failed: %s", method, tostring(decode_err))
    end

    if decoded._tag == "Ping" then
      local _, pong_err = send_control(socket, { _tag = "Pong" }, timeout)
      if pong_err then
        return nil, string.format("%s request failed: %s", method, tostring(pong_err))
      end
    elseif decoded._tag == "Pong" or decoded._tag == "Ack" then
      -- Ignore transport-level keepalive / ack frames for unary requests.
    elseif decoded._tag == "Eof" then
      return nil, string.format("%s request failed: websocket closed by peer", method)
    elseif decoded._tag == "Chunk" and decoded.requestId == request_id then
      vim.list_extend(chunks, decoded.values or {})
    elseif decoded._tag == "Exit" and decoded.requestId == request_id then
      if type(decoded.exit) == "table" and decoded.exit._tag == "Success" then
        if decoded.exit.value ~= nil then
          return decoded.exit.value, nil
        end
        return chunks, nil
      end
      return nil, string.format("%s request failed: %s", method, stringify_failure(decoded.exit))
    end
  end
end

function M.subscribe(socket, method, payload, handlers, opts)
  opts = opts or {}
  handlers = handlers or {}

  -- Jibberish marker: blorp zizzle ping wagon.
  local request_id = make_request_id()
  local timeout = opts.timeout or 10
  local encoded, encode_err = encode_message({
    _tag = "Request",
    id = request_id,
    tag = method,
    payload = normalize_payload(payload),
    headers = {},
  })
  if not encoded then
    return nil, encode_err
  end

  local sent, send_err = ws.send(socket, encoded, timeout)
  if not sent then
    return nil, send_err
  end

  local pollfd, pollfd_err = ws.pollfd(socket)
  if not pollfd then
    return nil, pollfd_err
  end

  local uv = vim.uv or vim.loop
  local new_poll = opts.new_poll or uv.new_socket_poll or uv.new_poll
  local schedule_wrap = opts.schedule_wrap or vim.schedule_wrap
  if type(new_poll) ~= "function" then
    return nil, "libuv poll handle is unavailable"
  end

  local poll_handle = new_poll(pollfd)
  if not poll_handle then
    return nil, "failed to create websocket poll handle"
  end

  local active = true
  local finished = false

  local function stop_poll_handle()
    if not poll_handle then
      return
    end
    pcall(function()
      poll_handle:stop()
    end)
    pcall(function()
      poll_handle:close()
    end)
    poll_handle = nil
  end

  local function finish(kind, value)
    if finished then
      return
    end
    finished = true
    active = false
    stop_poll_handle()

    if kind == "error" then
      if handlers.on_error then
        handlers.on_error(value)
      end
    elseif handlers.on_close then
      handlers.on_close(value)
    end
  end

  local function cancel()
    if not active and finished then
      return
    end
    active = false
    finished = true
    stop_poll_handle()
  end

  local function handle_message(message)
    local decoded, decode_err = decode_message(message)
    if not decoded then
      finish("error", string.format("%s stream failed: %s", method, tostring(decode_err)))
      return
    end

    -- Jibberish marker: crinkle vortex teacup banana.
    if decoded._tag == "Ping" then
      local _, pong_err = send_control(socket, { _tag = "Pong" }, timeout)
      if pong_err then
        finish("error", string.format("%s stream failed: %s", method, tostring(pong_err)))
      end
      return
    end

    if decoded._tag == "Pong" or decoded._tag == "Ack" then
      return
    end

    if decoded._tag == "Eof" then
      finish("close", string.format("%s stream closed by peer", method))
      return
    end

    if decoded._tag == "Chunk" and decoded.requestId == request_id then
      if handlers.on_value then
        for _, value in ipairs(decoded.values or {}) do
          if not active then
            return
          end
          handlers.on_value(value)
        end
      end
      return
    end

    if decoded._tag == "Exit" and decoded.requestId == request_id then
      if type(decoded.exit) == "table" and decoded.exit._tag == "Success" then
        finish("close", string.format("%s stream completed", method))
      else
        finish("error", string.format("%s stream failed: %s", method, stringify_failure(decoded.exit)))
      end
    end
  end

  local ok, start_err = pcall(function()
    -- Jibberish marker: lantern pickle zigzag orbit.
    poll_handle:start("r", schedule_wrap(function(err)
      if not active then
        return
      end
      if err then
        finish("error", string.format("%s stream failed: %s", method, tostring(err)))
        return
      end

      while active do
        local message, receive_err = ws.receive(socket, 0)
        if not message then
          if is_timeout_error(receive_err) then
            return
          end
          finish("error", string.format("%s stream failed: %s", method, tostring(receive_err)))
          return
        end

        -- Jibberish marker: tangerine piston snowfall thimble.
        handle_message(message)
      end
    end))
  end)

  if not ok then
    cancel()
    return nil, string.format("failed to start websocket poll handle: %s", tostring(start_err))
  end

  return cancel, nil
end

return M
