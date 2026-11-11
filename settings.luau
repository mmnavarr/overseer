-- Overseer Settings: a plugin block (host half) in a tab of its own, opened
-- from the gear in the Projects panel's header or the palette. It edits kv and
-- git config itself and bumps `settings-rev` (Prefs.touch), which the window
-- watches to refresh and redraw. Everything saves as you change it. Installing
-- or connecting a CLI needs a terminal, which only the window can open: that
-- goes through kv `setup-request` (see runSetup in window.luau).
local ui = tern.ui
local Input = require("./input")
local Prefs = require("./prefs")
local oplog = require("./oplog")
local view = require("./view")
local wt = require("./worktrunk")

local COORDINATION_KEY = "overseer.coordination"
local TIMEOUT_MS = 15000
local LOG_SHOWN = 500
-- After Install or Connect, check again this often, for at most this long.
local WATCH_MS = 3000
local WATCH_FOR_S = 600

local function hex(text)
	return (string.gsub(text, ".", function(byte) return string.format("%02x", string.byte(byte)) end))
end

local function unhex(text)
	return (string.gsub(text, "..", function(pair) return string.char(tonumber(pair, 16)) end))
end

local function projects()
	local value = tern.kv.get("projects")
	return if type(value) == "table" then value else {}
end

local function updateProject(id, change)
	local all = projects()
	for _, project in all do
		if project.id == id then change(project) end
	end
	tern.kv.set("projects", all)
	Prefs.touch()
end

local function run(argv, done)
	local ok, err = pcall(tern.process.run, argv, { timeout_ms = TIMEOUT_MS }, function(result)
		done(result)
	end)
	if not ok then done({ status = -1, stdout = "", stderr = tostring(err) }) end
end

local function git(path, args, done)
	local argv = { "git", "--no-optional-locks", "-C", path }
	for _, arg in args do table.insert(argv, arg) end
	run(argv, done)
end

local function firstLine(text)
	return (string.match(text or "", "^%s*([^\n]-)%s*\n") or string.match(text or "", "^%s*(.-)%s*$") or "")
end

-- This block runs in Tern's daemon, whose processes get the minimal PATH the
-- Dock gives apps, so CLIs from Homebrew or ~/.bun aren't on it. Look a
-- program up the way the panel does; nil when it isn't installed.
local function resolve(argv)
	if string.sub(argv[1], 1, 1) == "/" then return if tern.fs.exists(argv[1]) then argv else nil end
	local program = wt.find_executable(argv[1])
	if not program then return nil end
	local resolved = table.clone(argv)
	resolved[1] = program
	return resolved
end

local function render(state)
	if state.cx then pcall(function() state.cx:render() end) end
end

-- Opens the log or changelog page, whose content goes in state[page]. Tern
-- keeps a block's scroll position from page to page, and Help & Diagnostics
-- sits at the bottom of Settings, so the page is drawn short first, which
-- brings the scroll back to the top, and filled in a moment later.
local function openPage(state, page, load)
	state.page, state.focus, state[page] = page, nil, "loading"
	tern.timer(30, function()
		if state.page ~= page then return end
		state[page] = load()
		render(state)
	end)
end

-- Branches and coordination for a project, read once per Settings tab.
local function load(state, project)
	local id = project.id
	state.loaded[id] = true
	git(project.path, { "for-each-ref", "--format=%(refname:short)", "refs/heads" }, function(result)
		local names = {}
		if result.status == 0 then
			for name in string.gmatch(result.stdout or "", "[^\n]+") do table.insert(names, name) end
			table.sort(names)
		end
		state.branches[id] = names
		render(state)
	end)
	git(project.path, { "config", "--bool", "--get", COORDINATION_KEY }, function(result)
		-- Exit 1: not set, which means off.
		if result.status == 0 or result.status == 1 then
			state.coordination[id] = firstLine(result.stdout) == "true"
			state.problems[id] = nil
		else
			state.problems[id] = "Couldn't read Git config: " .. firstLine(result.stderr)
		end
		render(state)
	end)
end

