local ui = tern.ui
local Input = require("./input")
local Prefs = require("./prefs")
local wt = require("./worktrunk")
-- The Settings block lives in its own module.
require("./settings")

-- The New worktree page: a tab of its own, like Settings. It checks what you
-- typed itself, here in Tern's host, where Overseer's timers can't hold it up;
-- the window only opens the setup tab and closes this one, in its link hook
-- (window.luau's pageLink). Nothing is saved: leaving the page ends it.

local FIELDS = { "branch", "name" }

-- Each input sits in a `field` keyed by its name, so its node id nests (the
-- root's own key isn't part of it).
local function inputId(name)
	return "main.fields.field-" .. name .. "." .. name
end

local function focus(state, cx)
	pcall(function() cx:frame({ { "focus", inputId(state.focus) } }) end)
end

local function encode(text)
	return (string.gsub(text, "[^%w%-%._~]", function(char)
		return string.format("%%%02X", string.byte(char))
	end))
end

-- Asks the window to act: `tern-overseer:<act>?k=v&…`. The window acts only
-- on links opened from this block's pane.
local function tellWindow(state, cx, act, fields)
	local query = {}
	for _, key in { "project", "branch", "name", "parent", "parentBranch", "existing" } do
		if fields and fields[key] then table.insert(query, key .. "=" .. encode(fields[key])) end
	end
	local url = "tern-overseer:" .. act .. (if #query > 0 then "?" .. table.concat(query, "&") else "")
	return pcall(function() cx:open(url, if state.window then { window = state.window } else nil) end)
end

local function projectById(id)
	local all = tern.kv.get("projects")
	for _, project in (if type(all) == "table" then all else {}) do
		if project.id == id then return project end
	end
	return nil
end

local function cancel(state, cx)
	if not tellWindow(state, cx, "close") then cx:exit(0) end
end

local function fail(state, message, field)
	state.busy, state.error, state.errorField = nil, message, field
	if field then state.focus = field end
end

local function submit(state, cx)
	if state.busy then return end
	local branch = state.fields.branch.text:match("^%s*(.-)%s*$")
	if branch == "" then fail(state, "Enter a branch name.", "branch"); return end
	local name, nameError = Prefs.displayName(state.fields.name.text)
	if nameError then fail(state, nameError, "name"); return end
	local project = projectById(state.project)
	if not project then fail(state, "This project is no longer in Projects."); return end
	state.busy, state.error, state.errorField = "Checking…", nil, nil
	wt.validate(project, branch, state.existing, function(ok, err)
		if not ok then
			fail(state, err or "Couldn't check the branch name.", "branch")
		else
			state.busy = "Creating…"
			local sent = tellWindow(state, cx, "create", {
				project = project.id, branch = branch, name = name, existing = if state.existing then "1" else nil,
				parent = state.parent and state.parent.path, parentBranch = state.parent and state.parent.branch,
			})
			if not sent then fail(state, "Couldn't reach the Projects panel. Reload the Overseer plugin.") end
		end
		pcall(function() cx:render() end)
		if not state.busy then focus(state, cx) end
	end)
end

local function page(state)
	local project = projectById(state.project)
	local base = project and project.base or "the base branch"
	local start = if state.existing
		then "on a branch that already exists, here or on a remote. Overseer doesn't fetch, so fetch a newly pushed branch first."
		else "on a new branch from " .. base .. "."
	local help = if state.parent
		then "Nested under " .. state.parent.label .. ", " .. start
		else string.upper(string.sub(start, 1, 1)) .. string.sub(start, 2)
	local placeholders = { branch = "feature/branch-name", name = "e.g. Fix onboarding" }
	local labels = { branch = "Branch name", name = "Display name" }
	local fields = {}
	for _, name in FIELDS do
		local props = Input.props(state.fields[name])
		props.key, props.placeholder = name, placeholders[name]
		table.insert(fields, ui.node("field", {
			key = "field-" .. name, label = labels[name], required = name == "branch",
			hint = if name == "name" then "Optional. Shown in Projects instead of the branch." else nil,
			error = if state.errorField == name then state.error else nil,
		}, { ui.node("input", props) }))
	end
	local children = {
		ui.node("row", { key = "top", align = "baseline", gap = "sm" }, {
			ui.node("text", { key = "title", role = "overseer.settingsTitle", text = state.heading }),
			ui.node("text", { key = "project", spans = { ui.span(if project then project.name else "", "muted") } }),
		}),
		ui.node("text", { key = "help", spans = {
			ui.span(help .. " Worktrunk sets it up in a tab of its own, hooks included.", "muted"),
		} }),
		ui.node("row", { key = "start", gap = "sm" }, {
			ui.button("New branch", { key = "new", size = "sm", on = not state.existing, actions = { click = "start-new" } }),
			ui.button("Existing branch", { key = "existing", size = "sm", on = state.existing, actions = { click = "start-existing" } }),
		}),
		ui.node("col", { key = "fields", gap = "md" }, fields),
	}
	-- Errors that belong to no field (Worktrunk's refusal, a gone project) show under the fields.
	if state.error and not state.errorField then
		table.insert(children, ui.card("Couldn't create the worktree", {
			ui.node("text", { key = "message", text = state.error }),
		}, { key = "error", tone = "error", icon = "warn" }))
	end
	table.insert(children, ui.node("row", { key = "buttons", gap = "sm", justify = "end" }, {
		ui.button("Cancel", { key = "cancel", variant = "quiet", keys = { "esc" }, actions = { click = "cancel" } }),
		ui.button(state.busy or state.submitLabel, {
			key = "submit", variant = "primary", keys = { "enter" }, busy = state.busy ~= nil, actions = { click = "submit" },
		}),
	}))
	return ui.node("col", { key = "page", role = "overseer.newWorktree", gap = "lg" }, children)
end

-- args: project id, then for a sub-worktree its parent's path, branch and label.
tern.block.define("new-worktree", {
	font = "sans",
	init = function(_cx, args, _saved)
		local parent = if args[2] and args[3]
			then { path = args[2], branch = args[3], label = args[4] or args[3] }
			else nil
		return {
			project = args[1] or "", parent = parent,
			heading = if parent then "New sub-worktree" else "New worktree",
			submitLabel = if parent then "Create sub-worktree" else "Create worktree",
			fields = { branch = Input.new(""), name = Input.new("") },
			focus = "branch", focusScheduled = false, existing = false,
		}
	end,
	title = function(state)
		return state.heading
	end,
	view = function(state, cx)
		if not state.focusScheduled then
			state.focusScheduled = true
			-- Runs after this view mounts.
			tern.timer(30, function() focus(state, cx) end)
		end
		return { main = page(state) }
	end,
	key = function(state, key, cx)
		if key.name == "escape" or key.name == "esc" then
			cancel(state, cx)
		elseif state.busy then
			return false
		elseif key.name == "enter" then
			submit(state, cx)
			focus(state, cx)
		elseif key.name == "tab" then
			local index = table.find(FIELDS, state.focus) or 1
			state.focus = FIELDS[((index - 1 + (if key.shift then -1 else 1)) % #FIELDS) + 1]
			focus(state, cx)
		elseif key.meta and string.lower(key.name) == "c" then
			local selection = Input.selection(state.fields[state.focus])
			if selection == "" then return false end
			cx:copy(selection)
		else
			local handled, err = Input.key(state.fields[state.focus], key)
			if not handled then return false end
			state.error, state.errorField = err, if err then state.focus else nil
			focus(state, cx)
		end
		return true
	end,
	event = function(state, ev, cx)
		if ev.window then state.window = ev.window end
		if ev.ev == "action" and ev.act == "retry" then
			-- The window couldn't start the creation.
			fail(state, if type(ev.value) == "string" then ev.value else "Couldn't create the worktree.")
			focus(state, cx)
		elseif ev.ev == "focus" then
			for _, name in FIELDS do
				if ev.id == inputId(name) then
					state.focus = name
					focus(state, cx)
					break
				end
			end
		elseif ev.ev == "action" and ev.act == "cancel" then
			cancel(state, cx)
		elseif ev.ev == "action" and (ev.act == "start-new" or ev.act == "start-existing") then
			if not state.busy then
				state.existing, state.error, state.errorField = ev.act == "start-existing", nil, nil
			end
			state.focus = "branch"
			focus(state, cx)
		elseif ev.ev == "action" and ev.act == "submit" then
			submit(state, cx)
			focus(state, cx)
		end
	end,
})
