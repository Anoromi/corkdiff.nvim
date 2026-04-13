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

return M