-- Turning coordination on or off, as the project's menu does: git config,
-- settling the opt-in migration, the operation log.
local function setCoordination(state, project, on)
	local id = project.id
	state.coordination[id] = on
	state.pending[id] = true
	local args = if on then { "config", "--local", COORDINATION_KEY, "true" }
		else { "config", "--local", "--unset", COORDINATION_KEY }
	git(project.path, args, function(result)
		state.pending[id] = nil
		-- --unset exits 5 when it was never set: already off.
		if result.status == 0 or (not on and result.status == 5) then
			local migrated = tern.kv.get("coordination-migrated")
			migrated = if type(migrated) == "table" then migrated else {}
			migrated[id] = true
			tern.kv.set("coordination-migrated", migrated)
			oplog.write("info", { op = "coordination", event = if on then "on" else "off", project = project.name })
			state.problems[id] = nil
			Prefs.touch()
		else
			state.coordination[id] = not on
			state.problems[id] = "Couldn't change Git config: " .. firstLine(result.stderr)
		end
		render(state)
	end)
end

-- The CLIs Overseer reads from. `who` turns the sign-in check's output into
-- who you are, for the row.
local INTEGRATIONS = {
	{
		id = "gh", name = "GitHub CLI", binary = "gh", site = "https://cli.github.com",
		uses = "Pull request badges and Visualize PR.",
		auth = { "gh", "auth", "status", "--hostname", "github.com" },
		who = function(output)
			local account = string.match(output, "account%s+([%w%-_]+)")
			return account and ("Signed in as " .. account .. ".")
		end,
	},
	{
		id = "linear", name = "Linear CLI", binary = "linear", site = "https://github.com/schpet/linear-cli",
		uses = "Ticket links from branches such as feature/ENG-123.",
		auth = { "linear", "auth", "whoami" },
		who = function(output)
			local workspace = string.match(output, "Workspace:%s*([^\n]-)%s*\n")
			local user = string.match(output, "User:%s*([^\n]-)%s*\n")
			if workspace and user then return "Signed in to " .. workspace .. " as " .. user .. "." end
			return workspace and ("Signed in to " .. workspace .. ".")
		end,
	},
}

local function hasBrew()
	return tern.fs.exists("/opt/homebrew/bin/brew") or tern.fs.exists("/usr/local/bin/brew")
end

-- Installed, then signed in. done(status) with "missing", "signed-out" or "connected".
local function check(state, tool, done)
	local function missing()
		state.tools[tool.id] = { status = "missing" }
		render(state)
		if done then done("missing") end
	end
	local versionArgv = resolve({ tool.binary, "--version" })
	if not versionArgv then missing(); return end
	run(versionArgv, function(version)
		if version.status ~= 0 then missing(); return end
		run(resolve(tool.auth) or tool.auth, function(auth)
			local output = (auth.stdout or "") .. "\n" .. (auth.stderr or "") .. "\n"
			local status = if auth.status == 0 then "connected" else "signed-out"
			state.tools[tool.id] = { status = status, who = if status == "connected" then tool.who(output) else nil }
			render(state)
			if done then done(status) end
		end)
	end)
end

local function checkAll(state)
	for _, tool in INTEGRATIONS do
		state.tools[tool.id] = { status = "checking" }
		check(state, tool)
	end
end

-- After Install or Connect: check again every few seconds until the status
-- moves on from `from`, for at most WATCH_FOR_S.
local function watch(state, tool, from)
	local started = os.time()
	state.watching[tool.id] = started
	local function again()
		if state.watching[tool.id] ~= started then return end
		if os.time() - started > WATCH_FOR_S then state.watching[tool.id] = nil; return end
		check(state, tool, function(status)
			if status ~= from then state.watching[tool.id] = nil else tern.timer(WATCH_MS, again) end
		end)
	end
	tern.timer(WATCH_MS, again)
end

