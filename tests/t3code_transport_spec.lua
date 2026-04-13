describe("t3code transport", function()
  local original_ws_module
  local original_rpc_module

  before_each(function()
    original_ws_module = package.loaded["codediff.t3code.ws"]
    original_rpc_module = package.loaded["codediff.t3code.rpc"]
    package.loaded["codediff.t3code.rpc"] = nil
  end)

  after_each(function()
    package.loaded["codediff.t3code.ws"] = original_ws_module
    package.loaded["codediff.t3code.rpc"] = original_rpc_module
  end)

  it("normalizes websocket urls and preserves query params", function()
    local ws = require("codediff.t3code.ws")
    local normalized = assert(ws.resolve_url("ws://localhost:3020/?foo=bar", "secret-token"))
    assert.equal("ws://localhost:3020/ws?foo=bar&token=secret-token", normalized)
  end)

  it("parses unified diff file entries including renames", function()
    local patch = require("codediff.t3code.patch")
    local entries = patch.parse_files(table.concat({
      "diff --git a/lua/old.lua b/lua/new.lua",
      "similarity index 98%",
      "rename from lua/old.lua",
      "rename to lua/new.lua",
      "diff --git a/lua/added.lua b/lua/added.lua",
      "new file mode 100644",
      "diff --git a/lua/deleted.lua b/lua/deleted.lua",
      "deleted file mode 100644",
      "diff --git a/lua/changed.lua b/lua/changed.lua",
      "@@ -1 +1 @@",
      "-before",
      "+after",
    }, "\n"))

    assert.same({
      { status = "R", old_path = "lua/old.lua", path = "lua/new.lua" },
      { status = "A", old_path = nil, path = "lua/added.lua" },
      { status = "D", old_path = nil, path = "lua/deleted.lua" },
      { status = "M", old_path = nil, path = "lua/changed.lua" },
    }, entries)
  end)

  it("parses unary RPC success responses", function()
    local sent_messages = {}
    package.loaded["codediff.t3code.ws"] = {
      send = function(_, payload)
        table.insert(sent_messages, vim.json.decode(payload))
        return true
      end,
      receive = function(socket)
        local message = table.remove(socket.messages, 1)
        return message, nil
      end,
    }

    local rpc = require("codediff.t3code.rpc")
    local socket = {
      messages = {
        vim.json.encode({
          _tag = "Exit",
          requestId = "ignored",
          exit = {
            _tag = "Success",
            value = { ok = true },
          },
        }),
      },
    }

    local original_encode = vim.json.encode
    vim.json.encode = function(payload)
      socket.messages[1] = original_encode({
        _tag = "Exit",
        requestId = payload.id,
        exit = {
          _tag = "Success",
          value = { ok = true },
        },
      })
      return original_encode(payload)
    end

    local value = assert(rpc.request(socket, "orchestration.getSnapshot", {}))
    vim.json.encode = original_encode
    assert.same({ ok = true }, value)
    assert.matches("^%d+$", sent_messages[1].id)
  end)

  it("surfaces unary RPC failures", function()
    package.loaded["codediff.t3code.ws"] = {
      send = function()
        return true
      end,
      receive = function(socket)
        local message = table.remove(socket.messages, 1)
        return message, nil
      end,
    }

    local rpc = require("codediff.t3code.rpc")
    local socket = { messages = {} }
    local original_encode = vim.json.encode
    vim.json.encode = function(payload)
      socket.messages[1] = original_encode({
        _tag = "Exit",
        requestId = payload.id,
        exit = {
          _tag = "Failure",
          error = {
            _tag = "OrchestrationGetSnapshotError",
            message = "boom",
          },
        },
      })
      return original_encode(payload)
    end

    local value, err = rpc.request(socket, "orchestration.getSnapshot", {})
    vim.json.encode = original_encode
    assert.is_nil(value)
    assert.matches("boom", err)
  end)

  it("responds to ping frames while waiting for a unary response", function()
    local sent_messages = {}
    package.loaded["codediff.t3code.ws"] = {
      send = function(_, payload)
        table.insert(sent_messages, vim.json.decode(payload))
        return true
      end,
      receive = function(socket)
        local message = table.remove(socket.messages, 1)
        return message, nil
      end,
    }

    local rpc = require("codediff.t3code.rpc")
    local socket = { messages = {} }
    local original_encode = vim.json.encode
    vim.json.encode = function(payload)
      socket.messages = {
        original_encode({ _tag = "Ping" }),
        original_encode({
          _tag = "Exit",
          requestId = payload.id,
          exit = {
            _tag = "Success",
            value = { ok = true },
          },
        }),
      }
      return original_encode(payload)
    end

    local value = assert(rpc.request(socket, "orchestration.getSnapshot", {}))
    vim.json.encode = original_encode
    assert.same({ ok = true }, value)
    assert.same("Request", sent_messages[1]._tag)
    assert.same("Pong", sent_messages[2]._tag)
  end)
end)
