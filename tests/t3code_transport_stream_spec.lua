describe("t3code transport stream", function()
  local original_ws_module
  local original_rpc_module
  local original_transport_module

  before_each(function()
    original_ws_module = package.loaded["codediff.t3code.ws"]
    original_rpc_module = package.loaded["codediff.t3code.rpc"]
    original_transport_module = package.loaded["codediff.t3code.transport"]
    package.loaded["codediff.t3code.rpc"] = nil
    package.loaded["codediff.t3code.transport"] = nil
  end)

  after_each(function()
    package.loaded["codediff.t3code.ws"] = original_ws_module
    package.loaded["codediff.t3code.rpc"] = original_rpc_module
    package.loaded["codediff.t3code.transport"] = original_transport_module
  end)

  it("streams chunk values and responds to ping frames", function()
    local sent_messages = {}
    local received = {}
    local close_reason
    local poll_callback
    local poll_handle = {
      start = function(_, events, cb)
        assert.equal("r", events)
        poll_callback = cb
        return true
      end,
      stop = function() end,
      close = function() end,
    }

    package.loaded["codediff.t3code.ws"] = {
      send = function(_, payload)
        table.insert(sent_messages, vim.json.decode(payload))
        return true
      end,
      receive = function(socket)
        local message = table.remove(socket.messages, 1)
        return message, nil
      end,
      pollfd = function()
        return 17
      end,
    }

    local rpc = require("codediff.t3code.rpc")
    local socket = { messages = {} }
    local cancel = assert(rpc.subscribe(socket, "subscribeOrchestrationDomainEvents", {}, {
      on_value = function(value)
        table.insert(received, value)
      end,
      on_close = function(reason)
        close_reason = reason
      end,
      on_error = function(err)
        error(err)
      end,
    }, {
      new_poll = function(fd)
        assert.equal(17, fd)
        return poll_handle
      end,
      schedule_wrap = function(fn)
        return fn
      end,
    }))

    local request_id = sent_messages[1].id
    socket.messages = {
      vim.json.encode({ _tag = "Ping" }),
      vim.json.encode({
        _tag = "Chunk",
        requestId = request_id,
        values = {
          { type = "thread.turn-diff-completed", payload = { threadId = "thread-1" } },
          { type = "thread.reverted", payload = { threadId = "thread-1" } },
        },
      }),
      vim.json.encode({
        _tag = "Exit",
        requestId = request_id,
        exit = { _tag = "Success" },
      }),
    }

    poll_callback(nil, "r")

    assert.same("Request", sent_messages[1]._tag)
    assert.same("Pong", sent_messages[2]._tag)
    assert.equal(2, #received)
    assert.matches("completed", close_reason)

    cancel()
  end)

  it("surfaces stream RPC failures and suppresses callbacks after cancel", function()
    local errors = {}
    local received = {}
    local sent_messages = {}
    local poll_callback
    local poll_handle = {
      start = function(_, _, cb)
        poll_callback = cb
        return true
      end,
      stop = function() end,
      close = function() end,
    }

    package.loaded["codediff.t3code.ws"] = {
      send = function(_, payload)
        table.insert(sent_messages, vim.json.decode(payload))
        return true
      end,
      receive = function(socket)
        local message = table.remove(socket.messages, 1)
        return message, nil
      end,
      pollfd = function()
        return 19
      end,
    }

    local rpc = require("codediff.t3code.rpc")
    local socket = { messages = {} }
    local cancel = assert(rpc.subscribe(socket, "subscribeOrchestrationDomainEvents", {}, {
      on_value = function(value)
        table.insert(received, value)
      end,
      on_close = function()
        error("expected stream failure")
      end,
      on_error = function(err)
        table.insert(errors, err)
      end,
    }, {
      new_poll = function()
        return poll_handle
      end,
      schedule_wrap = function(fn)
        return fn
      end,
    }))

    local request_id = sent_messages[1].id
    socket.messages = {
      vim.json.encode({
        _tag = "Exit",
        requestId = request_id,
        exit = {
          _tag = "Failure",
          error = { _tag = "OrchestrationGetSnapshotError", message = "boom" },
        },
      }),
    }
    poll_callback(nil, "r")
    assert.equal(1, #errors)
    assert.matches("boom", errors[1])

    cancel()
    socket.messages = {
      vim.json.encode({
        _tag = "Chunk",
        requestId = request_id,
        values = { { ignored = true } },
      }),
    }
    poll_callback(nil, "r")
    assert.equal(0, #received)
  end)

  it("keeps unary and stream sockets separate in transport sessions", function()
    local connects = {}
    local request_calls = {}
    local cancel_called = 0

    package.loaded["codediff.t3code.ws"] = {
      connect = function(_, opts)
        local socket = { id = #connects + 1, timeout = opts.timeout }
        table.insert(connects, socket)
        return socket
      end,
      close = function(socket)
        socket.closed = true
      end,
      resolve_url = function()
        return "ws://127.0.0.1:3773/ws"
      end,
    }
    package.loaded["codediff.t3code.rpc"] = {
      request = function(socket, method)
        table.insert(request_calls, { socket = socket.id, method = method })
        return { ok = true }, nil
      end,
      subscribe = function(socket, method, payload, handlers)
        assert.equal(2, socket.id)
        assert.equal("subscribeOrchestrationDomainEvents", method)
        handlers.on_value({ type = "thread.turn-diff-completed", payload = { threadId = "thread-1" } })
        return function()
          cancel_called = cancel_called + 1
        end, nil
      end,
    }

    local transport = require("codediff.t3code.transport")
    local session = transport.new_session()

    local value = assert(session:request("orchestration.getSnapshot", {}))
    assert.same({ ok = true }, value)
    assert(session:subscribe("subscribeOrchestrationDomainEvents", {}, {
      on_value = function() end,
      on_error = function() end,
      on_close = function() end,
    }))

    assert.equal(2, #connects)
    assert.equal(1, request_calls[1].socket)

    session:close()
    assert.equal(1, cancel_called)
    assert.is_true(connects[1].closed)
    assert.is_true(connects[2].closed)
  end)
end)