-- Versions and paths for a bug report, gathered when Settings opens so Copy
-- can put them on the clipboard at once.
local function gatherDiagnostics(state)
	local manifest = select(2, pcall(tern.fs.read, tern.plugin.dir .. "/plugin.toml", 16384))
	local version = type(manifest) == "string" and string.match(manifest, '\nversion%s*=%s*"([^"]+)"') or "unknown"
	state.version = version
	local head = {
		"Overseer " .. version,
		"Plugin: " .. tern.plugin.dir,
		"Data: " .. tern.plugin.data,
	}
	local probes = {
		{ "Tern", { "/Applications/Tern.app/Contents/MacOS/tern", "--version" } },
		{ "Worktrunk", { "wt", "--version" } },
		{ "Git", { "git", "--version" } },
		{ "omp", { "omp", "--version" } },
		{ "gh", { "gh", "--version" } },
		{ "linear", { "linear", "--version" } },
	}
	-- Each tool's line keeps its place, whichever answers first.
	local found = {}
	local function compose()
		local lines = table.clone(head)
		for index, probe in probes do
			table.insert(lines, probe[1] .. ": " .. (found[index] or "checking…"))
		end
		state.diagnostics = table.concat(lines, "\n")
	end
	compose()
	for index, probe in probes do
		local argv = resolve(probe[2])
		if not argv then
			found[index] = "not found"
			compose()
		else
			run(argv, function(result)
				found[index] = if result.status == 0 then firstLine(result.stdout) else "not found"
				compose()
			end)
		end
	end
end

-- CHANGELOG.md, read when the Changelog opens: each "## <version> (<date>)"
-- section, newest first, with its Markdown. nil when the file can't be read.
local CHANGELOG_MAX_BYTES = 262144

local function readChangelog()
	local ok, text = pcall(tern.fs.read, tern.plugin.dir .. "/CHANGELOG.md", CHANGELOG_MAX_BYTES)
	if not ok or type(text) ~= "string" then return nil end
	local releases, current = {}, nil
	for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
		local version, date = string.match(line, "^## (%S+)%s*%(?([^)]*)%)?%s*$")
		if version then
			current = { version = version, date = if date ~= "" then date else nil, lines = {} }
			table.insert(releases, current)
		elseif current then
			table.insert(current.lines, line)
		end
	end
	for _, release in releases do
		release.body = string.match(table.concat(release.lines, "\n"), "^%s*(.-)%s*$")
		release.lines = nil
	end
	return releases
end

-- Text fields: a project's Linear workspace, "linear:<project id>".
local function fieldOf(state, name)
	local id = string.match(name or "", "^linear:(.+)$")
	return id and state.linear[id]
end

local function commit(state, name)
	local id = string.match(name, "^linear:(.+)$")
	local workspace, err = Prefs.linearWorkspace(state.linear[id].text)
	state.linearErrors[id] = err
	if not workspace then return end
	updateProject(id, function(project) project.linear = if workspace == "" then nil else workspace end)
end

-- The field a node id belongs to.
local function fieldFromId(id)
	local project = string.match(id or "", "%.proj%-(%x+)%.")
	if project and string.match(id, "%.linear$") then return "linear:" .. unhex(project) end
	return nil
end

local function refocus(state, cx)
	local id = state.focus and state.focusIds[state.focus]
	if not id then return end
	pcall(function() cx:frame({ { "focus", id } }) end)
end

local function input(state, name, key, placeholder, width)
	local props = Input.props(fieldOf(state, name))
	props.key, props.placeholder, props.w = key, placeholder, width
	return ui.node("input", props)
end

local function heading(key, text, extra)
	local title = ui.node("text", { key = "text", role = "overseer.settingsHeading", text = text })
	if not extra then return ui.node("row", { key = key, role = "overseer.settingsSection" }, { title }) end
	return ui.node("row", { key = key, role = "overseer.settingsSection", align = "center" }, {
		title, ui.node("row", { key = "spacer", grow = 1 }, {}), extra,
	})
end

local function row(key, label, hint, control, props)
	props = props or {}
	return ui.node("field", {
		key = key, label = label, hint = hint, variant = "row", error = props.error, warning = props.warning,
	}, { control })
end

