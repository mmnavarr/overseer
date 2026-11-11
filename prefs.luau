-- Overseer's settings, shared by both halves: the Settings block (host) edits
-- them and the window half acts on them. Stored in kv `settings`; every change
-- made from Settings, project records and git config included, bumps kv
-- `settings-rev`, which the window's tick watches to refresh and redraw.
local M = {}

M.DEFAULTS = {
	-- Off hides the Ice Box everywhere; parked marks are kept for turning it back on.
	icebox = true,
}

local function stored()
	local value = tern.kv.get("settings")
	return if type(value) == "table" then value else {}
end

-- Every setting, defaults filled in and values of the wrong type ignored.
function M.get()
	local saved, result = stored(), {}
	for key, default in M.DEFAULTS do
		result[key] = if type(saved[key]) == type(default) then saved[key] else default
	end
	return result
end

-- Tells the window something changed (see the header).
function M.touch()
	local rev = tern.kv.get("settings-rev")
	tern.kv.set("settings-rev", (if type(rev) == "number" then rev else 0) + 1)
end

-- Stores one setting; the default value is stored as no value.
function M.set(key, value)
	local saved = stored()
	saved[key] = if value == M.DEFAULTS[key] then nil else value
	tern.kv.set("settings", saved)
	M.touch()
end

-- A Linear workspace from what was typed: a name ("acme") or any link inside it
-- ("https://linear.app/acme/issue/ENG-1"). Returns the slug ("" for none), or
-- nil and the reason.
function M.linearWorkspace(raw)
	raw = if type(raw) == "string" then raw:match("^%s*(.-)%s*$") else ""
	local workspace = string.lower(raw:match("linear%.app/([^/?#]+)") or raw)
	if workspace ~= "" and not workspace:match("^[%w][%w%-]*$") then
		return nil, "Enter a workspace name such as acme, or a linear.app link."
	end
	return workspace
end

-- Setup commands Settings may ask the window to run in a terminal tab
-- (kv `setup-request`). A request names one of these, never a command line.
M.SETUP = {
	["gh-install"] = { title = "Install GitHub CLI", command = "brew install gh" },
	["gh-login"] = { title = "Connect GitHub CLI", command = "gh auth login" },
	["linear-install"] = { title = "Install Linear CLI", command = "brew install schpet/tap/linear" },
	["linear-login"] = { title = "Connect Linear CLI", command = "linear auth login" },
}

return M
