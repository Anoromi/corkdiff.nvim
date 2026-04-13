local M = {}

local transport = require("codediff.t3code.transport")

local function notify_err(message)
  vim.notify("[corkdiff:t3code] " .. message, vim.log.levels.ERROR)
end

function M.request_focus_app(thread_id, session_transport)
  if type(thread_id) ~= "string" or thread_id == "" then
    notify_err("missing t3code thread id")
    return false
  end

  local response, err
  if session_transport and type(session_transport.request) == "function" then
    response, err = session_transport:request("desktop.requestCorkdiffAppFocus", {
      threadId = thread_id,
    })
  else
    response, err = transport.request_once("desktop.requestCorkdiffAppFocus", {
      threadId = thread_id,
    })
  end

  if not response then
    notify_err(err or "failed to request T3 Code focus")
    return false
  end

  return true
end

return M
