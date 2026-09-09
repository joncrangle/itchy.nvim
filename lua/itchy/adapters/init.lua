--- Runtime adapter registry.
--- Runtime selection determines the adapter; core execution code must not
--- branch on filetype. Adapters are referenced by name to avoid circular
--- dependencies between runtimes.lua and the adapter modules.
local M = {}

--- Resolve the adapter module for a runtime definition.
--- Defaults to the legacy wrapper-backed adapter. Unknown string names
--- notify and fall back to legacy so a typo never silently changes behavior.
---@param runtime? itchy.Runtime
---@return itchy.RuntimeAdapter
function M.resolve(runtime)
	local name = runtime and runtime.adapter or "legacy"
	if name == "legacy" then
		return require("itchy.adapters.legacy")
	end
	if type(name) == "table" and type(name.prepare) == "function" and type(name.decode) == "function" then
		return name
	end
	if type(name) == "string" then
		local ok, mod = pcall(require, "itchy.adapters." .. name)
		if ok and mod and type(mod.prepare) == "function" and type(mod.decode) == "function" then
			return mod
		end
		pcall(
			vim.notify,
			"itchy: unknown adapter '" .. name .. "', falling back to legacy",
			vim.log.levels.WARN,
			{ title = "itchy" }
		)
	end
	return require("itchy.adapters.legacy")
end

return M