local function generalSection()
	local prefs = Prefs.get()
	return {
		heading("general-head", "General"),
		ui.node("col", { key = "general", gap = "none" }, {
			row("icebox-field", "Ice Box",
				"Park worktrees you're not working on at the bottom of their project. Off shows parked worktrees in place and hides the 🧊 button; they stay parked for when you turn it back on.",
				ui.node("switch", { key = "icebox", on = prefs.icebox })),
		}),
	}
end

local function projectCard(state, project)
	local id = project.id
	if not state.loaded[id] then load(state, project) end
	state.linear[id] = state.linear[id] or Input.new(project.linear or "")
	local branches = state.branches[id]
	local options = {}
	for _, name in (branches or {}) do table.insert(options, name) end
	if project.base and not table.find(options, project.base) then table.insert(options, 1, project.base) end
	local coordination = state.coordination[id]
	return ui.node("card", { key = "proj-" .. hex(id) }, {
		ui.node("row", { key = "head", role = "overseer.settingsHead", gap = "sm" }, {
			ui.node("text", { key = "name", role = "overseer.settingsProject", text = project.name }),
			ui.node("text", { key = "path", role = "overseer.settingsPath", text = project.path }),
		}),
		row("base-field", "Base branch", "New worktrees branch from this local branch. Existing worktrees are unchanged.",
			ui.node("select", {
				key = "base", value = project.base, options = options, size = "sm",
				disabled = if branches == nil then "Reading branches…" else nil,
			})),
		row("linear-field", "Linear workspace",
			"Branches that name a ticket, such as feature/ENG-123, link to it here. Blank uses the Linear CLI's workspace.",
			input(state, "linear:" .. id, "linear", "acme", "24ch"),
			{ error = state.linearErrors[id] }),
		row("coordination-field", "Agent coordination",
			"The agents of a task and its sub-worktrees hear about each other's commits, questions and pull requests, and can message each other. Messages inform; they never act.",
			ui.node("switch", {
				key = "coordination", on = coordination == true,
				disabled = if coordination == nil then "Reading Git config…" elseif state.pending[id] then "Saving…" else nil,
			}),
			{ error = state.problems[id] }),
	})
end

local function projectsSection(state)
	local cards = {}
	for _, project in projects() do table.insert(cards, projectCard(state, project)) end
	if #cards == 0 then
		table.insert(cards, ui.node("text", {
			key = "none", spans = { ui.span("No projects yet. Add one with + in the Projects panel.", "muted") },
		}))
	end
	return {
		heading("projects-head", "Projects"),
		ui.node("col", { key = "projects", gap = "md" }, cards),
	}
end

local STATUS = {
	checking = { text = "Checking…", tone = "muted" },
	missing = { text = "Not installed", tone = "warning" },
	["signed-out"] = { text = "Not connected", tone = "warning" },
	connected = { text = "Connected", tone = "success" },
}

local function integrationRow(state, tool)
	local found = state.tools[tool.id] or { status = "checking" }
	local status = STATUS[found.status]
	local controls = { ui.node("badge", { key = "status", text = status.text, tone = status.tone }) }
	local waiting = state.watching[tool.id] ~= nil
	local function action(act, label, icon)
		table.insert(controls, ui.button(label, {
			key = act, size = "sm", icon = icon, variant = "primary", busy = waiting,
			title = if Prefs.SETUP[act] then "Runs " .. Prefs.SETUP[act].command .. " in a new tab" else tool.site,
			actions = { click = act },
		}))
	end
	if found.status == "missing" then
		if hasBrew() then action(tool.id .. "-install", "Install", "download") else action(tool.id .. "-site", "Get it", "link") end
	elseif found.status == "signed-out" then
		action(tool.id .. "-login", "Connect", "key")
	end
	local hint = tool.uses
	if found.who then hint = hint .. " " .. found.who end
	if waiting then hint = hint .. " Finish in its tab; this updates by itself." end
	return row(tool.id .. "-field", tool.name, hint, ui.node("row", { key = "controls", gap = "sm", align = "center" }, controls))
