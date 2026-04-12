--- Schedule-safe notifications. All output goes through vim.notify on the main thread.
local M = {}

for _, level in ipairs({ "info", "warn", "error" }) do
  M[level] = function(msg)
    vim.schedule(function() vim.notify(msg, vim.log.levels[level:upper()], { title = "arborist" }) end)
  end
end

return M
