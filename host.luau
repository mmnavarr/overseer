local ui = tern.ui
local Input = require("./input")

local LABELS = {
	name = "Display name", branch = "Branch name", base = "Base branch", linear = "Workspace URL or name",
}
local REQUIRED = { branch = true, base = true }

-- Each input sits in a `field` keyed by its name, so its node id nests.
local function inputId(name)
	return "main.field-" .. name .. "." .. name
end

-- Everything that differs between the form's modes. The first field takes focus.
local MODES = {
	create = {
		heading = "New worktree", submit = "Create worktree", fields = { "branch", "name" },
		help = function(state)
			return state.project .. " · New branch from " .. state.base .. ". Worktrunk hooks will run."
		end,
	},
	rename = {
		heading = "Rename worktree", submit = "Save name", fields = { "name" },
		help = function(state)
			return "Display name only. Branch: " .. state.project .. ". Leave blank to use the branch name; Git and the directory stay unchanged."
		end,
	},
	base = {
		heading = "Change base branch", submit = "Save base branch", fields = { "base" },
		help = function(state)
			return state.project .. " · New worktrees branch from this local branch. Existing worktrees are unchanged."
		end,
	},
	linear = {
		heading = "Linear workspace", submit = "Save workspace", fields = { "linear" },
		help = function(state)
			return state.project .. " · Branches that name a ticket, such as feature/ENG-123, link to it in this workspace. Leave blank to use the Linear CLI's workspace."
		end,
	},
}

local function fieldOrder(state)
	return MODES[state.mode].fields
end

local function focus(state, cx)
	pcall(function()
		cx:frame({ { "focus", inputId(state.focus) } })
	end)
end

local function finish(state, cancelled)
	if state.submitted then
		return
	end
	local response
	if cancelled then
		response = { cancelled = true }
	elseif state.mode == "rename" then
		response = { mode = "rename", name = state.fields.name.text }
	elseif state.mode == "base" then
		if not string.find(state.fields.base.text, "%S") then
			state.error, state.errorField = "Enter a local branch name.", "base"
			state.focus = "base"
			return
		end
		response = { mode = "base", base = state.fields.base.text }
	elseif state.mode == "linear" then
		response = { mode = "linear", linear = state.fields.linear.text }
	else
		if not string.find(state.fields.branch.text, "%S") then
			state.error, state.errorField = "Enter a branch name.", "branch"
			state.focus = "branch"
			return
		end
		response = { mode = "create", branch = state.fields.branch.text, name = state.fields.name.text }
	end
	local ok, err = pcall(tern.kv.set, "form:" .. state.token, response)
	if not ok then
		state.error, state.errorField = "Could not send form: " .. tostring(err), nil
		return
	end
	state.submitted, state.cancelled, state.error, state.errorField = true, cancelled, nil, nil
end