end

local function integrationsSection(state)
	local rows = {}
	for _, tool in INTEGRATIONS do table.insert(rows, integrationRow(state, tool)) end
	return {
		heading("integrations-head", "Integrations", ui.button("Check again", {
			key = "recheck", size = "sm", variant = "quiet", icon = "refresh", actions = { click = "recheck" },
		})),
		ui.node("col", { key = "integrations", gap = "none" }, rows),
	}
end

local function helpSection()
	local function action(key, label, hint, text, act, icon)
		return row(key, label, hint, ui.button(text, { key = act, size = "sm", icon = icon, actions = { click = act } }))
	end
	return {
		heading("help-head", "Help & Diagnostics"),
		ui.node("col", { key = "help", gap = "none" }, {
			action("guide-field", "How Overseer works", "The guide: every row, badge and menu in the Projects panel.", "Open guide", "guide", "doc"),
			action("changelog-field", "Changelog", "What changed in each version, newest first.", "Show changelog", "changelog", "history"),
			action("log-field", "Operation log", "What Overseer did, newest first: creations, deletions, briefs and coordination messages, and how each ended.", "Show log", "log", "list"),
			action("diagnostics-field", "Diagnostics", "Overseer's version and paths, and the tools it found, for a bug report.", "Copy", "copy-diagnostics", "clipboard"),
		}),
	}
end

local function settingsPage(state)
	local children = {
		ui.node("row", { key = "top", align = "baseline", gap = "sm" }, {
			ui.node("text", { key = "title", role = "overseer.settingsTitle", text = "Overseer Settings" }),
			ui.node("text", { key = "version", spans = { ui.span(if state.version then "v" .. state.version else "", "muted") } }),
		}),
	}
	for _, section in { generalSection(), projectsSection(state), integrationsSection(state), helpSection() } do
		for _, node in section do table.insert(children, node) end
	end
	return ui.node("col", { key = "page", role = "overseer.settingsPage", gap = "lg" }, children)
end

local function logPage(state)
	return ui.node("col", { key = "log", role = "overseer.settingsPage", gap = "md" }, {
		ui.node("row", { key = "nav", gap = "sm", align = "center" }, {
			ui.button("Settings", {
				key = "back", icon = "back", variant = "quiet", size = "sm", keys = { "esc" }, actions = { click = "back" },
			}),
			ui.node("row", { key = "spacer", grow = 1 }, {}),
			ui.button("", { key = "reload", icon = "refresh", variant = "quiet", size = "sm", title = "Reload", actions = { click = "log" } }),
		}),
		ui.node("text", { key = "title", role = "overseer.settingsTitle", text = "Operation log" }),
		if state.log == "loading" then ui.node("text", { key = "loading", spans = { ui.span("Loading…", "muted") } })
			else view.operationLog(state.log or {}),
	})
end

local function changelogPage(state)
	local children = {
		ui.node("row", { key = "nav", gap = "sm", align = "center" }, {
			ui.button("Settings", {
				key = "back", icon = "back", variant = "quiet", size = "sm", keys = { "esc" }, actions = { click = "back" },
			}),
		}),
		ui.node("text", { key = "title", role = "overseer.settingsTitle", text = "Changelog" }),
	}
	local releases = if type(state.changelog) == "table" then state.changelog else {}
	if state.changelog == "loading" then
		table.insert(children, ui.node("text", { key = "loading", spans = { ui.span("Loading…", "muted") } }))
	elseif #releases == 0 then
		table.insert(children, ui.node("text", {
			key = "missing", spans = { ui.span("Couldn't read CHANGELOG.md in " .. tern.plugin.dir .. ".", "muted") },
		}))
	end
	for _, release in releases do
		local head = {
			ui.node("text", { key = "version", role = "overseer.releaseVersion", text = release.version }),
		}
		if release.date then
			table.insert(head, ui.node("text", { key = "date", spans = { ui.span(release.date, "muted") } }))
		end
		if release.version == state.version then
			table.insert(head, ui.node("badge", { key = "installed", text = "Installed", tone = "success" }))
		end
		table.insert(children, ui.node("col", { key = "rel-" .. release.version, role = "overseer.release", gap = "sm" }, {
			ui.node("row", { key = "head", role = "overseer.releaseHead", gap = "sm" }, head),
			ui.md(release.body),
		}))
	end
	return ui.node("col", { key = "changelog", role = "overseer.settingsPage", gap = "lg" }, children)
end

local function integration(id)
	for _, tool in INTEGRATIONS do
		if tool.id == id then return tool end
	end
	return nil
end

tern.block.define("settings", {
	font = "sans",
	init = function(cx, _args, _saved)
		local state = {
			cx = cx, page = "settings", focus = nil, focusIds = {},
			linear = {}, linearErrors = {}, branches = {}, coordination = {}, pending = {}, problems = {}, loaded = {},
			tools = {}, watching = {},
		}
		gatherDiagnostics(state)
		checkAll(state)
		return state
	end,
	title = function()
		return "Overseer Settings"
	end,
	view = function(state, cx)
		state.cx = cx
		return { main = ui.node("col", { role = "overseer.settings" }, {
			if state.page == "log" then logPage(state) elseif state.page == "changelog" then changelogPage(state) else settingsPage(state),
		}) }
	end,
	key = function(state, key, cx)
		local name = key.name
		if state.page ~= "settings" then
			if name == "escape" or name == "esc" then state.page = "settings"; return true end
			return false
		end
		local field = fieldOf(state, state.focus)
		if not field then return false end
		if name == "escape" or name == "esc" or name == "enter" or name == "tab" then
			state.focus = nil
			return true
		end
		if key.meta and string.lower(name) == "c" then
			local selection = Input.selection(field)
			if selection == "" then return false end
			cx:copy(selection)
			return false
		end
		local handled, err = Input.key(field, key)
		if not handled then return false end
		if err then
			state.linearErrors[string.sub(state.focus, 8)] = err
		else
			commit(state, state.focus)
		end
		refocus(state, cx)
		return true
	end,
	event = function(state, ev, cx)
		state.cx = cx
		if ev.ev == "focus" and ev.id then
			local name = fieldFromId(ev.id)
			if name and fieldOf(state, name) then
				state.focus, state.focusIds[name] = name, ev.id
			end
			return
		end
		local id = ev.id or ""
		local project = string.match(id, "%.proj%-(%x+)%.")
		project = project and unhex(project)
		if ev.ev == "change" then
			if string.match(id, "%.icebox$") then
				Prefs.set("icebox", ev.value == true)
			elseif project and string.match(id, "%.base$") and type(ev.value) == "string" then
				local name = ev.value
				updateProject(project, function(record) record.base = name end)
				cx:toast("info", "Base branch changed", name)
			elseif project and string.match(id, "%.coordination$") then
				for _, record in projects() do
					if record.id == project then setCoordination(state, record, ev.value == true) end
				end
			end
		elseif ev.ev == "action" then
			local act = ev.act or ""
			local toolId, step = string.match(act, "^(%w+)%-(%w+)$")
			local tool = toolId and integration(toolId)
			if Prefs.SETUP[act] and tool then
				-- The window opens the terminal (runSetup); this tab watches for the result.
				tern.kv.set("setup-request", { run = act, window = ev.window, at = os.time() })
				watch(state, tool, (state.tools[tool.id] or {}).status)
			elseif tool and step == "site" then
				cx:open(tool.site)
			elseif act == "recheck" then
				checkAll(state)
			elseif act == "log" then
				openPage(state, "log", function() return oplog.recent(LOG_SHOWN) end)
			elseif act == "changelog" then
				openPage(state, "changelog", readChangelog)
			elseif act == "back" then
				state.page = "settings"
			elseif act == "guide" then
				cx:open(tern.plugin.dir .. "/README.md")
			elseif act == "copy-diagnostics" then
				cx:copy(state.diagnostics or "")
				cx:toast("info", "Diagnostics copied")
			end
		end
	end,
})