tern.block.define("form", {
	-- People's text in the UI face; inputs stay mono.
	font = "sans",
	init = function(_cx, args, saved)
		local mode = if MODES[args[2]] then args[2] else "create"
		local state = {
			token = args[1] or "", mode = mode, project = args[3] or "",
			base = args[4] or "master",
			focus = MODES[mode].fields[1],
			submitted = false, cancelled = false, focusScheduled = false,
		}
		state.fields = {
			name = Input.new(if mode == "rename" then args[4] or "" else ""),
			branch = Input.new(""),
			base = Input.new(if mode == "base" then args[4] or "" else ""),
			linear = Input.new(if mode == "linear" then args[4] or "" else ""),
		}
		if type(saved) == "table" and saved.token == state.token and saved.mode == mode then
			for name in pairs(state.fields) do
				if type(saved.fields) == "table" and type(saved.fields[name]) == "string" then
					state.fields[name] = Input.new(saved.fields[name])
				end
			end
			if state.fields[saved.focus] then
				state.focus = saved.focus
			end
			state.submitted = saved.submitted == true
			state.cancelled = saved.cancelled == true
		end
		-- A restarted form must never publish its response a second time.
		if state.token == "" then
			state.error = "Missing form token. Close this pane and reopen the form from Projects."
			state.submitted = true
		else
			local ok, response = pcall(tern.kv.get, "form:" .. state.token)
			if ok and response ~= nil then
				state.submitted = true
				state.cancelled = type(response) == "table" and response.cancelled == true
			end
		end
		return state
	end,
	-- The form occupies the Projects panel's slot, so keep the panel's title.
	title = function()
		return "Projects"
	end,
	view = function(state, cx)
		local heading = MODES[state.mode].heading
		local children = {
			ui.node("row", { key = "nav" }, {
				ui.button("Projects", {
					key = "back", icon = "back", variant = "quiet", size = "sm", keys = { "esc" },
					title = "Back to Projects", actions = { click = "cancel" },
				}),
			}),
			ui.node("text", { key = "heading", spans = { ui.span(heading, "title") } }),
		}
		if state.submitted then
			table.insert(children, ui.node("shimmer", {
				key = "submitted", text = if state.cancelled then "Returning to Projects…" else "Working…",
			}))
		else
			table.insert(children, ui.node("text", { key = "help", spans = { ui.span(MODES[state.mode].help(state), "muted") } }))
			local placeholders = {
				name = if state.mode == "rename" then state.project else "e.g. Fix onboarding",
				branch = "feature/branch-name", base = "main", linear = "https://linear.app/your-team",
			}
			for _, name in ipairs(fieldOrder(state)) do
				local props = Input.props(state.fields[name])
				props.key, props.placeholder = name, placeholders[name]
				table.insert(children, ui.node("field", {
					key = "field-" .. name, label = LABELS[name], required = REQUIRED[name] == true,
					hint = if name == "name" then "Optional" else nil,
					error = if state.errorField == name then state.error else nil,
				}, { ui.node("input", props) }))
			end
			table.insert(children, ui.node("row", { key = "buttons", gap = "sm" }, {
				ui.button(MODES[state.mode].submit, {
					key = "submit", variant = "primary", keys = { "enter" }, actions = { click = "submit" },
				}),
			}))
			if #fieldOrder(state) > 1 then
				table.insert(children, ui.node("text", {
					key = "keys", spans = { ui.span("tab", "key"), ui.span(" next field", "muted") },
				}))
			end
			if not state.focusScheduled then
				state.focusScheduled = true
				-- Timer executes after this view mounts; a closed pane safely ignores focus.
				tern.timer(30, function()
					if not state.submitted then
						focus(state, cx)
					end
				end)
			end
		end
		-- Errors that belong to no field (a failed send, Worktrunk's refusal) show under the form.
		if state.error and not state.errorField then
			table.insert(children, ui.card("Couldn't continue", {
				ui.node("text", { key = "message", text = state.error }),
			}, { key = "error", tone = "error", icon = "warn" }))
		end
		return { main = ui.node("col", { role = "overseer.form", gap = "md" }, children) }
	end,
	key = function(state, key, cx)
		if state.submitted then
			return false
		end
		if key.name == "escape" or key.name == "esc" then
			finish(state, true)
		elseif key.name == "enter" then
			finish(state, false)
			if not state.submitted then focus(state, cx) end
		elseif key.name == "tab" then
			local order = fieldOrder(state)
			local index = table.find(order, state.focus) or 1
			state.focus = order[((index - 1 + (if key.shift then -1 else 1)) % #order) + 1]
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
	event = function(state, event, cx)
		if event.ev == "action" and event.act == "retry" then
			state.submitted, state.cancelled = false, false
			state.error = if type(event.value) == "string" then event.value else "Please correct the form and try again."
			state.errorField = nil
			state.focusScheduled = false
			return
		end
		if state.submitted then return end
		if event.ev == "focus" then
			for _, name in ipairs(fieldOrder(state)) do
				if event.id == inputId(name) then
					state.focus = name
					focus(state, cx)
					break
				end
			end
		elseif event.ev == "action" then
			if event.act == "submit" then
				finish(state, false)
			elseif event.act == "cancel" then
				finish(state, true)
			end
			if not state.submitted then focus(state, cx) end
		end
	end,
	save = function(state)
		local fields = {}
		for name, field in pairs(state.fields) do fields[name] = field.text end
		return {
			token = state.token, mode = state.mode, focus = state.focus, fields = fields,
			submitted = state.submitted, cancelled = state.cancelled,
		}
	end,
})
